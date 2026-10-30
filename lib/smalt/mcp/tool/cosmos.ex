defmodule Smalt.Mcp.Tool.Cosmos do
  @moduledoc """
  MCP Cosmos DB read family: `cosmos.query`, `cosmos.stats`,
  `cosmos.uniquekeys.get`, `cosmos.ttl.effective`.

  Change-feed reads live in `Smalt.Mcp.Tool.CosmosFeed`. References the
  generated TTL surface (`Smalt.Mcp.Descriptor`); never redefines tool
  metadata. Returns the standard tool envelope: `{:ok, result}` |
  `{:refusal, code, message}` — `nil` when the tool id is not in this family
  (the router falls through to the next family).
  """

  @invalid_params_code "INVALID_PARAMS"
  @resource_not_found_code "RESOURCE_NOT_FOUND"
  @internal_code "MCP_INTERNAL"

  def input_schema("cosmos.query") do
    %{
      "type" => "object",
      "required" => ["db", "coll"],
      "properties" => %{
        "db" => %{"type" => "string"},
        "coll" => %{"type" => "string"},
        "partition_key" => %{"type" => "string", "description" => "optional partition-key value"}
      }
    }
  end

  def input_schema("cosmos.stats"), do: %{"type" => "object", "properties" => %{}}

  def input_schema("cosmos.uniquekeys.get") do
    %{
      "type" => "object",
      "required" => ["db", "coll"],
      "properties" => %{
        "db" => %{"type" => "string"},
        "coll" => %{"type" => "string"}
      }
    }
  end

  def input_schema("cosmos.ttl.effective") do
    %{
      "type" => "object",
      "required" => ["db", "coll"],
      "properties" => %{
        "db" => %{"type" => "string"},
        "coll" => %{"type" => "string"}
      }
    }
  end

  def input_schema(_other), do: nil

  def invoke("cosmos.query", args) do
    case args do
      %{"db" => db, "coll" => coll} when is_binary(db) and is_binary(coll) ->
        with {:ok, headers} <- partition_key_headers(args["partition_key"]) do
          case Smalt.DataPlane.Cosmos.query_docs(
                 db,
                 coll,
                 %{"query" => "SELECT * FROM c"},
                 headers
               ) do
            {:ok, 200, _headers, body} ->
              {:ok, body}

            {:ok, status, _headers, body} ->
              {:refusal, "COSMOS_ERROR", "cosmos.query returned #{status}: #{inspect(body)}"}

            {:error, :store_not_ready} ->
              {:refusal, "STORE_NOT_READY", "refused: cosmos store tables not initialized"}

            other ->
              {:refusal, @internal_code, "cosmos.query unexpected: #{inspect(other)}"}
          end
        end

      _ ->
        {:refusal, @invalid_params_code, "refused: cosmos.query requires db and coll"}
    end
  end

  def invoke("cosmos.stats", _args) do
    if :ets.info(:smalt_cosmos_docs) == :undefined do
      {:refusal, "STORE_NOT_READY", "refused: cosmos store tables not initialized"}
    else
      # pk_meta keys are tuples ({0,db} / {1,db,coll}); term order puts tuples
      # below binaries, so the binary-key Store scan (prefix_keys) cannot see
      # them — enumerate the table directly, same discipline as cosmos'
      # meta_records/1 (cosmos.ex:368).
      containers =
        :smalt_cosmos_pk_meta
        |> :ets.tab2list()
        |> Enum.filter(fn
          {{1, _db, _coll}, _} -> true
          _ -> false
        end)
        |> Enum.map(fn {{1, db, coll}, _} -> {db, coll} end)
        |> Enum.map(fn {db, coll} ->
          count =
            :smalt_cosmos_docs
            |> Smalt.Store.prefix_keys("#{db}/#{coll}/")
            |> Enum.count()

          %{"db" => db, "coll" => coll, "documents" => count}
        end)
        |> Enum.sort_by(&{&1["db"], &1["coll"]})

      total = Enum.sum(Enum.map(containers, & &1["documents"]))

      {:ok,
       %{
         "containers" => containers,
         "container_count" => length(containers),
         "document_count" => total
       }}
    end
  end

  def invoke("cosmos.uniquekeys.get", args) do
    case args do
      %{"db" => db, "coll" => coll} when is_binary(db) and is_binary(coll) ->
        if :ets.info(:smalt_cosmos_pk_meta) == :undefined do
          {:refusal, "STORE_NOT_READY", "refused: cosmos store tables not initialized"}
        else
          # The {1, db, coll} container record carries the uniqueKeyPolicy set
          # at create (Cosmos.create_container). Direct ETS read — tuple key,
          # invisible to the binary-key Store scan (same discipline as
          # cosmos.stats). A missing container is typed 404, never an empty ok.
          case :ets.lookup(:smalt_cosmos_pk_meta, {1, db, coll}) do
            [{_, record}] ->
              keys = record["uniqueKeyPolicy"] || []

              {:ok,
               %{
                 "db" => db,
                 "coll" => coll,
                 "uniqueKeyPolicy" => %{"uniqueKeys" => keys}
               }}

            [] ->
              {:refusal, @resource_not_found_code,
               "refused: container #{inspect(db)}/#{inspect(coll)} not found"}

            other ->
              {:refusal, @internal_code, "cosmos.uniquekeys.get unexpected: #{inspect(other)}"}
          end
        end

      _ ->
        {:refusal, @invalid_params_code, "refused: cosmos.uniquekeys.get requires db and coll"}
    end
  end

  def invoke("cosmos.ttl.effective", args) do
    case args do
      %{"db" => db, "coll" => coll} when is_binary(db) and is_binary(coll) ->
        if :ets.info(:smalt_cosmos_pk_meta) == :undefined do
          {:refusal, "STORE_NOT_READY", "refused: cosmos store tables not initialized"}
        else
          case Smalt.DataPlane.Cosmos.effective_ttl(db, coll) do
            ttl when ttl == :off or is_integer(ttl) ->
              {:ok, %{"db" => db, "coll" => coll, "effective_ttl" => ttl}}
          end
        end

      _ ->
        {:refusal, @invalid_params_code, "refused: cosmos.ttl.effective requires db and coll"}
    end
  end

  def invoke(_other, _args), do: nil

  # partition_key is optional (nil = no header) but MUST be binary when present:
  # the previous `_other -> %{}` silent-coercion treated integer/list/map keys
  # as absent, yielding a full-table scan instead of typed INVALID_PARAMS.
  defp partition_key_headers(nil), do: {:ok, %{}}

  defp partition_key_headers(pk) when is_binary(pk),
    do: {:ok, %{Smalt.DataPlane.PartitionKey.header_name() => partition_key_header(pk)}}

  defp partition_key_headers(_other),
    do: {:refusal, @invalid_params_code, "refused: partition_key must be a string"}

  defp partition_key_header(pk), do: pk
end
