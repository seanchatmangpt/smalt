defmodule Smalt.Egress.SchemaRegistryRoutes do
  @moduledoc """
  w6R-split delegator (lane w6x): Event Hubs Schema Registry arm.
  Fallthrough router — unmatched conns pass through un-halted; the main
  router's blob splat + 404 catch-all handle everything else, unchanged.
  """
  use Plug.Router
  import Smalt.EgressRouter, except: [match: 2, match: 3, dispatch: 2]
  plug :match
  plug :dispatch



  alias Smalt.Messaging.EhSchemaRegistry

  # ---------------------------------------------------------------------------
  # Azure Event Hubs Schema Registry (capability wave-6, lane w6x).
  # ROUTE ORDER: /schemas/ids/:id must precede /schemas/:group/:name/... so
  # the bare-id read is not shadowed by the group/name splat.
  # ---------------------------------------------------------------------------
  get "/schemas/ids/:id" do
    if :ets.info(:smalt_eh_schemas) == :undefined do
      route_not_ready(conn)
    else
      case EhSchemaRegistry.get_by_id(id) do
        {:ok, body, _rec} ->
          conn
          |> put_resp_content_type("application/json")
          |> send_resp(200, body)

        {:error, {code, message}} ->
          schema_registry_error(conn, code, message)
      end
    end
  end

  get "/schemas/$schemagroups" do
    if :ets.info(:smalt_eh_schemas) == :undefined do
      route_not_ready(conn)
    else
      send_json(conn, 200, %{"groups" => EhSchemaRegistry.list_groups()})
    end
  end

  put "/schemas/$schemagroups/:group" do
    if :ets.info(:smalt_eh_schemas) == :undefined do
      route_not_ready(conn)
    else
      with_valid_body(conn, fn conn ->
        case EhSchemaRegistry.create_group(group, conn.body_params) do
          {:ok, rec} -> send_json(conn, 201, rec)
          {:error, {code, message}} -> schema_registry_error(conn, code, message)
        end
      end)
    end
  end

  get "/schemas/$schemagroups/:group" do
    if :ets.info(:smalt_eh_schemas) == :undefined do
      route_not_ready(conn)
    else
      case EhSchemaRegistry.get_group(group) do
        {:ok, rec} -> send_json(conn, 200, rec)
        {:error, {code, message}} -> schema_registry_error(conn, code, message)
      end
    end
  end

  delete "/schemas/$schemagroups/:group" do
    if :ets.info(:smalt_eh_schemas) == :undefined do
      route_not_ready(conn)
    else
      case EhSchemaRegistry.delete_group(group) do
        :ok -> send_resp(conn, 204, "")
        {:error, {code, message}} -> schema_registry_error(conn, code, message)
      end
    end
  end

  post "/schemas/:group/:name" do
    if :ets.info(:smalt_eh_schemas) == :undefined do
      route_not_ready(conn)
    else
      case read_raw_body(conn) do
        {:ok, raw} ->
          case EhSchemaRegistry.register_schema(group, name, raw) do
            {:ok, rec} ->
              conn
              |> put_resp_header("location", rec.location)
              |> send_json(201, rec)

            {:error, {code, message}} ->
              schema_registry_error(conn, code, message)
          end

        :error ->
          schema_registry_error(conn, "InvalidSchema", "request body could not be read")
      end
    end
  end

  get "/schemas/:group/:name/versions" do
    if :ets.info(:smalt_eh_schemas) == :undefined do
      route_not_ready(conn)
    else
      case EhSchemaRegistry.versions(group, name) do
        {:ok, vs} -> send_json(conn, 200, %{"versions" => vs})
        {:error, {code, message}} -> schema_registry_error(conn, code, message)
      end
    end
  end

  get "/schemas/:group/:name/versions/:v" do
    if :ets.info(:smalt_eh_schemas) == :undefined do
      route_not_ready(conn)
    else
      case Integer.parse(v) do
        {n, ""} ->
          case EhSchemaRegistry.get_version(group, name, n) do
            {:ok, rec} -> send_json(conn, 200, rec)
            {:error, {code, message}} -> schema_registry_error(conn, code, message)
          end

        _ ->
          schema_registry_error(conn, "InvalidVersion", "version must be an integer")
      end
    end
  end

  match _ do
    conn
  end

  defp schema_registry_error(conn, code, message) do
    status =
      case code do
        c when c in ["InvalidSchema", "InvalidVersion"] -> 400
        c when c in ["GroupNotFound", "SchemaNotFound"] -> 404
        _ -> 409
      end

    send_json(conn, status, %{"error" => %{"code" => code, "message" => message}})
  end
end
