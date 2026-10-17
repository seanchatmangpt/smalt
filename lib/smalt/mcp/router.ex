defmodule Smalt.Mcp.Router do
  # Runtime single source for the wire protocol version. The authored source
  # stays the TTL (ema:mcpProtocolVersion); test/mcp_test.exs cross-checks the
  # two so a spec bump cannot drift one side silently.
  @protocol_version "2024-11-05"
  @moduledoc """
  Read-only MCP (JSON-RPC 2.0) tool surface over the smalt substrate for
  coding agents. Hand-written dispatch; the tool metadata comes from the
  generated `Smalt.Mcp.Descriptor` (elixir-mcp-a2a-pack shape, adapted).

  Tools: substrate.status, substrate.capabilities (Registry-derived),
  arm.get, cosmos.query, blob.list, sb.peek, kv.get, doctor.summary.

  READ-ONLY BY LAW: this surface exposes NO actuation tools. The substrate
  refuses unreceipted DO; any tool call for a non-registered (actuation or
  unknown) tool id is refused with a typed error, never dispatched. The
  fail-closed gate is dispatch-local (SHIM-COURT: doc-truth fix per audit
  A26 — the generated `Descriptor.requires_authority?/1` exists but is NOT
  the dispatch gate): `dispatch_tool/2` refuses any unregistered id whose
  name carries an actuation verb fragment (`@actuation_fragments`,
  case-insensitive substring match) with `ACTUATION_REFUSED`, any other
  unregistered id with `TOOL_NOT_FOUND`, and dispatches registered ids only
  after `Smalt.Mcp.Descriptor.describe/1` confirms registration.

  Mount as a Plug (wire for the coordinator):

      {Bandit,
       plug: {Smalt.Mcp.Router, []},
       scheme: :http,
       port: Application.get_env(:smalt, :mcp_port, 9545)}

  Tests exercise this module over `Plug.Test` with real substrate modules
  (no mocks) — see test/mcp_test.exs.

  ## Test seam: `:doctor_supervisor`

  `doctor_summary/0` reads application env `:smalt, :doctor_supervisor` to pick
  which supervisor `Supervisor.which_children/1` observes. Contract:

    * default (env unset or nil): the real `Smalt.Supervisor` — production
      behavior; every deployed path leaves this env unset.
    * test only: a hostile supervisor may be substituted to fuzz
      `sanitize_child_id/1` through the public wire path (real collaborator,
      no mock). The ONLY observable change is the child-id list; nothing else
      in the doctor summary or any other tool reads this env.

  Anti-vacuity: the hostile-supervisor fence (test/mcp_test.exs) seeds a
  sentinel child id unique to that fence and asserts it appears verbatim in
  the response, proving the substitution was actually observed (a seam that
  silently stopped being read would make the fence test the real supervisor
  and still pass).

  ## Typed UNSUPPORTED register: no TLS variant

  The MCP surface is HTTP-only. `config :smalt, :tls, :auto` covers the
  egress (`:8443`) and ARM control-plane (`:9443`/`:9444`) listeners; there
  is NO `Smalt.TLS.bandit_opts/2` variant for the MCP mount, so wire fences
  that assume TLS (e.g. the lens-4 pipelined-burst-under-TLS probe) are
  typed `UNSUPPORTED(tls-variant-absent)` for this surface — recorded here
  rather than silently absent.
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

  # Test-seam accessor (SHIM-COURT): lets the wire-tier verb fence assert its
  # verb list length against the real gate list, so adding a fragment in
  # lib/ without updating the fence is caught. Read-only, no behavior.
  def actuation_fragments, do: @actuation_fragments

  get "/" do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(200, Jason.encode!(%{"service" => "smalt-mcp", "protocol" => "JSON-RPC/2.0"}))
  end

  post "/" do
    with {:ok, body, conn} <- read_body(conn),
         {:ok, req} <- decode_rpc(body) do
      case req do
        # JSON-RPC 2.0: a request without an id (or with "id": null) is a
        # notification — the server MUST NOT send a response. Suppress the
        # envelope entirely: 204, empty body.
        %{"method" => _, "id" => nil} ->
          send_resp(conn, 204, "")

        %{"method" => _} = req when not is_map_key(req, "id") ->
          send_resp(conn, 204, "")

        %{"method" => "initialize"} = req ->
          respond(conn, req, %{
            "protocolVersion" => @protocol_version,
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

        # tools/call without params.name: typed invalid-params, never
        # METHOD_NOT_FOUND (method IS known; the request shape is wrong).
        %{"method" => "tools/call"} = req ->
          respond_error(
            conn,
            req,
            @json_rpc_invalid_params,
            "INVALID_PARAMS",
            "tools/call requires params.name (string)"
          )

        # JSON-RPC batch: not supported, typed error per spec.
        %{"method" => _other} = req ->
          respond_error(conn, req, @json_rpc_method_not_found, "METHOD_NOT_FOUND", req["method"])
      end
    else
      # Plug.read_body/1 caps at 8 MiB by default; a larger body comes back as
      # {:more, ...}. Refuse it as a typed 413 instead of crashing with a
      # CaseClauseError (500).
      {:more, _partial, conn} ->
        send_json_rpc_error(
          conn,
          413,
          nil,
          @json_rpc_invalid_params,
          "PAYLOAD_TOO_LARGE",
          "request body exceeds the JSON-RPC size limit"
        )

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

  # Canonical wire order (capability_id-sorted) is enforced HERE, not inherited
  # from the generated descriptor's map-literal order — so tools/list stays
  # deterministic even if the upstream template canonicalization (lens-7) or
  # the descriptor file itself ever regresses. Order-independence by
  # construction at the wire tier, per the lens-7 ORDER-BY root cause.
  defp tools do
    Smalt.Mcp.Descriptor.capabilities()
    |> Enum.sort_by(fn {id, _meta} -> id end)
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
         "refused: #{inspect(name)} is an actuation tool; the smalt substrate exposes read-only MCP tools only and refuses unreceipted DO by law"}

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
    with %{"resource_group" => rg, "resource_type" => type, "resource_name" => name}
           when is_binary(rg) and is_binary(type) and is_binary(name) <-
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
      %{"db" => db, "coll" => coll} when is_binary(db) and is_binary(coll) ->
        with {:ok, headers} <- partition_key_headers(args["partition_key"]) do
          case Smalt.DataPlane.Cosmos.query_docs(db, coll, %{"query" => "SELECT * FROM c"}, headers) do
            {:ok, 200, _headers, body} ->
              {:ok, body}

            {:ok, status, _headers, body} ->
              {:refusal, "COSMOS_ERROR", "cosmos.query returned #{status}: #{inspect(body)}"}

            {:error, :store_not_ready} ->
              {:refusal, "STORE_NOT_READY", "refused: cosmos store tables not initialized"}

            other ->
              {:refusal, @internal_code, "cosmos.query unexpected: #{inspect(other)}"}
          end
        end

      _ ->
        {:refusal, @invalid_params_code, "refused: cosmos.query requires db and coll"}
    end
  end

  defp invoke("blob.list", args) do
    case args do
      %{"account" => account, "container" => container}
      when is_binary(account) and is_binary(container) ->
        prefix = "#{account}/#{container}/"

        # Keys-only-class scan (blob_storage.list_blobs_xml pattern): walk
        # KEYS via Store.prefix_keys/2 and fetch+project one record at a
        # time, so the full content of every blob is never held in a single
        # intermediate list. Behavioral no-op: same keys, same order,
        # churn-safe skip preserved (deleted mid-walk entries drop out).
        blobs =
          :smalt_blobs
          |> Smalt.Store.prefix_keys(prefix)
          |> Enum.flat_map(fn key ->
            case Smalt.Store.get(:smalt_blobs, key) do
              {:ok, blob} -> [Smalt.DataPlane.BlobStorage.blob_metadata(blob)]
              _ -> []
            end
          end)

        {:ok,
         %{"container" => "#{account}/#{container}", "blobs" => blobs, "count" => length(blobs)}}

      _ ->
        {:refusal, @invalid_params_code, "refused: blob.list requires account and container"}
    end
  end

  defp invoke("sb.peek", args) do
    case args do
      %{"queue" => queue} when is_binary(queue) ->
        with {:ok, mc} <- message_count_arg(args["message_count"]),
             {:ok, messages} <-
               Smalt.Amqp.QueueStore.peek(queue, message_count: mc) do
          {:ok, %{"queue" => queue, "messages" => messages, "count" => length(messages)}}
        else
          :error ->
            {:refusal, @invalid_params_code,
             "refused: sb.peek message_count must be an integer between 1 and 100"}

          other ->
            {:refusal, "SB_ERROR", "sb.peek unexpected: #{inspect(other)}"}
        end

      _ ->
        {:refusal, @invalid_params_code, "refused: sb.peek requires queue"}
    end
  end

  defp invoke("kv.get", args) do
    case args do
      %{"name" => name} when is_binary(name) ->
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

  # partition_key is optional (nil = no header) but MUST be binary when present:
  # the previous `_other -> %{}` silent-coercion treated integer/list/map keys
  # as absent, yielding a full-table scan instead of typed INVALID_PARAMS.
  # (Kept AFTER the invoke/2 clause group so invoke/2 stays contiguous — see
  # the message_count_arg/1 note below.)
  defp partition_key_headers(nil), do: {:ok, %{}}

  defp partition_key_headers(pk) when is_binary(pk),
    do: {:ok, %{Smalt.DataPlane.PartitionKey.header_name() => partition_key_header(pk)}}

  defp partition_key_headers(_other),
    do: {:refusal, @invalid_params_code, "refused: partition_key must be a string"}

  # message_count is schema-bounded (integer 1..100): out-of-schema values are
  # refused at dispatch, never forwarded to the substrate's silent clamp.
  # (Kept AFTER the invoke/2 clause group so invoke/2 stays contiguous — an
  # interleaved defp here made invoke/2 non-contiguous and warned under
  # `mix compile --warnings-as-errors`, which is the ggen_igniter.sync
  # terminal verify gate.)
  defp message_count_arg(nil), do: {:ok, 10}

  defp message_count_arg(n) when is_integer(n) and n >= 1 and n <= 100, do: {:ok, n}
  defp message_count_arg(_), do: :error

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
      "mcp_tools" =>
        Smalt.Mcp.Descriptor.capabilities()
        |> Enum.map(fn {id, _} -> id end)
        |> Enum.sort()
    }
  end

  defp doctor_summary do
    # Test seam (lens-4): the supervisor observed defaults to the real one; a
    # hostile-id real supervisor can be substituted to fuzz sanitize_child_id/1
    # through the public wire path. No other behavior changes.
    sup = Application.get_env(:smalt, :doctor_supervisor, Smalt.Supervisor)

    children =
      case sup do
        nil ->
          []

        sup ->
          Supervisor.which_children(sup)
          |> Enum.map(fn {id, pid, _type, _mods} ->
            %{
              "id" => sanitize_child_id(id),
              "pid" => inspect(pid),
              "alive" => Process.alive?(pid)
            }
          end)
      end

    %{
      "status" => if(substrate_alive?(), do: "healthy", else: "degraded"),
      "supervisor_children" => children,
      "store_alive" => Process.whereis(Smalt.Store) != nil,
      "cosmos_store_ready" => Smalt.DataPlane.Cosmos.store_ready?(),
      "blob_policy_table_ready" => :ets.info(:smalt_blob_policy) != :undefined,
      "vault_keys_table_ready" => :ets.info(:smalt_vault_keys) != :undefined,
      "sb_queues_table_ready" => :ets.info(:smalt_sb_queues) != :undefined,
      "node_uptime_seconds" => elem(:erlang.statistics(:wall_clock), 1) |> div(1000)
    }
  end

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp default_subscription, do: "00000000-0000-0000-0000-000000000000"

  # Supervisor child ids render as their atom form where possible; compound
  # ids (e.g. {Bandit, #Reference<...>}) keep the module name but collapse
  # session-local reference tokens so no ephemeral internals cross the wire.
  defp sanitize_child_id(id) when is_atom(id), do: inspect(id)

  defp sanitize_child_id(id) do
    String.replace(inspect(id), ~r/#Reference<[^>]+>/, "#Reference")
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
