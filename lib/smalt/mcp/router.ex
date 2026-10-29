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
  arm.get, cosmos.query, blob.list, sb.peek, kv.get, doctor.summary, and the
  v26.10.19 window-capability reads: kv.deletedkeys.list,
  policy.exemptions.list, eg.dlq.list, lro.operations.list, cluster.status,
  health.readiness, plus the v26.10.20 window reads: kv.certificates.list,
  sb.topics.list, cosmos.stats, policy.remediations.list,
  appconfig.snapshots.list, atlas.lineage.get, plus the v26.10.21 window reads:
  policy.locks.list, appconfig.snapshots.kv, cosmos.changefeed.peek,
  sb.topics.subscriptions, eh.consumergroups.list, certificates.get, and the
  v26.10.22 wave-4 reads: kv.deletedsecrets.list, policy.setdefinitions.list,
  sb.rules.list, cosmos.uniquekeys.get.

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
  # Adaptive health probes (envelope Phase 4): zero-auth readiness/liveness.
  # Readiness degrades only on structural failure, never on load.
  plug(Smalt.HealthPlug)
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

  # T-03 (v26.10.28): Event Grid read tools.
  defp input_schema("eventgrid.topics.list") do
    %{
      "type" => "object",
      "properties" => %{
        "subscription_id" => %{"type" => "string", "default" => default_subscription()},
        "resource_group" => %{"type" => "string"}
      }
    }
  end

  defp input_schema("eventgrid.subscriptions.list") do
    %{
      "type" => "object",
      "properties" => %{
        "subscription_id" => %{"type" => "string", "default" => default_subscription()},
        "topic" => %{"type" => "string", "description" => "optional topic or system topic name"}
      }
    }
  end

  defp input_schema("eventgrid.events.recent") do
    %{"type" => "object", "properties" => %{}}
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

  defp input_schema("kv.deletedkeys.list"), do: %{"type" => "object", "properties" => %{}}

  defp input_schema("policy.exemptions.list") do
    %{
      "type" => "object",
      "required" => ["scope"],
      "properties" => %{
        "scope" => %{
          "type" => "string",
          "description" =>
            "scope prefix, e.g. /subscriptions/<sub> or /subscriptions/<sub>/resourceGroups/<rg>"
        }
      }
    }
  end

  defp input_schema("eg.dlq.list") do
    %{
      "type" => "object",
      "properties" => %{
        "account" => %{"type" => "string", "default" => "eg-dlq"},
        "subscriber" => %{
          "type" => "string",
          "description" => "optional subscriber name; narrows to container eg-dlq-<subscriber>"
        }
      }
    }
  end

  defp input_schema("lro.operations.list") do
    %{
      "type" => "object",
      "properties" => %{
        "subscription" => %{
          "type" => "string",
          "description" => "optional subscription id filter (Scopes to /subscriptions/<id>/operations)"
        }
      }
    }
  end

  defp input_schema("cluster.status"), do: %{"type" => "object", "properties" => %{}}

  defp input_schema("health.readiness"), do: %{"type" => "object", "properties" => %{}}

  defp input_schema("kv.certificates.list"), do: %{"type" => "object", "properties" => %{}}

  defp input_schema("sb.topics.list") do
    %{
      "type" => "object",
      "properties" => %{
        "namespace" => %{
          "type" => "string",
          "description" => "optional Service Bus namespace name filter"
        }
      }
    }
  end

  defp input_schema("cosmos.stats"), do: %{"type" => "object", "properties" => %{}}

  defp input_schema("policy.remediations.list"), do: %{"type" => "object", "properties" => %{}}

  defp input_schema("appconfig.snapshots.list"), do: %{"type" => "object", "properties" => %{}}

  defp input_schema("policy.locks.list") do
    %{
      "type" => "object",
      "required" => ["scope"],
      "properties" => %{
        "scope" => %{
          "type" => "string",
          "description" =>
            "scope prefix, e.g. /subscriptions/<sub> or /subscriptions/<sub>/resourceGroups/<rg>"
        }
      }
    }
  end

  defp input_schema("appconfig.snapshots.kv") do
    %{
      "type" => "object",
      "required" => ["name"],
      "properties" => %{
        "name" => %{"type" => "string", "description" => "snapshot name"}
      }
    }
  end

  defp input_schema("cosmos.changefeed.peek") do
    %{
      "type" => "object",
      "required" => ["db", "coll"],
      "properties" => %{
        "db" => %{"type" => "string"},
        "coll" => %{"type" => "string"}
      }
    }
  end

  defp input_schema("sb.topics.subscriptions") do
    %{
      "type" => "object",
      "required" => ["topic"],
      "properties" => %{
        "topic" => %{"type" => "string", "description" => "topic name"},
        "namespace" => %{
          "type" => "string",
          "description" => "optional Service Bus namespace name filter"
        }
      }
    }
  end

  defp input_schema("eh.consumergroups.list") do
    %{
      "type" => "object",
      "required" => ["hub"],
      "properties" => %{
        "hub" => %{"type" => "string", "description" => "Event Hub name"}
      }
    }
  end

  defp input_schema("certificates.get") do
    %{
      "type" => "object",
      "required" => ["name"],
      "properties" => %{
        "name" => %{"type" => "string"}
      }
    }
  end

  defp input_schema("atlas.lineage.get") do
    %{
      "type" => "object",
      "required" => ["guid"],
      "properties" => %{
        "guid" => %{"type" => "string"},
        "direction" => %{
          "type" => "string",
          "enum" => ["input", "output", "both"],
          "default" => "both"
        },
        "depth" => %{"type" => "integer", "minimum" => 1, "maximum" => 10, "default" => 1}
      }
    }
  end

  # -- v26.10.22 ERRC RAISE lane: wave-4 read tools (27-30) -------------------

  defp input_schema("kv.deletedsecrets.list"), do: %{"type" => "object", "properties" => %{}}

  defp input_schema("policy.setdefinitions.list") do
    %{
      "type" => "object",
      "required" => ["subscription_id"],
      "properties" => %{
        "subscription_id" => %{"type" => "string"}
      }
    }
  end

  defp input_schema("sb.rules.list") do
    %{
      "type" => "object",
      "required" => ["topic", "subscription"],
      "properties" => %{
        "topic" => %{"type" => "string", "description" => "topic name"},
        "subscription" => %{"type" => "string", "description" => "subscription name"},
        "namespace" => %{
          "type" => "string",
          "description" => "optional Service Bus namespace name filter"
        }
      }
    }
  end

  defp input_schema("cosmos.uniquekeys.get") do
    %{
      "type" => "object",
      "required" => ["db", "coll"],
      "properties" => %{
        "db" => %{"type" => "string"},
        "coll" => %{"type" => "string"}
      }
    }
  end

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
          case Smalt.DataPlane.Cosmos.query_docs(
                 db,
                 coll,
                 %{"query" => "SELECT * FROM c"},
                 headers
               ) do
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

  # -- v26.10.19 window-capability read tools (ERRC RAISE lane) --------------

  defp invoke("kv.deletedkeys.list", _args) do
    case Smalt.DataPlane.KeyVaultActions.list_deleted_keys() do
      {:ok, 200, %{"value" => keys}} ->
        {:ok, %{"deleted_keys" => keys, "count" => length(keys)}}

      {:ok, status, body} ->
        {:refusal, "KV_ERROR", "kv.deletedkeys.list returned #{status}: #{inspect(body)}"}

      other ->
        {:refusal, @internal_code, "kv.deletedkeys.list unexpected: #{inspect(other)}"}
    end
  end

  defp invoke("policy.exemptions.list", args) do
    case args do
      %{"scope" => scope} when is_binary(scope) ->
        exemptions = Smalt.Policy.list_policy_exemptions(scope)

        {:ok, %{"scope" => scope, "value" => exemptions, "count" => length(exemptions)}}

      _ ->
        {:refusal, @invalid_params_code, "refused: policy.exemptions.list requires scope"}
    end
  end

  defp invoke("eg.dlq.list", args) do
    account = args["account"]

    if account != nil and not is_binary(account) do
      {:refusal, @invalid_params_code, "refused: eg.dlq.list account must be a string"}
    else
      account = account || "eg-dlq"

      prefix =
        case args["subscriber"] do
          sub when is_binary(sub) -> "#{account}/eg-dlq-#{sub}/"
          nil -> "#{account}/"
          _ ->
            {:refusal, @invalid_params_code,
             "refused: eg.dlq.list subscriber must be a string"}
        end

      if is_binary(prefix) do
        blobs =
          :smalt_blobs
          |> Smalt.Store.prefix_keys(prefix)
          |> Enum.flat_map(fn key ->
            case Smalt.Store.get(:smalt_blobs, key) do
              {:ok, blob} -> [dlq_blob_row(blob)]
              _ -> []
            end
          end)

        {:ok, %{"prefix" => prefix, "dead_lettered" => blobs, "count" => length(blobs)}}
      else
        prefix
      end
    end
  end

  defp invoke("lro.operations.list", args) do
    sub = args["subscription"]

    if sub != nil and not is_binary(sub) do
      {:refusal, @invalid_params_code, "refused: lro.operations.list subscription must be a string"}
    else
      ops =
        :smalt_operations
        |> Smalt.Store.list()
        |> Enum.filter(fn
          %{"id" => "/subscriptions/" <> rest} ->
            case sub do
              nil -> true
              ^sub -> true
              _ -> String.starts_with?(rest, "#{sub}/")
            end

          _ ->
            false
        end)
        |> Enum.sort_by(& &1["id"])

      {:ok, %{"operations" => ops, "count" => length(ops)}}
    end
  end

  defp invoke("cluster.status", _args), do: {:ok, Smalt.Cluster.cluster_status()}

  defp invoke("health.readiness", _args),
    do: {:ok, Smalt.Health.to_json_map(Smalt.Health.readiness())}

  # -- v26.10.20 ERRC RAISE lane: window-capability read tools (15-20) --------

  defp invoke("kv.certificates.list", _args) do
    case Smalt.DataPlane.Certificates.list() do
      {:ok, 200, %{"value" => certs}} ->
        {:ok, %{"certificates" => certs, "count" => length(certs)}}

      other ->
        {:refusal, @internal_code, "kv.certificates.list unexpected: #{inspect(other)}"}
    end
  end

  defp invoke("sb.topics.list", args) do
    ns = args["namespace"]

    if ns != nil and not is_binary(ns) do
      {:refusal, @invalid_params_code, "refused: sb.topics.list namespace must be a string"}
    else
      topics =
        :smalt_resources
        |> Smalt.Store.list()
        |> Enum.filter(&(&1["type"] == "Microsoft.ServiceBus/namespaces/topics"))
        |> Enum.filter(fn rec ->
          case ns do
            nil -> true
            ^ns -> true
            _ -> String.contains?(rec["id"] || "", "/namespaces/#{ns}/topics/")
          end
        end)
        |> Enum.sort_by(&String.downcase(&1["id"] || ""))
        |> Enum.map(&%{"id" => &1["id"], "name" => &1["name"], "properties" => &1["properties"]})

      {:ok, %{"topics" => topics, "count" => length(topics)}}
    end
  end

  defp invoke("cosmos.stats", _args) do
    if :ets.info(:smalt_cosmos_docs) == :undefined do
      {:refusal, "STORE_NOT_READY", "refused: cosmos store tables not initialized"}
    else
      # pk_meta keys are tuples ({0,db} / {1,db,coll}); term order puts tuples
      # below binaries, so the binary-key Store scan (prefix_keys) cannot see
      # them — enumerate the table directly, same discipline as cosmos'
      # meta_records/1 (cosmos.ex:368).
      containers =
        :smalt_cosmos_pk_meta
        |> :ets.tab2list()
        |> Enum.filter(fn
          {{1, _db, _coll}, _} -> true
          _ -> false
        end)
        |> Enum.map(fn {{1, db, coll}, _} -> {db, coll} end)
        |> Enum.map(fn {db, coll} ->
          count =
            :smalt_cosmos_docs
            |> Smalt.Store.prefix_keys("#{db}/#{coll}/")
            |> Enum.count()

          %{"db" => db, "coll" => coll, "documents" => count}
        end)
        |> Enum.sort_by(&{&1["db"], &1["coll"]})

      total = Enum.sum(Enum.map(containers, & &1["documents"]))

      {:ok,
       %{
         "containers" => containers,
         "container_count" => length(containers),
         "document_count" => total
       }}
    end
  end

  defp invoke("policy.remediations.list", _args) do
    remediations =
      Smalt.Enclave.Remediations.table()
      |> Enum.sort_by(fn {code, _} -> code end)
      |> Enum.map(fn {code, command} ->
        %{"code" => code, "command" => command}
      end)

    {:ok,
     %{
       "remediations" => remediations,
       "count" => length(remediations),
       "severities" => ["BLOCKING_GATE", "ADVISORY"]
     }}
  end

  defp invoke("appconfig.snapshots.list", _args) do
    snapshots = Smalt.DataPlane.AppConfigSnapshots.list()

    {:ok, %{"snapshots" => snapshots, "count" => length(snapshots)}}
  end

  # T-03 (v26.10.28): Event Grid read tools — registry scans over the ARM
  # store (same source arm.get reads) and the event store, all read-only.
  defp invoke("eventgrid.topics.list", args) do
    sub = Map.get(args, "subscription_id", default_subscription())

    rows =
      eg_scan(String.downcase("/subscriptions/#{sub}/"), args["resource_group"])
      |> Enum.filter(&eg_id_matches?(&1, ["/providers/microsoft.eventgrid/topics/", "/providers/microsoft.eventgrid/systemtopics/"]))
      |> Enum.take(100)

    {:ok, %{"topics" => rows, "count" => length(rows)}}
  end

  defp invoke("eventgrid.subscriptions.list", args) do
    sub = Map.get(args, "subscription_id", default_subscription())

    rows =
      eg_scan(String.downcase("/subscriptions/#{sub}/"), nil)
      |> Enum.filter(&eg_id_matches?(&1, ["/eventsubscriptions/"]))
      |> then(fn rs ->
        case args["topic"] do
          t when is_binary(t) and t != "" ->
            marker = "/#{String.downcase(t)}/"
            Enum.filter(rs, fn r -> String.contains?(eg_id(r), marker) end)

          _ ->
            rs
        end
      end)
      |> Enum.take(100)

    {:ok, %{"subscriptions" => rows, "count" => length(rows)}}
  end

  defp invoke("eventgrid.events.recent", _args) do
    rows =
      case :ets.info(:smalt_event_messages) do
        :undefined -> []
        _ -> Smalt.Store.list_prefix(:smalt_event_messages, "")
      end
      |> Enum.filter(&is_map/1)
      |> Enum.take(-25)
      |> Enum.map(fn r ->
        r
        |> Map.take(["id", "eventType", "eventTime", "subject", "topic", "type", "data"])
        |> Map.put_new("raw_kind", if(is_map(r), do: "map", else: "other"))
      end)

    {:ok, %{"events" => rows, "count" => length(rows)}}
  end

  defp eg_scan(sub_prefix, resource_group) do
    prefix =
      case resource_group do
        rg when is_binary(rg) and rg != "" ->
          sub_prefix <> "resourcegroups/#{String.downcase(rg)}/"

        _ ->
          sub_prefix
      end

    case :ets.info(:smalt_resources) do
      :undefined -> []
      _ -> Smalt.Store.list_prefix(:smalt_resources, prefix) |> Enum.filter(&is_map/1)
    end
  end

  defp eg_id(row), do: String.downcase(to_string(Map.get(row, "id", "")))

  defp eg_id_matches?(row, markers),
    do: Enum.any?(markers, &String.contains?(eg_id(row), &1))

  defp invoke("atlas.lineage.get", args) do
    case args do
      %{"guid" => guid} when is_binary(guid) ->
        direction = args["direction"] || "both"
        depth = args["depth"] || 1

        cond do
          direction not in ["input", "output", "both"] ->
            {:refusal, @invalid_params_code,
             "refused: atlas.lineage.get direction must be one of input, output, both"}

          not is_integer(depth) or depth < 1 or depth > 10 ->
            {:refusal, @invalid_params_code,
             "refused: atlas.lineage.get depth must be an integer between 1 and 10"}

          true ->
            case Smalt.DataPlane.Purview.lineage(guid, direction, depth) do
              {:ok, 200, body} ->
                {:ok, body}

              {:error, 400, %{"error" => %{"code" => code, "message" => message}}} ->
                {:refusal, code, "atlas.lineage.get: #{message}"}

              other ->
                {:refusal, @internal_code, "atlas.lineage.get unexpected: #{inspect(other)}"}
            end
        end

      _ ->
        {:refusal, @invalid_params_code, "refused: atlas.lineage.get requires guid"}
    end
  end

  # -- v26.10.21 ERRC RAISE lane: window-capability read tools (21-26) --------
  defp invoke("policy.locks.list", args) do
    case args do
      %{"scope" => scope} when is_binary(scope) ->
        locks = Smalt.Policy.list_locks(scope)

        {:ok, %{"scope" => scope, "value" => locks, "count" => length(locks)}}

      _ ->
        {:refusal, @invalid_params_code, "refused: policy.locks.list requires scope"}
    end
  end

  defp invoke("appconfig.snapshots.kv", args) do
    case args do
      %{"name" => name} when is_binary(name) ->
        case Smalt.DataPlane.AppConfigSnapshots.kv_view(name) do
          {:ok, items} ->
            {:ok, %{"name" => name, "items" => items, "count" => length(items)}}

          {:error, {code, message}} ->
            {:refusal, code, "appconfig.snapshots.kv: #{message}"}

          other ->
            {:refusal, @internal_code, "appconfig.snapshots.kv unexpected: #{inspect(other)}"}
        end

      _ ->
        {:refusal, @invalid_params_code, "refused: appconfig.snapshots.kv requires name"}
    end
  end

  # Read-only PEEK over the Cosmos change feed: counts docs newer than the
  # persisted per-container cursor ({2, db, coll} in :smalt_cosmos_pk_meta)
  # WITHOUT advancing it — the wire `change_feed/3` advances the cursor as a
  # side effect, so the MCP read surface cannot call it (read-only by law).
  # Cursor semantics mirrored from Cosmos.do_change_feed/2 (ts boundary +
  # seen-etag pins); see cf_is_new? there. Cursor-record absence = fresh feed
  # (everything pending), same as Cosmos.cf_cursor/1.
  @cf_cursor_key_index 2

  defp invoke("cosmos.changefeed.peek", args) do
    case args do
      %{"db" => db, "coll" => coll} when is_binary(db) and is_binary(coll) ->
        if :ets.info(:smalt_cosmos_docs) == :undefined or
             :ets.info(:smalt_cosmos_pk_meta) == :undefined do
          {:refusal, "STORE_NOT_READY", "refused: cosmos store tables not initialized"}
        else
          cursor_key = {@cf_cursor_key_index, db, coll}
          cursor = cf_cursor_read(cursor_key)

          pending =
            :smalt_cosmos_docs
            |> Smalt.Store.list_prefix("#{db}/#{coll}/")
            |> Enum.filter(fn doc -> cf_doc_new?(doc, cursor) end)
            |> Enum.sort_by(&{&1["_ts"] || 0, &1["id"]})

          {:ok,
           %{
             "db" => db,
             "coll" => coll,
             "pending" => pending,
             "count" => length(pending),
             "cursor_advanced" => false
           }}
        end

      _ ->
        {:refusal, @invalid_params_code, "refused: cosmos.changefeed.peek requires db and coll"}
    end
  end

  defp invoke("sb.topics.subscriptions", args) do
    case args do
      %{"topic" => topic} when is_binary(topic) ->
        ns = args["namespace"]

        if ns != nil and not is_binary(ns) do
          {:refusal, @invalid_params_code,
           "refused: sb.topics.subscriptions namespace must be a string"}
        else
          subs =
            :smalt_resources
            |> Smalt.Store.list()
            |> Enum.filter(&(&1["type"] == "Microsoft.ServiceBus/namespaces/topics/subscriptions"))
            |> Enum.filter(fn rec ->
              id = rec["id"] || ""

              String.contains?(id, "/topics/#{topic}/subscriptions/") and
                case ns do
                  nil -> true
                  _ -> String.contains?(id, "/namespaces/#{ns}/topics/")
                end
            end)
            |> Enum.sort_by(&String.downcase(&1["id"] || ""))
            |> Enum.map(&%{"id" => &1["id"], "name" => &1["name"], "properties" => &1["properties"]})

          {:ok, %{"topic" => topic, "subscriptions" => subs, "count" => length(subs)}}
        end

      _ ->
        {:refusal, @invalid_params_code, "refused: sb.topics.subscriptions requires topic"}
    end
  end

  defp invoke("eh.consumergroups.list", args) do
    case args do
      %{"hub" => hub} when is_binary(hub) ->
        groups = Smalt.Messaging.EventHubs.list_consumer_groups(hub)

        {:ok, %{"hub" => hub, "consumer_groups" => groups, "count" => length(groups)}}

      _ ->
        {:refusal, @invalid_params_code, "refused: eh.consumergroups.list requires hub"}
    end
  end

  defp invoke("certificates.get", args) do
    case args do
      %{"name" => name} when is_binary(name) ->
        case Smalt.DataPlane.Certificates.get(name) do
          {:ok, 200, record} ->
            # Attributes only, matching the list projection: never the base64
            # DER body, private-key material, or stored request headers.
            {:ok,
             %{
               "id" => record["id"],
               "name" => record["name"],
               "attributes" => record["attributes"]
             }}

          {:error, 404, %{"error" => %{"code" => code, "message" => message}}} ->
            {:refusal, code, "certificates.get: #{message}"}

          other ->
            {:refusal, @internal_code, "certificates.get unexpected: #{inspect(other)}"}
        end

      _ ->
        {:refusal, @invalid_params_code, "refused: certificates.get requires name"}
    end
  end

  # -- v26.10.22 ERRC RAISE lane: wave-4 read tools (27-30) -------------------

  defp invoke("kv.deletedsecrets.list", _args) do
    case Smalt.DataPlane.KeyVaultActions.list_deleted_secrets() do
      {:ok, 200, %{"value" => secrets}} ->
        {:ok, %{"deleted_secrets" => secrets, "count" => length(secrets)}}

      {:ok, status, body} ->
        {:refusal, "KV_ERROR", "kv.deletedsecrets.list returned #{status}: #{inspect(body)}"}

      other ->
        {:refusal, @internal_code, "kv.deletedsecrets.list unexpected: #{inspect(other)}"}
    end
  end

  defp invoke("policy.setdefinitions.list", args) do
    case args do
      %{"subscription_id" => sub} when is_binary(sub) ->
        defs = Smalt.Policy.list_policy_set_definitions(sub)

        {:ok,
         %{
           "subscription_id" => sub,
           "value" => defs,
           "count" => length(defs)
         }}

      _ ->
        {:refusal, @invalid_params_code, "refused: policy.setdefinitions.list requires subscription_id"}
    end
  end

  defp invoke("sb.rules.list", args) do
    case args do
      %{"topic" => topic, "subscription" => sub} when is_binary(topic) and is_binary(sub) ->
        ns = args["namespace"]

        if ns != nil and not is_binary(ns) do
          {:refusal, @invalid_params_code, "refused: sb.rules.list namespace must be a string"}
        else
          # Rules live in :smalt_sb_rules keyed by the downcased full ARM rule
          # scope ("<base>/namespaces/<ns>/topics/<topic>/subscriptions/<sub>/rules/<rule>"),
          # the same key contract Smalt.SbRules.fan_out/4 reads. Suffix
          # contains-match, so any resource-group/subscription base works.
          suffix = "/topics/#{topic}/subscriptions/#{sub}/rules/"

          rules =
            :smalt_sb_rules
            |> Smalt.Store.keys()
            |> Enum.filter(fn key -> is_binary(key) end)
            |> Enum.filter(fn key ->
              String.contains?(key, String.downcase(suffix)) and
                case ns do
                  nil -> true
                  _ -> String.contains?(key, "/namespaces/#{ns}/topics/")
                end
            end)
            |> Enum.sort()
            |> Enum.flat_map(fn key ->
              case Smalt.Store.get(:smalt_sb_rules, key) do
                {:ok, rec} -> [Map.put(rec, "name", key |> String.split("/") |> List.last())]
                _ -> []
              end
            end)

          {:ok,
           %{
             "topic" => topic,
             "subscription" => sub,
             "rules" => rules,
             "count" => length(rules)
           }}
        end

      _ ->
        {:refusal, @invalid_params_code, "refused: sb.rules.list requires topic and subscription"}
    end
  end

  defp invoke("cosmos.uniquekeys.get", args) do
    case args do
      %{"db" => db, "coll" => coll} when is_binary(db) and is_binary(coll) ->
        if :ets.info(:smalt_cosmos_pk_meta) == :undefined do
          {:refusal, "STORE_NOT_READY", "refused: cosmos store tables not initialized"}
        else
          # The {1, db, coll} container record carries the uniqueKeyPolicy set
          # at create (Cosmos.create_container). Direct ETS read — tuple key,
          # invisible to the binary-key Store scan (same discipline as
          # cosmos.stats). A missing container is typed 404, never an empty ok.
          case :ets.lookup(:smalt_cosmos_pk_meta, {1, db, coll}) do
            [{_, record}] ->
              keys = record["uniqueKeyPolicy"] || []

              {:ok,
               %{
                 "db" => db,
                 "coll" => coll,
                 "uniqueKeyPolicy" => %{"uniqueKeys" => keys}
               }}

            [] ->
              {:refusal, @resource_not_found_code,
               "refused: container #{inspect(db)}/#{inspect(coll)} not found"}

            other ->
              {:refusal, @internal_code, "cosmos.uniquekeys.get unexpected: #{inspect(other)}"}
          end
        end

      _ ->
        {:refusal, @invalid_params_code, "refused: cosmos.uniquekeys.get requires db and coll"}
    end
  end

  defp invoke(name, _args),
    do: {:refusal, @tool_not_found_code, "refused: unknown tool #{inspect(name)}"}

  # Kept AFTER the invoke/2 clause group (contiguity — see message_count_arg
  # note above). Read-only mirror of Cosmos.cf_cursor/1 + cf_is_new?/2 (same
  # ts-boundary + seen-etag semantics, cursor record NEVER advanced here).
  defp cf_cursor_read(cursor_key) do
    case :ets.lookup(:smalt_cosmos_pk_meta, cursor_key) do
      [{^cursor_key, %{"ts" => ts, "seen" => seen}}]
      when is_integer(ts) and is_map(seen) ->
        %{"ts" => ts, "seen" => seen}

      _ ->
        %{"ts" => 0, "seen" => %{}}
    end
  end

  defp cf_doc_new?(doc, cursor) do
    ts = doc["_ts"] || 0

    ts > cursor["ts"] or
      (ts == cursor["ts"] and cursor["seen"][doc["id"]] != doc["_etag"])
  end

  # Kept AFTER the invoke/2 clause group (contiguity — see message_count_arg
  # note above). DLQ rows are CONTENT-FREE and header-free: the stored blob
  # record keeps the original PUT request headers, which carry the caller's
  # Authorization bearer — a read-only surface must never project credential
  # material across the wire. Only blob-identity + x-ms-meta-* ride the MCP
  # response.
  defp dlq_blob_row(blob) do
    metadata = Smalt.DataPlane.BlobStorage.blob_metadata(blob)

    meta =
      metadata
      |> Map.get("headers", %{})
      |> Enum.filter(fn {k, _v} -> is_binary(k) and String.starts_with?(k, "x-ms-meta-") end)
      |> Map.new()

    metadata
    |> Map.drop(["headers"])
    |> Map.put("metadata", meta)
  end

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
          flatten_children(sup, 0)
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

  # AZB-09: the app tree is partitioned into plane supervisors (Data/Control/
  # Integration/Identity), so leaf services like Smalt.Store live one level
  # below the root. Flatten the plane subtrees (bounded depth) so the summary
  # reports every service, annotating each nested child with its plane. Only
  # :supervisor-typed children are descended into (a :worker pid is never a
  # supervisor, so the hostile-id fuzz supervisor's Task children are never
  # signalled), and the descent is exit-guarded: a dead or non-supervisor
  # subtree degrades to that plane's own row, never a crash.
  @doctor_flatten_depth 3

  defp flatten_children(sup, depth) when depth >= @doctor_flatten_depth do
    Enum.map(Supervisor.which_children(sup), &child_row(&1, nil))
  end

  defp flatten_children(sup, depth) do
    Supervisor.which_children(sup)
    |> Enum.flat_map(fn {id, pid, type, _mods} ->
      row = child_row({id, pid, type, nil}, nil)

      nested =
        if type == :supervisor and is_pid(pid) and pid != :undefined and Process.alive?(pid) do
          try do
            plane = sanitize_child_id(id)
            flatten_children(pid, depth + 1) |> Enum.map(&put_plane(&1, plane))
          catch
            _class, _reason -> []
          end
        else
          []
        end

      [row | nested]
    end)
  end

  defp child_row({id, pid, _type, _mods}, plane) do
    row = %{
      "id" => sanitize_child_id(id),
      "pid" => inspect(pid),
      "alive" => is_pid(pid) and Process.alive?(pid)
    }

    if plane, do: Map.put(row, "plane", plane), else: row
  end

  defp put_plane(%{} = row, plane), do: Map.put(row, "plane", plane)
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
