defmodule PopcornDemo.LiveQueue do
  @moduledoc """
  WASM-BEAM queue round-trip walk (ERRC-R4): ensure/reuse a real queue, PUT
  one real message with a unique id, GET (dequeue) it, assert the returned
  body-borne values match, then DELETE it via its popreceipt. Chicago
  school — the only collaborators are the live smalt substrate and the wire.

  REST face (verified with curl against the live substrate BEFORE this module
  existed, 2026-10-20):

  - STS token: POST {sts}/:tenant/oauth2/v2.0/token (enforce-mode bearer —
    the queue plane sits behind `plug(Smalt.Auth.Bearer)` in the egress
    router; SAS `sig=` is the alternate face but bearer is the pinned
    default).
  - Queue: PUT /{account}/{queue}?restype=queue -> 201 create (409
    QueueAlreadyExists = reuse, idempotent for the walk).
  - Put Message: POST /{account}/{queue}/messages with body
    `<QueueMessage><MessageText>html-escaped</MessageText></QueueMessage>`
    -> 201 QueueMessagesList. WIRE TRAP witnessed during the curl probe: the
    POST MUST carry a content-type the plug treats as an opaque body — with
    curl's default `application/x-www-form-urlencoded` the stored message
    text came back EMPTY (`<MessageText></MessageText>`), so the walk pins
    `content-type: application/xml`.
  - Get Messages: GET /{account}/{queue}/messages?visibilitytimeout=&numofmessages=1
    -> 200, rotates the PopReceipt, marks invisible. Delete Message: DELETE
    /{account}/{queue}/messages/{id}?popreceipt=... -> 204.

  Host transport is `PopcornDemo.Transport.Httpc` (real `:httpc`, loopback
  http only; inets beams are broken under the popcorn_demo mix env without
  the explicit ebin pathing that module performs — witnessed 2026-10-20).
  No Transport gap: every wire value this module needs (MessageId,
  PopReceipt, MessageText) is parsed from the response BODY
  (QueueMessagesList envelope), never from response headers, so the
  Transport `%{status, body}` response map is sufficient for this surface.

  QUEUE-ISOLATION LAW (W13-P, 2026-10-20): EVERY walk in this module —
  including `run/0` — rides a RUN-UNIQUE queue minted by `with_queue/2`
  (`popcorn-q-<ms>-<rand>`). A shared fixed queue name cross-talks under
  parallel full-suite runs: two concurrent `run/0` walkers dequeue each
  other's messages and the byte-for-byte assert fails with a same-length
  byte mismatch. Witnessed; fixed at the source, not in the tests.
  """

  @base "http://127.0.0.1:8443"
  @sts "http://127.0.0.1:9443"
  @tenant "smalt-tenant"
  @account "popcorn"
  @ms_version "2021-12-02"

  @doc """
  Runs the walk on a run-unique queue. Returns:

  - `{:ok, "queue=OK(<queue>:<n>-bytes-roundtrip)"}`
  - `{:skip, "queue=SKIP(<loud reason>)"}`
  - `{:error, "queue=FAIL(<step>:<reason>)"}`
  """
  def run do
    with_queue("run", fn token, queue ->
      payload = payload()

      with {:ok, %{n: n, id: id, popreceipt: pr}} <- put_get(token, queue, payload),
           :ok <- delete_message(id, pr, token, queue) do
        {:ok, "queue=OK(#{queue}:#{n}-bytes-roundtrip)"}
      end
    end)
  end

  # -- walk steps ----------------------------------------------------------

  defp health do
    case request(%{method: "GET", url: @base <> "/healthz", body: nil}) do
      {:ok, %{status: 200}} -> {:ok, :ready}
      {:ok, %{status: st}} -> {:error, {"health", "http-#{st}"}}
      {:error, _} = err -> err
    end
  end

  defp token do
    req = %{
      method: "POST",
      url: @sts <> "/#{@tenant}/oauth2/v2.0/token",
      headers: [{"content-type", "application/x-www-form-urlencoded"}],
      body: "grant_type=client_credentials&client_id=popcorn-demo&client_secret=not-checked"
    }

    case request(req) do
      {:ok, %{status: 200, body: body}} ->
        case Jason.decode(body) do
          {:ok, %{"access_token" => tok}} when is_binary(tok) -> {:ok, tok}
          _ -> {:error, {"token", "no-access_token-in-sts-body"}}
        end

      {:ok, %{status: st, body: body}} ->
        {:error, {"token", "http-#{st}:#{slice(body)}"}}

      {:error, {step, reason}} when is_atom(step) ->
        {:error, {{Atom.to_string(step), reason}}}
    end
  end

  defp put_get(token, queue, payload) do
    put_req = %{
      method: "POST",
      url: @base <> "/#{@account}/#{queue}/messages",
      headers: auth_headers(token) ++ [{"content-type", "application/xml"}],
      body: "<QueueMessage><MessageText>#{xml_escape(payload)}</MessageText></QueueMessage>"
    }

    get_req = %{
      method: "GET",
      url: @base <>
        "/#{@account}/#{queue}/messages?visibilitytimeout=60&numofmessages=1",
      headers: auth_headers(token),
      body: nil
    }

    with {:ok, %{status: 201, body: put_body}} <- step_req("put-message", put_req, 201),
         {:ok, id} <- xml_field(put_body, "MessageId", "put-message") do
      case step_req("get-messages", get_req, 200) do
        {:ok, %{status: 200, body: get_body}} ->
          with {:ok, raw_text} <- xml_field(get_body, "MessageText", "get-messages"),
               got_text = xml_unescape(raw_text),
               {:ok, id2} <- xml_field(get_body, "MessageId", "get-messages"),
               {:ok, pr} <- xml_field(get_body, "PopReceipt", "get-messages") do
            cond do
              got_text != payload ->
                {:error, {"compare", "byte-mismatch(put=#{byte_size(payload)},got=#{byte_size(got_text)})"}}

              id2 != id ->
                {:error, {"fifo", "got-message-#{id2}-wanted-#{id}"}}

              true ->
                {:ok, %{n: byte_size(payload), id: id, popreceipt: pr}}
            end
          end

        {:ok, %{status: st, body: body}} ->
          {:error, {"get-messages", "http-#{st}:#{slice(body)}"}}

        {:error, reason} ->
          {:error, {"get-messages", fmt(reason)}}
      end
    end
  end

  defp step_req(step, req, want) do
    case request(req) do
      {:ok, %{status: ^want} = resp} -> {:ok, resp}
      {:ok, %{status: st, body: body}} -> {:error, {step, "http-#{st}:#{slice(body)}"}}
      {:error, reason} -> {:error, {step, fmt(reason)}}
    end
  end

  # -- xml helpers (the surface is the Azure QueueMessagesList envelope) ----

  defp xml_field(xml, tag, step) do
    case Regex.run(~r/<#{tag}>(.*?)<\/#{tag}>/s, xml) do
      [_, val] -> {:ok, val}
      nil -> {:error, {step, "missing-<#{tag}>-in-response"}}
    end
  end

  # Mirrors the server's xml_escape/unescape pair (QueueStorage stores the
  # unescaped text and escapes only at render time) so the byte-for-byte
  # compare is on the real stored bytes.
  defp xml_escape(s),
    do:
      s
      |> String.replace("&", "&amp;")
      |> String.replace("<", "&lt;")
      |> String.replace(">", "&gt;")

  defp xml_unescape(s) do
    s
    |> String.replace("&lt;", "<")
    |> String.replace("&gt;", ">")
    |> String.replace("&quot;", "\"")
    |> String.replace("&apos;", "'")
    |> String.replace("&amp;", "&")
  end

  # -- transport dispatch ---------------------------------------------------

  # All HTTP goes through the shared PopcornDemo.Transport behaviour (Httpc
  # on host, Fetch in a browser VM). Caller headers (content-type pins,
  # auth) are sent verbatim by the transport.
  #
  # BK-15 Fetch port (2026-10-21): the former hardcoded Httpc dispatch
  # crashed in the wasm BEAM (:httpc unavailable) and surfaced as a loud
  # queue=SKIP(wasm-transport...). Dispatch is now the kv=OK precedent:
  # Transport.Fetch when the Popcorn JS bridge is up, Transport.Httpc on
  # the host. Req maps are normalized (default :headers) for Fetch.
  defp request(req) do
    req = Map.put_new(req, :headers, [])

    if browser?() do
      PopcornDemo.Transport.Fetch.request(req)
    else
      PopcornDemo.Transport.Httpc.request(req)
    end
  end

  defp browser? do
    Code.ensure_loaded?(Popcorn.JS) and function_exported?(Popcorn.JS, :available?, 0) and
      Popcorn.JS.available?()
  end

  # -- shared helpers -------------------------------------------------------

  defp auth_headers(token),
    do: [
      {"authorization", "Bearer " <> token},
      {"x-ms-version", @ms_version}
    ]

  defp payload, do: "popcorn-demo queue receipt <&esc> " <> stamp() <> " lane=ERRC-R4"

  defp stamp do
    {:ok, dt} = DateTime.now("Etc/UTC")
    DateTime.to_iso8601(dt)
  end

  defp slice(b) when is_binary(b), do: String.slice(b, 0, 120)
  defp slice(other), do: inspect(other, limit: 10)

  defp fmt(r) when is_binary(r), do: r
  defp fmt(other), do: inspect(other, limit: 10)

  @doc """
  Peek N messages WITHOUT dequeueing: GET /messages?visibilitytimeout=0&numofmessages=N
  (vt=0 keeps the message visible — the receipt minted expires immediately),
  then asserts the same messages are STILL visible on a second identical GET.
  Uses a fresh per-call queue so leftover messages can't pollute the FIFO
  assert. Returns `{:ok, "peek=OK(<queue>:<n>-messages-still-visible)"}` or
  `{:error, "queue=FAIL(<step>:<reason>)"}`.
  """
  def peek(n \\ 2) when is_integer(n) and n > 0 do
    with_queue("peek", fn token, queue ->
      bodies = for i <- 1..n, do: "peek-msg-#{i}-#{stamp()}"
      texts = bodies

      with :ok <- put_all(token, queue, bodies),
           {:ok, list1} <- get_visible(token, queue, n, 0, "peek"),
           {:ok, list2} <- get_visible(token, queue, n, 0, "peek-recheck") do
        got1 = Enum.map(list1, & &1.text)
        got2 = Enum.map(list2, & &1.text)

        cond do
          got1 != texts ->
            {:error, {"peek", "fifo-mismatch(wanted-#{inspect(texts)},got-#{inspect(got1)})"}}

          got2 != texts ->
            {:error, {"peek-recheck", "peeked-messages-not-still-visible(got-#{inspect(got2)})"}}

          true ->
            {:ok, "peek=OK(#{queue}:#{n}-messages-still-visible)"}
        end
      end
    end)
  end

  @doc """
  Update Message: PUT /messages/{id}?popreceipt=...&visibilitytimeout=0 with
  a NEW body (vt=0 so the replaced body is immediately re-visible — a vt>0
  update correctly keeps it invisible for that window). Asserts 200, a fresh PopReceipt comes back and differs from the
  received one, and the next receive returns the NEW body under the NEW
  receipt. Returns `{:ok, "update=OK(<queue>:receipt-rotated+body-replaced)"}`
  or `{:error, "queue=FAIL(<step>:<reason>)"}`.
  """
  def update_message do
    with_queue("update-message", fn token, queue ->
      body1 = "update-before-#{stamp()}"
      body2 = "update-after-#{stamp()}"

      with {:ok, %{id: id, popreceipt: pr}} <- put_then_receive(token, queue, body1, 30),
           {:ok, new_pr} <- update_req(token, queue, id, pr, body2),
           false <- new_pr == pr,
           {:ok, [%{text: got, popreceipt: got_pr}]} <-
             get_visible(token, queue, 1, 30, "update-receive") do
        cond do
          got != body2 ->
            {:error, {"update-receive", "body-not-replaced(got-#{slice(got)})"}}

          got_pr == pr or got_pr == new_pr ->
            {:error, {"update-receive", "stale-receipt-accepted"}}

          true ->
            {:ok, "update=OK(#{queue}:receipt-rotated+body-replaced)"}
        end
      else
        true -> {:error, {"update-message", "popreceipt-not-rotated(same-receipt-returned)"}}
        {:error, _} = err -> err
      end
    end)
  end

  @doc """
  Receive two messages and FIFO-assert their order, then DELETE each by its
  own popreceipt — including the SECOND message — proving receive-delete
  works across a batch. Returns
  `{:ok, "recv-del=OK(<queue>:2-fifo-deleted)"}` or
  `{:error, "queue=FAIL(<step>:<reason>)"}`.
  """
  def receive_delete do
    with_queue("receive-delete", fn token, queue ->
      m1 = "recv-del-first-#{stamp()}"
      m2 = "recv-del-second-#{stamp()}"

      with :ok <- put_all(token, queue, [m1, m2]),
           {:ok, [_first, _second] = batch} <- get_visible(token, queue, 2, 30, "receive"),
           results <- Enum.map(batch, fn %{id: id, popreceipt: pr} ->
             delete_message(id, pr, token, queue)
           end) do
        texts = Enum.map(batch, & &1.text)

        cond do
          texts != [m1, m2] ->
            {:error, {"fifo", "wanted-#{inspect([m1, m2])}-got-#{inspect(texts)}"}}

          results != [:ok, :ok] ->
            {:error, {"delete", "results-#{inspect(results)}"}}

          true ->
            {:ok, "recv-del=OK(#{queue}:2-fifo-deleted)"}
        end
      end
    end)
  end

  # -- enterprise-op helpers ------------------------------------------------

  # RUN-UNIQUE queue mint — every walk gets its own queue so parallel
  # walkers never dequeue each other's messages (see moduledoc law).
  defp with_queue(step, fun) do
    queue = "popcorn-q-#{System.system_time(:millisecond)}-#{:rand.uniform(999_999)}"

    case request(%{method: "GET", url: @base <> "/healthz", body: nil}) do
      {:ok, %{status: 200}} ->
        with {:ok, token} <- token(),
             :ok <- ensure_queue(token, queue) do
          fun.(token, queue)
        else
          {:skip, reason} -> {:skip, "queue=SKIP(#{reason})"}
          {:error, {s, reason}} when is_binary(s) -> {:error, "queue=FAIL(#{s}:#{fmt(reason)})"}
          {:error, reason} -> {:error, "queue=FAIL(#{step}:#{fmt(reason)})"}
        end

      {:ok, %{status: st}} ->
        {:error, "queue=FAIL(health:http-#{st})"}

      {:error, _} ->
        {:skip, "queue=SKIP(substrate-down)"}
    end
  end

  defp put_all(token, queue, bodies) do
    Enum.reduce_while(bodies, :ok, fn body, :ok ->
      case put_message(token, queue, body) do
        {:ok, _id} -> {:cont, :ok}
        {:error, _} = err -> {:halt, err}
      end
    end)
  end

  defp put_message(token, queue, text) do
    req = %{
      method: "POST",
      url: @base <> "/#{@account}/#{queue}/messages",
      headers: auth_headers(token) ++ [{"content-type", "application/xml"}],
      body: "<QueueMessage><MessageText>#{xml_escape(text)}</MessageText></QueueMessage>"
    }

    with {:ok, %{status: 201, body: body}} <- step_req("put-message", req, 201) do
      xml_field(body, "MessageId", "put-message")
    end
  end

  defp put_then_receive(token, queue, text, vt) do
    with {:ok, _id} <- put_message(token, queue, text),
         {:ok, [msg]} <- get_visible(token, queue, 1, vt, "receive") do
      {:ok, msg}
    end
  end

  defp update_req(token, queue, id, pr, new_text) do
    url =
      @base <> "/#{@account}/#{queue}/messages/#{id}" <>
        "?popreceipt=" <> URI.encode_www_form(pr) <> "&visibilitytimeout=0"

    req = %{
      method: "PUT",
      url: url,
      headers: auth_headers(token) ++ [{"content-type", "application/xml"}],
      body: "<QueueMessage><MessageText>#{xml_escape(new_text)}</MessageText></QueueMessage>"
    }

    with {:ok, %{status: 200, body: body}} <- step_req("update-message", req, 200) do
      xml_field(body, "PopReceipt", "update-message")
    end
  end

  defp get_visible(token, queue, n, vt, step) do
    url =
      @base <> "/#{@account}/#{queue}/messages" <>
        "?visibilitytimeout=#{vt}&numofmessages=#{n}"

    req = %{method: "GET", url: url, headers: auth_headers(token), body: nil}

    with {:ok, %{status: 200, body: body}} <- step_req(step, req, 200) do
      parse_messages(body, step)
    end
  end

  # Splits a QueueMessagesList into %{id, text, popreceipt} maps (order
  # preserved — FIFO assert depends on it).
  defp parse_messages(body, step) do
    case Regex.scan(~r/<QueueMessage>(.*?)<\/QueueMessage>/s, body) do
      [] ->
        {:ok, []}

      matches ->
        msgs =
          for [_full, seg] <- matches,
              {:ok, id} <- [xml_field(seg, "MessageId", step)],
              {:ok, pr} <- [xml_field(seg, "PopReceipt", step)],
              text = xml_unescape(elem_or_raw(seg, "MessageText")) do
            %{id: id, popreceipt: pr, text: text}
          end

        if length(msgs) == length(matches) do
          {:ok, msgs}
        else
          {:error, {step, "malformed-QueueMessage-segment"}}
        end
    end
  end

  defp elem_or_raw(seg, tag) do
    case Regex.run(~r/<#{tag}>(.*?)<\/#{tag}>/s, seg) do
      [_, val] -> val
      nil -> ""
    end
  end

  defp ensure_queue(token, queue) do
    req = %{
      method: "PUT",
      url: @base <> "/#{@account}/#{queue}?restype=queue",
      headers: auth_headers(token),
      body: ""
    }

    case request(req) do
      {:ok, %{status: 201}} -> :ok
      {:ok, %{status: 409}} -> :ok
      {:ok, %{status: st, body: body}} -> {:error, {"create-queue", "http-#{st}:#{slice(body)}"}}
      {:error, reason} -> {:error, {"create-queue", fmt(reason)}}
    end
  end

  defp delete_message(id, pr, token, queue) do
    url =
      @base <> "/#{@account}/#{queue}/messages/#{id}?popreceipt=" <> URI.encode_www_form(pr)

    case request(%{method: "DELETE", url: url, headers: auth_headers(token), body: nil}) do
      {:ok, %{status: 204}} -> :ok
      {:ok, %{status: st, body: body}} -> {:error, "http-#{st}:#{slice(body)}"}
      {:error, reason} -> {:error, fmt(reason)}
    end
  end
end
