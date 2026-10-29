defmodule Smalt.DataPlane.BlobService do
  @moduledoc """
  Account/service-level Blob operations complementing
  `Smalt.DataPlane.BlobStorage` (container/blob scoped).

  * List containers (`GET /{account}?comp=list`) — EnumerationResults XML with
    Prefix/Marker/MaxResults pagination (max 50 per page; marker = last
    returned container name).
  * Container metadata (`PUT/GET ?comp=metadata`) — `x-ms-meta-*` dict stored
    in `:smalt_blob_policy` under `"metadata"`.
  * Container properties (`GET ?restype=container`) — ETag, `x-ms-meta-*`,
    `x-ms-has-immutability-policy`, `x-ms-has-legal-hold` headers.

  Blob snapshots are PLANNED, not implemented.
  """

  alias Smalt.DataPlane.BlobStorage
  alias Smalt.Store

  @policy_table :smalt_blob_policy
  @max_page 50

  # ---------------------------------------------------------------------------
  # List containers
  # ---------------------------------------------------------------------------

  @doc """
  List containers for `account`. Options (binary-keyed, matching the query
  string): `"prefix"`, `"marker"`, `"maxresults"`.

  Returns `{:ok, %{"containers" => [record], "next_marker" => String.t | nil}}`
  where each record is the full `:smalt_blob_containers` row.
  """
  def list_containers(account, opts \\ %{}) do
    # Azure grammar parity (v26.10.14 lane 06 defect 2): container listing
    # previously SILENTLY COERCED junk maxresults to the default page size
    # while blob listing answered typed 400 InvalidQueryParameterValue — split
    # grammar. Both routes now share BlobStorage.check_maxresults/1.
    with :ok <- BlobStorage.check_maxresults(Map.get(opts, "maxresults")) do
      do_list_containers(account, opts)
    end
  end

  defp do_list_containers(account, opts) do
    prefix_filter = Map.get(opts, "prefix") || ""
    marker = Map.get(opts, "marker") || ""
    max_results = normalize_max(Map.get(opts, "maxresults"))

    key_prefix = "#{account}/"

    matching =
      Store.list_prefix(:smalt_blob_containers, key_prefix)
      |> Enum.reject(&hidden_policy_row?/1)
      |> Enum.map(fn record ->
        name = record["container"]
        {name, record}
      end)
      |> Enum.reject(fn {name, _} ->
        name != nil and not String.starts_with?(name, prefix_filter)
      end)
      |> Enum.reject(fn {name, _} -> marker != "" and name <= marker end)
      # Deterministic name order (Azure lists containers in lexicographic order)
      |> Enum.sort_by(fn {name, _} -> name end)
      |> Enum.uniq_by(fn {name, _} -> name end)

    page = Enum.take(matching, max_results)
    next_marker = if length(matching) > length(page), do: Enum.at(page, -1) |> elem(0), else: nil

    {:ok,
     %{
       "containers" => Enum.map(page, fn {_name, record} -> record end),
       "next_marker" => next_marker
     }}
  end

  @doc """
  List containers as Azure EnumerationResults XML (same style as
  `BlobStorage.list_blobs_xml/2`). Returns `{xml, next_marker}` on success
  or `{:error, 400, "InvalidQueryParameterValue", msg}` for invalid `maxresults`
  (Azure grammar parity, lane 06 defect 2).
  """
  def list_containers_xml(account, opts \\ %{}) do
    case list_containers(account, opts) do
      {:ok, result} -> {render_containers_xml(account, opts, result), result["next_marker"]}
      {:error, _status, _code, _msg} = invalid -> invalid
    end
  end

  defp render_containers_xml(account, opts, result) do
    next_marker = result["next_marker"]
    prefix_filter = Map.get(opts, "prefix") || ""
    marker = Map.get(opts, "marker") || ""
    max_results = normalize_max(Map.get(opts, "maxresults"))

    container_items =
      Enum.map_join(result["containers"], "\n", fn record ->
        """
        <Container>
          <Name>#{xml_escape(record["container"])}</Name>
          <Properties>
            <Last-Modified>#{xml_escape(record["created"])}</Last-Modified>
            <Etag>#{xml_escape(container_etag(record))}</Etag>
            <LeaseStatus>unlocked</LeaseStatus>
            <PublicAccess>none</PublicAccess>
            <HasImmutabilityPolicy>#{policy_flag(record, "immutability_policy")}</HasImmutabilityPolicy>
            <HasLegalHold>#{policy_flag(record, "legal_hold")}</HasLegalHold>
          </Properties>
        </Container>
        """
      end)

    xml = """
    <?xml version="1.0" encoding="utf-8"?>
    <EnumerationResults ServiceEndpoint="http://127.0.0.1:8443/#{xml_escape(account)}">
      <Prefix>#{xml_escape(prefix_filter)}</Prefix>
      <Marker>#{xml_escape(marker)}</Marker>
      <MaxResults>#{max_results}</MaxResults>
      <Containers>
    #{container_items}
      </Containers>
    #{next_marker_xml(next_marker)}
    </EnumerationResults>
    """

    xml
  end

  @doc """
  XML-escape listing output — delegates to `BlobStorage.xml_escape/1` (the
  canonical implementation, including the supplementary-plane transform that
  rewrites astral codepoints U+10000..U+10FFFF to numeric character
  references): container names, prefixes and markers containing `<`, `>`,
  `&`, `"` must not break EnumerationResults. Non-binary falls back to the
  empty string.
  """
  @spec xml_escape(term) :: String.t()
  def xml_escape(value), do: BlobStorage.xml_escape(value)

  # ---------------------------------------------------------------------------
  # Container metadata
  # ---------------------------------------------------------------------------

  @doc false
  # Public pre-check so callers (container create) can validate metadata
  # BEFORE any state transition — Azure validates at create, a refused create
  # must not leave the container behind.
  def check_metadata(metadata) do
    with :ok <- validate_metadata_names(metadata),
         :ok <- validate_metadata_values(metadata) do
      :ok
    end
  end

  @doc """
  PUT ?restype=container&comp=metadata — replace (never merge) the container's
  metadata dict (Azure Put Metadata replaces the full set). Returns
  `{:ok, 200, headers}` or `{:error, 404/400, code, msg}`.
  """
  def set_container_metadata(account, container, metadata, _headers \\ %{}) do
    container_key = "#{account}/#{container}"
    # Engine totality (cycle-18): nil metadata = empty replace set (Azure:
    # Put Metadata with no x-ms-meta-* headers replaces the full set with {}),
    # never a FunctionClauseError 500.
    metadata = metadata || %{}

    with {:ok, record} <- Store.get(:smalt_blob_containers, container_key),
         :ok <- validate_metadata_names(metadata),
         :ok <- validate_metadata_values(metadata),
         # R133: the write goes through the Store CAS (BlobStorage.cas_policy_row)
         # so it cannot clobber a hold committed concurrently. The WORM check
         # runs against the row inside the CAS update fn, so a hold landed
         # between our read and our write-back is SEEN on the retry and the
         # metadata PUT refuses with 409 — never a silent clear.
         :ok <-
           check_metadata_worm(
             record,
             BlobStorage.get_policy(record["account"], record["container"])
           ),
         :ok <-
           BlobStorage.cas_policy_row(container_key, fn policy ->
             case check_metadata_worm(record, policy) do
               :ok -> {:ok, Map.put(policy, "metadata", stringify_keys(metadata))}
               refused -> refused
             end
           end) do
      BlobStorage.ensure_policy_table()

      {:ok, 200,
       %{
         "x-ms-request-id" => request_id(),
         "x-ms-version" => "2021-12-02",
         "etag" => container_etag(record)
       }}
    else
      :error -> {:error, 404, "ContainerNotFound", "Container not found."}
      {:error, 400, _code, _msg} = invalid -> invalid
      {:error, 409, _code, _msg} = locked -> locked
    end
  end

  # WORM guard for Put Metadata (R62 repair 2): container metadata PUT must
  # refuse under legal hold or locked immutability policy while retention is
  # live — the same conditions that block blob put/delete (409
  # ContainerLocked, mirrored from BlobStorage.worm_blocked?/3 "overwrite"
  # arm). The legacy-immutable-without-policy arm is intentionally NOT
  # mirrored: HTTP-created containers default immutable=true with no policy,
  # and Put Metadata at create-time (and on time-retention containers, real
  # Azure parity) must succeed. BlobStorage helpers are private and
  # blob_storage.ex is not in this lane's lease.
  defp check_metadata_worm(record, policy) do
    now = System.os_time(:millisecond)

    blocked =
      cond do
        metadata_legal_hold?(policy) -> true
        metadata_retention_expired?(record, now) -> false
        metadata_locked_policy?(policy) -> true
        true -> false
      end

    if blocked do
      {:error, 409, "ContainerLocked", metadata_worm_message(policy)}
    else
      :ok
    end
  end

  defp metadata_legal_hold?(policy), do: !!policy && !!Map.get(policy, "legal_hold")

  # R83 lane unblock note: the clauses previously here (metadata_policy_present?/1)
  # had zero call sites and tripped --warnings-as-errors; removed per SLA, disclosed
  # in the R83 receipt (owner lane may restore with a call site).

  defp metadata_locked_policy?(nil), do: false

  defp metadata_locked_policy?(policy) do
    case Map.get(policy, "immutability_policy") do
      %{"locked" => true} -> true
      _ -> false
    end
  end

  defp metadata_retention_expired?(record, now) do
    case Map.get(record, "created_at") do
      nil -> false
      created_at -> now > created_at + Map.get(record, "retention_days", 1095) * 86_400_000
    end
  end

  defp metadata_worm_message(policy) do
    cond do
      metadata_legal_hold?(policy) ->
        "Blob modification refused: container has an active legal hold (ContainerLocked)."

      metadata_locked_policy?(policy) ->
        "Blob modification refused: container immutability policy is locked (ContainerLocked)."

      true ->
        "Blob modification refused: container policy enforces immutable WORM retention."
    end
  end

  @doc "GET ?comp=metadata — returns `{:ok, metadata}` or `{:error, 404, ...}`."
  def get_container_metadata(account, container) do
    container_key = "#{account}/#{container}"

    with {:ok, _} <- Store.get(:smalt_blob_containers, container_key) do
      case policy_row(container_key)["metadata"] do
        nil -> {:ok, %{}}
        meta -> {:ok, meta}
      end
    else
      :error -> {:error, 404, "ContainerNotFound", "Container not found."}
    end
  end

  # ---------------------------------------------------------------------------
  # Container properties
  # response headers only
  # ---------------------------------------------------------------------------

  @doc """
  GET ?restype=container — returns `{:ok, 200, headers}` with `ETag`,
  `x-ms-meta-*`, `x-ms-has-immutability-policy`, `x-ms-has-legal-hold`,
  `Last-Modified`, `x-ms-request-id`, `x-ms-version`; or
  `{:error, 404, "ContainerNotFound", msg}`.
  """
  def get_container_properties(account, container) do
    container_key = "#{container_key_prefix(account, container)}"

    with {:ok, record} <- Store.get(:smalt_blob_containers, container_key) do
      policy = policy_row(container_key)
      meta = policy["metadata"] || %{}

      headers =
        %{
          "etag" => container_etag(record),
          "x-ms-request-id" => request_id(),
          "x-ms-version" => "2021-12-02",
          "last-modified" => rfc1123(record["created"]),
          "x-ms-has-immutability-policy" => policy_flag(record, "immutability_policy"),
          "x-ms-has-legal-hold" => policy_flag(record, "legal_hold")
        }
        |> Map.merge(meta_headers(meta))

      {:ok, 200, headers}
    else
      :error -> {:error, 404, "ContainerNotFound", "Container not found."}
    end
  end

  # ---------------------------------------------------------------------------
  # Internals
  # ---------------------------------------------------------------------------

  defp hidden_policy_row?(record), do: is_map(record) and record["container"] == nil

  # KD-COVERS: KD-03
  # KD-03 wire normalization: Azure dates are RFC-1123 ("Tue, 15 Oct 2026
  # 12:00:00 GMT"), not ISO-8601. A nil/unparseable `created` keeps the raw
  # string (put_resp_headers/2 skips nil) — never a crash on a fresh record.
  defp rfc1123(raw) do
    case DateTime.from_iso8601(raw || "") do
      {:ok, dt, _offset} -> Calendar.strftime(dt, "%a, %d %b %Y %H:%M:%S GMT")
      {:error, _reason} -> raw
    end
  end

  defp normalize_max(nil), do: @max_page
  defp normalize_max(value) when is_integer(value) and value > 0, do: min(value, @max_page)

  defp normalize_max(value) when is_binary(value) do
    case Integer.parse(value) do
      {n, _} when n > 0 -> min(n, @max_page)
      _ -> @max_page
    end
  end

  defp policy_row(container_key) do
    BlobStorage.ensure_policy_table()

    case Store.get(@policy_table, container_key) do
      {:ok, policy} -> policy
      :error -> %{}
    end
  end

  defp stringify_keys(meta) when is_map(meta) do
    Map.new(meta, fn
      {k, v} when is_binary(k) -> {k, v}
      {k, v} -> {to_string(k), v}
    end)
  end

  # Azure parity (Put Metadata): metadata names must be valid C# identifiers;
  # violations answer 400 InvalidMetadata and store nothing.
  @meta_name_re ~r/^[A-Za-z_][A-Za-z0-9_]*$/

  defp validate_metadata_names(meta) when is_map(meta) do
    bad = Enum.find(meta, fn {k, _} -> not Regex.match?(@meta_name_re, k) end)

    case bad do
      nil ->
        :ok

      {k, _} ->
        {:error, 400, "InvalidMetadata",
         "Invalid metadata name (must be a valid C# identifier): #{k}."}
    end
  end

  defp validate_metadata_names(_), do: :ok

  # Azure parity (Put Metadata): metadata VALUES ride HTTP headers (they are
  # re-emitted as x-ms-meta-* on GET properties) — they must be valid header
  # values. Control bytes (NUL/CR/LF/DEL, other C0) are rejected; printable
  # ASCII and UTF-8 pass (both directions accept them). Previously hostile
  # values stored fine and then raised Plug.Conn.InvalidHeaderError (a 500)
  # on GET properties.
  @meta_value_re ~r/^[^\x00-\x1F\x7F]*$/

  defp validate_metadata_values(meta) when is_map(meta) do
    bad =
      Enum.find(meta, fn {_k, v} -> not (is_binary(v) and Regex.match?(@meta_value_re, v)) end)

    case bad do
      nil ->
        :ok

      {k, _} ->
        {:error, 400, "InvalidMetadata",
         "Invalid metadata value for #{k}: values must be valid HTTP header values (no control characters)."}
    end
  end

  defp validate_metadata_values(_), do: :ok

  defp meta_headers(meta) do
    Map.new(meta, fn {k, v} -> {"x-ms-meta-#{k}", to_string(v)} end)
  end

  # HasImmutabilityPolicy must not count the default immutability_policy stub
  # that set_legal_hold writes via put_in_worm_defaults — only a real policy
  # (locked, non-zero period, or a set until) counts.
  defp policy_flag(record, "immutability_policy") do
    case BlobStorage.get_policy(record["account"], record["container"]) do
      nil ->
        "false"

      policy ->
        ip = Map.get(policy, "immutability_policy") || %{}

        has =
          ip["locked"] == true or ip["until"] != nil or
            (is_integer(ip["period_days"]) and ip["period_days"] > 0)

        to_string(has)
    end
  end

  defp policy_flag(record, "legal_hold") do
    case BlobStorage.get_policy(record["account"], record["container"]) do
      nil -> "false"
      policy -> to_string(!!Map.get(policy, "legal_hold"))
    end
  end

  # KD-COVERS: KD-144 — real Azure renders storage ETags as a quoted
  # `0x`-prefixed 16-hex-digit string (e.g. `"0x8DAB1C3A4B5C6D7E"`), never a
  # bare 32-char hex digest. Single derivation for the container and blob
  # faces (KD-144 containers, KD-146 blobs); conditional headers (If-Match)
  # compare the stored string, so one consistent shape round-trips.
  @doc "Quoted `0x…` storage ETag (Azure contract shape) — stable per seed."
  def storage_etag(seed) when is_binary(seed) do
    <<prefix::binary-size(8), _::binary>> = :crypto.hash(:md5, seed)
    "\"0x" <> Base.encode16(prefix, case: :upper) <> "\""
  end

  @doc "Quoted container ETag — stable per (account, container, created_at)."
  def container_etag(record) do
    seed = "#{record["account"]}/#{record["container"]}/#{record["created_at"]}"
    storage_etag(seed)
  end

  defp container_key_prefix(account, container), do: "#{account}/#{container}"

  defp next_marker_xml(nil), do: "<NextMarker />"
  defp next_marker_xml(marker), do: "<NextMarker>#{xml_escape(marker)}</NextMarker>"

  # Real Azure Storage answers x-ms-request-id with a dashed-36 RFC 4122 v4
  # GUID — same unified form as the ARM gateway and LA surface
  # (egress_router.ex generate_request_id/0; cross-court finding F1,
  # compliance lens-7 8th confirmation). Previously a 32-hex dialect pin.
  defp request_id do
    <<a::32, b::16, c::16, d::16, e::48>> = :crypto.strong_rand_bytes(16)
    c4 = :erlang.band(c, 0x0FFF) + 0x4000
    d = :erlang.bor(:erlang.band(d, 0x3FFF), 0x8000)

    :io_lib.format("~8.16.0b-~4.16.0b-~4.16.0b-~4.16.0b-~12.16.0b", [
      a,
      b,
      c4,
      d,
      e
    ])
    |> IO.iodata_to_binary()
  end
end
