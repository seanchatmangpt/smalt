defmodule Smalt.EgressRouter do
  @moduledoc """
  Subsystems 3 & 4 + Data Plane Egress Router (Port 8443).

  Wire dispatcher over the delivered data-plane modules. Route order:
  literal service prefixes first, then blob routes (guarded catch-all), then
  the 404 catch-all. Missing/uncompiled sibling modules fail closed with
  `503 {"error":{"code":"RouteNotReady"}}` — never a 200-empty response.

  Endpoints:
  - Microsoft Azure Attestation (`/attest/:type`)
  - Azure Confidential Ledger (`/app/transactions`)
  - Cosmos DB NoSQL Engine (`/dbs/:db/colls/:coll/docs`)
  - Key Vault / Managed HSM Secure Key Release (`/keys/:name`)
  - Event Grid / Event Hubs CloudEvents ingestion (`/topics/:topic/events`)
  - Azure Monitor Sentinel / Log Analytics ingestion + KQL (`/dataCollectionRules`, `/v1/workspaces`)
  - Azure Resource Graph (`/providers/Microsoft.ResourceGraph/resources`)
  - Microsoft Purview Catalog (Atlas v2) (`/atlas/v2/...`)
  - Immutable Blob Storage REST API (guarded catch-all `/{account}/{container}[/{blob}]`)
  """

  use Plug.Router
  # EXPL-9 F2b (KD-COVERS: KD-175): crash-path fence, re-landed from the
  # pre-undock source (95d4243d) — the v26.10.29 undock dropped it while the
  # expl9r1_egress_guard_court_test source-assert kept pinning it. Before this
  # fence, any unhandled crash escaped to Bandit and rendered a NAKED adapter
  # 500 — empty body, no envelope, no x-ms-request-id — bypassing every
  # register_before_send callback.
  use Plug.ErrorHandler
  require Logger
  alias Smalt.Store
  alias Smalt.DataPlane.KeyVaultActions
  alias Smalt.DataPlane.Cosmos
  alias Smalt.DataPlane.Purview
  alias Smalt.DataPlane.ResourceGraph
  alias Smalt.DataPlane.Sentinel
  alias Smalt.DataPlane.AppConfigSnapshots
  alias Smalt.Messaging.EventStream
  alias Smalt.Security.Attestation
  alias Smalt.Security.ConfidentialLedger


  # Adaptive health probes (envelope Phase 4): zero-auth readiness/liveness.
  # Readiness degrades only on structural failure, never on load.
  plug(Smalt.HealthPlug)
  plug(Plug.Logger)
  # Lane 19 (v26.10.14) item 6: CORS origins are configurable at runtime via
  # `:smalt, :egress_cors_origins` (list of allowed origins). The default is
  # ["*"] — the documented dev posture for the emulator's 8443 surface; in
  # production, configure an explicit allowlist. Evaluated per-request so a
  # config flip does not need a recompile.
  plug(:egress_cors)

  defp egress_cors(conn, _opts) do
    # Restored (:egress_cors_headers knob dropped in the v26.10.29 undock
    # while cors_headers_knob_test retained it — historical shape 8261a435).
    # The undock's queue/blob rule-CORS variants (queue_mcp_cors,
    # w6ay_blob_cors) are NOT restored here — next-wave scope.
    origins = Application.get_env(:smalt, :egress_cors_origins, ["*"])
    headers = Application.get_env(:smalt, :egress_cors_headers, ["*"])
    CORSPlug.call(conn, CORSPlug.init(origin: origins, headers: headers))
  end

  # KD-COVERS: KD-15
  # KD-15 (v26.10.15): mode-blind Key Vault challenge guard. The real
  # @azure/keyvault-keys SDK is challenge-based: it sends a tokenless request
  # first and only attaches a token after a 401 + enriched WWW-Authenticate.
  # Anonymous mode previously passed tokenless /keys requests straight through
  # (no challenge => the SDK never attaches a token => handshake stalls).
  # Runs BEFORE Smalt.Auth.Bearer so it fires in BOTH auth modes; enforce mode
  # additionally refuses invalid tokens downstream (unchanged).
  plug(:kv_challenge_guard)

  defp kv_challenge_guard(conn, _opts) do
    auth = get_req_header(conn, "authorization")
    # Lane 345 (v26.10.16) item 8: @azure/keyvault-secrets is challenge-based
    # exactly like @azure/keyvault-keys — extend the mode-blind challenge to
    # the /secrets plane so tokenless SDK first-touch 401s with the enriched
    # WWW-Authenticate instead of falling through to the blob splat.
    # KD-COVERS: KD-53 (App Config /kv plane, v26.10.16 lane 520)
    kv_path? =
      String.starts_with?(conn.request_path, "/keys") or
        String.starts_with?(conn.request_path, "/secrets") or
        String.starts_with?(conn.request_path, "/kv")

    tokenless? = auth == [] or auth == [""]

    # CORS preflight (OPTIONS) stays auth-exempt — it must answer before any
    # 401 (the method-mismatch court pins OPTIONS /keys/k1 -> 404).
    #
    # Integration unblock (X-10, cross-lane merge artifact with the SKR
    # legacy-header lane): a request carrying the legacy SKR
    # `x-ms-compliance-status` raw header is NOT an SDK challenge-handshake
    # client — it must fall through to the SKR release handler, whose own
    # admission decides (200 when `skr_allow_legacy_header` is active, typed
    # 403 UnauthorizedAttestation when disabled). Challenging here would
    # shadow the handler's typed verdict with a 401.
    legacy_skr? = get_req_header(conn, "x-ms-compliance-status") != []

    # AZB-08: the mode-blind challenge posture is named by the identity-plane
    # profile key `challenge_mode: :strict_bearer` (default :strict_bearer —
    # KD-15 is the pinned default, byte-identical boot). Read via the Bearer
    # module (single read surface), never a private copy.
    strict_bearer? = Smalt.Auth.Bearer.kv_challenge_mode() == :strict_bearer

    if kv_path? and conn.method != "OPTIONS" and tokenless? and not legacy_skr? and strict_bearer? do
      Smalt.Auth.Bearer.send_challenge(conn, "MissingBearerToken")
    else
      conn
    end
  end

  # KD-101 narrowed: webhook receiver surface (zero-auth /eventgrid class)
  plug(Smalt.EventGridWebhookPlug)
  plug(Smalt.Auth.Bearer)
  plug(:fetch_query_params)

  # ---------------------------------------------------------------------------
  # G5 tenant fence (T-R1/L07 restore from the pre-undock source 95d4243d;
  # coordinator scope addendum): foreign-`tid` bearers on the blob/queue planes
  # get their account segment namespaced (tenant_scoped_key) so cross-tenant
  # data is structurally unreachable, and point access at another tenant's key
  # answers the typed 403 (never a first-party-shaped 404 lie). Home/no-tid
  # bearers pass through byte-identical (legacy law). Mounted downstream of
  # Smalt.Auth.Bearer so resolve_tenant/1 reads the verified bearer. Body in
  # Smalt.Egress.StorageCatchAll (T07 split).
  # ---------------------------------------------------------------------------
  plug(:tenant_namespace)
  # Python SDK trailing-slash tolerance: GET /dbs/:db/colls/:coll/ must route
  # identically to the non-slash form. Plug treats the trailing slash as an
  # empty final segment, which falls through to the 404 catch-all — strip it
  # for /dbs-prefixed paths before :match.
  plug(:trim_dbs_trailing_slash)

  plug(:maybe_parse_body)

  # ---------------------------------------------------------------------------
  # SB-REST lane (re-landed from the pre-undock source 95d4243d): Microsoft
  # Service Bus REST data-plane surface. Same path shape as the Queue Storage
  # plane below (/{account}/{queue}/messages...); the disambiguator is the
  # auth face — a `SharedAccessSignature` / `ServiceBusAuthorization` header
  # claims the request for Service Bus, a `SharedKey` face (or absence) falls
  # through UNCHANGED.
  # ---------------------------------------------------------------------------
  plug(Smalt.Egress.ServiceBusRestRoutes)

  plug(:queue_storage_plane)

  plug(:file_share_plane)



  # T07 split: the file-plane banner + body moved to
  # Smalt.Egress.StorageCatchAll. This SECOND mount is preserved verbatim —
  # the pre-split front mounted :file_share_plane twice (L02 restore
  # artifact), and byte-parity law keeps both mounts (see r7 receipt).
  plug(:file_share_plane)


  # w6R structural split (re-landed from the pre-undock source 95d4243d): the
  # delegator sub-routers under lib/smalt/egress/ (SyncRoutes /sync/journal/batch,
  # MarketplaceRoutes /saas/*, GraphRoutes /v1.0/*, ...) receive every conn
  # BEFORE :match/:dispatch; each passes unmatched conns through un-halted.
  # plug(Mod) resolves at COMPILE time, so referencing the w6R sub-routers
  # (which `import Smalt.EgressRouter`) deadlocks against them — resolved at
  # RUNTIME only, via the atom plug below.
  # PRD-APIM wire plane (ApimWireTest): /apim-gw/{api}/... — policies (jwt,
  # rate-limit 429) and the default-off typed 404 must answer BEFORE the blob
  # catch-all's MissingXMsVersion guard, whose blanket 400 previously shadowed
  # the whole family. Runtime atom plug (same idiom as :w6r_fallthrough) so
  # the reference never resolves at compile time; claims only /apim-gw/* and
  # passes everything else through un-halted.
  plug(:apim_gateway_plane)
  plug(:w6r_fallthrough)
  plug(:match)
  plug(:dispatch)
  plug(:storage_dispatch)

  # JA-R1 (V2): the ONLY expected failure class here is an unmatched route
  # clause (FunctionClauseError) — benign fallthrough to the next sub-router.
  # The fallthrough is logged, not silent; every other exception class
  # propagates untouched (never swallowed into a benign miss on the wire).
  defp safe_subrouter_call(m, conn) do
    try do
      m.call(conn, m.init([]))
    rescue
      FunctionClauseError ->
        Logger.warning("egress subrouter #{inspect(m)} unmatched route — falling through")

        conn
    end
  end

  defp apim_gateway_plane(conn, _opts) do
    Smalt.Apim.gateway(conn, [])
  end

  defp w6r_fallthrough(conn, _opts) do
    mods = [
      Smalt.Egress.AttestRoutes,
      Smalt.Egress.CosmosRoutes,
      Smalt.Egress.KvRoutes,
      Smalt.Egress.AppConfigRoutes,
      Smalt.Egress.ObservabilityRoutes,
      Smalt.Egress.SchemaRegistryRoutes,
      # EH-REST lane: POST /{hub}/messages — the Microsoft-documented Event
      # Hubs REST producer (SAS 401 law, x-ms-partition-key -> KD-76 pk
      # partition rule, 1 MiB 413 cap, 201 empty-body success).
      Smalt.Egress.EventHubsRestRoutes,
      # GLD-3 (v26.10.21): POST /sql-ingest — SQL ingestion wire face
      # (SqlIngest pipeline -> OCEL projection -> andon 422 refusals).
      Smalt.Egress.SqlIngestRoutes,
      # ATH-1 (v26.10.22): POST /sync/journal/batch — domain-blind binary
      # sync ingress (frame integrity -> guard seam -> CAS/ANDON + receipt).
      Smalt.Egress.SyncRoutes,
      # AZURE-FIDELITY lane 8: /saas/* — the Microsoft-documented Marketplace
      # SaaS fulfillment face (resolve/activate/operations/usageEvent).
      # Default OFF: with `config :smalt, :marketplace_saas, enabled: false`
      # (the default) every conn falls through un-halted and un-sent.
      Smalt.Egress.MarketplaceRoutes,
      # AZURE-FIDELITY lane 13: /v1.0/* — the Microsoft-documented Graph stub
      # face (servicePrincipals/applications/oauth2PermissionGrants; odata
      # envelopes; STS bearer auth).
      Smalt.Egress.GraphRoutes
    ]

    Enum.reduce(mods, conn, fn m, conn ->
      cond do
        # A sub-router that SENT a response must end the chain: its send paths
        # (send_resp/json_response) set state :sent without halting, so the
        # conn previously fell through to the blob splat and blob_route's
        # put_resp_header raised AlreadySentError (witnessed: wire_norm kd07
        # court, lane E1 2026-10-20; same class as S1's double-send finding).
        # halt() also stops the plug pipeline itself (match/dispatch follow).
        conn.halted ->
          conn

        conn.state in [:sent, :chunked] ->
          Plug.Conn.halt(conn)

        Code.ensure_loaded?(m) ->
          safe_subrouter_call(m, conn)

        true ->
          conn
      end
    end)
  end

  # ---------------------------------------------------------------------------
  # T07 split (v26.10.29, L07): storage-family delegation + the post-dispatch
  # typed-404 fallback. The queue/file planes and the tenant fence run at their
  # pre-split pipeline positions as one-line delegates into
  # Smalt.Egress.StorageCatchAll; the guarded blob splat runs from
  # :storage_dispatch AFTER the front's literal-prefix families (the pre-split
  # route order) and BEFORE this fallback.
  # ---------------------------------------------------------------------------
  defp queue_storage_plane(conn, _opts),
    do: Smalt.Egress.StorageCatchAll.queue_storage_plane(conn)

  defp file_share_plane(conn, _opts),
    do: Smalt.Egress.StorageCatchAll.file_share_plane(conn)

  defp tenant_namespace(conn, _opts),
    do: Smalt.Egress.StorageCatchAll.tenant_namespace(conn, [])

  # 2026-10-30 r18/S5 compile-freeze unblock (DISCLOSED): at 00:27 the helper
  # in storage_catch_all.ex moved to the plug arity-2 form (def
  # tenant_namespace(conn, _opts)) while this arity-1 call remained, so EVERY
  # egress route 500'd (UndefinedFunctionError at plug_builder_call —
  # witnessed: /v2/track and /v1/workspaces/:id/query both crashed in the r18
  # court substrate log /tmp/r18-court-substrate.log). This one-line arity
  # alignment is behavior-preserving (the opts arg is the plug's []); the
  # owner (L02/T07 split lane) owns the final shape.

  # T07 split: Plug.Router raises FunctionClauseError on no-match and the
  # front's route list no longer ends in `match _` (the blob splat + the typed
  # 404 moved to the post-dispatch storage plane). Rescue the front no-match
  # and fall through to :storage_dispatch. Route BODIES run in dispatch — a
  # raise from a matched body is NOT rescued here (unchanged crash-fence
  # semantics). The stale :plug_route clear is defensive: w6r sub-routers set
  # their own :plug_route on the conn they return.
  def match(conn, _opts) do
    conn = %{conn | private: Map.delete(conn.private, :plug_route)}
    try do
      super(conn, _opts)
    rescue
      FunctionClauseError -> conn
    end
  end

  def dispatch(conn, _opts) do
    case conn.private do
      %{plug_route: _} -> super(conn, _opts)
      _ -> conn
    end
  end

  defp storage_dispatch(conn, _opts) do
    conn =
      cond do
        conn.halted or conn.state in [:sent, :chunked] -> conn
        true -> Smalt.Egress.StorageCatchAll.call(conn, [])
      end

    if conn.halted or conn.state in [:sent, :chunked] do
      conn
    else
      # The pre-split `match _` catch-all 404 (front router, byte-identical
      # envelope; the face is unstamped here so the envelope is JSON).
      blob_error(conn, 404, %{
        "error" => %{
          "code" => "RouteNotFound",
          "message" => "No route matches #{conn.method} #{conn.request_path}"
        }
      })
      |> Plug.Conn.halt()
    end
  end
  # ---------------------------------------------------------------------------
  # Microsoft Azure Attestation (MAA) (/attest/:type)
  # ---------------------------------------------------------------------------
  post "/attest/:type" do
    if not_ready?(conn, [Attestation]) do
      route_not_ready(conn)
    else
      with_valid_body(conn, fn conn ->
        case Attestation.attest_enclave(conn.body_params, type) do
          {:ok, token, claims} ->
            conn
            |> put_resp_content_type("application/json")
            |> send_resp(200, Jason.encode!(%{"token" => token, "claims" => claims}))

          {:error, status, code} ->
            blob_error(conn, status, %{"error" => %{"code" => code}})
        end
      end)
    end
  end

  # ---------------------------------------------------------------------------
  # Azure Confidential Ledger (/app/transactions)
  # ---------------------------------------------------------------------------
  get "/app/transactions" do
    if not_ready?(conn, [ConfidentialLedger]) or not tables_ready?([:smalt_ledger_transactions]) do
      route_not_ready(conn)
    else
      send_json(conn, 200, ConfidentialLedger.list_transactions("default_ledger"))
    end
  end

  get "/app/transactions/latest" do
    if not_ready?(conn, [ConfidentialLedger]) or
         not tables_ready?([:smalt_ledger_transactions, :smalt_ledger_meta]) do
      route_not_ready(conn)
    else
      case ConfidentialLedger.get_latest("default_ledger") do
        {:ok, receipt} -> send_json(conn, 200, receipt)
        :error -> blob_error(conn, 404, not_found_error("TransactionNotFound"))
      end
    end
  end

  get "/app/transactions/:tx_id" do
    if not_ready?(conn, [ConfidentialLedger]) do
      route_not_ready(conn)
    else
      case ConfidentialLedger.get_transaction("default_ledger", tx_id) do
        {:ok, receipt} -> send_json(conn, 200, receipt)
        :error -> blob_error(conn, 404, not_found_error("TransactionNotFound"))
      end
    end
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
                send_json(conn, 201, receipt)

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
          {:ok, db} -> cosmos_respond(conn, Cosmos.create_db(db))
          :error -> blob_error(conn, 400, invalid_body_error())
        end
      end)
    end)
  end

  get "/dbs" do
    with_route(conn, Cosmos, fn conn ->
      cosmos_respond(conn, Cosmos.list_dbs())
    end)
  end

  # GET /dbs/:db — database read. Without this route the @azure/cosmos SDK's
  # createIfNotExists falls through to the blob catch-all (the SDK sends
  # x-ms-version), which answered XML and broke the SDK's JSON parse.
  get "/dbs/:db" do
    with_route(conn, Cosmos, fn conn ->
      case Cosmos.list_dbs() do
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

            case Cosmos.create_collection(db, coll, body) do
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
      cosmos_respond(conn, Cosmos.list_collections(db))
    end)
  end

  # GET /dbs/:db/colls/:coll — container read (python SDK
  # create_container_if_not_exists / read_container surface). Serves the
  # record from list_collections with the partitionKey "kind" the SDK
  # requires, 404 NotFound envelope when absent.
  get "/dbs/:db/colls/:coll" do
    with_route(conn, Cosmos, fn conn ->
      case Cosmos.list_collections(db) do
        {:ok, status, headers, %{"DocumentCollections" => colls}} ->
          case Enum.find(colls, &(&1["id"] == coll)) do
            nil ->
              blob_error(conn, 404, %{
                "code" => "NotFound",
                "message" => "Entity with id #{coll} not found"
              })

            record ->
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
        case Cosmos.replace_collection(db, coll, conn.body_params) do
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
      case Cosmos.partition_key_ranges(db, coll) do
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

  # Query POST: content-type application/query+json is routed to the query
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

            cosmos_respond(conn, Cosmos.bulk_operations(db, coll, ops, header_map(conn)))
          end)

        true ->
          with_valid_body(conn, fn conn ->
            cosmos_respond(conn, Cosmos.create_doc(db, coll, conn.body_params, header_map(conn)))
          end)
      end
    end)
  end

  get "/dbs/:db/colls/:coll/docs/:doc_id" do
    with_route(conn, Cosmos, fn conn ->
      cosmos_respond(conn, Cosmos.get_doc(db, coll, doc_id, header_map(conn)))
    end)
  end

  get "/dbs/:db/colls/:coll/docs" do
    with_route(conn, Cosmos, fn conn ->
      case Cosmos.list_docs(db, coll, "", header_map(conn)) do
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
        cosmos_respond(conn, Cosmos.put_doc(db, coll, doc_id, conn.body_params, header_map(conn)))
      end)
    end)
  end

  # PATCH /dbs/:db/colls/:coll/docs/:doc_id — RFC 6902 patch (GAP-AUD1-05).
  # The patch document is a TOP-LEVEL JSON ARRAY of ops; Plug.Parsers wraps a
  # decoded non-map body as %{"_json" => list}, so unwrap that form here and
  # refuse anything that is not an op list (typed 400 before the engine —
  # PATCH is a separate route, never the SQL query path).
  patch "/dbs/:db/colls/:coll/docs/:doc_id" do
    with_route(conn, Cosmos, fn conn ->
      case unwrap_patch_ops(conn.body_params) do
        {:ok, ops} ->
          cosmos_respond(conn, Cosmos.patch_doc(db, coll, doc_id, ops, header_map(conn)))

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
      cosmos_respond(conn, Cosmos.delete_doc(db, coll, doc_id, header_map(conn)))
    end)
  end

  # ---------------------------------------------------------------------------
  # Key Vault & Managed HSM / Secure Key Release (/keys/:name)
  # ---------------------------------------------------------------------------
  post "/keys/:name/create" do
    with_valid_body(conn, fn conn ->
      key_params = conn.body_params
      kty = Map.get(key_params, "kty", "RSA-HSM")
      release_policy = Map.get(key_params, "release_policy")

      with {:ok, jwk_fields, key_material} <- jwk_for_kty(kty, name, release_policy),
           :ok <- validate_release_policy(release_policy) do
        # GAP-A2-08/10: the kid carries the version suffix (SDK witness) and the
        # version is kept in a list on the row so /keys/{name}/{version} and
        # /keys/{name}/{version}/{action} can resolve it.
        version = Integer.to_string(System.unique_integer([:positive]))

        key_record = %{
          "kid" => "https://#{conn.host}:8443/keys/#{name}/#{version}",
          "versions" => [version],
          "key" =>
            %{
              "kid" => "https://#{conn.host}:8443/keys/#{name}/#{version}",
              "kty" => kty
            }
            |> Map.merge(jwk_fields),
          "attributes" => %{
            "enabled" => true,
            "exportable" => not is_nil(release_policy),
            "created" => System.system_time(:second)
          },
          "release_policy" => release_policy,
          "key_material" => key_material
        }

        # Lens7 fail-closed: a missing vault table is server not-ready, never
        # a client-fault-shaped 400 from a rescued ArgumentError.
        if :ets.info(:smalt_vault_keys) == :undefined do
          route_not_ready(conn)
        else
          # Re-create accumulates versions: latest record rides the bare name,
          # each version also lands under its own {name, version} row.
          prior_versions =
            case Store.get(:smalt_vault_keys, name) do
              {:ok, %{"versions" => vs}} when is_list(vs) -> vs
              _ -> []
            end

          key_record = Map.update!(key_record, "versions", &(&1 ++ prior_versions))
          Store.put(:smalt_vault_keys, name, key_record)

          Store.put(
            :smalt_vault_keys,
            {name, version},
            Map.put(key_record, "is_version_row", true)
          )

          # the private DER never leaves the vault; project the public record
          # (SHIM-COURT-KV86: internal bookkeeping stripped too).
          send_json(
            conn,
            200,
            # R111: release_policy stays public (egress_dispatch_test.exs:415)
            Map.drop(key_record, ["key_material", "is_version_row", "versions"])
          )
        end
      else
        {:kty_error, kty} ->
          blob_error(conn, 400, %{
            "error" => %{
              "code" => "UnsupportedKeyType",
              "message" => "kty #{kty} is not supported"
            }
          })

        {:policy_error, message} ->
          blob_error(conn, 400, %{
            "error" => %{"code" => "InvalidParameter", "message" => message}
          })
      end
    end)
  end

  # Azure parity: POST /keys/{name}/rotate mints a new version from the SAME
  # policy (kty/key_ops/release_policy carried; old versions retained). Literal
  # route, NOT the kv_crypto_dispatch catch-all: the common rotate body is
  # EMPTY and with_valid_body? refuses %{} — rotation must not demand a body.
  # Defined before /keys/:name/:action so the literal wins.
  post "/keys/:name/rotate" do
    with_route(conn, KeyVaultActions, fn conn ->
      kv_respond(conn, KeyVaultActions.rotate_key(name, conn.body_params))
    end)
  end

  # Real JsonWebKey form: RSA carries n = base64url modulus, e = base64url
  # exponent ("AQAB" for 65537); oct carries k = base64url key material (the
  # derived AES key is deterministic per name — disclosed dev material).
  # The RSA private key is generated once at create and its DER cached in the
  # row ("key_material") for later crypto ops.
  defp jwk_for_kty(kty, _name, policy) when kty in ["RSA", "RSA-HSM"] do
    key = :public_key.generate_key({:rsa, 2048, 65537})
    der = :public_key.der_encode(:RSAPrivateKey, key)
    n = elem(key, 2)
    e = elem(key, 3)

    {:ok,
     %{
       "kty" => kty,
       "key_ops" => jwk_key_ops(kty, policy),
       "n" => Base.url_encode64(:binary.encode_unsigned(n), padding: false),
       "e" => Base.url_encode64(:binary.encode_unsigned(e), padding: false)
     }, der}
  end

  # SHIM-COURT: oct material is derived from the key NAME (and version), never
  # the kty — two different oct keys must project different JWK "k" values.
  defp jwk_for_kty(kty, name, policy) when kty in ["oct", "oct-HSM"] do
    k = Smalt.DataPlane.KeyVaultActions.derive_oct_key(name)

    {:ok,
     %{
       "kty" => kty,
       "key_ops" => jwk_key_ops(kty, policy),
       "k" => Base.url_encode64(k, padding: false)
     }, nil}
  end

  defp jwk_for_kty(kty, _name, _policy), do: {:kty_error, kty}

  # Default ops per key type, intersected with an explicit release-policy
  # `allowed_operations` list when one is present (Azure contract: the JWK
  # body advertises the ops the key may perform).
  defp jwk_key_ops(kty, policy) do
    default =
      if kty in ["oct", "oct-HSM"] do
        ["encrypt", "decrypt", "wrapKey", "unwrapKey"]
      else
        ["encrypt", "decrypt", "sign", "verify", "wrapKey", "unwrapKey"]
      end

    # SHIM-COURT: both spellings accepted; an explicit EMPTY list is deny-all
    # (key_ops []), absent/nil falls back to the defaults — empty ≠ absent.
    case policy do
      %{} = p when is_map_key(p, "allowed_operations") or is_map_key(p, "allowedOperations") ->
        ops = p["allowed_operations"] || p["allowedOperations"]

        if is_list(ops) do
          allowed = Enum.map(ops, &to_string/1)
          Enum.filter(default, &(&1 in allowed))
        else
          default
        end

      _ ->
        default
    end
  end

  # Accept BOTH smalt's `allowed_operations` form and the real Azure release
  # policy grammar (`anyOf`/`allOf`/`claim`/`equals`, nested; `version`,
  # `contentType` siblings). Stored verbatim; validated minimally: somewhere in
  # the structure there must be a claim/equals assertion or an explicit
  # allowed_operations list.
  defp validate_release_policy(nil), do: :ok

  defp validate_release_policy(policy) when is_map(policy) do
    if policy_has_claim?(policy) or policy_has_ops_list?(policy) do
      :ok
    else
      {:policy_error,
       "release_policy must be an Azure anyOf/allOf/claim/equals structure or an allowed_operations list"}
    end
  end

  defp validate_release_policy(_),
    do: {:policy_error, "release_policy must be a JSON object"}

  def policy_has_claim?(%{"claim" => _}), do: true

  def policy_has_claim?(policy) when is_map(policy) do
    Enum.any?(policy, fn {_k, v} -> policy_has_claim?(v) end)
  end

  def policy_has_claim?(list) when is_list(list), do: Enum.any?(list, &policy_has_claim?/1)
  def policy_has_claim?(_), do: false

  def policy_has_ops_list?(policy),
    do: is_list(policy["allowed_operations"] || policy["allowedOperations"])

  get "/keys/:name" do
    if :ets.info(:smalt_vault_keys) == :undefined do
      route_not_ready(conn)
    else
      case Store.get(:smalt_vault_keys, name) do
        # SHIM-COURT-KV86: strip internal bookkeeping fields, not just key_material.
        {:ok, key_record} ->
          send_json(
            conn,
            200,
            # R111: release_policy stays public (egress_dispatch_test.exs:415)
            Map.drop(key_record, ["key_material", "is_version_row", "versions"])
          )

        :error ->
          blob_error(conn, 404, not_found_error("KeyNotFound"))
      end
    end
  end

  post "/keys/:name/release" do
    # R143 (GAP S8): real AKV Secure Key Release requires ?api-version=7.x on
    # every request; a missing/wrong version is a typed 400 InvalidApiVersion
    # before any key/policy lookup. Mirrors the Sentinel DCR-ingest gate
    # (Sentinel.ingest/4 head pattern-match in data_plane/sentinel.ex).
    case check_akv_api_version(conn) do
      :ok ->
        case Smalt.DataPlane.SKR.release(name, conn) do
          # Lane 19 (v26.10.14) item 1: KV/SKR envelope pins must not see blob-plane
          # headers (F5 law). blob_error/3 stamps x-ms-request-id/x-ms-version on
          # the release 200 — rendered through send_json like every other KV route.
          {:ok, status, body} -> send_json(conn, status, body)
          {:error, status, body} -> send_json(conn, status, body)
        end

      {:error, status, body} ->
        send_json(conn, status, body)
    end
  end

  # ---------------------------------------------------------------------------
  # Key Vault crypto actions (Smalt.DataPlane.KeyVaultActions)
  # ---------------------------------------------------------------------------
  get "/keys" do
    with_route(conn, KeyVaultActions, fn conn ->
      case KeyVaultActions.list_keys() do
        # Lane 19 (v26.10.14) item 5: the previous `elem/2` catch-all raised
        # ArgumentError on a non-3-tuple return (unhandled 500 outside
        # safe_dispatch). The fallback arm is total: a 3-tuple (compiler's
        # dialyzed type is {:ok, _, _} only, so the error-tuple dispatch lives
        # in the fallback) renders through send_json; any other shape answers
        # a typed 500 envelope — no unhandled raise.
        {:ok, status, body} ->
          send_json(conn, status, body)

        other
        when is_tuple(other) and tuple_size(other) == 3 ->
          send_json(conn, elem(other, 1), elem(other, 2))

        other ->
          Logger.error("list_keys/0 returned unexpected shape: #{inspect(other)}")
          send_json(conn, 500, %{"error" => %{"code" => "InternalError"}})
      end
    end)
  end

  get "/keys/:name/versions" do
    with_route(conn, KeyVaultActions, fn conn ->
      case KeyVaultActions.list_versions(name) do
        {:ok, status, body} -> blob_error(conn, status, body)
        {:error, status, body} -> blob_error(conn, status, body)
      end
    end)
  end

  # GAP-A2-08: versioned key fetch — GET /keys/{name}/{version} serves that
  # key version's record (resolved from the {name, version} row the create
  # route stores). Unknown version -> 404 KeyNotFound. Defined AFTER
  # /keys/:name/versions so the literal segment wins.
  get "/keys/:name/:version" do
    if :ets.info(:smalt_vault_keys) == :undefined do
      route_not_ready(conn)
    else
      case Store.get(:smalt_vault_keys, {name, version}) do
        {:ok, key_record} ->
          # SHIM-COURT-KV86: strip internal bookkeeping fields from the wire record.
          send_json(
            conn,
            200,
            # R111: release_policy stays public (egress_dispatch_test.exs:415)
            Map.drop(key_record, ["key_material", "is_version_row", "versions"])
          )

        :error ->
          # R137: the R52 blob fallback here was dead code — the R99
          # reserved-namespace fence refuses every /keys first segment before
          # this route can serve, and the :2188 whitelist re-home made the
          # fallback obsolete. KeyNotFound 404 stands.
          blob_error(conn, 404, not_found_error("KeyNotFound"))
      end
    end
  end

  # Case-insensitive crypto action suffix: encrypt/decrypt/sign/verify/
  # wrapKey/unwrapKey. Defined AFTER the literal /keys/:name/create and
  # /keys/:name/release routes so it never shadows them; an unrecognized
  # action re-emits the catch-all 404 so behavior is unchanged.
  post "/keys/:name/:action" do
    kv_crypto_dispatch(conn, name, nil, action)
  end

  # GAP-A2-10: versioned crypto URLs — /keys/{name}/{version}/encrypt|decrypt|
  # sign|verify|wrapKey|unwrapKey route to the same handlers as the unversioned
  # form, resolving the named version (SDK CryptographyClient wire shape).
  post "/keys/:name/:version/:action" do
    kv_crypto_dispatch(conn, name, version, action)
  end

  patch "/keys/:name" do
    with_route(conn, KeyVaultActions, fn conn ->
      kv_respond(conn, KeyVaultActions.update_key_properties(name, conn.body_params))
    end)
  end

  patch "/keys/:name/:version" do
    with_route(conn, KeyVaultActions, fn conn ->
      kv_respond(conn, KeyVaultActions.update_key_properties(name, conn.body_params, version))
    end)
  end

  # KV soft-delete plane (wave I16/L1, 2026-10-17): key_vault_actions.ex has
  # implemented the full deleted-key lifecycle since the 26.10.14 lane, but
  # zero routes exposed it — every deleted-key wire shape answered the
  # catch-all 404 (KD-13/KD-75 class). Handlers are tuple-shaped for
  # kv_respond/2; routes go through with_route like their /keys siblings.
  delete "/keys/:name" do
    with_route(conn, KeyVaultActions, fn conn ->
      kv_respond(conn, KeyVaultActions.delete_key(name))
    end)
  end

  get "/deletedkeys" do
    with_route(conn, KeyVaultActions, fn conn ->
      kv_respond(conn, KeyVaultActions.list_deleted_keys())
    end)
  end

  get "/deletedkeys/:name" do
    with_route(conn, KeyVaultActions, fn conn ->
      kv_respond(conn, KeyVaultActions.get_deleted_key(name))
    end)
  end

  post "/deletedkeys/:name/recover" do
    with_route(conn, KeyVaultActions, fn conn ->
      kv_respond(conn, KeyVaultActions.recover_deleted_key(name))
    end)
  end

  post "/deletedkeys/:name/purge" do
    with_route(conn, KeyVaultActions, fn conn ->
      kv_respond(conn, KeyVaultActions.purge_deleted_key(name))
    end)
  end

  # Real Azure Key Vault purge shape (TS wf6 finding): KeyClient.purgeDeletedKey
  # sends bare `DELETE /deletedkeys/{name}` (204), NOT `POST .../purge`. The
  # POST shape was unrouted on the twin and fell through to the blob guarded
  # catch-all (`/{account}/{container}`), answering 400 MissingXMsVersion.
  delete "/deletedkeys/:name" do
    with_route(conn, KeyVaultActions, fn conn ->
      kv_respond(conn, KeyVaultActions.purge_deleted_key(name))
    end)
  end

  # KD-102: deleted-secrets plane — the secrets twin of /deletedkeys above.
  # Same bundle shape (recoveryId/deletedDate/scheduledPurgeDate), same
  # recover-200 / purge-204 / purge-protection-409 contracts. List/read are
  # namespaced from deleted keys by {:secret, name} tuple keys in the shared
  # deleted-bundle table (see KeyVaultActions).
  get "/deletedsecrets" do
    with_route(conn, KeyVaultActions, fn conn ->
      kv_respond(conn, KeyVaultActions.list_deleted_secrets())
    end)
  end

  get "/deletedsecrets/:name" do
    with_route(conn, KeyVaultActions, fn conn ->
      kv_respond(conn, KeyVaultActions.get_deleted_secret(name))
    end)
  end

  post "/deletedsecrets/:name/recover" do
    with_route(conn, KeyVaultActions, fn conn ->
      kv_respond(conn, KeyVaultActions.recover_deleted_secret(name))
    end)
  end

  post "/deletedsecrets/:name/purge" do
    with_route(conn, KeyVaultActions, fn conn ->
      kv_respond(conn, KeyVaultActions.purge_deleted_secret(name))
    end)
  end

  defp kv_crypto_dispatch(conn, name, version, action) do
    with_route(conn, KeyVaultActions, fn conn ->
      with_valid_body(conn, fn conn ->
        case String.downcase(action) do
          "encrypt" ->
            kv_respond(conn, KeyVaultActions.encrypt(name, conn.body_params, version))

          "decrypt" ->
            kv_respond(conn, KeyVaultActions.decrypt(name, conn.body_params, version))

          "sign" ->
            kv_respond(conn, KeyVaultActions.sign(name, conn.body_params, version))

          "verify" ->
            kv_respond(conn, KeyVaultActions.verify(name, conn.body_params, version))

          "wrapkey" ->
            kv_respond(conn, KeyVaultActions.wrap_key(name, conn.body_params, version))

          "unwrapkey" ->
            kv_respond(conn, KeyVaultActions.unwrap_key(name, conn.body_params, version))

          _other ->
            blob_error(conn, 404, %{
              "error" => %{
                "code" => "RouteNotFound",
                "message" => "No route matches #{conn.method} #{conn.request_path}"
              }
            })
        end
      end)
    end)
  end

  # ---------------------------------------------------------------------------
  # Key Vault Secrets (/secrets) — lane 345 (v26.10.16) item 8 (data plane)
  # Wire shape mirrors the /keys envelope: KV {"error":{...}} refusals,
  # id "https://{host}:8443/secrets/{name}/{version}", typed SecretNotFound.
  # Accepts BOTH the minimal body {value, attributes?} and the KV REST
  # attributes shape {enabled, expires|exp, contentType}.
  # ---------------------------------------------------------------------------
  get "/secrets" do
    if :ets.info(:smalt_vault_secrets) == :undefined do
      route_not_ready(conn)
    else
      send_json(conn, 200, %{
        "value" => Enum.map(Store.list(:smalt_vault_secrets), &list_secret_record/1)
      })
    end
  end

  put "/secrets/:name" do
    if :ets.info(:smalt_vault_secrets) == :undefined do
      route_not_ready(conn)
    else
      with_valid_body(conn, fn conn ->
        case secret_params(conn.body_params) do
          {:ok, value, attrs_in} ->
            version = Integer.to_string(System.unique_integer([:positive]))

            record =
              %{
                "value" => value,
                "id" => "https://#{conn.host}:8443/secrets/#{name}/#{version}",
                "attributes" =>
                  %{
                    "enabled" => Map.get(attrs_in, "enabled", true),
                    "created" => System.system_time(:second),
                    "updated" => System.system_time(:second)
                  }
                  |> Map.merge(secret_expiry(attrs_in)),
                "version" => version
              }
              |> maybe_put_content_type(attrs_in)

            # Re-set accumulates the new version as the latest (mirrors the
            # /keys re-create version-accumulation contract).
            Store.put(:smalt_vault_secrets, name, record)
            send_json(conn, 200, public_secret_record(record))

          :error ->
            blob_error(conn, 400, %{
              "error" => %{
                "code" => "InvalidParameter",
                "message" => "secret body requires a string \"value\""
              }
            })
        end
      end)
    end
  end

  get "/secrets/:name" do
    if :ets.info(:smalt_vault_secrets) == :undefined do
      route_not_ready(conn)
    else
      case Store.get(:smalt_vault_secrets, name) do
        {:ok, record} -> send_json(conn, 200, public_secret_record(record))
        :error -> blob_error(conn, 404, not_found_error("SecretNotFound"))
      end
    end
  end

  # KD-102 (secrets soft-delete plane): DELETE is a soft delete — the live row
  # moves to the deleted-bundle table and the response is the deleted-secret
  # bundle (id/attributes + recoveryId/deletedDate/scheduledPurgeDate), exactly
  # the real Azure SecretBundle delete contract. Live GET then 404s by
  # construction; recover/purge ride /deletedsecrets below.
  delete "/secrets/:name" do
    if :ets.info(:smalt_vault_secrets) == :undefined do
      route_not_ready(conn)
    else
      kv_respond(conn, KeyVaultActions.delete_secret(name))
    end
  end

  # Typed refusals for unimplemented sub-verbs (KD-comment style): they name
  # the gap with 501 NotImplemented instead of falling through to the blob
  # splat. The reserved-namespace fence still backstops the /secrets first
  # segment for splat-matched case variants (R137) — the literal routes above
  # always win first.
  get "/secrets/:name/versions" do
    secret_subverb_refusal(conn, "list versions")
  end


  # ---------------------------------------------------------------------------
  # Key Vault Certificates (KD-104, Smalt.DataPlane.Certificates)
  # ---------------------------------------------------------------------------
  post "/certificates/:name/create" do
    with_valid_body(conn, fn conn ->
      case Smalt.DataPlane.Certificates.create(name, conn, conn.body_params) do
        {:ok, status, body} -> send_json(conn, status, body)
        {:error, status, body} -> send_json(conn, status, body)
      end
    end)
  end

  get "/certificates" do
    {:ok, status, body} = Smalt.DataPlane.Certificates.list()
    send_json(conn, status, body)
  end

  get "/certificates/:name" do
    case Smalt.DataPlane.Certificates.get(name) do
      {:ok, status, body} -> send_json(conn, status, body)
      {:error, status, body} -> send_json(conn, status, body)
    end
  end

  # Soft delete (deleted-certificates class, parity with /deletedkeys and
  # /deletedsecrets): the live row moves to the {:deleted, name} tuple row in
  # the same heir'd table and the response is the deletedCertificate bundle
  # (recoveryId/deletedDate/scheduledPurgeDate). Live GET then 404s by
  # construction; recover/purge ride /deletedcertificates below.
  delete "/certificates/:name" do
    case Smalt.DataPlane.Certificates.delete(name) do
      {:ok, status, body} -> send_json(conn, status, body)
      {:error, status, body} -> send_json(conn, status, body)
    end
  end

  get "/deletedcertificates" do
    # list_deleted/0 always succeeds ({:ok, 200, map}); the dead {:error, ...}
    # clause here failed `mix compile --warnings-as-errors`, which is the
    # ggen_igniter.sync terminal verify gate (wave-4 MCP lane unblock, 2026-10-20).
    case Smalt.DataPlane.Certificates.list_deleted() do
      {:ok, status, body} -> send_json(conn, status, body)
    end
  end

  get "/deletedcertificates/:name" do
    case Smalt.DataPlane.Certificates.get_deleted(name) do
      {:ok, status, body} -> send_json(conn, status, body)
      {:error, status, body} -> send_json(conn, status, body)
    end
  end

  post "/deletedcertificates/:name/recover" do
    case Smalt.DataPlane.Certificates.recover(name) do
      {:ok, status, body} -> send_json(conn, status, body)
      {:error, status, body} -> send_json(conn, status, body)
    end
  end

  post "/deletedcertificates/:name/purge" do
    case Smalt.DataPlane.Certificates.purge(name) do
      {:ok, status, body} -> send_json(conn, status, body)
      {:error, status, body} -> send_json(conn, status, body)
    end
  end

  # KD-103 (capability wave 1): backup/restore via VaultData — the refusal
  # sites became real surfaces when backup_secret/restore_secret landed.
  post "/secrets/:name/backup" do
    if :ets.info(:smalt_vault_secrets) == :undefined do
      route_not_ready(conn)
    else
      case Smalt.DataPlane.VaultData.backup_secret(name) do
        {:ok, envelope} -> send_json(conn, 200, envelope)
        :error -> blob_error(conn, 404, not_found_error("SecretNotFound"))
      end
    end
  end

  post "/secrets/:name/restore" do
    if :ets.info(:smalt_vault_secrets) == :undefined do
      route_not_ready(conn)
    else
      with_valid_body(conn, fn conn ->
        case conn.body_params do
          %{"value" => blob} when is_binary(blob) ->
            case Smalt.DataPlane.VaultData.restore_secret(blob, conn.host) do
              {:ok, :created} ->
                send_json(conn, 201, %{"status" => "restored"})

              {:ok, :conflict} ->
                blob_error(conn, 409, %{
                  "error" => %{
                    "code" => "Conflict",
                    "message" =>
                      "secret already exists and is live; delete (or purge) it before restore"
                  }
                })

              {:error, code, msg} ->
                blob_error(conn, 400, %{"error" => %{"code" => code, "message" => msg}})
            end

          _ ->
            blob_error(conn, 400, %{
              "error" => %{
                "code" => "InvalidParameter",
                "message" => "restore body requires a string \"value\" (the backup blob)"
              }
            })
        end
      end)
    end
  end

  # Rotation-trigger cross-plane read-back (v26.10.16 ARM secret rotate lane):
  # the version minted by the ARM-plane POST .../rotate route must stay GET-able
  # BY VERSION on the data plane. The store keeps only the LATEST version per
  # bare name (re-PUT and rotate overwrite), so a non-latest version is a typed
  # 404 SecretNotFound — never a splat fall-through into the blob catch-all.
  get "/secrets/:name/:version" do
    if :ets.info(:smalt_vault_secrets) == :undefined do
      route_not_ready(conn)
    else
      case Store.get(:smalt_vault_secrets, name) do
        {:ok, %{"version" => rec_version} = record} when rec_version == version ->
          send_json(conn, 200, public_secret_record(record))

        _ ->
          blob_error(conn, 404, not_found_error("SecretNotFound"))
      end
    end
  end

  # ---------------------------------------------------------------------------
  # Azure App Configuration (/kv) — v26.10.16 lane 520 (C7 console gap)
  # KD-COVERS: KD-53. Wire contract per
  # docs/jira/v26.10.16/sdk-results/appconfig-console-gap.md. Storage:
  # :smalt_appconfig ETS keyed {key, label}; etag = sha256 content hash
  # (quoted). Feature-flag content type is an opaque passthrough (client-side
  # evaluation concern). Same KV challenge/tokenless posture as /secrets
  # (kv_challenge_guard above now covers the /kv prefix).
  # ---------------------------------------------------------------------------
  get "/kv" do
    if :ets.info(:smalt_appconfig) == :undefined do
      route_not_ready(conn)
    else
      key_filter = conn.query_params["key"]
      label_filter = conn.query_params["label"]

      items =
        Store.list_all(:smalt_appconfig)
        |> Enum.filter(fn record ->
          key_match = is_nil(key_filter) or String.starts_with?(record["key"], key_filter)
          label_match = is_nil(label_filter) or record["label"] == label_filter
          key_match and label_match
        end)
        |> Enum.map(&public_kv_record/1)

      conn
      |> put_resp_header("sync-token", kv_sync_token(Store.list_all(:smalt_appconfig)))
      |> send_json(200, %{"items" => items})
    end
  end

  put "/kv/:key" do
    if :ets.info(:smalt_appconfig) == :undefined do
      route_not_ready(conn)
    else
      with_valid_body(conn, fn conn ->
        label = conn.query_params["label"] || ""
        existing = Store.get(:smalt_appconfig, {key, label})
        if_match = if_match_value(conn)
        if_none_match = if_none_match_value(conn)

        cond do
          # create-only: refuse overwrite of an existing kv with 412
          if_none_match == "*" and existing != :error ->
            send_json(conn, 412, %{
              "error" => %{
                "code" => "PreconditionFailed",
                "message" => "kv #{key} (label #{label}) already exists"
              }
            })

          # CAS / unconditional-overwrite rules
          kv_precondition(existing, if_match) == :stale ->
            send_json(conn, 412, %{
              "error" => %{
                "code" => "PreconditionFailed",
                "message" => "If-Match precondition failed for kv #{key} (label #{label})"
              }
            })

          existing != :error and is_nil(if_match) and is_nil(if_none_match) ->
            send_json(conn, 409, %{
              "error" => %{
                "code" => "WriteConflict",
                "message" =>
                  "kv #{key} (label #{label}) exists; supply If-Match to overwrite " <>
                    "or If-None-Match: * for create-only"
              }
            })

          true ->
            {:ok, record} = kv_write(conn, key, label, existing)
            status = if existing == :error, do: 201, else: 200

            # T-04 (v26.10.28): kv create/modify publishes
            # AppConfigurationKeyValueModified (fire-and-forget — an event
            # failure never fails the kv write).
            publish_kv_change("AppConfigurationKeyValueModified", record)

            send_json(conn, status, public_kv_record(record))
        end
      end)
    end
  end

  get "/kv/:key" do
    if :ets.info(:smalt_appconfig) == :undefined do
      route_not_ready(conn)
    else
      label = conn.query_params["label"] || ""

      case Store.get(:smalt_appconfig, {key, label}) do
        {:ok, record} ->
          if if_none_match_value(conn) == record["etag"] do
            conn
            |> put_resp_header("etag", record["etag"])
            |> send_resp(304, "")
          else
            conn
            |> put_resp_header("etag", record["etag"])
            |> send_json(200, public_kv_record(record))
          end

        :error ->
          blob_error(conn, 404, not_found_error("KvNotFound"))
      end
    end
  end

  delete "/kv/:key" do
    if :ets.info(:smalt_appconfig) == :undefined do
      route_not_ready(conn)
    else
      label = conn.query_params["label"] || ""

      case Store.get(:smalt_appconfig, {key, label}) do
        :error ->
          blob_error(conn, 404, not_found_error("KvNotFound"))

        {:ok, record} ->
          if_match = if_match_value(conn)

          if is_nil(if_match) do
            # Real App Configuration: delete REQUIRES an If-Match (a missing
            # header is a 409, unlike PUT where absence imposes no
            # precondition and upsert is legal).
            blob_error(conn, 409, %{
              "code" => "MissingIfMatch",
              "message" => "If-Match header must be specified for the delete operation"
            })
          else
            if kv_precondition({:ok, record}, if_match) == :stale do
              send_json(conn, 412, %{
                "error" => %{
                  "code" => "PreconditionFailed",
                  "message" => "If-Match precondition failed for kv #{key} (label #{label})"
                }
              })
            else
              Store.delete(:smalt_appconfig, {key, label})

              # T-04 (v26.10.28): kv delete publishes
              # AppConfigurationKeyValueDeleted (fire-and-forget — an event
              # failure never fails the kv delete).
              publish_kv_change("AppConfigurationKeyValueDeleted", record)

              send_resp(conn, 204, "")
            end
          end
      end
    end
  end

  # ---------------------------------------------------------------------------
  # Azure App Configuration snapshots (v26.10.19 capability wave-2, W2N
  # fragment on the KD-53 plane). AppConfigSnapshots owns the typed state
  # machine; this fragment is wire-only. ROUTE ORDER IS LOAD-BEARING: this
  # block sits BEFORE the blob catch-all family — `/snapshots/:name` is
  # shape-identical to the blob splat `/:account/:container`, and when the
  # blob family claimed the path the PY wf7 lane witnessed MissingXMsVersion
  # instead of the snapshot surface (v26.10.19 wave-2 dispatch note).
  # ---------------------------------------------------------------------------
  get "/snapshots" do
    if :ets.info(:smalt_appconfig) == :undefined do
      route_not_ready(conn)
    else
      send_json(conn, 200, %{"items" => AppConfigSnapshots.list()})
    end
  end

  put "/snapshots/:name" do
    if :ets.info(:smalt_appconfig) == :undefined do
      route_not_ready(conn)
    else
      with_valid_body(conn, fn conn ->
        live_records = Store.list_all(:smalt_appconfig)

        case AppConfigSnapshots.create(name, conn.body_params, live_records) do
          {:ok, record} -> send_json(conn, 201, record)
          {:error, reason} -> snapshots_error(conn, reason)
        end
      end)
    end
  end

  get "/snapshots/:name" do
    if :ets.info(:smalt_appconfig) == :undefined do
      route_not_ready(conn)
    else
      case AppConfigSnapshots.get(name) do
        {:ok, record} -> send_json(conn, 200, record)
        {:error, reason} -> snapshots_error(conn, reason)
      end
    end
  end

  get "/snapshots/:name/kv" do
    if :ets.info(:smalt_appconfig) == :undefined do
      route_not_ready(conn)
    else
      case AppConfigSnapshots.kv_view(name) do
        {:ok, items} -> send_json(conn, 200, %{"items" => items})
        {:error, reason} -> snapshots_error(conn, reason)
      end
    end
  end

  post "/snapshots/:name/archive" do
    if :ets.info(:smalt_appconfig) == :undefined do
      route_not_ready(conn)
    else
      case AppConfigSnapshots.archive(name) do
        {:ok, record} -> send_json(conn, 200, record)
        {:error, reason} -> snapshots_error(conn, reason)
      end
    end
  end

  delete "/snapshots/:name" do
    if :ets.info(:smalt_appconfig_snapshots) == :undefined and
         :ets.info(:smalt_appconfig) == :undefined do
      route_not_ready(conn)
    else
      case AppConfigSnapshots.purge(name) do
        :ok -> send_resp(conn, 204, "")
        {:error, reason} -> snapshots_error(conn, reason)
      end
    end
  end

  # Typed snapshot error mapping: validation -> 400, absence -> 404,
  # state-machine conflicts -> 409 (the module emits {code, message} tuples;
  # the HTTP mapping is egress-owned by design, per the module's @moduledoc).
  defp snapshots_error(conn, {code, message}) do
    status =
      case code do
        c when c in ["InvalidFilter", "InvalidComposition"] -> 400
        c when c in ["SnapshotNotFound"] -> 404
        _ -> 409
      end

    send_json(conn, status, %{"error" => %{"code" => code, "message" => message}})
  end

  defp secret_subverb_refusal(conn, verb) do
    send_json(conn, 501, %{
      "error" => %{
        "code" => "NotImplemented",
        "message" =>
          "#{conn.method} #{conn.request_path} (#{verb}) is not implemented on " <>
            "the /secrets plane; nothing was stored."
      }
    })
  end

  # Accepts {value, attributes?} — attributes may carry enabled, expires|exp,
  # and contentType may ride top-level or inside attributes.
  def secret_params(%{"value" => value} = params) when is_binary(value) do
    attrs =
      params["attributes"]
      |> coerce_secret_attrs()
      |> Map.merge(Map.take(params, ["contentType"]))

    {:ok, value, attrs}
  end

  def secret_params(_), do: :error

  defp coerce_secret_attrs(%{} = attrs), do: attrs
  defp coerce_secret_attrs(_), do: %{}

  def secret_expiry(attrs_in) do
    case attrs_in["expires"] || attrs_in["exp"] do
      nil -> %{}
      exp -> %{"expires" => exp}
    end
  end

  def maybe_put_content_type(record, attrs_in) do
    case attrs_in["contentType"] do
      nil -> record
      ct -> Map.put(record, "contentType", ct)
    end
  end

  # List renders omit the secret value (Azure contract); GET keeps it.
  def public_secret_record(record), do: Map.drop(record, ["version"])

  def list_secret_record(record), do: record |> public_secret_record() |> Map.drop(["value"])

  # --- /kv (App Configuration) helpers ------------------- (KD-COVERS: KD-53)

  defp if_match_value(conn) do
    case get_req_header(conn, "if-match") do
      [v | _] -> v
      [] -> nil
    end
  end

  defp if_none_match_value(conn) do
    case get_req_header(conn, "if-none-match") do
      [v | _] -> v
      [] -> nil
    end
  end

  # :ok when the precondition permits the write, :stale when it fails.
  # `*` matches anything (including absent); an exact etag matches only that
  # etag; a missing header imposes no precondition.
  defp kv_precondition(_existing, nil), do: :ok

  # If-Match: * asserts the resource EXISTS (RFC 7232); on an absent kv the
  # precondition fails (412), even on the create path.
  defp kv_precondition(:error, "*"), do: :stale
  defp kv_precondition({:ok, _}, "*"), do: :ok

  defp kv_precondition({:ok, %{"etag" => etag}}, if_match) when is_binary(if_match) do
    if if_match == etag, do: :ok, else: :stale
  end

  defp kv_precondition(:error, _if_match), do: :stale

  defp kv_write(conn, key, label, _existing) do
    value = conn.body_params["value"]
    content_type = conn.body_params["contentType"]

    etag =
      :crypto.hash(:sha256, :erlang.term_to_binary({key, label, value, content_type}))
      |> Base.encode16()

    last_modified = System.system_time(:second)

    record = %{
      "key" => key,
      "label" => label,
      "value" => value,
      "contentType" => content_type,
      "etag" => "\"" <> etag <> "\"",
      "last_modified" => last_modified
    }

    Store.put(:smalt_appconfig, {key, label}, record)
    {:ok, record}
  end

  defp public_kv_record(record), do: record

  defp kv_sync_token(records) do
    max =
      records
      |> Enum.map(fn r -> r["last_modified"] || 0 end)
      |> Enum.max(fn -> 0 end)

    "smalt-#{max}"
  end

  # T-04 (v26.10.28): kv-plane change notifications. Every successful kv PUT
  # (create or modify) publishes AppConfigurationKeyValueModified and every
  # successful kv DELETE publishes AppConfigurationKeyValueDeleted into the
  # Event Grid engine under topic "appconfig" (real App Configuration
  # system-topic shape; webhook delivery rides the existing
  # EventGridWebhookPlug surface). FIRE-AND-FORGET law: an event-engine
  # failure must NEVER fail the kv write itself — the publish is
  # try/rescue-wrapped and logged (require Logger at the module head).
  # Precondition failures (412/409) and missing-kv deletes publish nothing.
  defp publish_kv_change(event_type, record) do
    event = kv_change_event(event_type, record["key"], record)

    try do
      Smalt.Messaging.EventGrid.publish("appconfig", event)
    rescue
      e ->
        Logger.error(
          "kv change event publish failed (kv write unaffected): " <>
            "eventType=#{event_type} key=#{inspect(event[:data][:key])} error=#{inspect(e)}"
        )
    end

    :ok
  end

  # Real Azure App Configuration system-topic event schema: id, eventType,
  # subject, eventTime, data {key, label, etag}. Subject is the bare key,
  # suffixed "|<label>" only when a non-empty label is set (real Azure omits
  # the suffix for the no-label kv). id (uuid) is the Event Grid dedup key.
  defp kv_change_event(event_type, key, record) do
    label = record["label"]

    subject =
      if label in [nil, ""], do: key, else: "#{key}|#{label}"

    %{
      id: kv_event_uuid(),
      eventType: event_type,
      subject: subject,
      eventTime: DateTime.utc_now() |> DateTime.to_iso8601(),
      data: %{key: key, label: label, etag: record["etag"]}
    }
  end

  # UUID v4 event id (Event Grid dedup key), same shape as
  # Messaging.EventStream.uuid4/0.
  defp kv_event_uuid do
    <<a::32, b::16, c_lo::12, _::4, d_lo::14, _::2, e::48>> = :crypto.strong_rand_bytes(16)

    <<a::32, b::16, 4::4, c_lo::12, 2::2, d_lo::14, e::48>>
    |> Base.encode16(case: :lower)
    |> then(fn hex ->
      <<h1::binary-size(8), h2::binary-size(4), h3::binary-size(4), h4::binary-size(4),
        h5::binary-size(12)>> = hex

      Enum.join([h1, h2, h3, h4, h5], "-")
    end)
  end

  # ---------------------------------------------------------------------------
  # Event Grid / Event Hubs CloudEvents ingestion (/topics/:topic/events)
  # ---------------------------------------------------------------------------
  post "/topics/:topic/events" do
    if not_ready?(conn, [EventStream]) do
      route_not_ready(conn)
    else
      case events_content_type(conn) do
        :json ->
          events_post(conn, topic)

        :unsupported ->
          send_json(conn, 415, %{
            "error" => %{
              "code" => "UnsupportedMediaType",
              "message" =>
                "CloudEvents ingestion requires a JSON content-type " <>
                  "(application/json, application/cloudevents+json, " <>
                  "application/cloudevents-batch+json)."
            }
          })
      end
    end
  end

  get "/topics/:topic/events" do
    if not_ready?(conn, [EventStream]) or
         not tables_ready?([:smalt_event_messages, :smalt_eg_topics]) do
      route_not_ready(conn)
    else
      # SHIM-COURT-adjacent readback merge (EG1 lane): CloudEvents events live
      # in :smalt_event_messages (EventStream), EG1 events in :smalt_eg_topics;
      # the readback merges both by stored seq so one topic's feed is one feed.
      send_json(
        conn,
        200,
        EventStream.list_events(topic)
        |> Kernel.++(Smalt.ArmGateway.Router.eg_topic_events(topic))
        |> Enum.sort_by(fn ev -> (is_map(ev) && ev["seq"]) || 0 end)
      )
    end
  end

  # ---------------------------------------------------------------------------
  # Azure Monitor Sentinel / Log Analytics
  # ---------------------------------------------------------------------------
  post "/dataCollectionRules/:dcr/streams/:stream" do
    with_route(conn, Sentinel, fn conn ->
      with_valid_body(conn, fn conn ->
        api_version = Map.get(conn.query_params, "api-version", "")

        case normalize_list_body(conn) do
          {:ok, batch} ->
            case Sentinel.ingest(dcr, stream, batch, api_version) do
              {:ok, 204, _body} ->
                conn
                |> put_resp_header("x-ms-request-id", generate_request_id())
                |> send_resp(204, "")

              {:ok, status, body} ->
                blob_error(conn, status, body)

              {:error, status, body} ->
                blob_error(conn, status, body)
            end

          {:error, :invalid_body} ->
            blob_error(conn, 400, invalid_body_error())
        end
      end)
    end)
  end

  post "/v1/workspaces/:workspace_id/query" do
    with_route(conn, Sentinel, fn conn ->
      with_valid_body(conn, fn conn ->
        # R143 (GAP D8, repaired R173): reject an explicitly-wrong api-version
        # on the KQL query route; absence is the SDK's real wire shape (v1 in
        # path is the version discriminator).
        case check_sentinel_api_version(conn) do
          :ok ->
            case Sentinel.query(workspace_id, conn.body_params) do
              {:ok, status, body} -> blob_error(conn, status, body)
              {:error, status, body} -> blob_error(conn, status, body)
            end

          {:error, status, body} ->
            blob_error(conn, status, body)
        end
      end)
    end)
  end

  # ---------------------------------------------------------------------------
  # Azure Resource Graph
  # ---------------------------------------------------------------------------
  post "/providers/Microsoft.ResourceGraph/resources" do
    with_route(conn, ResourceGraph, fn conn ->
      with_valid_body(conn, fn conn ->
        body = conn.body_params || %{}
        subscriptions = Map.get(body, "subscriptions")

        case ResourceGraph.query(
               subscriptions,
               body,
               Map.get(conn.query_params, "api-version", "")
             ) do
          {:ok, status, resp} -> blob_error(conn, status, resp)
          {:error, status, resp} -> blob_error(conn, status, resp)
        end
      end)
    end)
  end

  # ---------------------------------------------------------------------------
  # Microsoft Purview Catalog (Atlas v2)
  # ---------------------------------------------------------------------------
  # POST /atlas/v2/relationship: mints a lineage edge via Purview.put_edge
  # (Atlas v2 wire shape: {"relationship": {"end1": {"guid"...},
  # "end2": {...}, "typeName": ...}}). The edge lands in :smalt_purview_edges,
  # which GET /atlas/v2/lineage already BFSes — lineage relations become
  # wire-visible immediately.
  post "/atlas/v2/relationship" do
    with_route(conn, Purview, fn conn ->
      with_valid_body(conn, fn conn ->
        rel = conn.body_params["relationship"] || conn.body_params
        from = rel["end1"]["guid"] || rel["end1"]["id"] || rel["fromEntityId"]
        to = rel["end2"]["guid"] || rel["end2"]["id"] || rel["toEntityId"]
        type_name = rel["typeName"] || "smalt_lineage"

        if is_binary(from) and is_binary(to) do
          relationship_id = rel["id"] || "#{from}->#{to}:#{type_name}"

          edge =
            Purview.put_edge(from, to, type_name, %{
              "relationshipId" => relationship_id,
              "id" => relationship_id,
              "linkType" => rel["linkType"] || "Child"
            })

          send_json(conn, 201, %{"guid" => edge["relationshipId"], "id" => edge["id"]})
        else
          blob_error(conn, 400, %{
            "error" => %{
              "code" => "ATLAS-400-00-001",
              "message" => "relationship requires end1/end2 guids"
            }
          })
        end
      end)
    end)
  end

  post "/atlas/v2/entity" do
    with_route(conn, Purview, fn conn ->
      with_valid_body(conn, fn conn ->
        case Purview.create_entity(conn.body_params, header_map(conn)) do
          {:ok, status, entity} -> blob_error(conn, status, entity)
          {:error, status, body} -> blob_error(conn, status, body)
        end
      end)
    end)
  end

  post "/atlas/v2/entity/bulk" do
    with_route(conn, Purview, fn conn ->
      with_valid_body(conn, fn conn ->
        case Purview.bulk_entities(conn.body_params, header_map(conn)) do
          {:ok, status, body} -> blob_error(conn, status, body)
          {:error, status, body} -> blob_error(conn, status, body)
        end
      end)
    end)
  end

  get "/atlas/v2/entity/guid/:guid" do
    with_route(conn, Purview, fn conn ->
      case Purview.get_entity(guid, header_map(conn)) do
        {:ok, status, entity} -> blob_error(conn, status, entity)
        {:error, status, body} -> blob_error(conn, status, body)
      end
    end)
  end

  get "/atlas/v2/lineage/:direction/:guid" do
    with_route(conn, Purview, fn conn ->
      depth = Map.get(conn.query_params, "depth", "1")

      case Purview.lineage(guid, direction, depth) do
        {:ok, status, body} -> blob_error(conn, status, body)
        {:error, status, body} -> blob_error(conn, status, body)
      end
    end)
  end

  # ---------------------------------------------------------------------------
  # Cosmos DB account bootstrap (GET "/") — the @azure/cosmos SDK's
  # ClientContext.create → getDatabaseAccount reads the account root. Minimal
  # DatabaseAccount body: id (must NOT be "localhost" — the SDK skips location
  # parsing for that id), writable/readableLocations with a
  # databaseAccountEndpoint pointing back at this egress plane.
  # ---------------------------------------------------------------------------
  get "/" do
    base = "#{conn.scheme}://#{conn.host}:#{conn.port}/"
    # DIVERGENCE (display-name vs ARM-name): the Cosmos data-plane contract
    # advertises the writable/readable location as the display name "East US",
    # while arm_gateway/provider_matrix.ex advertises canonical ARM names
    # ("eastus"). Real Cosmos getDatabaseAccount does return display-name
    # forms here, and this contract predates the ARM surface — do NOT change
    # to the ARM form; the azurerm↔cosmos naming divergence is documented,
    # not unified. Consumers that copy this name into an ARM PUT must map it
    # ("East US" -> "eastus") to stay zero-drift against the matrix.
    location = %{"name" => "East US", "databaseAccountEndpoint" => base}

    conn
    |> put_resp_header("x-ms-request-charge", "1.0")
    |> put_resp_content_type("application/json")
    |> send_resp(
      200,
      Jason.encode!(%{
        # python azure-cosmos GetDatabaseAccount shape (documents.DatabaseAccount)
        # + the .NET/JS account fields; additive only.
        "kind" => "DatabaseAccount",
        "_self" => "",
        "id" => "smalt",
        "databasesLink" => "/dbs/",
        "mediaLink" => "/media/",
        "addressesLink" => "/addresses/",
        "enableMultipleWriteLocations" => false,
        "writableLocations" => [location],
        "readableLocations" => [location],
        "userConsistencyPolicy" => %{"defaultConsistencyLevel" => "Session"}
      })
    )
  end
  # ---------------------------------------------------------------------------
  # Internals
  # ---------------------------------------------------------------------------

  # Trailing-slash tolerance for the Cosmos surface only (blob catch-all
  # depends on exact path shape; other services unchanged).
  defp trim_dbs_trailing_slash(%Plug.Conn{path_info: ["dbs" | rest]} = conn, _opts) do
    if rest != [] and List.last(rest) == "" do
      %{conn | path_info: List.delete_at(conn.path_info, -1)}
    else
      conn
    end
  end

  defp trim_dbs_trailing_slash(conn, _opts), do: conn

  # Body parsing is route-conditional. Plug.Parsers CONSUMES the request body
  # for json/urlencoded content-types, which would leave the raw blob PUT
  # (PUT /:account/:container/:blob) with an empty stream — an urlencoded
  # content-type used to store a zero-byte blob. Blob PUTs without a `comp`
  # query parameter are therefore exempted from parsing; the handler reads the
  # raw body itself. Every other request is parsed exactly as before.
  @parsers_opts parsers: [:json, :urlencoded], pass: ["*/*"], json_decoder: Jason

  defp maybe_parse_body(conn, _opts) do
    if raw_blob_put?(conn) do
      conn
    else
      Plug.Parsers.call(conn, Plug.Parsers.init(@parsers_opts))
    end
  end

  # Blob-route PUT shapes are exactly `/:account/:container/*blob_name`
  # (3+ segments, no `comp` query). The exemption is a WHITELIST of the
  # literal route prefixes that own a 3+-segment PUT route — each entry is
  # load-bearing and mutation-proven (drop it and the corresponding wire
  # probe dies). Adding a literal 3+-segment PUT route REQUIRES extending
  # this list; a missed entry fails visible (parsed body on a blob PUT =>
  # zero-byte store, fenced below) instead of silent parse-swallow of a
  # service route (the lens-3 Cosmos regression this replaces).
  @non_blob_put_namespaces ~w(dbs)

  # Decoded-to-decoded invariant (lane R154): Plug path_info segments are RAW
  # (R137 finding), so a percent-encoded first segment (`PUT /%64bs/...` ==
  # `/dbs/...`) matched the raw set, was exempted from nothing, and got its
  # urlencoded body parsed as blob content before the decoded reserved fence
  # refused. Decode first, then match — mirroring the fence's decode-aware
  # pattern. Decoded names behave unchanged.
  defp raw_blob_put?(%Plug.Conn{method: "PUT", path_info: [first, _, _ | _]} = conn) do
    # SHIM-COURT: decode+downcase mirrors the fence (:reserved_fence_then),
    # else a case-variant first segment (/DBS/...) skipped the raw-PUT
    # exemption and got its body parsed as blob content before the fence.
    if String.downcase(URI.decode(first)) in @non_blob_put_namespaces do
      false
    else
      params = fetchd_query_params(conn)
      Map.get(params, "comp") in [nil, ""]
    end
  end

  # KD-108 (ACL wire seam): Put Container ACL (PUT /:account/:container
  # ?restype=container&comp=acl) carries a RAW SignedIdentifiers XML body.
  # Without the exemption Plug.Parsers' :urlencoded parser consumes it (curl's
  # default Content-Type for --data-binary is x-www-form-urlencoded; SDKs send
  # text/xml variants that can match json/urlencoded decoders), the arm's
  # read_body then returns "" and parse_signed_identifiers("") == {:ok, []}
  # silently CLEARS the ACL — the witnessed PUT-204-then-empty-GET divergence.
  # Reserved first segments (dbs, ...) still go through the parsers.
  defp raw_blob_put?(%Plug.Conn{method: "PUT", path_info: [first, _container]} = conn) do
    String.downcase(URI.decode(first)) not in @non_blob_put_namespaces and
      fetchd_query_params(conn) |> Map.get("comp") == "acl"
  end

  # KD-COVERS: KD-122 — Set Blob Service Properties
  # (PUT /:account?restype=service&comp=properties) carries a RAW
  # StorageServiceProperties XML body; without this exemption Plug.Parsers'
  # :urlencoded parser consumes it (curl's default --data-binary Content-Type)
  # and the route stores empty <Cors> rules / StaticWebsite props under a
  # lying 202 (witnessed 2026-10-20: PUT=202 then preflight 403-empty;
  # root cause proven by lane B1 on a private beam — ETS held {"popcorn", []}).
  # (re-landed from the pre-undock source 95d4243d)
  defp raw_blob_put?(%Plug.Conn{method: "PUT", path_info: [_account]} = conn) do
    params = fetchd_query_params(conn)
    params["restype"] == "service" and params["comp"] == "properties"
  end

  # KD-COVERS: KD-123 — Put Message (POST /:account/:queue/messages)
  # carries a raw QueueMessage XML body. Without this exemption Plug.Parsers'
  # :urlencoded parser consumes the body (curl's default --data Content-Type
  # is x-www-form-urlencoded), read_queue_body then sees "" and put_message
  # stores an EMPTY MessageText under a lying 201 (witnessed 2026-10-20,
  # lane ERRC-R4: urlencoded POST -> empty payload on dequeue;
  # application/xml round-trips correctly). Same parser-consumed-body class
  # as KD-108 / KD-122; the path shape mirrors queue_plane_route/3's
  # put_messages clause exactly.
  # (re-landed from the pre-undock source 95d4243d)
  defp raw_blob_put?(%Plug.Conn{method: "POST", path_info: [_account, _queue, "messages"]}),
    do: true

  # D9 lane (athena differential, 2026-10-25): the marketplace SaaS face
  # (/saas/* — Smalt.Egress.MarketplaceRoutes) reads its JSON bodies with its
  # own Plug.Conn.read_body inside the sub-router. Plug.Parsers consumes any
  # application/json body BEFORE the sub-router chain runs, so every real-wire
  # activate/patch/usageEvent carrying `content-type: application/json`
  # reached the handler with an empty raw stream and answered a lying
  # 400 "invalid JSON body" (witnessed on the live 8443 wire: resolve 200,
  # activate 400). The in-process court missed it because its raw-socket
  # helper sends NO content-type, so the parsers never matched. The /saas
  # prefix is marketplace-owned (no other plane serves it), so exempt the
  # whole family and let the handler read raw — the exact shape its own
  # integration court exercises.
  # (re-landed from the pre-undock source 95d4243d)
  defp raw_blob_put?(%Plug.Conn{method: m, path_info: ["saas" | _]})
       when m in ["POST", "PATCH"],
    do: true

  defp raw_blob_put?(_conn), do: false
  def fetchd_query_params(%Plug.Conn{query_params: %Plug.Conn.Unfetched{}} = conn),
    do: fetch_query_params(conn).query_params

  def fetchd_query_params(%Plug.Conn{query_params: params}), do: params

  # The python azure-cosmos SDK reads partitionKeyDefinition["kind"]
  # (_ExtractPartitionKey in _cosmos_client_connection.py); a container record
  # without "kind" KeyErrors inside the SDK. Additive: only fills the field
  # when the engine record omits it.
  def with_pk_kind(%{"partitionKey" => %{} = pk} = record) do
    %{record | "partitionKey" => Map.put_new(pk, "kind", "Hash")}
  end

  def with_pk_kind(record), do: record

  # The python azure-cosmos SDK sends the partition key as a bare JSON string
  # ("/pk") in the CreateContainer body; the JS SDK sends {"paths": [...]},
  # .NET the same. Normalize the string form to the paths form at the seam.
  def normalize_pk_body(%{"partitionKey" => pk} = body) when is_binary(pk) do
    Map.put(body, "partitionKey", %{"paths" => [pk]})
  end

  def normalize_pk_body(body), do: body

  # Runs `fun` only when every module is loaded; fails closed with 503
  # RouteNotReady otherwise. This is the only seam that probes compile status.
  def with_route(conn, modules, fun) do
    if not_ready?(conn, List.wrap(modules)) do
      route_not_ready(conn)
    else
      fun.(conn)
    end
  end

  # Lens7 law: a missing coordinator-owned ETS table is server not-ready, not
  # a raw 500 from :ets raising ArgumentError inside a list walk.
  def tables_ready?(tables) do
    Enum.all?(tables, fn t -> :ets.info(t) != :undefined end)
  end

  # AZB-15 data-plane DR: a killed Store subtree is "server not ready", never
  # a raw 500 from :ets raising on a dead table. When the data subtree's
  # coordinator-owned tables are gone, every guarded surface answers the same
  # typed retryable 503 the module-load guard already yields.
  def not_ready?(_conn, modules) do
    (not Enum.all?(modules, &Code.ensure_loaded?/1)) or not tables_ready?(Smalt.Store.table_names())
  end

  # Restored (was dropped from source post-c72e47c3 while callers in
  # auth/shared_key.ex and mcp/router.ex remained — stale-beam masked until
  # the v26.10.29 merge forced recompile). Historical body: 2958d200:863.
  def account_key(account) do
    case Application.get_env(:smalt, :blob_account_key) ||
           System.get_env("SMALT_BLOB_ACCOUNT_KEY") do
      key when is_binary(key) and key != "" ->
        {:ok, key}

      _ ->
        {:ok, Base.encode64(:crypto.hash(:sha256, account <> "smalt-dev-sb"))}
    end
  end

  # Restored from 8261a435:150 — see account_key/1 note above.
  def loopback_origin?(origin) when is_binary(origin) do
    case URI.parse(origin).host do
      nil -> false
      host -> String.downcase(host) in ["127.0.0.1", "localhost", "::1"] or String.ends_with?(host, ".localhost")
    end
  end

  def loopback_origin?(_), do: false

  # Public (def, not defp): the lib/smalt/egress/* delegator routers import
  # this module and call these helpers — private helpers cannot be imported.
  def route_not_ready(conn) do
    # R50 repair 1: the 503 answers with blob_error-style header discipline
    # (x-ms-request-id + x-ms-version) — real Azure stamps request-id on
    # error responses, not only on the blob_error-rendered ones.
    conn
    |> put_resp_header("x-ms-request-id", generate_request_id())
    |> put_resp_header("x-ms-version", "2021-12-02")
    |> send_json(503, %{"error" => %{"code" => "RouteNotReady"}})
  end

  # R143 (GAP S8): real AKV requires ?api-version=7.x on every request. A
  # missing/wrong version is a typed 400 InvalidApiVersion before any key or
  # policy lookup. The gate lives at the router seam (route handler is the
  # only place `conn` query params are visible to the SKR flow).
  # AZB-08 config read site: the pinned 7.x grammar stays (wire-compat), but
  # the example version in the refusal message is the configured
  # `:keyvault, api_version` (default "7.4") — single source, no dual truth.
  def check_akv_api_version(conn) do
    version = Map.get(conn.query_params, "api-version", "")
    example = Smalt.DataPlane.KeyVaultActions.api_version()

    if Regex.match?(~r/^7\.\d+$/, version) do
      :ok
    else
      {:error, 400,
       %{
         "error" => %{
           "code" => "InvalidApiVersion",
           "message" => "api-version must be 7.x (e.g. api-version=#{example})"
         }
       }}
    end
  end
  # R143 (GAP D8, repaired R173): the real azure-monitor-query client sends
  # KQL queries to /v1/workspaces/:id/query with NO api-version query param
  # (live wire capture) — the `v1` path segment IS the version discriminator.
  # A param-required gate is unsatisfiable by the real SDK. Parity contract:
  # absent param is accepted; an explicitly-wrong value is still rejected
  # (typed 400 InvalidApiVersion), preserving the mutation-detection value of
  # the original gate. The DCR ingest route keeps its strict gate — the real
  # ingest API does carry api-version=2023-01-01.
  def check_sentinel_api_version(conn) do
    case Map.get(conn.query_params, "api-version", "") do
      "" ->
        :ok

      "2023-01-01" ->
        :ok

      _other ->
        {:error, 400,
         %{
           "error" => %{
             "code" => "InvalidApiVersion",
             "message" => "api-version must be 2023-01-01"
           }
         }}
    end
  end
  def header_map(conn) do
    Map.new(conn.req_headers)
  end

  # Sentinel DCR ingest body handling: total — object wraps to a single-event
  # batch, list is the batch, anything else (nil/Unfetched/scalars) is an
  # InvalidBody refusal instead of a FunctionClauseError 500.
  def normalize_list_body(conn) do
    case conn.body_params do
      %Plug.Conn.Unfetched{} ->
        case read_raw_body(conn) do
          {:ok, raw} -> decode_batch(raw)
          :error -> {:error, :invalid_body}
        end

      params when is_list(params) ->
        {:ok, params}

      params when is_map(params) ->
        {:ok, wrap_json_list(params)}

      _other ->
        {:error, :invalid_body}
    end
  end

  def read_raw_body(conn) do
    case Plug.Conn.read_body(conn) do
      {:ok, raw, _conn} -> {:ok, raw}
      _ -> :error
    end
  end

  defp decode_batch(raw) do
    case Jason.decode(raw) do
      {:ok, payload} when is_list(payload) -> {:ok, payload}
      {:ok, %{} = payload} -> {:ok, wrap_json_list(payload)}
      _ -> {:error, :invalid_body}
    end
  end

  # Total batch normalization: a "_json"-enveloped map unwraps to its batch
  # (or wraps a single value); a plain JSON object wraps as a single-event
  # batch; a list is already a batch.
  def wrap_json_list(%{"_json" => list}) when is_list(list), do: list
  def wrap_json_list(%{"_json" => single}), do: List.wrap(single)
  def wrap_json_list(%{} = single), do: [single]
  def wrap_json_list(batch) when is_list(batch), do: batch
  def wrap_json_list(_other), do: {:error, :invalid_body}

  # Body-parameter seam guard: Plug.Parsers is configured with pass: ["*/*"],
  # so a non-JSON content-type (or an empty body) leaves body_params as
  # %Plug.Conn.Unfetched{} (or a scalar). Data-plane handlers that consume
  # body_params as JSON must never see that — refuse with a 400 envelope at
  # this seam instead of crashing with a 500 inside a callee.
  # Public for the egress delegator routers (see route_not_ready/1 note).
  def with_valid_body(conn, fun) do
    if valid_json_body?(conn.body_params) do
      safe_dispatch(conn, fun)
    else
      send_json(conn, 400, invalid_body_error())
    end
  end

  defp valid_json_body?(%Plug.Conn.Unfetched{}), do: false

  # Plug.Parsers wraps a decoded non-map JSON body (null / scalar / top-level
  # array on older Plug) as %{"_json" => term}. Admitting that wrapper let
  # `POST /app/transactions` with body `null` or `5` append a garbage ledger
  # entry (measured 201). The only legitimate wrapped form on this surface is
  # the batch list (Sentinel/events unwrap it downstream), so refuse the
  # wrapper unless the wrapped value is a list.
  defp valid_json_body?(%{"_json" => wrapped}) when not is_list(wrapped), do: false

  # Plug.Parsers wraps a decoded non-map JSON body (null / scalar / top-level
  # array on older Plug) as %{"_json" => term}. Admitting that wrapper through
  # the gate let `POST /app/transactions` with body `null` or `5` append a
  # garbage ledger entry (measured 201). The only legitimate wrapped form on
  # this surface is the batch list (Sentinel/events unwrap it downstream), so
  # refuse the wrapper unless the wrapped value is a list.
  # An empty JSON object body ({} / truly empty body with application/json) is
  # not an admission either — measured: `POST /app/transactions` with an empty
  # body appended an empty ledger entry (201). Real Azure surfaces refuse an
  # empty object on append/create verbs.
  defp valid_json_body?(params) when params == %{}, do: false

  defp valid_json_body?(params) when is_map(params) or is_list(params), do: true
  defp valid_json_body?(_other), do: false

  # Public for the egress delegator routers (see route_not_ready/1 note).
  def invalid_body_error do
    %{"error" => %{"code" => "InvalidBody"}}
  end

  # Belt-and-braces: even with the seam guard, a malformed parameter that
  # slips through to a callee (ConfidentialLedger.canonical/1,
  # Cosmos.quoted_sha256/1, ...) must degrade to a 400 envelope, never a 500.
  # Public (def, not defp): re-landed from the pre-undock source (95d4243d) —
  # the bk101 G3 seam probe calls Smalt.EgressRouter.safe_dispatch/2 directly
  # and the undock demoted it to private.
  def safe_dispatch(conn, fun) do
    fun.(conn)
  rescue
    # R50 repair 3: CaseClauseError admitted (measured through the ledger
    # append clause mismatch, comment at post /app/transactions) — typed 400
    # InvalidBody, never a blanket catch-all.
    e in [
      Protocol.UndefinedError,
      ArgumentError,
      BadMapError,
      FunctionClauseError,
      CaseClauseError
    ] ->
      Logger.warning("egress invalid body on #{conn.request_path}: #{inspect(e.__struct__)}")

      send_json(conn, 400, invalid_body_error())
  end

  # CloudEvents ingestion body handling.
  #
  # Content-type gate: anything whose content-type does not carry `json`
  # (application/json, application/cloudevents+json,
  # application/cloudevents-batch+json, any +json suffix) is refused with 415
  # UnsupportedMediaType — never the previous BadMapError 500.
  #
  # Body shapes, all-or-nothing: a single JSON OBJECT with an in-body
  # specversion is one structured event; a top-level JSON ARRAY is a batch
  # (including Plug.Parsers' `"_json"` envelope); a JSON OBJECT without an
  # in-body specversion is binary mode when ce-* headers are present — the
  # event is constructed from the ce-* headers with the body as `data`.
  #
  # Admission is all-or-nothing: every event is validated against the
  # CloudEvents 1.0 required context attributes BEFORE any store write; the
  # first invalid event fails the whole batch with
  # 400 {"error":{"code":"InvalidCloudEvent",...}} and nothing is stored.
  def events_content_type(conn) do
    case get_req_header(conn, "content-type") do
      [ct] -> if String.contains?(ct, "json"), do: :json, else: :unsupported
      _ -> :unsupported
    end
  end

  def events_post(conn, topic) do
    # SHIM-COURT-adjacent per-topic schema gate (EG1 lane): a topic declared
    # inputSchema "EventGrid" in :smalt_eg_topics (via the ARM control plane,
    # Microsoft.EventGrid/topics PUT) admits the EG1 single-event envelope;
    # every other topic keeps CloudEvents 1.0-only admission — the EG1 refusal
    # stays the default for un-schema'd topics (GAP(eventgrid-eg1-schema-absent)
    # closes for DECLARED topics only).
    if Smalt.ArmGateway.Router.eg_topic_input_schema(topic) == "EventGrid" do
      case eg1_decode_events(conn) do
        {:ok, events} ->
          case Smalt.ArmGateway.Router.eg1_publish(topic, events) do
            {:ok, _ids} ->
              respond_published(conn, topic, events)

            {:error, :invalid_eg1_event} ->
              send_json(conn, 400, invalid_eg1_event_error())
          end

        {:error, :invalid_eg1_event} ->
          send_json(conn, 400, invalid_eg1_event_error())
      end
    else
      eg_cloudevents_post(conn, topic)
    end
  end

  defp eg_cloudevents_post(conn, topic) do
    case decode_events(conn) do
      {:ok, events} ->
        case validate_events(events) do
          :ok ->
            case EventStream.publish_events(topic, events) do
              :ok ->
                respond_published(conn, topic, events)

              {:error, :invalid_cloudevent} ->
                send_json(conn, 400, invalid_cloudevent_error())
            end

          {:error, :invalid_cloudevent} ->
            send_json(conn, 400, invalid_cloudevent_error())
        end

      {:error, :invalid_cloudevent} ->
        send_json(conn, 400, invalid_cloudevent_error())
    end
  end

  # EG1 body shapes mirror the CloudEvents ones: a top-level JSON OBJECT is a
  # single envelope, a JSON ARRAY (incl. Plug's "_json" envelope) is a batch.
  defp eg1_decode_events(conn) do
    case conn.body_params do
      %Plug.Conn.Unfetched{} ->
        case read_raw_body(conn) do
          {:ok, raw} ->
            case Jason.decode(raw) do
              {:ok, payload} -> {:ok, eg1_wrap(payload)}
              {:error, _} -> {:error, :invalid_eg1_event}
            end

          :error ->
            {:error, :invalid_eg1_event}
        end

      params when is_list(params) ->
        {:ok, params}

      params when is_map(params) ->
        cond do
          Map.has_key?(params, "_json") -> {:ok, eg1_wrap(params["_json"])}
          true -> {:ok, [params]}
        end

      _other ->
        {:error, :invalid_eg1_event}
    end
  end

  defp eg1_wrap(payload) when is_list(payload), do: payload
  defp eg1_wrap(payload), do: [payload]

  defp invalid_eg1_event_error do
    %{
      "error" => %{
        "code" => "InvalidEventGridEvent",
        "message" =>
          "Event failed Event Grid schema (EG1) validation: id, subject, eventType, " <>
            "eventTime must be non-empty strings and data must be present. " <>
            "Ingestion is all-or-nothing; no events from this batch were stored."
      }
    }
  end

  # Real Event Grid publish answers 200 with an EMPTY body. The legacy
  # {"status":"Published",...} envelope stays reachable only through
  # :smalt, :eventgrid_response_mode == "per-event" (compat escape hatch):
  # a single event keeps the old envelope; a batch answers with a per-event
  # status array [{"id":..., "status":"Published"}, ...].
  defp respond_published(conn, topic, events) do
    case Application.get_env(:smalt, :eventgrid_response_mode, "real") do
      "per-event" ->
        case events do
          [event] when is_map(event) and not is_list(event) ->
            send_json(conn, 200, %{
              "status" => "Published",
              "topic" => topic,
              "id" => Map.get(event, "id")
            })

          batch when is_list(batch) ->
            send_json(
              conn,
              200,
              Enum.map(batch, &%{"id" => Map.get(&1, "id"), "status" => "Published"})
            )
        end

      _ ->
        send_resp(conn, 200, "")
    end
  end

  defp invalid_cloudevent_error do
    %{
      "error" => %{
        "code" => "InvalidCloudEvent",
        "message" =>
          "Event failed CloudEvents 1.0 validation: specversion must be \"1.0\", " <>
            "source and type must be present and non-empty. Ingestion is " <>
            "all-or-nothing; no events from this batch were stored."
      }
    }
  end

  defp decode_events(conn) do
    case conn.body_params do
      %Plug.Conn.Unfetched{} ->
        case read_raw_body(conn) do
          {:ok, raw} -> decode_events_payload(raw)
          :error -> {:error, :invalid_cloudevent}
        end

      params when is_list(params) ->
        {:ok, params}

      params when is_map(params) ->
        cond do
          Map.has_key?(params, "_json") ->
            {:ok, wrap_json_list(params)}

          is_binary(params["specversion"]) ->
            {:ok, [params]}

          binary_mode_headers?(conn) ->
            {:ok, [binary_mode_event(conn, params)]}

          true ->
            {:error, :invalid_cloudevent}
        end

      _other ->
        {:error, :invalid_cloudevent}
    end
  end

  defp decode_events_payload(raw) do
    case Jason.decode(raw) do
      {:ok, payload} -> {:ok, wrap_json_list(%{"_json" => payload})}
      {:error, _} -> {:error, :invalid_cloudevent}
    end
  end

  # Binary mode: ce-* headers carry the context attributes, the body is the
  # event data. Requires ce-specversion plus at least one of ce-source/ce-type.
  defp binary_mode_headers?(conn) do
    ce_headers = ce_attributes(conn)

    is_binary(ce_headers["specversion"]) and
      (is_binary(ce_headers["source"]) or is_binary(ce_headers["type"]))
  end

  defp binary_mode_event(conn, body) do
    event = ce_attributes(conn)

    event =
      if is_map(body) and body != %{} do
        Map.put(event, "data", body)
      else
        event
      end

    ct = conn |> get_req_header("content-type") |> List.first()
    if is_binary(ct), do: Map.put(event, "datacontenttype", ct), else: event
  end

  defp ce_attributes(conn) do
    Enum.reduce(conn.req_headers, %{}, fn {name, value}, acc ->
      case name do
        "ce-" <> attr ->
          attr = attr |> String.downcase() |> String.replace("-", "")
          Map.put(acc, attr, value)

        _ ->
          acc
      end
    end)
  end

  # Mirrors Smalt.Messaging.EventStream validation so admission is decided
  # BEFORE any store write (all-or-nothing).
  defp validate_events(events) do
    if Enum.all?(events, &valid_cloudevent?/1), do: :ok, else: {:error, :invalid_cloudevent}
  end

  defp valid_cloudevent?(event) when is_map(event) do
    event["specversion"] == "1.0" and present?(event["source"]) and present?(event["type"])
  end

  defp valid_cloudevent?(_), do: false

  defp present?(value), do: is_binary(value) and value != ""

  # Query POST: content-type application/query+json (the Cosmos SDK's query
  # wire form). Body is the query document; no SQL engine — the engine filters
  # by partition-key header when present and returns the honest result set.
  def query_post?(conn) do
    case get_req_header(conn, "content-type") do
      [ct | _] -> String.contains?(ct, "query+json")
      _ -> false
    end
  end

  def query_post(conn, db, coll) do
    case decoded_body(conn) do
      {:ok, body} ->
        cosmos_respond(conn, Cosmos.query_docs(db, coll, body, header_map(conn)))

      :error ->
        send_json(conn, 400, invalid_body_error())
    end
  end

  defp decoded_body(conn) do
    case conn.body_params do
      %Plug.Conn.Unfetched{} ->
        case read_raw_body(conn) do
          {:ok, raw} ->
            case Jason.decode(raw) do
              {:ok, %{} = body} -> {:ok, body}
              _ -> :error
            end

          :error ->
            :error
        end

      body when is_map(body) ->
        {:ok, body}

      _other ->
        :error
    end
  end

  def id_param(conn) do
    case Map.get(conn.body_params, "id") do
      name when is_binary(name) and name != "" -> {:ok, name}
      _ -> :error
    end
  end

  # RFC 6902 patch body: a top-level JSON array of ops. Plug.Parsers wraps a
  # decoded top-level array as %{"_json" => list}; admit ONLY the list form.
  def unwrap_patch_ops(%{"_json" => ops}) when is_list(ops), do: {:ok, ops}
  def unwrap_patch_ops(ops) when is_list(ops), do: {:ok, ops}
  def unwrap_patch_ops(_other), do: :error

  def cosmos_respond(conn, {:error, :store_not_ready}) do
    route_not_ready(conn)
  end

  def cosmos_respond(conn, {:ok, status, headers, body}) when is_map(headers) do
    conn =
      conn
      |> ensure_request_charge(headers)
      |> apply_headers(headers)

    if body in ["", nil] do
      send_resp(conn, status, "")
    else
      send_json(conn, status, body)
    end
  end

  defp ensure_request_charge(conn, headers) do
    if Map.has_key?(headers, "x-ms-request-charge") do
      conn
    else
      put_resp_header(conn, "x-ms-request-charge", "1.0")
    end
  end

  defp apply_headers(conn, headers) do
    Enum.reduce(headers, conn, fn {name, value}, conn ->
      Plug.Conn.put_resp_header(conn, name, value)
    end)
  end

  # Real Log Analytics DCR ingest answers 204 No Content plus x-ms-request-id.
  # Unified to the dashed-36 RFC 4122 v4 GUID form real Azure emits on BOTH
  # the LA and ARM surfaces (cross-court finding, compliance-corpus cycle 8);
  # previously a 32-hex dialect pin.
  # Public for the egress delegator routers (see route_not_ready/1 note).
  def generate_request_id do
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

  # Public for the egress delegator routers (see route_not_ready/1 note).
  def send_json(conn, status, body) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(status, Jason.encode!(body))
  end
  # EXPL-9 F2b (KD-COVERS: KD-175): crash-path fence handler, re-landed from
  # the pre-undock source (95d4243d). Renders the Storage <Error> envelope +
  # x-ms-request-id on any unhandled crash — never a naked adapter 500.
  # (No @impl: handle_errors is defp called dynamically by Plug.ErrorHandler;
  # @impl on a defp is a compile warning.)
  defp handle_errors(conn, %{kind: kind, reason: reason, stack: stack}) do
    # BK-EGS1 (F-EGS1 repair, EXPL9-R2): a fault INSIDE handle_errors/2 itself
    # (error_xml/2, generate_request_id/0, put_resp_content_type/2 ...) used to
    # propagate out of Plug.ErrorHandler.__catch__ to Bandit and render the
    # NAKED adapter 500 — empty body, no envelope, no x-ms-request-id (audit
    # probe T6). The rescue path renders a fault-free constant fallback
    # envelope and logs the secondary fault loudly.
    # BK-XPRIF: exceptions carrying a typed plug_status < 500 (e.g.
    # Plug.Parsers.ParseError -> 400) are NOT 500-class crashes — sending the
    # 500 envelope here would swallow the typed status (BK-XPRI HIGH
    # regression). Skip the fence so Plug.ErrorHandler's re-raise reaches the
    # adapter, which renders the exception's own typed status.
    if kind == :error and Plug.Exception.status(reason) < 500 do
      Logger.error(
        "egress_router typed plug-status crash (fence skipped, adapter renders typed status): " <>
          Exception.format(kind, reason, stack)
      )

      :ok
    else
      try do
        Logger.error("egress_router crash 500: #{Exception.format(kind, reason, stack)}")

        # :unsent is not a real Plug conn.state — "nothing sent yet" is
        # state in [:unset, :set].
        if conn.state in [:unset, :set] do
          conn
          |> put_resp_header("x-ms-request-id", generate_request_id())
          |> put_resp_content_type("application/xml")
          |> send_resp(500, error_xml("InternalServerError", "Internal server error."))
        end

        :ok
      rescue
        secondary ->
          Logger.error(
            "egress_router handle_errors itself FAULTED (F-EGS1 fallback engaged): " <>
              Exception.format(:error, secondary, __STACKTRACE__)
          )

          fegs1_fallback_send(conn, secondary)
      end
    end
  end

  # BK-EGS1: constant, fault-free fallback render. Module attributes are
  # compile-time literals; put_resp_header/send_resp/state check cannot raise
  # on a well-formed conn. Static request id (v4-shaped nil GUID) marks the
  # fallback face on the wire.
  @fegs1_fallback_request_id "00000000-0000-4000-8000-000000000000"
  @fegs1_fallback_body "<?xml version=\"1.0\" encoding=\"utf-8\"?><Error><Code>InternalServerError</Code><Message>Internal server error.</Message></Error>"

  defp fegs1_fallback_send(conn, _secondary) do
    if conn.state in [:unset, :set] do
      conn
      |> put_resp_header("x-ms-request-id", @fegs1_fallback_request_id)
      |> put_resp_header("content-type", "application/xml; charset=utf-8")
      |> send_resp(500, @fegs1_fallback_body)
    end

    :ok
  end

  # Re-landed from the pre-undock source (95d4243d) — shared <Error> envelope
  # renderer needed by handle_errors/2 above.
  def error_xml(code, msg) do
    ~s(<?xml version="1.0" encoding="utf-8"?><Error><Code>) <>
      Smalt.DataPlane.BlobService.xml_escape(code) <>
      "</Code><Message>" <> Smalt.DataPlane.BlobService.xml_escape(msg) <> "</Message></Error>"
  end

  # Lane 06 (v26.10.14) defect 3, part 2: blob error responses now carry the
  # error code in the x-ms-error-code header, extracted from the JSON body's
  # code slot (either envelope shape). Additive — the JSON body is unchanged.
  def blob_error(conn, status, body) do
    code = blob_error_code(body)

    # B-XML opt-in law (re-landed from the pre-undock source 95d4243d): the
    # XML envelope renders ONLY on the stamped blob face — blob_route/2 stamps
    # :smalt_blob_face at route entry, and every other consumer (ARM / Cosmos /
    # KV / AppConfig / Ledger / delegator sub-routers) keeps its JSON envelope
    # byte-identical (BlobError moduledoc law). The undock dropped both the
    # stamp and this consult, so EVERY blob_error call site rendered XML and
    # the KV wire answered blob-XML where the KV courts pin typed JSON
    # (kds3_s4 + kv_ec_create live regressions, coordinator/L11 probe r9c).
    if conn.private[:smalt_blob_face] && is_binary(code) do
      # Parity lane 2026-10-28 (wf8, python SDK receipt): the storage-plane
      # error body is the Azure XML <Error><Code/><Message/></Error> envelope
      # — the official python storage pipeline parses Message from XML and
      # gets None for JSON bodies (error_message += None TypeError). The
      # Message element must never be EMPTY either (python's error formatter
      # += None chain); default it to the code text, as real Azure always
      # carries message text. Scoped to the stamped blob face only —
      # send_json is untouched, so ARM/cosmos/KV/ledger envelopes keep their
      # pinned JSON.
      code = code || "InternalError"
      message = blob_error_message(body)
      message = if is_binary(message) and message != "", do: message, else: code

      xml =
        "<?xml version=\"1.0\" encoding=\"utf-8\"?>" <>
          "<Error><Code>#{code}</Code>" <>
          "<Message>#{xml_escape_error(message)}</Message></Error>"

      conn
      |> put_resp_header("x-ms-request-id", generate_request_id())
      |> put_resp_header("x-ms-version", "2021-12-02")
      |> put_resp_header("x-ms-error-code", code)
      |> put_resp_content_type("application/xml")
      |> send_resp(status, xml)
    else
      conn
      |> put_resp_header("x-ms-request-id", generate_request_id())
      |> put_resp_header("x-ms-version", "2021-12-02")
      |> put_error_code_header(body)
      |> send_json(status, body)
    end
  end

  # Restored alongside the B-XML consult (re-landed from the pre-undock source
  # 95d4243d): the undock deleted this helper as "unused" precisely because the
  # consult branch that called it was gone; the JSON branch needs it to keep
  # the typed x-ms-error-code header on non-blob faces.
  def put_error_code_header(conn, body) do
    case blob_error_code(body) do
      nil -> conn
      code -> put_resp_header(conn, "x-ms-error-code", code)
    end
  end

  defp blob_error_message(%{"error" => %{"message" => msg}}) when is_binary(msg), do: msg
  defp blob_error_message(%{"message" => msg}) when is_binary(msg), do: msg
  defp blob_error_message(_), do: nil

  defp xml_escape_error(s) do
    s
    |> String.replace("&", "&amp;")
    |> String.replace("<", "&lt;")
    |> String.replace(">", "&gt;")
  end

  defp blob_error_code(%{"error" => %{"code" => code}}) when is_binary(code), do: code
  defp blob_error_code(%{"code" => code}) when is_binary(code), do: code
  defp blob_error_code(_), do: nil
  def not_found_error(code) do
    %{"error" => %{"code" => code}}
  end
  # Key Vault action tuple helper: {:ok, status, body} / {:error, status, body}.
  def kv_respond(conn, {:ok, status, body}), do: send_json(conn, status, body)
  def kv_respond(conn, {:error, status, body}), do: send_json(conn, status, body)
end
