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
  defp valid_name?(name), do: is_binary(name) and byte_size(name) in 1..255 and not contains_slash?(name)

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
             "message" => "Invalid database or container name: must be 1-255 chars and must not contain '/'."
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

  defp invalid_doc_id_message,
    do: "Invalid document id: must be a 1-255 char string and must not contain '/'."

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

        case Store.insert_new(@docs_table, doc_key(db, coll, doc_id), stored) do
          :ok ->
            lsn = next_lsn(db, coll)
            {:ok, 201, success_headers(db, coll, lsn, %{"etag" => etag}), stored}

          {:error, :exists} ->
            error_response(
              db,
              coll,
              409,
              "Conflict",
              "Entity with the specified id already exists in the system."
            )
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
             :ok <- partition_check(headers, body, pk_meta) do
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

  @doc """
  Lists documents in a collection by id prefix. Returns `{:ok, 200, headers, docs}`.
  """
  def list_docs(db, coll, prefix \\ "", headers \\ %{}) do
    gate(:get, "docs", container_link(db, coll), headers, fn ->
      if store_ready?() do
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
            {:ok, _b64c, _tok_prefix, last_id} -> Enum.drop_while(docs, fn d -> d["id"] <= last_id end)
            :none -> docs
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
      else
        {:error, :store_not_ready}
      end
    end)
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
          do_query_docs(db, coll, q, headers)
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
  defp do_query_docs(db, coll, q, headers) do
    if sql_whitelisted?(q) do
      scan_query_docs(db, coll, headers)
    else
      error_response(db, coll, 400, "SyntaxError", "The query syntax is invalid.")
    end
  end

  defp scan_query_docs(db, coll, headers) do
    pk_meta = container_meta(db, coll)
    paths = (pk_meta && Map.get(pk_meta, "paths", [])) || []
    pk_hdr = header(headers, PartitionKey.header_name())
    ledger = current_lsn(db, coll)

    # Minimal unblock (amqp-codec lens-4 lane, compile-freeze SLA): the
    # in-flight edit passed `docs` to query_pk_check/3 before it was bound;
    # hoist the fetch above the `with` (same value, all clauses ignore it).
    docs =
      @docs_table
      |> Store.list_prefix("#{db}/#{coll}/")
      |> Enum.sort_by(& &1["id"])

    with :ok <- parse_continuation(header(headers, @continuation_header), pk_hdr, ledger, db, coll),
         :ok <- query_pk_check(pk_hdr, paths, docs) do
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
  defp query_pk_check(nil, _paths, _docs), do: :ok
  defp query_pk_check(_hdr, [], _docs), do: :ok

  defp query_pk_check(hdr, _paths, _docs) do
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
end
