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
  require Logger
  alias Smalt.Store
  alias Smalt.DataPlane.BlobService
  alias Smalt.DataPlane.BlobStorage
  alias Smalt.DataPlane.KeyVaultActions
  alias Smalt.DataPlane.Cosmos
  alias Smalt.DataPlane.Purview
  alias Smalt.DataPlane.ResourceGraph
  alias Smalt.DataPlane.Sentinel
  alias Smalt.Messaging.EventStream
  alias Smalt.Security.Attestation
  alias Smalt.Security.ConfidentialLedger

  # GAP-AUD1-01 (v26.10.14, lane W-5): blob comp whitelists — MUST be defined
  # textually BEFORE the route macros that expand them (module attributes are
  # expanded at their point of use, top-to-bottom).
  # KD-COVERS: KD-60 — comp=snapshot is registered (wire arm below); the rest
  # of the KD-60 class (page/tags/lease/...) stays default-deny refused.
  @blob_put_comps ~w(block blocklist metadata snapshot)
  # KD-COVERS: KD-60 — comp=metadata GET registered (Azure Get Blob Metadata);
  # the rest of the KD-60 GET class (pagelist/tags/...) stays default-deny.
  @blob_get_comps ~w(blocklist metadata)
  # R98 container comp whitelists — mirror of the blob arms above. Lease and
  # ACL are UNIMPLEMENTED (KD/GAP(blob-comp-lease-absent)); previously an
  # unknown container comp fell through: PUT into the create-container branch
  # (silent 201 lie), GET into the plain-list fallback (wrong-body 200).
  @container_put_comps ~w(legalhold immutabilityPolicy immutabilitypolicy metadata)
  @container_get_comps ~w(legalhold immutabilityPolicy immutabilitypolicy metadata list)

  plug(Plug.Logger)
  # Lane 19 (v26.10.14) item 6: CORS origins are configurable at runtime via
  # `:smalt, :egress_cors_origins` (list of allowed origins). The default is
  # ["*"] — the documented dev posture for the emulator's 8443 surface; in
  # production, configure an explicit allowlist. Evaluated per-request so a
  # config flip does not need a recompile.
  plug(:egress_cors)

  defp egress_cors(conn, _opts) do
    origins = Application.get_env(:smalt, :egress_cors_origins, ["*"])
    CORSPlug.call(conn, CORSPlug.init(origin: origins))
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

  plug(Smalt.Auth.Bearer)
  plug(:fetch_query_params)
  # Python SDK trailing-slash tolerance: GET /dbs/:db/colls/:coll/ must route
  # identically to the non-slash form. Plug treats the trailing slash as an
  # empty final segment, which falls through to the 404 catch-all — strip it
  # for /dbs-prefixed paths before :match.
  plug(:trim_dbs_trailing_slash)

  plug(:maybe_parse_body)

  plug(:match)
  plug(:dispatch)

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
  # feed before reads; a single full-hash-space range models the single-region
  # account.
  @pkranges_etag "\"smalt-pkranges-v1\""

  get "/dbs/:db/colls/:coll/pkranges" do
    with_route(conn, Cosmos, fn conn ->
      # The python SDK's routing-map drain terminates ONLY on a literal 304
      # (evaluate_drain_page): first fetch -> 200 + ETag, any further fetch
      # carrying a matching If-None-Match -> 304, loop exits.
      if get_req_header(conn, "if-none-match") == [@pkranges_etag] do
        send_resp(conn, 304, "")
      else
        conn
        |> put_resp_header("etag", @pkranges_etag)
        |> send_json(200, %{
          "PartitionKeyRanges" => [
            %{
              "id" => "0",
              "minInclusive" => "",
              "maxExclusive" => "FF",
              "ridPrefix" => 0,
              "throughputFraction" => 1.0
            }
          ],
          "_count" => 1
        })
      end
    end)
  end

  # Query POST: content-type application/query+json is routed to the query
  # engine BEFORE the create handler is reachable — a query POST never creates
  # a document.
  post "/dbs/:db/colls/:coll/docs" do
    with_route(conn, Cosmos, fn conn ->
      if query_post?(conn) do
        query_post(conn, db, coll)
      else
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

  defp policy_has_claim?(%{"claim" => _}), do: true

  defp policy_has_claim?(policy) when is_map(policy) do
    Enum.any?(policy, fn {_k, v} -> policy_has_claim?(v) end)
  end

  defp policy_has_claim?(list) when is_list(list), do: Enum.any?(list, &policy_has_claim?/1)
  defp policy_has_claim?(_), do: false

  defp policy_has_ops_list?(policy),
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

  delete "/secrets/:name" do
    if :ets.info(:smalt_vault_secrets) == :undefined do
      route_not_ready(conn)
    else
      case Store.get(:smalt_vault_secrets, name) do
        {:ok, record} ->
          Store.delete(:smalt_vault_secrets, name)

          send_json(conn, 200, %{
            "id" => record["id"],
            "attributes" => public_attributes(record)
          })

        :error ->
          blob_error(conn, 404, not_found_error("SecretNotFound"))
      end
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

  post "/secrets/:name/backup" do
    secret_subverb_refusal(conn, "backup")
  end

  post "/secrets/:name/restore" do
    secret_subverb_refusal(conn, "restore")
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
              send_resp(conn, 204, "")
            end
          end
      end
    end
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
  defp secret_params(%{"value" => value} = params) when is_binary(value) do
    attrs =
      params["attributes"]
      |> coerce_secret_attrs()
      |> Map.merge(Map.take(params, ["contentType"]))

    {:ok, value, attrs}
  end

  defp secret_params(_), do: :error

  defp coerce_secret_attrs(%{} = attrs), do: attrs
  defp coerce_secret_attrs(_), do: %{}

  defp secret_expiry(attrs_in) do
    case attrs_in["expires"] || attrs_in["exp"] do
      nil -> %{}
      exp -> %{"expires" => exp}
    end
  end

  defp maybe_put_content_type(record, attrs_in) do
    case attrs_in["contentType"] do
      nil -> record
      ct -> Map.put(record, "contentType", ct)
    end
  end

  # List renders omit the secret value (Azure contract); GET keeps it.
  defp public_secret_record(record), do: Map.drop(record, ["version"])

  defp list_secret_record(record), do: record |> public_secret_record() |> Map.drop(["value"])

  defp public_attributes(record), do: record["attributes"] || %{}

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
  # Immutable Blob Storage REST API — guarded catch-all
  # NOTE route ordering: GET /{account}?comp=list is a single-segment route and
  # must be defined BEFORE the generic /:account/:container catch-alls below.
  # ---------------------------------------------------------------------------
  get "/:account" do
    if conn.query_params["comp"] == "list" do
      blob_route(conn, fn conn ->
        if not_ready?(conn, [BlobService]) do
          route_not_ready(conn)
        else
          # Typed engine errors (container-list maxresults 400,
          # v26.10.14 lane 06 defects 2+3) reach the wire as the Azure XML
          # <Error> envelope on this comp=list route — never a MatchError 500
          # or a JSON body where the real service emits XML.
          case BlobService.list_containers_xml(account, %{
                 "prefix" => conn.query_params["prefix"],
                 "marker" => conn.query_params["marker"],
                 "maxresults" => conn.query_params["maxresults"]
               }) do
            {xml, _next_marker} ->
              conn
              |> put_resp_content_type("application/xml")
              |> send_resp(200, xml)

            {:error, status, code, msg} when is_integer(status) ->
              blob_error_xml(conn, status, code, msg)
          end
        end
      end)
    else
      blob_error(conn, 404, %{
        "error" => %{
          "code" => "RouteNotFound",
          "message" => "No route matches #{conn.method} #{conn.request_path}"
        }
      })
    end
  end

  put "/:account/:container" do
    blob_route(conn, fn conn ->
      cond do
        # R98 fail-closed container comp registration: an unknown comp on the
        # container PUT arm is a typed 400, never a silent 201 create.
        unhandled_comp?(conn, @container_put_comps) ->
          unhandled_container_comp_error(conn, conn.query_params["comp"])

        conn.query_params["comp"] == "legalhold" ->
          if not_ready?(conn, [BlobStorage]) do
            route_not_ready(conn)
          else
            flag = header_map(conn)["x-ms-legal-hold"] == "true"

            case BlobStorage.set_legal_hold(account, container, flag, header_map(conn)) do
              {:ok, status, headers, record} ->
                conn
                |> put_resp_headers(headers)
                |> put_resp_content_type("application/json")
                |> send_resp(status, Jason.encode!(record))

              {:error, status, code, msg} ->
                blob_error(conn, status, not_found_error(code) |> put_message(msg))
            end
          end

        conn.query_params["comp"] in ["immutabilityPolicy", "immutabilitypolicy"] ->
          if not_ready?(conn, [BlobStorage]) do
            route_not_ready(conn)
          else
            case immutability_policy_from_wire(conn) do
              {:ok, policy, conn} ->
                case BlobStorage.set_immutability_policy(
                       account,
                       container,
                       policy,
                       header_map(conn)
                     ) do
                  {:ok, status, headers, record} ->
                    conn
                    |> put_resp_headers(headers)
                    |> put_resp_content_type("application/json")
                    |> send_resp(status, Jason.encode!(record))

                  {:error, status, code, msg} ->
                    blob_error(conn, status, not_found_error(code) |> put_message(msg))
                end

              {:error, conn} ->
                blob_error(conn, 400, %{
                  "error" => %{
                    "code" => "InvalidXmlOrJson",
                    "message" => "The immutability policy body is not valid XML or JSON."
                  }
                })
            end
          end

        conn.query_params["comp"] == "metadata" ->
          if not_ready?(conn, [BlobService]) do
            route_not_ready(conn)
          else
            case BlobService.set_container_metadata(account, container, meta_headers(conn)) do
              {:ok, status, headers} ->
                send_headers(conn, status, headers)

              {:error, status, code, msg} ->
                blob_error(conn, status, not_found_error(code) |> put_message(msg))
            end
          end

        true ->
          opts = %{"immutable" => get_req_header(conn, "x-ms-immutable-policy") != ["false"]}

          # Azure parity: x-ms-meta-* on Put Container SETS metadata at
          # create. Validated BEFORE the create — a refused create must not
          # leave the container behind.
          with :ok <- BlobService.check_metadata(meta_headers(conn)) do
            case BlobStorage.create_container(account, container, opts) do
              {:ok, record} ->
                # R77: propagate the create-time seeding result. The container
                # stands either way (Azure parity: create is not rolled back),
                # but a refused/failed seeding is logged loudly, never silently
                # dropped — a fresh no-policy container must seed (R62's gate
                # does not block it); only hold/locked refusals may skip it.
                case BlobService.set_container_metadata(account, container, meta_headers(conn)) do
                  {:ok, 200, _} ->
                    :ok

                  {:error, _status, _code, _msg} = seeding ->
                    require Logger

                    Logger.warning(
                      "container created but x-ms-meta-* seeding did not land: #{inspect(seeding)} (SHIM-COURT R77)"
                    )
                end

                # Real Azure (lens-5 work order, cycle-33): 201 create carries
                # a quoted ETag, RFC 1123 Last-Modified, x-ms-request-id +
                # x-ms-version, and an EMPTY body. GET properties is
                # untouched (courts pin its exact bytes).
                {:ok, created_dt, _} = DateTime.from_iso8601(record["created"])

                conn
                |> put_resp_header("etag", container_put_etag(record))
                |> put_resp_header(
                  "last-modified",
                  Calendar.strftime(created_dt, "%a, %d %b %Y %H:%M:%S GMT")
                )
                |> put_resp_header("x-ms-request-id", generate_request_id())
                |> put_resp_header("x-ms-version", "2021-12-02")
                |> send_resp(201, "")

              # Idempotent Put Container (real Azure semantics): re-PUT on an
              # EXISTING container is 200 with the standard headers when the
              # x-ms-meta-* set is IDENTICAL, 409 ContainerAlreadyExists when
              # it differs. The WORM/lease gates stay AHEAD of the comparison
              # (container_reput_arm) — a hold/locked re-PUT still refuses
              # 409 ContainerLocked per the WORM arms.
              {:error, 409, "ContainerAlreadyExists", _msg} ->
                container_reput_arm(conn, account, container)

              # Cross-lane repair (blob lane cycle-15 §3): typed engine error
              # tuples `{:error, status, code, msg}` from create_container
              # reach the wire at their exact Azure status instead of a
              # blanket 500 — this un-deads blob's container-name-grammar and
              # duplicate-create-409 fences. Non-tuple shapes keep the
              # runtime safety net below.
              {:error, status, code, msg} when is_integer(status) ->
                blob_error(conn, status, not_found_error(code) |> put_message(msg))

              # mechanical warning fix (store+graphlaw lane): the compiler types
              # create_container/3 as {:ok, map()} only (no error clauses in the
              # data plane), so the shape is not statically indexable; the dead
              # branch stays as a runtime safety net without elem/2 indexing.
              other ->
                blob_error(conn, 500, %{"error" => inspect(other)})
            end
          else
            {:error, status, code, msg} ->
              blob_error(conn, status, not_found_error(code) |> put_message(msg))
          end
      end
    end)
  end

  # Idempotent Put Container arm (see the 409 ContainerAlreadyExists clause
  # in the create route): WORM/lease gate FIRST (hold or locked-while-retention-
  # live → 409 ContainerLocked, mirroring BlobService.check_metadata_worm
  # semantics via BlobStorage.policy_state/3), then metadata comparison —
  # IDENTICAL x-ms-meta-* → 200 with the standard headers; DIFFERENT →
  # 409 ContainerAlreadyExists.
  defp container_reput_arm(conn, account, container) do
    requested = meta_headers(conn)

    case BlobStorage.policy_state(account, container) do
      {:ok, %{"legal_hold" => true}} ->
        blob_error(conn, 409, %{
          "error" => %{
            "code" => "ContainerLocked",
            "message" =>
              "Blob modification refused: container has an active legal hold (ContainerLocked)."
          }
        })

      {:ok, %{"locked" => true, "expired" => false}} ->
        blob_error(conn, 409, %{
          "error" => %{
            "code" => "ContainerLocked",
            "message" =>
              "Blob modification refused: container has a locked immutability policy (ContainerLocked)."
          }
        })

      {:ok, _state} ->
        existing =
          case BlobStorage.get_policy(account, container) do
            nil -> %{}
            policy -> Map.get(policy, "metadata") || %{}
          end

        if existing == requested do
          {:ok, record} = Store.get(:smalt_blob_containers, "#{account}/#{container}")
          {:ok, created_dt, _} = DateTime.from_iso8601(record["created"])

          conn
          |> put_resp_header("etag", container_put_etag(record))
          |> put_resp_header(
            "last-modified",
            Calendar.strftime(created_dt, "%a, %d %b %Y %H:%M:%S GMT")
          )
          |> put_resp_header("x-ms-request-id", generate_request_id())
          |> put_resp_header("x-ms-version", "2021-12-02")
          |> send_resp(200, "")
        else
          blob_error(conn, 409, %{
            "error" => %{
              "code" => "ContainerAlreadyExists",
              "message" => "The specified container already exists with different metadata."
            }
          })
        end

      {:error, :container_not_found} ->
        blob_error(conn, 404, %{
          "error" => %{"code" => "ContainerNotFound", "message" => "Container not found."}
        })
    end
  end

  get "/:account/:container" do
    blob_route(conn, fn conn ->
      cond do
        # R98 fail-closed container comp registration: an unknown comp on the
        # container GET arm is a typed 400, never a wrong-body 200.
        unhandled_comp?(conn, @container_get_comps) ->
          unhandled_container_comp_error(conn, conn.query_params["comp"])

        conn.query_params["comp"] in ["immutabilityPolicy", "immutabilitypolicy"] ->
          if not_ready?(conn, [BlobStorage]) do
            route_not_ready(conn)
          else
            case BlobStorage.get_policy(account, container) do
              %{"immutability_policy" => policy} ->
                conn
                |> put_resp_header("x-ms-version", "2021-12-02")
                |> put_resp_content_type("application/json")
                |> send_resp(200, Jason.encode!(policy))

              _ ->
                blob_error(conn, 404, not_found_error("ImmutabilityPolicyNotFound"))
            end
          end

        conn.query_params["comp"] == "legalhold" ->
          if not_ready?(conn, [BlobStorage]) do
            route_not_ready(conn)
          else
            case BlobStorage.get_policy(account, container) do
              %{"legal_hold" => flag} ->
                conn
                |> put_resp_header("x-ms-version", "2021-12-02")
                |> put_resp_header("x-ms-legal-hold", to_string(flag))
                |> send_resp(200, "")

              _ ->
                blob_error(conn, 404, not_found_error("LegalHoldNotFound"))
            end
          end

        conn.query_params["comp"] == "metadata" ->
          if not_ready?(conn, [BlobService]) do
            route_not_ready(conn)
          else
            case BlobService.get_container_metadata(account, container) do
              {:ok, meta} ->
                conn
                |> put_resp_header("x-ms-version", "2021-12-02")
                |> put_resp_headers(meta_headers(meta))
                |> send_resp(200, "")

              {:error, status, code, msg} ->
                blob_error(conn, status, not_found_error(code) |> put_message(msg))
            end
          end

        conn.query_params["comp"] == "list" ->
          if not_ready?(conn, [BlobStorage]) do
            route_not_ready(conn)
          else
            # Typed engine errors (e.g. blob lane's pending maxresults 400)
            # must reach the wire at their exact status — a bare
            # {xml, _} destructure here would MatchError into a blanket 500.
            case BlobStorage.list_blobs_xml(account, container, %{
                   "prefix" => conn.query_params["prefix"],
                   "delimiter" => conn.query_params["delimiter"],
                   "include" => conn.query_params["include"],
                   "marker" => conn.query_params["marker"],
                   "maxresults" => conn.query_params["maxresults"]
                 }) do
              {xml, _next_marker} ->
                conn
                |> put_resp_content_type("application/xml")
                |> send_resp(200, xml)

              # comp=list errors emit the Azure XML <Error> envelope on the
              # blob list route (real-service shape; lane 06 defect 3).
              {:error, status, code, msg} when is_integer(status) ->
                blob_error_xml(conn, status, code, msg)
            end
          end

        conn.query_params["restype"] == "container" ->
          if not_ready?(conn, [BlobService]) do
            route_not_ready(conn)
          else
            case BlobService.get_container_properties(account, container) do
              {:ok, status, headers} ->
                send_headers(conn, status, headers)

              {:error, status, code, msg} ->
                blob_error(conn, status, not_found_error(code) |> put_message(msg))
            end
          end

        true ->
          case BlobStorage.list_blobs_xml(account, container, %{
                 "prefix" => conn.query_params["prefix"],
                 "delimiter" => conn.query_params["delimiter"],
                 "include" => conn.query_params["include"],
                 "marker" => conn.query_params["marker"],
                 "maxresults" => conn.query_params["maxresults"]
               }) do
            {xml, _next_marker} ->
              conn
              |> put_resp_content_type("application/xml")
              |> send_resp(200, xml)

            # comp=list-class errors emit the Azure XML envelope here too
            # (lane 06 defect 3; the plain-GET container fallback is the same
            # list operation as the comp=list arm).
            {:error, status, code, msg} when is_integer(status) ->
              blob_error_xml(conn, status, code, msg)
          end
      end
    end)
  end

  put "/:account/:container/*blob_name" do
    # Azure virtual directories: the tail may carry `/` (blob lane cycles
    # 21/28 engine-verified). Splat binds a segment list; rejoin to the wire name.
    blob_name = Enum.join(blob_name, "/")

    blob_route(conn, fn conn ->
      # GAP-AUD1-01 (v26.10.14, lane W-5): fail-closed comp registration on the
      # blob PUT arm. Any comp value with no implemented handler here (snapshot,
      # page, tags, query, tier, expiry, seal, lease, copy, ...) previously fell
      # into the generic Put Blob fallback and stored the request's (usually
      # empty) body AS THE BLOB BODY — the audit's headline corruption class.
      # Known comps route to their handlers; every OTHER comp answers a typed
      # 400 and never reaches read_body/put_blob.
      if unhandled_comp?(conn, @blob_put_comps) do
        unhandled_blob_comp_error(conn, conn.query_params["comp"])
      else
        # X-1 (v26.10.14): Put Block / Put Block List get dedicated arms BEFORE
        # the generic Put Blob fallback — previously comp=blocklist fell into
        # put_blob and stored the request XML as the blob body (P0 data
        # corruption found by bench B-5).
        if conn.query_params["comp"] in ["block", "blocklist"] do
          blob_block_arm(conn, account, container, blob_name)
        else
          # KD-01 wire normalization (Azure Put Blob Metadata): comp=metadata is
          # answered BEFORE the body read — 200 EMPTY with etag, never the old
          # 201 + JSON debug body (which also silently emptied the content).
          if conn.query_params["comp"] == "metadata" do
            if not_ready?(conn, [BlobStorage]) do
              route_not_ready(conn)
            else
              case BlobStorage.set_blob_metadata(
                     account,
                     container,
                     blob_name,
                     meta_headers(conn)
                   ) do
                {:ok, status, headers} ->
                  send_headers(conn, status, headers)

                # SHIM-COURT: metadata PUT under WORM hold/locked policy -> 409
                # ContainerLocked (R183 finding 2; keep in lockstep with the
                # put_blob / commit_block_list arms above).
                {:error, :worm_locked, msg} ->
                  blob_error(conn, 409, %{
                    "error" => %{"code" => "ContainerLocked", "message" => msg}
                  })

                {:error, status, code, msg} ->
                  blob_error(conn, status, not_found_error(code) |> put_message(msg))
              end
            end
          else
            # KD-COVERS: KD-60 — Snapshot Blob wire arm (KD-52's engine
            # snapshot_blob/5 was previously engine-only; an unregistered comp hit
            # the typed 400). Azure answers 201 with the x-ms-snapshot timestamp
            # header; the engine handles existence + WORM (legal hold blocks the
            # snapshot create arm with 409 ContainerLocked).
            if conn.query_params["comp"] == "snapshot" do
              if not_ready?(conn, [BlobStorage]) do
                route_not_ready(conn)
              else
                case BlobStorage.snapshot_blob(account, container, blob_name, header_map(conn)) do
                  {:ok, 201, headers, nil} ->
                    send_headers(conn, 201, headers)

                  # WORM create arm: legal hold (or locked policy) -> 409
                  # ContainerLocked, same shape as the metadata/put_blob arms.
                  {:error, 409, "ContainerLocked", msg} ->
                    blob_error(conn, 409, %{
                      "error" => %{"code" => "ContainerLocked", "message" => msg}
                    })

                  {:error, status, code, msg} when is_integer(status) ->
                    blob_error(conn, status, not_found_error(code) |> put_message(msg))
                end
              end
            else
              case Plug.Conn.read_body(conn, length: 8_000_000, read_length: 1_000_000) do
                {:ok, raw_body, conn} ->
                  case BlobStorage.put_blob(
                         account,
                         container,
                         blob_name,
                         raw_body,
                         header_map(conn)
                       ) do
                    {:ok, blob} ->
                      # Metadata-only body: raw "content" (arbitrary bytes, frequently
                      # invalid UTF-8) must never reach Jason — a metadata projection
                      # is total over binary content.
                      conn
                      |> put_resp_header("etag", blob["etag"])
                      |> put_resp_content_type("application/json")
                      |> send_resp(201, Jason.encode!(BlobStorage.blob_metadata(blob)))

                    {:error, :worm_locked, msg} ->
                      blob_error(conn, 409, %{
                        "error" => %{"code" => "ContainerLocked", "message" => msg}
                      })

                    {:error, :precondition_failed, msg} ->
                      blob_error(conn, 412, %{
                        "error" => %{"code" => "PreconditionFailed", "message" => msg}
                      })

                    {:error, :too_large, msg} ->
                      blob_error(conn, 413, %{
                        "error" => %{"code" => "RequestBodyTooLarge", "message" => msg}
                      })

                    {:error, :container_not_found} ->
                      blob_error(conn, 404, not_found_error("ContainerNotFound"))

                    {:error, status, code, msg} when is_integer(status) ->
                      # engine-emitted typed HTTP errors (e.g. 400 InvalidMetadata)
                      blob_error(conn, status, not_found_error(code) |> put_message(msg))
                  end

                # A partial read is oversize only when it fills the cap; a small
                # partial means the body was truncated mid-flight (transport stopped
                # early) — Plug.Conn.read_body is single-shot, so {:more, small, _}
                # is a truncation, not a size refusal. Measured with a real
                # partial-then-error adapter (egress cycle-8).
                {:more, partial, _conn} when byte_size(partial) >= 8_000_000 ->
                  blob_error(conn, 413, %{
                    "error" => %{
                      "code" => "RequestBodyTooLarge",
                      "message" => "Blob exceeds the 8,000,000-byte request body limit."
                    }
                  })

                {:more, partial, _conn} ->
                  blob_error(conn, 400, %{
                    "error" => %{
                      "code" => "InvalidRequestBody",
                      "message" =>
                        "The request body was truncated mid-flight " <>
                          "(read #{byte_size(partial)} of the declared bytes)."
                    }
                  })

                # Plug >= 1.14 read_body returns {:error, reason} without the conn; the
                # historical {:error, term, _conn} clause here was typed-unreachable.
                {:error, reason} ->
                  blob_error(conn, 400, %{
                    "error" => %{"code" => "InvalidRequestBody", "message" => inspect(reason)}
                  })
              end
            end
          end
        end
      end
    end)
  end

  get "/:account/:container/*blob_name" do
    # Azure virtual directories: the tail may carry `/` (blob lane cycles
    # 21/28 engine-verified). Splat binds a segment list; rejoin to the wire name.
    blob_name = Enum.join(blob_name, "/")

    blob_route(conn, fn conn ->
      # GAP-AUD1-01 (v26.10.14, lane W-5): same fail-closed comp registration
      # on the GET arm — comp=pagelist/tags previously fell past the blocklist
      # branch and served blob CONTENT with a 200 (SDK XML decode error /
      # silent wrong semantics).
      if unhandled_comp?(conn, @blob_get_comps) do
        unhandled_blob_comp_error(conn, conn.query_params["comp"])
      else
        # KD-COVERS: KD-60 — Get Blob Metadata (`GET ?comp=metadata`): 200 EMPTY
        # with the stored x-ms-meta-* headers echoed back, mirroring the PUT
        # comp=metadata arm's meta_headers/stored_meta_wire read path.
        if conn.query_params["comp"] == "metadata" do
          if not_ready?(conn, [BlobStorage]) do
            route_not_ready(conn)
          else
            case BlobStorage.get_blob(account, container, blob_name) do
              {:ok, blob} ->
                conn
                |> put_resp_headers(stored_meta_wire(blob))
                |> put_resp_header("etag", blob["etag"])
                |> put_resp_header("x-ms-request-id", generate_request_id())
                |> put_resp_header("x-ms-version", "2021-12-02")
                |> send_resp(200, "")

              :error ->
                blob_error(conn, 404, not_found_error("BlobNotFound"))
            end
          end
        else
          # X-1 (v26.10.14): Get Block List — Azure answers application/xml; the
          # old fallback served the blob body as octet-stream (SDK DecodeError).
          if conn.query_params["comp"] == "blocklist" do
            if not_ready?(conn, [BlobStorage]) do
              route_not_ready(conn)
            else
              case BlobStorage.get_block_list(account, container, blob_name) do
                {:ok, committed, uncommitted} ->
                  conn
                  |> put_resp_header("x-ms-request-id", generate_request_id())
                  |> put_resp_header("x-ms-version", "2021-12-02")
                  |> put_resp_content_type("application/xml")
                  |> send_resp(200, BlobStorage.block_list_xml(committed, uncommitted))

                :error ->
                  blob_error(conn, 404, not_found_error("BlobNotFound"))
              end
            end
          else
            # KD-COVERS: KD-60 — snapshot read-back (`GET ?sharesnapshot=<ts>`):
            # serves the frozen point-in-time record from :smalt_blob_snapshots
            # byte-exact; base-blob mutations after the snapshot stay invisible
            # through the snapshot. Without the param the normal GET path runs.
            if conn.query_params["sharesnapshot"] in [nil, ""] do
              # Azure storage semantics: the range rides `x-ms-range` (python/JS SDKs)
              # or the standard `Range` header; honor both. x-ms-range WINS when both
              # are present (Azure parity + C4 fence): the engine takes List.first.
              range_header = get_req_header(conn, "x-ms-range") ++ get_req_header(conn, "range")

              # Conditional read (Azure parity, cycle-30): If-Match / If-None-Match
              # evaluated before the range branch; RFC 7232 precedence (If-Match
              # first, 412; then If-None-Match, 304).
              case BlobStorage.get_blob_conditional(
                     account,
                     container,
                     blob_name,
                     header_map(conn)
                   ) do
                {:error, 412, code, msg} ->
                  blob_error(conn, 412, not_found_error(code) |> put_message(msg))

                {:not_modified, etag} ->
                  conn
                  |> put_resp_header("etag", etag)
                  |> put_resp_header("x-ms-request-id", generate_request_id())
                  |> put_resp_header("x-ms-version", "2021-12-02")
                  |> send_resp(304, "")

                :error ->
                  blob_error(conn, 404, not_found_error("BlobNotFound"))

                {:ok, _blob} ->
                  case BlobStorage.get_blob_range(account, container, blob_name, range_header) do
                    {:ok, blob, nil} ->
                      conn
                      |> put_resp_headers(stored_meta_wire(blob))
                      |> put_resp_header("etag", blob["etag"])
                      |> put_resp_header(
                        "content-length",
                        blob["content"] |> byte_size() |> Integer.to_string()
                      )
                      |> put_resp_content_type("application/octet-stream")
                      |> send_resp(200, blob["content"])

                    {:ok, blob, {first, last}} ->
                      body = binary_part(blob["content"], first, last - first + 1)

                      conn
                      |> put_resp_headers(stored_meta_wire(blob))
                      |> put_resp_header("etag", blob["etag"])
                      |> put_resp_header(
                        "content-range",
                        "bytes #{first}-#{last}/#{byte_size(blob["content"])}"
                      )
                      |> put_resp_header(
                        "content-length",
                        (last - first + 1) |> Integer.to_string()
                      )
                      |> put_resp_content_type("application/octet-stream")
                      |> send_resp(206, body)

                    {:error, :range_not_satisfiable, total} ->
                      conn
                      |> put_resp_header("content-range", "bytes */#{total}")
                      |> put_resp_content_type("application/json")
                      |> send_resp(
                        416,
                        Jason.encode!(%{
                          "error" => %{
                            "code" => "InvalidRange",
                            "message" =>
                              "The range specified is invalid for a blob of #{total} bytes."
                          }
                        })
                      )

                    :error ->
                      blob_error(conn, 404, not_found_error("BlobNotFound"))
                  end
              end
            else
              # Snapshot read arm (sharesnapshot present).
              if not_ready?(conn, [BlobStorage]) do
                route_not_ready(conn)
              else
                case BlobStorage.get_blob_snapshot(
                       account,
                       container,
                       blob_name,
                       conn.query_params["sharesnapshot"]
                     ) do
                  {:ok, blob} ->
                    conn
                    |> put_resp_headers(stored_meta_wire(blob))
                    |> put_resp_header("etag", blob["etag"])
                    |> put_resp_header("x-ms-snapshot", conn.query_params["sharesnapshot"])
                    |> put_resp_header(
                      "content-length",
                      blob["content"] |> byte_size() |> Integer.to_string()
                    )
                    |> put_resp_content_type("application/octet-stream")
                    |> send_resp(200, blob["content"])

                  {:error, _status, _code, _msg} ->
                    blob_error(conn, 404, not_found_error("BlobNotFound"))
                end
              end
            end
          end
        end
      end
    end)
  end

  # HEAD container: header-only container properties (restype=container),
  # mirroring the GET container-properties branch.
  head "/:account/:container" do
    blob_route(conn, fn conn ->
      if conn.query_params["restype"] == "container" do
        if not_ready?(conn, [BlobService]) do
          route_not_ready(conn)
        else
          case BlobService.get_container_properties(account, container) do
            {:ok, status, headers} ->
              send_headers(conn, status, headers)

            {:error, status, code, msg} ->
              blob_error(conn, status, not_found_error(code) |> put_message(msg))
          end
        end
      else
        blob_error(
          conn,
          404,
          not_found_error("RouteNotFound")
          |> put_message("No route matches #{conn.method} #{conn.request_path}")
        )
      end
    end)
  end

  # HEAD blob: same engine as GET, empty body, content-length set. This is what
  # @azure/storage-blob downloadToBuffer probes before it issues the GET.
  head "/:account/:container/*blob_name" do
    # Azure virtual directories: the tail may carry `/` (blob lane cycles
    # 21/28 engine-verified). Splat binds a segment list; rejoin to the wire name.
    blob_name = Enum.join(blob_name, "/")

    blob_route(conn, fn conn ->
      # D14 (R122, KD-60): HEAD splat arm default-deny — comp=appendblock (and
      # any other unimplemented comp) previously served 200 header metadata as
      # if the operation had happened. SHIM-COURT: no HEAD blocklist handler
      # exists downstream, so unlike GET the whitelist must be EMPTY — a
      # comp=blocklist HEAD fell through to get_blob and served fake 200
      # header metadata. Same shape as the DELETE arm below.
      if unhandled_comp?(conn, []) do
        unhandled_blob_comp_error(conn, conn.query_params["comp"])
      else
        # KD-COVERS: KD-97 — conditional/ranged HEAD parity (v26.10.17): the HEAD
        # arm previously dispatched to unconditional get_blob and answered 200 to
        # every conditional probe. Mirror the GET arm's engine (If-Match 412,
        # If-None-Match 304, Range 206/416) with empty bodies; content-length
        # still reflects the effective (range) size, as Azure parity requires.
        range_header = get_req_header(conn, "x-ms-range") ++ get_req_header(conn, "range")

        case BlobStorage.get_blob_conditional(account, container, blob_name, header_map(conn)) do
          {:error, 412, code, msg} ->
            blob_error(conn, 412, not_found_error(code) |> put_message(msg))

          {:not_modified, etag} ->
            conn
            |> put_resp_header("etag", etag)
            |> put_resp_header("x-ms-request-id", generate_request_id())
            |> put_resp_header("x-ms-version", "2021-12-02")
            |> send_resp(304, "")

          :error ->
            blob_error(conn, 404, not_found_error("BlobNotFound"))

          {:ok, _blob} ->
            case BlobStorage.get_blob_range(account, container, blob_name, range_header) do
              {:ok, blob, nil} ->
                conn
                |> put_resp_headers(stored_meta_wire(blob))
                |> put_resp_header("etag", blob["etag"])
                |> put_resp_header("x-ms-request-id", generate_request_id())
                |> put_resp_header(
                  "content-length",
                  blob["content"] |> byte_size() |> Integer.to_string()
                )
                |> put_resp_content_type("application/octet-stream")
                |> send_resp(200, "")

              {:ok, blob, {first, last}} ->
                conn
                |> put_resp_headers(stored_meta_wire(blob))
                |> put_resp_header("etag", blob["etag"])
                |> put_resp_header(
                  "content-range",
                  "bytes #{first}-#{last}/#{byte_size(blob["content"])}"
                )
                |> put_resp_header("x-ms-request-id", generate_request_id())
                |> put_resp_header(
                  "content-length",
                  (last - first + 1) |> Integer.to_string()
                )
                |> put_resp_content_type("application/octet-stream")
                |> send_resp(206, "")

              {:error, :range_not_satisfiable, total} ->
                conn
                |> put_resp_header("content-range", "bytes */#{total}")
                |> put_resp_content_type("application/json")
                |> send_resp(
                  416,
                  Jason.encode!(%{
                    "error" => %{
                      "code" => "InvalidRange",
                      "message" => "The range specified is invalid for a blob of #{total} bytes."
                    }
                  })
                )

              :error ->
                blob_error(conn, 404, not_found_error("BlobNotFound"))
            end
        end
      end
    end)
  end

  delete "/:account/:container/*blob_name" do
    # Azure virtual directories: the tail may carry `/` (blob lane cycles
    # 21/28 engine-verified). Splat binds a segment list; rejoin to the wire name.
    blob_name = Enum.join(blob_name, "/")

    blob_route(conn, fn conn ->
      # D14 (R122, KD-60): DELETE splat arm default-deny — no blob-level comp
      # has an implemented DELETE handler, so ANY comp (lease, appendblock,
      # snapshot, ...) previously fell through and deleted the blob anyway.
      # comp must be absent/empty; everything else is a typed 400.
      if unhandled_comp?(conn, []) do
        unhandled_blob_comp_error(conn, conn.query_params["comp"])
      else
        case BlobStorage.delete_blob(account, container, blob_name, header_map(conn)) do
          {:ok, status, headers, _record} ->
            conn
            |> put_resp_headers(headers)
            |> send_resp(status, "")

          {:error, status, code, msg} ->
            blob_error(conn, status, not_found_error(code) |> put_message(msg))
        end
      end
    end)
  end

  # ---------------------------------------------------------------------------
  # Blob Batch (GAP-AUD1-02): POST /{account}/{container}?comp=batch (container
  # level) and POST /{account}?comp=batch&restype=account (account level).
  # Multipart/mixed request body; each part's body is a full HTTP sub-request
  # (request line + headers [+ body]); each sub-request is dispatched to the
  # same BlobStorage engine as its individual route arm (delete / set tier).
  # Bounded at 256 sub-requests (real Azure's cap); over → 400.
  # ---------------------------------------------------------------------------
  post "/:account/:container" do
    blob_route(conn, fn conn ->
      if conn.query_params["comp"] == "batch" do
        if not_ready?(conn, [BlobStorage]) do
          route_not_ready(conn)
        else
          blob_batch_arm(conn, account)
        end
      else
        blob_error(
          conn,
          404,
          not_found_error("RouteNotFound")
          |> put_message("No route matches #{conn.method} #{conn.request_path}")
        )
      end
    end)
  end

  post "/:account" do
    blob_route(conn, fn conn ->
      if conn.query_params["comp"] == "batch" do
        if not_ready?(conn, [BlobStorage]) do
          route_not_ready(conn)
        else
          blob_batch_arm(conn, account)
        end
      else
        blob_error(
          conn,
          404,
          not_found_error("RouteNotFound")
          |> put_message("No route matches #{conn.method} #{conn.request_path}")
        )
      end
    end)
  end

  # ---------------------------------------------------------------------------
  # Catch-all 404
  # ---------------------------------------------------------------------------
  match _ do
    blob_error(conn, 404, %{
      "error" => %{
        "code" => "RouteNotFound",
        "message" => "No route matches #{conn.method} #{conn.request_path}"
      }
    })
  end

  # ---------------------------------------------------------------------------
  # Internals
  # ---------------------------------------------------------------------------

  # X-1 (v26.10.14): Put Block / Put Block List wire arms. Put Block stages
  # raw block content (keyed account/container/blob/block-id); Put Block List
  # parses the request XML and commits the concatenation as the blob body.
  defp blob_block_arm(conn, account, container, blob_name) do
    if not_ready?(conn, [BlobStorage]) do
      route_not_ready(conn)
    else
      case Plug.Conn.read_body(conn, length: 8_000_000, read_length: 1_000_000) do
        {:ok, body, _conn} ->
          if conn.query_params["comp"] == "block" do
            case BlobStorage.stage_block(
                   account,
                   container,
                   blob_name,
                   conn.query_params["blockid"] || "",
                   body,
                   header_map(conn)
                 ) do
              {:ok, status, headers} ->
                send_headers(conn, status, headers)

              {:error, status, code, msg} ->
                blob_error(conn, status, not_found_error(code) |> put_message(msg))
            end
          else
            with {:ok, refs} <- BlobStorage.parse_block_list_xml(body),
                 {:ok, status, headers} <-
                   commit_response(account, container, blob_name, refs, header_map(conn)) do
              send_headers(conn, status, headers)
            else
              {:error, 400, code, msg} ->
                blob_error(conn, 400, not_found_error(code) |> put_message(msg))

              {:error, :worm_locked, msg} ->
                blob_error(conn, 409, %{
                  "error" => %{"code" => "ContainerLocked", "message" => msg}
                })

              {:error, :precondition_failed, msg} ->
                blob_error(conn, 412, %{
                  "error" => %{"code" => "PreconditionFailed", "message" => msg}
                })
            end
          end

        {:more, partial, _conn} ->
          blob_error(conn, 413, %{
            "error" => %{
              "code" => "RequestBodyTooLarge",
              "message" =>
                "The request body exceeds the 8,000,000-byte transport cap (read #{byte_size(partial)}+ bytes)."
            }
          })

        {:error, reason} ->
          blob_error(conn, 400, %{
            "error" => %{"code" => "InvalidRequestBody", "message" => inspect(reason)}
          })
      end
    end
  end

  # Map engine commit outcomes onto wire status/header tuples.
  defp commit_response(account, container, blob_name, refs, headers) do
    case BlobStorage.commit_block_list(account, container, blob_name, refs, headers) do
      {:ok, status, headers} -> {:ok, status, headers}
      {:error, :worm_locked, msg} -> {:error, :worm_locked, msg}
      {:error, :precondition_failed, msg} -> {:error, :precondition_failed, msg}
      {:error, status, code, msg} when is_integer(status) -> {:error, status, code, msg}
    end
  end

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

  defp raw_blob_put?(_conn), do: false

  defp fetchd_query_params(%Plug.Conn{query_params: %Plug.Conn.Unfetched{}} = conn),
    do: fetch_query_params(conn).query_params

  defp fetchd_query_params(%Plug.Conn{query_params: params}), do: params

  # The python azure-cosmos SDK reads partitionKeyDefinition["kind"]
  # (_ExtractPartitionKey in _cosmos_client_connection.py); a container record
  # without "kind" KeyErrors inside the SDK. Additive: only fills the field
  # when the engine record omits it.
  defp with_pk_kind(%{"partitionKey" => %{} = pk} = record) do
    %{record | "partitionKey" => Map.put_new(pk, "kind", "Hash")}
  end

  defp with_pk_kind(record), do: record

  # The python azure-cosmos SDK sends the partition key as a bare JSON string
  # ("/pk") in the CreateContainer body; the JS SDK sends {"paths": [...]},
  # .NET the same. Normalize the string form to the paths form at the seam.
  defp normalize_pk_body(%{"partitionKey" => pk} = body) when is_binary(pk) do
    Map.put(body, "partitionKey", %{"paths" => [pk]})
  end

  defp normalize_pk_body(body), do: body

  # Runs `fun` only when every module is loaded; fails closed with 503
  # RouteNotReady otherwise. This is the only seam that probes compile status.
  defp with_route(conn, modules, fun) do
    if not_ready?(conn, List.wrap(modules)) do
      route_not_ready(conn)
    else
      fun.(conn)
    end
  end

  # Lens7 law: a missing coordinator-owned ETS table is server not-ready, not
  # a raw 500 from :ets raising ArgumentError inside a list walk.
  defp tables_ready?(tables) do
    Enum.all?(tables, fn t -> :ets.info(t) != :undefined end)
  end

  defp not_ready?(_conn, modules) do
    not Enum.all?(modules, &Code.ensure_loaded?/1)
  end

  defp route_not_ready(conn) do
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
  defp check_akv_api_version(conn) do
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
  defp check_sentinel_api_version(conn) do
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

  # R99: known other-plane namespaces that must never reach the blob splat
  # arms (see reserved_fence_then below). Derived from
  # the router's documented route families (moduledoc).
  @reserved_first_segments ~w(dbs secrets certificates keys topics subscriptions attest app atlas dataCollectionRules v1 providers)

  # Blob catch-all guard: require x-ms-version header, or the host must be
  # configured in :smalt, :blob_catch_all_hosts.
  defp blob_route(conn, fun) do
    # Auth-lens-5 disclosed unblock (test-freeze SLA): the slash-blob glob
    # `/:account/:container/*blob_name` widened the catch-all to 3+ segments,
    # so exempt-prefix traversals (…/oauth2/../../acct/cont/blob) now match
    # the blob routes and reach the 400 x-ms-version guard instead of the
    # 404/401 the auth traversal court pins. A decoded "."/".." SEGMENT is a
    # path-traversal shape, never a legal storage name; refuse 404
    # fail-closed before the version guard.
    # Decoded segments are split on "/" so %-encoded traversals
    # (%2f%2e%2e -> "/..") are caught component-wise; a slash-containing
    # blob name without "." / ".." components stays legal (slash-blob).
    if Enum.any?(conn.path_info, fn seg ->
         String.split(URI.decode(seg), "/") |> Enum.any?(&(&1 in [".", ".."]))
       end) do
      blob_error(conn, 404, not_found_error("BlobNotFound"))
    else
      # KD-97 rider (v26.10.17, C4 fence): stamp x-ms-request-id + x-ms-version
      # at blob-route entry so EVERY blob arm (success, XML, comp arms) carries
      # them — real Azure stamps request-id on all storage responses; the
      # success/XML arms previously shipped without either. Error arms
      # (blob_error/3) restamp their own; put_resp_header replaces, so the
      # values stay single-valued.
      conn =
        conn
        |> put_resp_header("x-ms-request-id", generate_request_id())
        |> put_resp_header("x-ms-version", "2021-12-02")

      # Auth-lens interplay (egress lens-4 cycle 1, measured): the auth-exempt
      # namespace (/.well-known/, /oauth2/, /attest/, /metadata/endpoints,
      # /{tid}/oauth2/v2.0/token) composes with the blob splat — account=
      # ".well-known"/"oauth2"/"attest"/"metadata" — and x-ms-version is
      # client-supplied, not authentication, so an UNAUTHENTICATED blob
      # CRUD surface was reachable inside the exempt namespace (measured at
      # this seam). Blob-reachable exempt paths are refused fail-closed here;
      # real discovery endpoints are served before the router ever sees a
      # blob route. Canonical predicate from Smalt.Auth.Bearer — never a
      # copied prefix list.
      auth_exempt_blob =
        Code.ensure_loaded?(Smalt.Auth.Bearer) and
          Smalt.Auth.Bearer.auth_exempt_path?(conn.request_path)

      if auth_exempt_blob do
        blob_error(conn, 404, not_found_error("BlobNotFound"))
      else
        blob_route_guarded(conn, fun)
      end
    end
  end

  defp blob_route_guarded(conn, fun) do
    allowed_hosts = Application.get_env(:smalt, :blob_catch_all_hosts, [])

    # GAP-AUD1-03 (v26.10.15, W-7): SAS query-token auth. A `sig=` query token
    # is admission evidence in its own right — a SAS-only URI (sig present, no
    # x-ms-version header) previously 400'd MissingXMsVersion and the SAS
    # flow was dead. Fail-closed: bad signature / no configured account key /
    # malformed token → 401 with the KD-15-enriched WWW-Authenticate challenge
    # class; live signature without the method's required permission → 403
    # AuthorizationPermissionMismatch; valid token → admitted with the SIGNED
    # permissions only.
    case Smalt.Auth.Sas.verify(conn) do
      {:ok, permissions} ->
        required = Smalt.Auth.Sas.required_permission(conn.method)

        if Smalt.Auth.Sas.authorized?(permissions, required) do
          # Tokened path: x-ms-version not required (GAP-AUD1-03 spec).
          run_guarded(conn, :sas_admitted, fun, allowed_hosts)
        else
          conn
          |> put_resp_header("x-ms-version", "2021-12-02")
          |> put_resp_header("x-ms-request-id", generate_request_id())
          |> put_resp_header("x-ms-error-code", "AuthorizationPermissionMismatch")
          |> send_json(403, %{
            "error" => %{
              "code" => "AuthorizationPermissionMismatch",
              "message" =>
                "This request is not authorized to perform this operation using this permission."
            }
          })
          |> halt()
        end

      {:error, :not_sas} ->
        run_guarded(conn, :not_sas, fun, allowed_hosts)

      {:error, reason} when reason in [:bad_signature, :no_key, :malformed] ->
        # KD-15 challenge class: enriched WWW-Authenticate, mode-blind.
        Smalt.Auth.Bearer.send_challenge(
          conn,
          "The SAS signature is invalid or the account key is not configured."
        )

      {:error, :expired} ->
        conn
        |> put_resp_header("x-ms-version", "2021-12-02")
        |> put_resp_header("x-ms-request-id", generate_request_id())
        |> put_resp_header("x-ms-error-code", "AuthorizationFailure")
        |> send_json(403, %{
          "error" => %{
            "code" => "AuthorizationFailure",
            "message" => "The SAS token supplied with the request has expired."
          }
        })
        |> halt()
    end
  rescue
    e in [Jason.EncodeError, Protocol.UndefinedError] ->
      Logger.error("blob response encode failure on #{conn.request_path}: #{inspect(e)}")

      send_json(conn, 500, %{
        "error" => %{"code" => "BlobResponseEncodeFailure", "message" => Exception.message(e)}
      })
  end

  # R136: presence-only check let `x-ms-version: ""` (empty value), duplicate
  # headers (valid + junk), and whitespace-only values through to 201-stored.
  # Real Azure answers 400 MissingRequiredHeader. Validate as a SINGLE
  # non-empty, non-blank plausible version value; fail closed with the same
  # typed MissingXMsVersion envelope. SHIM-COURT: this predicate is the
  # mutation surface for the egress-version shim court.
  defp plausible_x_ms_version?(conn) do
    case get_req_header(conn, "x-ms-version") do
      [value] when is_binary(value) -> String.trim(value) != ""
      _ -> false
    end
  end

  defp run_guarded(conn, fun, allowed_hosts) do
    if plausible_x_ms_version?(conn) or conn.host in allowed_hosts do
      if not_ready?(conn, [BlobStorage]) or
           not tables_ready?([:smalt_blobs, :smalt_blob_containers, :smalt_blob_policy]) do
        route_not_ready(conn)
      else
        # D1 belt-and-braces: an encode failure in ANY blob response path
        # degrades to a clean JSON 500 envelope — never an empty response.
        reserved_fence_then(conn, fun)
      end
    else
      # AUD6-R1: a request that is neither SAS-admitted nor x-ms-version'ed on
      # a non-allowlisted host previously fell through with conn unsent
      # (Plug.NotSentError). Fail closed with the typed 400 envelope.
      blob_error(conn, 400, %{
        "error" => %{
          "code" => "MissingXMsVersion",
          "message" => "Missing required x-ms-version header, SAS token, or allowlisted host."
        }
      })
      |> halt()
    end
  end

  defp run_guarded(conn, :sas_admitted, fun, _allowed_hosts) do
    if not_ready?(conn, [BlobStorage]) or
         not tables_ready?([:smalt_blobs, :smalt_blob_containers, :smalt_blob_policy]) do
      route_not_ready(conn)
    else
      reserved_fence_then(conn, fun)
    end
  end

  # R124: catch-all tag arm kept adjacent to the :sas_admitted clause so
  # run_guarded/4 stays clause-cohesive (kills the compiler's clause-grouping warning).
  defp run_guarded(conn, _tag, fun, allowed_hosts) do
    run_guarded(conn, fun, allowed_hosts)
  end

  # R99 reserved-namespace fence (D70 worst class). Runs AFTER the SAS /
  # x-ms-version admission guards (the guard 400 envelope keeps precedence
  # for unversioned service-prefix PUTs) and immediately before any splat
  # handler: a splat first segment in @reserved_first_segments is a known
  # OTHER-plane namespace that fell through to the blob catch-alls — cosmos
  # triggers/udfs/sprocs answered 201 with the request body stored as a
  # blob, /secrets/* answered empty blob-list XML, PUT /keys/:name created
  # a blob. Fail closed with a typed refusal in the OWNING plane's JSON
  # error convention (never a blob envelope), naming the unimplemented
  # verb; nothing is stored. Reserved set = the router's own known-plane
  # first segments (moduledoc route families) plus the KV collection roots
  # (secrets, certificates) that appear as splat account names in D70. A
  # literal blob account named exactly one of these is shadowed — accepted
  # cost, impossible to distinguish at this seam.
  defp reserved_fence_then(conn, fun) do
    case conn.path_info do
      # R137 (W5-15 measured): Plug path_info segments are RAW (undecoded);
      # route matching happens on decoded segments, so `PUT /%6beys/vltkey`
      # (encoded "keys") reached the blob splat and stored under the decoded
      # reserved name. Decode+downcase before comparing — mirrors the
      # traversal fence's decode-aware pattern above.
      [first | _rest] ->
        decoded = String.downcase(URI.decode(first))

        if decoded in @reserved_first_segments do
          reserved_namespace_refusal(conn, decoded)
        else
          fun.(conn)
        end

      _ ->
        fun.(conn)
    end
  end

  # KV namespaces answer the KV envelope ({"error":{...}}) 404; every other
  # reserved namespace answers its plane's flat JSON {"code","message"} 400.
  defp reserved_namespace_refusal(conn, ns) when ns in ~w(secrets certificates keys) do
    send_json(conn, 404, %{
      "error" => %{
        "code" => "NotFound",
        "message" =>
          "#{conn.method} #{conn.request_path} is not implemented on this plane " <>
            "(reserved namespace '#{ns}'); nothing was stored."
      }
    })
  end

  defp reserved_namespace_refusal(conn, ns) do
    send_json(conn, 400, %{
      "code" => "NotImplemented",
      "message" =>
        "#{conn.method} #{conn.request_path} is not implemented on this plane " <>
          "(reserved namespace '#{ns}'); nothing was stored."
    })
  end

  # ---------------------------------------------------------------------------
  # Blob Batch (GAP-AUD1-02): multipart/mixed parse → per-sub-request dispatch
  # → multipart/mixed response. Only Delete Blob and Set Blob Tier are
  # dispatched (the two operations real Azure's batch plane accepts); any
  # other sub-request → per-sub-request 400, never a silent skip. Bounded at
  # 256 sub-requests (real Azure's cap).
  # ---------------------------------------------------------------------------

  @batch_max_subrequests 256

  defp blob_batch_arm(conn, account) do
    case Plug.Conn.read_body(conn, length: 8_000_000, read_length: 1_000_000) do
      {:ok, body, conn} ->
        case batch_boundary(conn) do
          {:ok, boundary} ->
            case parse_batch_parts(body, boundary) do
              {:ok, parts} when length(parts) > @batch_max_subrequests ->
                send_json(conn, 400, %{
                  "error" => %{
                    "code" => "SubRequestCountExceedsLimit",
                    "message" =>
                      "The batch request exceeds the limit of #{@batch_max_subrequests} sub-requests."
                  }
                })

              {:ok, []} ->
                send_json(conn, 400, %{
                  "error" => %{
                    "code" => "InvalidInput",
                    "message" => "The batch request contains no sub-requests."
                  }
                })

              {:ok, parts} ->
                send_batch_response(conn, account, parts)
            end

          :error ->
            send_json(conn, 400, %{
              "error" => %{
                "code" => "InvalidInput",
                "message" =>
                  "The batch request requires a multipart/mixed content-type with a boundary."
              }
            })
        end

      {:more, _, _} ->
        send_json(conn, 413, %{
          "error" => %{
            "code" => "RequestBodyTooLarge",
            "message" => "Batch body exceeds the 8 MB cap."
          }
        })
    end
  end

  defp batch_boundary(conn) do
    with [ct] <- get_req_header(conn, "content-type"),
         segments = Enum.map(String.split(ct, ";"), &String.trim/1),
         true <- hd(segments) |> String.downcase() == "multipart/mixed",
         boundary when is_binary(boundary) <- find_boundary(segments) do
      {:ok, String.trim(boundary, "\"")}
    else
      _ -> :error
    end
  end

  defp find_boundary(segments) do
    Enum.find_value(segments, fn segment ->
      case String.split(segment, "boundary=", parts: 2) do
        [_, b] -> String.trim(b)
        [_] -> nil
      end
    end)
  end

  # Splits the multipart body on the boundary and returns each part's
  # sub-request text (part headers stripped; the sub-request begins at the
  # first blank line inside the part). The closing "--boundary--" tail is
  # rejected.
  defp parse_batch_parts(body, boundary) do
    marker = "--" <> boundary

    parts =
      body
      |> String.split(marker)
      |> Enum.reject(fn chunk ->
        # SHIM-COURT-adjacent repair (R33): reject only the exact closing-boundary
        # tail ("--<boundary>--", i.e. a chunk that is just "--" plus whitespace),
        # not any chunk whose body merely starts with "--".
        trimmed = String.trim(chunk)
        trimmed in ["", "--"]
      end)
      |> Enum.map(fn chunk ->
        chunk
        |> String.trim_leading("\r\n")
        |> String.trim_trailing("\r\n")
        |> strip_part_headers()
      end)

    {:ok, parts}
  end

  # R67: hand-rolled curl batches may use LF-only line endings. Normalize lone
  # \n to \r\n so the header-block split below does not swallow the part head
  # into the sub-request line (which yielded a typed 400 per sub-request).
  defp strip_part_headers(chunk) do
    case :binary.split(normalize_crlf(chunk), "\r\n\r\n") do
      [_, sub_request] -> String.trim_leading(sub_request, "\r\n")
      [_] -> chunk
    end
  end

  defp send_batch_response(conn, _account, parts) do
    boundary = "batchresponse_" <> generate_request_id()

    chunks =
      parts
      |> Enum.with_index()
      |> Enum.map(fn {sub_request, idx} ->
        {status, headers, body} = dispatch_batch_subrequest(sub_request, idx)
        render_batch_part(idx, status, headers, body, boundary)
      end)

    response_body = IO.iodata_to_binary([chunks, "\r\n--", boundary, "--\r\n"])

    conn
    |> put_resp_header("x-ms-version", "2021-12-02")
    |> put_resp_header("x-ms-request-id", generate_request_id())
    |> put_resp_header("content-type", "multipart/mixed; boundary=#{boundary}")
    |> send_resp(202, response_body)
  end

  defp render_batch_part(idx, status, headers, body, boundary) do
    header_lines = Enum.map_join(headers, "\r\n", fn {k, v} -> "#{k}: #{v}" end)

    body_block =
      if body in [nil, ""] do
        ""
      else
        body
      end

    IO.iodata_to_binary([
      "\r\n--",
      boundary,
      "\r\nContent-Type: application/http\r\nContent-ID: ",
      Integer.to_string(idx),
      "\r\n\r\nHTTP/1.1 ",
      Integer.to_string(status),
      " ",
      plug_status_reason(status),
      "\r\n",
      header_lines,
      "\r\n\r\n",
      body_block,
      "\r\n"
    ])
  end

  defp plug_status_reason(status) do
    Plug.Conn.Status.reason_phrase(status)
  end

  # Dispatches one sub-request. Supported: Delete Blob, Set Blob Tier.
  # Returns {status, headers_list, body_string_or_empty}.
  defp dispatch_batch_subrequest(sub_request, _idx) do
    case parse_sub_request(sub_request) do
      {method, target, headers, _body} ->
        uri = URI.parse(target)
        query = URI.decode_query(uri.query || "")
        segments = Enum.reject(String.split(uri.path || "", "/"), &(&1 == ""))

        batch_dispatch_op(method, segments, query, headers)

      :error ->
        {400, [{"x-ms-error-code", "InvalidInput"}],
         batch_error_body("InvalidInput", "Malformed sub-request.")}
    end
  end

  defp batch_dispatch_op("DELETE", [account, container | blob_segments], _query, headers) do
    blob_name = Enum.join(blob_segments, "/")

    case BlobStorage.delete_blob(account, container, blob_name, headers) do
      {:ok, status, headers, _record} ->
        {status, Map.to_list(headers), ""}

      {:error, status, code, msg} ->
        {status, [{"x-ms-error-code", code}], batch_error_body(code, msg)}
    end
  end

  defp batch_dispatch_op(
         "PUT",
         [account, container | blob_segments],
         %{"comp" => "tier"},
         headers
       ) do
    blob_name = Enum.join(blob_segments, "/")

    case BlobStorage.set_blob_tier(account, container, blob_name, headers["x-ms-access-tier"]) do
      {:ok, status, headers, _} ->
        {status, Map.to_list(headers), ""}

      {:error, status, code, msg} ->
        {status, [{"x-ms-error-code", code}], batch_error_body(code, msg)}
    end
  end

  defp batch_dispatch_op(_method, _segments, _query, _headers) do
    {400, [{"x-ms-error-code", "InvalidOperation"}],
     batch_error_body("InvalidOperation", "Unsupported batch sub-request operation.")}
  end

  defp batch_error_body(code, msg) do
    Jason.encode!(%{"error" => %{"code" => code, "message" => msg}})
  end

  # Parses an HTTP sub-request: "METHOD /path?query HTTP/1.1" + headers
  # [+ body]. Returns {method, target, headers_map, body} or :error.
  defp parse_sub_request(sub) do
    case :binary.split(sub, "\r\n\r\n") do
      [head, body] -> parse_sub_head(head, body)
      [_] -> parse_sub_head(sub, "")
    end
  end

  # R67: same LF normalization for the sub-request head itself (request line +
  # header lines), so an LF-only sub-request inside an otherwise-CRLF part parses.
  defp parse_sub_head(head, body) do
    [req_line | header_lines] = String.split(normalize_crlf(head), "\r\n")
    segments = String.split(String.trim(req_line), " ")

    with [method, target, _version] <- segments do
      headers =
        header_lines
        |> Enum.reject(&(&1 == ""))
        |> Enum.map(fn line ->
          case :binary.split(line, ":") do
            [k, v] -> {String.downcase(String.trim(k)), String.trim(v)}
            [k] -> {String.downcase(String.trim(k)), ""}
          end
        end)
        |> Map.new()

      {method, target, headers, body}
    else
      _ -> :error
    end
  end

  # R67: replace "\r\n" with "\n" first, then "\n" with "\r\n" — normalizes
  # lone LF to CRLF without doubling existing CRLF.
  defp normalize_crlf(bin) do
    bin
    |> String.replace("\r\n", "\n")
    |> String.replace("\n", "\r\n")
  end

  defp header_map(conn) do
    Map.new(conn.req_headers)
  end

  # Sentinel DCR ingest body handling: total — object wraps to a single-event
  # batch, list is the batch, anything else (nil/Unfetched/scalars) is an
  # InvalidBody refusal instead of a FunctionClauseError 500.
  defp normalize_list_body(conn) do
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

  defp read_raw_body(conn) do
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
  defp wrap_json_list(%{"_json" => list}) when is_list(list), do: list
  defp wrap_json_list(%{"_json" => single}), do: List.wrap(single)
  defp wrap_json_list(%{} = single), do: [single]
  defp wrap_json_list(batch) when is_list(batch), do: batch
  defp wrap_json_list(_other), do: {:error, :invalid_body}

  # Body-parameter seam guard: Plug.Parsers is configured with pass: ["*/*"],
  # so a non-JSON content-type (or an empty body) leaves body_params as
  # %Plug.Conn.Unfetched{} (or a scalar). Data-plane handlers that consume
  # body_params as JSON must never see that — refuse with a 400 envelope at
  # this seam instead of crashing with a 500 inside a callee.
  defp with_valid_body(conn, fun) do
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

  defp invalid_body_error do
    %{"error" => %{"code" => "InvalidBody"}}
  end

  # Belt-and-braces: even with the seam guard, a malformed parameter that
  # slips through to a callee (ConfidentialLedger.canonical/1,
  # Cosmos.quoted_sha256/1, ...) must degrade to a 400 envelope, never a 500.
  defp safe_dispatch(conn, fun) do
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
  defp events_content_type(conn) do
    case get_req_header(conn, "content-type") do
      [ct] -> if String.contains?(ct, "json"), do: :json, else: :unsupported
      _ -> :unsupported
    end
  end

  defp events_post(conn, topic) do
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
  defp query_post?(conn) do
    case get_req_header(conn, "content-type") do
      [ct | _] -> String.contains?(ct, "query+json")
      _ -> false
    end
  end

  defp query_post(conn, db, coll) do
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

  defp id_param(conn) do
    case Map.get(conn.body_params, "id") do
      name when is_binary(name) and name != "" -> {:ok, name}
      _ -> :error
    end
  end

  # RFC 6902 patch body: a top-level JSON array of ops. Plug.Parsers wraps a
  # decoded top-level array as %{"_json" => list}; admit ONLY the list form.
  defp unwrap_patch_ops(%{"_json" => ops}) when is_list(ops), do: {:ok, ops}
  defp unwrap_patch_ops(ops) when is_list(ops), do: {:ok, ops}
  defp unwrap_patch_ops(_other), do: :error

  defp cosmos_respond(conn, {:error, :store_not_ready}) do
    route_not_ready(conn)
  end

  defp cosmos_respond(conn, {:ok, status, headers, body}) when is_map(headers) do
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
  defp generate_request_id do
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

  defp send_json(conn, status, body) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(status, Jason.encode!(body))
  end

  # F5 (compliance-corpus lens-4 work order): real Azure emits
  # x-ms-request-id + x-ms-version on ERROR responses too. Blob-plane-scoped
  # renderer — shared send_json is untouched (ARM/LA/Cosmos/KV envelope pins
  # must not see blob headers). v4 GUID from generate_request_id/0.
  # Quoted opaque container ETag for the Put Container 201 render — delegates
  # to the single derivation in BlobService.container_etag/1 (R62 repair 1),
  # stable per (account, container, created_at).
  defp container_put_etag(record) do
    BlobService.container_etag(record)
  end

  # Lane 06 (v26.10.14) defect 3, part 2: blob error responses now carry the
  # error code in the x-ms-error-code header, extracted from the JSON body's
  # code slot (either envelope shape). Additive — the JSON body is unchanged.
  defp blob_error(conn, status, body) do
    conn
    |> put_resp_header("x-ms-request-id", generate_request_id())
    |> put_resp_header("x-ms-version", "2021-12-02")
    |> put_error_code_header(body)
    |> send_json(status, body)
  end

  defp put_error_code_header(conn, body) do
    case blob_error_code(body) do
      nil -> conn
      code -> put_resp_header(conn, "x-ms-error-code", code)
    end
  end

  defp blob_error_code(%{"error" => %{"code" => code}}) when is_binary(code), do: code
  defp blob_error_code(%{"code" => code}) when is_binary(code), do: code
  defp blob_error_code(_), do: nil

  # Lane 06 (v26.10.14) defect 3, part 1: on the blob comp=list routes the
  # real Azure Blob service answers typed errors with an XML
  # <?xml?><Error><Code/><Message/></Error> envelope (Content-Type
  # application/xml), not JSON. Scoped to the comp=list arms only — every
  # other blob_error/3 consumer (ledger, cosmos, KV, attestation, sentinel)
  # keeps byte-identical JSON output.
  defp blob_error_xml(conn, status, code, message) do
    xml =
      ~s(<?xml version="1.0" encoding="utf-8"?><Error><Code>#{BlobService.xml_escape(code)}</Code><Message>#{BlobService.xml_escape(message)}</Message></Error>)

    conn
    |> put_resp_header("x-ms-request-id", generate_request_id())
    |> put_resp_header("x-ms-version", "2021-12-02")
    |> put_resp_header("x-ms-error-code", code)
    |> put_resp_content_type("application/xml")
    |> send_resp(status, xml)
  end

  defp not_found_error(code) do
    %{"error" => %{"code" => code}}
  end

  # ---------------------------------------------------------------------------
  # GAP-AUD1-01 (v26.10.14, lane W-5): blob comp whitelist.
  #
  # The generic Put/Get Blob fallback arms previously absorbed every `comp`
  # value they did not name (appendblock, snapshot, page, pagelist, tags,
  # query, tier, expiry, seal, lease, copy) and silently overwrote / served
  # the blob body — the AUD-1 headline corruption class. Whitelist = exactly
  # the comps with implemented handlers on each arm. Container-level comps
  # (list, acl, legalhold, immutabilityPolicy) are routed on the container
  # routes and never reach these arms. Unimplemented features stay KD rows;
  # the class is dead because an unlisted comp can no longer touch the body.
  # ---------------------------------------------------------------------------

  # R124: the blob and container `?/2` predicates were byte-identical —
  # collapsed into one helper. The two error envelopes stay separate
  # functions (their messages genuinely differ; see each below).
  defp unhandled_comp?(conn, allowed) do
    case conn.query_params["comp"] do
      v when is_binary(v) and v != "" -> v not in allowed
      # A14 (D14/KD-60): Plug decodes duplicate query keys into a LIST, so
      # ?comp=metadata&comp=lease yields %{"comp" => ["metadata", "lease"]} —
      # the is_binary/1 clause above admitted it, skipping every whitelist and
      # falling into the true -> catch-all (201-lie class reopened on both
      # blob and container arms). Default-deny: any list-form comp refuses.
      v when is_list(v) -> true
      _ -> false
    end
  end

  # A14: error-envelope rendering for the list-form comp — "a, b", not the
  # Elixir inspect of a list.
  defp comp_str(v) when is_list(v), do: Enum.join(v, ", ")
  defp comp_str(v), do: v

  # R124 message convention (both comp-error envelopes): the wire-visible
  # prefix `The comp value '<v>' is not supported` is byte-identical and
  # test-pinned (blob_hardening_test.exs). The GAP clause
  # `(GAP(blob-comp-lease-absent)): ...` is appended ONLY where a registered
  # GAP row names the comp family — container lease/ACL — never on the blob
  # arm, whose unhandled comps (appendblock, snapshot, page, ...) span more
  # than the lease GAP and would overclaim.
  defp unhandled_blob_comp_error(conn, v) do
    blob_error(conn, 400, %{
      "error" => %{
        "code" => "InvalidQueryParameterValue",
        "message" => "The comp value '#{comp_str(v)}' is not supported."
      }
    })
  end

  # R98 container comp whitelist (mirror of the blob-arm whitelist above).
  # restype=container carries no comp and comp=nil is admitted; any other
  # comp value with no implemented container handler answers the same typed
  # InvalidQueryParameterValue envelope as the blob arms, naming the registered
  # GAP so the wire no longer lies via fallthrough (PUT 201 / GET 200).
  defp unhandled_container_comp_error(conn, v) do
    blob_error(conn, 400, %{
      "error" => %{
        "code" => "InvalidQueryParameterValue",
        "message" =>
          "The comp value '#{comp_str(v)}' is not supported (GAP(blob-comp-lease-absent)): " <>
            "container leases and ACLs are not implemented."
      }
    })
  end

  # Key Vault action tuple helper: {:ok, status, body} / {:error, status, body}.
  defp kv_respond(conn, {:ok, status, body}), do: send_json(conn, status, body)
  defp kv_respond(conn, {:error, status, body}), do: send_json(conn, status, body)

  # x-ms-meta-* request headers -> %{"name" => "value"} map (BlobService
  # container metadata). Response direction: meta dict -> x-ms-meta-* headers.
  # Wire body (Azure shape) -> BlobStorage.set_immutability_policy/5 policy map.
  #
  # Body seam: Plug.Parsers may already have consumed and decoded the JSON
  # body (body_params is a map) — re-reading the stream would return "" and
  # lose the policy. Read body_params first; read_body is only the fallback
  # for unparsed content-types. A non-empty body that fails to decode is a
  # 400 InvalidXmlOrJson, never a nil-expires 500 downstream.
  defp immutability_policy_from_wire(conn) do
    case conn.body_params do
      %Plug.Conn.Unfetched{} ->
        case Plug.Conn.read_body(conn) do
          {:ok, raw, conn} -> decode_policy_body(raw, conn)
          {:error, _reason} -> {:error, conn}
        end

      params when is_map(params) ->
        {:ok, policy_from_params(params), conn}

      _other ->
        {:error, conn}
    end
  end

  defp decode_policy_body("", conn), do: {:ok, %{}, conn}

  defp decode_policy_body(raw, conn) do
    case Jason.decode(raw) do
      {:ok, %{} = body} -> {:ok, policy_from_params(body), conn}
      _ -> {:error, conn}
    end
  end

  defp policy_from_params(body) do
    %{
      "locked" => Map.get(body, "locked", false) == true,
      "period_days" => period_days(Map.get(body, "immutabilityPeriodSinceCreationInDays", 0)),
      "until" => Map.get(body, "expiresOn")
    }
    |> Enum.reject(fn {_k, v} -> is_nil(v) end)
    |> Map.new()
  end

  defp period_days(days) when is_integer(days), do: days

  defp period_days(days) when is_binary(days) do
    case Integer.parse(days) do
      {n, ""} -> n
      _ -> days
    end
  end

  defp period_days(other), do: other

  defp meta_headers(%Plug.Conn{} = conn) do
    Enum.reduce(conn.req_headers, %{}, fn {name, value}, acc ->
      case name do
        "x-ms-meta-" <> meta_name -> Map.put(acc, meta_name, value)
        _ -> acc
      end
    end)
  end

  defp meta_headers(meta) when is_map(meta) do
    Map.new(meta, fn {name, value} -> {"x-ms-meta-#{name}", to_string(value)} end)
  end

  # KD-01 echo: stored x-ms-meta-* ride GET/HEAD blob responses (Azure Get
  # Blob metadata). Scoped to the x-ms-meta-* subset — the stored header map
  # carries the full PUT request headers (auth, x-ms-version) and only user
  # metadata is wire-safe to emit.
  defp stored_meta_wire(blob) do
    blob
    |> Map.get("headers", %{}) ||
      %{}
      |> Enum.filter(fn {k, _v} -> String.starts_with?(k, "x-ms-meta-") end)
  end

  defp put_resp_headers(conn, headers) do
    Enum.reduce(headers, conn, fn
      # Engine header maps may carry nil values (measured: BlobService
      # get_container_properties emits "last-modified" => nil on a fresh
      # container — HEAD container crashed with FunctionClauseError inside
      # put_resp_header). nil means "header absent" at this seam; skip it.
      {_name, nil}, conn -> conn
      {name, value}, conn -> Plug.Conn.put_resp_header(conn, name, value)
    end)
  end

  # BlobService header-only responses (container metadata PUT / properties).
  defp send_headers(conn, status, headers) do
    put_resp_headers(conn, headers)
    |> send_resp(status, "")
  end

  defp put_message(body, msg), do: put_in(body, ["error", "message"], msg)
end
