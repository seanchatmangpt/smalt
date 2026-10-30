defmodule Smalt.Mcp.Router do
  # Runtime single source for the wire protocol version. The authored source
  # stays the TTL (ema:mcpProtocolVersion); the internal court
  # (test/internal/expl8r_court_test.exs) cross-checks the two so a spec bump
  # cannot drift one side silently.
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
  sb.rules.list, cosmos.uniquekeys.get, the v26.10.22 wave-5 reads:
  cosmos.changefeed.cursor, eh.geo-dr.aliases, and the v26.10.22 wave-6 reads:
  kv.rotationpolicy.get, dns.zones.list, eg.schemaregistry.groups,
  monitor.alerts.list, cosmos.ttl.effective (37 tools total; the
  TTL-vs-descriptor drift fence and the per-tool dispatchability court live in
  test/internal/expl8r_court_test.exs).

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
  (no mocks) — see test/internal/expl8r_court_test.exs (the
  test/mcp_test.exs cited here previously was deleted in the 64f6099
  clean-room reset and never re-authored; its claimed fences — hostile
  supervisor, actuation-verb gate, TTL-vs-descriptor cross-check — are
  re-authored there).

  ## Test seam: `:doctor_supervisor`

  `doctor_summary/0` reads application env `:smalt, :doctor_supervisor` to pick
  which supervisor `Supervisor.which_children/1` observes. Contract:

    * default (env unset or nil): the real `Smalt.Supervisor` — production
      behavior; every deployed path leaves this env unset.
    * test only: a hostile supervisor may be substituted to fuzz
      `sanitize_child_id/1` through the public wire path (real collaborator,
      no mock). The ONLY observable change is the child-id list; nothing else
      in the doctor summary or any other tool reads this env.

  Anti-vacuity: the hostile-supervisor fence (expl8r_court_test.exs,
  "hostile :doctor_supervisor seam is read over the wire") seeds a
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
  # BK-21 (v26.10.21): the MCP plane previously served no CORS face at all
  # (OPTIONS / → 404, no allow headers) — the KD-15 mcp leg's transport gap.
  # Same static CORSPlug face as the 8443 KV precedent, gated on loopback
  # origin (Smalt.EgressRouter.loopback_origin?/1 — one law, two mounts).
  # Preflights (Origin + Access-Control-Request-Method) are answered and
  # halted; actual requests with an allowed Origin get the allow headers
  # registered on the response. Non-loopback Origin → 403, no allow headers.
  plug(:mcp_cors)
  plug(Plug.Logger)
  plug(:match)
  plug(:dispatch)

  def mcp_cors(conn, _opts) do
    case get_req_header(conn, "origin") do
      [] ->
        # No Origin → no CORS face (browser-irrelevant request).
        conn

      [origin | _] ->
        if Smalt.EgressRouter.loopback_origin?(origin) do
          origins = Application.get_env(:smalt, :egress_cors_origins, ["*"])
          headers = Application.get_env(:smalt, :egress_cors_headers, ["*"])
          CORSPlug.call(conn, CORSPlug.init(origin: origins, headers: headers))
        else
          conn |> send_resp(403, "") |> halt()
        end
    end
  end

  # BK-EGS1 (F-EGS1 repair, EXPL9-R2): the MCP surface declared
  # `use Plug.ErrorHandler` but never defined handle_errors/2 — the default
  # handler is a no-op and Plug.ErrorHandler ALWAYS re-raises, so any unhandled
  # crash escaped to Bandit as the NAKED adapter 500 (empty body, no envelope,
  # no request id; audit probe T6 class,
  # docs/jira/v26.10.22/receipts/bkegskep-fence-audit.md). Renders the JSON-RPC
  # error envelope + x-ms-request-id, with the same fault-guard as the egress
  # and ARM routers: a fault INSIDE this handler hits the rescue path, which
  # renders a fault-free constant fallback (module-attribute bytes + static
  # request id) and logs the secondary fault loudly.
  defp handle_errors(conn, %{kind: kind, reason: reason, stack: stack}) do
    require Logger

    # BK-XPRIF: exceptions carrying a typed plug_status < 500 are NOT
    # 500-class crashes — sending the 500 envelope here would swallow the
    # typed status (BK-XPRI HIGH regression class). Skip the fence so
    # Plug.ErrorHandler's re-raise reaches the adapter, which renders the
    # exception's own typed status.
    if kind == :error and Plug.Exception.status(reason) < 500 do
      Logger.error(
        "mcp_router typed plug-status crash (fence skipped, adapter renders typed status): " <>
          Exception.format(kind, reason, stack)
      )

      :ok
    else
      try do
        Logger.error("mcp_router crash 500: #{Exception.format(kind, reason, stack)}")

        # :unsent is not a real Plug conn.state — "nothing sent yet" is
        # state in [:unset, :set].
        if conn.state in [:unset, :set] do
          conn
          |> put_resp_header("x-ms-request-id", generate_uuid())
          |> put_resp_content_type("application/json")
          |> send_resp(
            500,
            Jason.encode!(%{
              "jsonrpc" => "2.0",
              "error" => %{"code" => -32_603, "message" => "Internal server error."},
              "id" => nil
            })
          )
        end

        :ok
      rescue
        secondary ->
          Logger.error(
            "mcp_router handle_errors itself FAULTED (F-EGS1 fallback engaged): " <>
              Exception.format(:error, secondary, __STACKTRACE__)
          )

          fegs1_fallback_send(conn, secondary)
      end
    end
  end

  @fegs1_fallback_request_id "00000000-0000-4000-8000-000000000000"
  @fegs1_fallback_body "{\"jsonrpc\":\"2.0\",\"error\":{\"code\":-32603,\"message\":\"Internal server error.\"},\"id\":null}"

  defp fegs1_fallback_send(conn, _secondary) do
    if conn.state in [:unset, :set] do
      conn
      |> put_resp_header("x-ms-request-id", @fegs1_fallback_request_id)
      |> put_resp_header("content-type", "application/json; charset=utf-8")
      |> send_resp(500, @fegs1_fallback_body)
    end

    :ok
  end

  defp generate_uuid do
    <<a::32, b::16, c::16, d::16, e::48>> = :crypto.strong_rand_bytes(16)

    :io_lib.format("~8.16.0b-~4.16.0b-~4.16.0b-~4.16.0b-~12.16.0b", [
      a,
      b,
      :erlang.band(c, 0x0FFF) + 0x4000,
      :erlang.band(d, 0x3FFF) + 0x8000,
      e
    ])
    |> IO.iodata_to_binary()
  end

  @json_rpc_parse_error -32_700
  @json_rpc_invalid_request -32_600
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
          @json_rpc_invalid_request,
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

  # ---------------------------------------------------------------------------
  # Tool families (T10 v26.10.29 split): this module keeps the tool registry
  # and the typed dispatch gate; per-tool input schemas and tool bodies live
  # in the Smalt.Mcp.Tool.<Family> modules under lib/smalt/mcp/tool/. Each
  # family returns the standard tool envelope ({:ok, result} |
  # {:refusal, code, message}) and nil for ids outside the family (the router
  # falls through to the next family). The generated mcp_descriptor.ex
  # surface is generator-owned - never hand-edited; families reference the
  # TTL surface, they never redefine it (drift fence:
  # test/internal/mcpt1_dispatch_court_test.exs).
  # ---------------------------------------------------------------------------

  @families [
    Smalt.Mcp.Tool.Arm,
    Smalt.Mcp.Tool.Catalog,
    Smalt.Mcp.Tool.Cosmos,
    Smalt.Mcp.Tool.CosmosFeed,
    Smalt.Mcp.Tool.Core,
    Smalt.Mcp.Tool.Eventing,
    Smalt.Mcp.Tool.KeyVault,
    Smalt.Mcp.Tool.Operations,
    Smalt.Mcp.Tool.Policy,
    Smalt.Mcp.Tool.ServiceBus,
    Smalt.Mcp.Tool.Storage
  ]

  # Minimal, honest input schemas (one per tool), resolved across the
  # families. A registered id with no family clause is a registry skew and
  # fails loudly instead of serving an empty schema.
  defp input_schema(id) do
    case Enum.find_value(@families, & &1.input_schema(id)) do
      nil -> raise ArgumentError, "no input_schema family clause for #{inspect(id)}"
      schema -> schema
    end
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

  defp registered?(name), do: match?({:ok, _}, Smalt.Mcp.Descriptor.describe(name))

  defp invoke(name, args) do
    Enum.find_value(@families, fn family -> family.invoke(name, args) end) ||
      {:refusal, @tool_not_found_code, "refused: unknown tool #{inspect(name)}"}
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
