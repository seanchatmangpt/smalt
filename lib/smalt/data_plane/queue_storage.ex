defmodule Smalt.DataPlane.QueueStorage do
  @moduledoc """
  Azure Queue Storage REST engine (`Microsoft.Storage/storageAccounts`, queue
  service) — G1 (v26.10.19). Scoping:
  docs/jira/v26.10.18/azsim-burn/G1-QUEUE-STORAGE-SCOPING.md.

  Pure Store-backed, wire-agnostic: every handler returns a uniform
  `{:ok, status, headers, body}` / `{:error, status, code, msg}` tuple; the
  egress router maps errors onto the blob `x-ms-error-code` JSON envelope
  (same discipline as BlobStorage).

  Surface: queue create/delete/list (`restype=queue`, `comp=list`), Put
  Messages, Get Messages (`visibilitytimeout`/`numofmessages`), Update/Delete
  Message with `popreceipt`. A stale or superseded popreceipt replay answers
  404 `PopReceiptMismatch`; a missing message answers 404 `MessageNotFound`;
  a dequeued message re-appears after its visibility timeout elapses.

  Deliberately NOT the Service Bus AMQP stack (the smalt_sb table prefix): a different
  lock model (popreceipt + visibility timeout vs AMQP lock token) on
  different tables `:smalt_q_queues` / `:smalt_q_messages`.

  Layout: queues are binary-prefix rows `downcase(account/queue)`; messages
  are binary rows `downcase(account/queue)/<20-digit zero-padded seq>-<rand>`
  so :ordered_set term order IS the FIFO order and every prefix scan
  (`Store.prefix_keys/2`, queue cascade delete, account teardown) stays on the
  binary-key contract.

  Table ownership (S8 discipline, same as Cosmos): BOTH tables are created
  ONCE by `Smalt.Store.init/1` (coordinator-owned). This module NEVER creates
  tables — when the tables are absent every handler fails closed with
  `{:error, :store_not_ready}` (the router maps to 503 RouteNotReady).
  """

  alias Smalt.Store

  @queues_table :smalt_q_queues
  @messages_table :smalt_q_messages
  @version "2021-12-02"

  # Azure parity: a message payload is at most 64KiB.
  @max_message_bytes 64 * 1024
  # visibilitytimeout grammar: 0..604800 seconds.
  @max_visibility_timeout_s 604_800
  # numofmessages grammar: 1..32.
  @max_numofmessages 32
  # Azure default message TTL: 7 days.
  @default_ttl_ms 7 * 24 * 3600 * 1000
  @seq_width 20

  @type resp :: {:ok, pos_integer(), map(), map() | binary() | nil}
  @type not_ready :: {:error, :store_not_ready}

  # ---------------------------------------------------------------------------
  # Store readiness (never creates tables)
  # ---------------------------------------------------------------------------

  @doc "True only when the coordinator-owned Store created the queue tables."
  @spec store_ready?() :: boolean()
  def store_ready? do
    Enum.all?([@queues_table, @messages_table], fn t -> :ets.info(t) != :undefined end)
  end

  defp ready! do
    if store_ready?(), do: :ok, else: {:error, :store_not_ready}
  end

  defp std_headers do
    %{"x-ms-request-id" => request_id(), "x-ms-version" => @version}
  end

  defp request_id, do: Base.encode16(:crypto.strong_rand_bytes(8), case: :lower)

  defp key(account, queue), do: String.downcase("#{account}/#{queue}")

  # ---------------------------------------------------------------------------
  # Queue lifecycle (restype=queue, comp=list)
  # ---------------------------------------------------------------------------

  @doc """
  Put Queue (`PUT /{account}/{queue}?restype=queue`). 201 on create; 409
  QueueAlreadyExists on duplicate (no silent replace — the WORM-clock-reset
  bug class).
  """
  @spec create_queue(String.t(), String.t()) ::
          {:ok, 201, map()} | {:error, 400 | 409, String.t(), String.t()} | not_ready()
  def create_queue(account, queue) do
    with :ok <- ready!(),
         :ok <- check_queue_name(queue),
         :error <- Store.get(@queues_table, key(account, queue)) do
      Store.put(@queues_table, key(account, queue), %{
        "account" => account,
        "queue" => queue,
        "created_at" => System.os_time(:millisecond)
      })

      {:ok, 201, std_headers()}
    else
      {:ok, _existing} ->
        {:error, 409, "QueueAlreadyExists", "The specified queue already exists."}

      {:error, _, _, _} = err ->
        err
    end
  end

  @doc """
  Delete Queue (`DELETE /{account}/{queue}?restype=queue`). 204 with cascade
  delete of every message; 404 QueueNotFound when absent.
  """
  @spec delete_queue(String.t(), String.t()) ::
          {:ok, 204, map()} | {:error, 404 | 400, String.t(), String.t()} | not_ready()
  def delete_queue(account, queue) do
    with :ok <- ready!(),
         {:ok, _} <- Store.get(@queues_table, key(account, queue)) do
      base = key(account, queue) <> "/"

      for k <- Store.prefix_keys(@messages_table, base) do
        Store.delete(@messages_table, k)
      end

      Store.delete(@queues_table, key(account, queue))
      {:ok, 204, std_headers()}
    else
      :error ->
        {:error, 404, "QueueNotFound", "The specified queue does not exist."}

      {:error, _, _, _} = err ->
        err
    end
  end

  @doc """
  List Queues (`GET /{account}?comp=list&restype=queue`). XML
  EnumerationResults envelope with one `<Queue><Name>` element per queue;
  supports `prefix`, `marker` and `maxresults`. Typed 400 on invalid
  `maxresults` (BlobService list discipline).
  """
  @spec list_queues(String.t(), map()) ::
          {:ok, 200, map(), binary()} | {:error, 400, String.t(), String.t()} | not_ready()
  def list_queues(account, opts \\ %{}) do
    with :ok <- ready!(),
         {:ok, max} <- parse_maxresults(opts["maxresults"]) do
      rows =
        @queues_table
        |> Store.list_prefix(key(account, ""))
        |> Enum.filter(&is_map(&1))

      prefix = opts["prefix"]

      rows =
        if is_binary(prefix) and prefix != "" do
          Enum.filter(rows, &String.starts_with?(&1["queue"], prefix))
        else
          rows
        end

      max = max || 5000
      marker = opts["marker"]

      rows =
        if is_binary(marker) and marker != "" do
          Enum.drop_while(rows, &(&1["queue"] <= marker))
        else
          rows
        end

      {page, rest} = Enum.split(rows, max)
      next_marker = if rest == [] or page == [], do: nil, else: List.last(page)["queue"]

      xml =
        ~s(<?xml version="1.0" encoding="utf-8"?><EnumerationResults ServiceEndpoint="http://localhost/">) <>
          "<Prefix>#{xml_escape(prefix || "")}</Prefix>" <>
          if(is_binary(marker) and marker != "", do: "<Marker>#{xml_escape(marker)}</Marker>", else: "") <>
          "<MaxResults>#{max}</MaxResults><Queues>" <>
          Enum.map_join(page, "", &"<Queue><Name>#{xml_escape(&1["queue"])}</Name></Queue>") <>
          "</Queues>" <>
          if(next_marker, do: "<NextMarker>#{xml_escape(next_marker)}</NextMarker>", else: "") <>
          "</EnumerationResults>"

      {:ok, 200, std_headers(), xml}
    else
      {:error, _, _, _} = err ->
        err
    end
  end

  defp check_queue_name(name) when is_binary(name) do
    if name == "" or byte_size(name) > 63 or
         not Regex.match?(~r/^[a-z0-9][a-z0-9-]{1,61}[a-z0-9]$/, name) do
      {:error, 400, "InvalidResourceName",
       "The specified queue name is invalid (3-63 bytes, lowercase letters, digits and dashes, starting and ending alphanumeric)."}
    else
      :ok
    end
  end

  defp check_queue_name(_),
    do: {:error, 400, "InvalidResourceName", "The specified queue name is invalid."}

  defp parse_maxresults(nil), do: {:ok, nil}

  defp parse_maxresults(""), do:
         {:error, 400, "InvalidQueryParameterValue",
          "Value for query parameter 'maxresults' is invalid."}

  defp parse_maxresults(v) when is_binary(v) do
    case Integer.parse(v) do
      {n, ""} when is_integer(n) and n > 0 -> {:ok, min(n, 5000)}
      _ ->
        {:error, 400, "InvalidQueryParameterValue",
         "Value for query parameter 'maxresults' is invalid."}
    end
  end

  defp parse_maxresults(_),
    do: {:error, 400, "InvalidQueryParameterValue",
         "Value for query parameter 'maxresults' is invalid."}

  # ---------------------------------------------------------------------------
  # Messages
  # ---------------------------------------------------------------------------

  @doc """
  Put Message (`POST /{account}/{queue}/messages`). Body is the Azure XML
  envelope `<QueueMessage><MessageText>...</MessageText></QueueMessage>`
  (HTML-escaped text); a body with no `<MessageText>` element is taken as the
  raw text. 201 renders the PopReceipt XML. 404 QueueNotFound.
  """
  @spec put_message(String.t(), String.t(), binary(), map()) ::
          resp() | {:error, 400 | 404, String.t(), String.t()} | not_ready()
  def put_message(account, queue, body, opts \\ %{}) do
    with :ok <- ready!(),
         {:ok, _} <- Store.get(@queues_table, key(account, queue)),
         {:ok, text} <- parse_message_text(body),
         :ok <- check_message_size(text) do
      now = Map.get(opts, "now_ms") || System.os_time(:millisecond)
      ttl_ms = parse_ttl(opts["messagettl"]) || @default_ttl_ms
      qkey = key(account, queue)
      seq = next_seq(qkey)
      msg_id = uuid()
      # key sorts by (queue, seq) => :ordered_set term order is FIFO.
      mkey = "#{qkey}/#{Integer.to_string(seq, 10) |> String.pad_leading(@seq_width, "0")}-#{msg_id}"

      record = %{
        "message_id" => msg_id,
        "mkey" => mkey,
        "text" => text,
        "inserted" => now,
        "expires_at" => now + ttl_ms,
        "next_visible_on" => now,
        "popreceipt" => popreceipt(now + ttl_ms),
        "pop_expiry" => now + ttl_ms,
        "dequeue_count" => 0
      }

      Store.put(@messages_table, mkey, record)
      {:ok, 201, std_headers(), "<QueueMessagesList>" <> message_xml(record) <> "</QueueMessagesList>"}
    else
      :error ->
        {:error, 404, "QueueNotFound", "The specified queue does not exist."}

      {:error, _, _, _} = err ->
        err
    end
  end

  @doc """
  Get Messages (`GET /{account}/{queue}/messages?visibilitytimeout=&numofmessages=`).
  Returns only currently-visible, unexpired messages (FIFO), marks each
  invisible for `visibilitytimeout` seconds (default 30), increments
  DequeueCount and issues a fresh PopReceipt. 404 QueueNotFound.
  """
  @spec get_messages(String.t(), String.t(), map()) ::
          resp() | {:error, 400 | 404, String.t(), String.t()} | not_ready()
  def get_messages(account, queue, opts \\ %{}) do
    with :ok <- ready!(),
         {:ok, _} <- Store.get(@queues_table, key(account, queue)),
         {:ok, vt_s} <- parse_visibility_timeout(opts["visibilitytimeout"]),
         {:ok, n} <- parse_numofmessages(opts["numofmessages"]) do
      now = Map.get(opts, "now_ms") || System.os_time(:millisecond)
      base = key(account, queue) <> "/"
      vt_ms = vt_s * 1000

      visible =
        @messages_table
        |> Store.list_prefix(base)
        |> Enum.filter(&(is_map(&1) and visible?(&1, now)))
        |> Enum.take(n)

      updated =
        Enum.map(visible, fn r ->
          r2 =
            r
            |> Map.put("next_visible_on", now + vt_ms)
            |> Map.put("popreceipt", popreceipt(now + vt_ms))
            |> Map.put("pop_expiry", now + vt_ms)
            |> Map.put("dequeue_count", (r["dequeue_count"] || 0) + 1)

          Store.put(@messages_table, r2["mkey"], r2)
          r2
        end)

      body =
        "<QueueMessagesList>" <>
          Enum.map_join(updated, "", &message_xml(&1, dequeue: true, text: true)) <>
          "</QueueMessagesList>"

      {:ok, 200, std_headers(), body}
    else
      :error ->
        {:error, 404, "QueueNotFound", "The specified queue does not exist."}

      {:error, _, _, _} = err ->
        err
    end
  end

  defp visible?(r, now),
    do: r["next_visible_on"] <= now and r["expires_at"] > now

  @doc """
  Update Message (`PUT /{account}/{queue}/messages/{id}?popreceipt=...&visibilitytimeout=...`).
  Rotates the popreceipt, optionally replaces the message text, extends
  visibility. Stale/superseded popreceipt -> 404 `PopReceiptMismatch`; missing
  message -> 404 `MessageNotFound`.
  """
  @spec update_message(String.t(), String.t(), String.t(), String.t(), binary() | nil, map()) ::
          resp() | {:error, 400 | 404, String.t(), String.t()} | not_ready()
  def update_message(account, queue, msg_id, popreceipt, body, opts \\ %{}) do
    with :ok <- ready!(),
         {:ok, vt_s} <- parse_visibility_timeout(opts["visibilitytimeout"]),
         :ok <- check_popreceipt(popreceipt),
         {:ok, text_or_nil} <- parse_update_body(body) do
      now = Map.get(opts, "now_ms") || System.os_time(:millisecond)

      with {:ok, r} <- find_message(account, queue, msg_id),
           :ok <- check_receipt(r, popreceipt, now) do
        new_receipt = popreceipt(now + vt_s * 1000)

        r2 =
          r
          |> Map.put("text", text_or_nil || r["text"])
          |> Map.put("next_visible_on", now + vt_s * 1000)
          |> Map.put("popreceipt", new_receipt)
          |> Map.put("pop_expiry", now + vt_s * 1000)

        Store.put(@messages_table, r2["mkey"], r2)
        {:ok, 200, std_headers(), "<QueueMessagesList>" <> message_xml(r2) <> "</QueueMessagesList>"}
      else
        :error ->
          {:error, 404, "MessageNotFound", "The specified message does not exist."}

        {:error, _, _, _} = err ->
          err
      end
    else
      {:error, _, _, _} = err ->
        err
    end
  end

  @doc """
  Delete Message (`DELETE /{account}/{queue}/messages/{id}?popreceipt=...`).
  204; the message is permanently removed. Stale/superseded popreceipt -> 404
  `PopReceiptMismatch`; missing message -> 404 `MessageNotFound`.
  """
  @spec delete_message(String.t(), String.t(), String.t(), String.t(), map()) ::
          {:ok, 204, map()} | {:error, 400 | 404, String.t(), String.t()} | not_ready()
  def delete_message(account, queue, msg_id, popreceipt, opts \\ %{}) do
    with :ok <- ready!(),
         :ok <- check_popreceipt(popreceipt) do
      now = Map.get(opts, "now_ms") || System.os_time(:millisecond)

      with {:ok, r} <- find_message(account, queue, msg_id),
           :ok <- check_receipt(r, popreceipt, now) do
        Store.delete(@messages_table, r["mkey"])
        {:ok, 204, std_headers()}
      else
        :error ->
          {:error, 404, "MessageNotFound", "The specified message does not exist."}

        {:error, _, _, _} = err ->
          err
      end
    else
      {:error, _, _, _} = err ->
        err
    end
  end

  # A popreceipt is valid only while it is still CURRENT: it must equal the
  # record's receipt AND its window must not have elapsed (visibility expiry
  # supersedes it — the message re-appeared, so the old receipt is stale).
  # Exactly two failure codes: present message, wrong/expired receipt ->
  # PopReceiptMismatch; missing message -> MessageNotFound. Both 404, both in
  # the x-ms-error-code envelope (the scoping doc's stale-replay face).
  defp check_receipt(r, popreceipt, now) do
    if r["popreceipt"] == popreceipt and now < r["pop_expiry"] do
      :ok
    else
      {:error, 404, "PopReceiptMismatch",
       "The specified pop receipt does not match the message or has expired."}
    end
  end

  # Bounded per-queue scan for a message id. The per-queue $seq counter row is
  # an integer value, not a map — filtered out.
  defp find_message(account, queue, msg_id) do
    @messages_table
    |> Store.list_prefix(key(account, queue) <> "/")
    |> Enum.find_value(:error, fn
      %{"message_id" => ^msg_id} = r -> {:ok, r}
      _ -> nil
    end)
  end

  defp next_seq(qkey) do
    Store.update_counter(@messages_table, "#{qkey}/$seq", 1)
  end

  defp check_popreceipt(pr) when is_binary(pr) and pr != "", do: :ok

  defp check_popreceipt(_),
    do: {:error, 400, "MissingRequiredQueryParameter",
         "A query parameter popreceipt is missing."}

  defp parse_visibility_timeout(nil), do: {:ok, 30}

  defp parse_visibility_timeout(v) when is_binary(v) do
    case Integer.parse(v) do
      {n, ""} when n >= 0 and n <= @max_visibility_timeout_s ->
        {:ok, n}

      _ ->
        {:error, 400, "InvalidQueryParameterValue",
         "Value for query parameter 'visibilitytimeout' is out of range."}
    end
  end

  defp parse_visibility_timeout(_),
    do: {:error, 400, "InvalidQueryParameterValue",
         "Value for query parameter 'visibilitytimeout' is out of range."}

  defp parse_numofmessages(nil), do: {:ok, 1}

  defp parse_numofmessages(v) when is_binary(v) do
    case Integer.parse(v) do
      {n, ""} when n >= 1 and n <= @max_numofmessages ->
        {:ok, n}

      _ ->
        {:error, 400, "InvalidQueryParameterValue",
         "Value for query parameter 'numofmessages' is out of range."}
    end
  end

  defp parse_numofmessages(_),
    do: {:error, 400, "InvalidQueryParameterValue",
         "Value for query parameter 'numofmessages' is out of range."}

  defp parse_ttl(v) when is_binary(v) do
    case Integer.parse(v) do
      {n, ""} when n > 0 -> n * 1000
      _ -> @default_ttl_ms
    end
  end

  defp parse_ttl(_), do: @default_ttl_ms

  defp check_message_size(text) when byte_size(text) <= @max_message_bytes, do: :ok

  defp check_message_size(_text),
    do: {:error, 400, "InvalidXmlDocument", "The message text exceeds the 64KiB limit."}

  # Accepts the Azure envelope (`<QueueMessage><MessageText>`), a bare
  # `<MessageText>` wrapper, or a raw body as the text itself. MessageText
  # content is HTML-unescaped.
  defp parse_message_text(body) when is_binary(body) do
    {:ok, extract_text(body)}
  end

  defp parse_message_text(_),
    do: {:error, 400, "InvalidXmlDocument", "The request body is not valid."}

  defp parse_update_body(nil), do: {:ok, nil}
  defp parse_update_body(""), do: {:ok, nil}

  defp parse_update_body(body) when is_binary(body), do: {:ok, extract_text(body)}

  defp parse_update_body(_),
    do: {:error, 400, "InvalidXmlDocument", "The request body is not valid."}

  defp extract_text(body) do
    case Regex.run(~r/<MessageText>(.*)<\/MessageText>/s, body) do
      [_, inner] -> unescape_xml(inner)
      nil -> body
    end
  end

  defp unescape_xml(s) do
    s
    |> String.replace("&lt;", "<")
    |> String.replace("&gt;", ">")
    |> String.replace("&quot;", "\"")
    |> String.replace("&apos;", "'")
    |> String.replace("&amp;", "&")
  end

  defp xml_escape(s) do
    s
    |> String.replace("&", "&amp;")
    |> String.replace("<", "&lt;")
    |> String.replace(">", "&gt;")
  end

  # Timestamps render in RFC 1123 ("Thu, 19 Oct 2026 12:00:00 GMT"), the Azure
  # Queue Storage wire form.
  defp rfc1123(ms) do
    ms
    |> DateTime.from_unix!(:millisecond)
    |> Calendar.strftime("%a, %d %b %Y %H:%M:%S GMT")
  end

  defp message_xml(r, opts \\ []) do
    dequeue = if Keyword.get(opts, :dequeue, false), do: "<DequeueCount>#{r["dequeue_count"]}</DequeueCount>", else: ""
    text = if Keyword.get(opts, :text, false), do: "<MessageText>#{xml_escape(r["text"])}</MessageText>", else: ""

    "<QueueMessage>" <>
      "<MessageId>#{r["message_id"]}</MessageId>" <>
      "<InsertionTime>#{rfc1123(r["inserted"])}</InsertionTime>" <>
      "<ExpirationTime>#{rfc1123(r["expires_at"])}</ExpirationTime>" <>
      "<PopReceipt>#{r["popreceipt"]}</PopReceipt>" <>
      "<TimeNextVisible>#{rfc1123(r["next_visible_on"])}</TimeNextVisible>" <>
      dequeue <>
      text <>
      "</QueueMessage>"
  end

  defp popreceipt(expiry_ms) do
    # Opaque receipt; the expiry is baked into the token so a receipt from an
    # earlier visibility window can never collide with a later one.
    Base.encode64("v2:#{expiry_ms}:#{:erlang.unique_integer([:positive])}")
  end

  defp uuid do
    :crypto.strong_rand_bytes(16)
    |> Base.encode16(case: :lower)
    |> then(fn h ->
      {a, rest} = String.split_at(h, 8)
      {b, rest} = String.split_at(rest, 4)
      {c, rest} = String.split_at(rest, 4)
      {d, e} = String.split_at(rest, 4)
      "#{a}-#{b}-#{c}-#{d}-#{e}"
    end)
  end

  # ---------------------------------------------------------------------------
  # Account teardown cascade (D127 discipline — mirrors BlobStorage)
  # ---------------------------------------------------------------------------

  @doc """
  Removes every queue + message row for `account` (ARM storageAccount
  teardown cascade). Coordinator-table-absent-safe via :ets.info guards.
  """
  @spec drop_account_data(String.t()) :: :ok
  def drop_account_data(account) do
    base = key(account, "")

    for table <- [@queues_table, @messages_table],
        :ets.info(table) != :undefined,
        k <- Store.prefix_keys(table, base) do
      Store.delete(table, k)
    end

    :ok
  end
end
