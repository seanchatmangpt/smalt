defmodule Smalt.DataPlane.Cosmos do
  @moduledoc """
  Cosmos DB NoSQL point-operation engine extracted from the egress router.

  All handlers return a uniform `{:ok, status, headers, body}` tuple where
  `headers` is a string-keyed map ready for the router lane to emit as HTTP
  response headers.

  Table ownership (S8 fix): BOTH `:smalt_cosmos_lsn` and `:smalt_cosmos_pk_meta`
  are created ONCE by `Smalt.Store.init/1` (coordinator-owned). This module
  NEVER creates tables — when the store tables are absent every handler fails
  closed with `{:error, :store_not_ready}`, which the egress router maps to
  `503 RouteNotReady`.

  Optimistic concurrency (S8 fix): on the If-Match conditional paths the check
  and the write run as ONE `Smalt.Store.compare_and_swap/4` — lookup+insert
  serialized inside the Store GenServer — so a same-doc race between If-Match
  writers yields exactly one 200 and N-1 412s, never a lost update. This
  guarantee is scoped to If-Match-vs-If-Match pairs; a participant that omits
  If-Match takes the documented last-writer-wins (LWW) branch (`put_doc` /
  `patch_doc` without the header) and can supersede a concurrent conditional
  write by design.
  """

  alias Smalt.DataPlane.ConditionalHeaders
  alias Smalt.DataPlane.PartitionKey
  alias Smalt.Store

  @request_charge "1.0"
  @docs_table :smalt_cosmos_docs
  @pk_meta_table :smalt_cosmos_pk_meta
  @lsn_table :smalt_cosmos_lsn
  @session_token_version 1
  # List-feed continuation tokens live in a SEPARATE namespace (version 2) so a
  # query token and a list token are never interchangeable: feeding either
  # across surfaces is a typed 400 (real Cosmos: continuation tokens are bound
  # to the feed that emitted them; a foreign/logically-invalid token is 400).
  @list_token_version 2

  @continuation_header "x-ms-continuation"

  @query_limit 100

  # Real Cosmos doc payload limit: 2MB.
  @max_doc_bytes 2 * 1024 * 1024

  @type resp :: {:ok, pos_integer(), map(), map() | String.t() | list()}
  @type not_ready :: {:error, :store_not_ready}

  # ---------------------------------------------------------------------------
  # Store readiness (never creates tables)
  # ---------------------------------------------------------------------------

  @doc """
  True only when the coordinator-owned Store has created the Cosmos tables.
  This module never creates them.
  """
  def store_ready? do
    Enum.all?([@docs_table, @pk_meta_table, @lsn_table], fn t ->
      :ets.info(t) != :undefined
    end)
  end

  # ---------------------------------------------------------------------------
  # Database / container creation surfaces
  # ---------------------------------------------------------------------------

  @doc """
  POST /dbs — create a database record. Stored in `:smalt_cosmos_pk_meta`
  under a `{0, db}` tuple key (term order keeps tuple keys out of every binary
  prefix scan).
  """
  def create_db(db) do
    if store_ready?() do
      # Real Cosmos name rules (row 11 surface): names are case-sensitive and
      # capped at 255 chars; "/" is reserved for the path grammar.
      case valid_name?(db) do
        true ->
          do_create_db(db)

        false ->
          {:ok, 400, %{"x-ms-request-charge" => @request_charge},
           %{
             "code" => "BadRequest",
             "message" => "Invalid database name: must be 1-255 chars and must not contain '/'."
           }}
      end
    else
      {:error, :store_not_ready}
    end
  end

  defp do_create_db(db) do
    key = {0, db}

    record = %{
      "id" => db,
      "_rid" => db_rid(db),
      "_self" => "/dbs/#{db}",
      "_ts" => System.system_time(:second)
    }

    :ets.insert(@pk_meta_table, {key, record})
    {:ok, 201, success_headers(db, nil, 0, %{"etag" => quoted_sha256(record)}), record}
  end

  # Real Cosmos: resource names are 1-255 chars; "/" is reserved for the path
  # grammar (and is this engine's key delimiter).
  defp valid_name?(name),
    do: is_binary(name) and byte_size(name) in 1..255 and not contains_slash?(name)

  defp contains_slash?(name), do: String.contains?(name, "/")

  @doc "GET /dbs — list database records."
  def list_dbs do
    if store_ready?() do
      dbs =
        meta_records(fn
          {0, _db} -> true
          _ -> false
        end)

      {:ok, 200, %{"x-ms-request-charge" => @request_charge},
       %{"Databases" => dbs, "_count" => length(dbs)}}
    else
      {:error, :store_not_ready}
    end
  end

  @doc """
  POST /dbs/:db/colls — create a container with its partition-key definition.
  The pk definition is stored DURABLY (store-owned table) via `define_container/3`,
  which re-enables live pk enforcement (400 on mismatch).
  """
  def create_collection(db, coll, body) when is_map(body) do
    if store_ready?() do
      case valid_name?(db) and valid_name?(coll) do
        true ->
          do_create_collection(db, coll, body)

        false ->
          {:ok, 400, %{"x-ms-request-charge" => @request_charge},
           %{
             "code" => "BadRequest",
             "message" =>
               "Invalid database or container name: must be 1-255 chars and must not contain '/'."
           }}
      end
    else
      {:error, :store_not_ready}
    end
  end

  defp do_create_collection(db, coll, body) do
    paths =
      body
      |> Map.get("partitionKey")
      |> paths_from_body()

    key = {1, db, coll}

    case throughput_from_body(body) do
      {:error, status, message} ->
        {:ok, status, %{"x-ms-request-charge" => @request_charge}, message}

      {:ok, throughput} ->
        record =
          %{
            "id" => coll,
            "_rid" => coll_rid(db, coll),
            "_self" => "/dbs/#{db}/colls/#{coll}",
            # Engine-level: the python azure-cosmos SDK reads partitionKey["kind"]
            # (_ExtractPartitionKey); a record without it KeyErrors in the SDK.
            "partitionKey" => Map.put_new(%{"paths" => paths}, "kind", "Hash"),
            "uniqueKeyPolicy" => unique_keys_from_body(body),
            "_ts" => System.system_time(:second)
          }
          |> maybe_put_throughput(throughput)

        :ets.insert(@pk_meta_table, {key, record})
        define_container(db, coll, paths)

        {:ok, 201, success_headers(db, coll, 0, %{"etag" => quoted_sha256(record)}), record}
    end
  end

  # 80/20 throughput surface (C5 typed gap): real Cosmos models throughput as
  # an offer; here the integer is stored on the container record and served on
  # every read. Absent key -> key absent from the record (never null).
  @doc """
  PUT /dbs/:db/colls/:coll — replace container (throughput replace path).
  Absent `throughput` on the PUT body leaves the stored value unchanged;
  present non-integer (or non-positive) is a typed 400 BadRequest, never a 500.
  """
  def replace_collection(db, coll, body) when is_map(body) do
    if store_ready?() do
      case container_record(db, coll) do
        nil ->
          {:ok, 404, %{"x-ms-request-charge" => @request_charge},
           %{"code" => "NotFound", "message" => "Entity with id #{coll} not found"}}

        record ->
          case throughput_from_body(body) do
            {:error, status, message} ->
              {:ok, status, %{"x-ms-request-charge" => @request_charge}, message}

            {:ok, nil} ->
              {:ok, 200, success_headers(db, coll, 0, %{"etag" => quoted_sha256(record)}), record}

            {:ok, t} ->
              record =
                record
                |> Map.put("throughput", t)
                |> Map.put("_ts", System.system_time(:second))

              :ets.insert(@pk_meta_table, {{1, db, coll}, record})
              {:ok, 200, success_headers(db, coll, 0, %{"etag" => quoted_sha256(record)}), record}
          end
      end
    else
      {:error, :store_not_ready}
    end
  end

  defp maybe_put_throughput(record, nil), do: record
  defp maybe_put_throughput(record, t), do: Map.put(record, "throughput", t)

  # SHIM-COURT lane 529: throughput extraction — present-but-non-integer (or
  # non-positive) is a typed 400; absent is {:ok, nil} (key stays absent, not null).
  defp throughput_from_body(body) do
    case Map.get(body, "throughput") do
      nil ->
        {:ok, nil}

      t when is_integer(t) and t > 0 ->
        {:ok, t}

      other ->
        {:error, 400,
         %{
           "code" => "BadRequest",
           "message" => "Invalid throughput: expected a positive integer, got: #{inspect(other)}"
         }}
    end
  end

  @doc "GET /dbs/:db/colls — list container records for a database."
  def list_collections(db) do
    if store_ready?() do
      colls =
        meta_records(fn
          {1, ^db, _coll} -> true
          _ -> false
        end)

      {:ok, 200, %{"x-ms-request-charge" => @request_charge},
       %{"DocumentCollections" => colls, "_count" => length(colls)}}
    else
      {:error, :store_not_ready}
    end
  end

  defp paths_from_body(nil), do: []

  defp paths_from_body(%{"paths" => paths}) when is_list(paths),
    do: Enum.filter(paths, &is_binary/1)

  defp paths_from_body(_other), do: []

  # ---------------------------------------------------------------------------
  # Unique-key policy (real Cosmos: container-scoped uniqueness within each
  # logical partition; a violating create/replace is a 409 Conflict).
  # ---------------------------------------------------------------------------

  # Extracts a normalized uniqueKeyPolicy from a create-container body:
  # %{"uniqueKeyPolicy" => %{"uniqueKeys" => [%{"paths" => [p, ...]}, ...]}}
  # -> [%{"paths" => [p, ...]}, ...]. Non-conforming entries are dropped.
  defp unique_keys_from_body(body) do
    case body do
      %{"uniqueKeyPolicy" => %{"uniqueKeys" => keys}} when is_list(keys) ->
        for %{"paths" => ps} <- keys, ps = Enum.filter(ps, &is_binary/1), ps != [] do
          %{"paths" => ps}
        end

      _ ->
        []
    end
  end

  # The {1, db, coll} container record carries the uniqueKeyPolicy at create.
  defp container_record(db, coll) do
    if store_ready?() do
      case Store.get(@pk_meta_table, {1, db, coll}) do
        {:ok, record} -> record
        :error -> nil
      end
    else
      nil
    end
  end

  defp unique_key_defs(db, coll) do
    case container_record(db, coll) do
      %{"uniqueKeyPolicy" => keys} when is_list(keys) -> keys
      _ -> []
    end
  end

  # :ok | {:error, 409, "Conflict"} — checked against every other stored doc
  # in the same logical partition (same pk values) sharing the same unique-key
  # tuple. `exclude_id` skips the doc being replaced (PUT path).
  defp unique_key_gate(db, coll, body, exclude_id) do
    defs = unique_key_defs(db, coll)
    pk_paths = container_paths(db, coll)

    if defs == [] do
      :ok
    else
      pk_val = PartitionKey.extract(body, pk_paths)

      mine = Enum.map(defs, fn %{"paths" => ps} -> values_at(body, ps) end)

      conflict? =
        @docs_table
        |> Store.list_prefix(container_prefix(db, coll))
        |> Enum.any?(fn doc ->
          Map.get(doc, "id") != exclude_id and same_partition?(doc, pk_paths, pk_val) and
            Enum.with_index(mine)
            |> Enum.any?(fn {vals, i} ->
              %{"paths" => ps} = Enum.at(defs, i)
              values_at(doc, ps) == vals
            end)
        end)

      if conflict? do
        {:error, 409, "Conflict"}
      else
        :ok
      end
    end
  end

  defp same_partition?(doc, pk_paths, pk_val) do
    PartitionKey.extract(doc, pk_paths) == pk_val
  end

  # Resolves JSON-pointer path(s) to a comparable value tuple; missing paths
  # yield nil so a doc missing the unique-key field never collides with one
  # that has it (real Cosmos: absent fields are not equal to present fields).
  defp values_at(doc, paths) do
    Enum.map(paths, fn path ->
      case pointer_get(doc, path) do
        {:ok, v} -> v
        :error -> nil
      end
    end)
  end

  defp container_paths(db, coll) do
    case container_meta(db, coll) do
      %{"paths" => paths} -> paths
      _ -> []
    end
  end

  defp container_prefix(db, coll), do: "#{db}/#{coll}/"

  defp meta_records(pred) do
    # Tuple keys sort above every binary in term order, so they are invisible
    # to Store.list_prefix/2 binary scans; enumerate the table directly.
    Stream.unfold(:ets.first(@pk_meta_table), fn
      :"$end_of_table" -> nil
      key -> {key, :ets.next(@pk_meta_table, key)}
    end)
    |> Enum.filter(pred)
    |> Enum.map(fn key ->
      {:ok, val} = Store.get(@pk_meta_table, key)
      val
    end)
  end

  # ---------------------------------------------------------------------------
  # Container partition-key metadata
  # ---------------------------------------------------------------------------

  @doc """
  Defines a container's partition key (JSON-pointer paths). Stored in
  `:smalt_cosmos_pk_meta` as `{"db/coll", %{"paths" => [...]}}` (durable:
  store-owned table created by Store.init, not the request process).
  """
  def define_container(db, coll, paths) when is_list(paths) do
    if store_ready?() do
      Store.put(@pk_meta_table, container_key(db, coll), %{"paths" => paths})
      :ok
    else
      {:error, :store_not_ready}
    end
  end

  @doc "Returns the container's `%{\"paths\" => [...]}` meta or nil."
  def container_meta(db, coll) do
    if store_ready?() do
      case Store.get(@pk_meta_table, container_key(db, coll)) do
        {:ok, meta} -> meta
        :error -> nil
      end
    else
      nil
    end
  end

  # ---------------------------------------------------------------------------
  # Delete-path sweep helpers (composite-identity lane, D127 cascade semantics)
  # ---------------------------------------------------------------------------

  @doc """
  Cascade sweep for a deleted sqlDatabase: removes the `{0, db}` record, every
  `{1, db, _}` collection record, and the `"db/coll"` pk-paths records under it.
  Tolerates a missing table (pre-Store boot) — control-plane deletes never
  500 on data-plane absence (same fence as `VaultData.drop_vault_secrets/1`).
  """
  @spec drop_db(binary()) :: :ok
  def drop_db(db) when is_binary(db) do
    if :ets.info(@pk_meta_table) != :undefined do
      Store.delete(@pk_meta_table, {0, db})

      # Collection (`{1, db, coll}`) and pk-paths (`"db/coll"`) keys are swept
      # by pattern: any child row belonging to this db goes with it.
      for {key, _} <- :ets.tab2list(@pk_meta_table),
          cosmos_child_of?(key, db) do
        Store.delete(@pk_meta_table, key)
      end
    end

    :ok
  end

  @doc """
  Cascade sweep for a deleted sqlContainer: removes the `{1, db, coll}`
  collection record and the `"db/coll"` pk-paths record. Leaves the parent
  `{0, db}` record alone (the database still exists).
  """
  @spec drop_container(binary(), binary()) :: :ok
  def drop_container(db, coll) when is_binary(db) and is_binary(coll) do
    if :ets.info(@pk_meta_table) != :undefined do
      Store.delete(@pk_meta_table, {1, db, coll})
      Store.delete(@pk_meta_table, container_key(db, coll))
    end

    :ok
  end

  @doc """
  DELETE /dbs/:db — delete a database and its full cascade. Azure parity:
  204 + system headers on success; 404 (wire code "NotFound", the
  CosmosResourceNotFoundError the SDKs raise) on a missing database. Cascades
  every container under the db: documents, pk_meta rows (`{1, db, coll}`,
  `"db/coll"`), change-feed cursors (`{2, db, coll}`), and the per-container
  LSN counters (the session-token namespace — `x-ms-session-token` is
  "version#lsn", so dropping the counter resets the token namespace for the
  container; on recreate the token stream restarts clean). No If-Match is
  required — real Cosmos requires no etag for db/container delete.
  """
  def delete_database(db, headers) when is_binary(db) do
    gate(:delete, "dbs", "dbs/#{db}", headers, fn ->
      if store_ready?() do
        case Store.get(@pk_meta_table, {0, db}) do
          {:ok, _record} ->
            for {key, _} <- :ets.tab2list(@pk_meta_table),
                match?({1, ^db, _coll}, key) do
              {1, ^db, coll} = key
              sweep_container(db, coll)
            end

            drop_db(db)
            {:ok, 204, success_headers(db, nil, 0, %{}), ""}

          :error ->
            error_response(
              db,
              nil,
              404,
              "NotFound",
              "Entity with the specified id does not exist in the system."
            )
        end
      else
        {:error, :store_not_ready}
      end
    end)
  end

  @doc """
  DELETE /dbs/:db/colls/:coll — delete a container and its full cascade.
  Azure parity: 204 + system headers on success; 404 ("NotFound" → SDK
  CosmosResourceNotFoundError) on a missing container. Cascades the
  container's documents, its pk_meta rows, its change-feed cursor, and its
  LSN counter (session-token namespace reset). No If-Match required.
  """
  def delete_collection(db, coll, headers) when is_binary(db) and is_binary(coll) do
    gate(:delete, "colls", container_link(db, coll), headers, fn ->
      if store_ready?() do
        case container_record(db, coll) do
          nil ->
            error_response(
              db,
              coll,
              404,
              "NotFound",
              "Entity with the specified id does not exist in the system."
            )

          _record ->
            sweep_container(db, coll)
            {:ok, 204, success_headers(db, coll, 0, %{}), ""}
        end
      else
        {:error, :store_not_ready}
      end
    end)
  end

  # Full per-container cascade: docs (`"db/coll/<id>"` prefix), pk_meta rows
  # (collection record + pk-paths via drop_container/2), change-feed cursor
  # `{2, db, coll}`, and the LSN counter `"db/coll"` in @lsn_table (the
  # session-token namespace for this container).
  defp sweep_container(db, coll) do
    if :ets.info(@docs_table) != :undefined do
      prefix = "#{container_key(db, coll)}/"

      for {key, _} <- :ets.tab2list(@docs_table),
          is_binary(key) and String.starts_with?(key, prefix) do
        Store.delete(@docs_table, key)
      end
    end

    if :ets.info(@lsn_table) != :undefined do
      Store.delete(@lsn_table, container_key(db, coll))
    end

    if :ets.info(@pk_meta_table) != :undefined do
      Store.delete(@pk_meta_table, {2, db, coll})
    end

    drop_container(db, coll)
    :ok
  end

  # True when `key` is a pk_meta row belonging to `db`: a collection record
  # `{1, db, _}` or a pk-paths record `"db/coll"`.
  defp cosmos_child_of?({1, db, _coll}, db), do: true
  defp cosmos_child_of?(key, db) when is_binary(key), do: String.starts_with?(key, "#{db}/")
  defp cosmos_child_of?(_, _), do: false

  # ---------------------------------------------------------------------------
  # Route-handling functions (wired by the egress lane)
  # ---------------------------------------------------------------------------

  @doc """
  POST /dbs/:db/colls/:coll/docs — bulk/batch operations.
  Accepts a list of operation maps, e.g.:
  `[%{"operationType" => "Upsert", "resourceBody" => %{...}, "partitionKey" => "[\"...\"]"}]`
  Returns `{:ok, 200, headers, results}` where results is a list of per-item responses:
  `[%{"statusCode" => 200, "resourceBody" => %{...}}]`.
  """
  def bulk_operations(db, coll, ops, headers) when is_list(ops) do
    gate(:post, "docs", container_link(db, coll), headers, fn ->
      if store_ready?() do
        results =
          Enum.map(ops, fn op ->
            op_type = Map.get(op, "operationType")
            resource = Map.get(op, "resourceBody") || %{}
            pk = Map.get(op, "partitionKey")
            op_headers =
              if pk do
                Map.put(headers, "x-ms-documentdb-partitionkey", pk)
              else
                headers
              end

            case op_type do
              "Create" ->
                case do_create_doc(db, coll, resource, op_headers) do
                  {:ok, status, _h, body} ->
                    %{"statusCode" => status, "resourceBody" => body}
                end

              "Upsert" ->
                upsert_headers = Map.put(op_headers, "x-ms-documentdb-is-upsert", "true")

                case do_create_doc(db, coll, resource, upsert_headers) do
                  {:ok, status, _h, body} ->
                    %{"statusCode" => status, "resourceBody" => body}
                end

              "Replace" ->
                doc_id = Map.get(resource, "id") || Map.get(op, "id")

                case do_put_doc(db, coll, doc_id, resource, op_headers) do
                  {:ok, status, _h, body} ->
                    %{"statusCode" => status, "resourceBody" => body}
                end

              "Delete" ->
                doc_id = Map.get(op, "id") || Map.get(resource, "id")

                case do_delete_doc(db, coll, doc_id, op_headers) do
                  {:ok, status, _h, body} ->
                    %{"statusCode" => status, "resourceBody" => body}
                end

              "Read" ->
                doc_id = Map.get(op, "id") || Map.get(resource, "id")

                case do_get_doc_direct(db, coll, doc_id, op_headers) do
                  {:ok, status, _h, body} ->
                    %{"statusCode" => status, "resourceBody" => body}
                end

              _ ->
                %{"statusCode" => 400, "resourceBody" => %{"message" => "Unsupported operationType #{inspect(op_type)}"}}
            end
          end)

        lsn = current_lsn(db, coll)
        {:ok, 200, success_headers(db, coll, lsn, %{}), results}
      else
        {:error, :store_not_ready}
      end
    end)
  end

  defp do_get_doc_direct(db, coll, doc_id, headers) do
    case Store.get(@docs_table, doc_key(db, coll, doc_id)) do
      {:ok, doc} ->
        case ConditionalHeaders.evaluate(headers, doc["_etag"]) do
          :proceed ->
            lsn = current_lsn(db, coll)
            {:ok, 200, success_headers(db, coll, lsn, %{"etag" => doc["_etag"]}), doc}

          {:halt, 304} ->
            lsn = current_lsn(db, coll)
            {:ok, 304, success_headers(db, coll, lsn, %{"etag" => doc["_etag"]}), %{}}

          {:halt, 412} ->
            error_response(db, coll, 412, "PreconditionFailed", precondition_message())
        end

      :error ->
        error_response(
          db,
          coll,
          404,
          "NotFound",
          "Entity with the specified id does not exist in the system."
        )
    end
  end

  @doc """
  POST /dbs/:db/colls/:coll/docs — create. Returns `{:ok, 201, headers, doc}`.
  """
  def create_doc(db, coll, body, headers) when is_map(body) do
    gate(:post, "docs", container_link(db, coll), headers, fn ->
      if store_ready?() do
        do_create_doc(db, coll, body, headers)
      else
        {:error, :store_not_ready}
      end
    end)
  end

  defp do_create_doc(db, coll, body, headers) do
    doc_id = Map.get(body, "id") || "doc_#{System.unique_integer([:positive])}"

    cond do
      # Real Cosmos doc-id grammar (same class as the db/container name rule):
      # 1-255 chars, no "/". Previously an id of "a/b", "" or a 256-char id
      # was admitted (201) at this surface while the wire layer refused it.
      not valid_doc_id?(doc_id) ->
        error_response(db, coll, 400, "BadRequest", invalid_doc_id_message())

      byte_size(Jason.encode!(body)) > @max_doc_bytes ->
        error_response(db, coll, 413, "RequestEntityTooLarge", request_entity_too_large_message())

      true ->
        do_create_doc_sized(db, coll, doc_id, body, headers)
    end
  end

  # Create with an id that already exists in the container → 409 Conflict
  # (real Cosmos semantics; previously a silent 201-overwrite — measured:
  # create {"id":"x","v":2} over {"v":1} returned 201 and clobbered the doc).
  # Real Cosmos doc ids: 1-255 chars, no "/" (ids compose the storage key and
  # the _self link, so the same grammar as db/container names applies).
  defp valid_doc_id?(id), do: valid_name?(id)

  # KD-36: x-ms-documentdb-is-upsert truthy values (real Cosmos .NET/Go SDKs
  # send "true"; tolerate "1").
  defp upsert?(headers) do
    header(headers, "x-ms-documentdb-is-upsert") in ["true", "True", "1"]
  end

  defp invalid_doc_id_message,
    do: "Invalid document id: must be a 1-255 char string and must not contain '/'."

  defp do_create_doc_sized(db, coll, doc_id, body, headers) do
    pk_meta = container_meta(db, coll)

    case PartitionKey.enforce(header(headers, PartitionKey.header_name()), body, pk_meta) do
      :ok ->
        case unique_key_gate(db, coll, body, nil) do
          :ok ->
            # SHIM-COURT-adjacent etag hardening (R59/A18): etag binds the body
            # hash with a per-doc version (_v) and per-creation nonce (_gen),
            # so identical bodies never collide and delete+recreate invalidates
            # the old etag.
            gen = doc_gen_nonce()
            etag = doc_etag(body_hash_hex(body), 1, gen)
            now = System.system_time(:second)

            stored =
              body
              |> Map.put("id", doc_id)
              |> Map.put("_rid", doc_rid(db, coll, doc_id))
              |> Map.put("_self", "/dbs/#{db}/colls/#{coll}/docs/#{doc_id}")
              |> Map.put("_v", 1)
              |> Map.put("_gen", gen)
              |> Map.put("_etag", etag)
              |> Map.put("_ts", now)

            case Store.insert_new(@docs_table, doc_key(db, coll, doc_id), stored) do
              :ok ->
                lsn = next_lsn(db, coll)
                {:ok, 201, success_headers(db, coll, lsn, %{"etag" => etag}), stored}

              {:error, :exists} ->
                # KD-36: x-ms-documentdb-is-upsert -> create-or-replace. On an
                # existing id, real Cosmos replaces (200) instead of 409;
                # delegate to the replace path (full replace semantics, fresh
                # _v/_gen/_etag). Without the header the 409 Conflict stands.
                if upsert?(headers) do
                  do_put_doc(db, coll, doc_id, body, headers)
                else
                  error_response(
                    db,
                    coll,
                    409,
                    "Conflict",
                    "Entity with the specified id already exists in the system."
                  )
                end
            end

          {:error, 409, "Conflict"} ->
            error_response(
              db,
              coll,
              409,
              "Conflict",
              "Uniqueness constraint violated: an item with the same unique key " <>
                "values already exists in the logical partition."
            )

          {:error, status, code} ->
            error_response(db, coll, status, code, error_message(code, pk_meta))
        end

      {:error, status, code} ->
        error_response(db, coll, status, code, error_message(code, pk_meta))
    end
  end

  @doc """
  GET /dbs/:db/colls/:coll/docs/:doc_id — read.
  200 with body, 304 when If-None-Match matches, 404 NotFound.
  """
  def get_doc(db, coll, doc_id, headers) do
    gate(:get, "docs", doc_link(db, coll, doc_id), headers, fn ->
      if store_ready?() do
        case Store.get(@docs_table, doc_key(db, coll, doc_id)) do
          {:ok, doc} ->
            case ConditionalHeaders.evaluate(headers, doc["_etag"]) do
              :proceed ->
                lsn = current_lsn(db, coll)
                {:ok, 200, success_headers(db, coll, lsn, %{"etag" => doc["_etag"]}), doc}

              {:halt, 304} ->
                lsn = current_lsn(db, coll)
                {:ok, 304, success_headers(db, coll, lsn, %{"etag" => doc["_etag"]}), %{}}

              {:halt, 412} ->
                error_response(db, coll, 412, "PreconditionFailed", precondition_message())
            end

          :error ->
            error_response(
              db,
              coll,
              404,
              "NotFound",
              "Entity with the specified id does not exist in the system."
            )
        end
      else
        {:error, :store_not_ready}
      end
    end)
  end

  @doc """
  PUT /dbs/:db/colls/:coll/docs/:doc_id — replace.

  When If-Match is present, the etag check AND the write run as ONE atomic
  `Store.compare_and_swap/4` on the stored doc record: lookup+insert is
  serialized inside the Store GenServer, so concurrent replacers observe
  exactly one 200 and everyone else 412 — lost updates are structurally
  impossible. On `{:error, :conflict}` → 412 PreconditionFailed.

  The write path without If-Match stays direct (last-writer-wins) but still
  bumps the LSN via the durable `Store.update_counter/3`.
  """
  def put_doc(db, coll, doc_id, body, headers) when is_map(body) do
    gate(:put, "docs", doc_link(db, coll, doc_id), headers, fn ->
      if store_ready?() do
        do_put_doc(db, coll, doc_id, body, headers)
      else
        {:error, :store_not_ready}
      end
    end)
  end

  defp do_put_doc(db, coll, doc_id, body, headers) do
    pk_meta = container_meta(db, coll)
    key = doc_key(db, coll, doc_id)

    case Store.get(@docs_table, key) do
      {:ok, existing} ->
        with :ok <- doc_id_check(doc_id),
             :ok <- partition_check(headers, body, pk_meta),
             :ok <- unique_key_gate(db, coll, body, doc_id) do
          if_match = header(headers, "if-match")
          # R59/A18: version+nonce-bound etag (see do_create_doc_sized).
          new_v = Map.get(existing, "_v", 1) + 1
          new_gen = Map.get(existing, "_gen", doc_gen_nonce())
          new_etag = doc_etag(body_hash_hex(body), new_v, new_gen)
          now = System.system_time(:second)

          # R118/D17: replace, not merge — the stored doc IS the request body.
          # Map.merge(existing, body) retained fields the client removed from
          # body (stale top-level keys leaked across replaces). Only system
          # fields are carried forward (its _rid/_self identity + fresh
          # _v/_gen/_etag/_ts below).
          updated =
            body
            |> Map.put("id", doc_id)
            |> Map.put("_rid", existing["_rid"])
            |> Map.put("_self", existing["_self"])
            |> Map.delete("_etag")
            |> Map.put("_v", new_v)
            |> Map.put("_gen", new_gen)
            |> Map.put("_etag", new_etag)
            |> Map.put("_ts", now)

          cond do
            if_match == nil ->
              # No If-Match: direct last-writer-wins write; LSN still bumped.
              Store.put(@docs_table, key, updated)
              lsn = next_lsn(db, coll)
              {:ok, 200, success_headers(db, coll, lsn, %{"etag" => new_etag}), updated}

            ConditionalHeaders.evaluate(headers, existing["_etag"]) == :proceed ->
              # Atomic check+write: CAS keyed on the CURRENT STORED RECORD.
              case Store.compare_and_swap(@docs_table, key, existing, updated) do
                :ok ->
                  lsn = next_lsn(db, coll)
                  {:ok, 200, success_headers(db, coll, lsn, %{"etag" => new_etag}), updated}

                {:error, :conflict} ->
                  error_response(db, coll, 412, "PreconditionFailed", precondition_message())
              end

            true ->
              error_response(db, coll, 412, "PreconditionFailed", precondition_message())
          end
        else
          {:error, status, code} ->
            error_response(db, coll, status, code, error_message(code, pk_meta))
        end

      :error ->
        error_response(
          db,
          coll,
          404,
          "NotFound",
          "Entity with the specified id does not exist in the system."
        )
    end
  end

  # ---------------------------------------------------------------------------
  # Patch (GAP-AUD1-05): PATCH /dbs/:db/colls/:coll/docs/:id, RFC 6902
  # ---------------------------------------------------------------------------

  @doc """
  PATCH /dbs/:db/colls/:coll/docs/:doc_id — RFC 6902 patch on the doc body.

  `ops` is the decoded RFC 6902 op list (add/remove/replace/test/move/copy).
  With If-Match the etag check and the write run as ONE
  `Store.compare_and_swap/4` (same S8 guarantee as the replace path): 412 on
  mismatch or a same-doc race. Malformed op list → typed 400. Missing doc →
  404. The patched doc is re-stored whole with a fresh _etag/_ts and the
  container LSN bumped.
  """
  def patch_doc(db, coll, doc_id, ops, headers) when is_list(ops) do
    gate(:patch, "docs", doc_link(db, coll, doc_id), headers, fn ->
      if store_ready?() do
        do_patch_doc(db, coll, doc_id, ops, headers)
      else
        {:error, :store_not_ready}
      end
    end)
  end

  defp do_patch_doc(db, coll, doc_id, ops, headers) do
    key = doc_key(db, coll, doc_id)

    case Store.get(@docs_table, key) do
      {:ok, existing} ->
        with :ok <- doc_id_check(doc_id),
             pk_meta = container_meta(db, coll),
             {:ok, patched_body} <- apply_patch_ops(existing, ops),
             :ok <- partition_check(headers, patched_body, pk_meta),
             :ok <- unique_key_gate(db, coll, patched_body, doc_id) do
          # R10 fix: PATCH now runs the same admission gates as PUT —
          # partition_check + unique_key_gate applied to the PATCHED body
          # (mirroring do_put_doc/5). A patch that moves the doc across
          # partitions without the pk header is a typed 400; a patch that
          # violates the uniqueKeyPolicy is a 409. Refused before any write.
          # KD-COVERS: KD-52
          if_match = header(headers, "if-match")
          # R59/A18: version+nonce-bound etag (see do_create_doc_sized).
          # R134: the etag is a pure function of the FINAL stored body — build
          # the patched body with system fields applied first, then hash it
          # (sans the volatile _etag itself and the wall-clock _ts). Hashing
          # the pre-system-field body let the etag depend on stale _v/_gen/
          # _etag values from the OLD record.
          new_v = Map.get(existing, "_v", 1) + 1
          new_gen = Map.get(existing, "_gen", doc_gen_nonce())
          now = System.system_time(:second)

          patched =
            patched_body
            |> Map.put("id", doc_id)
            |> Map.put("_rid", existing["_rid"])
            |> Map.put("_self", existing["_self"])
            |> Map.put("_v", new_v)
            |> Map.put("_gen", new_gen)

          new_etag =
            doc_etag(
              patched |> Map.delete("_etag") |> Map.delete("_ts") |> body_hash_hex(),
              new_v,
              new_gen
            )

          updated = Map.put(patched, "_etag", new_etag) |> Map.put("_ts", now)

          cond do
            if_match == nil ->
              Store.put(@docs_table, key, updated)
              lsn = next_lsn(db, coll)
              {:ok, 200, success_headers(db, coll, lsn, %{"etag" => new_etag}), updated}

            ConditionalHeaders.evaluate(headers, existing["_etag"]) == :proceed ->
              case Store.compare_and_swap(@docs_table, key, existing, updated) do
                :ok ->
                  lsn = next_lsn(db, coll)
                  {:ok, 200, success_headers(db, coll, lsn, %{"etag" => new_etag}), updated}

                {:error, :conflict} ->
                  error_response(db, coll, 412, "PreconditionFailed", precondition_message())
              end

            true ->
              error_response(db, coll, 412, "PreconditionFailed", precondition_message())
          end
        else
          {:error, :malformed} ->
            error_response(db, coll, 400, "BadRequest", "The patch document is invalid.")

          {:error, :test_failed} ->
            error_response(db, coll, 400, "BadRequest", "A test operation of the patch failed.")

          {:error, status, code} ->
            error_response(db, coll, status, code, error_message(code, container_meta(db, coll)))
        end

      :error ->
        error_response(
          db,
          coll,
          404,
          "NotFound",
          "Entity with the specified id does not exist in the system."
        )
    end
  end

  # RFC 6902 application over the stored document. Any structural defect
  # (non-map op, missing/unknown op field, bad pointer, remove of a nonexistent
  # member, failed test) aborts with {:error, :malformed} / {:error,
  # :test_failed}; the stored doc is never mutated.
  defp apply_patch_ops(doc, ops) do
    Enum.reduce_while(ops, {:ok, doc}, fn op, {:ok, acc} ->
      case apply_patch_op(acc, op) do
        {:ok, next} -> {:cont, {:ok, next}}
        err -> {:halt, err}
      end
    end)
  end

  defp apply_patch_op(target, %{"op" => op, "path" => path} = spec)
       when op in ["add", "remove", "replace", "test"] and is_binary(path) do
    value = Map.get(spec, "value")

    case op do
      "add" -> pointer_add(target, path, value)
      "remove" -> pointer_remove(target, path)
      "replace" -> pointer_replace(target, path, value)
      "test" -> pointer_test(target, path, value)
    end
  end

  defp apply_patch_op(target, %{"op" => "move", "from" => from, "path" => path})
       when is_binary(from) and is_binary(path) do
    with {:ok, v} <- pointer_get(target, from),
         {:ok, without} <- pointer_remove(target, from) do
      pointer_add(without, path, v)
    end
  end

  defp apply_patch_op(target, %{"op" => "copy", "from" => from, "path" => path})
       when is_binary(from) and is_binary(path) do
    with {:ok, v} <- pointer_get(target, from) do
      pointer_add(target, path, v)
    end
  end

  defp apply_patch_op(_target, _op), do: {:error, :malformed}

  # --- JSON pointer (RFC 6901) ---

  # "" -> whole document. "~1" -> "/", "~0" -> "~".
  defp pointer_tokens(""), do: []

  defp pointer_tokens(pointer) do
    if String.starts_with?(pointer, "/") do
      pointer
      |> String.split("/")
      |> tl()
      |> Enum.map(&unescape_token/1)
    else
      # RFC 6901: a pointer is "" or starts with "/".
      :error
    end
  end

  defp unescape_token(token), do: token |> String.replace("~1", "/") |> String.replace("~0", "~")

  defp pointer_get(target, pointer) do
    case pointer_tokens(pointer) do
      tokens when is_list(tokens) -> do_pointer_get(target, tokens)
      :error -> {:error, :malformed}
    end
  end

  defp do_pointer_get(target, []), do: {:ok, target}

  defp do_pointer_get(target, [token | rest]) when is_map(target) do
    case Map.fetch(target, token) do
      {:ok, v} -> do_pointer_get(v, rest)
      :error -> {:error, :malformed}
    end
  end

  defp do_pointer_get(target, [token | rest]) when is_list(target) do
    case Integer.parse(token) do
      {idx, ""} when idx >= 0 ->
        case Enum.fetch(target, idx) do
          {:ok, v} -> do_pointer_get(v, rest)
          :error -> {:error, :malformed}
        end

      # "-" is append-only; reading through "-" is malformed.
      _ ->
        {:error, :malformed}
    end
  end

  defp do_pointer_get(_target, [_token | _rest]), do: {:error, :malformed}

  # add "" -> replace the whole document.
  defp pointer_add(target, "", value) when is_map(target), do: {:ok, value}

  defp pointer_add(target, pointer, value) do
    case pointer_tokens(pointer) do
      tokens when is_list(tokens) -> do_pointer_add(target, tokens, value)
      :error -> {:error, :malformed}
    end
  end

  defp do_pointer_add(_target, [], _value), do: {:error, :malformed}

  defp do_pointer_add(target, [token], value) when is_map(target),
    do: {:ok, Map.put(target, token, value)}

  defp do_pointer_add(target, [token], value) when is_list(target) do
    cond do
      token == "-" ->
        {:ok, target ++ [value]}

      idx_before?(token, length(target) + 1) ->
        {:ok, List.insert_at(target, String.to_integer(token), value)}

      true ->
        {:error, :malformed}
    end
  end

  defp do_pointer_add(target, [token | rest], value) do
    case descend_for_write(target, token) do
      {:ok, child, wrap} ->
        case do_pointer_add(child, rest, value) do
          {:ok, child2} -> {:ok, wrap.(child2)}
          err -> err
        end

      err ->
        err
    end
  end

  defp pointer_replace(target, pointer, value) do
    case pointer_tokens(pointer) do
      tokens when is_list(tokens) -> do_pointer_replace(target, tokens, value)
      :error -> {:error, :malformed}
    end
  end

  defp do_pointer_replace(_target, [], _value), do: {:error, :malformed}

  # replace requires the member to EXIST (RFC 6902 §4.3).
  defp do_pointer_replace(target, [token], value) when is_map(target) do
    if Map.has_key?(target, token) do
      {:ok, Map.put(target, token, value)}
    else
      {:error, :malformed}
    end
  end

  defp do_pointer_replace(target, [token], value) when is_list(target) do
    if idx_before?(token, length(target)) do
      {:ok, List.replace_at(target, String.to_integer(token), value)}
    else
      {:error, :malformed}
    end
  end

  defp do_pointer_replace(target, [token | rest], value) do
    case descend_for_write(target, token) do
      {:ok, child, wrap} ->
        case do_pointer_replace(child, rest, value) do
          {:ok, child2} -> {:ok, wrap.(child2)}
          err -> err
        end

      err ->
        err
    end
  end

  # remove requires the member to exist; root remove is refused (the store
  # holds whole docs — a root remove would destroy the id/_rid/_self envelope).
  defp pointer_remove(target, pointer) do
    case pointer_tokens(pointer) do
      tokens when is_list(tokens) and tokens != [] -> do_pointer_remove(target, tokens)
      _ -> {:error, :malformed}
    end
  end

  defp do_pointer_remove(target, [token]) when is_map(target) do
    if Map.has_key?(target, token) do
      {:ok, Map.delete(target, token)}
    else
      {:error, :malformed}
    end
  end

  defp do_pointer_remove(_target, ["-"]), do: {:error, :malformed}

  defp do_pointer_remove(target, [token]) when is_list(target) do
    if idx_before?(token, length(target)) do
      {:ok, List.delete_at(target, String.to_integer(token))}
    else
      {:error, :malformed}
    end
  end

  defp do_pointer_remove(target, [token | rest]) do
    case descend_for_write(target, token) do
      {:ok, child, wrap} ->
        case do_pointer_remove(child, rest) do
          {:ok, child2} -> {:ok, wrap.(child2)}
          err -> err
        end

      err ->
        err
    end
  end

  defp pointer_test(target, pointer, value) do
    case pointer_get(target, pointer) do
      {:ok, ^value} -> {:ok, target}
      {:ok, _} -> {:error, :test_failed}
      err -> err
    end
  end

  # Walk one level for a write op: return the child container and a wrapper
  # that rebuilds the parent. The parent must already exist; only the FINAL
  # member of a pointer is created by add.
  defp descend_for_write(target, token) when is_map(target) do
    case Map.fetch(target, token) do
      {:ok, child} -> {:ok, child, fn child2 -> Map.put(target, token, child2) end}
      :error -> {:error, :malformed}
    end
  end

  defp descend_for_write(target, token) when is_list(target) do
    if idx_before?(token, length(target)) do
      child = Enum.fetch!(target, String.to_integer(token))
      {:ok, child, fn child2 -> List.replace_at(target, String.to_integer(token), child2) end}
    else
      {:error, :malformed}
    end
  end

  defp descend_for_write(_target, _token), do: {:error, :malformed}

  # index valid for a container of the given length (exclusive bound).
  defp idx_before?(token, bound) do
    case Integer.parse(token) do
      {idx, ""} -> idx >= 0 and idx < bound
      _ -> false
    end
  end

  @doc """
  DELETE /dbs/:db/colls/:coll/docs/:doc_id — delete.
  Real Cosmos semantics: WITHOUT If-Match the delete is unconditional
  (204 + request-charge headers). WITH If-Match the delete is conditional:
  match → 204, mismatch → 412. Missing doc → 404 either way.
  """
  def delete_doc(db, coll, doc_id, headers) do
    gate(:delete, "docs", doc_link(db, coll, doc_id), headers, fn ->
      if store_ready?() do
        do_delete_doc(db, coll, doc_id, headers)
      else
        {:error, :store_not_ready}
      end
    end)
  end

  defp do_delete_doc(db, coll, doc_id, headers) do
    case Store.get(@docs_table, doc_key(db, coll, doc_id)) do
      {:ok, doc} ->
        if header(headers, "if-match") == nil do
          # No If-Match: unconditional delete (real Cosmos semantics).
          Store.delete(@docs_table, doc_key(db, coll, doc_id))
          lsn = next_lsn(db, coll)
          {:ok, 204, success_headers(db, coll, lsn, %{}), ""}
        else
          case ConditionalHeaders.evaluate(headers, doc["_etag"]) do
            :proceed ->
              # Atomic check+delete: same S8 guarantee as the If-Match replace
              # path — N concurrent conditional deletes on one doc yield
              # exactly one 204, the rest 412 (never two 204s from a
              # read-check-delete window).
              case Store.compare_and_swap_delete(@docs_table, doc_key(db, coll, doc_id), doc) do
                :ok ->
                  lsn = next_lsn(db, coll)
                  {:ok, 204, success_headers(db, coll, lsn, %{}), ""}

                {:error, :conflict} ->
                  error_response(db, coll, 412, "PreconditionFailed", precondition_message())
              end

            _halted ->
              error_response(db, coll, 412, "PreconditionFailed", precondition_message())
          end
        end

      :error ->
        error_response(
          db,
          coll,
          404,
          "NotFound",
          "Entity with the specified id does not exist in the system."
        )
    end
  end

  # ---------------------------------------------------------------------------
  # Change Feed (GAP-AUD1-04): A-IM: Incremental feed on the docs GET
  # ---------------------------------------------------------------------------

  # Cursor record stored per container in the pk_meta table under {2, db, coll}
  # (tuple keys sort above every binary key, so the change-feed cursor is
  # invisible to Store.list_prefix/2 binary scans, exactly like the {0, db}
  # and {1, db, coll} meta records).

  @doc """
  GET /dbs/:db/colls/:coll/docs with `A-IM: Incremental feed` — Cosmos Change
  Feed. Returns only docs whose `_ts` is newer than the container's last-seen
  cursor (per-partition cursor persisted in the pk_meta table), then advances
  the cursor. Without the header, list_docs behavior is unchanged.
  """
  def change_feed(db, coll, headers \\ %{}) do
    gate(:get, "docs", container_link(db, coll), headers, fn ->
      if store_ready?() do
        do_change_feed(db, coll)
      else
        {:error, :store_not_ready}
      end
    end)
  end

  defp do_change_feed(db, coll) do
    cursor_key = {2, db, coll}
    cursor = cf_cursor(cursor_key)

    docs =
      @docs_table
      |> Store.list_prefix("#{db}/#{coll}/")
      |> Enum.filter(fn d -> cf_is_new?(d, cursor) end)
      |> Enum.sort_by(&{&1["_ts"] || 0, &1["id"]})

    new_cursor = cf_advance(cursor, docs)
    :ets.insert(@pk_meta_table, {cursor_key, new_cursor})

    lsn = current_lsn(db, coll)

    {:ok, 200, success_headers(db, coll, lsn, %{@continuation_header => cf_token(new_cursor)}),
     %{
       "_rid" => coll_rid(db, coll),
       "Documents" => docs,
       "_count" => length(docs)
     }}
  end

  defp cf_cursor(cursor_key) do
    case :ets.lookup(@pk_meta_table, cursor_key) do
      [{^cursor_key, %{"ts" => ts, "seen" => seen}}]
      when is_integer(ts) and is_map(seen) ->
        # Cursor "seen" is a map of id => _etag pinned at the boundary second:
        # a same-second UPDATE changes the doc's _etag, so it re-surfaces once
        # instead of being swallowed by the seen-set.
        %{"ts" => ts, "seen" => seen}

      _ ->
        %{"ts" => 0, "seen" => %{}}
    end
  end

  # A doc is new when its _ts is strictly newer than the cursor ts, or when it
  # shares the boundary second and its CURRENT _etag was never returned on that
  # boundary before (so a same-second UPDATE re-surfaces exactly once).
  defp cf_is_new?(doc, cursor) do
    ts = doc["_ts"] || 0

    ts > cursor["ts"] or
      (ts == cursor["ts"] and cursor["seen"][doc["id"]] != doc["_etag"])
  end

  # The advanced cursor pins id => _etag for every doc at the boundary second,
  # MERGED with the previous cursor's pins at the same boundary — so each doc
  # version is delivered exactly once even though _ts resolution is 1s.
  defp cf_advance(cursor, []), do: cursor

  defp cf_advance(cursor, docs) do
    max_ts = docs |> Enum.map(&(&1["_ts"] || 0)) |> Enum.max()

    seen =
      docs
      |> Enum.filter(&(&1["_ts"] == max_ts))
      |> Map.new(&{&1["id"], &1["_etag"]})

    seen =
      if cursor["ts"] == max_ts do
        Map.merge(cursor["seen"], seen)
      else
        seen
      end

    %{"ts" => max_ts, "seen" => seen}
  end

  # Continuation token for the change feed: opaque base64url of "cf<ts>:<n>"
  # (n = number of boundary ids pinned). Delivered on every feed response so
  # the client can carry it; incrementality itself is session (cursor) state.
  defp cf_token(%{"ts" => ts, "seen" => seen}) do
    Base.url_encode64("cf#{ts}:#{map_size(seen)}", padding: false)
  end

  @doc """
  Lists documents in a collection by id prefix. Returns `{:ok, 200, headers, docs}`.

  With `A-IM: Incremental feed`, behaves as the Cosmos Change Feed
  (GAP-AUD1-04): only docs newer than the session's per-container cursor are
  returned and the cursor advances; without the header behavior is unchanged.
  """
  def list_docs(db, coll, prefix \\ "", headers \\ %{}) do
    gate(:get, "docs", container_link(db, coll), headers, fn ->
      if store_ready?() do
        if cf_requested?(headers) do
          do_change_feed(db, coll)
        else
          do_list_docs(db, coll, scope(prefix), headers)
        end
      else
        {:error, :store_not_ready}
      end
    end)
  end

  defp cf_requested?(headers) do
    case header(headers, "a-im") do
      v when is_binary(v) -> String.contains?(String.downcase(v), "incremental feed")
      _ -> false
    end
  end

  defp do_list_docs(db, coll, prefix, headers) do
    # nil prefix is the same feed as "" (token namespace must not mint
    # "nil/<id>" tails a nil-prefix resume could never consume).
    prefix = scope(prefix)
    lsn = current_lsn(db, coll)
    cont_hdr = header(headers, @continuation_header)

    with :ok <- parse_list_continuation(cont_hdr, prefix, lsn, db, coll) do
      docs =
        @docs_table
        |> Store.list_prefix("#{db}/#{coll}/#{prefix}")
        |> Enum.sort_by(& &1["id"])

      # Same ORDER-based (deletion-safe) cursor as the query feed: the token
      # encodes the last id of the previous page, so deleting that doc
      # mid-resume cannot skip or stall the feed (row-18 contract).
      docs =
        case list_cursor(cont_hdr) do
          {:ok, _b64c, _tok_prefix, last_id} ->
            Enum.drop_while(docs, fn d -> d["id"] <= last_id end)

          :none ->
            docs
        end

      page = Enum.take(docs, @query_limit)

      extra =
        if length(docs) > @query_limit do
          %{@continuation_header => list_continuation_token(db, coll, prefix, lsn, page)}
        else
          %{}
        end

      {:ok, 200, success_headers(db, coll, lsn, extra), page}
    else
      {:error, 400, "BadRequest"} ->
        error_response(db, coll, 400, "BadRequest", "The continuation token is invalid.")
    end
  end

  @doc """
  POST /dbs/:db/colls/:coll/docs with content-type application/query+json.

  NO SQL engine: when a partition-key header is present the result is the
  documents of THAT partition (honest limit #{@query_limit}); without a pk
  header the whole container is scanned (cross-partition). The response is the
  SDK wire shape `{"_rid", "Documents", "_count"}`. A query POST NEVER creates
  a document — the router routes it here before any create path is reachable.
  """
  def query_docs(db, coll, body, headers) do
    gate(:post, "docs", container_link(db, coll), headers, fn ->
      if store_ready?() do
        # Real Cosmos: a query POST must carry a query document — a body
        # without a nonblank "query" string is 400 BadRequest (row 8).
        q = query_text(body)

        if is_binary(q) do
          do_query_docs(db, coll, q, body, headers)
        else
          error_response(db, coll, 400, "BadRequest", "The query is invalid.")
        end
      else
        {:error, :store_not_ready}
      end
    end)
  end

  # Nonblank "query" string -> the trimmed text; anything else -> nil (400).
  defp query_text(body) when is_map(body) do
    case Map.get(body, "query") do
      q when is_binary(q) ->
        case String.trim(q) do
          "" -> nil
          trimmed -> trimmed
        end

      _ ->
        nil
    end
  end

  defp query_text(_body), do: nil

  # GAP(cosmos-sql-translator-absent) whitelist gate (work order V261014-07
  # item 5, option (a)): only the trivial `SELECT * FROM <alias>` form is
  # admitted to the partition scan; any other nonblank query answers a typed
  # 400 SyntaxError like real Cosmos — the emulator no longer answers queries
  # it did not evaluate. The gap label stays: the whitelist narrows the lie,
  # it does not close the gap.
  @sql_whitelist ~r/^select\s+\*\s+from\s+[A-Za-z_][A-Za-z0-9_]*$/i

  defp sql_whitelisted?(q), do: Regex.match?(@sql_whitelist, String.trim(q))

  # Minimal unblock (test-isolation lane 01, compile-freeze SLA): the in-flight
  # V261014-07 edit renamed the scan to scan_query_docs/3 and updated the call
  # site to pass `q`, but left do_query_docs/4 undefined. This wiring completes
  # that rename; the owning lane may fold it into its own implementation.
  # GAP(cosmos-sql-translator-absent) closure (lane 523): the whitelist stays
  # as the `SELECT * FROM c` fast path; every other query is parsed by
  # Smalt.CosmosSql (80/20 AST: SELECT/FROM/WHERE/ORDER BY/LIMIT, comparisons,
  # AND/OR/NOT, IN, CONTAINS/STARTSWITH/ARRAY_CONTAINS, @params, nested member
  # access) and evaluated over the scanned set. Anything outside the grammar
  # (joins, UDFs, aggregates, TOP, OFFSET) is a typed 400 SyntaxError,
  # fail-closed — never a silent wrong answer.
  defp do_query_docs(db, coll, q, body, headers) do
    if sql_whitelisted?(q) do
      scan_query_docs(db, coll, headers)
    else
      case Smalt.CosmosSql.parse(q, query_params(body)) do
        {:error, {:syntax, msg}} ->
          error_response(db, coll, 400, "SyntaxError", msg)

        # Parsed-but-not-implemented surface (cross-array iteration): typed
        # 400 InvalidQuery, fail-closed — never a silent wrong answer.
        {:error, {:unsupported, msg}} ->
          error_response(db, coll, 400, "InvalidQuery", msg)

        {:ok, ast} ->
          scan_query_docs(db, coll, headers, ast)
      end
    end
  end

  # Query-body "parameters": [{"name": "@x", "value": v}, ...] -> %{"@x" => v}
  # (with or without the @ prefix; Cosmos binds by name). Malformed entries are
  # ignored — an unbound @ref surfaces as a typed 400 at parse time.
  defp query_params(body) when is_map(body) do
    case Map.get(body, "parameters") do
      list when is_list(list) ->
        Enum.reduce(list, %{}, fn
          %{"name" => name, "value" => value}, acc when is_binary(name) ->
            Map.put(acc, String.trim_leading(name, "@"), value)

          _entry, acc ->
            acc
        end)

      _ ->
        %{}
    end
  end

  defp query_params(_body), do: %{}

  defp scan_query_docs(db, coll, headers, sql \\ nil) do
    pk_meta = container_meta(db, coll)
    paths = (pk_meta && Map.get(pk_meta, "paths", [])) || []
    pk_hdr = header(headers, PartitionKey.header_name())
    ledger = current_lsn(db, coll)

    # Hoisted above the `with`: the scan body below needs `docs`, and the
    # fetch must not depend on continuation/pk-header validation outcomes.
    docs =
      @docs_table
      |> Store.list_prefix("#{db}/#{coll}/")
      |> Enum.sort_by(& &1["id"])

    with :ok <-
           parse_continuation(header(headers, @continuation_header), pk_hdr, ledger, db, coll),
         :ok <- query_pk_check(pk_hdr, paths) do
      docs =
        if paths == [] do
          # No partition key defined: every partition (header ignored).
          docs
        else
          # Header present and parseable: partition-scoped. (A PRESENT but
          # malformed header is a 400 below — never a silent cross-partition
          # scan; previously "not-json"/"[]"/multi-element headers leaked ALL
          # partitions' docs with 200.)
          case pk_hdr do
            nil ->
              # No pk header: deliberate cross-partition scan.
              docs

            raw ->
              case PartitionKey.parse(raw) do
                {:ok, pk} -> Enum.filter(docs, fn d -> PartitionKey.extract(d, paths) == pk end)
                :error -> docs
              end
          end
        end

      # Continuation cursor: an ORDER-based resume (id > last_id), NOT an
      # existence-based one — the token encodes the last id of the previous
      # page, so deleting that doc mid-resume cannot skip or stall the feed
      # (row 18 contract pin).
      docs =
        case list_cursor(header(headers, @continuation_header)) do
          {:ok, _b64c, _scope, last_id} -> Enum.drop_while(docs, fn d -> d["id"] <= last_id end)
          :none -> docs
        end

      # GAP(cosmos-sql-translator-absent) closure (lane 523): evaluate the
      # parsed Smalt.CosmosSql AST over the scoped set (filter + ORDER BY +
      # LIMIT + projection). The whitelist fast path passes sql = nil and
      # keeps the raw scan.
      docs = if sql, do: Smalt.CosmosSql.eval_docs(sql, docs), else: docs

      page = Enum.take(docs, @query_limit)

      # Real Cosmos row-18 semantics: a token rides the response ONLY when the
      # feed is truncated — the last page carries none, so the SDK loop
      # terminates.
      extra =
        if length(docs) > @query_limit do
          %{@continuation_header => continuation_token(db, coll, pk_hdr, ledger, page)}
        else
          %{}
        end

      lsn = current_lsn(db, coll)

      {:ok, 200, success_headers(db, coll, lsn, extra),
       %{
         "_rid" => coll_rid(db, coll),
         "Documents" => page,
         "_count" => length(page)
       }}
    else
      # SHIM-COURT parity with the list feed (:1116): the only 400 BadRequest
      # shapes reachable in this `with` come from parse_continuation/4 (expired/
      # foreign/undecodable token) or query_pk_check/3 (malformed pk header
      # token scope) — never a partition-key mismatch, so the generic
      # error_message("BadRequest", _) "Partition key provided in the header…"
      # text here was misleading. Reuse the list path's dedicated typed message.
      {:error, 400, "BadRequest"} ->
        error_response(db, coll, 400, "BadRequest", "The continuation token is invalid.")

      {:error, status, code} ->
        error_response(db, coll, status, code, error_message(code, pk_meta))
    end
  end

  # ---------------------------------------------------------------------------
  # Feed continuation tokens (row 18: x-ms-continuation)
  # ---------------------------------------------------------------------------

  # Format (engine work order lens-2 c5; scope binding lens-5; container
  # binding lens-6): the query-feed token is "1#{lsn}:{b64c}:{tail}" where
  # b64c = base64url("db/coll") binds the token to the FEED'S CONTAINER and
  # tail = last_id for an UNSCOPED feed and "<pk_raw>/<last_id>" when the feed
  # was scoped by a partition-key header. The token's scope AND container must
  # EQUAL the resume request's, else typed 400 — real Cosmos binds a token to
  # its query/feed; a cross-partition page resumed under a different partition
  # SILENTLY DROPS docs (measured lens-5), and a token minted on one container
  # resumed on another ALSO silently narrows the second container's feed
  # (measured lens-6: token "2#105:n100" from A resumed on B returned 5 of
  # 105 B docs with 200). b64url has no ":" or "/", so the split is exact.
  defp continuation_token(db, coll, _scope, lsn, []),
    do: "#{@session_token_version}##{lsn}:#{token_container(db, coll)}:"

  defp continuation_token(db, coll, scope, lsn, page) do
    tail = List.last(page)["id"]
    tail = if scope in [nil, ""], do: tail, else: "#{scope}/#{tail}"
    "#{@session_token_version}##{lsn}:#{token_container(db, coll)}:#{tail}"
  end

  # nil header = no resume. The token's embedded container AND scope must
  # equal the request's (scope both "" when absent).
  defp parse_continuation(nil, _scope, _ledger, _db, _coll), do: :ok

  defp parse_continuation(raw, scope, ledger, db, coll) do
    case list_cursor(raw) do
      {:ok, b64c, tok_scope, last_id} ->
        if continuation_lsn_ok_version?(raw, @session_token_version, ledger) and
             b64c == token_container(db, coll) and
             tok_scope == scope(scope) and
             valid_doc_id?(last_id) do
          :ok
        else
          {:error, 400, "BadRequest"}
        end

      :none ->
        {:error, 400, "BadRequest"}
    end
  end

  defp scope(nil), do: ""
  defp scope(s), do: s

  defp integer_lsn?(s), do: s != "" and String.match?(s, ~r/^\d+$/)

  # ---------------------------------------------------------------------------
  # List-feed continuation tokens (version-2 namespace, never cross-accepted
  # with query tokens)
  # ---------------------------------------------------------------------------

  # Format (lens-5 prefix binding; lens-6 container binding): "2#{lsn}:{b64c}:{tail}"
  # where b64c = base64url("db/coll") binds the token to its container and
  # tail = last_id when the prefix is empty, otherwise "<prefix>/<last_id>"
  # (doc ids never contain "/", so the split is exact). A token minted under
  # one prefix (or one CONTAINER) resumed under a DIFFERENT one is a typed
  # 400 — real Cosmos binds a continuation token to the query that emitted it
  # and 400s on cross-filter/cross-container reuse (learn.microsoft.com Cosmos
  # DB query/pagination; SO 52108370).
  defp list_continuation_token(db, coll, _prefix, lsn, []),
    do: "#{@list_token_version}##{lsn}:#{token_container(db, coll)}:"

  defp list_continuation_token(db, coll, prefix, lsn, page) do
    tail = List.last(page)["id"]
    tail = if prefix == "", do: tail, else: "#{prefix}/#{tail}"
    "#{@list_token_version}##{lsn}:#{token_container(db, coll)}:#{tail}"
  end

  # Same fences as the query token gate: version-2 namespace only, numeric
  # ledger position not ahead of this container's ledger, doc-id-grammar
  # cursor, and the token's container/prefix must EQUAL the request's (real
  # Cosmos: a token is only valid for the feed that emitted it). nil header =
  # no resume; anything else malformed is a typed 400.
  defp parse_list_continuation(nil, _prefix, _ledger, _db, _coll), do: :ok

  defp parse_list_continuation(raw, prefix, ledger, db, coll) do
    case list_cursor(raw) do
      {:ok, b64c, tok_prefix, last_id} ->
        if continuation_lsn_ok_version?(raw, @list_token_version, ledger) and
             b64c == token_container(db, coll) and
             tok_prefix == prefix and valid_doc_id?(last_id) do
          :ok
        else
          {:error, 400, "BadRequest"}
        end

      :none ->
        {:error, 400, "BadRequest"}
    end
  end

  # {:ok, b64c, scope, last_id} | :none — nil header is :none; the tail must
  # carry "<b64url(db/coll)>:<scope_or_prefix>/<last_id>".
  defp list_cursor(nil), do: :none

  defp list_cursor(raw) do
    with [_vsn_lsn, tail] <- String.split(raw, ":", parts: 2),
         [b64c, rest] <- String.split(tail, ":", parts: 2),
         {tok_scope, last_id} <- split_list_tail(rest) do
      {:ok, b64c, tok_scope, last_id}
    else
      _ -> :none
    end
  end

  # Split the tail at the LAST "/": last_id never contains "/", the prefix
  # may. {"", "d1"} for the empty-prefix form; :error when the tail is empty.
  defp split_list_tail(""), do: :error

  defp split_list_tail(tail) do
    case String.split(tail, "/") do
      parts ->
        last_id = List.last(parts)
        tok_prefix = parts |> :lists.sublist(1, length(parts) - 1) |> Enum.join("/")

        {tok_prefix, last_id}
    end
  end

  # Container segment of a continuation token: base64url("db/coll") — the
  # url-safe alphabet has no ":" or "/", so the token split stays exact.
  defp token_container(db, coll), do: Base.url_encode64("#{db}/#{coll}", padding: false)

  # Shared token grammar check, parameterized on the namespace version so the
  # query (v1) and list (v2) gates can never admit each other's tokens.
  defp continuation_lsn_ok_version?(raw, version, ledger) do
    case String.split(raw, ":", parts: 2) do
      [vsn_lsn, _last_id] ->
        case String.split(vsn_lsn, "#", parts: 2) do
          [vsn, lsn] ->
            vsn == Integer.to_string(version) and integer_lsn?(lsn) and
              String.to_integer(lsn) <= ledger

          _ ->
            false
        end

      _ ->
        false
    end
  end

  # A PRESENT but malformed pk header on a pk-defined container is a 400 —
  # never a silent cross-partition scan (measured leak: "not-json" returned
  # both partitions' docs with 200).
  defp query_pk_check(nil, _paths), do: :ok
  defp query_pk_check(_hdr, []), do: :ok

  defp query_pk_check(hdr, _paths) do
    case PartitionKey.parse(hdr) do
      {:ok, _pk} -> :ok
      :error -> {:error, 400, "BadRequest"}
    end
  end

  # ---------------------------------------------------------------------------
  # Request gate: master-key Authorization validation + RU throttle + echo
  # ---------------------------------------------------------------------------

  # Wraps a doc-surface handler: (1) master-key Authorization validation in
  # :enforce auth_mode only (Bearer/anonymous paths untouched); (2) in-memory
  # fixed-window RU throttle per partition-route (container), active only when
  # Smalt.Config.cosmos_ru_limit/0 resolves a positive integer (env-first-int
  # SMALT_COSMOS_RU_LIMIT; default :infinity — behavior unchanged unless
  # configured); (3) x-ms-consistency-level echo.
  defp gate(verb, resource_type, resource_link, headers, fun) do
    with :ok <- authorize(verb, resource_type, resource_link, headers),
         :ok <- throttle(resource_link) do
      fun.() |> echo_consistency(headers)
    else
      {:halt, resp} -> resp
    end
  end

  # Real Cosmos string-to-sign: verb, resource type, resource link, date, then
  # two empty members. Sig is Base64(HMAC-SHA256(master_key, string-to-sign)).
  # Only consulted when auth_mode == :enforce AND :cosmos_master_key is set;
  # non-master Authorization schemes (Bearer) pass through untouched.
  defp authorize(verb, resource_type, resource_link, headers) do
    if Application.get_env(:smalt, :auth_mode) == :enforce do
      case master_key() do
        nil ->
          :ok

        key ->
          case header(headers, "authorization") do
            nil ->
              :ok

            raw ->
              case master_sig(raw) do
                nil ->
                  :ok

                sig ->
                  if valid_master_sig?(verb, resource_type, resource_link, headers, sig, key),
                    do: :ok,
                    else: {:halt, unauthorized()}
              end
          end
      end
    else
      :ok
    end
  end

  defp master_key do
    case Application.get_env(:smalt, :cosmos_master_key) do
      key when is_binary(key) and key != "" -> key
      _ -> nil
    end
  end

  # Authorization header wire form is URL-encoded:
  # "type%3dmaster%26ver%3d1.0%26sig%3d<base64>". Returns the sig or nil when
  # the header is not the master-key scheme.
  defp master_sig(raw) do
    case URI.decode_query(URI.decode(raw)) do
      %{"type" => "master", "sig" => sig} when is_binary(sig) and sig != "" -> sig
      _ -> nil
    end
  end

  defp valid_master_sig?(verb, resource_type, resource_link, headers, sig, key) do
    date = header(headers, "x-ms-date") || ""

    string_to_sign =
      "#{Atom.to_string(verb)}\n#{resource_type}\n#{resource_link}\n#{String.downcase(date)}\n\n"

    case Base.decode64(sig) do
      {:ok, provided} ->
        expected = :crypto.mac(:hmac, :sha256, key, string_to_sign)
        Plug.Crypto.secure_compare(provided, expected)

      :error ->
        false
    end
  end

  defp unauthorized do
    {:ok, 401, %{"x-ms-request-charge" => @request_charge},
     %{
       "code" => "Unauthorized",
       "message" =>
         "The input authorization token can't serve the request. Please check that the expected payload is built as per the documentation."
     }}
  end

  # Single resolution chain for the RU throttle limit:
  #   SMALT_COSMOS_RU_LIMIT (parsed int) > named throttle profile (:cosmos pk)
  #   > `:cosmos` profile kw `max_ru_limit` (AZB-06; :unbounded = no throttle)
  #   > flat app-env key :cosmos_ru_limit > :infinity.
  # Smalt.Config.cosmos_ru_limit/0 implements the first, second and last
  # layers; the former local Application.get_env reads here bypassed the env
  # and throttle-profile layers entirely.
  defp ru_limit do
    case Smalt.Config.cosmos_ru_limit() do
      :infinity ->
        # No env override and :unbounded throttle profile — honor the
        # `:cosmos` profile kw's explicit max_ru_limit (AZB-06) if present.
        case Smalt.Config.cosmos() do
          kw when is_list(kw) -> Keyword.get(kw, :max_ru_limit, :infinity)
          _ -> :infinity
        end

      limit ->
        limit
    end
  end

  # Fixed-window (1s) in-memory counter per partition-route. ETS table is
  # created lazily and left to die with the VM (in-memory by definition).
  defp throttle(route_key) do
    case ru_limit() do
      limit when limit in [:infinity, :unbounded] ->
        :ok

      limit when is_integer(limit) and limit > 0 ->
        key = {route_key, div(System.system_time(:millisecond), 1000)}
        count = :ets.update_counter(ru_table(), key, {2, 1}, {key, 0})

        if count > limit do
          {:halt, throttled()}
        else
          :ok
        end

      _ ->
        :ok
    end
  end

  defp ru_table do
    if :ets.info(:smalt_cosmos_ru) == :undefined do
      try do
        :ets.new(:smalt_cosmos_ru, [
          :named_table,
          :public,
          :set,
          {:read_concurrency, true},
          # Shadow-table law (see Smalt.Policy): the first creator can be a
          # Bandit request task — without an heir the table dies with that
          # request process, silently DISARMING the throttle (counters reset
          # to a fresh window every request). Heir to :init makes it
          # node-permanent; the ArgumentError rescue keeps the create race
          # fail-safe.
          {:heir, Process.whereis(:init), []}
        ])
      rescue
        ArgumentError -> :ok
      end
    end

    :smalt_cosmos_ru
  end

  defp throttled do
    {:ok, 429,
     %{
       "x-ms-request-charge" => @request_charge,
       "x-ms-retry-after-ms" => "1",
       "x-ms-lsn" => "0",
       "x-ms-session-token" => "#{@session_token_version}#0",
       "x-ms-alt-content-path" => ""
     },
     %{
       "code" => "TooManyRequests",
       "message" =>
         "Request rate is too large. More Request Charge is required than the provisioned amount."
     }}
  end

  defp echo_consistency({:ok, status, resp_headers, body}, headers) do
    case header(headers, "x-ms-consistency-level") do
      nil -> {:ok, status, resp_headers, body}
      level -> {:ok, status, Map.put(resp_headers, "x-ms-consistency-level", level), body}
    end
  end

  defp echo_consistency(other, _headers), do: other

  defp container_link(db, coll), do: "dbs/#{db}/colls/#{coll}"

  defp doc_link(db, coll, doc_id), do: "dbs/#{db}/colls/#{coll}/docs/#{doc_id}"

  defp partition_check(headers, body, pk_meta) do
    case PartitionKey.enforce(header(headers, PartitionKey.header_name()), body, pk_meta) do
      :ok -> :ok
      err -> err
    end
  end

  # Replace path: the doc id arrives from the route, so it was never checked
  # against the doc-id grammar. An id violating it cannot exist (create
  # refuses it), so a put is 404 NotFound — refused before the pk check.
  defp doc_id_check(doc_id) do
    if valid_doc_id?(doc_id) do
      :ok
    else
      {:error, 404, "NotFound"}
    end
  end

  # Real-SDK-driven response headers. The @azure/cosmos SDK tolerates these
  # missing but READS them when present:
  # - x-ms-alt-content-path (HttpHeaders.OwnerFullName): resolves the owning
  #   container for session tracking (getContainerName).
  # - x-ms-session-token: VectorSessionToken "version#globalLsn" format,
  #   monotonic per collection (write ops bump it, reads report current).
  # - x-ms-lsn: the record's log sequence number.
  defp success_headers(db, coll, lsn, extra) do
    Map.merge(
      %{
        "x-ms-request-charge" => @request_charge,
        "x-ms-alt-content-path" => alt_content_path(db, coll),
        "x-ms-session-token" => session_token(lsn),
        "x-ms-lsn" => Integer.to_string(lsn)
      },
      extra
    )
  end

  defp alt_content_path(db, nil), do: "dbs/#{db}"
  defp alt_content_path(db, coll), do: "dbs/#{db}/colls/#{coll}"

  defp session_token(lsn), do: "#{@session_token_version}##{lsn}"

  # Durable LSN counter: the @lsn_table is store-owned (created by Store.init),
  # so counters survive request-process death. update_counter is atomic.
  defp next_lsn(db, coll) do
    Store.update_counter(@lsn_table, container_key(db, coll))
  end

  defp current_lsn(db, coll) do
    Store.current_counter(@lsn_table, container_key(db, coll))
  end

  defp error_response(db, coll, status, code, message) do
    lsn = current_lsn(db, coll)

    {:ok, status, success_headers(db, coll, lsn, %{}), %{"code" => code, "message" => message}}
  end

  defp request_entity_too_large_message,
    do: "Entity is too large. The maximum document size is 2MB."

  @doc """
  Deterministic resource-id minting in the real Cosmos grammar: a composite
  of base64url(sha256(...)) segments — db rid 8 chars, container rid = db rid
  + 4, doc rid = container rid + 8 (base64url alphabet of the wire format).
  Stable across restarts and consistently used by the db/container/doc records
  and the query feed envelope.
  """
  def rid_segment(value, chars) do
    data = value

    :crypto.hash(:sha256, data)
    |> Base.url_encode64(padding: false)
    |> binary_part(0, chars)
  end

  def db_rid(db), do: rid_segment(db, 8)

  def coll_rid(db, coll), do: db_rid(db) <> rid_segment(coll, 4)

  def doc_rid(db, coll, id), do: coll_rid(db, coll) <> rid_segment(id, 8)

  defp error_message("NotFound", _pk_meta),
    do: "Entity with the specified id does not exist in the system."

  defp error_message("BadRequest", _pk_meta),
    do: "Partition key provided in the header doesn't match the partition key of the document."

  defp error_message(_code, pk_meta), do: pk_error_message(pk_meta)

  defp pk_error_message(pk_meta) do
    if pk_meta do
      "Partition key header is required and must match the document's partition key value."
    else
      "BadRequest"
    end
  end

  defp precondition_message,
    do: "The condition specified using HTTP conditional header(s) is not met."

  defp header(headers, name), do: ConditionalHeaders.header(headers || %{}, name)

  defp doc_key(db, coll, doc_id), do: "#{db}/#{coll}/#{doc_id}"
  defp container_key(db, coll), do: "#{db}/#{coll}"

  defp quoted_sha256(value) do
    "\"" <> (:crypto.hash(:sha256, Jason.encode!(value)) |> Base.encode16(case: :lower)) <> "\""
  end

  # R59/A18 doc-etag composition: sha256 over {body-hash, version, nonce}.
  defp body_hash_hex(body) do
    :crypto.hash(:sha256, Jason.encode!(body)) |> Base.encode16(case: :lower)
  end

  defp doc_gen_nonce, do: Base.encode16(:crypto.strong_rand_bytes(8), case: :lower)

  defp doc_etag(body_hash, v, gen), do: quoted_sha256(%{"h" => body_hash, "v" => v, "g" => gen})
end
