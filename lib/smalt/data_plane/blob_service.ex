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
      |> Enum.reject(fn {name, _} -> name != nil and not String.starts_with?(name, prefix_filter) end)
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
  `BlobStorage.list_blobs_xml/2`). Returns `{xml, next_marker}`.
  """
  def list_containers_xml(account, opts \\ %{}) do
    {:ok, result} = list_containers(account, opts)
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

    {xml, next_marker}
  end

  @doc """
  XML-escape listing output (see `BlobStorage.xml_escape/1`): container
  names, prefixes and markers containing `<`, `>`, `&`, `"` must not break
  EnumerationResults. Non-binary falls back to the empty string.
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
  end

  def xml_escape(value), do: value |> to_string() |> xml_escape()

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

    with {:ok, _} <- Store.get(:smalt_blob_containers, container_key),
         :ok <- validate_metadata_names(metadata),
         :ok <- validate_metadata_values(metadata) do
      BlobStorage.ensure_policy_table()
      existing = policy_row(container_key)
      policy =
        existing
        |> Map.put("metadata", stringify_keys(metadata))

      Store.put(@policy_table, container_key, policy)

      {:ok, 200,
       %{
         "x-ms-request-id" => request_id(),
         "x-ms-version" => "2021-12-02",
         "etag" => etag(container_key)
       }}
    else
      :error -> {:error, 404, "ContainerNotFound", "Container not found."}
      {:error, 400, _code, _msg} = invalid -> invalid
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
          "last-modified" => record["created"],
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
      nil -> :ok
      {k, _} -> {:error, 400, "InvalidMetadata", "Invalid metadata name (must be a valid C# identifier): #{k}."}
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
    bad = Enum.find(meta, fn {_k, v} -> not (is_binary(v) and Regex.match?(@meta_value_re, v)) end)

    case bad do
      nil -> :ok
      {k, _} -> {:error, 400, "InvalidMetadata", "Invalid metadata value for #{k}: values must be valid HTTP header values (no control characters)."}
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

  defp container_etag(record) do
    seed = "#{record["account"]}/#{record["container"]}/#{record["created_at"]}"
    "\"" <> Base.encode16(:crypto.hash(:md5, seed), case: :upper) <> "\""
  end

  defp etag(container_key),
    do: "\"" <> Base.encode16(:crypto.hash(:md5, container_key), case: :upper) <> "\""

  defp container_key_prefix(account, container), do: "#{account}/#{container}"

  defp next_marker_xml(nil), do: "<NextMarker />"
  defp next_marker_xml(marker), do: "<NextMarker>#{xml_escape(marker)}</NextMarker>"

  defp request_id, do: Base.encode16(:crypto.strong_rand_bytes(16), case: :lower)
end
