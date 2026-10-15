defmodule Smalt.DataPlane.PartitionKey do
  @moduledoc """
  Cosmos DB partition-key header parsing and enforcement.

  A collection partition key is defined by JSON pointer paths (e.g. `["/tenantId"]`).
  The request header `x-ms-documentdb-partitionkey` must be a JSON array with
  exactly one non-empty string element matching the value extracted from the
  document at the collection's partition key path.
  """

  @header "x-ms-documentdb-partitionkey"

  @doc """
  Parses the `x-ms-documentdb-partitionkey` header value.

  Accepts only a JSON array with exactly one non-empty string element:

      iex> parse(~s(["acme"]))
      {:ok, "acme"}

      iex> parse("[]")
      :error
  """
  @spec parse(term()) :: {:ok, String.t()} | :error
  def parse(value) do
    case Jason.decode(value) do
      {:ok, [single]} when is_binary(single) and single != "" -> {:ok, single}
      _ -> :error
    end
  rescue
    _ -> :error
  end

  @doc """
  Extracts the partition key value from a document given JSON-pointer style
  paths (e.g. `["/tenantId", "/a/b"]`). Returns the first present path's value.
  """
  @spec extract(map(), [String.t()]) :: String.t() | nil
  def extract(doc, paths) when is_map(doc) and is_list(paths) do
    Enum.find_value(paths, fn path ->
      case path_value(doc, path) do
        nil -> nil
        val when is_binary(val) -> val
        val -> to_string(val)
      end
    end)
  end

  @doc """
  Enforces the partition-key contract for a document operation.

    * `pk_meta` is `nil` (no partition key defined) → `:ok`
    * header missing, unparseable, or mismatched against the doc's pk value
      → `{:error, 400, "BadRequest"}`

  `pk_meta` is expected as `%{"paths" => ["/tenantId"]}`.
  """
  @spec enforce(map() | nil, map() | nil) :: :ok | {:error, 400, String.t()}
  def enforce(nil, nil), do: :ok
  def enforce(nil, _pk_meta), do: {:error, 400, "BadRequest"}
  def enforce(_doc, nil), do: :ok

  def enforce(doc, pk_meta) when is_map(doc) and is_map(pk_meta) do
    enforce(Map.get(doc, "__pk_header__"), doc, pk_meta)
  end

  @doc """
  Enforces the partition-key contract given the raw header value, the document,
  and the container's pk meta (`%{"paths" => [...]}` or nil).

  No partition key defined on the container → `:ok`. Otherwise the header must
  parse and equal the pk value extracted from the document.
  """
  @spec enforce(String.t() | nil, map() | nil, map() | nil) ::
          :ok | {:error, 400, String.t()}
  def enforce(_header_raw, _doc, nil), do: :ok

  # Container defined with an EMPTY partition-key path list (create_collection
  # without a partitionKey body): header not required, matching real Cosmos
  # (a container without a pk definition accepts headerless docs).
  def enforce(_header_raw, _doc, %{"paths" => []}), do: :ok

  def enforce(_header_raw, nil, _pk_meta), do: :ok

  def enforce(header_raw, doc, pk_meta) when is_map(doc) and is_map(pk_meta) do
    paths = Map.get(pk_meta, "paths", [])

    with {:ok, header_pk} <- parse_header(header_raw, paths),
         pk when is_binary(pk) <- extract(doc, paths),
         true <- pk == header_pk do
      :ok
    else
      _ -> {:error, 400, "BadRequest"}
    end
  end

  # No paths defined on the container -> header is not required.
  defp parse_header(_raw, []), do: {:ok, nil}
  defp parse_header(nil, _paths), do: :error

  defp parse_header(raw, _paths), do: parse(raw)

  # Internal: resolve a JSON-pointer path ("/tenantId" or "/a/b") in a doc.
  defp path_value(doc, path) do
    segments =
      path
      |> String.trim_leading("/")
      |> String.split("/", parts: :infinity)

    Enum.reduce(segments, doc, fn
      seg, acc when is_map(acc) -> Map.get(acc, seg)
      _seg, _acc -> nil
    end)
  end

  @doc false
  def header_name, do: @header
end
