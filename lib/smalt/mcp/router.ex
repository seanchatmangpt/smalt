defmodule Smalt.Mcp.Router do
  @moduledoc """
  Read-only MCP (JSON-RPC 2.0) tool surface over the smalt substrate for
  coding agents. Hand-written dispatch; the tool metadata comes from the
  generated `Smalt.Mcp.Descriptor` (elixir-mcp-a2a-pack shape, adapted).

  Tools: substrate.status, substrate.capabilities (Registry-derived),
  arm.get, cosmos.query, blob.list, sb.peek, kv.get, doctor.summary.

  READ-ONLY BY LAW: this surface exposes NO actuation tools. The substrate
  refuses unreceipted DO; any tool call for a non-registered (actuation or
  unknown) tool id is refused with a typed error, never dispatched. The
  fail-closed gate is `Smalt.Mcp.Descriptor.requires_authority?/1`: any id
  absent from the generated descriptor is treated as authority-requiring
  and refused.

  Mount as a Plug (wire for the coordinator):

      {Bandit,
       plug: {Smalt.Mcp.Router, []},
       scheme: :http,
       port: Application.get_env(:smalt, :mcp_port, 9545)}

  Tests exercise this module over `Plug.Test` with real substrate modules
  (no mocks) — see test/mcp_test.exs.
  """
  use Plug.Router
  use Plug.ErrorHandler

  plug(Plug.RequestId)
  plug(Plug.Logger)
  plug(:match)
  plug(:dispatch)

  @json_rpc_parse_error -32_700
  @json_rpc_method_not_found -32_601
  @json_rpc_invalid_params -32_602
  @tool_not_found_code "TOOL_NOT_FOUND"
  @invalid_params_code "INVALID_PARAMS"
  @actuation_refused_code "ACTUATION_REFUSED"
  @resource_not_found_code "RESOURCE_NOT_FOUND"
  @internal_code "MCP_INTERNAL"

  # Actuation verbs: any tool id carrying one of these fragments is a DO
  # attempt against a read-only surface, refused by name (not merely
  # "unknown").
  @actuation_fragments ~w(put post create delete update patch set enqueue send
                          complete abandon defer release deadletter encrypt
                          decrypt sign verify wrap unwrap actuate execute run
                          write commit)

  get "/" do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(200, Jason.encode!(%{"service" => "smalt-mcp", "protocol" => "JSON-RPC/2.0"}))
  end

  post "/" do
    with {:ok, body, conn} <- read_body(conn),
         {:ok, req} <- decode_rpc(body) do
      case req do
        %{"method" => "initialize"} = req ->
          respond(conn, req, %{
            "protocolVersion" => "2024-11-05",
            "capabilities" => %{"tools" => %{}},
            "serverInfo" => %{
              "name" => "smalt-mcp",
              "version" => to_string(Application.spec(:smalt, :vsn) || "0.0.0")
            }
          })

        %{"method" => "tools/list"} = req ->
          respond(conn, req, %{"tools" => tools()})

        %{"method" => "tools/call", "params" => %{"name" => name} = params} = req ->
          case dispatch_tool(name, params["arguments"] || %{}) do
            {:ok, result} ->
              respond(conn, req, %{
                "content" => [%{"type" => "text", "text" => Jason.encode!(result)}],
                "structuredContent" => result,
                "isError" => false
              })

            {:refusal, code, message} ->
              respond(conn, req, %{
                "content" => [
                  %{"type" => "text", "text" => message}
                ],
                "structuredContent" => %{"code" => code, "message" => message},
                "isError" => true
              })
          end

        # JSON-RPC batch: not supported, typed error per spec.
        %{"method" => _other} = req ->
          respond_error(conn, req, @json_rpc_method_not_found, "METHOD_NOT_FOUND", req["method"])
      end
    else
      {:error, :invalid_json} ->
        send_json_rpc_error(
          conn,
          400,
          nil,
          @json_rpc_parse_error,
          "PARSE_ERROR",
          "invalid JSON body"
        )

      {:error, :invalid_request} ->
        send_json_rpc_error(
          conn,
          400,
          nil,
          @json_rpc_invalid_params,
          "INVALID_REQUEST",
          "request is not a JSON-RPC 2.0 object"
        )
    end
  end

  match _ do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(404, Jason.encode!(%{"error" => "not found"}))
  end

  # ---------------------------------------------------------------------------
  # Tool registry: generated descriptor -> MCP tool descriptors
  # ---------------------------------------------------------------------------

  defp tools do
    Smalt.Mcp.Descriptor.capabilities()
    |> Enum.map(fn {id, meta} ->
      %{
        "name" => id,
        "description" => meta.description,
        "inputSchema" => input_schema(id),
        "annotations" => %{
          "readOnlyHint" => true,
          "destructiveHint" => false,
          "idempotentHint" => true,
          "openWorldHint" => false
        }
      }
    end)
  end

  # Minimal, honest input schemas (one per tool).
  defp input_schema("substrate.status"), do: %{"type" => "object", "properties" => %{}}

  defp input_schema("substrate.capabilities"), do: %{"type" => "object", "properties" => %{}}

  defp input_schema("arm.get") do
    %{
      "type" => "object",
      "required" => ["resource_group", "resource_type", "resource_name"],
      "properties" => %{
        "subscription_id" => %{"type" => "string", "default" => default_subscription()},
        "resource_group" => %{"type" => "string"},
        "resource_type" => %{
          "type" => "string",
          "description" => "full type, e.g. Microsoft.Storage/storageAccounts"
        },
        "resource_name" => %{"type" => "string"}
      }
    }
  end

  defp input_schema("cosmos.query") do
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

  defp input_schema("blob.list") do
    %{
      "type" => "object",
      "required" => ["account", "container"],
      "properties" => %{
        "account" => %{"type" => "string"},
        "container" => %{"type" => "string"}
      }
    }
  end

  defp input_schema("sb.peek") do
    %{
      "type" => "object",
      "required" => ["queue"],
      "properties" => %{
        "queue" => %{"type" => "string"},
        "message_count" => %{"type" => "integer", "minimum" => 1, "maximum" => 100}
      }
    }
  end

  defp input_schema("kv.get") do
    %{
      "type" => "object",
      "required" => ["name"],
      "properties" => %{
        "name" => %{"type" => "string"}
      }
    }
  end

  defp input_schema("doctor.summary"), do: %{"type" => "object", "properties" => %{}}

  # ---------------------------------------------------------------------------
  # Dispatch: real substrate modules, reads only
  # ---------------------------------------------------------------------------

  defp dispatch_tool(name, args) do
    cond do
      actuation_attempt?(name) ->
        {:refusal, @actuation_refused_code,
         "refused: #{name} is an actuation tool; the smalt substrate exposes read-only MCP tools only and refuses unreceipted DO by law"}

      match?({:ok, _}, Smalt.Mcp.Descriptor.describe(name)) ->
        invoke(name, args)

      true ->
        {:refusal, @tool_not_found_code,
         "refused: unknown tool #{inspect(name)} (not in the generated read-only descriptor)"}
    end
  end

  # A tool id that is unknown AND carries an actuation verb is reported as an
  # actuation refusal (the stronger, more informative typed verdict); a plain
  # unknown id is TOOL_NOT_FOUND.
  defp actuation_attempt?(name) when is_binary(name) do
    not registered?(name) and actuation_verb?(name)
  end

  defp actuation_attempt?(_), do: true

  defp actuation_verb?(name) when is_binary(name) do
    normalized = String.downcase(name)
    Enum.any?(@actuation_fragments, &String.contains?(normalized, &1))
  end

  defp actuation_verb?(_), do: false

  defp registered?(name), do: match?({:ok, _}, Smalt.Mcp.Descriptor.describe(name))

  defp invoke("substrate.status", _args), do: {:ok, substrate_status()}

  defp invoke("substrate.capabilities", _args), do: {:ok, substrate_capabilities()}

  defp invoke("arm.get", args) do
    with %{"resource_group" => rg, "resource_type" => type, "resource_name" => name} <-
           args,
         sub when is_binary(sub) <- Map.get(args, "subscription_id", default_subscription()),
         res_id =
           String.downcase("/subscriptions/#{sub}/resourceGroups/#{rg}/providers/#{type}/#{name}"),
         {:ok, record} <- Smalt.Store.get(:smalt_resources, res_id) do
      {:ok, record}
    else
      :error ->
        {:refusal, @resource_not_found_code, "refused: resource not found in substrate store"}

      _ ->
        {:refusal, @invalid_params_code,
         "refused: arm.get requires resource_group, resource_type, resource_name"}
    end
  end

  defp invoke("cosmos.query", args) do
    case args do
      %{"db" => db, "coll" => coll} ->
        headers =
          case args["partition_key"] do
            nil -> %{}
            pk -> %{Smalt.DataPlane.PartitionKey.header_name() => partition_key_header(pk)}
          end

        case Smalt.DataPlane.Cosmos.query_docs(db, coll, %{}, headers) do
          {:ok, 200, _headers, body} ->
            {:ok, body}

          {:ok, status, _headers, body} ->
            {:refusal, "COSMOS_ERROR", "cosmos.query returned #{status}: #{inspect(body)}"}

          {:error, :store_not_ready} ->
            {:refusal, "STORE_NOT_READY", "refused: cosmos store tables not initialized"}

          other ->
            {:refusal, @internal_code, "cosmos.query unexpected: #{inspect(other)}"}
        end

      _ ->
        {:refusal, @invalid_params_code, "refused: cosmos.query requires db and coll"}
    end
  end

  defp invoke("blob.list", args) do
    case args do
      %{"account" => account, "container" => container} ->
        prefix = "#{account}/#{container}/"

        blobs =
          Smalt.Store.list_prefix(:smalt_blobs, prefix)
          |> Enum.map(&Smalt.DataPlane.BlobStorage.blob_metadata/1)

        {:ok,
         %{"container" => "#{account}/#{container}", "blobs" => blobs, "count" => length(blobs)}}

      _ ->
        {:refusal, @invalid_params_code, "refused: blob.list requires account and container"}
    end
  end

  defp invoke("sb.peek", args) do
    case args do
      %{"queue" => queue} ->
        case Smalt.Amqp.QueueStore.peek(queue,
               message_count: args["message_count"] || 10
             ) do
          {:ok, messages} ->
            {:ok, %{"queue" => queue, "messages" => messages, "count" => length(messages)}}

          other ->
            {:refusal, "SB_ERROR", "sb.peek unexpected: #{inspect(other)}"}
        end

      _ ->
        {:refusal, @invalid_params_code, "refused: sb.peek requires queue"}
    end
  end

  defp invoke("kv.get", args) do
    case args do
      %{"name" => name} ->
        case Smalt.Store.get(:smalt_vault_keys, name) do
          {:ok, record} ->
            {:ok, public_vault_record(record)}

          :error ->
            {:refusal, @resource_not_found_code,
             "refused: key #{inspect(name)} not found in vault key table"}

          other ->
            {:refusal, @internal_code, "kv.get unexpected: #{inspect(other)}"}
        end

      _ ->
        {:refusal, @invalid_params_code, "refused: kv.get requires name"}
    end
  end

  defp invoke("doctor.summary", _args), do: {:ok, doctor_summary()}

  defp invoke(name, _args),
    do: {:refusal, @tool_not_found_code, "refused: unknown tool #{inspect(name)}"}

  # ---------------------------------------------------------------------------
  # Tool bodies
  # ---------------------------------------------------------------------------

  defp substrate_status do
    %{
      "status" => if(substrate_alive?(), do: "ok", else: "degraded"),
      "otp_app" => "smalt",
      "version" => to_string(Application.spec(:smalt, :vsn) || "0.0.0"),
      "store_alive" => Process.whereis(Smalt.Store) != nil,
      "supervisor_alive" => Process.whereis(Smalt.Supervisor) != nil,
      "mcp_read_only_surface" => true,
      "ports" => %{
        "control_plane" => Smalt.Registry.control_plane_port(),
        "data_plane" => Smalt.Registry.data_plane_port(),
        "amqp" => Smalt.Registry.amqp_port(),
        "event_hubs" => Smalt.Registry.event_hubs_port()
      }
    }
  end

  defp substrate_alive? do
    Process.whereis(Smalt.Store) != nil and Process.whereis(Smalt.Supervisor) != nil
  end

  defp substrate_capabilities do
    types = Smalt.Registry.admitted_resource_types()

    %{
      "admitted_resource_types" => types,
      "admitted_resource_type_count" => length(types),
      "api_versions" =>
        Enum.reduce(types, %{}, fn type, acc ->
          case Smalt.Registry.latest_version(type) do
            nil -> acc
            v -> Map.put(acc, type, v)
          end
        end),
      "shape_bindings" =>
        types
        |> Enum.map(fn type -> {type, Smalt.Registry.shape_for(type)} end)
        |> Enum.reject(fn {_t, s} -> is_nil(s) end)
        |> Map.new(),
      "mcp_tools" => Enum.map(Smalt.Mcp.Descriptor.capabilities(), fn {id, _} -> id end)
    }
  end

  defp doctor_summary do
    children =
      case Process.whereis(Smalt.Supervisor) do
        nil ->
          []

        sup ->
          Supervisor.which_children(sup)
          |> Enum.map(fn {id, pid, _type, _mods} ->
            %{"id" => inspect(id), "pid" => inspect(pid), "alive" => Process.alive?(pid)}
          end)
      end

    %{
      "status" => if(substrate_alive?(), do: "healthy", else: "degraded"),
      "supervisor_children" => children,
      "store_alive" => Process.whereis(Smalt.Store) != nil,
      "cosmos_store_ready" => Smalt.DataPlane.Cosmos.store_ready?(),
      "blob_policy_table_ready" => :ets.info(:smalt_blob_policies) != :undefined,
      "vault_keys_table_ready" => :ets.info(:smalt_vault_keys) != :undefined,
      "sb_queues_table_ready" => :ets.info(:smalt_sb_queues) != :undefined,
      "node_uptime_seconds" => elem(:erlang.statistics(:wall_clock), 1) |> div(1000)
    }
  end

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp default_subscription, do: "00000000-0000-0000-0000-000000000000"

  defp provider_of(type) do
    type |> String.split("/") |> List.first()
  end

  defp partition_key_header(pk), do: pk

  defp public_vault_record(record) do
    record
    |> Map.delete("key_material")
    |> Map.delete("value")
  end

  defp respond(conn, req, result) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(
      200,
      Jason.encode!(%{
        "jsonrpc" => "2.0",
        "id" => req["id"],
        "result" => result
      })
    )
  end

  defp respond_error(conn, req, rpc_code, code, message) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(
      200,
      Jason.encode!(%{
        "jsonrpc" => "2.0",
        "id" => req["id"],
        "error" => %{"code" => rpc_code, "data" => %{"code" => code, "message" => message}}
      })
    )
  end

  defp send_json_rpc_error(conn, status, id, rpc_code, code, message) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(
      status,
      Jason.encode!(%{
        "jsonrpc" => "2.0",
        "id" => id,
        "error" => %{"code" => rpc_code, "data" => %{"code" => code, "message" => message}}
      })
    )
  end

  defp decode_rpc(body) do
    case Jason.decode(body) do
      {:ok, %{"jsonrpc" => "2.0", "method" => m} = req} when is_binary(m) ->
        {:ok, req}

      {:ok, _} ->
        {:error, :invalid_request}

      {:error, _} ->
        {:error, :invalid_json}
    end
  end
end
