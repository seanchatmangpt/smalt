defmodule Smalt.DataPlane.BlobStorage do
  @moduledoc """
  Pure Elixir Azure Immutable Blob Storage REST engine (`Microsoft.Storage/storageAccounts`).
  Supports container creation, block blob PUT/GET/DELETE, ETag generation, If-Match
  preconditions, legal hold and immutability policy (WORM), and XML blob listing.
  """
  alias Smalt.DataPlane.ConditionalHeaders
  alias Smalt.Store

  @policy_table :smalt_blob_policy

  def create_container(account, container, opts \\ %{}) do
    with :ok <- check_container_name(container) do
      do_create_container(account, container, opts)
    end
  end

  # Azure parity (cycle-25, Put Container): container names are 3-63 bytes,
  # lowercase letters/digits/dashes, starting and ending alphanumeric. Real
  # Azure answers 400 InvalidResourceName; smalt accepted anything and the
  # duplicate-create silently replaced records (WORM clock reset).
  @container_name_re ~r/^[a-z0-9][a-z0-9-]{1,61}[a-z0-9]$/

  defp check_container_name(name) when is_binary(name) do
    if name == "" or byte_size(name) > 63 or not Regex.match?(@container_name_re, name) do
      {:error, 400, "InvalidResourceName",
       "The specified container name is invalid (3-63 bytes, lowercase letters, digits and dashes, starting and ending alphanumeric)."}
    else
      :ok
    end
  end

  defp check_container_name(_),
    do: {:error, 400, "InvalidResourceName", "The specified container name is invalid."}

  # Azure parity (cycle-25): Put Container on an existing container is 409
  # ContainerAlreadyExists — previously any duplicate create silently
  # REPLACED the record (created_at/WORM clock reset, flag flip-flop).
  defp do_create_container(account, container, opts) do
    key = "#{account}/#{container}"

    with :error <- Smalt.Store.get(:smalt_blob_containers, key) do
      created_at = Map.get(opts, "created_at_ms") || System.os_time(:millisecond)

    record = %{
      "account" => account,
      "container" => container,
      "immutable" => Map.get(opts, "immutable", true),
      "retention_days" => Map.get(opts, "retention_days", 1095),
      "created_at" => created_at,
      "created" => DateTime.from_unix!(created_at, :millisecond) |> DateTime.to_iso8601()
    }
    Store.put(:smalt_blob_containers, key, record)
      {:ok, record}
    else
      {:ok, _existing} ->
        {:error, 409, "ContainerAlreadyExists",
         "The specified container already exists."}
    end
  end

  @doc """
  Validate List Blobs `maxresults` (Azure grammar: 1-5000; non-positive or
  non-integer values are 400 InvalidQueryParameter, never silently coerced
  to the default page size).
  """
  def check_maxresults(nil), do: :ok

  def check_maxresults(raw) when is_binary(raw) do
    case Integer.parse(raw) do
      {n, ""} when n > 0 -> :ok
      _ -> maxresults_error()
    end
  end

  def check_maxresults(n) when is_integer(n) and n > 0, do: :ok
  def check_maxresults(_), do: maxresults_error()

  defp maxresults_error,
    do: {:error, 400, "InvalidQueryParameter",
         "Value for maxresults is invalid (must be a positive integer)."}

  @doc """
  Time-aware policy evaluation for a container. `:now_ms` is injected
  (defaults to `System.os_time(:millisecond)`).

  Returns `{:ok, %{"locked" => bool, "legal_hold" => bool, "expired" => bool,
  "expires_at" => ms | nil}}` or `{:error, :container_not_found}`. When
  `now > created_at + retention_days` the container's immutability policy has
  expired and the container unlocks (overwrite/delete permitted). Legal holds
  NEVER auto-expire. Legacy containers without `created_at` are conservatively
  reported as not-yet-expired.
  """
  def policy_state(account, container, opts \\ []) do
    now = now_ms(opts)
    container_key = container_key(account, container)

    with {:ok, meta} <- Store.get(:smalt_blob_containers, container_key) do
      policy = fetch_policy(meta)
      expires_at = retention_end_ms(meta)

      {:ok,
       %{
         "locked" => locked_policy?(policy),
         "legal_hold" => legal_hold?(policy),
         "expired" => expired?(meta, now),
         "expires_at" => expires_at
       }}
    else
      :error -> {:error, :container_not_found}
    end
  end

  # Documented C4 fence: a single PUT carries at most 1 MiB of blob content.
  # Real Azure enforces a per-request size cap with 413 RequestBodyTooLarge;
  # smalt's fence is 1,048,576 bytes (the 8,000,000-byte egress_router
  # read_body cap stays as the transport-level backstop).
  @max_put_bytes 1_048_576

  @doc """
  PUT blob. Hardened: If-Match precondition (412 on mismatch), WORM refusal
  extended to legal hold and locked immutability policy (409 `ContainerLocked`),
  and a 1 MiB per-PUT content cap (`{:error, :too_large, msg}` — the router maps
  it to 413 `RequestBodyTooLarge`).
  """
  def put_blob(account, container, blob_name, content, headers \\ %{}, opts \\ []) do
    container_key = "#{account}/#{container}"
    blob_key = "#{account}/#{container}/#{blob_name}"
    now = now_ms(opts)

    with :ok <- check_blob_name(blob_name),
         {:ok, container_meta} <- Store.get(:smalt_blob_containers, container_key),
         :ok <- check_content(content),
         :ok <- check_put_size(content),
         :ok <- check_metadata_names(headers) do
      case Store.get(:smalt_blobs, blob_key) do
        {:ok, existing} ->
          cond do
            worm_blocked?(container_meta, "overwrite", now) ->
              {:error, :worm_locked, worm_message(container_meta, now)}

            mismatched_if_match?(headers, existing["etag"]) ->
              {:error, :precondition_failed, precondition_message()}

            # Azure parity (cycle-21): If-None-Match: * refuses overwrite of
            # an existing blob (412) — previously silently ignored, so a
            # conditional-create raced through as an unconditional overwrite.
            if_none_match_star?(headers) ->
              {:error, :precondition_failed, precondition_message()}

            true ->
              store_blob(account, container, blob_name, content, headers)
          end

        :error ->
          cond do
            # Azure parity (cycle-21): If-Match on a NON-EXISTENT blob is
            # 412 (a precondition on a resource that does not exist fails).
            # Previously the create path skipped all preconditions, so
            # If-Match: * created unconditionally.
            ConditionalHeaders.header(headers, "if-match") != nil ->
              {:error, :precondition_failed, precondition_message()}

            true ->
              store_blob(account, container, blob_name, content, headers)
          end
      end
    else
      :error ->
        {:error, :container_not_found}

      {:error, :too_large, msg} ->
        {:error, :too_large, msg}

      {:error, 400, _code, _msg} = invalid ->
        invalid
    end
  end

  # Azure parity (Put Blob): real Azure rejects control characters in blob
  # names at PUT with 400 InvalidResourceName, and names are bounded
  # (1,024 characters per the naming reference). smalt accepted any bytes
  # and only sanitized at listing emission (cycle-11).
  @max_blob_name_bytes 1_024

  defp check_blob_name(name) when is_binary(name) do
    cond do
      name == "" or byte_size(name) > @max_blob_name_bytes ->
        {:error, 400, "InvalidResourceName",
         "The specified blob name is invalid (must be 1 to 1024 bytes)."}

      String.match?(name, ~r/[\x00-\x1F\x7F]/) ->
        {:error, 400, "InvalidResourceName",
         "The specified blob name is invalid (control characters are not permitted)."}

      true ->
        :ok
    end
  end

  defp check_blob_name(_),
    do: {:error, 400, "InvalidResourceName", "The specified blob name is invalid."}

  # Azure parity (Put Blob / Put Metadata): user metadata names must be valid
  # C# identifiers; violations answer 400 InvalidMetadata, never a stored row.
  @meta_name_re ~r/^[A-Za-z_][A-Za-z0-9_]*$/

  defp check_metadata_names(headers) when is_map(headers) do
    bad =
      Enum.find(headers, fn {k, v} ->
        case k do
          "x-ms-meta-" <> name ->
            not Regex.match?(@meta_name_re, name) or
              not (is_binary(v) and not Regex.match?(~r/[\x00-\x1F\x7F]/, v))

          _ -> false
        end
      end)

    case bad do
      nil ->
        :ok

      {k, _} ->
        {:error, 400, "InvalidMetadata",
         "Invalid metadata name (must be a valid C# identifier) or value (must be a control-character-free binary): #{k}."}
    end
  end

  defp check_metadata_names(_), do: :ok

  # Azure parity: container existence (404) outranks request size (413).
  defp check_put_size(content) do
    if byte_size(content) > @max_put_bytes do
      {:error, :too_large, too_large_message()}
    else
      :ok
    end
  end

  defp too_large_message,
    do: "Blob exceeds the 1,048,576-byte per-PUT limit (RequestBodyTooLarge)."

  @doc """
  DELETE blob. Returns:

    * `{:ok, 202, headers}` on success (`x-ms-request-id` header)
    * `{:error, 404, "BlobNotFound", msg}`
    * `{:error, 409, "ContainerLocked", msg}` when legal hold or locked
      immutability policy blocks the delete (message names the blocker)
    * `{:error, 412, "PreconditionFailed", msg}` on If-Match mismatch
  """
  def delete_blob(account, container, blob_name, headers \\ %{}, opts \\ []) do
    container_key = "#{account}/#{container}"
    blob_key = "#{account}/#{container}/#{blob_name}"
    now = now_ms(opts)

    with {:ok, container_meta} <- Store.get(:smalt_blob_containers, container_key),
         {:ok, existing} <- blob_or_404(blob_key),
         :ok <- check_worm(container_meta, now),
         :ok <- check_if_match(headers, existing["etag"]),
         :ok <- check_if_none_match(headers) do
      Store.delete(:smalt_blobs, blob_key)

      {:ok, 202,
       %{"x-ms-request-id" => request_id(), "x-ms-version" => "2021-12-02"}, nil}
    else
      :error -> {:error, 404, "ContainerNotFound", "Container not found."}
      {:error, :not_found} -> {:error, 404, "BlobNotFound", "The specified blob does not exist."}
      {:error, {:worm, reason}} -> {:error, 409, "ContainerLocked", worm_message_reason(reason)}
      {:error, {:precondition}} -> {:error, 412, "PreconditionFailed", precondition_message()}
      {:error, {:precondition, _}} -> {:error, 412, "PreconditionFailed", precondition_message()}
    end
  end

  @doc """
  PUT ?comp=immutabilityPolicy — sets or locks the container immutability policy.
  Locking requires `If-Match: "*"`. After lock, changing the policy → 409
  `ContainerLocked`. Stored in `:smalt_blob_policy`.
  """
  def set_immutability_policy(account, container, policy, headers \\ %{}, opts \\ []) do
    container_key = container_key(account, container)
    now = now_ms(opts)
    ensure_policy_table()

    with {:ok, container_meta} <- fetch_container_meta(container_key),
         {:ok, existing} <- policy_or_empty(container_key),
         :ok <- refuse_if_locked(existing, container_meta, now),
         :ok <- require_star_if_match_for_lock(headers, policy) do
      locked = Map.get(policy, "locked", false)
      period_days = Map.get(policy, "period_days", Map.get(existing, "period_days", 0))

      with :ok <- validate_period_days(period_days) do
        # nil-coalescing: an explicit "until" => nil in the policy map must fall
        # through to the computed default, never propagate nil into a response
        # header (put_resp_header on nil is a FunctionClauseError 500).
        until = Map.get(policy, "until") || default_until(period_days, now)

        new_policy = %{
          "immutability_policy" => %{
            "locked" => locked,
            "until" => until,
            "period_days" => period_days
          },
          "legal_hold" => Map.get(existing, "legal_hold", false)
        }

        Store.put(@policy_table, container_key, new_policy)

        base_headers = %{
          "x-ms-request-id" => request_id(),
          "x-ms-version" => "2021-12-02",
          "x-ms-has-immutability-policy" => "true"
        }

        # nil-safe projection: immutability-policy-until is only emitted when a
        # real expiry exists (period_days > 0 or a wire expiresOn was supplied).
        headers =
          if is_binary(until),
            do: Map.put(base_headers, "immutability-policy-until", until),
            else: base_headers

        {:ok, 200, headers,
         %{"locked" => locked, "until" => until, "period_days" => period_days}}
      else
        {:error, 400, code, msg} -> {:error, 400, code, msg}
      end
    else
      {:error, :locked} -> {:error, 409, "ContainerLocked", locked_policy_message()}
      {:error, :if_match_required} -> {:error, 412, "PreconditionFailed",
        "Locking an immutability policy requires If-Match: \"*\"."}
      {:error, 400, code, msg} -> {:error, 400, code, msg}
      {:error, 404, code, msg} -> {:error, 404, code, msg}
    end
  end

  @doc """
  Validate blob PUT content type (engine-level total: the wire always hands
  put_blob a binary body, but the engine answers 400, never a raise, for a
  non-binary content argument — a 500-class crash fenced per cycle-14).
  """
  @spec check_content(binary) :: :ok | {:error, 400, String.t(), String.t()}
  def check_content(content) when is_binary(content), do: :ok
  def check_content(_),
    do: {:error, 400, "InvalidInput", "Blob content must be a binary."}

  # Azure grammar: immutabilityPeriodSinceCreationInDays is an integer in
  # [0, 146000]; anything else is 400 InvalidXmlDocument (previously ANY value
  # was stored verbatim — negative days, binaries, 10^12 producing an
  # "until" in the year 2737909033).
  @max_retention_days 146_000

  defp validate_period_days(days) when is_integer(days) and days >= 0 and days <= @max_retention_days,
    do: :ok

  defp validate_period_days(_),
    do:
      {:error, 400, "InvalidXmlDocument",
       "immutabilityPeriodSinceCreationInDays must be an integer between 0 and 146000."}

  @doc """
  PUT/DELETE ?comp=legalhold — sets (`flag: true`) or clears (`flag: false`)
  the container legal hold. Stored in `:smalt_blob_policy`.
  """
  def set_legal_hold(account, container, flag, _headers \\ %{})

  def set_legal_hold(account, container, flag, _headers) when is_boolean(flag) do
    container_key = container_key(account, container)
    ensure_policy_table()

    with {:ok, _} <- Store.get(:smalt_blob_containers, container_key),
         {:ok, existing} <- policy_or_empty(container_key) do
      policy =
        existing
        |> Map.put("legal_hold", flag)
        |> put_in_worm_defaults()

      Store.put(@policy_table, container_key, policy)

      {:ok, 200,
       %{
         "x-ms-request-id" => request_id(),
         "x-ms-version" => "2021-12-02",
         "x-ms-has-legal-hold" => to_string(flag)
       },
       %{"has_legal_hold" => flag}}
    else
      # Store.get/2 returns a bare :error on a missing row — without this
      # clause the with raises WithClauseError (a 500), never a typed 404.
      :error -> {:error, 404, "ContainerNotFound", "Container not found."}
      {:error, :container_not_found} -> {:error, 404, "ContainerNotFound", "Container not found."}
    end
  end

  # Azure parity (cycle-19): a non-boolean x-ms-legal-hold flag is a client
  # error — 400 InvalidHeaderValue, never a FunctionClauseError 500.
  def set_legal_hold(_account, _container, flag, _headers) do
    {:error, 400, "InvalidHeaderValue",
     "The value for x-ms-legal-hold must be true or false (got: #{inspect(flag)})."}
  end

  @doc "Returns the container's policy record or nil."
  def get_policy(account, container) do
    ensure_policy_table()
    case Store.get(@policy_table, "#{account}/#{container}") do
      {:ok, policy} -> policy
      :error -> nil
    end
  end

  def get_blob(account, container, blob_name) do
    Store.get(:smalt_blobs, "#{account}/#{container}/#{blob_name}")
  end

  @doc """
  Content-free, wire-safe metadata projection of a stored blob: name, etag,
  content_length, last_modified, x-ms headers. Total over binary content —
  the raw `content` field is never included, so JSON encoding cannot raise.
  """
  def blob_metadata(blob) do
    blob
    |> Map.take(["name", "etag", "content_length", "last_modified", "headers"])
    |> Map.update("headers", %{}, &(&1 || %{}))
  end

  @doc """
  Ranged GET engine: given the raw `Range` header list, returns

    * `{:ok, blob, nil}` — no usable range: serve full 200
    * `{:ok, blob, {first, last}}` — 0-based inclusive slice, 206 + Content-Range
    * `{:error, :range_not_satisfiable, total}` — 416 (start past EOF, suffix length 0)
    * `:error` — blob missing (404)

  Accepts `bytes=a-b`, `bytes=a-`, `bytes=-suffix`. A malformed range is
  ignored (RFC 9110: a syntactically invalid Range header MUST be ignored),
  serving the full body. Multi-range specs (`bytes=0-1,5-6`) are treated as
  malformed and ignored the same way (single-part 206 only; a first-spec-only
  slice is NOT served).
  """
  def get_blob_range(account, container, blob_name, range_header \\ [])

  def get_blob_range(account, container, blob_name, range_header) when is_list(range_header) do
    case Store.get(:smalt_blobs, "#{account}/#{container}/#{blob_name}") do
      {:ok, blob} ->
        total = byte_size(blob["content"])

        case parse_range(List.first(range_header), total) do
          {:ok, nil} ->
            {:ok, blob, nil}

          {:ok, {first, last}} ->
            {:ok, blob, {first, last}}

          :unsatisfiable ->
            {:error, :range_not_satisfiable, total}
        end

      :error ->
        :error
    end
  end

  def get_blob_range(_account, _container, _blob_name, _other), do: :error

  @doc """
  Conditional read engine (Azure parity, cycle-30 Get Blob): evaluates
  If-Match then If-None-Match per RFC 7232 precedence.

    * `{:ok, blob}` — preconditions pass (or absent): serve the read
    * `{:not_modified, etag}` — If-None-Match matched (incl. `*`): 304
    * `{:error, 412, "PreconditionFailed", msg}` — If-Match failed
    * `:error` — blob missing (404)
  """
  def get_blob_conditional(account, container, blob_name, headers) when is_map(headers) do
    case Store.get(:smalt_blobs, "#{account}/#{container}/#{blob_name}") do
      {:ok, blob} ->
        etag = blob["etag"]
        if_match = ConditionalHeaders.header(headers, "if-match")
        if_none_match = ConditionalHeaders.header(headers, "if-none-match")

        cond do
          if_match != nil and not conditional_etag_match?(if_match, etag) ->
            {:error, 412, "PreconditionFailed",
             "The condition specified using HTTP conditional header(s) is not met."}

          if_none_match != nil and conditional_etag_match?(if_none_match, etag) ->
            {:not_modified, etag}

          true ->
            {:ok, blob}
        end

      :error ->
        :error
    end
  end

  def get_blob_conditional(_account, _container, _blob_name, _headers), do: :error

  defp conditional_etag_match?("*", _etag), do: true

  defp conditional_etag_match?(value, etag) when is_binary(value) do
    String.split(value, ",") |> Enum.map(&String.trim/1) |> Enum.member?(etag)
  end

  defp conditional_etag_match?(_, _), do: false

  defp parse_range(nil, _total), do: {:ok, nil}

  defp parse_range(header, total) when is_binary(header) do
    case Regex.run(~r/^bytes=(\d*)-(\d*)$/, String.trim(header)) do
      [_, first, last] -> parse_range_spec(first, last, total)
      _ -> {:ok, nil}
    end
  end

  defp parse_range_spec("", "", _total), do: {:ok, nil}

  defp parse_range_spec(first, "", total) do
    first = String.to_integer(first)
    if first >= total, do: :unsatisfiable, else: {:ok, {first, total - 1}}
  end

  defp parse_range_spec("", last, total) do
    last = String.to_integer(last)
    if last <= 0, do: :unsatisfiable, else: {:ok, {max(total - last, 0), total - 1}}
  end

  defp parse_range_spec(first, last, total) do
    first = String.to_integer(first)
    last = String.to_integer(last)

    cond do
      first >= total -> :unsatisfiable
      last < first -> {:ok, nil}
      true -> {:ok, {first, min(last, total - 1)}}
    end
  end

  @max_page 50

  @doc """
  List blobs for `account`/`container` as Azure EnumerationResults XML.
  Options (binary-keyed, matching the query string): `"marker"`,
  `"maxresults"` (default 50, capped as in BlobService).

  Blobs are scanned by their ACTUAL stored key prefix
  `"\#{account}/\#{container}/"` via `Store.list_prefix/2` — same-named blobs
  in other containers of the account can never bleed in. Returns
  `{xml, next_marker}`; marker = last returned blob name, `NextMarker`
  present only when more results remain.
  """
  def list_blobs_xml(account, container, opts \\ %{}) do
    with :ok <- check_maxresults(Map.get(opts, "maxresults")) do
      do_list_blobs_xml(account, container, opts)
    end
  end

  defp do_list_blobs_xml(account, container, opts) do
    key_prefix = "#{account}/#{container}/"
    marker = Map.get(opts, "marker") || ""
    prefix = Map.get(opts, "prefix") || ""
    delimiter = Map.get(opts, "delimiter") || ""
    include_meta = include_metadata?(Map.get(opts, "include"))
    max_results = normalize_max(Map.get(opts, "maxresults"))

    if delimiter == "" and prefix == "" and marker == "" do
      # Fast path (perf contract fence): sorted key scan, values fetched only
      # for the page — the delimiter/prefix/marker composition below
      # materializes element tuples for the full key set.
      keys = :smalt_blobs |> Store.prefix_keys(key_prefix) |> Enum.sort()
      page_keys = Enum.take(keys, max_results)

      next_marker = if length(keys) > max_results, do: String.replace_prefix(List.last(page_keys), key_prefix, ""), else: nil

      xml =
        render_blobs(page_keys, next_marker, account, container, marker, max_results, "", key_prefix, include_meta)
      {xml, next_marker}
    else
      # Delimiter/prefix/marker composition (Azure parity, cycle-27):
      # names containing the delimiter (after the requested prefix) roll
      # into a single synthetic <BlobPrefix> per directory; Blob/BlobPrefix
      # interleave lexicographically; prefixes count toward maxresults;
      # NextMarker continues from the last element name.
      elements =
        :smalt_blobs
        |> Store.prefix_keys(key_prefix)
        |> Enum.map(fn key ->
          name = binary_part(key, byte_size(key_prefix), byte_size(key) - byte_size(key_prefix))

          rel =
            if prefix == "" or not String.starts_with?(name, prefix),
              do: nil,
              else: binary_part(name, byte_size(prefix), byte_size(name) - byte_size(prefix))

          cond do
            prefix != "" and rel == nil ->
              :skip

            delimiter != "" and String.contains?(name, delimiter) and
                (prefix == "" or String.contains?(rel, delimiter)) ->
              {:bp, prefix <> hd(String.split(rel || name, delimiter)) <> delimiter, nil}

            true ->
              {:blob, name, key}
          end
        end)
        |> Enum.reject(&(&1 == :skip))
        |> Enum.uniq()
        |> Enum.filter(fn {_t, n, _k} -> marker == "" or n > marker end)
        |> Enum.sort_by(fn {_t, n, _k} -> n end)

      page = Enum.take(elements, max_results)

      next_marker = if length(elements) > max_results, do: elem(List.last(page), 1), else: nil

      delimiter_xml =
        if delimiter == "", do: "", else: "\n  <Delimiter>#{xml_escape(delimiter)}</Delimiter>"

      blob_items =
        Enum.map_join(page, "\n", fn
          {:blob, name, key} ->
            render_blob(name, key, key_prefix, include_meta)

          {:bp, bp_name, _} ->
            "\n  <BlobPrefix>\n    <Name>#{xml_escape(bp_name)}</Name>\n  </BlobPrefix>\n "
        end)

      xml = """
      <?xml version="1.0" encoding="utf-8"?>
      <EnumerationResults ServiceEndpoint="http://127.0.0.1:8443/#{xml_escape(account)}" ContainerName="#{xml_escape(container)}">
        <Prefix>#{xml_escape(if(prefix == "", do: key_prefix, else: prefix))}</Prefix>#{delimiter_xml}
        <Marker>#{xml_escape(marker)}</Marker>
        <MaxResults>#{max_results}</MaxResults>
        <Blobs>
      #{blob_items}
        </Blobs>
      #{next_marker_xml(next_marker)}
      </EnumerationResults>
      """

      {xml, next_marker}
    end
  end

  defp render_blobs(page_keys, next_marker, account, container, marker, max_results, delimiter_xml, key_prefix, include_meta) do
    items =
      Enum.map_join(page_keys, "\n", fn key ->
        render_blob(String.replace_prefix(key, key_prefix, ""), key, key_prefix, include_meta)
      end)

    """
    <?xml version="1.0" encoding="utf-8"?>
    <EnumerationResults ServiceEndpoint="http://127.0.0.1:8443/#{xml_escape(account)}" ContainerName="#{xml_escape(container)}">
      <Prefix>#{xml_escape(key_prefix)}</Prefix>#{delimiter_xml}
      <Marker>#{xml_escape(marker)}</Marker>
      <MaxResults>#{max_results}</MaxResults>
      <Blobs>
    #{items}
      </Blobs>
    #{next_marker_xml(next_marker)}
    </EnumerationResults>
    """
  end
  defp render_blob(name, key, key_prefix, include_meta \\ false) do
    case Store.get(:smalt_blobs, key) do
      {:ok, b} ->
        """
        <Blob>
          <Name>#{xml_escape(b["name"] || name)}</Name>#{blob_metadata_xml(b, include_meta)}<Properties>
            <Content-Length>#{b["content_length"]}</Content-Length>
            <Etag>#{xml_escape(b["etag"])}</Etag>
            <Last-Modified>#{xml_escape(b["last_modified"])}</Last-Modified>
          </Properties>
        </Blob>
        """

      _ ->
        ""
    end
  end

  # Azure parity (cycle-34, List Blobs include=metadata): user metadata rides
  # x-ms-meta-* on the stored headers; when the request includes metadata the
  # listing emits a <Metadata> element per blob. Values go through the same
  # xml_escape (hostile & < > " entity-escaped; control chars are refused at
  # PUT by the InvalidMetadata fence). Only the exact "metadata" include
  # token enables it; unknown include values (snapshots/versions/tags) are
  # typed UNSUPPORTED(feature-ban) and never emit decoration.
  # Azure parity (lens2 cycle-35): `include` is a COMMA-SEPARATED token list;
  # a token must match exactly. A plain substring match wrongly enables
  # metadata emission for hostile tokens like `metadatabase` or `metadatax`.
  defp include_metadata?(include) when is_binary(include) do
    include
    |> String.split(",")
    |> Enum.map(&String.trim/1)
    |> Enum.member?("metadata")
  end

  defp include_metadata?(_), do: false

  defp blob_metadata_xml(_b, false), do: ""

  defp blob_metadata_xml(b, true) do
    meta =
      b["headers"]
      |> Kernel.||(%{})
      |> Enum.filter(fn {k, _} -> is_binary(k) and String.starts_with?(k, "x-ms-meta-") end)
      |> Enum.map_join("\n", fn {"x-ms-meta-" <> name, value} ->
        "<#{xml_escape(name)}>#{xml_escape(value)}</#{xml_escape(name)}>"
      end)

    if meta == "", do: "", else: "\n  <Metadata>\n#{meta}\n  </Metadata>"
  end

  @doc """
  XML-escape a value for safe interpolation into element text or attribute
  values (real Blob service escapes all listing output; unescaped blob or
  container names containing `<`, `>`, `&`, `"` produce malformed
  EnumerationResults XML). Non-binary falls back to the empty string so a
  nil name can never raise.
  """
  @spec xml_escape(term) :: String.t()
  def xml_escape(nil), do: ""

  def xml_escape(value) when is_binary(value) do
    # XML 1.0 forbids most C0 control bytes in content (only \t \n \r are
    # legal). Hostile stored names / marker or prefix query params must never
    # produce ill-formed enumeration XML — illegal control bytes are dropped;
    # & < > " are entity-escaped as before.
    value
    |> String.replace("&", "&amp;")
    |> String.replace("<", "&lt;")
    |> String.replace(">", "&gt;")
    |> String.replace("\"", "&quot;")
    |> String.replace(~r/[\x00-\x08\x0B\x0C\x0E-\x1F\x7F]/, "")
    # Astral-plane codepoints (> U+FFFF) are legal XML 1.0 content but a real
    # parser family (xmerl 2.x, lens2 cycle-35 falsifier: emoji blob name
    # listing) rejects the raw UTF-8 form with wfc_Legal_Character. A numeric
    # character reference is semantically IDENTICAL XML (same parsed content)
    # and parses under every XML 1.0 parser — Azure parity preserved (same
    # name after parse), parser-compat hardened.
    |> String.replace(~r/[\x{10000}-\x{10FFFF}]/u, fn <<cp::utf8>> ->
      "&#x" <> String.downcase(Integer.to_string(cp, 16)) <> ";"
    end)
  end

  def xml_escape(value), do: value |> to_string() |> xml_escape()

  defp normalize_max(nil), do: @max_page

  defp normalize_max(raw) when is_binary(raw) do
    case Integer.parse(raw) do
      {n, ""} when n > 0 -> min(n, @max_page)
      _ -> @max_page
    end
  end

  defp normalize_max(n) when is_integer(n) and n > 0, do: min(n, @max_page)
  defp normalize_max(_), do: @max_page

  defp next_marker_xml(nil), do: "<NextMarker />"

  defp next_marker_xml(marker), do: "<NextMarker>#{xml_escape(marker)}</NextMarker>"

  # ---------------------------------------------------------------------------
  # Internals
  # ---------------------------------------------------------------------------

  defp store_blob(account, container, blob_name, content, headers) do
    etag = "\"#{:crypto.hash(:md5, content) |> Base.encode16(case: :lower)}\""
    blob = %{
      "name" => blob_name,
      "content" => content,
      "content_length" => byte_size(content),
      "etag" => etag,
      "last_modified" => DateTime.utc_now() |> DateTime.to_iso8601(),
      "headers" => headers
    }
    blob = Map.update!(blob, "content", &String.trim_trailing/1)
    Store.put(:smalt_blobs, "#{account}/#{container}/#{blob_name}", blob)
    {:ok, blob}
  end

  defp mismatched_if_match?(headers, current_etag) do
    case ConditionalHeaders.header(headers || %{}, "if-match") do
      nil -> false
      _value -> ConditionalHeaders.evaluate(headers, current_etag) == {:halt, 412}
    end
  end

  defp if_none_match_star?(headers) do
    case ConditionalHeaders.header(headers || %{}, "if-none-match") do
      nil -> false
      "*" -> true
      _ -> false
    end
  end

  defp check_if_match(headers, current_etag) do
    case ConditionalHeaders.header(headers || %{}, "if-match") do
      nil -> :ok
      _ -> if ConditionalHeaders.evaluate(headers, current_etag) == {:halt, 412},
        do: {:error, {:precondition}},
        else: :ok
    end
  end

  # Azure parity (cycle-22): If-None-Match: * refuses deletion of an existing
  # blob with 412 — previously silently ignored (202 on a refuse-if-exists
  # precondition).
  defp check_if_none_match(headers) do
    case if_none_match_star?(headers) do
      true -> {:error, {:precondition}}
      false -> :ok
    end
  end

  defp check_worm(container_meta, now) do
    if worm_blocked?(container_meta, "delete", now) do
      {:error, {:worm, blocker(fetch_policy(container_meta))}}
    else
      :ok
    end
  end

  # WORM block when a legal hold is set (never expires), or the immutability
  # policy is locked / container is immutable while retention is still live.
  # Once `now > created_at + retention_days` the container unlocks — except
  # for an active legal hold, which only an explicit release lifts.
  defp worm_blocked?(container_meta, _op, now) do
    policy = fetch_policy(container_meta)

    cond do
      legal_hold?(policy) -> true
      expired?(container_meta, now) -> false
      locked_policy?(policy) -> true
      Map.get(container_meta, "immutable") == true and not policy_present?(policy) -> true
      true -> false
    end
  end

  # Retention expiry: now strictly past created_at + retention_days.
  # Legacy containers without created_at are conservatively never expired.
  defp expired?(_container_meta, _now, created_at) when is_nil(created_at), do: false

  defp expired?(container_meta, now, created_at) do
    now > created_at + retention_ms(container_meta)
  end

  defp expired?(container_meta, now) do
    expired?(container_meta, now, Map.get(container_meta, "created_at"))
  end

  defp retention_end_ms(container_meta) do
    case Map.get(container_meta, "created_at") do
      nil -> nil
      created_at -> created_at + retention_ms(container_meta)
    end
  end

  defp retention_ms(container_meta) do
    Map.get(container_meta, "retention_days", 1095) * 86_400_000
  end

  defp now_ms(opts) when is_list(opts) do
    Keyword.get(opts, :now_ms) || System.os_time(:millisecond)
  end

  defp now_ms(opts) when is_map(opts), do: now_ms(Enum.to_list(opts))

  defp fetch_policy(container_meta) do
    ensure_policy_table()
    case Store.get(@policy_table, "#{container_meta["account"]}/#{container_meta["container"]}") do
      {:ok, p} -> p
      :error -> nil
    end
  end

  defp policy_present?(nil), do: false
  defp policy_present?(policy), do: Map.has_key?(policy, "immutability_policy")

  defp legal_hold?(policy), do: !!policy && !!Map.get(policy, "legal_hold")

  defp locked_policy?(nil), do: false

  defp locked_policy?(policy) do
    case Map.get(policy, "immutability_policy") do
      %{"locked" => true} -> true
      _ -> false
    end
  end

  defp blocker(policy) do
    cond do
      legal_hold?(policy) -> :legal_hold
      locked_policy?(policy) -> :locked_policy
      true -> :legacy_immutable
    end
  end

  defp worm_message(container_meta, _now) do
    container_meta
    |> fetch_policy()
    |> blocker()
    |> worm_message_reason()
  end

  defp worm_message_reason(:legal_hold),
    do: "Blob modification refused: container has an active legal hold (ContainerLocked)."

  defp worm_message_reason(:locked_policy),
    do: "Blob modification refused: container immutability policy is locked (ContainerLocked)."

  defp worm_message_reason(:legacy_immutable),
    do: "Blob modification refused: container policy enforces immutable WORM retention."

  defp locked_policy_message,
    do: "Immutability policy is locked and can no longer be changed (ContainerLocked)."

  defp precondition_message,
    do: "The condition specified using HTTP conditional header(s) is not met."

  defp blob_or_404(blob_key) do
    case Store.get(:smalt_blobs, blob_key) do
      {:ok, blob} -> {:ok, blob}
      :error -> {:error, :not_found}
    end
  end

  defp policy_or_empty(container_key) do
    case Store.get(@policy_table, container_key) do
      {:ok, policy} -> {:ok, policy}
      :error -> {:ok, %{}}
    end
  end

  # A locked policy refuses change — unless retention has already expired,
  # in which case the container is unlocked and the policy may be changed.
  # Missing container on the policy path must be a typed 404, never a
  # WithClauseError 500 (C4-fix residual).
  defp fetch_container_meta(container_key) do
    case Store.get(:smalt_blob_containers, container_key) do
      {:ok, meta} -> {:ok, meta}
      :error -> {:error, 404, "ContainerNotFound", "Container not found."}
    end
  end

  defp refuse_if_locked(existing, container_meta, now) do
    if locked_policy?(existing) and not expired?(container_meta, now) do
      {:error, :locked}
    else
      :ok
    end
  end

  defp require_star_if_match_for_lock(headers, policy) do
    if Map.get(policy, "locked", false) do
      case ConditionalHeaders.header(headers || %{}, "if-match") do
        "*" -> :ok
        _ -> {:error, :if_match_required}
      end
    else
      :ok
    end
  end

  defp put_in_worm_defaults(policy) do
    Map.put_new(policy, "immutability_policy", %{"locked" => false, "until" => nil, "period_days" => 0})
  end

  defp default_until(days, now_ms) when is_integer(days) and days > 0 do
    DateTime.from_unix!(now_ms, :millisecond)
    |> DateTime.add(days * 86_400)
    |> DateTime.to_iso8601()
  end

  defp default_until(_, _), do: nil

  defp container_key(account, container), do: "#{account}/#{container}"

  @doc false
  def ensure_policy_table do
    if :ets.info(@policy_table) == :undefined do
      :ets.new(@policy_table, [:set, :public, :named_table,
        read_concurrency: true, write_concurrency: true])
    end
    :ok
  end

  defp request_id, do: Base.encode16(:crypto.strong_rand_bytes(16), case: :lower)

end
