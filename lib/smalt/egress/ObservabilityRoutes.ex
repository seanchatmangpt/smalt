defmodule Smalt.Egress.ObservabilityRoutes do
  @moduledoc """
  w6R structural split of Smalt.EgressRouter (BEAM implementation limit,
  function '__MODULE__'/1+14): /topics, /dataCollectionRules, /v1/workspaces, /v2/track, ResourceGraph, /atlas arm, verbatim relocation.
  Fallthrough router — unmatched conns pass through un-halted; the main
  router's blob splat + 404 catch-all handle everything else, unchanged.
  """
  use Plug.Router
  import Smalt.EgressRouter, except: [match: 2, match: 3, dispatch: 2]
  alias Smalt.DataPlane.Purview
  alias Smalt.DataPlane.ResourceGraph
  alias Smalt.DataPlane.Sentinel
  alias Smalt.Messaging.EventStream
  plug :match
  plug :dispatch



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
  # Application Insights Breeze ingest (v26.10.20 wave-6, lane w6s)
  # ---------------------------------------------------------------------------
  post "/v2/track" do
    with_route(conn, Smalt.Monitor.AppInsights, fn conn ->
      with_valid_body(conn, fn conn ->
        body = conn.body_params || %{}

        case Smalt.Monitor.AppInsights.track(body) do
          {:ok, status, body} -> blob_error(conn, status, body)
          {:error, status, body} -> blob_error(conn, status, body)
        end
      end)
    end)
  end

  get "/v2/track/summary" do
    with_route(conn, Smalt.Monitor.AppInsights, fn conn ->
      case Smalt.Monitor.AppInsights.summary() do
        {:ok, body} ->
          conn
          |> put_resp_content_type("application/json")
          |> send_resp(200, Jason.encode!(body))
      end
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
end
