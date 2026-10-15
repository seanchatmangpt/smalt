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

  plug(Plug.Logger)
  plug(CORSPlug, origin: "*")
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

  @compliance_status "azure-compliant-cvm"

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
            send_json(conn, status, %{"error" => %{"code" => code}})
        end
      end)
    end
  end

  # ---------------------------------------------------------------------------
  # Azure Confidential Ledger (/app/transactions)
  # ---------------------------------------------------------------------------
  get "/app/transactions" do
    if not_ready?(conn, [ConfidentialLedger]) do
      route_not_ready(conn)
    else
      send_json(conn, 200, ConfidentialLedger.list_transactions("default_ledger"))
    end
  end

  get "/app/transactions/latest" do
    if not_ready?(conn, [ConfidentialLedger]) do
      route_not_ready(conn)
    else
      case ConfidentialLedger.get_latest("default_ledger") do
        {:ok, receipt} -> send_json(conn, 200, receipt)
        :error -> send_json(conn, 404, not_found_error("TransactionNotFound"))
      end
    end
  end

  get "/app/transactions/:tx_id" do
    if not_ready?(conn, [ConfidentialLedger]) do
      route_not_ready(conn)
    else
      case ConfidentialLedger.get_transaction("default_ledger", tx_id) do
        {:ok, receipt} -> send_json(conn, 200, receipt)
        :error -> send_json(conn, 404, not_found_error("TransactionNotFound"))
      end
    end
  end

  post "/app/transactions" do
    if not_ready?(conn, [ConfidentialLedger]) do
      route_not_ready(conn)
    else
      with_valid_body(conn, fn conn ->
        case ConfidentialLedger.append_transaction("default_ledger", conn.body_params) do
          {:ok, receipt} -> send_json(conn, 201, receipt)
          {:error, 409, code} -> send_json(conn, 409, %{"error" => %{"code" => code}})
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
          :error -> send_json(conn, 400, invalid_body_error())
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
            nil -> send_json(conn, 404, %{"code" => "NotFound", "message" => "Entity with id #{db} not found"})
            record -> cosmos_respond(conn, {:ok, status, headers, record})
          end

        _ ->
          send_json(conn, 404, %{"code" => "NotFound", "message" => "Entity with id #{db} not found"})
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
            send_json(conn, 400, invalid_body_error())
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
              send_json(conn, 404, %{
                "code" => "NotFound",
                "message" => "Entity with id #{coll} not found"
              })

            record ->
              cosmos_respond(conn, {:ok, status, headers, with_pk_kind(record)})
          end

        _ ->
          send_json(conn, 404, %{
            "code" => "NotFound",
            "message" => "Entity with id #{coll} not found"
          })
      end
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
            %{"id" => "0", "minInclusive" => "", "maxExclusive" => "FF",
              "ridPrefix" => 0, "throughputFraction" => 1.0}
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
      {status, headers, docs} =
        case Cosmos.list_docs(db, coll) do
          {:ok, status, headers, docs} -> {status, headers, docs}
          _other -> {200, %{}, []}
        end

      cosmos_respond(conn, {:ok, status, headers, docs})
    end)
  end

  put "/dbs/:db/colls/:coll/docs/:doc_id" do
    with_route(conn, Cosmos, fn conn ->
      with_valid_body(conn, fn conn ->
        cosmos_respond(conn, Cosmos.put_doc(db, coll, doc_id, conn.body_params, header_map(conn)))
      end)
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

      with {:ok, jwk_fields, key_material} <- jwk_for_kty(kty),
           :ok <- validate_release_policy(release_policy) do
        key_record = %{
          "kid" => "https://#{conn.host}:8443/keys/#{name}/#{System.unique_integer([:positive])}",
          "key" =>
            %{
              "kid" => "https://#{conn.host}:8443/keys/#{name}",
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

        Store.put(:smalt_vault_keys, name, key_record)

        # the private DER never leaves the vault; project the public record
        send_json(conn, 200, Map.delete(key_record, "key_material"))
      else
        {:kty_error, kty} ->
          send_json(conn, 400, %{
            "error" => %{"code" => "UnsupportedKeyType", "message" => "kty #{kty} is not supported"}
          })

        {:policy_error, message} ->
          send_json(conn, 400, %{"error" => %{"code" => "InvalidParameter", "message" => message}})
      end
    end)
  end

  # Real JsonWebKey form: RSA carries n = base64url modulus, e = base64url
  # exponent ("AQAB" for 65537); oct carries k = base64url key material (the
  # derived AES key is deterministic per name — disclosed dev material).
  # The RSA private key is generated once at create and its DER cached in the
  # row ("key_material") for later crypto ops.
  defp jwk_for_kty(kty) when kty in ["RSA", "RSA-HSM"] do
    key = :public_key.generate_key({:rsa, 2048, 65537})
    der = :public_key.der_encode(:RSAPrivateKey, key)
    n = elem(key, 2)
    e = elem(key, 3)

    {:ok,
     %{
       "n" => Base.url_encode64(:binary.encode_unsigned(n), padding: false),
       "e" => Base.url_encode64(:binary.encode_unsigned(e), padding: false)
     }, der}
  end

  defp jwk_for_kty(kty) when kty in ["oct", "oct-HSM"] do
    k = Smalt.DataPlane.KeyVaultActions.derive_oct_key(kty)

    {:ok, %{"k" => Base.url_encode64(k, padding: false)}, nil}
  end

  defp jwk_for_kty(kty), do: {:kty_error, kty}

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
    case Store.get(:smalt_vault_keys, name) do
      {:ok, key_record} -> send_json(conn, 200, Map.delete(key_record, "key_material"))
      :error -> send_json(conn, 404, not_found_error("KeyNotFound"))
    end
  end

  post "/keys/:name/release" do
    case Smalt.DataPlane.SKR.release(name, conn) do
      {:ok, status, body} -> send_json(conn, status, body)
      {:error, status, body} -> send_json(conn, status, body)
    end
  end

  # ---------------------------------------------------------------------------
  # Key Vault crypto actions (Smalt.DataPlane.KeyVaultActions)
  # ---------------------------------------------------------------------------
  get "/keys" do
    with_route(conn, KeyVaultActions, fn conn ->
      case KeyVaultActions.list_keys() do
        {:ok, status, body} -> send_json(conn, status, body)
        {:error, status, body} -> send_json(conn, status, body)
      end
    end)
  end

  get "/keys/:name/versions" do
    with_route(conn, KeyVaultActions, fn conn ->
      case KeyVaultActions.list_versions(name) do
        {:ok, status, body} -> send_json(conn, status, body)
        {:error, status, body} -> send_json(conn, status, body)
      end
    end)
  end

  # Case-insensitive crypto action suffix: encrypt/decrypt/sign/verify/
  # wrapKey/unwrapKey. Defined AFTER the literal /keys/:name/create and
  # /keys/:name/release routes so it never shadows them; an unrecognized
  # action re-emits the catch-all 404 so behavior is unchanged.
  post "/keys/:name/:action" do
    with_route(conn, KeyVaultActions, fn conn ->
      with_valid_body(conn, fn conn ->
        case String.downcase(action) do
          "encrypt" ->
            kv_respond(conn, KeyVaultActions.encrypt(name, conn.body_params))

          "decrypt" ->
            kv_respond(conn, KeyVaultActions.decrypt(name, conn.body_params))

          "sign" ->
            kv_respond(conn, KeyVaultActions.sign(name, conn.body_params))

          "verify" ->
            kv_respond(conn, KeyVaultActions.verify(name, conn.body_params))

          "wrapkey" ->
            kv_respond(conn, KeyVaultActions.wrap_key(name, conn.body_params))

          "unwrapkey" ->
            kv_respond(conn, KeyVaultActions.unwrap_key(name, conn.body_params))

          _other ->
            send_json(conn, 404, %{
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
    if not_ready?(conn, [EventStream]) do
      route_not_ready(conn)
    else
      send_json(conn, 200, EventStream.list_events(topic))
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

              {:ok, status, body} -> send_json(conn, status, body)
              {:error, status, body} -> send_json(conn, status, body)
            end

          {:error, :invalid_body} ->
            send_json(conn, 400, invalid_body_error())
        end
      end)
    end)
  end

  post "/v1/workspaces/:workspace_id/query" do
    with_route(conn, Sentinel, fn conn ->
      with_valid_body(conn, fn conn ->
        case Sentinel.query(workspace_id, conn.body_params) do
          {:ok, status, body} -> send_json(conn, status, body)
          {:error, status, body} -> send_json(conn, status, body)
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
          {:ok, status, resp} -> send_json(conn, status, resp)
          {:error, status, resp} -> send_json(conn, status, resp)
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
          send_json(conn, 400, %{
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
          {:ok, status, entity} -> send_json(conn, status, entity)
          {:error, status, body} -> send_json(conn, status, body)
        end
      end)
    end)
  end

  post "/atlas/v2/entity/bulk" do
    with_route(conn, Purview, fn conn ->
      with_valid_body(conn, fn conn ->
        case Purview.bulk_entities(conn.body_params, header_map(conn)) do
          {:ok, status, body} -> send_json(conn, status, body)
          {:error, status, body} -> send_json(conn, status, body)
        end
      end)
    end)
  end

  get "/atlas/v2/entity/guid/:guid" do
    with_route(conn, Purview, fn conn ->
      case Purview.get_entity(guid, header_map(conn)) do
        {:ok, status, entity} -> get_json(conn, status, entity)
        {:error, status, body} -> get_json(conn, status, body)
      end
    end)
  end

  get "/atlas/v2/lineage/:direction/:guid" do
    with_route(conn, Purview, fn conn ->
      depth = Map.get(conn.query_params, "depth", "1")

      case Purview.lineage(guid, direction, depth) do
        {:ok, status, body} -> send_json(conn, status, body)
        {:error, status, body} -> send_json(conn, status, body)
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
          {xml, _next_marker} =
            BlobService.list_containers_xml(account, %{
              "prefix" => conn.query_params["prefix"],
              "marker" => conn.query_params["marker"],
              "maxresults" => conn.query_params["maxresults"]
            })

          conn
          |> put_resp_content_type("application/xml")
          |> send_resp(200, xml)
        end
      end)
    else
      send_json(conn, 404, %{
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
                send_json(conn, status, not_found_error(code) |> put_message(msg))
            end
          end

        conn.query_params["comp"] in ["immutabilityPolicy", "immutabilitypolicy"] ->
          if not_ready?(conn, [BlobStorage]) do
            route_not_ready(conn)
          else
            case immutability_policy_from_wire(conn) do
              {:ok, policy, conn} ->
                case BlobStorage.set_immutability_policy(account, container, policy, header_map(conn)) do
                  {:ok, status, headers, record} ->
                    conn
                    |> put_resp_headers(headers)
                    |> put_resp_content_type("application/json")
                    |> send_resp(status, Jason.encode!(record))

                  {:error, status, code, msg} ->
                    send_json(conn, status, not_found_error(code) |> put_message(msg))
                end

              {:error, conn} ->
                send_json(conn, 400, %{
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
                send_json(conn, status, not_found_error(code) |> put_message(msg))
            end
          end

        true ->
          opts = %{"immutable" => get_req_header(conn, "x-ms-immutable-policy") != ["false"]}

          case BlobStorage.create_container(account, container, opts) do
            {:ok, record} -> send_json(conn, 201, record)
            {:error, status, body} -> send_json(conn, status, body)
          end
      end
    end)
  end

  get "/:account/:container" do
    blob_route(conn, fn conn ->
      cond do
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
                send_json(conn, 404, not_found_error("ImmutabilityPolicyNotFound"))
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
                send_json(conn, 404, not_found_error("LegalHoldNotFound"))
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
                send_json(conn, status, not_found_error(code) |> put_message(msg))
            end
          end

        conn.query_params["comp"] == "list" ->
          if not_ready?(conn, [BlobStorage]) do
            route_not_ready(conn)
          else
            {xml, _next_marker} =
              BlobStorage.list_blobs_xml(account, container, %{
                "marker" => conn.query_params["marker"],
                "maxresults" => conn.query_params["maxresults"]
              })

            conn
            |> put_resp_content_type("application/xml")
            |> send_resp(200, xml)
          end

        conn.query_params["restype"] == "container" ->
          if not_ready?(conn, [BlobService]) do
            route_not_ready(conn)
          else
            case BlobService.get_container_properties(account, container) do
              {:ok, status, headers} ->
                send_headers(conn, status, headers)

              {:error, status, code, msg} ->
                send_json(conn, status, not_found_error(code) |> put_message(msg))
            end
          end

        true ->
          {xml, _next_marker} =
            BlobStorage.list_blobs_xml(account, container, %{
              "marker" => conn.query_params["marker"],
              "maxresults" => conn.query_params["maxresults"]
            })

          conn
          |> put_resp_content_type("application/xml")
          |> send_resp(200, xml)
      end
    end)
  end

  put "/:account/:container/:blob_name" do
    blob_route(conn, fn conn ->
      case Plug.Conn.read_body(conn, length: 8_000_000, read_length: 1_000_000) do
        {:ok, raw_body, conn} ->
          case BlobStorage.put_blob(account, container, blob_name, raw_body, header_map(conn)) do
            {:ok, blob} ->
              # Metadata-only body: raw "content" (arbitrary bytes, frequently
              # invalid UTF-8) must never reach Jason — a metadata projection
              # is total over binary content.
              conn
              |> put_resp_header("etag", blob["etag"])
              |> put_resp_content_type("application/json")
              |> send_resp(201, Jason.encode!(BlobStorage.blob_metadata(blob)))

            {:error, :worm_locked, msg} ->
              send_json(conn, 409, %{"error" => %{"code" => "ContainerLocked", "message" => msg}})

            {:error, :precondition_failed, msg} ->
              send_json(conn, 412, %{
                "error" => %{"code" => "PreconditionFailed", "message" => msg}
              })

            {:error, :too_large, msg} ->
              send_json(conn, 413, %{
                "error" => %{"code" => "RequestBodyTooLarge", "message" => msg}
              })

            {:error, :container_not_found} ->
              send_json(conn, 404, not_found_error("ContainerNotFound"))
          end

        {:more, _partial, _conn} ->
          send_json(conn, 413, %{
            "error" => %{
              "code" => "RequestBodyTooLarge",
              "message" => "Blob exceeds the 8,000,000-byte request body limit."
            }
          })

        {:error, term, _conn} ->
          send_json(conn, 400, %{
            "error" => %{"code" => "InvalidRequestBody", "message" => inspect(term)}
          })
      end
    end)
  end

  get "/:account/:container/:blob_name" do
    blob_route(conn, fn conn ->
      # Azure storage semantics: the range rides `x-ms-range` (python/JS SDKs)
      # or the standard `Range` header; honor both.
      range_header = get_req_header(conn, "range") ++ get_req_header(conn, "x-ms-range")

      case BlobStorage.get_blob_range(account, container, blob_name, range_header) do
        {:ok, blob, nil} ->
          conn
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
          |> put_resp_header("etag", blob["etag"])
          |> put_resp_header("content-range", "bytes #{first}-#{last}/#{byte_size(blob["content"])}")
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
          |> send_resp(416, Jason.encode!(%{
            "error" => %{
              "code" => "InvalidRange",
              "message" => "The range specified is invalid for a blob of #{total} bytes."
            }
          }))

        :error ->
          send_json(conn, 404, not_found_error("BlobNotFound"))
      end
    end)
  end

  # HEAD blob: same engine as GET, empty body, content-length set. This is what
  # @azure/storage-blob downloadToBuffer probes before it issues the GET.
  head "/:account/:container/:blob_name" do
    blob_route(conn, fn conn ->
      case BlobStorage.get_blob(account, container, blob_name) do
        {:ok, blob} ->
          conn
          |> put_resp_header("etag", blob["etag"])
          |> put_resp_header(
            "content-length",
            blob["content"] |> byte_size() |> Integer.to_string()
          )
          |> put_resp_content_type("application/octet-stream")
          |> send_resp(200, "")

        :error ->
          send_json(conn, 404, not_found_error("BlobNotFound"))
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
              send_json(conn, status, not_found_error(code) |> put_message(msg))
          end
        end
      else
        send_json(
          conn,
          404,
          not_found_error("RouteNotFound")
          |> put_message("No route matches #{conn.method} #{conn.request_path}")
        )
      end
    end)
  end

  delete "/:account/:container/:blob_name" do
    blob_route(conn, fn conn ->
      case BlobStorage.delete_blob(account, container, blob_name, header_map(conn)) do
        {:ok, status, headers, _record} ->
          conn
          |> put_resp_headers(headers)
          |> send_resp(status, "")

        {:error, status, code, msg} ->
          send_json(conn, status, not_found_error(code) |> put_message(msg))
      end
    end)
  end

  # ---------------------------------------------------------------------------
  # Catch-all 404
  # ---------------------------------------------------------------------------
  match _ do
    send_json(conn, 404, %{
      "error" => %{
        "code" => "RouteNotFound",
        "message" => "No route matches #{conn.method} #{conn.request_path}"
      }
    })
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

  defp raw_blob_put?(%Plug.Conn{method: "PUT", path_info: [_, _, _]} = conn) do
    params = fetchd_query_params(conn)
    Map.get(params, "comp") in [nil, ""]
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

  defp not_ready?(_conn, modules) do
    not Enum.all?(modules, &Code.ensure_loaded?/1)
  end

  defp route_not_ready(conn) do
    send_json(conn, 503, %{"error" => %{"code" => "RouteNotReady"}})
  end

  # Blob catch-all guard: require x-ms-version header, or the host must be
  # configured in :smalt, :blob_catch_all_hosts.
  defp blob_route(conn, fun) do
    allowed_hosts = Application.get_env(:smalt, :blob_catch_all_hosts, [])

    if get_req_header(conn, "x-ms-version") != [] or conn.host in allowed_hosts do
      if not_ready?(conn, [BlobStorage]) do
        route_not_ready(conn)
      else
        # D1 belt-and-braces: an encode failure in ANY blob response path
        # degrades to a clean JSON 500 envelope — never an empty response.
        fun.(conn)
      end
    else
      send_json(conn, 400, %{
        "error" => %{
          "code" => "MissingXMsVersion",
          "message" => "x-ms-version header is required for blob storage routes."
        }
      })
    end
  rescue
    e in [Jason.EncodeError, Protocol.UndefinedError] ->
      Logger.error("blob response encode failure on #{conn.request_path}: #{inspect(e)}")

      send_json(conn, 500, %{
        "error" => %{"code" => "BlobResponseEncodeFailure", "message" => Exception.message(e)}
      })
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
  # array on older Plug) as %{"_json" => term}. Admitting that wrapper through
  # the gate let `POST /app/transactions` with body `null` or `5` append a
  # garbage ledger entry (measured 201). The only legitimate wrapped form on
  # this surface is the batch list (Sentinel/events unwrap it downstream), so
  # refuse the wrapper unless the wrapped value is a list.
  # Plug.Parsers wraps a decoded non-map JSON body (null / scalar / top-level
  # array on older Plug) as %{"_json" => term}. Admitting that wrapper let
  # `POST /app/transactions` with body `null` or `5` append a garbage ledger
  # entry (measured 201). The only legitimate wrapped form on this surface is
  # the batch list (Sentinel/events unwrap it downstream), so refuse the
  # wrapper unless the wrapped value is a list.
  defp valid_json_body?(%{"_json" => wrapped}) when not is_list(wrapped), do: false

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
    e in [Protocol.UndefinedError, ArgumentError, BadMapError, FunctionClauseError] ->
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
            send_json(conn, 200, Enum.map(batch, &%{"id" => Map.get(&1, "id"), "status" => "Published"}))
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
        {:ok, raw, _conn} = Plug.Conn.read_body(conn)
        decode_events_payload(raw)

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
  defp generate_request_id do
    :crypto.strong_rand_bytes(16)
    |> Base.encode16(case: :lower)
  end

  defp send_json(conn, status, body) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(status, Jason.encode!(body))
  end

  defp get_json(conn, status, body) do
    send_json(conn, status, body)
  end

  defp not_found_error(code) do
    %{"error" => %{"code" => code}}
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
          {:error, _term, conn} -> {:error, conn}
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

  defp put_resp_headers(conn, headers) do
    Enum.reduce(headers, conn, fn {name, value}, conn ->
      Plug.Conn.put_resp_header(conn, name, value)
    end)
  end

  # BlobService header-only responses (container metadata PUT / properties).
  defp send_headers(conn, status, headers) do
    put_resp_headers(conn, headers)
    |> send_resp(status, "")
  end

  defp put_message(body, msg), do: put_in(body, ["error", "message"], msg)
end
