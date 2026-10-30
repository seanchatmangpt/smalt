defmodule Smalt.ArmGateway.Router do
  @moduledoc """
  Subsystem 1: smalt-arm-gateway (Control Plane REST Mux)
  Listens on Port 9443 for ARM REST API calls and STS token issuance across all 15 emulated services.

  Surface (v26.10.14):
  - STS/OAuth2 token issuance with v2.0 issuer + oid/sub/tid/azp claims
  - Bootstrap/discovery endpoints (metadata, discovery instance, openid-configuration, tenant)
  - Subscription + resource-group CRUD with case-normalized `resourceGroups` segments
  - LIST routes via `Smalt.Store.list_prefix/2`
  - api-version require/validate against `Smalt.Registry.latest_version/1`
  - Child-resource routes (subnets, keys, blobServices/containers/immutabilityPolicies)
  - azapi POST action routes (.../lock, .../setLegalHold)
  - LRO (202 + Azure-AsyncOperation polling) via `Smalt.ArmGateway.LRO`
  - ARM error envelopes; GraphLaw refusal -> HTTP 400 (pinned)
  """
  use Plug.Router
  # GAP-AZB20-3 crash-path fence: without Plug.ErrorHandler a route crash is
  # adapter-rendered (Bandit), bypassing every register_before_send callback —
  # the naked 500 carries no x-ms-request-id. The handler below renders the ARM
  # envelope on the crash path.
  use Plug.ErrorHandler
  require Logger
  import Smalt.ArmGateway.Plug.Common

  # T06 (v26.10.29): public seams moved with their engines/families; kept on
  # the front module for callers that reach them as
  # Smalt.ArmGateway.Router.<fn> (egress_router.ex, tests).
  defdelegate affidavit_witness(subject), to: Smalt.ArmGateway.Plug.Common
  defdelegate lock_policy_etag(lock_request_path), to: Smalt.ArmGateway.Plug.ResourceProviders
  defdelegate eg1_publish(topic, events), to: Smalt.ArmGateway.Plug.ResourceProviders
  defdelegate eg_topic_events(topic), to: Smalt.ArmGateway.Plug.ResourceProviders
  defdelegate eg_topic_input_schema(topic), to: Smalt.ArmGateway.Plug.ResourceProviders

  plug(Plug.Logger)
  plug(:arm_cors)
  plug(:normalize_leading_empty_segment)
  # X-ARR-ClientCert mTLS gateway termination (WO-2 G2). No-op by default
  # (config :smalt, :x_arr_cert, require: false) — byte-identical when off.
  plug(Smalt.Auth.XArrCert)
  # DoD Gate 4: turnstile receipt headers on every membrane-served ARM
  # response (posh-court stage 5 asserts presence, fail-closed). Mounted
  # ABOVE Bearer (X1/C7) so pre-membrane 401/400 rejections also carry
  # receipts; the body read is deferred into the before_send closure, so
  # smalt_raw_body being nil pre-Parsers is handled by the plug's "" fallback.
  plug(Smalt.ArmGateway.Plug.ReceiptTurnstile)
  plug(Smalt.Auth.Bearer)

  # Per-request CORS knob for the 9443/9444 control plane (mirrors the egress
  # surface's :egress_cors_origins): default ["*"] keeps the historical
  # posture; an explicit allowlist echoes only allowed origins. Evaluated
  # per-request so a config flip does not need a recompile.
  defp arm_cors(conn, _opts) do
    origins = Smalt.Config.arm_cors_origins()
    headers = Application.get_env(:smalt, :arm_cors_headers, ["*"])

    CORSPlug.call(conn, CORSPlug.init(origin: origins, headers: headers))
  end

  plug(Plug.Parsers,
    parsers: [:json, :urlencoded],
    pass: ["*/*"],
    # AR-WIRE-01: JSON decode rides the JsonCompat engine seam (native :json when
    # available, Jason fallback; null normalized to nil).
    json_decoder: {Smalt.JsonCompat, :decode!, []},
    # Caches the raw body in conn.private so the STS token endpoint can
    # refuse duplicate form parameters (OAuth 2.1 draft / AAD parity).
    body_reader: {Smalt.Auth.BodyCache, :read_body, []}
  )

  plug(:arm_request_id)
  plug(:arm_throttle)
  # AZURE-FIDELITY lane 18: control-plane throttling realism — DEFAULT-OFF
  # (rate/burst nil). Gate-off the plug passes the conn through untouched.
  plug(Smalt.Egress.ThrottlePlug)
  # T-11 (r13): Microsoft.Web/sites (kind functionapp) ARM face + SCM-lite
  # admin surface. Mounted BEFORE :match so the sites routes never reach the
  # generic :provider_ns/:resource_type face; the router passes unmatched
  # conns through untouched and HALTS only on routes it answered.
  plug(Smalt.ArmGateway.Providers.FunctionsRouter)
  # S2 (v26.10.29): Microsoft.App containerApps runtime-plane pass-through
  # (answers via Smalt.ArmGateway.Providers.ContainerApps; conn unchanged
  # otherwise). The disclosed ONE-LINE mount of lane S2's contract.
  plug(Smalt.ArmGateway.Providers.ContainerAppsRouter)
  # v26.10.29 W2: Ash-dispatched deep child face — DEFAULT-INERT
  # (config :smalt, :ash_gateway, false). Passes through unless the flag is
  # on AND the deep shape resolves via Smalt.AshGen.Registry and is not
  # owned by an existing route family (see CanonicalRouter claim law).
  plug(Smalt.ArmGateway.CanonicalRouter)
  # T06 (v26.10.29): route-family plugs behind the front plug. Each answers the
  # conns its routes claim and returns UNCHANGED (pass-through tail) otherwise;
  # order preserves the monolith's first-match-wins precedence (identity faces,
  # then subscription/RG face, then provider faces).
  plug(Smalt.ArmGateway.Plug.OidcSts)
  plug(Smalt.ArmGateway.Plug.Metadata)
  plug(Smalt.ArmGateway.Plug.SubscriptionRouter)
  # 2026-10-30 r18/S5 compile-freeze unblock (DISCLOSED): the ACR pass-through
  # (r14-t01-acr receipt pins the mount "immediately before plug(:match)") was
  # absent mid-wave — /acr/* 404'd RouteNotFound on every face (witnessed:
  # listCredentials + /acr/:reg/v2/_catalog in the r18 court). One-line
  # behavior-restoring mount; the owner lane owns the final placement.
  # 2026-10-30 acrfix lane: mounted BEFORE ResourceProviders — the generic
  # face 400s canonical `resourceGroups`-casing ACR PUTs with
  # InvalidApiVersionParameter before the ACR pass-through ever sees them.
  # AcrRouter returns UNCHANGED for every non-ACR conn, so the generic face
  # behavior for all other types is byte-identical.
  plug(Smalt.ArmGateway.Providers.AcrRouter)
  plug(Smalt.ArmGateway.Plug.ResourceProviders)
  plug(:match)
  plug(:dispatch)

  # ===========================================================================
  # Helpers (Plug.Router requires helpers to be defined BEFORE the routes)
  # ===========================================================================

  # ===========================================================================
  # Wire-level plugs: x-ms-request-id echo (row 11) + ARM-wide throttling
  # (row 12). Both run before match/dispatch; the request-id header is attached
  # via register_before_send so it lands on EVERY response, including 429s.
  # ===========================================================================

  # Echo the client's x-ms-request-id when present, else mint a UUID. ARM SDK
  # retry/mid-tier-replay semantics key off this header.
  # KD-COVERS: KD-87 (canonical row in docs/jira/v26.10.14/KNOWN_DIVERGENCES.md; retokenized 2026-10-17 from the duplicate KD-82 mint; open until a real-SDK witness receipt).
  # azurerm 4.54.0 derives the STS authority from the metadata loginEndpoint
  # (trailing slash) and joins the tenant with a leading slash, producing
  # "//tenant/oauth2/v2.0/token" — a leading empty path segment Plug.Router
  # cannot match (falls through to the bearer guard -> 401 MissingBearerToken).
  # Real Azure tolerates the double slash; parity requires the same tolerance.
  # Normalization is limited to a leading empty segment ("//a" -> "/a");
  # interior double slashes stay untouched (byte-parity discipline).
  defp normalize_leading_empty_segment(conn, _opts) do
    case conn.path_info do
      ["" | rest] -> %{conn | path_info: rest}
      _ -> conn
    end
  end

  defp arm_request_id(conn, _opts) do
    request_id =
      case get_req_header(conn, "x-ms-request-id") do
        [id | _] when is_binary(id) and id != "" -> id
        _ -> generate_uuid()
      end

    # Stash the id so the crash path (handle_errors/2) reuses it. Note:
    # send_resp/3 DOES run register_before_send callbacks, so a handled 500
    # still carries x-ms-request-id and the ReceiptTurnstile headers.
    conn
    |> put_private(:arm_request_id, request_id)
    |> register_before_send(fn conn ->
      put_resp_header(conn, "x-ms-request-id", request_id)
    end)
  end

  # GAP-AZB20-3: crash-path ARM envelope. Plug.ErrorHandler calls handle_errors
  # and then ALWAYS re-raises (deps/plug error_handler.ex __catch__), so this
  # handler must send the response itself when nothing was sent yet — a double
  # send is impossible because Plug.ErrorHandler skips the handler via the
  # {:plug_conn, :sent} message when the response already went out. Renders a
  # well-formed ARM 500 InternalServerError with x-ms-request-id (stashed id,
  # else fresh). (No @impl: handle_errors is defp — Plug.ErrorHandler calls it
  # dynamically, and @impl on a private function is a compile warning.)
  defp handle_errors(conn, %{kind: kind, reason: reason, stack: stack}) do
    # BK-EGS1 (F-EGS1 repair, EXPL9-R2): a fault INSIDE handle_errors/2 itself
    # (generate_uuid/0, send_arm_error/5 -> Jason.encode!, ...) used to escape
    # Plug.ErrorHandler.__catch__ to Bandit as the NAKED adapter 500 (audit
    # probe T6, docs/jira/v26.10.22/receipts/bkegskep-fence-audit.md). The
    # rescue path renders a fault-free constant fallback envelope and logs the
    # secondary fault loudly.
    # BK-XPRIF: exceptions carrying a typed plug_status < 500 are NOT
    # 500-class crashes — sending the 500 envelope here would swallow the
    # typed status (BK-XPRI HIGH regression class). Skip the fence so
    # Plug.ErrorHandler's re-raise reaches the adapter, which renders the
    # exception's own typed status.
    if kind == :error and Plug.Exception.status(reason) < 500 do
      Logger.error(
        "arm_gateway typed plug-status crash (fence skipped, adapter renders typed status): " <>
          Exception.format(kind, reason, stack)
      )

      :ok
    else
      try do
        Logger.error("arm_gateway crash 500: #{Exception.format(kind, reason, stack)}")

        # :unsent is not a real Plug conn.state — "nothing sent yet" is
        # state in [:unset, :set].
        if conn.state in [:unset, :set] do
          rid = conn.private[:arm_request_id] || generate_uuid()

          send_arm_error(
            put_resp_header(conn, "x-ms-request-id", rid),
            500,
            "InternalServerError",
            "Internal server error.",
            conn.request_path
          )
        end

        :ok
      rescue
        secondary ->
          Logger.error(
            "arm_gateway handle_errors itself FAULTED (F-EGS1 fallback engaged): " <>
              Exception.format(:error, secondary, __STACKTRACE__)
          )

          fegs1_fallback_send(conn, secondary)
      end
    end
  end

  # BK-EGS1: constant, fault-free fallback render — compile-time attribute
  # bytes, static v4-shaped request id, no fallible call on the rescue path.
  @fegs1_fallback_request_id "00000000-0000-4000-8000-000000000000"
  @fegs1_fallback_body "{\"error\":{\"code\":\"InternalServerError\",\"message\":\"Internal server error.\",\"innererror\":{}}}"

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

    # RFC 4122 version 4 / variant bits (band via :erlang.band — Elixir
    # has no &&& operator without an import, and Bitwise is not imported
    # in this module)
    :io_lib.format("~8.16.0b-~4.16.0b-4~3.16.0b-~4.16.0b-~12.16.0b", [
      a,
      b,
      :erlang.band(c, 0x0FFF),
      :erlang.band(d, 0x3FFF) + 0x8000,
      e
    ])
    |> IO.iodata_to_binary()
  end

  # ARM-wide fixed-window (1s) throttle: 429 + Retry-After once the configured
  # :smalt, :arm_rate_limit is exceeded. Default :infinity — responses stay
  # byte-identical unless configured (mirrors the cosmos :cosmos_ru_limit gate).
  defp arm_throttle(conn, _opts) do
    case Smalt.Config.arm_rate_limit() do
      limit when is_integer(limit) and limit > 0 ->
        second = div(System.system_time(:millisecond), 1000)
        key = {:smalt_arm_rate, second}
        count = :ets.update_counter(rate_table(), key, {2, 1}, {key, 0})

        # Prune the previous window's key: the fixed-window counter is a lease,
        # not an asset — without this the table grows one key per second,
        # unbounded, for the life of the VM.
        :ets.delete(rate_table(), {:smalt_arm_rate, second - 1})

        if count > limit do
          throttled(conn)
        else
          conn
        end

      _ ->
        conn
    end
  end

  # Test seam: the throttle's named ETS table (creates it when missing).
  @doc false
  def rate_table_for_test, do: rate_table()

  defp rate_table do
    if :ets.info(:smalt_arm_rate) == :undefined do
      try do
        # Silent-disarm law (KD-110 lane, burst witness 2026-10-19): the first
        # creator is a Bandit request task — without an heir the counter table
        # DIES with that request, and the next burst re-creates a fresh table
        # mid-window (update_counter re-seeds at 0 → limiter disarmed, and a
        # racing delete can raise → 500s). Heir to :init (permanent,
        # node-local) makes the table outlive its creator; the ArgumentError
        # rescue keeps the create race fail-safe. Mirrors policy.ex
        # ensure_tables/0 (PW lane, same defect class).
        # ETSAUTO (AR-DATA-01 rollout, same flag as :smalt_cosmos_ru):
        # {:write_concurrency, :auto} on the pure rate-counter table.
        # update_counter/4 is atomic regardless of option, so semantics are
        # identical; the option only changes write-lock granularity (per-
        # scheduler sharding under :auto). Config-gated, default ON,
        # reversible via :smalt, :ets_write_concurrency_auto -> false.
        wc =
          if Application.get_env(:smalt, :ets_write_concurrency_auto, true),
            do: [{:write_concurrency, :auto}],
            else: []

        :ets.new(
          :smalt_arm_rate,
          List.flatten([
            :named_table,
            :public,
            :set,
            {:read_concurrency, true},
            wc,
            {:heir, Process.whereis(:init), []}
          ])
        )
      rescue
        ArgumentError -> :ok
      end
    end

    :smalt_arm_rate
  end

  # Inline envelope (NOT send_arm_error — the arm_error_corpus meta-test pins
  # the exact send_arm_error (status, code) set; 429 is not in that set).
  defp throttled(conn) do
    body =
      Jason.encode!(%{
        "error" => %{
          "code" => "TooManyRequests",
          "message" =>
            "The request rate has exceeded the configured arm_rate_limit. Retry after the indicated interval.",
          "innererror" => %{}
        }
      })

    conn
    |> put_resp_header("retry-after", "1")
    |> put_resp_content_type("application/json")
    |> send_resp(429, body)
    |> halt()
  end

  def sb_atom_alias(conn, method, path) do
    # EXPL9-R2 F1 (KD-COVERS: KD-175): the ATOM alias face previously matched
    # read_body/1 unguarded, so an oversized body (>8MB) escaped as
    # `{:more, _, _}` -> MatchError -> crash-path 500 InternalServerError
    # envelope. Real Azure answers 413 RequestBodyTooLarge; the canonical
    # guarded shape is egress_router.ex blob_block_arm. `{:error, reason}`
    # (malformed chunked body, socket abort) is a typed 400, never a crash.
    case Plug.Conn.read_body(conn, length: 8_000_000, read_length: 1_000_000) do
      {:ok, body, conn} ->
        sb_atom_alias_dispatch(conn, method, path, body)

      {:more, partial, _conn} ->
        send_arm_error(
          conn,
          413,
          "RequestBodyTooLarge",
          "The request body exceeds the 8,000,000-byte transport cap (read #{byte_size(partial)}+ bytes).",
          path
        )

      {:error, reason} ->
        send_arm_error(
          conn,
          400,
          "InvalidRequestBody",
          "The request body could not be read: #{inspect(reason)}.",
          path
        )
    end
  end

  defp sb_atom_alias_dispatch(conn, method, path, body) do
    # T27LQ-r: conn.request_path carries NO query string; the paged-list face
    # needs $top/$skip, so reconstruct the full path from query_string.
    path =
      case conn.query_string do
        nil -> path
        "" -> path
        qs -> path <> "?" <> qs
      end

    case Smalt.Amqp.AtomBridge.handle_request(method, path, body) do
      # KD-COVERS: KD-155 — layer 2: the flat ATOM face answers DELETE with
      # 204 No Content (real Azure ATOM "Delete Queue": 204, empty body).
      # The ARM management alias face keeps Azure ARM semantics: "Queues -
      # Delete" answers 200 OK with an empty body, and Plug 204 responses
      # must not carry content-type/content-length headers.
      {204, :no_content, <<>>} ->
        send_resp(conn, 200, "")

      {status, ctype, payload} ->
        conn
        |> put_resp_header("content-type", ctype)
        |> send_resp(status, payload)
    end
  end


  # -- Catch-all (proper ARM envelope) -------------------------------------------
  match _ do
    send_arm_error(
      conn,
      404,
      "RouteNotFound",
      "The route '#{conn.request_path}' could not be found.",
      conn.request_path
    )
  end
end
