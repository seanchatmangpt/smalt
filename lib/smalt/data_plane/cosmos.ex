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

  Optimistic concurrency (S8 fix): the If-Match check and the write run as ONE
  `Smalt.Store.compare_and_swap/4` — lookup+insert serialized inside the Store
  GenServer — so a same-doc race yields exactly one 200 and N-1 412s, never a
  lost update.
  """

  alias Smalt.DataPlane.ConditionalHeaders
  alias Smalt.DataPlane.PartitionKey
  alias Smalt.Store

  @request_charge "1.0"
  @docs_table :smalt_cosmos_docs
  @pk_meta_table :smalt_cosmos_pk_meta
  @lsn_table :smalt_cosmos_lsn
  @session_token_version 1

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
      key = {0, db}

      record = %{
        "id" => db,
        "_rid" => db_rid(db),
        "_self" => "/dbs/#{db}",
        "_ts" => System.system_time(:second)
      }

      :ets.insert(@pk_meta_table, {key, record})
      {:ok, 201, success_headers(db, nil, 0, %{"etag" => quoted_sha256(record)}), record}
    else
      {:error, :store_not_ready}
    end
  end

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
      paths =
        body
        |> Map.get("partitionKey")
        |> paths_from_body()

      key = {1, db, coll}

      record = %{
        "id" => coll,
        "_rid" => coll_rid(db, coll),
        "_self" => "/dbs/#{db}/colls/#{coll}",
        # Engine-level: the python azure-cosmos SDK reads partitionKey["kind"]
        # (_ExtractPartitionKey); a record without it KeyErrors in the SDK.
        "partitionKey" => Map.put_new(%{"paths" => paths}, "kind", "Hash"),
        "_ts" => System.system_time(:second)
      }

      :ets.insert(@pk_meta_table, {key, record})
      define_container(db, coll, paths)
      {:ok, 201, success_headers(db, coll, 0, %{"etag" => quoted_sha256(record)}), record}
    else
      {:error, :store_not_ready}
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
  # Route-handling functions (wired by the egress lane)
  # ---------------------------------------------------------------------------

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

    if byte_size(Jason.encode!(body)) > @max_doc_bytes do
      error_response(db, coll, 413, "RequestEntityTooLarge", request_entity_too_large_message())
    else
      do_create_doc_sized(db, coll, doc_id, body, headers)
    end
  end

  defp do_create_doc_sized(db, coll, doc_id, body, headers) do
    pk_meta = container_meta(db, coll)

    case PartitionKey.enforce(header(headers, PartitionKey.header_name()), body, pk_meta) do
      :ok ->
        etag = quoted_sha256(body)
        now = System.system_time(:second)

        stored =
          body
          |> Map.put("id", doc_id)
          |> Map.put("_rid", doc_rid(db, coll, doc_id))
          |> Map.put("_self", "/dbs/#{db}/colls/#{coll}/docs/#{doc_id}")
          |> Map.put("_etag", etag)
          |> Map.put("_ts", now)

        Store.put(@docs_table, doc_key(db, coll, doc_id), stored)
        lsn = next_lsn(db, coll)

        {:ok, 201, success_headers(db, coll, lsn, %{"etag" => etag}), stored}

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
        with :ok <- partition_check(headers, body, pk_meta) do
          if_match = header(headers, "if-match")
          new_etag = quoted_sha256(body)
          now = System.system_time(:second)

          updated =
            existing
            |> Map.merge(body)
            |> Map.put("id", doc_id)
            |> Map.put("_rid", existing["_rid"])
            |> Map.put("_self", existing["_self"])
            |> Map.delete("_etag")
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
              Store.delete(@docs_table, doc_key(db, coll, doc_id))
              lsn = next_lsn(db, coll)
              {:ok, 204, success_headers(db, coll, lsn, %{}), ""}

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

  @doc """
  Lists documents in a collection by id prefix. Returns `{:ok, 200, headers, docs}`.
  """
  def list_docs(db, coll, prefix \\ "") do
    if store_ready?() do
      docs =
        @docs_table
        |> Store.list_prefix("#{db}/#{coll}/#{prefix}")
        |> Enum.sort_by(& &1["id"])

      lsn = current_lsn(db, coll)
      {:ok, 200, success_headers(db, coll, lsn, %{}), docs}
    else
      {:error, :store_not_ready}
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
  def query_docs(db, coll, _body, headers) do
    gate(:post, "docs", container_link(db, coll), headers, fn ->
      if store_ready?() do
        pk_meta = container_meta(db, coll)
        paths = (pk_meta && Map.get(pk_meta, "paths", [])) || []

        docs =
          @docs_table
          |> Store.list_prefix("#{db}/#{coll}/")
          |> Enum.sort_by(& &1["id"])

        docs =
          if paths == [] do
            # No partition key defined: every partition (header ignored).
            docs
          else
            case PartitionKey.parse(header(headers, PartitionKey.header_name())) do
              {:ok, pk} -> Enum.filter(docs, fn d -> PartitionKey.extract(d, paths) == pk end)
              :error -> docs
            end
          end
          |> Enum.take(@query_limit)

        lsn = current_lsn(db, coll)

        {:ok, 200, success_headers(db, coll, lsn, %{}),
         %{
           "_rid" => coll_rid(db, coll),
           "Documents" => docs,
           "_count" => length(docs)
         }}
      else
        {:error, :store_not_ready}
      end
    end)
  end

  # ---------------------------------------------------------------------------
  # Request gate: master-key Authorization validation + RU throttle + echo
  # ---------------------------------------------------------------------------

  # Wraps a doc-surface handler: (1) master-key Authorization validation in
  # :enforce auth_mode only (Bearer/anonymous paths untouched); (2) in-memory
  # fixed-window RU throttle per partition-route (container), active only when
  # Application.get_env(:smalt, :cosmos_ru_limit) is set (default :infinity —
  # behavior unchanged unless configured); (3) x-ms-consistency-level echo.
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

  # Fixed-window (1s) in-memory counter per partition-route. ETS table is
  # created lazily and left to die with the VM (in-memory by definition).
  defp throttle(route_key) do
    case Application.get_env(:smalt, :cosmos_ru_limit, :infinity) do
      :infinity ->
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
        :ets.new(:smalt_cosmos_ru, [:named_table, :public, :set, read_concurrency: true])
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
end
