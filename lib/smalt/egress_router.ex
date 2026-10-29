defmodule Smalt.EgressRouter do
  # UNBLOCK FIX (IMPL-4, compile-freeze SLA 2026-10-21): OTP-29-lane experiment
  # used `is_integer/3` range guards (not a real BIF on OTP 28 / any OTP).
  # Equivalent guard macro preserves semantics; owning lane may re-pin.
  # AR-WIRE-02 (IMPL-2 re-pin): body delegates to the real OTP-29 range
  # guard BIF `:erlang.is_integer/3` (OTP-29-only; compile-refused on
  # OTP <= 28). The Elixir 1.20 front end does not admit bare
  # `is_integer/3` in guards ("there is no such import"), so this one-line
  # delegate is the direct-BIF form — IMPL-4's 3-comparison shim body is
  # superseded. Repo standard toolchain: OTP 29 (TOOLUP, .tool-versions
  # erlang 29.1.2 / elixir 1.20.4-otp-29).
  # AR-WIRE-02 (IMPL-2 final re-pin): delegates to the real OTP-29 range
  # guard BIF `:erlang.is_integer/3` (OTP-29-only; compile-refused on
  # OTP <= 28). Elixir 1.20 does not admit bare is_integer/3 in guards
  # ("there is no such import"), so this one-line delegate IS the direct-BIF
  # form; the `x in lo..hi` shim body is semantically identical but is the
  # OTP-28 fallback, not the adopted BIF. Repo toolchain: OTP 29
  # (TOOLUP, .tool-versions erlang 29.1.2 / elixir 1.20.4-otp-29).
  defguardp int_in(x, lo, hi) when is_integer(x) and x >= lo and x <= hi

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
  # EXPL-9 F2b (KD-COVERS: KD-175): crash-path fence, GAP-AZB20-3 class. Before
  # this, any unhandled crash (e.g. the F2 read_body MatchError) escaped to
  # Bandit and rendered a NAKED adapter 500 — empty body, no envelope, no
  # x-ms-request-id — bypassing every register_before_send callback. The
  # arm_gateway router's handler is the in-repo template.
  use Plug.ErrorHandler
  require Logger
  alias Smalt.Store
  alias Smalt.DataPlane.BlobError
  alias Smalt.DataPlane.BlobService
  alias Smalt.Messaging.EventStream
  alias Smalt.DataPlane.BlobStorage
  alias Smalt.DataPlane.Cosmos
  alias Smalt.DataPlane.QueueStorage

  # GAP-AUD1-01 (v26.10.14, lane W-5): blob comp whitelists — MUST be defined
  # textually BEFORE the route macros that expand them (module attributes are
  # expanded at their point of use, top-to-bottom).
  # KD-COVERS: KD-60 — comp=snapshot is registered (wire arm below); the rest
  # of the KD-60 class (tags/pagelist/...) stays default-deny refused.
  # Parity lane 2026-10-28: comp=lease (base blob, no sharesnapshot),
  # appendblock, page and properties (Set Blob HTTP Headers) registered —
  # receipted against Azurite (parity/COVERAGE_VS_TOPAZ.md gap list).
  # Local wave (w6aw/BK-132): comp=undelete and comp=tier registered on the
  # same fail-closed whitelist (arms below).
  @blob_put_comps ~w(block blocklist metadata snapshot undelete tier lease appendblock page properties)
  # KD-COVERS: KD-60 — comp=metadata GET registered (Azure Get Blob Metadata);
  # pagelist/tags stay default-deny.
  @blob_get_comps ~w(blocklist metadata)
  # R98 container comp whitelists — mirror of the blob arms above. Lease and
  # ACL are UNIMPLEMENTED (KD/GAP(blob-comp-lease-absent)); previously an
  # unknown container comp fell through: PUT into the create-container branch
  # (silent 201 lie), GET into the plain-list fallback (wrong-body 200).
  @container_put_comps ~w(legalhold immutabilityPolicy immutabilitypolicy metadata lease acl)
  @container_get_comps ~w(legalhold immutabilityPolicy immutabilitypolicy metadata list acl)

  # R99: known other-plane namespaces that must never reach the blob splat
  # arms (see reserved_fence_then below). Also consumed by the G5 tenant
  # fence plug (tenant_blob_shape?/1) — routes in these namespaces match
  # before the blob splat and must never see a tenant-rewritten path.
  @reserved_first_segments ~w(dbs secrets certificates keys topics subscriptions attest app atlas dataCollectionRules v1 v1.0 providers)

  # Adaptive health probes (envelope Phase 4): zero-auth readiness/liveness.
  # Readiness degrades only on structural failure, never on load.
  plug(Smalt.HealthPlug)
  # MOONSHOT lane 9 (throttling realism): token-bucket 429 gate, per plane.
  # DEFAULT-OFF — with no `:smalt, :throttle` rate/burst the plug passes every
  # conn through UNCHANGED (byte-identical boot, existing courts unaffected).
  plug(Smalt.Egress.ThrottlePlug)
  plug(Plug.Logger)
  # Lane 19 (v26.10.14) item 6: CORS origins are configurable at runtime via
  # `:smalt, :egress_cors_origins` (list of allowed origins). The default is
  # ["*"] — the documented dev posture for the emulator's 8443 surface; in
  # production, configure an explicit allowlist. Evaluated per-request so a
  # config flip does not need a recompile.
  plug(:egress_cors)

  def egress_cors(conn, _opts) do
    # w6ay: the blob plane gets rule-based CORS (Set Blob Service Properties
    # <Cors> rules, 403 preflight no-match per real Azure) instead of the
    # static-origin CORSPlug answer; all other planes keep the pinned
    # CORSPlug face (the KD-15 court pins OPTIONS on the KV plane).
    cond do
      # BK-21 (v26.10.21): queue REST preflights used to fall into the blob
      # rule-based branch (path has no plane prefix) and answer 403 — the
      # KD-15 queue leg's CORS gap. Queue-shaped preflights get the same
      # static CORSPlug face as KV, gated on loopback origin (loopback-only
      # posture preserved; non-loopback origins still refuse 403).
      queue_preflight?(conn) ->
        queue_mcp_cors(conn)

      # BK-56 (v26.10.22): the actual (non-preflight) queue responses also
      # need the allow-origin face — a browser blocks the real PUT/POST/GET
      # even after a passing 204 preflight if the actual response carries no
      # `access-control-allow-origin`. Divert loopback-CORS actual requests on
      # queue shapes to the same face (static_cors/CORSPlug echoes the origin
      # on actual responses). Nil-origin passes through (not a CORS request);
      # non-loopback origins take the ordinary non-CORS path (they get no
      # allow face, loopback-only posture preserved).
      queue_actual_cors?(conn) ->
        queue_mcp_cors(conn)

      blob_plane_path?(conn.request_path) ->
        w6ay_blob_cors(conn)

      true ->
        static_cors(conn)
    end
  end

  defp static_cors(conn) do
    origins = Application.get_env(:smalt, :egress_cors_origins, ["*"])
    headers = Application.get_env(:smalt, :egress_cors_headers, ["*"])
    CORSPlug.call(conn, CORSPlug.init(origin: origins, headers: headers))
  end

  # ---------------------------------------------------------------------------
  # G5 tenant fence plug (CZ2 law; shared helper Smalt.Auth.TenantLaw).
  # Foreign-`tid` bearers on the blob/queue planes get (a) their account
  # segment namespaced via TenantLaw.tenant_scoped_key/2 so tenant data is
  # structurally partitioned, and (b) point access at a key that exists only
  # under another tenant's namespace answered with the typed 403 (never a
  # 404 lie, never a silent leak). Home/no-tid bearers pass through
  # byte-identical — every legacy single-tenant court keeps its exact wire.
  # ---------------------------------------------------------------------------
  def tenant_namespace(conn, _opts) do
    tenant = Smalt.Auth.TenantLaw.resolve_tenant(conn)

    if tenant == Smalt.Auth.TenantLaw.home_tenant() do
      conn
    else
      cond do
        queue_plane_shape?(conn) -> tenant_queue_fence(conn, tenant)
        tenant_blob_shape?(conn) -> tenant_blob_fence(conn, tenant)
        true -> conn
      end
    end
  end

  # Blob-fence scope: blob-plane heuristic + NOT a reserved/service segment
  # (@reserved_first_segments routes are matched before the blob splat and
  # must never see a rewritten path) + NOT an auth-exempt bootstrap path
  # (STS mint/discovery must stay reachable for foreign-tenant clients).
  defp tenant_blob_shape?(conn) do
    first = conn.path_info |> List.first()

    blob_plane_path?(conn.request_path) and
      first not in @reserved_first_segments and
      first != "tables" and
      not Smalt.Auth.Bearer.auth_exempt_path?(conn.request_path)
  end

  defp tenant_queue_fence(conn, tenant) do
    case conn.path_info do
      [account, queue | _] ->
        qkey = String.downcase("#{account}/#{queue}")

        if foreign_scoped_key?(:smalt_q_queues, tenant, qkey) do
          refuse_tenant_403(conn)
        else
          namespace_account(conn, tenant, account)
        end

      [_account] ->
        # List Queues: no point key — namespacing alone yields the empty
        # feed for a tenant with no own rows (never a 403).
        namespace_account(conn, tenant, hd(conn.path_info))
    end
  end

  defp tenant_blob_fence(conn, tenant) do
    case conn.path_info do
      [account, container | _] ->
        ckey = "#{account}/#{container}"

        if foreign_scoped_key?(:smalt_blob_containers, tenant, ckey) do
          refuse_tenant_403(conn)
        else
          namespace_account(conn, tenant, account)
        end

      [_account] ->
        # List Containers / service properties: namespacing alone.
        namespace_account(conn, tenant, hd(conn.path_info))
    end
  end

  # Rewrite the account segment so every downstream engine key is derived in
  # the caller's namespace ("{tenant}/{account}/..."); home callers never get
  # here, so legacy keys stay byte-identical.
  defp namespace_account(conn, tenant, account) do
    scoped = Smalt.Auth.TenantLaw.tenant_scoped_key(tenant, account)
    segs = [scoped | tl(conn.path_info)]
    path = "/" <> Enum.join(segs, "/")

    conn
    |> Map.put(:path_info, segs)
    |> Map.put(:request_path, path)
  end

  # True when `legacy_key` exists in `table` ONLY under a namespace that is
  # NOT `tenant`'s: the exact legacy (home) key itself, or a
  # "{other_tenant}/.../legacy_key" scoped key with the tenant prefix
  # (everything before the exact "/#{legacy_key}" suffix) different from
  # `tenant`. Real Store.keys/1 scan — no mocks.
  def foreign_scoped_key?(table, tenant, legacy_key) do
    own = Smalt.Auth.TenantLaw.tenant_scoped_key(tenant, legacy_key)

    Enum.any?(Store.keys(table), fn k ->
      is_binary(k) and k != own and
        (k == legacy_key or foreign_prefixed_key?(k, legacy_key, tenant))
    end)
  end

  defp foreign_prefixed_key?(k, legacy_key, tenant) do
    if String.ends_with?(k, "/#{legacy_key}") do
      binary_part(k, 0, byte_size(k) - byte_size(legacy_key) - 1) != tenant
    else
      false
    end
  end

  # Typed 403 — the TenantLaw Forbidden envelope, rendered through the same
  # blob_error face the planes already use (XML on the blob face, JSON
  # envelope on queue shapes).
  defp refuse_tenant_403(conn) do
    blob_error(conn, 403, %{
      "error" => %{
        "code" => "Forbidden",
        "message" => Smalt.Auth.TenantLaw.mismatch_message()
      }
    })
  end

  # BK-21: shared CORSPlug face for queue REST preflights (this router) and
  # the MCP 9545 plane (Smalt.Mcp.Router) — identical init to the KV
  # precedent (KD-15 pins that face). Loopback-origin gate: the emulator
  # binds loopback only, so browser clients are loopback pages; a
  # non-loopback Origin is refused 403 with no allow headers.
  def queue_mcp_cors(conn) do
    origin = conn |> get_req_header("origin") |> List.first()

    cond do
      # No Origin → not a CORS request; pass through untouched (CORSPlug
      # semantics — never fabricate a CORS face for a non-browser request).
      is_nil(origin) ->
        conn

      loopback_origin?(origin) ->
        static_cors(conn)

      true ->
        conn |> send_resp(403, "") |> halt()
    end
  end

  # BK-21: queue REST surface shapes (G1 disambiguation, scoping doc section
  # 1): restype=queue lifecycle + List Queues + /messages surface. Only
  # OPTIONS preflights on these shapes take the queue CORS arm; every other
  # method/path is untouched (byte-identical requests downstream).
  defp queue_preflight?(conn) do
    conn.method == "OPTIONS" and queue_plane_shape?(conn)
  end

  # BK-56: loopback-CORS actual (non-OPTIONS) request on a queue shape — the
  # actual-response allow-origin gap closed alongside the preflight (BK-21).
  defp queue_actual_cors?(conn) do
    conn.method != "OPTIONS" and queue_plane_shape?(conn) and
      conn |> get_req_header("origin") |> List.first() |> loopback_origin?()
  end

  # G5: public read — the tenant fence plug consumes the canonical shape
  # predicate (one law, never a copied shape list).
  def queue_plane_shape?(conn) do
    qp = fetchd_query_params(conn)

    case conn.path_info do
      [_account] -> qp["restype"] == "queue" and qp["comp"] == "list"
      [_account, _queue] -> qp["restype"] == "queue"
      [_account, _queue, "messages"] -> true
      [_account, _queue, "messages", _id] -> true
      _ -> false
    end
  end

  @doc """
  BK-21: loopback-origin gate for CORS faces on loopback-only surfaces.
  Accepts an `Origin` header value; true iff its host is 127.0.0.1,
  localhost, ::1, or a `*.localhost` name. Public so `Smalt.Mcp.Router`
  shares the exact same gate (one law, two mounts).
  """
  def loopback_origin?(origin) when is_binary(origin) do
    case URI.parse(origin).host do
      nil ->
        false

      host ->
        host = String.downcase(host)
        host in ["127.0.0.1", "localhost", "::1"] or String.ends_with?(host, ".localhost")
    end
  end

  def loopback_origin?(_), do: false

  # Blob-plane path heuristic: blob REST is /{account}[/{container}[/{blob}]]
  # with no leading plane prefix (kv/cosmos/appconfig/attest/messaging...).
  # G5: public read of the blob-plane heuristic — the tenant fence plug
  # consumes it (one canonical predicate, never a copied prefix list).
  def blob_plane_path?("/" <> rest) do
    first = rest |> String.split("/", parts: 2) |> hd()

    first not in [
      "keys",
      "secrets",
      "certificates",
      "certificates/",
      # BK-56: deletedcertificates is the certs plane's soft-delete surface
      # (popcorn_demo LiveCerts deleted-get leg), never a blob account.
      "deletedcertificates",
      "kv",
      "dbs",
      "attest",
      "snapshots",
      "segments",
      "subscriptions",
      "metadata",
      "v2",
      "schemas",
      "revisions",
      "managedstorage",
      "$schemagroups",
      # PRD-APIM wire: /apim-gw is a policy-chained gateway namespace, never a
      # blob account (the apim plug intercepts configured gateways; the
      # unconfigured/default-off face is owned by the apim plane below).
      "apim-gw",
      # BK-SKIPPORT: /topics is the EventGrid publish/readback plane
      # (Microsoft.EventGrid systemTopics -> /topics/:topic/events); the blob
      # heuristic shadowed it as a phantom blob account, so topic OPTIONS
      # preflights were 403'd against account "topics" rules (always empty).
      "topics",
      # AZURE-FIDELITY lane 13/AF-L14-GAP-1 (v26.10.25): /v1.0/* is the
      # Microsoft Graph stub surface (servicePrincipals/applications/
      # oauth2PermissionGrants/auditLogs/signIns) — never a blob account; the
      # tenant fence must not namespace its account segment (witnessed:
      # foreign-tid bearer -> account "v1.0" namespaced -> GraphRoutes
      # fallthrough -> blob 400 MissingXMsVersion, signins court 0/3).
      "v1.0"
    ]
  end

  def blob_plane_path?(_), do: false

  # w6ay (Blob service CORS rules): OPTIONS preflight answered from the
  # stored <Cors> service properties; actual requests with a matching Origin
  # get Access-Control-Expose-Headers registered on the response.
  # w6av compile-freeze SLA unblock (disclosed): sibling w6ay's in-flight
  # helper — minimal first-segment extraction so the tree compiles. Owner may
  # supersede; disclosed in both receipts.
  defp account_from_blob_path(path) when is_binary(path) do
    path |> String.split("/", parts: 3) |> Enum.at(1) || ""
  end

  defp w6ay_blob_cors(conn) do
    origin = conn |> get_req_header("origin") |> List.first()

    if is_binary(origin) do
      account = account_from_blob_path(conn.request_path)
      method = conn |> get_req_header("access-control-request-method") |> List.first()

      if conn.method == "OPTIONS" and is_binary(method) do
        case Smalt.DataPlane.BlobCors.preflight(account, origin, method) do
          {:ok, headers} ->
            headers
            |> Enum.reduce(conn, fn {k, v}, acc -> put_resp_header(acc, k, v) end)
            |> send_resp(200, "")
            |> halt()

          :forbidden ->
            conn |> send_resp(403, "") |> halt()
        end
      else
        # BK-56: actual requests with a loopback Origin get the KV CORSPlug
        # face (echoed allow-origin + allow-credentials) on the actual
        # response, not just the preflight — the BK-15b residual. Non-loopback
        # origins keep the rule-based-only posture (no new allow face).
        conn =
          if loopback_origin?(origin) do
            static_cors(conn)
          else
            conn
          end

        case Smalt.DataPlane.BlobCors.expose_headers(account, origin) do
          nil ->
            conn

          expose ->
            register_before_send(conn, fn c ->
              put_resp_header(c, "Access-Control-Expose-Headers", expose)
            end)
        end
      end
    else
      # Requests without an Origin pass through untouched (no CORS face).
      conn
    end
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

  def kv_challenge_guard(conn, _opts) do
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

  # PRD-APIM wire (v26.10.21 lane APIMWIRE): policy-chained API-management
  # gateway namespace. Config-driven and DEFAULT-OFF -- with no
  # `:smalt, :apim_gateways` entry for the requested api the plug passes
  # through UNCHANGED (byte-identical boot, existing courts unaffected).
  # Sits BEFORE the global bearer plug so the per-route `jwt` policy owns
  # admission (jwt is optional per route config), never shadowed by the
  # substrate-wide challenge.
  plug(:apim_gateway_plane)

  def apim_gateway_plane(conn, _opts) do
    case apim_gateway_conf(conn.path_info) do
      # The /apim-gw namespace is owned by the APIM plane outright -- an
      # unconfigured api answers the same typed-404 face the router's
      # catch-all serves ({"error":{"code":"RouteNotFound"}}), NEVER a blob
      # account (the blob splat's x-ms-version guard would serve a lying 400
      # for this namespace otherwise -- witnessed on the first court run).
      nil ->
        case conn.path_info do
          ["apim-gw" | _] -> apim_not_found(conn)
          _ -> conn
        end

      conf ->
        run_apim_gateway(conn, conf)
    end
  end

  defp apim_gateway_conf(["apim-gw", api | _rest] = _path_info) do
    Application.get_env(:smalt, :apim_gateways, %{})
    |> Map.get(api)
    |> case do
      nil -> nil
      conf -> {api, conf}
    end
  end

  defp apim_gateway_conf(_path_info), do: nil

  # Gateway conf accepts keyword or map form (operator config ergonomics).
  defp run_apim_gateway(conn, {api, conf}) do
    # First refusal halts the chain and has already sent the typed envelope
    # ({:rate_limit -> 429 TooManyRequests, :jwt -> 401, :header_transform
    # never refuses}).
    conn = Smalt.Apim.run(conn, apim_conf(conf, :policies, []))

    if conn.halted do
      conn
    else
      apim_backend(conn, apim_conf(conf, :backend, :echo), api)
    end
  end

  defp apim_not_found(conn) do
    body =
      Jason.encode!(%{
        "error" => %{
          "code" => "RouteNotFound",
          "message" => "no APIM gateway is configured for this api"
        }
      })

    conn
    |> put_resp_content_type("application/json")
    |> send_resp(404, body)
    |> halt()
  end

  defp apim_conf(conf, key, default) when is_list(conf), do: Keyword.get(conf, key, default)
  defp apim_conf(conf, key, default) when is_map(conf), do: Map.get(conf, key, default)

  # Echo backend: 200 JSON witness of method/path plus the REQUEST headers
  # AFTER the chain's header_transform ran -- the transform is wire-visible.
  defp apim_backend(conn, :echo, api) do
    headers = Map.new(conn.req_headers)

    body =
      Jason.encode!(%{
        "api" => api,
        "method" => conn.method,
        "path" => conn.request_path,
        "headers" => headers
      })

    conn
    |> put_resp_content_type("application/json")
    |> send_resp(200, body)
  end

  defp apim_backend(_conn, other, api),
    do: raise(ArgumentError, message: "unknown APIM backend #{inspect(other)} for api #{api}")

  # KD-101 narrowed: webhook receiver surface (zero-auth /eventgrid class)
  plug(Smalt.EventGridWebhookPlug)
  # W1 (v26.10.22): Event Grid push-style subscription face — /eventgrid/
  # subscriptions CRUD, same zero-auth /eventgrid path class as the KD-101
  # receiver above; matched CloudEvents sieve to WAL/SB-queue (KD-169).
  plug(Smalt.EventGrid.PushRouterPlug)
  plug(Smalt.Auth.Bearer)
  plug(:fetch_query_params)
  # G5 tenant fence (CZ2 law, shared helper Smalt.Auth.TenantLaw from G4):
  # blob/queue plane requests carrying a foreign `tid` bearer get their
  # account segment namespaced (`tenant_scoped_key`) so cross-tenant data is
  # structurally unreachable, and point access at another tenant's live key
  # answers the typed 403 instead of a 404 lie. Downstream of
  # Smalt.Auth.Bearer, so `resolve_tenant/1` reads the verified bearer's
  # claim. Home/no-tid callers pass through byte-identical (legacy law).
  plug(:tenant_namespace)
  # Python SDK trailing-slash tolerance: GET /dbs/:db/colls/:coll/ must route
  # identically to the non-slash form. Plug treats the trailing slash as an
  # empty final segment, which falls through to the 404 catch-all — strip it
  # for /dbs-prefixed paths before :match.
  plug(:trim_dbs_trailing_slash)

  plug(:maybe_parse_body)

  # w6h: Cosmos users/permissions/resource-token surface — its own plug (the
  # main match function is at a beam implementation limit; witnessed).
  plug(Smalt.CosmosAuthzPlug)

  # ---------------------------------------------------------------------------
  # G1 Azure Queue Storage plane (v26.10.19) — arm BEFORE the blob splat.
  # Queue Storage's REST namespace (/{account}/{queue}/messages...) collides
  # with the guarded blob catch-all at the same /{account}/... prefix; the
  # disambiguation is query-shape detection (scoping doc section 1):
  #   * PUT/DELETE /{account}/{queue}?restype=queue  -> queue lifecycle
  #   * GET    /{account}?comp=list&restype=queue    -> List Queues
  #   * /{account}/{queue}/messages[/{id}]           -> message surface
  # Everything else (:pass) falls through to :match UNCHANGED — the blob
  # splat, Cosmos, KV and every other arm see byte-identical requests.
  # ---------------------------------------------------------------------------
  # ---------------------------------------------------------------------------
  # SB-REST lane: Microsoft Service Bus REST data-plane surface. Same path
  # shape as the Queue Storage plane below (/{account}/{queue}/messages...);
  # the disambiguator is the auth face — a `SharedAccessSignature` /
  # `ServiceBusAuthorization` header claims the request for Service Bus, a
  # `SharedKey` face (or absence) falls through UNCHANGED.
  # ---------------------------------------------------------------------------
  plug(Smalt.Egress.ServiceBusRestRoutes)

  plug(:queue_storage_plane)

  def queue_storage_plane(conn, _opts) do
    qp = fetchd_query_params(conn)

    # Parity lane 2026-10-28: the v12 storage-queue SDK sends
    # `GET /{account}?comp=list` with NO restype (real Azure implies the
    # service by endpoint host) — byte-identical to blob List Containers.
    # On this shared egress port the only deterministic discriminator is
    # the SDK User-Agent (azsdk-js-azure-storage-queue vs -blob); an
    # explicit restype, when present, always wins.
    queue_ua? =
      conn
      |> get_req_header("user-agent")
      |> Enum.any?(&String.contains?(&1, "storage-queue"))

    case queue_plane_route(conn.method, conn.path_info, qp, queue_ua?) do
      nil -> conn
      arm -> run_queue_arm(conn, arm, qp)
    end
  end

  # Parity lane 2026-10-28: reserved first segments that belong to OTHER
  # planes on the shared egress port (cosmos /dbs, KV /keys /secrets /kv,
  # eventgrid, ...) — the bare-2-segment queue arms below must never capture
  # them. Defined BEFORE every queue_plane_route clause that reads it
  # (module attributes resolve in file order).
  @queue_reserved_first_segments ~w(dbs keys secrets kv eventgrid events attest)

  defp queue_plane_route("GET", [account], qp, queue_ua?) do
    cond do
      qp["comp"] == "list" and qp["restype"] == "queue" ->
        {:list_queues, account}

      qp["comp"] == "list" and is_nil(qp["restype"]) and queue_ua? ->
        {:list_queues, account}

      true ->
        nil
    end
  end

  # Parity lane 2026-10-28: bare 2-segment GET (the v12 SDK's
  # Get Queue Properties shape — no restype on the wire), and the SDK's
  # getProperties()/getMetadata() shape `?comp=metadata` without restype
  # (real Azure Get Queue Metadata; the blob container GET always carries
  # restype=container, so the no-restype form is unambiguously queue).
  defp queue_plane_route("GET", [account, queue], qp, _queue_ua?) do
    cond do
      account in @queue_reserved_first_segments -> nil
      qp["restype"] == "queue" -> {:get_queue_props, account, queue}
      is_nil(qp["restype"]) and is_nil(qp["comp"]) -> {:get_queue_props, account, queue}
      qp["comp"] == "metadata" and is_nil(qp["restype"]) ->
        {:get_queue_props, account, queue}

      true ->
        nil
    end
  end

  # Parity lane 2026-10-28: the @azure/storage-queue v12 SDK does NOT send
  # restype=queue on queue create/delete — the service is implied by the
  # endpoint host on real Azure ({account}.queue.core.windows.net). On smalt's
  # single shared egress port the bare 2-segment PUT/DELETE (no comp, no
  # restype) is unambiguous: the blob container arm ALWAYS carries
  # restype=container (SDK-witnessed), so route it to the queue plane.
  defp queue_plane_route("PUT", [account, queue], qp, _queue_ua?) do
    cond do
      account in @queue_reserved_first_segments -> nil
      qp["restype"] == "queue" -> {:create_queue, account, queue}
      is_nil(qp["restype"]) and is_nil(qp["comp"]) -> {:create_queue, account, queue}
      # Queue Set Metadata (comp=metadata, NO restype — the blob container
      # metadata PUT carries restype=container and must NOT be hijacked).
      qp["comp"] == "metadata" and is_nil(qp["restype"]) ->
        {:set_queue_metadata, account, queue}

      true ->
        nil
    end
  end

  defp queue_plane_route("DELETE", [account, queue], qp, _queue_ua?) do
    cond do
      account in @queue_reserved_first_segments -> nil
      qp["restype"] == "queue" -> {:delete_queue, account, queue}
      is_nil(qp["restype"]) and is_nil(qp["comp"]) -> {:delete_queue, account, queue}
      true -> nil
    end
  end

  defp queue_plane_route("POST", [account, _queue, "messages"], _qp, _ua),
    do: {:put_messages, account}

  defp queue_plane_route("GET", [account, _queue, "messages"], qp, _ua),
    do: if(qp["peekonly"] == "true", do: {:peek_messages, account}, else: {:get_messages, account})

  defp queue_plane_route("PUT", [account, _queue, "messages", _id], _qp, _ua),
    do: {:update_message, account}

  # Clear Messages must shadow the popreceipt-carrying delete-message match on
  # path shape alone (3 elements vs 4) — the 3-element DELETE is the clear comp.
  defp queue_plane_route("DELETE", [account, _queue, "messages"], _qp, _ua),
    do: {:clear_messages, account}

  defp queue_plane_route("DELETE", [account, _queue, "messages", _id], _qp, _ua),
    do: {:delete_message, account}

  defp queue_plane_route(_, _, _, _), do: nil

  # Table Storage plane (lane w6p): literal /tables prefix, additive.
  plug(:table_service_plane)

  def table_service_plane(conn, _opts) do
    case Smalt.DataPlane.TableStorageRouter.route(conn) do
      nil -> conn
      _sent -> conn
    end
  end

  def run_queue_arm(conn, arm, qp) do
    if not_ready?(conn, [QueueStorage]) do
      route_not_ready(conn)
    else
      queue_dispatch(conn, arm, qp)
    end
    # The queue arms send their responses inside queue_dispatch; without an
    # explicit halt the plug pipeline CONTINUES into :match and the blob
    # splat re-dispatches the same request (in-process callers crash with
    # AlreadySentError; live Bandit traffic masked it because the response
    # was already on the socket). Halt is the correct terminal behavior for
    # a handled arm. Found by test/integration/parity_lane_wire_test.exs.
    |> Plug.Conn.halt()
  end

  defp queue_dispatch(conn, {:list_queues, account}, qp) do
    case QueueStorage.list_queues(account, qp) do
      {:ok, status, headers, body} ->
        conn
        |> put_resp_headers(headers)
        |> put_resp_content_type("application/xml")
        |> send_resp(status, body)

      {:error, status, code, msg} ->
        blob_error(conn, status, not_found_error(code) |> put_message(msg))
    end
  end

  defp queue_dispatch(conn, {:create_queue, account, queue}, _qp) do
    case QueueStorage.create_queue(account, queue) do
      {:ok, status, headers} ->
        send_headers(conn, status, headers)

      {:error, status, code, msg} ->
        blob_error(conn, status, not_found_error(code) |> put_message(msg))
    end
  end

  defp queue_dispatch(conn, {:delete_queue, account, queue}, _qp) do
    case QueueStorage.delete_queue(account, queue) do
      {:ok, status, headers} ->
        send_headers(conn, status, headers)

      {:error, status, code, msg} ->
        blob_error(conn, status, not_found_error(code) |> put_message(msg))
    end
  end

  # Parity lane 2026-10-28: Queue Set Metadata — persists x-ms-meta-* on the
  # queue row (Get Queue Properties reads them back); 204 No Content.
  defp queue_dispatch(conn, {:set_queue_metadata, account, queue}, _qp) do
    case QueueStorage.set_queue_metadata(account, queue, meta_headers(conn)) do
      {:ok, status, headers} ->
        send_headers(conn, status, headers)

      {:error, status, code, msg} ->
        blob_error(conn, status, not_found_error(code) |> put_message(msg))
    end
  end

  defp queue_dispatch(conn, {:get_queue_props, account, queue}, _qp) do
    case QueueStorage.get_queue_properties(account, queue) do
      {:ok, status, headers} ->
        send_headers(conn, status, headers)

      {:error, status, code, msg} ->
        blob_error(conn, status, not_found_error(code) |> put_message(msg))
    end
  end

  # Queue message bodies are XML — Plug.Parsers (json/urlencoded) leaves them
  # unread; read the raw body here. A JSON content-type body would already be
  # consumed by the parsers plug, which is acceptable (Azure clients send XML).
  defp queue_dispatch(conn, {:put_messages, account}, _qp) do
    [queue, _] = Enum.drop(conn.path_info, 1)

    with {:ok, body, conn} <- read_queue_body(conn) do
      case QueueStorage.put_message(account, queue, body) do
        {:ok, status, headers, resp_body} ->
          conn
          |> put_resp_headers(headers)
          |> put_resp_content_type("application/xml")
          |> send_resp(status, resp_body)

        {:error, status, code, msg} ->
          blob_error(conn, status, not_found_error(code) |> put_message(msg))
      end
    else
      {:error, reason} ->
        blob_error(conn, 400, %{
          "error" => %{"code" => "InvalidRequestBody", "message" => inspect(reason)}
        })
    end
  end

  defp queue_dispatch(conn, {:get_messages, account}, qp) do
    [queue, _] = Enum.drop(conn.path_info, 1)

    case QueueStorage.get_messages(account, queue, qp) do
      {:ok, status, headers, resp_body} ->
        conn
        |> put_resp_headers(headers)
        |> put_resp_content_type("application/xml")
        |> send_resp(status, resp_body)

      {:error, status, code, msg} ->
        blob_error(conn, status, not_found_error(code) |> put_message(msg))
    end
  end

  defp queue_dispatch(conn, {:peek_messages, account}, qp) do
    [queue, _] = Enum.drop(conn.path_info, 1)

    case QueueStorage.peek_messages(account, queue, qp) do
      {:ok, status, headers, resp_body} ->
        conn
        |> put_resp_headers(headers)
        |> put_resp_content_type("application/xml")
        |> send_resp(status, resp_body)

      {:error, status, code, msg} ->
        blob_error(conn, status, not_found_error(code) |> put_message(msg))
    end
  end

  defp queue_dispatch(conn, {:clear_messages, account}, _qp) do
    [queue, _] = Enum.drop(conn.path_info, 1)

    case QueueStorage.clear_messages(account, queue) do
      {:ok, status, headers} ->
        send_headers(conn, status, headers)

      {:error, status, code, msg} ->
        blob_error(conn, status, not_found_error(code) |> put_message(msg))
    end
  end

  defp queue_dispatch(conn, {:update_message, account}, qp) do
    [queue, _, msg_id] = Enum.drop(conn.path_info, 1)

    with {:ok, body, conn} <- read_queue_body(conn) do
      case QueueStorage.update_message(
             account,
             queue,
             msg_id,
             qp["popreceipt"] || "",
             body,
             qp
           ) do
        {:ok, _status, headers, _resp_body} ->
          # Azure parity (parity lane 2026-10-28, receipted vs Azurite):
          # Update Message answers 204 No Content — the @azure SDK
          # type-asserts 204 (RestError "Unexpected status code" otherwise).
          send_headers(conn, 204, headers)

        {:error, status, code, msg} ->
          blob_error(conn, status, not_found_error(code) |> put_message(msg))
      end
    else
      {:error, reason} ->
        blob_error(conn, 400, %{
          "error" => %{"code" => "InvalidRequestBody", "message" => inspect(reason)}
        })
    end
  end

  defp queue_dispatch(conn, {:delete_message, account}, qp) do
    [queue, _, msg_id] = Enum.drop(conn.path_info, 1)

    case QueueStorage.delete_message(account, queue, msg_id, qp["popreceipt"] || "", qp) do
      {:ok, status, headers} ->
        send_headers(conn, status, headers)

      {:error, status, code, msg} ->
        blob_error(conn, status, not_found_error(code) |> put_message(msg))
    end
  end

  def read_queue_body(conn) do
    case Plug.Conn.read_body(conn) do
      {:ok, body, conn} -> {:ok, body, conn}
      {:error, reason} -> {:error, reason}
    end
  end

  # ---------------------------------------------------------------------------
  # Azure Files plane (capability wave 6, lane w6o) — armed BEFORE the blob
  # splat, queue-plane style: strict query-shape gates (restype=share,
  # restype=directory, comp=list/stats/range/rangelist, x-ms-type: File) so
  # the blob catch-all and every other arm see byte-identical requests.
  # GET /{a}?comp=list (1 segment) is blob List Containers — passes through.
  # ---------------------------------------------------------------------------
  plug(:file_share_plane)

  def file_share_plane(conn, _opts) do
    qp = fetchd_query_params(conn)

    case file_plane_route(conn.method, conn.path_info, qp, conn) do
      nil -> conn
      arm -> run_file_arm(conn, arm, qp)
    end
  end

  def file_plane_route("GET", [], qp, _c) do
    if qp["comp"] == "list", do: {:list_shares, nil}
  end

  def file_plane_route("PUT", [s], qp, _c) do
    if qp["restype"] == "share", do: {:create_share, s}
  end

  def file_plane_route(m, [s], qp, _c) when m in ["GET", "HEAD"] do
    cond do
      qp["comp"] == "stats" and qp["restype"] == "share" -> {:get_share_stats, s}
      qp["comp"] == "list" and qp["restype"] == "directory" -> {:list_dir, s, nil}
      qp["restype"] == "share" -> {:get_share_props, s}
      true -> nil
    end
  end

  def file_plane_route("DELETE", [s], qp, _c) do
    if qp["restype"] == "share", do: {:delete_share, s}
  end

  def file_plane_route("PUT", [s, x | rest], qp, c) do
    cond do
      qp["comp"] == "range" -> {:put_range, s, join_segs([x | rest])}
      qp["restype"] == "directory" -> {:create_dir, s, join_segs([x | rest])}
      get_req_header(c, "x-ms-type") == ["File"] -> {:create_file, s, join_segs([x | rest])}
      true -> nil
    end
  end

  # Reserved first segments (w6bk): data-plane namespaces served by the KV /
  # cosmos / table delegators behind this router. The file plane must never
  # claim paths under them — the unfenced GET catch-all shadowed
  # `GET /keys/:name` into a blob-XML 404 (witnessed by lane w6c on v62).
  @file_reserved_first ~w(dbs keys secrets certificates tables colls users permissions)

  # (w6bl SLA unblock: the file_reserved_first?/1 helper was interleaved here,
  # splitting the file_plane_route/4 clause group and tripping the grouped-
  # clauses warning under --warnings-as-errors; relocated below the catch-all.)

  def file_plane_route("GET", [s, x | rest], qp, _c) do
    if file_reserved_first?(s) do
      nil
    else
      cond do
        qp["comp"] == "list" and qp["restype"] == "directory" ->
          {:list_dir, s, join_segs([x | rest])}

        qp["comp"] == "rangelist" ->
          {:get_range_list, s, join_segs([x | rest])}

        qp["restype"] == "directory" ->
          {:get_dir_props, s, join_segs([x | rest])}

        true ->
          {:get_file, s, join_segs([x | rest])}
      end
    end
  end

  def file_plane_route("HEAD", [s | r], qp, c), do: file_plane_route("GET", [s | r], qp, c)

  def file_plane_route("DELETE", [s, x | rest], qp, _c) do
    if file_reserved_first?(s) do
      nil
    else
      cond do
        qp["restype"] == "directory" -> {:delete_dir, s, join_segs([x | rest])}
        true -> {:delete_file, s, join_segs([x | rest])}
      end
    end
  end

  def file_plane_route(_, _, _, _), do: nil

  def file_reserved_first?(first) when is_binary(first),
    do: String.downcase(URI.decode(first)) in @file_reserved_first

  def join_segs(segs), do: Enum.join(segs, "/")

  def run_file_arm(conn, arm, qp) do
    if not_ready?(conn, [Smalt.DataPlane.FileShare]) do
      route_not_ready(conn)
    else
      file_dispatch(conn, arm, qp)
    end
  end

  def file_dispatch(conn, arm, qp) do
    headers = header_map(conn)

    _ = qp

    case arm do
      {:list_shares, _} ->
        {:ok, st, h, b} = Smalt.DataPlane.FileShare.list_shares()
        send_file_xml(conn, st, h, b)

      {:create_share, s} ->
        case Smalt.DataPlane.FileShare.create_share(s, headers) do
          {:ok, st, h, b} -> send_file_xml(conn, st, h, b)
          {:error, st, code, msg} -> send_file_error(conn, st, code, msg)
        end

      {:get_share_props, s} ->
        case Smalt.DataPlane.FileShare.get_share_properties(s) do
          {:ok, st, h, nil} -> send_file_headers_only(conn, st, h)
          {:error, st, code, msg} -> send_file_error(conn, st, code, msg)
        end

      {:get_share_stats, s} ->
        case Smalt.DataPlane.FileShare.get_share_stats(s) do
          {:ok, st, h, b} -> send_file_xml(conn, st, h, b)
          {:error, st, code, msg} -> send_file_error(conn, st, code, msg)
        end

      {:delete_share, s} ->
        case Smalt.DataPlane.FileShare.delete_share(s) do
          {:ok, st, h, b} -> send_file_xml(conn, st, h, b)
          {:error, st, code, msg} -> send_file_error(conn, st, code, msg)
        end

      {:create_dir, s, p} ->
        case Smalt.DataPlane.FileShare.create_directory(s, p) do
          {:ok, st, h, b} -> send_file_xml(conn, st, h, b)
          {:error, st, code, msg} -> send_file_error(conn, st, code, msg)
        end

      {:get_dir_props, s, p} ->
        case Smalt.DataPlane.FileShare.get_directory_properties(s, p) do
          {:ok, st, h, nil} -> send_file_headers_only(conn, st, h)
          {:error, st, code, msg} -> send_file_error(conn, st, code, msg)
        end

      {:delete_dir, s, p} ->
        case Smalt.DataPlane.FileShare.delete_directory(s, p) do
          {:ok, st, h, b} -> send_file_xml(conn, st, h, b)
          {:error, st, code, msg} -> send_file_error(conn, st, code, msg)
        end

      {:list_dir, s, d} ->
        case Smalt.DataPlane.FileShare.list_dir(s, d, qp["prefix"]) do
          {:ok, st, h, b} -> send_file_xml(conn, st, h, b)
          {:error, st, code, msg} -> send_file_error(conn, st, code, msg)
        end

      {:create_file, s, p} ->
        case Smalt.DataPlane.FileShare.create_file(s, p, headers) do
          {:ok, st, h, b} -> send_file_xml(conn, st, h, b)
          {:error, st, code, msg} -> send_file_error(conn, st, code, msg)
        end

      {:put_range, s, p} ->
        # KD-COVERS: KD-175 (EXPL-9 F2) — the read_body match was unguarded:
        # a >8MB body returned {:more, _, _}, the MatchError escaped the
        # router (no crash-path fence existed), and Bandit rendered a NAKED
        # adapter 500 (empty body, no envelope, no x-ms-request-id). Real
        # Azure answers typed 413 RequestBodyTooLarge; the case below is the
        # canonical blob_block_arm shape (egress_router.ex ~2549).
        case Plug.Conn.read_body(conn, length: 8_000_000, read_length: 1_000_000) do
          {:ok, body, _conn} ->
            case Smalt.DataPlane.FileShare.put_range(s, p, headers, body) do
              {:ok, st, h, b} -> send_file_xml(conn, st, h, b)
              {:error, st, code, msg} -> send_file_error(conn, st, code, msg)
            end

          {:more, partial, _conn} ->
            send_file_error(conn, 413, "RequestBodyTooLarge", file_range_too_large_msg(partial))

          {:error, reason} ->
            send_file_error(conn, 400, "InvalidRequestBody", inspect(reason))
        end

      {:get_range_list, s, p} ->
        case Smalt.DataPlane.FileShare.get_range_list(s, p) do
          {:ok, st, h, b} -> send_file_xml(conn, st, h, b)
          {:error, st, code, msg} -> send_file_error(conn, st, code, msg)
        end

      {:get_file, s, p} ->
        # w6R disclosed unblock (share-existence gate): without it the 3+seg
        # GET/DELETE catch-alls swallow blob-plane requests for absent shares.
        # Absent share -> conn unchanged -> falls through to the blob splat.
        case Smalt.DataPlane.FileShare.get_share_properties(s) do
          {:error, 404, _c, _m} ->
            conn

          _ ->
            case Smalt.DataPlane.FileShare.get_file(s, p, headers) do
              {:ok, st, h, b} -> send_file_bytes(conn, st, h, b)
              {:error, st, code, msg} -> send_file_error(conn, st, code, msg)
            end
        end

      {:delete_file, s, p} ->
        case Smalt.DataPlane.FileShare.get_share_properties(s) do
          {:error, 404, _c, _m} ->
            conn

          _ ->
            case Smalt.DataPlane.FileShare.delete_file(s, p) do
              {:ok, st, h, b} -> send_file_xml(conn, st, h, b)
              {:error, st, code, msg} -> send_file_error(conn, st, code, msg)
            end
        end
    end
  end

  # KD-COVERS: KD-139 — Put Blob without x-ms-blob-type is refused 400
  # MissingRequiredHeader before the body is read (real Azure parity;
  # engine-internal writers bypass this wire guard via BlobStorage.put_blob).
  def ensure_put_blob_type(conn, fun) do
    # BK-132 (v26.10.22): Put Blob From URL (`x-ms-copy-source`) is a distinct
    # operation that does NOT carry x-ms-blob-type — the KD-139 gate stays
    # scoped to plain Put Blob, never a headerless sync-copy refusal.
    copy_from_url? = is_binary(header_map(conn)["x-ms-copy-source"])

    blank? =
      case get_req_header(conn, "x-ms-blob-type") do
        [value] when is_binary(value) -> String.trim(value) == ""
        _ -> not copy_from_url?
      end

    if blank? do
      blob_error(conn, 400, %{
        "error" => %{
          "code" => "MissingRequiredHeader",
          "message" => "An x-ms-blob-type header is required for Put Blob."
        }
      })
    else
      # KD-COVERS: KD-140 — Put Blob without Content-Length answers 411
      # LengthRequired (real Azure requires Content-Length on Put Blob),
      # never a silently admitted 0-byte blob. Scoped to real-wire conns:
      # a synthetic test-adapter conn carries req_body WITHOUT transport
      # headers, so a missing CL there is a harness artifact, not a wire fact.
      # OTP-29 TOOLCHAIN FLOOR: is_integer/3 range guard in
      # content_length_admitted?/1 is OTP-29-only (compile-refused on
      # OTP <= 28). Repo standard toolchain: OTP 29 (TOOLUP).
      case get_req_header(conn, "content-length") do
        [len] when is_binary(len) ->
          case Integer.parse(String.trim(len)) do
            {cl, ""} -> content_length_admitted?(conn, cl, fun)
            # Non-numeric single CL value: admitted exactly as before the
            # guard conversion (transport owns CL grammar; AR-WIRE-02 keeps
            # typed paths unchanged).
            _ -> fun.()
          end

        _ ->
          if elem(conn.adapter, 0) == Plug.Adapters.Test.Conn do
            fun.()
          else
            blob_error(conn, 411, %{
              "error" => %{
                "code" => "LengthRequired",
                "message" => "A Content-Length header is required for Put Blob."
              }
            })
          end
      end
    end
  end

  # Real-Azure Put Blob ceiling: 5000 MiB per blob (block blob Put Blob max).
  @max_put_blob_bytes 5_242_880_000

  # OTP-29 is_integer/3 single-guard head (AR-WIRE-02): a numeric CL in
  # [0, 5000 MiB] is admitted exactly as before; a numeric CL outside the
  # band (negative or above the real-Azure ceiling) now answers the same
  # 411 LengthRequired as a missing CL. Typed 411/201 paths otherwise
  # unchanged.
  defp content_length_admitted?(_conn, cl, fun)
       when int_in(cl, 0, @max_put_blob_bytes),
       do: fun.()

  defp content_length_admitted?(conn, _cl, _fun),
    do:
      blob_error(conn, 411, %{
        "error" => %{
          "code" => "LengthRequired",
          "message" => "A Content-Length header is required for Put Blob."
        }
      })

  def header_map(conn) do
    Enum.reduce(conn.req_headers, %{}, fn {k, v}, acc -> Map.put(acc, k, v) end)
  end

  def send_file_xml(conn, st, h, b) do
    conn
    |> put_resp_headers(h)
    |> put_resp_content_type("application/xml")
    |> send_resp(st, b || "")
  end

  def send_file_bytes(conn, st, h, b) do
    conn
    |> put_resp_headers(h)
    |> send_resp(st, b)
  end

  def send_file_headers_only(conn, st, h) do
    conn
    |> put_resp_headers(h)
    |> send_resp(st, "")
  end

  # EXPL-9 F2 (KD-COVERS: KD-175): oversized Put Range body message.
  defp file_range_too_large_msg(partial) do
    "The request body exceeds the 8,000,000-byte transport cap (read #{byte_size(partial)}+ bytes)."
  end

  def send_file_error(conn, st, code, msg) do
    conn
    |> put_resp_header("x-ms-request-id", generate_request_id())
    |> put_resp_header("x-ms-version", "2021-06-08")
    |> put_resp_header("x-ms-error-code", code)
    |> put_resp_content_type("application/xml")
    |> send_resp(st, error_xml(code, msg))
  end

  def error_xml(code, msg) do
    ~s(<?xml version="1.0" encoding="utf-8"?><Error><Code>) <>
      Smalt.DataPlane.BlobService.xml_escape(code) <>
      "</Code><Message>" <> Smalt.DataPlane.BlobService.xml_escape(msg) <> "</Message></Error>"
  end

  # w6R structural split: the original match chain (112 clauses) exceeded the
  # BEAM per-function implementation limit ('__MODULE__'/1+14). Route arms were
  # relocated verbatim into per-surface fallthrough routers under lib/smalt/egress/.
  # Each delegator passes unmatched conns through un-halted; the blob splat and
  # 404 catch-all below are unchanged and remain LAST (blob catch-all semantics).
  # w6o unblock (compile deadlock): plug(Mod) is resolved at COMPILE time
  # (Plug.Builder invokes Mod.init/1), so referencing the w6R sub-routers
  # here deadlocks against their `import Smalt.EgressRouter`. Resolved at
  # RUNTIME only.
  plug(:w6r_fallthrough)
  plug(:match)
  plug(:dispatch)

  # JA-R1 (V2): the ONLY expected failure class here is an unmatched route
  # clause (FunctionClauseError) — benign fallthrough to the next sub-router.
  # The fallthrough is no longer silent (logged); every other exception class
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
  # w6av: Set Blob Service Properties (?restype=service&comp=properties) —
  # parses the StaticWebsite block into the per-account props ETS. 202 per
  # Azure Set Service Properties parity. Must precede the blob splat.
  put "/:account" do
    if conn.query_params["restype"] == "service" and conn.query_params["comp"] == "properties" do
      blob_route(conn, fn conn ->
        if not_ready?(conn, [BlobStorage]) do
          route_not_ready(conn)
        else
          # EXPL-9 F4 (KD-COVERS: KD-175) — same unguarded read_body escape as
          # the put_range arm; behind the x-ms-version fence, so reaching it
          # needs a valid version header + >8MB body. Same canonical guard.
          case Plug.Conn.read_body(conn, length: 8_000_000, read_length: 1_000_000) do
            {:ok, body, conn} ->
              case BlobStorage.set_service_properties(account, body) do
                :ok ->
                  # w6ay: parse + store the <Cors> rules from the same PUT body
                  # (parity: PUT without a Cors block clears rules).
                  case Smalt.DataPlane.BlobCors.parse_cors_xml(body) do
                    {:error, s, c, m} ->
                      blob_error(conn, s, not_found_error(c) |> put_message(m))

                    rules when is_list(rules) ->
                      case Smalt.DataPlane.BlobCors.put_rules(account, rules) do
                        :ok ->
                          conn
                          |> put_resp_header("x-ms-request-id", generate_request_id())
                          |> put_resp_header("x-ms-version", "2021-12-02")
                          |> send_resp(202, "")

                        {:error, s, c, m} ->
                          blob_error(conn, s, not_found_error(c) |> put_message(m))
                      end
                  end

                {:error, status, code, msg} ->
                  blob_error(conn, status, not_found_error(code) |> put_message(msg))
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

  # ---------------------------------------------------------------------------
  # KD-COVERS: KD-62 — Get User Delegation Key
  # (`POST /{account}?comp=userdelegationkey`)
  # ---------------------------------------------------------------------------
  # Registered close condition (v26.10.14 KD register) admits a
  # "typed-UNSUPPORTED admission seam": the SAS signature-verification face
  # stays explicitly typed (K1's SAS-only refusal already answers before this
  # arm — a sig-only URI gets the typed 401 challenge, never
  # MissingXMsVersion), while this arm answers a typed user-delegation-key
  # envelope backed by REAL service metadata: `value` is a real HMAC-SHA256
  # over a UDK string-to-sign, keyed with the account's storage key — the
  # configured `blob_account_key`, else the deterministic per-account key in
  # the scripts/dev_env.sh derivation shape (sha256(account <> "smalt-dev-sb"),
  # base64). Signed window from the Azure request body (<Start>/<Expiry>
  # XML), defaulting to [now, now+1h].
  # -- KD-62 user-delegation-key internals ------------------------------------

  # Signed window: honour the Azure <Start>/<Expiry> body when present,
  # default [now, now+1h]. Unparsable body elements are ignored (default
  # window) — the window is advisory metadata in the seam, not an admission
  # gate; the signature still folds the emitted window.
  defp udk_window(body) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)
    start = Calendar.strftime(now, "%Y-%m-%dT%H:%M:%SZ")
    expiry = now |> DateTime.add(3600, :second) |> Calendar.strftime("%Y-%m-%dT%H:%M:%SZ")

    case body do
      b when is_binary(b) and b != "" ->
        start_el = Regex.run(~r/<Start>([^<]+)<\/Start>/, b)
        expiry_el = Regex.run(~r/<Expiry>([^<]+)<\/Expiry>/, b)

        {(start_el && List.last(start_el)) || start,
         (expiry_el && List.last(expiry_el)) || expiry}

      _ ->
        {start, expiry}
    end
  end

  # Account key: configured blob_account_key first, else the deterministic
  # per-account dev key (dev_env.sh derivation shape, hostname -> account).
  #
  # KD-114 SharedKey reuse seam (lane W20-B, disclosed minimal edit): the
  # public `account_key/1` is the single derivation — the UDK mint path and
  # `Smalt.Auth.SharedKey` both consume it, no dual truth.
  def account_key(account) do
    case Application.get_env(:smalt, :blob_account_key) ||
           System.get_env("SMALT_BLOB_ACCOUNT_KEY") do
      key when is_binary(key) and key != "" ->
        {:ok, key}

      _ ->
        {:ok, Base.encode64(:crypto.hash(:sha256, account <> "smalt-dev-sb"))}
    end
  end

  defp udk_account_key(account) do
    {:ok, key} = account_key(account)
    key
  end

  defp udk_string_to_sign(account, start, expiry) do
    Enum.join([account, "b", "2021-12-02", start, expiry], "\n")
  end

  get "/:account" do
    cond do
      # w6av: Get Blob Service Properties — echoes the STORED StaticWebsite and
      # <Cors> blocks (element omitted when never enabled). Composed merge:
      # upstream's static-defaults body is superseded by this state-backed echo
      # so the PUT properties arm (set_service_properties) round-trips.
      conn.query_params["restype"] == "service" and conn.query_params["comp"] == "properties" ->
        blob_route(conn, fn conn ->
          if not_ready?(conn, [BlobStorage]) do
            route_not_ready(conn)
          else
            conn
            |> put_resp_header("x-ms-request-id", generate_request_id())
            |> put_resp_header("x-ms-version", "2021-12-02")
            |> put_resp_content_type("application/xml")
            |> send_resp(200, BlobStorage.service_properties_xml(account))
          end
        end)

      conn.query_params["comp"] == "list" ->
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

      true ->
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

        # KD-108: container lease surface (acquire/renew/release/break via
        # x-ms-lease-action). Engine: BlobStorage.lease_container/5 — state
        # rides the container row map; active lease refuses Delete Container
        # 409 ContainerLeased in BlobStorage.delete_container/3.
        conn.query_params["comp"] == "lease" ->
          if not_ready?(conn, [BlobStorage]) do
            route_not_ready(conn)
          else
            case BlobStorage.lease_container(
                   account,
                   container,
                   header_map(conn)["x-ms-lease-action"],
                   header_map(conn)
                 ) do
              {:ok, status, headers, _record} ->
                conn
                |> put_resp_headers(headers)
                |> send_resp(status, "")

              {:error, status, code, msg} ->
                blob_error(conn, status, not_found_error(code) |> put_message(msg))
            end
          end

        # KD-108: container ACL / signed identifiers. PUT -> 204 No Content;
        # GET -> 200 SignedIdentifiers XML (BlobStorage.acl_xml/1).
        conn.query_params["comp"] == "acl" ->
          if not_ready?(conn, [BlobStorage]) do
            route_not_ready(conn)
          else
            case acl_body(conn) do
              {:ok, body, conn} ->
                case BlobStorage.set_container_acl(account, container, body, header_map(conn)) do
                  {:ok, status, headers, _record} ->
                    conn
                    |> put_resp_headers(headers)
                    |> send_resp(status, "")

                  {:error, status, code, msg} ->
                    blob_error(conn, status, not_found_error(code) |> put_message(msg))
                end

              {:error, status, code, msg} ->
                blob_error(conn, status, not_found_error(code) |> put_message(msg))
            end
          end

        conn.query_params["comp"] == "legalhold" ->
          if not_ready?(conn, [BlobStorage]) do
            route_not_ready(conn)
          else
            flag = header_map(conn)["x-ms-legal-hold"] == "true"

            case BlobStorage.set_legal_hold(account, container, flag, header_map(conn)) do
              # Header-only 200 (real-Azure parity): x-ms-legal-hold header,
              # no JSON body. Internal state (policy row) is unchanged.
              {:ok, status, headers, _record} ->
                conn
                |> put_resp_headers(headers)
                |> send_resp(status, "")

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
          # KD-COVERS: KD-135 — Azure parity (official-SDK grounding): a
          # default container is writable; immutability is opted IN via
          # x-ms-immutable-policy (absent or "false" => immutable=false).
          opts = %{
            "immutable" =>
              case get_req_header(conn, "x-ms-immutable-policy") do
                [] -> false
                [v] when is_binary(v) -> v not in ["false", "False"]
                _ -> true
              end
          }

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

              # KD-130: Put Container on an EXISTING container answers
              # 409 ContainerAlreadyExists with the Azure error envelope —
              # real-Azure wire parity that @azure/storage-blob
              # createIfNotExists contractually depends on (the prior
              # 200-empty idempotent re-PUT broke the SDK exists-check).
              # The WORM/lease gates stay AHEAD (container_exists_arm): a
              # hold/locked re-PUT still refuses 409 ContainerLocked per the
              # WORM arms.
              {:error, 409, "ContainerAlreadyExists", _msg} ->
                container_exists_arm(conn, account, container)

              # Cross-lane repair (blob lane cycle-15 §3): typed engine error
              # tuples `{:error, status, code, msg}` from create_container
              # reach the wire at their exact Azure status instead of a
              # blanket 500 — this un-deads blob's container-name-grammar and
              # duplicate-create-409 fences. Non-tuple shapes keep the
              # runtime safety net below.
              {:error, status, code, msg} when is_integer(status) ->
                blob_error(conn, status, not_found_error(code) |> put_message(msg))

              # merge lane (v26.10.28, gate unblock): the former `other ->`
              # 500 safety net was proven unreachable by the Elixir 1.20 type
              # system (create_container/3 is {:ok, map()} |
              # {:error, integer(), binary(), binary()} — both shapes have
              # arms above) and removed under --warnings-as-errors.
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
  def container_reput_arm(conn, account, container) do
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

  # KD-130 arm: re-create on an existing container. WORM/lease gates FIRST
  # (hold or locked-while-retention-live -> 409 ContainerLocked, mirroring
  # the blob-worm invariant posture), then the unconditional Azure error
  # envelope 409 ContainerAlreadyExists. Replaces the idempotent 200-empty
  # re-PUT (container_reput_arm kept for the v26.10.18 burn-corpus fence
  # lineage; no longer on the create path).
  # KD-COVERS: KD-130
  def container_exists_arm(conn, account, container) do
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

      _state ->
        blob_error(conn, 409, %{
          "error" => %{
            "code" => "ContainerAlreadyExists",
            "message" => "The specified container already exists."
          }
        })
    end
  end

  get "/:account/:container" do
    blob_route(conn, fn conn ->
      cond do
        # w6av static website: container-level GET on $web with no query
        # serves the configured index document (root face).
        static_website_gate?(conn, account, container) and conn.query_params == %{} ->
          static_website_render(
            conn,
            BlobStorage.static_website_serve(account, container, nil, %{})
          )

        # R98 fail-closed container comp registration: an unknown comp on the
        # container GET arm would otherwise shadow real Get Container
        # Properties; keep the typed 400.
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

        # KD-108: Get Container ACL — 200 SignedIdentifiers XML.
        conn.query_params["comp"] == "acl" ->
          if not_ready?(conn, [BlobStorage]) do
            route_not_ready(conn)
          else
            case BlobStorage.get_acl(account, container) do
              {:ok, identifiers} ->
                conn
                |> put_resp_header("x-ms-version", "2021-12-02")
                |> put_resp_content_type("application/xml")
                |> send_resp(200, BlobStorage.acl_xml(identifiers))

              {:error, :container_not_found} ->
                blob_error(conn, 404, %{
                  "error" => %{"code" => "ContainerNotFound", "message" => "Container not found."}
                })
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
      # KD-108 (blob lane remainder): snapshot lease wire arm —
      # PUT ?comp=lease&sharesnapshot=<ts> with x-ms-lease-action rides the
      # FROZEN snapshot record (BlobStorage.lease_blob_snapshot/6, per-snapshot
      # lease id namespace). Runs BEFORE the fail-closed comp registration so
      # the implemented pair (comp=lease AND sharesnapshot) is never eaten by
      # the 400 default-deny; comp=lease WITHOUT sharesnapshot stays
      # default-deny (400 GAP) until the base-blob lease surface registers.
      if conn.query_params["comp"] == "lease" and
           conn.query_params["sharesnapshot"] not in [nil, ""] do
        if not_ready?(conn, [BlobStorage]) do
          route_not_ready(conn)
        else
          case BlobStorage.lease_blob_snapshot(
                 account,
                 container,
                 blob_name,
                 conn.query_params["sharesnapshot"],
                 header_map(conn)["x-ms-lease-action"],
                 header_map(conn)
               ) do
            {:ok, status, headers, _record} ->
              conn
              |> put_resp_headers(headers)
              |> send_resp(status, "")

            {:error, status, code, msg} ->
              blob_error(conn, status, not_found_error(code) |> put_message(msg))
          end
        end
      else
        # w6aw: Undelete Blob — PUT ?comp=undelete restores the most recent
        # soft-deleted instance of the blob (delete-retention must be enabled;
        # unknown/purged → typed 404 BlobNotFound).
        if conn.query_params["comp"] == "undelete" do
          if not_ready?(conn, [BlobStorage]) do
            route_not_ready(conn)
          else
            case Smalt.DataPlane.BlobSoftDelete.undelete_blob(account, container, blob_name) do
              {:ok, status, headers, _} ->
                conn
                |> put_resp_headers(headers)
                |> send_resp(status, "")

              {:error, status, code, msg} ->
                blob_error(conn, status, not_found_error(code) |> put_message(msg))
            end
          end
        else
          # BK-132 (corpus triage): Set Blob Tier direct wire arm — `PUT ?comp=tier`
          # + `x-ms-access-tier`. The engine (BlobStorage.set_blob_tier/5) and the
          # $batch sub-request arm existed; the direct arm was MISSING, so a real
          # `az storage blob set-tier` got the typed-400 default-deny. 202 per
          # Azure Set Blob Tier parity (az accepts 200/201/202).
          if conn.query_params["comp"] == "tier" do
            if not_ready?(conn, [BlobStorage]) do
              route_not_ready(conn)
            else
              case BlobStorage.set_blob_tier(
                     account,
                     container,
                     blob_name,
                     header_map(conn)["x-ms-access-tier"]
                   ) do
                {:ok, status, headers, _} ->
                  conn |> put_resp_headers(headers) |> send_resp(status, "")

                {:error, status, code, msg} ->
                  blob_error(conn, status, not_found_error(code) |> put_message(msg))
              end
            end
          else
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
                      case BlobStorage.snapshot_blob(
                             account,
                             container,
                             blob_name,
                             header_map(conn)
                           ) do
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
                    # Parity lane 2026-10-28: base-blob lease (comp=lease WITHOUT
                    # sharesnapshot; the snapshot variant is handled above). Header-only
                    # request — no body read. x-ms-lease-action drives the state machine.
                    if conn.query_params["comp"] == "lease" do
                      if not_ready?(conn, [BlobStorage]) do
                        route_not_ready(conn)
                      else
                        case BlobStorage.lease_blob(
                               account,
                               container,
                               blob_name,
                               header_map(conn)["x-ms-lease-action"],
                               header_map(conn)
                             ) do
                          {:ok, status, headers, _record} ->
                            conn
                            |> put_resp_headers(headers)
                            |> send_resp(status, "")

                          {:error, status, code, msg} ->
                            blob_error(conn, status, not_found_error(code) |> put_message(msg))
                        end
                      end
                    else
                      # Parity lane 2026-10-28: Set Blob HTTP Headers (comp=properties).
                      # Header-only request — no body read. 200 with the rotated etag.
                      if conn.query_params["comp"] == "properties" do
                        if not_ready?(conn, [BlobStorage]) do
                          route_not_ready(conn)
                        else
                          case BlobStorage.set_blob_http_headers(account, container, blob_name, header_map(conn)) do
                            {:ok, status, headers, _record} ->
                              conn
                              |> put_resp_headers(headers)
                              |> send_resp(status, "")

                            {:error, status, code, msg} ->
                              blob_error(conn, status, not_found_error(code) |> put_message(msg))
                          end
                        end
                      else
                        # Parity lane 2026-10-28: Append Block (comp=appendblock) and Put
                        # Page (comp=page) — body-carrying writes through the same
                        # read_body discipline as the generic Put Blob fallback.
                        if conn.query_params["comp"] in ["appendblock", "page"] do
                          if not_ready?(conn, [BlobStorage]) do
                            route_not_ready(conn)
                          else
                            case Plug.Conn.read_body(conn, length: 8_000_000, read_length: 1_000_000) do
                              {:ok, body, _conn} ->
                                if conn.query_params["comp"] == "appendblock" do
                                  case BlobStorage.append_block(account, container, blob_name, body, header_map(conn)) do
                                    {:ok, status, headers, _record} ->
                                      conn |> put_resp_headers(headers) |> send_resp(status, "")

                                    {:error, :worm_locked, _nil, msg} ->
                                      blob_error(conn, 409, %{
                                        "error" => %{"code" => "ContainerLocked", "message" => msg}
                                      })

                                    {:error, status, code, msg} ->
                                      blob_error(conn, status, not_found_error(code) |> put_message(msg))
                                  end
                                else
                                  case BlobStorage.put_page(account, container, blob_name, body, header_map(conn)) do
                                    {:ok, status, headers, _record} ->
                                      conn |> put_resp_headers(headers) |> send_resp(status, "")

                                    {:error, :worm_locked, _nil, msg} ->
                                      blob_error(conn, 409, %{
                                        "error" => %{"code" => "ContainerLocked", "message" => msg}
                                      })

                                    {:error, status, code, msg} ->
                                      blob_error(conn, status, not_found_error(code) |> put_message(msg))
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
                        else
                          # KD-COVERS: KD-139 — real Azure requires x-ms-blob-type on Put
                          # Blob; a headerless PUT answers 400 MissingRequiredHeader, never
                          # a silently admitted blob (census W30-D parity fix).
                          ensure_put_blob_type(conn, fn ->
                      # BK-132 (corpus triage): Sync Copy Blob — `PUT /{c}/{b}` +
                      # `x-ms-copy-source` (Put Blob From URL). Previously the header
                      # was ignored and the (usually empty) body stored as content.
                      if source = header_map(conn)["x-ms-copy-source"] do
                        if not_ready?(conn, [BlobStorage]) do
                          route_not_ready(conn)
                        else
                          case BlobStorage.copy_blob(
                                 account,
                                 container,
                                 blob_name,
                                 source,
                                 header_map(conn)
                               ) do
                            {:ok, 202, headers, nil} ->
                              conn |> put_resp_headers(headers) |> send_resp(202, "")

                            {:error, status, code, msg} ->
                              blob_error(conn, status, not_found_error(code) |> put_message(msg))
                          end
                        end
                      else
                        case Plug.Conn.read_body(conn, length: 8_000_000, read_length: 1_000_000) do
                          {:ok, raw_body, conn} ->
                            # w6aw: blob versioning — freeze the prior record as a
                            # version before the overwrite (no-op when versioning is
                            # off; freezing failure never blocks the write).
                            Smalt.DataPlane.BlobSoftDelete.intercept_put(
                              account,
                              container,
                              blob_name
                            )

                            case BlobStorage.put_blob(
                                   account,
                                   container,
                                   blob_name,
                                   raw_body,
                                   header_map(conn)
                                 ) do
                              {:ok, blob} ->
                                # KD-COVERS: KD-145 — real Azure answers Put Blob with a
                                # 201 and an EMPTY body (Content-Length: 0); the old arm
                                # emitted a non-spec JSON metadata projection.
                                # Azure Storage Put Blob returns x-ms-request-server-encrypted
                                # on every write op to confirm server-side encryption; the
                                # emulator's data plane is server-encrypted by construction.
                                conn
                                |> put_resp_header("etag", blob["etag"])
                                |> put_resp_header(
                                  "last-modified",
                                  blob["last_modified"]
                                  |> DateTime.from_iso8601()
                                  |> elem(1)
                                  |> Calendar.strftime("%a, %d %b %Y %H:%M:%S GMT")
                                )
                                |> put_resp_header("x-ms-request-server-encrypted", "true")
                                |> send_resp(201, "")

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
                                blob_error(
                                  conn,
                                  status,
                                  not_found_error(code) |> put_message(msg)
                                )
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
                              "error" => %{
                                "code" => "InvalidRequestBody",
                                "message" => inspect(reason)
                              }
                            })
                        end
                      end
                    end)
                  end
                end
              end
            end
            end
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
                |> put_resp_headers(BlobStorage.tier_wire(blob))
                |> put_resp_headers(BlobStorage.copy_wire(blob))
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
                  # w6av static website: missing blob under $web serves the
                  # configured 404 doc (or plain 404).
                  if static_website_gate?(conn, account, container) do
                    static_website_render(
                      conn,
                      BlobStorage.static_website_serve(account, container, blob_name, %{})
                    )
                  else
                    blob_error(conn, 404, not_found_error("BlobNotFound"))
                  end

                {:ok, _blob} ->
                  case BlobStorage.get_blob_range(account, container, blob_name, range_header) do
                    {:ok, blob, nil} ->
                      conn
                      |> put_resp_headers(stored_meta_wire(blob))
                      |> put_resp_headers(BlobStorage.tier_wire(blob))
                      |> put_resp_headers(BlobStorage.copy_wire(blob))
                      |> put_resp_header("etag", blob["etag"])
                      |> put_resp_header(
                        "content-length",
                        blob["content"] |> byte_size() |> Integer.to_string()
                      )
                      |> put_resp_content_type(stored_content_type(blob))
                      |> send_resp(200, blob["content"])

                    {:ok, blob, {first, last}} ->
                      body = binary_part(blob["content"], first, last - first + 1)

                      # KD-COVERS: KD-66 — x-ms-range-get-content-md5:true on a
                      # single ranged GET now answers Content-MD5 (base64 MD5 of
                      # the returned range bytes), matching Azure Get Blob range
                      # semantics; without the request header the wire is unchanged.
                      conn =
                        if comp_str(get_req_header(conn, "x-ms-range-get-content-md5")) in [
                             "true",
                             "True"
                           ] do
                          put_resp_header(
                            conn,
                            "content-md5",
                            :crypto.hash(:md5, body) |> Base.encode64()
                          )
                        else
                          conn
                        end

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
                      |> put_resp_content_type(stored_content_type(blob))
                      |> send_resp(206, body)

                    {:error, :range_not_satisfiable, total} ->
                      # KD-COVERS: KD-137 — 416 carries x-ms-error-code:
                      # InvalidRange plus the StorageError XML envelope on the
                      # blob face (blob_error renders XML when :smalt_blob_face).
                      conn
                      |> put_resp_header("content-range", "bytes */#{total}")
                      |> blob_error(416, %{
                        "error" => %{
                          "code" => "InvalidRange",
                          "message" =>
                            "The range specified is invalid for a blob of #{total} bytes."
                        }
                      })

                    :error ->
                      # w6av static website: missing content blob under $web
                      # serves the configured 404 doc (or plain 404).
                      if static_website_gate?(conn, account, container) do
                        static_website_render(
                          conn,
                          BlobStorage.static_website_serve(account, container, blob_name, %{})
                        )
                      else
                        blob_error(conn, 404, not_found_error("BlobNotFound"))
                      end
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
                     |> put_resp_content_type(stored_content_type(blob))
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

  # w6av static-website serving helpers (Azure $web static-site class).
  defp static_website_gate?(
         conn,
         account,
         container
       ) do
    not not_ready?(conn, [BlobStorage]) and
      website_enabled?(account) and
      container == BlobStorage.static_website_container()
  end

  defp website_enabled?(account) do
    case BlobStorage.website_props(account) do
      %{"enabled" => true} -> true
      _ -> false
    end
  end

  defp static_website_render(conn, {:serve, blob, ctype}) do
    conn
    |> put_resp_header("x-ms-request-id", generate_request_id())
    |> put_resp_header("x-ms-version", "2021-12-02")
    |> put_resp_content_type(ctype)
    |> send_resp(200, blob["content"])
  end

  defp static_website_render(conn, {:serve_404, blob}) do
    render_404_doc(conn, blob)
  end

  defp static_website_render(conn, {:plain_404, msg}) do
    blob_error(conn, 404, not_found_error("BlobNotFound") |> put_message(msg))
  end

  defp render_404_doc(conn, blob) do
    conn
    |> put_resp_header("x-ms-request-id", generate_request_id())
    |> put_resp_header("x-ms-version", "2021-12-02")
    |> put_resp_content_type(content_type_from_blob(blob))
    |> send_resp(404, blob["content"])
  end

  defp content_type_from_blob(blob) do
    blob["headers"]["content-type"] || "application/octet-stream"
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
                |> put_resp_headers(BlobStorage.tier_wire(blob))
                |> put_resp_headers(BlobStorage.copy_wire(blob))
                |> put_resp_header("etag", blob["etag"])
                |> put_resp_header("x-ms-request-id", generate_request_id())
                |> put_resp_header(
                  "content-length",
                  blob["content"] |> byte_size() |> Integer.to_string()
                )
                |> put_resp_content_type(stored_content_type(blob))
                |> send_resp(200, "")

              {:ok, blob, {first, last}} ->
                conn
                |> put_resp_headers(stored_meta_wire(blob))
                |> put_resp_headers(BlobStorage.tier_wire(blob))
                |> put_resp_headers(BlobStorage.copy_wire(blob))
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
                |> put_resp_content_type(stored_content_type(blob))
                |> send_resp(206, "")

              {:error, :range_not_satisfiable, total} ->
                # KD-COVERS: KD-137 — same envelope as the GET range arm above.
                conn
                |> put_resp_header("content-range", "bytes */#{total}")
                |> blob_error(416, %{
                  "error" => %{
                    "code" => "InvalidRange",
                    "message" => "The range specified is invalid for a blob of #{total} bytes."
                  }
                })

              :error ->
                blob_error(conn, 404, not_found_error("BlobNotFound"))
            end
        end
      end
    end)
  end

  delete "/:account/:container" do
    blob_route(conn, fn conn ->
      # w6d (v26.10.20): Delete Immutability Policy — DELETE ?comp=immutabilityPolicy
      # on the container arm. Engine: BlobStorage.delete_immutability_policy/4 —
      # 404 ImmutabilityPolicyNotFound when absent, 409 ContainerLocked while the
      # policy is locked (real Azure: a locked policy cannot be deleted), 200 on
      # success. Sibling policy-row keys (legal_hold, metadata) survive.
      cond do
        unhandled_comp?(conn, ["immutabilityPolicy", "immutabilitypolicy"]) ->
          unhandled_container_comp_error(conn, conn.query_params["comp"])

        conn.query_params["comp"] in ["immutabilityPolicy", "immutabilitypolicy"] ->
          if not_ready?(conn, [BlobStorage]) do
            route_not_ready(conn)
          else
            case BlobStorage.delete_immutability_policy(account, container, header_map(conn)) do
              {:ok, status, headers, _record} ->
                conn
                |> put_resp_headers(headers)
                |> send_resp(status, "")

              {:error, status, code, msg} ->
                blob_error(conn, status, not_found_error(code) |> put_message(msg))
            end
          end

        true ->
          case BlobStorage.delete_container(account, container, header_map(conn)) do
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
        # w6aw: delete-retention interception — when a delete-retention policy
        # is enabled for the account, Delete Blob parks the record instead of
        # hard-deleting (the parked row answers List include=deleted and
        # Undelete Blob).
        case Smalt.DataPlane.BlobSoftDelete.intercept_delete(account, container, blob_name) do
          {:soft, result} ->
            case result do
              {:ok, status, headers, _} ->
                conn
                |> put_resp_headers(headers)
                |> send_resp(status, "")

              {:error, status, code, msg} ->
                blob_error(conn, status, not_found_error(code) |> put_message(msg))
            end

          :pass ->
            case BlobStorage.delete_blob(account, container, blob_name, header_map(conn)) do
              {:ok, status, headers, _record} ->
                conn
                |> put_resp_headers(headers)
                |> send_resp(status, "")

              {:error, status, code, msg} ->
                blob_error(conn, status, not_found_error(code) |> put_message(msg))
            end
        end
      end
    end)
  end

  # ---------------------------------------------------------------------------
  # KD-COVERS: KD-61 — route + multipart arm landed; 202 batched response
  # witnessed live (docs/jira/v26.10.20/receipts/kd61-blob-batch-witness.md).
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
      cond do
        conn.query_params["comp"] == "batch" ->
          if not_ready?(conn, [BlobStorage]) do
            route_not_ready(conn)
          else
            blob_batch_arm(conn, account)
          end

        # KD-COVERS: KD-62 — Get User Delegation Key. The registered close
        # condition admits a "typed-UNSUPPORTED admission seam": the SAS
        # signature-verification face stays explicitly typed (K1's SAS-only
        # refusal answers before this arm — a sig-only URI gets the typed 401
        # challenge, never MissingXMsVersion), while this arm answers a typed
        # user-delegation-key envelope backed by REAL service metadata:
        # `value` is a real HMAC-SHA256 over a UDK string-to-sign keyed with
        # the account's storage key (configured `blob_account_key`, else the
        # deterministic per-account dev key in the scripts/dev_env.sh
        # derivation shape sha256(account <> "smalt-dev-sb") base64). Signed
        # window from the Azure <Start>/<Expiry> body, default [now, now+1h].
        conn.query_params["comp"] == "userdelegationkey" ->
          if not_ready?(conn, [BlobStorage]) do
            route_not_ready(conn)
          else
            # Body-seam note (same shape as the KD-108 acl_body seam): the
            # request body may already be consumed by Plug.Parsers — read the
            # raw cache first, fall back to the stream.
            {:ok, body, conn} = acl_body(conn)
            {start, expiry} = udk_window(body)
            key = udk_account_key(account)
            oid = "00000000-0000-0000-0000-000000000001"

            value =
              :crypto.mac(:hmac, :sha256, key, udk_string_to_sign(account, start, expiry))
              |> Base.encode64()

            conn
            |> put_resp_header("x-ms-request-id", generate_request_id())
            |> put_resp_header("x-ms-version", "2021-12-02")
            |> put_resp_content_type("application/json")
            |> send_resp(
              200,
              Jason.encode!(%{
                "signedObject" => %{
                  "account" => account,
                  "service" => "b",
                  "version" => "2021-12-02"
                },
                "tenant" => "00000000-0000-0000-0000-000000000000",
                "user" => oid,
                "delegatedUser" => oid,
                "issuedTo" => "127.0.0.1",
                "value" => value,
                "expiry" => expiry
              })
            )
          end

        true ->
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
  def blob_block_arm(conn, account, container, blob_name) do
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
  def commit_response(account, container, blob_name, refs, headers) do
    case BlobStorage.commit_block_list(account, container, blob_name, refs, headers) do
      {:ok, status, headers} -> {:ok, status, headers}
      {:error, :worm_locked, msg} -> {:error, :worm_locked, msg}
      {:error, :precondition_failed, msg} -> {:error, :precondition_failed, msg}
      {:error, status, code, msg} when is_integer(status) -> {:error, status, code, msg}
    end
  end

  # Trailing-slash tolerance for the Cosmos surface only (blob catch-all
  # depends on exact path shape; other services unchanged).
  def trim_dbs_trailing_slash(%Plug.Conn{path_info: ["dbs" | rest]} = conn, _opts) do
    if rest != [] and List.last(rest) == "" do
      %{conn | path_info: List.delete_at(conn.path_info, -1)}
    else
      conn
    end
  end

  def trim_dbs_trailing_slash(conn, _opts), do: conn

  # Body parsing is route-conditional. Plug.Parsers CONSUMES the request body
  # for json/urlencoded content-types, which would leave the raw blob PUT
  # (PUT /:account/:container/:blob) with an empty stream — an urlencoded
  # content-type used to store a zero-byte blob. Blob PUTs without a `comp`
  # query parameter are therefore exempted from parsing; the handler reads the
  # raw body itself. Every other request is parsed exactly as before.
  # AR-WIRE-01: JSON decode rides the JsonCompat engine seam (native :json when
  # available, Jason fallback; null normalized to nil).
  @parsers_opts parsers: [:json, :urlencoded],
                pass: ["*/*"],
                json_decoder: {Smalt.JsonCompat, :decode!, []}

  def maybe_parse_body(conn, _opts) do
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
  # w6c: /certificates/issuers/:name is a literal 3-segment PUT route (issuer
  # create-or-replace) — per the whitelist law above, adding it REQUIRES this
  # entry or the body is left unparsed (raw blob content) and the route's
  # with_valid_body gate answers 400 InvalidBody (measured on the w6c wire
  # witness, block v62, 2026-10-20).
  # KD-COVERS: KD-12 — "keys" (and "managedstorage") must parse JSON bodies on
  # multi-segment PUTs. The raw-PUT blob exemption skipped Plug.Parsers for EVERY
  # 3+-segment PUT whose first segment was not in this list, so
  # PUT /keys/:name/rotationpolicy and PUT /managedstorage/:name/sas/:sasdef
  # reached their handlers with %Plug.Conn.Unfetched{} body_params and answered
  # a lying 400 "requires a lifetimeActions array" to every valid SDK body
  # (witnessed on a private-bandit seat 2026-10-20, lane K3).
  @non_blob_put_namespaces ~w(dbs certificates keys managedstorage)

  # Decoded-to-decoded invariant (lane R154): Plug path_info segments are RAW
  # (R137 finding), so a percent-encoded first segment (`PUT /%64bs/...` ==
  # `/dbs/...`) matched the raw set, was exempted from nothing, and got its
  # urlencoded body parsed as blob content before the decoded reserved fence
  # refused. Decode first, then match — mirroring the fence's decode-aware
  # pattern. Decoded names behave unchanged.
  def raw_blob_put?(%Plug.Conn{method: "PUT", path_info: [first, _, _ | _]} = conn) do
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
  def raw_blob_put?(%Plug.Conn{method: "PUT", path_info: [first, _container]} = conn) do
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
  def raw_blob_put?(%Plug.Conn{method: "PUT", path_info: [_account]} = conn) do
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
  def raw_blob_put?(%Plug.Conn{method: "POST", path_info: [_account, _queue, "messages"]}),
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
  def raw_blob_put?(%Plug.Conn{method: m, path_info: ["saas" | _]})
      when m in ["POST", "PATCH"],
    do: true

  def raw_blob_put?(_conn), do: false

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
    not Enum.all?(modules, &Code.ensure_loaded?/1) or not tables_ready?(Smalt.Store.table_names())
  end

  def route_not_ready(conn) do
    # R50 repair 1: the 503 answers with blob_error-style header discipline
    # (x-ms-request-id + x-ms-version) — real Azure stamps request-id on
    # error responses, not only on the blob_error-rendered ones.
    conn
    |> put_resp_header("x-ms-request-id", generate_request_id())
    |> put_resp_header("x-ms-version", "2021-12-02")
    # T30-F2 hint-parity: real Azure Blob/Queue 503s carry `Retry-After`
    # (seconds); azure-core retries 503 on exponential backoff but honors the
    # hint when present. Fixed 1s — the Store subtree only needs a bounded
    # restart beat (same hint as the ARM 429/503 faces).
    |> put_resp_header("retry-after", "1")
    |> send_json(503, %{"error" => %{"code" => "RouteNotReady"}})
  end

  # R143 (GAP S8): real AKV requires ?api-version=7.x on every request. A
  # missing/wrong version is a typed 400 InvalidApiVersion before any key or
  # policy lookup. The gate lives at the router seam (route handler is the
  # only place `conn` query params are visible to the SKR flow).
  # AZB-08 config read site: the pinned 7.x grammar stays (wire-compat), but
  # the example version in the refusal message is the configured
  # `:keyvault, api_version` (default "7.4") — single source, no dual truth.
  # KD-COVERS: KD-34 — the gate reads the DECODED "api-version" key: Plug's
  # query decoder resolves the SDK 4.10 percent-encoded form (`api%2Dversion`)
  # to the same key, so encoded-hyphen SDK requests are admitted by parity
  # (wire witness: api%2Dversion=7.4 passes; api%2Dversion=2099-01-01 -> 400
  # InvalidApiVersion, kd11-kd16-kd17-kd33-kd34-kv-wire-witness.md).
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

  # R99: known other-plane namespaces that must never reach the blob splat
  # arms (see reserved_fence_then below).
  # (attribute defined textually above, with the blob comp whitelists)

  # Blob catch-all guard: require x-ms-version header, or the host must be
  # configured in :smalt, :blob_catch_all_hosts.
  def blob_route(conn, fun) do
    # B-XML (GAP(blob-error-envelope-json) close): stamp the blob face so
    # blob_error/3 renders the Azure Storage XML error envelope on this face
    # only — ARM/Cosmos/KV/AppConfig/Ledger consumers keep JSON byte-identical.
    conn = put_private(conn, :smalt_blob_face, true)

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

  def blob_route_guarded(conn, fun) do
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

      {:error, :ip_mismatch} ->
        # Signed IP constraint (sip) does not cover the request source —
        # real Azure parity: 403 AuthorizationSourceIPMismatch (w6bf).
        conn
        |> put_resp_header("x-ms-version", "2021-12-02")
        |> put_resp_header("x-ms-request-id", generate_request_id())
        |> put_resp_header("x-ms-error-code", "AuthorizationSourceIPMismatch")
        |> send_json(403, %{
          "error" => %{
            "code" => "AuthorizationSourceIPMismatch",
            "message" =>
              "This request is not authorized to perform this operation because the source IP is not within the signed IP range."
          }
        })
        |> halt()

      {:error, :protocol_mismatch} ->
        # Signed protocol constraint (spr) does not admit the request
        # scheme — real Azure parity: 403 AuthorizationProtocolMismatch (w6bf).
        conn
        |> put_resp_header("x-ms-version", "2021-12-02")
        |> put_resp_header("x-ms-request-id", generate_request_id())
        |> put_resp_header("x-ms-error-code", "AuthorizationProtocolMismatch")
        |> send_json(403, %{
          "error" => %{
            "code" => "AuthorizationProtocolMismatch",
            "message" =>
              "This request is not authorized to perform this operation because the signed protocol does not permit this scheme."
          }
        })
        |> halt()

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
  def plausible_x_ms_version?(conn) do
    case get_req_header(conn, "x-ms-version") do
      [value] when is_binary(value) -> plausible_version_value?(value)
      _ -> false
    end
  end

  # KD-COVERS: KD-67 — x-ms-version is grammar-validated, not presence-only:
  # a single header whose trimmed value is `YYYY-MM-DD` and parses as a real
  # calendar date. Garbage ("garbage-version", "2026-13-45") 400s
  # MissingXMsVersion at the blob admission guard instead of reaching the
  # blob splat arms.
  defp plausible_version_value?(value) do
    trimmed = String.trim(value)
    regex = Regex.match?(~r/^\d{4}-\d{2}-\d{2}$/, trimmed)

    parsed =
      case trimmed do
        <<_y::binary-size(4), "-", _mo::binary-size(2), "-", _d::binary-size(2)>> ->
          match?(:ok, elem(Date.from_iso8601(trimmed), 0))

        _ ->
          false
      end

    regex and parsed
  end

  def run_guarded(conn, fun, allowed_hosts) do
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

  def run_guarded(conn, :sas_admitted, fun, _allowed_hosts) do
    if not_ready?(conn, [BlobStorage]) or
         not tables_ready?([:smalt_blobs, :smalt_blob_containers, :smalt_blob_policy]) do
      route_not_ready(conn)
    else
      reserved_fence_then(conn, fun)
    end
  end

  # R124: catch-all tag arm kept adjacent to the :sas_admitted clause so
  # run_guarded/4 stays clause-cohesive (kills the compiler's clause-grouping warning).
  def run_guarded(conn, _tag, fun, allowed_hosts) do
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
  def reserved_fence_then(conn, fun) do
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
  def reserved_namespace_refusal(conn, ns) when ns in ~w(secrets certificates keys) do
    send_json(conn, 404, %{
      "error" => %{
        "code" => "NotFound",
        "message" =>
          "#{conn.method} #{conn.request_path} is not implemented on this plane " <>
            "(reserved namespace '#{ns}'); nothing was stored."
      }
    })
  end

  def reserved_namespace_refusal(conn, ns) do
    send_json(conn, 400, %{
      "code" => "NotImplemented",
      "message" =>
        "#{conn.method} #{conn.request_path} is not implemented on this plane " <>
          "(reserved namespace '#{ns}'); nothing was stored."
    })
  end

  # w6R: public accessor + delegator fallback. A request matching no clause in
  # its delegator gets the same tail semantics the original single-chain router
  # gave it: a reserved-namespace shape → typed reserved-namespace refusal;
  # any other residual shape → the original 404 catch-all JSON envelope.
  def reserved_first_segments, do: @reserved_first_segments

  def splat_fallback(conn) do
    ns =
      case conn.path_info do
        [first | _] -> String.downcase(URI.decode(first))
        _ -> nil
      end

    if is_binary(ns) and ns in reserved_first_segments() do
      reserved_namespace_refusal(conn, ns)
    else
      blob_error(conn, 404, %{
        "error" => %{
          "code" => "RouteNotFound",
          "message" => "No route matches #{conn.method} #{conn.request_path}"
        }
      })
    end
  end

  # ---------------------------------------------------------------------------
  # Blob Batch (GAP-AUD1-02): multipart/mixed parse → per-sub-request dispatch
  # → multipart/mixed response. Only Delete Blob and Set Blob Tier are
  # dispatched (the two operations real Azure's batch plane accepts); any
  # other sub-request → per-sub-request 400, never a silent skip. Bounded at
  # 256 sub-requests (real Azure's cap).
  # ---------------------------------------------------------------------------

  @batch_max_subrequests 256

  def blob_batch_arm(conn, account) do
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

  def batch_boundary(conn) do
    with [ct] <- get_req_header(conn, "content-type"),
         segments = Enum.map(String.split(ct, ";"), &String.trim/1),
         true <- hd(segments) |> String.downcase() == "multipart/mixed",
         boundary when is_binary(boundary) <- find_boundary(segments) do
      {:ok, String.trim(boundary, "\"")}
    else
      _ -> :error
    end
  end

  def find_boundary(segments) do
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
  def parse_batch_parts(body, boundary) do
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
  def strip_part_headers(chunk) do
    case :binary.split(normalize_crlf(chunk), "\r\n\r\n") do
      [_, sub_request] -> String.trim_leading(sub_request, "\r\n")
      [_] -> chunk
    end
  end

  def send_batch_response(conn, _account, parts) do
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

  def render_batch_part(idx, status, headers, body, boundary) do
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

  def plug_status_reason(status) do
    Plug.Conn.Status.reason_phrase(status)
  end

  # Dispatches one sub-request. Supported: Delete Blob, Set Blob Tier.
  # Returns {status, headers_list, body_string_or_empty}.
  def dispatch_batch_subrequest(sub_request, _idx) do
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

  def batch_dispatch_op("DELETE", [account, container | blob_segments], _query, headers) do
    blob_name = Enum.join(blob_segments, "/")

    case BlobStorage.delete_blob(account, container, blob_name, headers) do
      {:ok, status, headers, _record} ->
        {status, Map.to_list(headers), ""}

      {:error, status, code, msg} ->
        {status, [{"x-ms-error-code", code}], batch_error_body(code, msg)}
    end
  end

  def batch_dispatch_op(
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

  def batch_dispatch_op(_method, _segments, _query, _headers) do
    {400, [{"x-ms-error-code", "InvalidOperation"}],
     batch_error_body("InvalidOperation", "Unsupported batch sub-request operation.")}
  end

  def batch_error_body(code, msg) do
    Jason.encode!(%{"error" => %{"code" => code, "message" => msg}})
  end

  # Parses an HTTP sub-request: "METHOD /path?query HTTP/1.1" + headers
  # [+ body]. Returns {method, target, headers_map, body} or :error.
  def parse_sub_request(sub) do
    case :binary.split(sub, "\r\n\r\n") do
      [head, body] -> parse_sub_head(head, body)
      [_] -> parse_sub_head(sub, "")
    end
  end

  # R67: same LF normalization for the sub-request head itself (request line +
  # header lines), so an LF-only sub-request inside an otherwise-CRLF part parses.
  def parse_sub_head(head, body) do
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
  def normalize_crlf(bin) do
    bin
    |> String.replace("\r\n", "\n")
    |> String.replace("\n", "\r\n")
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

  def decode_batch(raw) do
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
  def with_valid_body(conn, fun) do
    if valid_json_body?(conn.body_params) do
      safe_dispatch(conn, fun)
    else
      send_json(conn, 400, invalid_body_error())
    end
  end

  def valid_json_body?(%Plug.Conn.Unfetched{}), do: false

  # Plug.Parsers wraps a decoded non-map JSON body (null / scalar / top-level
  # array on older Plug) as %{"_json" => term}. Admitting that wrapper let
  # `POST /app/transactions` with body `null` or `5` append a garbage ledger
  # entry (measured 201). The only legitimate wrapped form on this surface is
  # the batch list (Sentinel/events unwrap it downstream), so refuse the
  # wrapper unless the wrapped value is a list.
  def valid_json_body?(%{"_json" => wrapped}) when not is_list(wrapped), do: false

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
  def valid_json_body?(params) when params == %{}, do: false

  def valid_json_body?(params) when is_map(params) or is_list(params), do: true
  def valid_json_body?(_other), do: false

  def invalid_body_error do
    %{"error" => %{"code" => "InvalidBody"}}
  end

  # Belt-and-braces: even with the seam guard, a malformed parameter that
  # slips through to a callee (ConfidentialLedger.canonical/1,
  # Cosmos.quoted_sha256/1, ...) must degrade to a 400 envelope, never a 500.
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

  def eg_cloudevents_post(conn, topic) do
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
  def eg1_decode_events(conn) do
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

  def eg1_wrap(payload) when is_list(payload), do: payload
  def eg1_wrap(payload), do: [payload]

  def invalid_eg1_event_error do
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
  def respond_published(conn, topic, events) do
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

  def invalid_cloudevent_error do
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

  def decode_events(conn) do
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

  def decode_events_payload(raw) do
    case Jason.decode(raw) do
      {:ok, payload} -> {:ok, wrap_json_list(%{"_json" => payload})}
      {:error, _} -> {:error, :invalid_cloudevent}
    end
  end

  # Binary mode: ce-* headers carry the context attributes, the body is the
  # event data. Requires ce-specversion plus at least one of ce-source/ce-type.
  def binary_mode_headers?(conn) do
    ce_headers = ce_attributes(conn)

    is_binary(ce_headers["specversion"]) and
      (is_binary(ce_headers["source"]) or is_binary(ce_headers["type"]))
  end

  def binary_mode_event(conn, body) do
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

  def ce_attributes(conn) do
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
  def validate_events(events) do
    if Enum.all?(events, &valid_cloudevent?/1), do: :ok, else: {:error, :invalid_cloudevent}
  end

  def valid_cloudevent?(event) when is_map(event) do
    event["specversion"] == "1.0" and present?(event["source"]) and present?(event["type"])
  end

  def valid_cloudevent?(_), do: false

  def present?(value), do: is_binary(value) and value != ""

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

  def decoded_body(conn) do
    case conn.body_params do
      %Plug.Conn.Unfetched{} ->
        case read_raw_body(conn) do
          {:ok, raw} ->
            case Smalt.JsonCompat.decode(raw) do
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
      # KD-COVERS: KD-147 — the spec system-prop set on a Cosmos doc body is
      # _rid/_self/_ts/_etag only; the emulator-internal _gen/_v nonce fields
      # never cross the wire. Stored docs keep them (etag/CAS composition);
      # the render seam drops them recursively.
      send_json(conn, status, drop_cosmos_internal(body))
    end
  end

  defp drop_cosmos_internal(%{"Documents" => docs} = body) when is_list(docs) do
    Map.put(body, "Documents", Enum.map(docs, &drop_cosmos_internal/1))
  end

  defp drop_cosmos_internal(%{"_etag" => _} = doc) when is_map(doc) do
    Map.drop(doc, ["_gen", "_v"])
  end

  defp drop_cosmos_internal(body), do: body

  def ensure_request_charge(conn, headers) do
    if Map.has_key?(headers, "x-ms-request-charge") do
      conn
    else
      put_resp_header(conn, "x-ms-request-charge", "1.0")
    end
  end

  def apply_headers(conn, headers) do
    Enum.reduce(headers, conn, fn {name, value}, conn ->
      Plug.Conn.put_resp_header(conn, name, value)
    end)
  end

  # Real Log Analytics DCR ingest answers 204 No Content plus x-ms-request-id.
  # Unified to the dashed-36 RFC 4122 v4 GUID form real Azure emits on BOTH
  # the LA and ARM surfaces (cross-court finding, compliance-corpus cycle 8);
  # previously a 32-hex dialect pin.
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

  def send_json(conn, status, body) do
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
  def container_put_etag(record) do
    BlobService.container_etag(record)
  end

  # Lane 06 (v26.10.14) defect 3, part 2: blob error responses now carry the
  # error code in the x-ms-error-code header, extracted from the JSON body's
  # code slot (either envelope shape). Additive — the JSON body is unchanged.
  # KD-COVERS: KD-142 — blob-face typed errors render the Azure StorageError
  # XML envelope (Smalt.DataPlane.BlobError) with the x-ms-error-code header;
  # untyped/legacy bodies and non-blob faces keep JSON (face-scoped renderer).
  # EXPL-9 F2b (KD-COVERS: KD-175): crash-path fence handler. Renders the
  # Storage <Error> envelope + x-ms-request-id on any unhandled crash —
  # never a naked adapter 500. (No @impl: handle_errors is defp called
  # dynamically by Plug.ErrorHandler; @impl on a defp is a compile warning.)
  defp handle_errors(conn, %{kind: kind, reason: reason, stack: stack}) do
    # BK-EGS1 (F-EGS1 repair, EXPL9-R2): a fault INSIDE handle_errors/2 itself
    # (error_xml/2, generate_request_id/0, put_resp_content_type/2 ...) used to
    # propagate out of Plug.ErrorHandler.__catch__ to Bandit and render the
    # NAKED adapter 500 — empty body, no envelope, no x-ms-request-id (audit
    # probe T6, docs/jira/v26.10.22/receipts/bkegskep-fence-audit.md). The
    # rescue path renders a fault-free constant fallback envelope (module-
    # attribute bytes + static request id — no fallible call) and logs the
    # secondary fault loudly.
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

  def blob_error(conn, status, body) do
    code = blob_error_code(body)

    # B-XML: on the blob face a TYPED error (binary code) renders the Azure
    # Storage XML envelope; untyped bodies keep the legacy JSON renderer so
    # no call site loses its envelope. Non-blob faces are untouched.
    if conn.private[:smalt_blob_face] && is_binary(code) do
      blob_error_xml(conn, status, code, blob_error_message(body) || code)
    else
      conn
      |> put_resp_header("x-ms-request-id", generate_request_id())
      |> put_resp_header("x-ms-version", "2021-12-02")
      |> put_error_code_header(body)
      |> send_json(status, body)
    end
  end

  def put_error_code_header(conn, body) do
    case blob_error_code(body) do
      nil -> conn
      code -> put_resp_header(conn, "x-ms-error-code", code)
    end
  end

  def blob_error_code(%{"error" => %{"code" => code}}) when is_binary(code), do: code
  def blob_error_code(%{"code" => code}) when is_binary(code), do: code
  def blob_error_code(_), do: nil

  def blob_error_message(%{"error" => %{"message" => m}}) when is_binary(m), do: m
  def blob_error_message(%{"message" => m}) when is_binary(m), do: m
  def blob_error_message(_), do: nil

  # Lane 06 (v26.10.14) defect 3, part 1: on the blob comp=list routes the
  # real Azure Blob service answers typed errors with an XML
  # <?xml?><Error><Code/><Message/></Error> envelope (Content-Type
  # application/xml), not JSON. Scoped to the comp=list arms only — every
  # other blob_error/3 consumer (ledger, cosmos, KV, attestation, sentinel)
  # keeps byte-identical JSON output.
  def blob_error_xml(conn, status, code, message) do
    # B-XML: single renderer in Smalt.DataPlane.BlobError (header set + body).
    BlobError.send_error(conn, status, code, message, generate_request_id())
  end

  def not_found_error(code) do
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
  def unhandled_comp?(conn, allowed) do
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
  def comp_str(v) when is_list(v), do: Enum.join(v, ", ")
  def comp_str(v), do: v

  # R124 message convention (both comp-error envelopes): the wire-visible
  # prefix `The comp value '<v>' is not supported` is byte-identical and
  # test-pinned (blob_hardening_test.exs). The GAP clause
  # `(GAP(blob-comp-lease-absent)): ...` is appended ONLY where a registered
  # GAP row names the comp family — container lease/ACL — never on the blob
  # arm, whose unhandled comps (appendblock, snapshot, page, ...) span more
  # than the lease GAP and would overclaim.
  def unhandled_blob_comp_error(conn, v) do
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
  def unhandled_container_comp_error(conn, v) do
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
  def kv_respond(conn, {:ok, status, body}), do: send_json(conn, status, body)
  def kv_respond(conn, {:error, status, body}), do: send_json(conn, status, body)

  # x-ms-meta-* request headers -> %{"name" => "value"} map (BlobService
  # container metadata). Response direction: meta dict -> x-ms-meta-* headers.
  # Wire body (Azure shape) -> BlobStorage.set_immutability_policy/5 policy map.
  #
  # Body seam: Plug.Parsers may already have consumed and decoded the JSON
  # body (body_params is a map) — re-reading the stream would return "" and
  # lose the policy. Read body_params first; read_body is only the fallback
  # for unparsed content-types. A non-empty body that fails to decode is a
  # 400 InvalidXmlOrJson, never a nil-expires 500 downstream.
  def immutability_policy_from_wire(conn) do
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

  # KD-108 wire seam (ACL PUT): the raw SignedIdentifiers body may already
  # have been consumed by Plug.Parsers (a urlencoded/json Content-Type — curl's
  # default for --data-binary is x-www-form-urlencoded — matches :urlencoded
  # and eats the XML). Read the raw cache first (Smalt.Auth.BodyCache stashes
  # the complete raw body in :smalt_raw_body whenever a parser ran), fall back
  # to the stream for parser-exempt requests (raw_blob_put? style paths).
  # Without this, read_body/1 returns "" and the ACL arm silently CLEARS the
  # signed identifiers (204 with parse_signed_identifiers("") == {:ok, []}).
  def acl_body(conn) do
    case conn.private[:smalt_raw_body] do
      raw when is_binary(raw) ->
        {:ok, raw, conn}

      _ ->
        case Plug.Conn.read_body(conn) do
          {:ok, raw, conn} -> {:ok, raw, conn}
          {:error, reason} -> {:error, 400, "InvalidRequestBody", inspect(reason)}
        end
    end
  end

  def decode_policy_body("", conn), do: {:ok, %{}, conn}

  def decode_policy_body(raw, conn) do
    case Jason.decode(raw) do
      {:ok, %{} = body} -> {:ok, policy_from_params(body), conn}
      _ -> {:error, conn}
    end
  end

  def policy_from_params(body) do
    %{
      "locked" => Map.get(body, "locked", false) == true,
      "period_days" => period_days(Map.get(body, "immutabilityPeriodSinceCreationInDays", 0)),
      "until" => Map.get(body, "expiresOn")
    }
    |> Enum.reject(fn {_k, v} -> is_nil(v) end)
    |> Map.new()
  end

  def period_days(days) when is_integer(days), do: days

  def period_days(days) when is_binary(days) do
    case Integer.parse(days) do
      {n, ""} -> n
      _ -> days
    end
  end

  def period_days(other), do: other

  def meta_headers(%Plug.Conn{} = conn) do
    Enum.reduce(conn.req_headers, %{}, fn {name, value}, acc ->
      case name do
        "x-ms-meta-" <> meta_name -> Map.put(acc, meta_name, value)
        _ -> acc
      end
    end)
  end

  def meta_headers(meta) when is_map(meta) do
    Map.new(meta, fn {name, value} -> {"x-ms-meta-#{name}", to_string(value)} end)
  end

  # KD-01 echo: stored x-ms-meta-* ride GET/HEAD blob responses (Azure Get
  # Blob metadata). Scoped to the x-ms-meta-* subset — the stored header map
  # carries the full PUT request headers (auth, x-ms-version) and only user
  # metadata is wire-safe to emit.
  def stored_meta_wire(blob) do
    blob
    |> Map.get("headers", %{}) ||
      %{}
      |> Enum.filter(fn {k, _v} -> String.starts_with?(k, "x-ms-meta-") end)
  end

  # T-18 (v26.10.28): the content type a blob GET/HEAD serves is the one Set
  # Blob HTTP Headers stored (x-ms-blob-content-type on the record's header
  # map) — falling back to the service default when never set.
  defp stored_content_type(blob) do
    case get_in(blob, ["headers", "x-ms-blob-content-type"]) do
      ct when is_binary(ct) and ct != "" -> ct
      _ -> "application/octet-stream"
    end
  end

  def put_resp_headers(conn, headers) do
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
  def send_headers(conn, status, headers) do
    put_resp_headers(conn, headers)
    |> send_resp(status, "")
  end

  def put_message(body, msg), do: put_in(body, ["error", "message"], msg)

  # ===========================================================================
  # AZB-10 — Cross-plane wiring: peer resolution + egress guard (nested module;
  # ticket scope names this file for peer resolution ONLY — the router's own
  # dispatch behavior is untouched).
  # ===========================================================================
  defmodule Peers do
    @moduledoc """
    AZB-10 cross-plane wiring primitives (loopback-only, zero egress):

    - `resolve/1` — config-driven peer endpoints (`config :smalt, :peers`,
      sourced from `config/env/az_prod_*.exs`). No in-process short-circuit:
      callers always reach peers over the wire at the resolved endpoint.
    - `guard/1` — egress guard: any non-loopback / non-peer outbound endpoint
      is refused typed with `R_missing_authority`, counted, and instrumented
      (`[:smalt, :egress, :refused]` telemetry, metadata carries the reason).
    - `refused_connects/0` — suite-level counter of refused non-loopback
      connects (the Accept gate reads a delta of 0 over the cross-plane wire
      legs).
    - `emit_resource_write_success/2` — control-plane resource PUT emits the
      Event Grid `Microsoft.Resources.ResourceWriteSuccess` event to the
      integration plane (Event Grid topic fan-out + Service Bus bridge
      enqueue). Never raises into the PUT response path.

    Same-node peers are reached over real sockets (wire fidelity, AZB-10
    falsifier: an in-process resolution is a defect). Emission helpers live
    here so the control-plane router carries a single call site.
    """

    @loopback_hosts ~w(127.0.0.1 localhost ::1)
    @counter_table :smalt_egress_guard
    @sb_bridge_queue "resourcewritesuccess"

    # -- peer resolution ---------------------------------------------------------

    @doc "Config-driven peer endpoint for `plane` (nil when unconfigured)."
    @spec resolve(atom()) :: String.t() | nil
    def resolve(plane) when is_atom(plane) do
      case Application.get_env(:smalt, :peers) do
        kw when is_list(kw) -> Keyword.get(kw, plane)
        _other -> nil
      end
    end

    # -- egress guard ------------------------------------------------------------

    @doc """
    Egress guard for an outbound endpoint URL. Loopback hosts and endpoints
    matching a configured peer prefix are allowed (:ok); any other host is
    refused typed (`{:refused, :R_missing_authority}`), counted, and
    instrumented. Fail-closed: an unparseable URL refuses.
    """
    @spec guard(String.t()) :: :ok | {:refused, :R_missing_authority}
    def guard(url) when is_binary(url) do
      host = URI.parse(url).host

      cond do
        is_nil(host) ->
          refuse(url, nil)

        loopback?(host) or peer_endpoint?(url) ->
          :ok

        true ->
          refuse(url, host)
      end
    end

    @doc "Count of refused non-loopback outbound connects (monotone)."
    @spec refused_connects :: non_neg_integer()
    def refused_connects do
      ensure_table()
      :ets.lookup_element(@counter_table, :refused, 2)
    end

    defp refuse(url, host) do
      ensure_table()
      :ets.update_counter(@counter_table, :refused, {2, 1})

      :telemetry.execute(
        [:smalt, :egress, :refused],
        %{count: 1},
        %{host: host, url: url, reason: :R_missing_authority}
      )

      {:refused, :R_missing_authority}
    end

    defp loopback?(host), do: host in @loopback_hosts

    defp peer_endpoint?(url) do
      case Application.get_env(:smalt, :peers) do
        kw when is_list(kw) ->
          Enum.any?(kw, fn
            {plane, ep} when plane != :self and is_binary(ep) ->
              String.starts_with?(url, ep)

            _ ->
              false
          end)

        _ ->
          false
      end
    end

    defp ensure_table do
      if :ets.info(@counter_table) == :undefined do
        # Named public table; races on first-touch are benign (both arms
        # create the same shape; loser's :error is ignored).
        try do
          :ets.new(@counter_table, [:named_table, :public, :set, write_concurrency: true])
          :ets.insert(@counter_table, {:refused, 0})
        catch
          _, _ -> :ok
        end
      end
    end

    # -- control-plane resource-write emission ----------------------------------

    @doc """
    Emits the Event Grid `Microsoft.Resources.ResourceWriteSuccess` event for a
    successful control-plane resource PUT: fan-out on the Event Grid topic
    `resources` to every subscriber (integration-plane bridge), plus a Service
    Bus bridge enqueue on queue `#{@sb_bridge_queue}` (the integration plane's
    AMQP surface). Never raises into the PUT response path.
    """
    @spec emit_resource_write_success(map(), map()) :: :ok
    def emit_resource_write_success(record, meta) when is_map(record) and is_map(meta) do
      event = build_event(record, meta)

      # Event Grid fan-out (integration plane subscribers get redelivery
      # semantics from the engine itself).
      try do
        Smalt.Messaging.EventGrid.publish("resources", event)
      catch
        _, _ -> :ok
      end

      # Service Bus bridge: the event body enqueued on the integration plane's
      # queue so an AMQP/QueueStore subscriber receives ResourceWriteSuccess.
      try do
        # KD-86: the bridge queue is an internal emulator seam, not a client
        # entity — materialize it explicitly so the KD-86 send-path gate
        # (default real-SB refusal of sends to never-created entities) does
        # not silently drop bridge events.
        Smalt.Amqp.QueueStore.ensure_queue(@sb_bridge_queue)
        Smalt.Amqp.QueueStore.enqueue(@sb_bridge_queue, Jason.encode!(event))
      catch
        _, _ -> :ok
      end

      :ok
    end

    @doc false
    @spec build_event(map(), map()) :: map()
    def build_event(record, meta) do
      res_id = Map.get(record, "id")

      %{
        id: "rgw-" <> resource_uri_digest(res_id),
        event_type: "Microsoft.Resources.ResourceWriteSuccess",
        subject: res_id,
        topic: "resources",
        event_time: DateTime.utc_now() |> DateTime.to_iso8601(),
        data: %{
          "resourceUri" => res_id,
          "operationName" => "#{Map.get(record, "type", "Microsoft.Resources")}/write",
          # ARMSTRONG fix 3: the fallback is minted PER EVENT (make_ref), not
          # deterministic per resource — a digest-based fallback made every
          # event on a resource share one correlationId, destroying correlation.
          "correlationId" => Map.get(meta, :correlation_id, "azb10-" <> inspect(make_ref())),
          "subscription" => Map.get(meta, :subscription)
        }
      }
    end

    defp resource_uri_digest(res_id) do
      res_id
      |> :erlang.phash2()
      |> Integer.to_string()
    end
  end
end
