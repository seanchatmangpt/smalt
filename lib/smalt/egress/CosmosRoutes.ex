defmodule Smalt.Egress.CosmosRoutes do
  @moduledoc """
  w6R structural split of Smalt.EgressRouter (BEAM implementation limit,
  function '__MODULE__'/1+14): Cosmos DB (/dbs...) arm, verbatim relocation.
  Fallthrough router — unmatched conns pass through un-halted; the main
  router's blob splat + 404 catch-all handle everything else, unchanged.
  """
  use Plug.Router
  import Smalt.EgressRouter, except: [match: 2, match: 3, dispatch: 2]
  alias Smalt.DataPlane.Cosmos
  alias Smalt.Security.ConfidentialLedger
  plug :match
  plug :dispatch

  # G4 tenant fence: doc-plane routes stamp the VERIFIED bearer's tenant onto
  # the header map before it reaches Smalt.DataPlane.Cosmos (the data plane
  # has no conn). The data plane falls back to parsing the authorization
  # bearer the same way for callers that arrive via EgressRouter.query_post
  # (outside this module's lease).
  defp tenant_headers(conn) do
    Smalt.Auth.TenantLaw.stamp(header_map(conn), conn)
  end




  post "/app/transactions" do
    if not_ready?(conn, [ConfidentialLedger]) do
      route_not_ready(conn)
    else
      with_valid_body(conn, fn conn ->
        # Shape fence: a Confidential Ledger append is a JSON object
        # ({"contents": ...}). Top-level lists — including the empty list and
        # scalar/null-element lists — appended garbage ledger entries at 201
        # (measured: [] / [1,"a",null,true] / [nil,...] all admitted); refuse
        # the non-object classes at the dispatch seam with InvalidBody.
        case conn.body_params do
          # The %{"_json" => _} wrapper is Plug's encoding of a top-level
          # non-object JSON body — never a valid append shape even when the
          # wrapper itself is a map (e.g. [] arrives as %{"_json" => []}).
          %{"_json" => _wrapped} ->
            blob_error(conn, 400, invalid_body_error())

          params when is_map(params) ->
            case ConfidentialLedger.append_transaction("default_ledger", params) do
              {:ok, receipt} ->
                # ledger/append@key-extra closure (KD-W2): the documented
                # Confidential Ledger append 201 carries ONLY {transactionId,
                # contents, subLedgerId, timestamp}. The substrate chain
                # members (data_hash/prev_hash/merkle_root/signature) stay in
                # the store/audit path — they remain on the GET list/get faces
                # (the audit path the athena s17 append-only court reads) and
                # in the sealed receipt, never on the append wire body.
                send_json(conn, 201, %{
                  "transactionId" => receipt["transactionId"],
                  "contents" => receipt["contents"],
                  "subLedgerId" => receipt["subLedgerId"],
                  "timestamp" => receipt["timestamp"]
                })

              # The writer returns the full wire-ready error envelope
              # (R143-era convention, D126 coherence): render it directly —
              # no per-arm not_found_error/put_message fabrication. Typed
              # status reaches the wire (lens-4/5 commit-point law).
              {:error, status, env} when is_integer(status) and is_map(env) ->
                blob_error(conn, status, env)

              other ->
                blob_error(conn, 500, %{"error" => inspect(other)})
            end

          _non_object ->
            blob_error(conn, 400, invalid_body_error())
        end
      end)
    end
  end

  # ---------------------------------------------------------------------------
  # Cosmos DB NoSQL Engine (/dbs, /dbs/:db/colls, /dbs/:db/colls/:coll/docs)
  # ---------------------------------------------------------------------------
  post "/dbs" do
    with_route(conn, Cosmos, fn conn ->
      with_valid_body(conn, fn conn ->
        case id_param(conn) do
          {:ok, db} -> cosmos_respond(conn, Cosmos.create_db(db, tenant_headers(conn)))
          :error -> blob_error(conn, 400, invalid_body_error())
        end
      end)
    end)
  end

  get "/dbs" do
    with_route(conn, Cosmos, fn conn ->
      cosmos_respond(conn, Cosmos.list_dbs(tenant_headers(conn)))
    end)
  end

  # ---------------------------------------------------------------------------

  # GET /dbs/:db — database read. Without this route the @azure/cosmos SDK's
  # createIfNotExists falls through to the blob catch-all (the SDK sends
  # x-ms-version), which answered XML and broke the SDK's JSON parse.
  get "/dbs/:db" do
    with_route(conn, Cosmos, fn conn ->
      case Cosmos.list_dbs(tenant_headers(conn)) do
        {:ok, status, headers, %{"Databases" => dbs}} ->
          case Enum.find(dbs, &(&1["id"] == db)) do
            nil ->
              blob_error(conn, 404, %{
                "code" => "NotFound",
                "message" => "Entity with id #{db} not found"
              })

            record ->
              cosmos_respond(conn, {:ok, status, headers, record})
          end

        # Lens7 fail-closed: not-ready must never be masked as NotFound.
        {:error, :store_not_ready} ->
          route_not_ready(conn)

        _ ->
          blob_error(conn, 404, %{
            "code" => "NotFound",
            "message" => "Entity with id #{db} not found"
          })
      end
    end)
  end

  # DELETE /dbs/:db — database delete with full cascade (docs, pk_meta, cf
  # cursors, LSN/session-token namespace). 204 on success, 404 on miss.
  delete "/dbs/:db" do
    with_route(conn, Cosmos, fn conn ->
      cosmos_respond(conn, Cosmos.delete_database(db, header_map(conn)))
    end)
  end

  # DELETE /dbs/:db/colls/:coll — container delete with full cascade. 204 on
  # success, 404 on miss (SDK raises CosmosResourceNotFoundError).
  delete "/dbs/:db/colls/:coll" do
    with_route(conn, Cosmos, fn conn ->
      cosmos_respond(conn, Cosmos.delete_collection(db, coll, header_map(conn)))
    end)
  end

  post "/dbs/:db/colls" do
    with_route(conn, Cosmos, fn conn ->
      with_valid_body(conn, fn conn ->
        case id_param(conn) do
          {:ok, coll} ->
            body = normalize_pk_body(conn.body_params)

            case Cosmos.create_collection(db, coll, body, tenant_headers(conn)) do
              {:ok, status, headers, record} ->
                cosmos_respond(conn, {:ok, status, headers, with_pk_kind(record)})

              other ->
                cosmos_respond(conn, other)
            end

          :error ->
            blob_error(conn, 400, invalid_body_error())
        end
      end)
    end)
  end

  get "/dbs/:db/colls" do
    with_route(conn, Cosmos, fn conn ->
      cosmos_respond(conn, Cosmos.list_collections(db, tenant_headers(conn)))
    end)
  end

  # GET /dbs/:db/colls/:coll — container read (python SDK
  # create_container_if_not_exists / read_container surface). Serves the
  # record from list_collections with the partitionKey "kind" the SDK
  # requires, 404 NotFound envelope when absent.
  get "/dbs/:db/colls/:coll" do
    with_route(conn, Cosmos, fn conn ->
      case Cosmos.list_collections(db, tenant_headers(conn)) do
        {:ok, status, headers, %{"DocumentCollections" => colls}} ->
          case Enum.find(colls, &(&1["id"] == coll)) do
            nil ->
              blob_error(conn, 404, %{
                "code" => "NotFound",
                "message" => "Entity with id #{coll} not found"
              })

            record ->
              # w6bg: GET container x-ms-request-charge emulation — 2.5 flat +
              # 0.1/KB of container bytes scanned (constants documented in the
              # receipt; emulator has no RU accounting).
              charge =
                :smalt_cosmos_docs
                |> Smalt.Store.list_prefix("#{db}/#{coll}/")
                |> Enum.reduce(0, fn doc, acc ->
                  acc + Smalt.Cosmos.QueryMetrics.doc_bytes(doc)
                end)
                |> Smalt.Cosmos.QueryMetrics.request_charge()

              headers =
                Map.put(headers, "x-ms-request-charge", Float.to_string(charge))

              cosmos_respond(conn, {:ok, status, headers, with_pk_kind(record)})
          end

        # Lens7 fail-closed: not-ready must never be masked as NotFound.
        {:error, :store_not_ready} ->
          route_not_ready(conn)

        _ ->
          blob_error(conn, 404, %{
            "code" => "NotFound",
            "message" => "Entity with id #{coll} not found"
          })
      end
    end)
  end

  # PUT /dbs/:db/colls/:coll — replace container (throughput replace path).
  # Real Cosmos routes throughput changes through offers; 80/20 the emulator
  # accepts `throughput` in the replace body and the stored value is served on
  # every subsequent container read.
  put "/dbs/:db/colls/:coll" do
    with_route(conn, Cosmos, fn conn ->
      with_valid_body(conn, fn conn ->
        case Cosmos.replace_collection(db, coll, conn.body_params, tenant_headers(conn)) do
          {:ok, _status, _headers, _body} = responded ->
            cosmos_respond(conn, responded)

          {:error, :store_not_ready} = other ->
            cosmos_respond(conn, other)
        end
      end)
    end)
  end

  # GET /dbs/:db/colls/:coll/pkranges — partition-key-range feed. The python
  # SDK's session-token/routing layer resolves the routing map through this
  # feed before reads; the range set is served by the Cosmos engine
  # (Smalt.DataPlane.Cosmos.partition_key_ranges/2), deterministic per
  # container and 404 on unknown containers.

  get "/dbs/:db/colls/:coll/pkranges" do
    with_route(conn, Cosmos, fn conn ->
      # The python SDK's routing-map drain terminates ONLY on a literal 304
      # (evaluate_drain_page): first fetch -> 200 + ETag, any further fetch
      # carrying a matching If-None-Match -> 304, loop exits. The ETag is now
      # derived from the range set (deterministic per container), so a changed
      # map flips the ETag and the drain re-fetches.
      case Cosmos.partition_key_ranges(db, coll, tenant_headers(conn)) do
        {:ok, 200, headers, body} ->
          etag = headers["etag"]

          if get_req_header(conn, "if-none-match") == [etag] do
            conn |> put_resp_header("etag", etag) |> send_resp(304, "")
          else
            conn |> put_resp_header("etag", etag) |> send_json(200, body)
          end

        other ->
          cosmos_respond(conn, other)
      end
    end)
  end

  # ---------------------------------------------------------------------------
  # UDFs + triggers (lane w6g): PUT upsert / GET feed / GET one / DELETE.
  # Real Cosmos has no POST for these script resources; the JS SDK routes
  # create through PUT /dbs/{db}/colls/{coll}/udfs/{id}.
  # ---------------------------------------------------------------------------

  put "/dbs/:db/colls/:coll/udfs/:udf_id" do
    with_route(conn, Cosmos, fn conn ->
      with_valid_body(conn, fn conn ->
        cosmos_respond(conn, Cosmos.put_udf(db, coll, udf_id, conn.body_params))
      end)
    end)
  end

  get "/dbs/:db/colls/:coll/udfs" do
    with_route(conn, Cosmos, fn conn ->
      cosmos_respond(conn, Cosmos.list_udfs(db, coll))
    end)
  end

  get "/dbs/:db/colls/:coll/udfs/:udf_id" do
    with_route(conn, Cosmos, fn conn ->
      cosmos_respond(conn, Cosmos.get_udf(db, coll, udf_id))
    end)
  end

  delete "/dbs/:db/colls/:coll/udfs/:udf_id" do
    with_route(conn, Cosmos, fn conn ->
      cosmos_respond(conn, Cosmos.delete_udf(db, coll, udf_id))
    end)
  end

  put "/dbs/:db/colls/:coll/triggers/:trigger_id" do
    with_route(conn, Cosmos, fn conn ->
      with_valid_body(conn, fn conn ->
        cosmos_respond(conn, Cosmos.put_trigger(db, coll, trigger_id, conn.body_params))
      end)
    end)
  end

  get "/dbs/:db/colls/:coll/triggers" do
    with_route(conn, Cosmos, fn conn ->
      cosmos_respond(conn, Cosmos.list_triggers(db, coll))
    end)
  end

  get "/dbs/:db/colls/:coll/triggers/:trigger_id" do
    with_route(conn, Cosmos, fn conn ->
      cosmos_respond(conn, Cosmos.get_trigger(db, coll, trigger_id))
    end)
  end

  delete "/dbs/:db/colls/:coll/triggers/:trigger_id" do
    with_route(conn, Cosmos, fn conn ->
      cosmos_respond(conn, Cosmos.delete_trigger(db, coll, trigger_id))
    end)
  end
  # engine BEFORE the create handler is reachable — a query POST never creates
  # a document.
  post "/dbs/:db/colls/:coll/docs" do
    with_route(conn, Cosmos, fn conn ->
      cond do
        query_post?(conn) ->
          query_post(conn, db, coll)

        get_req_header(conn, "x-ms-cosmos-is-batch-request") == ["true"] or is_list(conn.body_params) ->
          with_valid_body(conn, fn conn ->
            ops =
              case conn.body_params do
                %{"_json" => list} when is_list(list) -> list
                list when is_list(list) -> list
                other -> List.wrap(other)
              end

            cosmos_respond(conn, Cosmos.bulk_operations(db, coll, ops, tenant_headers(conn)))
          end)

        true ->
          with_valid_body(conn, fn conn ->
            cosmos_respond(conn, Cosmos.create_doc(db, coll, conn.body_params, tenant_headers(conn)))
          end)
      end
    end)
  end

  # GET /dbs/:db/colls/:coll/docs/_changes — change feed, LSN order
  # (?format=sequence&version=<lsn>). MUST precede the docs/:doc_id route or
  # the feed path is captured as a point read of id "_changes".
  get "/dbs/:db/colls/:coll/docs/_changes" do
    with_route(conn, Cosmos, fn conn ->
      conn = Plug.Conn.fetch_query_params(conn)
      cosmos_respond(conn, Cosmos.change_feed(db, coll, conn.query_params, tenant_headers(conn)))
    end)
  end

  get "/dbs/:db/colls/:coll/docs/:doc_id" do
    with_route(conn, Cosmos, fn conn ->
      cosmos_respond(conn, Cosmos.get_doc(db, coll, doc_id, tenant_headers(conn)))
    end)
  end

  get "/dbs/:db/colls/:coll/docs" do
    with_route(conn, Cosmos, fn conn ->
      case Cosmos.list_docs(db, coll, "", tenant_headers(conn)) do
        {:ok, status, headers, docs} when is_list(docs) ->
          # KD-07 wire normalization: the SDK ReadFeed expects the Cosmos
          # envelope, never a bare array. A malformed (non-list) engine shape
          # still falls to the fail-closed clause below — 503, never an
          # empty success envelope.
          envelope = %{
            "_rid" => Cosmos.coll_rid(db, coll),
            "Documents" => docs,
            "_count" => length(docs)
          }

          cosmos_respond(conn, {:ok, status, headers, envelope})

        # X-10 integration unblock (cross-lane merge artifact with the KD-07
        # wire-normalization lane): the engine's typed 400 continuation
        # refusals leave list_docs as {:ok, status, headers, map} (the
        # error_response shape), not a list — render the flat BadRequest
        # envelope instead of falling into the fail-closed 503 arm.
        {:ok, status, headers, body} when is_map(body) ->
          cosmos_respond(conn, {:ok, status, headers, body})

        # Lens7 fail-closed law: a not-ready store or any unexpected engine
        # shape must never be answered with a success-shaped empty feed.
        _other ->
          route_not_ready(conn)
      end
    end)
  end

  put "/dbs/:db/colls/:coll/docs/:doc_id" do
    with_route(conn, Cosmos, fn conn ->
      with_valid_body(conn, fn conn ->
        cosmos_respond(conn, Cosmos.put_doc(db, coll, doc_id, conn.body_params, tenant_headers(conn)))
      end)
    end)
  end

  # PATCH /dbs/:db/colls/:coll/docs/:doc_id — RFC 6902 patch (GAP-AUD1-05).
  # The patch document is a TOP-LEVEL JSON ARRAY of ops; Plug.Parsers wraps a
  # decoded non-map body as %{"_json" => list}, so unwrap that form here and
  # refuse anything that is not an op list (typed 400 before the engine —
  # PATCH is a separate route, never the SQL query path).
  # KD-COVERS: KD-64
  patch "/dbs/:db/colls/:coll/docs/:doc_id" do
    with_route(conn, Cosmos, fn conn ->
      case unwrap_patch_ops(conn.body_params) do
        {:ok, ops} ->
          cosmos_respond(conn, Cosmos.patch_doc(db, coll, doc_id, ops, tenant_headers(conn)))

        :error ->
          # R50 repair 2: blob_error-style stamping (request-id + version) so
          # header discipline holds on the blob-plane-adjacent Cosmos route.
          blob_error(conn, 400, %{
            "code" => "BadRequest",
            "message" => "The patch document must be a JSON array of RFC 6902 operations."
          })
      end
    end)
  end

  delete "/dbs/:db/colls/:coll/docs/:doc_id" do
    with_route(conn, Cosmos, fn conn ->
      cosmos_respond(conn, Cosmos.delete_doc(db, coll, doc_id, tenant_headers(conn)))
    end)
  end

  # ---------------------------------------------------------------------------
  # ---------------------------------------------------------------------------
  # Cosmos stored procedures (w6f): /dbs/:db/colls/:coll/sprocs CRUD + execute
  # ---------------------------------------------------------------------------

  get "/dbs/:db/colls/:coll/sprocs" do
    with_route(conn, Cosmos, fn conn ->
      cosmos_respond(conn, Cosmos.list_sprocs(db, coll, header_map(conn)))
    end)
  end

  post "/dbs/:db/colls/:coll/sprocs" do
    with_route(conn, Cosmos, fn conn ->
      with_valid_body(conn, fn conn ->
        body = wrap_json_list(conn.body_params)
        cosmos_respond(conn, Cosmos.create_sproc(db, coll, body, header_map(conn)))
      end)
    end)
  end
  # POST .../sprocs/:sproc = EXECUTE (real Cosmos verb semantics); GET/PUT/
  # DELETE on the same path are the resource CRUD faces.
  post "/dbs/:db/colls/:coll/sprocs/:sproc" do
    with_route(conn, Cosmos, fn conn ->
      with_valid_body(conn, fn conn ->
        args = unwrap_sproc_args(conn.body_params)
        cosmos_respond(conn, Cosmos.execute_sproc(db, coll, sproc, args, header_map(conn)))
      end)
    end)
  end

  get "/dbs/:db/colls/:coll/sprocs/:sproc" do
    with_route(conn, Cosmos, fn conn ->
      cosmos_respond(conn, Cosmos.get_sproc(db, coll, sproc, header_map(conn)))
    end)
  end

  put "/dbs/:db/colls/:coll/sprocs/:sproc" do
    with_route(conn, Cosmos, fn conn ->
      with_valid_body(conn, fn conn ->
        body = unwrap_sproc_args(conn.body_params)
        cosmos_respond(conn, Cosmos.replace_sproc(db, coll, sproc, body, header_map(conn)))
      end)
    end)
  end

  delete "/dbs/:db/colls/:coll/sprocs/:sproc" do
    with_route(conn, Cosmos, fn conn ->
      cosmos_respond(conn, Cosmos.delete_sproc(db, coll, sproc, header_map(conn)))
    end)
  end


  # Plug wraps a top-level JSON array as %{"_json" => list}; unwrap for the
  # sproc execute-args seam (replace passes the map through untouched).
  defp unwrap_sproc_args(%{"_json" => list}) when is_list(list), do: list
  defp unwrap_sproc_args(%{"_json" => single}), do: List.wrap(single)
  defp unwrap_sproc_args(params) when is_list(params), do: params
  defp unwrap_sproc_args(%{} = single), do: [single]
  defp unwrap_sproc_args(_other), do: []
  # ---------------------------------------------------------------------------
  # Key Vault & Managed HSM / Secure Key Release (/keys/:name)
  # ---------------------------------------------------------------------------
end
