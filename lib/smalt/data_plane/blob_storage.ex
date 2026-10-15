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
    key = "#{account}/#{container}"
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
  end

  @doc """
  Time-aware policy evaluation for a container. `:now_ms` is injected
  (defaults to `System.os_time(:millisecond)`).

  Returns `%{"locked" => bool, "legal_hold" => bool, "expired" => bool,
  "expires_at" => ms | nil}`. When `now > created_at + retention_days` the
  container's immutability policy has expired and the container unlocks
  (overwrite/delete permitted). Legal holds NEVER auto-expire. Legacy
  containers without `created_at` are conservatively reported as
  not-yet-expired.
  """
  def policy_state(account, container, opts \\ []) do
    now = now_ms(opts)
    container_key = container_key(account, container)

    with {:ok, meta} <- Store.get(:smalt_blob_containers, container_key) do
      policy = fetch_policy(meta)
      expires_at = retention_end_ms(meta)

      %{
        "locked" => locked_policy?(policy),
        "legal_hold" => legal_hold?(policy),
        "expired" => expired?(meta, now),
        "expires_at" => expires_at
      }
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

    if byte_size(content) > @max_put_bytes do
      {:error, :too_large, too_large_message()}
    else

    case Store.get(:smalt_blob_containers, container_key) do
      {:ok, container_meta} ->
        case Store.get(:smalt_blobs, blob_key) do
          {:ok, existing} ->
            cond do
              worm_blocked?(container_meta, "overwrite", now) ->
                {:error, :worm_locked, worm_message(container_meta, now)}

              mismatched_if_match?(headers, existing["etag"]) ->
                {:error, :precondition_failed, precondition_message()}

              true ->
                store_blob(account, container, blob_name, content, headers)
            end

          :error ->
            store_blob(account, container, blob_name, content, headers)
        end

      :error ->
        {:error, :container_not_found}
    end
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
         :ok <- check_if_match(headers, existing["etag"]) do
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

    with :ok <- require_container(container_key),
         {:ok, container_meta} <- fetch_container_meta(container_key),
         {:ok, existing} <- policy_or_empty(container_key),
         :ok <- refuse_if_locked(existing, container_meta, now),
         :ok <- require_star_if_match_for_lock(headers, policy) do
      locked = Map.get(policy, "locked", false)
      period_days = Map.get(policy, "period_days", Map.get(existing, "period_days", 0))
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
      {:error, :container_not_found} -> {:error, 404, "ContainerNotFound", "Container not found."}
      {:error, :locked} -> {:error, 409, "ContainerLocked", locked_policy_message()}
      {:error, :if_match_required} -> {:error, 412, "PreconditionFailed",
        "Locking an immutability policy requires If-Match: \"*\"."}
    end
  end

  @doc """
  PUT/DELETE ?comp=legalhold — sets (`flag: true`) or clears (`flag: false`)
  the container legal hold. Stored in `:smalt_blob_policy`.
  """
  def set_legal_hold(account, container, flag, _headers \\ %{}) when is_boolean(flag) do
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
      {:error, :container_not_found} -> {:error, 404, "ContainerNotFound", "Container not found."}
    end
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
  serving the full body. Multiple ranges: first spec only (single-part 206).
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
    key_prefix = "#{account}/#{container}/"
    marker = Map.get(opts, "marker") || ""
    max_results = normalize_max(Map.get(opts, "maxresults"))

    matching =
      Store.list_prefix(:smalt_blobs, key_prefix)
      |> Enum.map(fn b -> {b["name"], b} end)
      |> Enum.reject(fn {name, _} -> name != nil and marker != "" and name <= marker end)
      |> Enum.sort_by(fn {name, _} -> name end)

    page = Enum.take(matching, max_results)
    next_marker = if length(matching) > length(page), do: elem(Enum.at(page, -1), 0), else: nil

    blobs = Enum.map(page, fn {_name, b} -> b end)

    blob_items =
      Enum.map_join(blobs, "\n", fn b ->
        """
        <Blob>
          <Name>#{xml_escape(b["name"])}</Name>
          <Properties>
            <Content-Length>#{b["content_length"]}</Content-Length>
            <Etag>#{xml_escape(b["etag"])}</Etag>
            <Last-Modified>#{xml_escape(b["last_modified"])}</Last-Modified>
          </Properties>
        </Blob>
        """
      end)

    xml = """
    <?xml version="1.0" encoding="utf-8"?>
    <EnumerationResults ServiceEndpoint="http://127.0.0.1:8443/#{xml_escape(account)}" ContainerName="#{xml_escape(container)}">
      <Prefix>#{xml_escape(key_prefix)}</Prefix>
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
    value
    |> String.replace("&", "&amp;")
    |> String.replace("<", "&lt;")
    |> String.replace(">", "&gt;")
    |> String.replace("\"", "&quot;")
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
    Store.put(:smalt_blobs, "#{account}/#{container}/#{blob_name}", blob)
    {:ok, blob}
  end

  defp mismatched_if_match?(headers, current_etag) do
    case ConditionalHeaders.header(headers || %{}, "if-match") do
      nil -> false
      _value -> ConditionalHeaders.evaluate(headers, current_etag) == {:halt, 412}
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

  defp require_container(container_key) do
    case Store.get(:smalt_blob_containers, container_key) do
      {:ok, _} -> :ok
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
