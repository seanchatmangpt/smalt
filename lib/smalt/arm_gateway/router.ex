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
  alias Smalt.ArmGateway.LRO
  alias Smalt.ArmGateway.Defaults
  alias Smalt.ArmGateway.ProviderMatrix
  alias Smalt.ArmGateway.SkuQuota
  alias Smalt.ArmGateway.ProviderState
  alias Smalt.ArmGateway.TagsLocks
  alias Smalt.Store
  alias Smalt.GraphLaw.Validator
  alias Smalt.Registry
  alias Smalt.DataPlane.Sentinel
  alias Smalt.DataPlane.Cosmos
  alias Smalt.DataPlane.BlobStorage
  alias Smalt.DataPlane.VaultData
  alias Smalt.Arm.EhConsumerGroups
  alias Smalt.ArmGateway.CostManagement
  alias Smalt.ArmGateway.ResourceHealth
  alias Smalt.Policy

  plug(Plug.Logger)
  plug(:arm_cors)
  plug(:normalize_leading_empty_segment)
  # X-ARR-ClientCert mTLS gateway termination (WO-2 G2). No-op by default
  # (config :smalt, :x_arr_cert, require: false) — byte-identical when off.
  plug(Smalt.Auth.XArrCert)
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
  # v26.10.29 W2: Ash-dispatched deep child face — DEFAULT-INERT
  # (config :smalt, :ash_gateway, false). Passes through unless the flag is
  # on AND the deep shape resolves via Smalt.AshGen.Registry and is not
  # owned by an existing route family (see CanonicalRouter claim law).
  plug(Smalt.ArmGateway.CanonicalRouter)
  plug(:match)
  plug(:dispatch)

  # ===========================================================================
  # Helpers (Plug.Router requires helpers to be defined BEFORE the routes)
  # ===========================================================================

  @actions ["lock", "setlegalhold"]

  # LIST pagination: ARM lists paginate via nextLink; smalt pages at 100 items
  # per page, `maxitempages` (default 1) controls how many pages one response
  # may carry before truncating with an absolute nextLink.
  @page_size 100

  # Synthetic fixed systemData — honest dev-mode: smalt has no user directory,
  # so every record carries the same substrate identity instead of fabricating
  # per-caller values.
  @system_data %{
    "createdBy" => "smalt-dev-substrate",
    "createdByType" => "Application",
    "createdAt" => "2026-01-01T00:00:00.0000000+00:00"
  }

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

    # Stash the id so the crash path (handle_errors/2) reuses it — a 500
    # rendered by Plug.ErrorHandler never runs register_before_send callbacks.
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

  defp handle_token(conn, tenant_id) do
    # AZB-15 identity-plane DR gate: when the identity subtree booted in this
    # VM and was then killed, NEW mints answer a typed 503 (retryable). A
    # control-only boot (split profile / wire tree, no identity plane) keeps
    # minting — the marker is set only by StsGate.init in a booted identity
    # subtree.
    if Smalt.Plane.Identity.StsGate.mint_allowed?() do
      case validate_token_request(conn) do
        :ok ->
          issue_token(conn, tenant_id)

        {:error, code} ->
          token_error(conn, code)
      end
    else
      conn
      |> put_resp_header("retry-after", "1")
      |> put_resp_content_type("application/json")
      |> send_resp(503, Jason.encode!(%{"error" => "StsUnavailable"}))
      |> halt()
    end
  end

  # RFC 6749 §5.2 error responses; §5.1 requires Cache-Control: no-store +
  # Pragma: no-cache on ALL token endpoint responses (success AND error).
  defp token_error(conn, code) do
    conn
    |> put_resp_header("cache-control", "no-store")
    |> put_resp_header("pragma", "no-cache")
    |> put_resp_content_type("application/json")
    |> send_resp(400, Jason.encode!(%{"error" => code}))
  end

  # RFC 6749 §5.2 request validation:
  # - unparseable/missing grant_type -> invalid_request
  # - wrong grant_type              -> unsupported_grant_type
  # - missing client_id/secret      -> invalid_client
  defp validate_token_request(conn) do
    params = conn.body_params

    # Duplicate form parameters are refused (OAuth 2.1 draft security
    # considerations / AAD parity): Plug's last-wins decoding would let a
    # later client-controlled key overwrite an earlier fixed one. Detected
    # on the RAW body via the BodyCache reader, not the decoded map.
    dup? =
      case conn.private[:smalt_raw_body] do
        body when is_binary(body) ->
          # Exact-key duplicate detection on &-separated pairs: substring
          # neighbors (e.g. xgrant_type=) must NOT false-positive.
          body
          |> String.split("&")
          |> Enum.count(fn
            "grant_type=" <> _ -> true
            "grant_type" -> true
            _ -> false
          end) > 1

        _ ->
          false
      end

    cond do
      dup? ->
        {:error, "invalid_request"}

      not is_map(params) or not is_binary(params["grant_type"]) or params["grant_type"] == "" ->
        {:error, "invalid_request"}

      params["grant_type"] != "client_credentials" ->
        {:error, "unsupported_grant_type"}

      blank?(params["client_id"]) or blank?(params["client_secret"]) ->
        {:error, "invalid_client"}

      true ->
        :ok
    end
  end

  defp blank?(v), do: not is_binary(v) or v == ""

  defp issue_token(conn, tenant_id) do
    now = System.system_time(:second)

    # AZB-08 config read site: the identity-plane profile
    # `config :smalt, :sts, token_ttl_seconds: 3600` names the mint TTL.
    # Default 3600 keeps the pinned STS mint contract (exp - iat == 3600,
    # expires_in == 3600) byte-identical on a plain `:all` boot.
    ttl = Keyword.get(Smalt.Config.sts(), :token_ttl_seconds, 3600)

    # Cross-seat issuer acceptance (F4 v3 finding 1): record the authority the
    # token is minted under so sibling seats (Cosmos :8443, blob, kv) accept
    # it. Server-side only — membership is added at mint time, never from
    # client-asserted claims, so the check stays tamper-resistant.
    authority = mint_authority(conn)
    Smalt.Auth.Bearer.register_trusted_authority(authority)

    # OIDC Discovery: the token iss must EXACTLY equal the discovery issuer for
    # the same request authority — both derive from request_authority/1.
    claims = %{
      "aud" => "https://management.azure.com",
      "iss" => "#{authority}/#{tenant_id}/v2.0",
      "iat" => now,
      "nbf" => now,
      "exp" => now + ttl,
      "appid" => "00000000-0000-0000-0000-000000000000",
      "azp" => "00000000-0000-0000-0000-000000000000",
      "oid" => "00000000-0000-0000-0000-000000000001",
      "sub" => "00000000-0000-0000-0000-000000000001",
      "tid" => tenant_id,
      "roles" => ["Contributor", "Owner"]
    }

    # Mint via the mode's key: RS256 emits {"typ":"JWT","alg":"RS256",
    # "kid":<thumbprint>} (JOSE-direct — Joken's JWS.compact strips custom JWS
    # header members); :hs256_dev stays on the legacy Joken path, wire
    # byte-identical to pre-StsKey.
    {:ok, token} = Smalt.Auth.StsKey.mint(claims)

    # AF-L14-GAP-1 closure: every successful mint feeds the sign-in logs ring
    # (GET /v1.0/auditLogs/signIns). Recording failure never fails the mint.
    Smalt.Egress.SignIns.record_mint(tenant_id, claims["appid"], conn)

    body =
      Jason.encode!(%{
        "token_type" => "Bearer",
        "expires_in" => ttl,
        "ext_expires_in" => ttl,
        "scope" => "https://management.azure.com/.default",
        "access_token" => token
      })

    conn
    |> put_resp_header("cache-control", "no-store")
    |> put_resp_header("pragma", "no-cache")
    |> send_json(200, body)
  end

  # STS signing key: RS256 via Smalt.Auth.StsKey (env-PEM-first precedence,
  # :global-locked once-per-VM generation, :persistent_term-cached with the
  # mode stamped). The legacy HS256 secret logic moved into
  # Smalt.Auth.StsKey.hs_signer/0 / generate_and_cache_dev_secret/0.

  # Lane R9 (JWT issuer configurability): when `config :smalt, :issuer_host`
  # is set, the STS mint + OIDC discovery authority is `https://<issuer_host>`
  # instead of the request-derived loopback authority. Default (nil) is
  # byte-identical to the legacy mint. The configured authority is registered
  # as a trusted mint authority so tokens still verify on every seat via the
  # existing cross-seat leg (JWKS/kid binding untouched).
  defp mint_authority(conn) do
    case Smalt.Config.issuer_host() do
      nil ->
        request_authority(conn)

      host when is_binary(host) ->
        authority = issuer_host_authority!(host)
        Smalt.Auth.Bearer.register_trusted_authority(authority)
        authority
    end
  end

  # Fail-closed validation: bare host or full HTTPS URL with NO path. The
  # issuer must stay a well-formed HTTPS-shape URL string; anything else
  # (http scheme, embedded path, empty) refuses the mint with ArgumentError.
  defp issuer_host_authority!(host) do
    cond do
      not String.contains?(host, "://") ->
        case String.trim_trailing(host, "/") do
          "" -> raise ArgumentError, "smalt :issuer_host must be a non-empty host or HTTPS URL"
          trimmed -> "https://#{trimmed}"
        end

      true ->
        case URI.parse(host) do
          %URI{scheme: "https", host: h, path: p} when is_binary(h) and p in [nil, ""] ->
            String.trim_trailing(host, "/")

          _ ->
            raise ArgumentError,
                  "smalt :issuer_host must be a bare host or an HTTPS URL with no path " <>
                    "(got #{inspect(host)})"
        end
    end
  end

  # Request-derived authority: scheme://host[:port] as the CLIENT reached us
  # (lane 90 TS court: advertising login.smalt.local — an NXDOMAIN — made
  # msal-node/azidentity follow the envelope and never reach the substrate
  # STS: endpoints_resolution_error). Single derivation shared with the auth
  # plug: forwarded headers honored ONLY from trusted proxies (fail-closed).
  defp request_authority(conn), do: Smalt.Auth.Bearer.request_authority(conn)

  # "https://arm.internal:19081" -> "arm.internal" (scheme + port stripped):
  # the instance-discovery alias for THIS substrate's authority.
  defp instance_alias_host(base) do
    case String.split(base, "://", parts: 2) do
      [_scheme, rest] -> hd(String.split(rest, ":", parts: 2))
      _ -> base
    end
  end

  defp openid_envelope(conn, tenant_id) do
    base = "#{mint_authority(conn)}/#{tenant_id}"

    %{
      "issuer" => "#{base}/v2.0",
      "token_endpoint" => "#{base}/oauth2/v2.0/token",
      "authorization_endpoint" => "#{base}/oauth2/v2.0/authorize",
      "jwks_uri" => "#{base}/discovery/v2.0/keys",
      # Mode-conditional: AAD advertises ["RS256"]; the HS256 dev pin
      # advertises what it actually uses (self-consistent with the mint).
      "id_token_signing_alg_values_supported" =>
        case Smalt.Auth.StsKey.mode() do
          :rs256 -> ["RS256"]
          :hs256_dev -> ["HS256"]
        end,
      # OIDC Discovery 3.0 REQUIRED members.
      "response_types_supported" => ["token"],
      "subject_types_supported" => ["public"]
    }
  end

  # C1-TENANT closure (divergence lane D2): the STS mints tokens for ARBITRARY
  # tenants (/:tenant_id/oauth2/v2.0/token), so /tenants must reflect what the
  # identity plane actually minted, not only the home tenant. Registry = the
  # sign-ins mint ring (Smalt.Egress.SignIns): every successful token-endpoint
  # mint already records its tenant there, so /tenants renders home + every
  # distinct minted tenant. Documented ARM TenantListResult shape
  # (learn.microsoft.com/rest/api/resources/tenants/list): id is the
  # "/tenants/{tenantId}" URI, tenantCategory "Home" on the home row only.
  @home_tenant_id "00000000-0000-0000-0000-000000000000"

  defp send_tenant_list(conn) do
    minted =
      Smalt.Egress.SignIns.events()
      |> Enum.map(& &1.tenant_id)
      |> Enum.uniq()
      |> Enum.reject(&(&1 == @home_tenant_id))

    home_row = %{
      "id" => "/tenants/#{@home_tenant_id}",
      "tenantId" => @home_tenant_id,
      "displayName" => "Sovereign",
      "tenantCategory" => "Home"
    }

    minted_rows =
      for tid <- minted do
        %{
          "id" => "/tenants/#{tid}",
          "tenantId" => tid,
          "displayName" => tid
        }
      end

    send_json(conn, 200, Jason.encode!(%{"value" => [home_row | minted_rows]}))
  end

  defp send_json(conn, status, body) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(status, body)
  end

  # ARM list envelope with nextLink pagination (row 9): page size 100,
  # `maxitempages` (default 1) caps pages per response; when items remain the
  # response carries an absolute nextLink continuing at $skip.
  defp send_list(conn, items) do
    # Deny-by-default list fence (lens-11, measured): a record that is not a
    # map, or a map carrying any value Jason cannot encode, previously raised
    # Jason.EncodeError / Protocol.UndefinedError inside send_json — 500-ing
    # the WHOLE list forever (the poisoning record persists). Like the LRO
    # get_op/2 ownership fence (lens-9 cycle-5), a record that does not prove
    # it is a well-formed ARM resource is never surfaced.
    items = Enum.filter(items, &renderable_record?/1)

    skip = int_query_param(conn, "$skip", 0)
    pages = max(int_query_param(conn, "maxitempages", 1), 1)
    slice = Enum.slice(items, skip, pages * @page_size)
    next_skip = skip + length(slice)
    truncated? = next_skip < length(items)

    body =
      if truncated? do
        %{"value" => slice, "nextLink" => next_link(conn, next_skip)}
      else
        %{"value" => slice}
      end

    send_json(conn, 200, Jason.encode!(body))
  end

  # A record renders as an ARM resource iff it is a map every member of which
  # Jason can encode. Anything else (a raw integer/atom/tuple under a store
  # key, or a map with a tuple/pid/function value) is not provably a resource
  # and is denied by default: filtered from lists, 404 on single GET.
  defp renderable_record?(%{} = record) do
    match?({:ok, _}, Jason.encode(record))
  end

  defp renderable_record?(_), do: false

  # SHIM-COURT tags-null-when-empty (2026-10-16, lane 419 wire evidence):
  # azurerm normalizes an EMPTY tags map to null in state (real Azure omits
  # tags on untagged resources), so echoing `"tags": {}` makes every
  # refresh-only plan drift `+ tags = {}` forever. Parity law: nil/missing
  # -> null on the wire; an existing non-empty map round-trips unchanged.
  # WITNESS: /tmp/tf-rg419 single-fixture apply+refresh (lane 419).
  defp normalize_tags(nil), do: nil

  defp normalize_tags(%{} = tags) do
    if map_size(tags) == 0, do: nil, else: tags
  end

  defp normalize_tags(_), do: nil

  # SHIM-COURT tags (2026-10-16, lane 429 reconciliation, FR-5 re-witness
  # /tmp/tf-plan-probe.hPaBPZ): ONE law for create AND update — an RG PUT is
  # a FULL REPLACE, so omitted/null/empty tags REMOVE the stored tags and the
  # GET renders `"tags": null` (azurerm normalizes empty tags to null in
  # state; echoing `{}` drifts every refresh-only plan `+ tags = {}`).
  # Only an explicit non-empty tags map renders as a map.
  defp rg_tags(payload, _created?) do
    case Map.fetch(payload, "tags") do
      {:ok, %{} = tags} when map_size(tags) > 0 -> tags
      _ -> nil
    end
  end

  # SHIM-COURT tags (2026-10-16, lane 429 reconciliation): the RG GET
  # renders stored tags through the same null-when-empty law — a stale
  # `%{}` record (pre-reconciliation update) still renders null, never `{}`.
  defp normalize_rg(%{} = rg) do
    Map.update(rg, "tags", nil, &normalize_tags/1)
  end

  defp int_query_param(conn, name, default) do
    case conn.query_params[name] do
      nil ->
        default

      value ->
        case Integer.parse(value) do
          {n, ""} when n >= 0 -> n
          _ -> default
        end
    end
  end

  defp next_link(conn, skip) do
    pages = max(int_query_param(conn, "maxitempages", 1), 1)

    query =
      conn.query_params
      |> Map.take(["api-version"])
      |> Map.put("maxitempages", Integer.to_string(pages))
      |> Map.put("$skip", skip)
      |> URI.encode_query()

    "#{request_authority(conn)}#{conn.request_path}?#{query}"
  end

  # C1 row 1b: error.target names the offending path when a specific path
  # caused the failure (404 classes); absent on api-version 400s (query-param
  # failures have no path component — corpus pins target ABSENT there).
  defp send_arm_error(conn, status, code, message, target \\ nil, details \\ []) do
    error =
      if target do
        %{
          "code" => code,
          "message" => message,
          "target" => target,
          # Real AAD/ARM shape: innererror present-but-empty when there is
          # nothing further to nest.
          "innererror" => %{}
        }
      else
        %{
          "code" => code,
          "message" => message,
          # Real AAD/ARM shape: innererror present-but-empty when there is
          # nothing further to nest.
          "innererror" => %{}
        }
      end

    error = if details == [], do: error, else: Map.put(error, "details", details)

    body = Jason.encode!(%{"error" => error})

    conn
    |> put_resp_content_type("application/json")
    |> send_resp(status, body)
  end

  # KD-COVERS: KD-28 — the NSG shape tightening lives in
  # priv/shacl/smalt-shapes.ttl (NsgShape: closed true + location required),
  # compiled into this router via GraphLaw.Validator's compile-time ttl parse;
  # this refusal site is where the wire 400 surfaces.
  # GraphLaw refusal -> HTTP 400 (PINNED decision; ARM never returns 422).
  # Envelope code InvalidResourceShape, target AshGraphLaw.Enforcement.
  # Optional `details` carries per-issue SHACL detail rows (ARM error.details
  # shape); byte-identical envelope when details == [] (existing corpus rows).
  defp send_graphlaw_refusal(conn, reason, details \\ []) do
    error = %{
      "code" => "InvalidResourceShape",
      "message" => "GraphLaw validation failure: #{reason}",
      "target" => "AshGraphLaw.Enforcement",
      "innererror" => %{}
    }

    error = if details == [], do: error, else: Map.put(error, "details", details)

    body = Jason.encode!(%{"error" => error})

    conn
    |> put_resp_content_type("application/json")
    |> send_resp(400, body)
  end

  # AZB-05: typed 503 face for engine-down under :fail_closed. ARM error
  # envelope shape; code EngineUnavailable; message names the typed atom
  # :engine_unavailable (ticket vocabulary).
  defp send_engine_unavailable(conn) do
    body =
      Jason.encode!(%{
        "error" => %{
          "code" => "EngineUnavailable",
          "message" =>
            "graphlaw validation engine is unavailable (:engine_unavailable); request refused fail-closed, never admitted.",
          "target" => "AshGraphLaw.Enforcement",
          "innererror" => %{}
        }
      })

    conn
    |> put_resp_content_type("application/json")
    |> send_resp(503, body)
  end

  # RG api-version gate (row 6b, coordinator-authorized landing 2026-10-15):
  # Microsoft.Resources/resourceGroups is an admitted Registry type
  # (latest 2021-04-01) — every RG verb validates api-version like any other
  # admitted type (missing -> 400 MissingApiVersionParameter; stale ->
  # 400 InvalidApiVersionParameter naming the latest).
  @rg_type "Microsoft.Resources/resourceGroups"

  defp handle_rg_list(conn, sub_id) do
    with :ok <- check_api_version(conn, @rg_type) do
      rgs =
        Store.list_prefix(:smalt_resource_groups, "/subscriptions/#{sub_id}/resourcegroups/")
        |> apply_lifecycle_expand(conn)

      send_list(conn, rgs)
    else
      {:respond, conn} -> conn
    end
  end

  defp handle_rg_put(conn, sub_id, rg_name) do
    with :ok <- check_api_version(conn, @rg_type) do
      do_rg_put(conn, sub_id, rg_name)
    else
      {:respond, conn} -> conn
    end
  end

  defp handle_rg_patch(conn, sub_id, rg_name) do
    with :ok <- check_api_version(conn, @rg_type) do
      do_rg_patch(conn, sub_id, rg_name)
    else
      {:respond, conn} -> conn
    end
  end

  defp do_rg_patch(conn, sub_id, rg_name) do
    rg_id = "/subscriptions/#{sub_id}/resourceGroups/#{rg_name}"
    key = String.downcase(rg_id)

    case Store.get(:smalt_resource_groups, key) do
      {:ok, existing} when is_map(existing) ->
        payload = conn.body_params

        merged_tags =
          case Map.fetch(payload, "tags") do
            {:ok, %{} = new_tags} ->
              # Merge with existing tags if present, or set
              cur = Map.get(existing, "tags") || %{}
              Map.merge(cur, new_tags)

            _ ->
              Map.get(existing, "tags")
          end

        updated =
          existing
          |> Map.put("tags", normalize_tags(merged_tags))

        Store.put(:smalt_resource_groups, key, updated)
        :ok = ProviderState.touch_lifecycle(rg_id)
        send_json(conn, 200, Jason.encode!(normalize_rg(updated)))

      _ ->
        send_arm_error(
          conn,
          404,
          "ResourceGroupNotFound",
          "Resource group '#{rg_name}' could not be found.",
          rg_id
        )
    end
  end

  defp handle_rg_resources_list(conn, sub_id, rg_name) do
    with :ok <- check_api_version(conn, nil) do
      prefix = String.downcase("/subscriptions/#{sub_id}/resourceGroups/#{rg_name}/")

      items =
        Store.list_prefix(:smalt_resources, prefix)
        |> Enum.filter(&renderable_record?/1)
        |> Enum.filter(&subscription_resource_filter(conn, &1))

      send_list(conn, items)
    else
      {:respond, conn} -> conn
    end
  end

  defp handle_locations_list(conn, sub_id) do
    with :ok <- check_api_version(conn, nil) do
      locations =
        ProviderMatrix.default_locations()
        |> Enum.map(fn loc ->
          display_name =
            case loc do
              "eastus" -> "East US"
              "westus2" -> "West US 2"
              "local" -> "Local"
              other -> other
            end

          %{
            "id" => "/subscriptions/#{sub_id}/locations/#{loc}",
            "name" => loc,
            "displayName" => display_name,
            "regionalDisplayName" => "(US) #{display_name}"
          }
        end)

      send_json(conn, 200, Jason.encode!(%{"value" => locations}))
    else
      {:respond, conn} -> conn
    end
  end

  defp do_rg_put(conn, sub_id, rg_name) do
    rg_id = "/subscriptions/#{sub_id}/resourceGroups/#{rg_name}"
    payload = conn.body_params
    requested = Map.get(payload, "location", "eastus")

    existing =
      case Store.get(:smalt_resource_groups, String.downcase(rg_id)) do
        {:ok, existing} when is_map(existing) -> existing
        _ -> nil
      end

    # EXPL9-R2 F3: real Azure requires `location` on CREATE. A PUT with an
    # empty/no-location body previously fell through to the "eastus" default
    # and minted a silently wrong record (success-on-missing-field). Updates
    # keep the R30 semantics: location immutable, defaulted value tolerated.
    refused_create? =
      is_nil(existing) and not Map.has_key?(payload, "location")

    # ARM treats a resource group's location as immutable on update (R30):
    # an update PUT that changes location is refused with a typed 400,
    # never a silent overwrite of the original.
    refused_update? =
      existing != nil and Map.get(existing, "location") != requested

    cond do
      refused_create? ->
        send_arm_error(
          conn,
          400,
          "LocationRequired",
          "The request body must specify a 'location' for resource group creation. Location: cannot be null or empty.",
          rg_id
        )

      refused_update? ->
        send_arm_error(
          conn,
          400,
          "LocationMismatch",
          "Resource group location cannot be changed. Existing location '#{Map.get(existing, "location")}' does not match requested location '#{requested}'.",
          rg_id
        )

      true ->
        build_and_put_rg(conn, rg_id, rg_name, payload)
    end
  end

  defp build_and_put_rg(conn, rg_id, rg_name, payload) do
    existed? = match?({:ok, _}, Store.get(:smalt_resource_groups, String.downcase(rg_id)))

    rg = %{
      "id" => rg_id,
      "name" => rg_name,
      "type" => "Microsoft.Resources/resourceGroups",
      "location" => Map.get(payload, "location", "eastus"),
      "properties" => %{"provisioningState" => "Succeeded"},
      # SHIM-COURT tags (lane 428): normalization is split by write shape —
      # rg_tags/2 owns the contract (see its comment).
      "tags" => rg_tags(payload, existed?),
      "systemData" => @system_data
    }

    Store.put(:smalt_resource_groups, String.downcase(rg_id), rg)
    :ok = ProviderState.touch_lifecycle(rg_id)

    # V7 lane: RG-level writes join the activity log (previously only generic
    # resource PUT/PATCH/DELETE were hooked — an RG-put alone never appeared).
    # Fail-safe post-store sideband, same law as the resource hooks.
    Smalt.ArmGateway.ActivityLog.record(conn, :write, rg_id, rg_name)

    send_json(conn, if(existed?, do: 200, else: 201), Jason.encode!(rg))
  end

  defp handle_rg_get(conn, sub_id, rg_name) do
    with :ok <- check_api_version(conn, @rg_type) do
      do_rg_get(conn, sub_id, rg_name)
    else
      {:respond, conn} -> conn
    end
  end

  defp do_rg_get(conn, sub_id, rg_name) do
    rg_id = "/subscriptions/#{sub_id}/resourceGroups/#{rg_name}"

    case Store.get(:smalt_resource_groups, String.downcase(rg_id)) do
      {:ok, rg} ->
        if renderable_record?(rg) do
          # SHIM-COURT tags: GET normalizes via normalize_tags/1 (null-when-empty).
          send_json(conn, 200, Jason.encode!(normalize_rg(rg)))
        else
          # Deny-by-default (lens-11): a malformed record is not provably the
          # requested resource group — 404, never a 500.
          send_arm_error(
            conn,
            404,
            "ResourceGroupNotFound",
            "Resource group '#{rg_name}' could not be found.",
            rg_id
          )
        end

      :error ->
        send_arm_error(
          conn,
          404,
          "ResourceGroupNotFound",
          "Resource group '#{rg_name}' could not be found.",
          rg_id
        )
    end
  end

  # ARM RG delete is an LRO: 202 + Location polling URL + Retry-After (C1 row
  # 4, fixed). The RG and every resource inside it are removed from the Store
  # (cascade — previously children were orphaned and stayed GETable), and an
  # operation record backs the polling URL so the delete poll terminates.
  defp handle_rg_delete(conn, sub_id, rg_name) do
    with :ok <- check_api_version(conn, @rg_type) do
      do_rg_delete(conn, sub_id, rg_name)
    else
      {:respond, conn} -> conn
    end
  end

  defp do_rg_delete(conn, sub_id, rg_name) do
    rg_id = "/subscriptions/#{sub_id}/resourceGroups/#{rg_name}"
    _base = String.downcase("/subscriptions/#{sub_id}/resourceGroups/#{rg_name}/")

    # Real ARM returns 404 ResourceGroupNotFound for a delete of a nonexistent
    # RG, not 202 + a phantom LRO (R30). Same envelope shape as do_rg_get/3.
    # SHIM-COURT affidavit-seal (lane 611): the RG record is captured here so
    # the delete cascade can seal its canonical bytes before removal.
    {exists?, rg} =
      case Store.get(:smalt_resource_groups, String.downcase(rg_id)) do
        {:ok, rg} -> {renderable_record?(rg), rg}
        :error -> {false, nil}
      end

    if exists? do
      # Management-lock gate (KD-113 leg b, wave-4 lane w4d): a CanNotDelete or
      # ReadOnly lock covering the RG refuses the delete with 409 ScopeLocked.
      if Policy.lock_blocks?(rg_id, :delete) do
        send_json(conn, 409, lock_scope_locked_body(rg_id))
      else
        do_rg_delete_confirmed(conn, sub_id, rg_name, rg_id, rg)
      end
    else
      send_rg_not_found(conn, rg_id, rg_name)
    end
  end

  # The lock-cleared delete body (wave-4 lane w4d): affidavit seal -> RG row
  # delete -> keyed cascade -> LRO 202. Split from do_rg_delete/3 so the
  # ScopeLocked refusal returns before any mutation.
  defp do_rg_delete_confirmed(conn, sub_id, rg_name, rg_id, rg) do
    base = String.downcase("/subscriptions/#{sub_id}/resourceGroups/#{rg_name}/")

    # SHIM-COURT affidavit-seal (lane 611): capture-then-sweep — the RG
    # record is sealed BEFORE deletion (state_delta = the deleted record's
    # canonical bytes). Best-effort sideband: never affects the 202.
    affidavit_seal(rg, %{
      subject: String.downcase(rg_id),
      lease_context: "/subscriptions/#{sub_id}/resourceGroups/#{rg_name}"
    })

    Store.delete(:smalt_resource_groups, String.downcase(rg_id))

    # Cascade by STORE KEY, never by the record's own "id" member (lens-11,
    # measured): list_prefix/2 returns records, and a malformed (non-map)
    # child — only reachable via a direct external write — raised
    # FunctionClauseError inside Access.get/3, 500-ing the whole delete and
    # leaking every remaining child. Store keys ARE the lowercased full ids,
    # so deleting by key is exact and needs no read of the record at all.
    # Capture-then-sweep: extract the storageAccount names from the swept
    # ARM keys BEFORE deleting them, so each account's data-plane rows
    # (blob containers/blobs/policies, D127) are cascade-swept too.
    swept_keys = Store.prefix_keys(:smalt_resources, base)

    for key <- swept_keys do
      Store.delete(:smalt_resources, key)
    end

    for acct <- storage_account_names(swept_keys) do
      BlobStorage.drop_account_data(acct)
    end

    # FR-6: the vault branch of the cascade. Keys in :smalt_vault_secrets are
    # bare secret names, so capture them from the swept ARM keys BEFORE the
    # rows are gone (capture-then-sweep, same shape as storage_account_names).
    vault_secret_sweep(swept_keys)

    # Cosmos pk_meta cascade (composite-identity lane): capture-then-sweep
    # from the swept ARM keys BEFORE deletion — extract db/coll names from
    # swept sqlDatabases/sqlContainers keys, then drop the pk_meta rows.
    cosmos_sweep(swept_keys)

    op = LRO.start_op(rg_id)
    authority = request_authority(conn)

    # V7 lane: the RG delete (cascade complete, LRO minted) records one
    # activity-log event — operationName Microsoft.Resources/resourceGroups/delete.
    Smalt.ArmGateway.ActivityLog.record(conn, :delete, rg_id, rg_name)

    conn
    |> put_resp_header("location", "#{authority}#{op["id"]}")
    |> put_resp_header("retry-after", "1")
    |> send_json(202, "")
  end

  defp send_rg_not_found(conn, rg_id, rg_name) do
    send_arm_error(
      conn,
      404,
      "ResourceGroupNotFound",
      "Resource group '#{rg_name}' could not be found.",
      rg_id
    )
  end

  # -- KD-113 tags leg: tags-at-scope handlers ---------------------------------

  # api-version presence check mirrors the providers listing gate (the
  # Microsoft.Resources/tags surface is not a Registry individual, so use the
  # presence-only nil form).
  defp handle_scope_tags_get(conn, sub_id, rg_name) do
    with :ok <- check_api_version(conn, nil) do
      rg_id = "/subscriptions/#{sub_id}/resourceGroups/#{rg_name}"

      case Store.get(:smalt_resource_groups, String.downcase(rg_id)) do
        {:ok, rg} ->
          send_json(conn, 200, Jason.encode!(scope_tags_envelope(rg)))

        :error ->
          send_rg_not_found(conn, rg_id, rg_name)
      end
    else
      {:respond, conn} -> conn
    end
  end

  # PUT = FULL REPLACE (omitted/empty tags REMOVE the stored tags — same law
  # as rg_tags/2), PATCH = MERGE. Tags land on the RG record's "tags" member:
  # the RG GET path (normalize_tags/1) and the RG delete cascade see them
  # with zero extra sweep code.
  defp handle_scope_tags_put(conn, sub_id, rg_name, mode) do
    with :ok <- check_api_version(conn, nil) do
      rg_id = "/subscriptions/#{sub_id}/resourceGroups/#{rg_name}"

      case Store.get(:smalt_resource_groups, String.downcase(rg_id)) do
        {:ok, rg} ->
          incoming = scope_tags_incoming(conn.body_params)

          merged =
            case mode do
              :replace -> incoming
              :merge -> Map.merge(Map.get(rg, "tags") || %{}, incoming)
            end

          rg = Map.put(rg, "tags", normalize_tags(merged))
          Store.put(:smalt_resource_groups, String.downcase(rg_id), rg)
          send_json(conn, 200, Jason.encode!(scope_tags_envelope(rg)))

        :error ->
          send_rg_not_found(conn, rg_id, rg_name)
      end
    else
      {:respond, conn} -> conn
    end
  end

  defp scope_tags_envelope(rg) do
    %{"name" => "default", "properties" => %{"tags" => normalize_tags(Map.get(rg, "tags"))}}
  end

  # KD-COVERS: KD-58 — the tags/default PUT body at resource scope is
  # {"properties":{"tags":{...}}} (2022-09-01 tags API), not just top-level
  # {"tags":{...}}. Both shapes accepted; properties wins when both present.
  defp scope_tags_incoming(%{"properties" => %{"tags" => %{} = tags}}), do: tags
  defp scope_tags_incoming(%{"tags" => %{} = tags}), do: tags
  defp scope_tags_incoming(_), do: %{}

  # -- KD-COVERS: KD-58 — tenant tagNames CRUD over the :smalt_policy table
  # ("tagname:" prefix; discriminated-prefix law, KD-125 precedent).

  defp tagname_key(name), do: "tagname:" <> String.downcase(name)

  defp tagname_record(name, values) do
    %{
      "id" => "/tagNames/#{name}",
      "name" => name,
      "type" => "Microsoft.Resources/tags",
      "properties" => %{
        "tags" => Map.new(values, fn {v, _count} -> {v, "tagValue"} end)
      }
    }
  end

  defp handle_tenant_tags_list(conn) do
    with :ok <- check_api_version(conn, nil) do
      tags =
        :smalt_policy
        |> Store.list_prefix("tagname:")
        |> Enum.filter(fn rec -> is_map(rec) and rec["type"] == "Microsoft.Resources/tags" end)

      send_json(conn, 200, Jason.encode!(%{"value" => tags}))
    else
      {:respond, conn} -> conn
    end
  end

  defp handle_tenant_tags_get(conn, tag_name) do
    with :ok <- check_api_version(conn, nil) do
      case Store.get(:smalt_policy, tagname_key(tag_name)) do
        {:ok, rec} -> send_json(conn, 200, Jason.encode!(rec))
        :error -> send_json(conn, 404, tagname_not_found(tag_name))
      end
    else
      {:respond, conn} -> conn
    end
  end

  defp handle_tenant_tags_delete(conn, tag_name) do
    with :ok <- check_api_version(conn, nil) do
      case Store.get(:smalt_policy, tagname_key(tag_name)) do
        {:ok, rec} ->
          for {value, _} <- Map.get(rec, "values", %{}) do
            Store.delete(:smalt_policy, tagvalue_key(tag_name, value))
          end

          Store.delete(:smalt_policy, tagname_key(tag_name))
          send_json(conn, 200, "")

        :error ->
          send_json(conn, 404, tagname_not_found(tag_name))
      end
    else
      {:respond, conn} -> conn
    end
  end

  defp handle_tenant_tag_value_put(conn, tag_name, tag_value) do
    with :ok <- check_api_version(conn, nil) do
      now = DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()

      rec =
        case Store.get(:smalt_policy, tagname_key(tag_name)) do
          {:ok, rec} -> rec
          :error -> tagname_record(tag_name, %{})
        end

      values = Map.put(Map.get(rec, "values", %{}), tag_value, now)
      rec = Map.put(rec, "values", values)
      Store.put(:smalt_policy, tagname_key(tag_name), rec)

      Store.put(
        :smalt_policy,
        tagvalue_key(tag_name, tag_value),
        tagvalue_record(tag_name, tag_value)
      )

      send_json(conn, 201, Jason.encode!(tagvalue_record(tag_name, tag_value)))
    else
      {:respond, conn} -> conn
    end
  end

  defp handle_tenant_tag_value_get(conn, tag_name, tag_value) do
    with :ok <- check_api_version(conn, nil) do
      case Store.get(:smalt_policy, tagvalue_key(tag_name, tag_value)) do
        {:ok, rec} -> send_json(conn, 200, tagvalue_json(rec))
        :error -> send_json(conn, 404, tagvalue_not_found(tag_name, tag_value))
      end
    else
      {:respond, conn} -> conn
    end
  end

  defp handle_tenant_tag_value_delete(conn, tag_name, tag_value) do
    with :ok <- check_api_version(conn, nil) do
      case Store.get(:smalt_policy, tagvalue_key(tag_name, tag_value)) do
        {:ok, _rec} ->
          Store.delete(:smalt_policy, tagvalue_key(tag_name, tag_value))

          case Store.get(:smalt_policy, tagname_key(tag_name)) do
            {:ok, rec} ->
              values = Map.delete(Map.get(rec, "values", %{}), tag_value)

              if values == %{} do
                # last value gone: delete the tagName row itself (real ARM
                # deletes a tag with no remaining values)
                Store.delete(:smalt_policy, tagname_key(tag_name))
              else
                rec = Map.put(rec, "values", values)
                Store.put(:smalt_policy, tagname_key(tag_name), rec)
              end

              send_json(conn, 200, "")

            :error ->
              Store.delete(:smalt_policy, tagname_key(tag_name))
              send_json(conn, 200, "")
          end

        :error ->
          send_json(conn, 404, tagvalue_not_found(tag_name, tag_value))
      end
    else
      {:respond, conn} -> conn
    end
  end

  defp tagvalue_key(name, value), do: tagname_key(name) <> "/tagValues/" <> String.downcase(value)

  defp tagvalue_record(name, value) do
    %{
      "id" => "/tagNames/#{name}/tagValues/#{value}",
      "name" => value,
      "type" => "Microsoft.Resources/tagValues",
      "properties" => %{"tagName" => name, "value" => value},
      "count" => %{"type" => "Modified", "value" => 0}
    }
  end

  defp tagvalue_json(rec), do: Jason.encode!(rec)

  defp tagname_not_found(tag_name) do
    Jason.encode!(%{
      "error" => %{
        "code" => "TagNotFound",
        "message" => "Tag '#{tag_name}' was not found."
      }
    })
  end

  defp tagvalue_not_found(name, value) do
    Jason.encode!(%{
      "error" => %{
        "code" => "TagValueNotFound",
        "message" => "Tag value '#{value}' of tag '#{name}' was not found."
      }
    })
  end

  # -- KD-COVERS: KD-59 — exportTemplate delegates to the wave-6 export face
  # (Smalt.Arm.ExportTemplate.export_rg/3), previously unrouted. Synchronous
  # 200 (terminal for ARM LRO pollers — documented boundary); an RG with no
  # exportable resources is a typed 404 (ResourceGroupResourceNotFound).
  defp handle_export_template(conn, sub_id, rg_name) do
    with :ok <- check_api_version(conn, nil) do
      case Smalt.Arm.ExportTemplate.export_rg(sub_id, rg_name) do
        {:ok, template} -> send_json(conn, 200, Jason.encode!(template))
        {:error, status, body} -> send_json(conn, status, Jason.encode!(body))
      end
    else
      {:respond, conn} -> conn
    end
  end

  # -- KD-COVERS: KD-59 — moveResources / validateMoveResources: TYPED
  # UNSUPPORTED (row close condition: routes OR typed refusal; falsifier:
  # "never 404"). Real Azure refuses moves of unsupported types with 400
  # MoveUnsupportedResourceType; the emulator names the boundary directly.
  defp handle_move_resources(conn, sub_id, rg_name) do
    with :ok <- check_api_version(conn, nil) do
      send_json(
        conn,
        400,
        Jason.encode!(%{
          "error" => %{
            "code" => "MoveUnsupportedResourceType",
            "message" =>
              "Resource move is not supported by this emulator for resources in " <>
                "/subscriptions/#{sub_id}/resourceGroups/#{rg_name}.",
            "target" => "/subscriptions/#{sub_id}/resourceGroups/#{rg_name}",
            "innererror" => %{}
          }
        })
      )
    else
      {:respond, conn} -> conn
    end
  end

  # -- Management locks (KD-113 leg b): wired to Smalt.Policy (wave-4 lane w4d).
  # PUT/GET/DELETE/LIST at RG and subscription scope, api-version 2016-09-01
  # (monotonic-admission: <= the admitted 2020-05-01 latest). Inline envelopes,
  # NOT send_arm_error/5 — its (status, code) set is pinned by the
  # arm_error_corpus meta-test.
  defp handle_lock_put(conn, scope_prefix, lock_name) do
    with :ok <- check_api_version(conn, "Microsoft.Authorization/locks") do
      case Policy.put_lock(scope_prefix, lock_name, conn.body_params) do
        {:ok, record} -> send_json(conn, 201, Jason.encode!(record))
        {:error, refusal} -> send_json(conn, 400, Jason.encode!(refusal))
      end
    else
      {:respond, conn} -> conn
    end
  end

  defp handle_lock_get(conn, scope_prefix, lock_name) do
    with :ok <- check_api_version(conn, "Microsoft.Authorization/locks") do
      case Policy.get_lock(scope_prefix, lock_name) do
        {:ok, record} -> send_json(conn, 200, Jason.encode!(record))
        :error -> send_json(conn, 404, lock_not_found_body(scope_prefix, lock_name))
      end
    else
      {:respond, conn} -> conn
    end
  end

  defp handle_lock_delete(conn, scope_prefix, lock_name) do
    with :ok <- check_api_version(conn, "Microsoft.Authorization/locks") do
      case Policy.get_lock(scope_prefix, lock_name) do
        {:ok, _record} ->
          _ = Policy.delete_lock(scope_prefix, lock_name)
          send_json(conn, 200, "")

        :error ->
          send_json(conn, 404, lock_not_found_body(scope_prefix, lock_name))
      end
    else
      {:respond, conn} -> conn
    end
  end

  defp handle_locks_list(conn, scope_prefix) do
    with :ok <- check_api_version(conn, "Microsoft.Authorization/locks") do
      locks = Policy.list_locks(scope_prefix)
      send_json(conn, 200, Jason.encode!(%{"value" => locks}))
    else
      {:respond, conn} -> conn
    end
  end

  defp lock_not_found_body(scope_prefix, lock_name) do
    id = "#{scope_prefix}/providers/Microsoft.Authorization/locks/#{lock_name}"

    Jason.encode!(%{
      "error" => %{
        "code" => "LockNotFound",
        "message" => "Management lock '#{lock_name}' was not found at scope '#{scope_prefix}'.",
        "target" => id,
        "innererror" => %{}
      }
    })
  end

  # ScopeLocked (KD-113 leg b): the ROUTER owns the 409 mapping — same
  # inline-envelope law as Smalt.Policy.scope_locked_body (kept in sync).
  defp lock_scope_locked_body(rg_id) do
    Jason.encode!(%{
      "error" => %{
        "code" => "ScopeLocked",
        "message" =>
          "The scope '#{rg_id}' is locked at a level that blocks this operation. " <>
            "Remove the lock (Microsoft.Authorization/locks) to proceed.",
        "target" => rg_id,
        "innererror" => %{}
      }
    })
  end

  # -- AZURE-FIDELITY lane 4 handlers -------------------------------------------

  # Write verb of the lock law: a covering ReadOnly lock answers 409
  # ScopeLocked; :ok proceeds. In-with usable (with-else renders the
  # response via the shared {:respond, conn} arm).
  defp check_lock_write(conn, res_id) do
    if TagsLocks.write_gate(res_id) == :locked do
      # Immutable conn: rebind the send_json result (a discarded return here
      # returns the UNSSENT conn and the 409 never reaches the client).
      conn = send_json(conn, 409, lock_scope_locked_body(res_id))
      {:respond, conn}
    else
      :ok
    end
  end

  # Tags at SUBSCRIPTION scope: the tags API envelope rides the subscription
  # record's "tags" member (null-when-empty render law).
  defp handle_subscription_tags_get(conn, sub_id) do
    with :ok <- check_api_version(conn, nil) do
      case TagsLocks.subscription_record(sub_id) do
        {:ok, sub} ->
          send_json(
            conn,
            200,
            Jason.encode!(tags_scope_envelope("/subscriptions/#{sub_id}", Map.get(sub, "tags")))
          )

        :error ->
          send_arm_error(
            conn,
            404,
            "SubscriptionNotFound",
            "The subscription '#{sub_id}' was not found.",
            "/subscriptions/#{sub_id}"
          )
      end
    else
      {:respond, conn} -> conn
    end
  end

  defp handle_subscription_tags_put(conn, sub_id, mode) do
    with :ok <- check_api_version(conn, nil) do
      case TagsLocks.put_subscription_tags(sub_id, conn.body_params, mode) do
        {:ok, sub} ->
          send_json(
            conn,
            200,
            Jason.encode!(tags_scope_envelope("/subscriptions/#{sub_id}", Map.get(sub, "tags")))
          )

        :error ->
          send_arm_error(
            conn,
            404,
            "SubscriptionNotFound",
            "The subscription '#{sub_id}' was not found.",
            "/subscriptions/#{sub_id}"
          )
      end
    else
      {:respond, conn} -> conn
    end
  end

  defp tags_scope_envelope(scope_id, tags) do
    %{
      "id" => scope_id,
      "name" => "default",
      "type" => "Microsoft.Resources/tags",
      "properties" => %{"tags" => TagsLocks.normalize_tags(tags)}
    }
  end

  # Tags at RESOURCE scope: envelope over the resource record's "tags"
  # member. A covering ReadOnly lock refuses PUT/PATCH (409 ScopeLocked,
  # pre-mutation); unknown resource -> 404 ResourceNotFound.
  defp handle_resource_tags_get(conn, sub_id, rg_name, provider_ns, resource_type, resource_name) do
    with :ok <- check_api_version(conn, nil) do
      res_id = resource_id(sub_id, rg_name, provider_ns, resource_type, resource_name)

      case TagsLocks.resource_record(res_id) do
        {:ok, rec} ->
          send_json(conn, 200, Jason.encode!(tags_scope_envelope(res_id, Map.get(rec, "tags"))))

        :error ->
          send_arm_error(
            conn,
            404,
            "ResourceNotFound",
            "The Resource '#{resource_name}' was not found.",
            res_id
          )
      end
    else
      {:respond, conn} -> conn
    end
  end

  defp handle_resource_tags_put(
         conn,
         sub_id,
         rg_name,
         provider_ns,
         resource_type,
         resource_name,
         mode
       ) do
    with :ok <- check_api_version(conn, nil) do
      res_id = resource_id(sub_id, rg_name, provider_ns, resource_type, resource_name)

      case TagsLocks.put_resource_tags(res_id, conn.body_params, mode) do
        {:ok, rec} ->
          send_json(conn, 200, Jason.encode!(tags_scope_envelope(res_id, Map.get(rec, "tags"))))

        :locked ->
          send_json(conn, 409, lock_scope_locked_body(res_id))

        :error ->
          send_arm_error(
            conn,
            404,
            "ResourceNotFound",
            "The Resource '#{resource_name}' was not found.",
            res_id
          )
      end
    else
      {:respond, conn} -> conn
    end
  end

  # THE LAW (lane 4): a covering CanNotDelete or ReadOnly lock refuses the
  # delete with the documented 409 ScopeLocked and the resource SURVIVES;
  # an unlocked delete is an ARM LRO (202 + Location + Retry-After) that
  # sweeps the record, its children (store-key prefix cascade), its metrics
  # series and its lane-1 lifecycle row.
  defp handle_resource_delete(conn, sub_id, rg_name, provider_ns, resource_type, resource_name) do
    with :ok <- check_api_version(conn, "#{provider_ns}/#{resource_type}") do
      res_id = resource_id(sub_id, rg_name, provider_ns, resource_type, resource_name)
      key = String.downcase(res_id)

      case TagsLocks.resource_record(res_id) do
        {:ok, rec} ->
          if is_map(rec) and renderable_record?(rec) do
            if TagsLocks.delete_gate(res_id) == :locked do
              send_json(conn, 409, lock_scope_locked_body(res_id))
            else
              for child <- Store.prefix_keys(:smalt_resources, key <> "/") do
                Store.delete(:smalt_resources, child)
              end

              Store.delete(:smalt_resources, key)
              Smalt.Metrics.drop(res_id)
              ProviderState.drop_lifecycle(res_id)

              # AZURE-FIDELITY lane 5: activity-log event for the completed
              # DELETE (fail-safe sideband — never alters the 202).
              Smalt.ArmGateway.ActivityLog.record(conn, :delete, res_id, rg_name)

              op = LRO.start_op(res_id)
              authority = request_authority(conn)

              conn
              |> put_resp_header("location", "#{authority}#{op["id"]}")
              |> put_resp_header("retry-after", "1")
              |> send_json(202, "")
            end
          else
            send_arm_error(
              conn,
              404,
              "ResourceNotFound",
              "The Resource '#{resource_name}' was not found.",
              res_id
            )
          end

        :error ->
          send_arm_error(
            conn,
            404,
            "ResourceNotFound",
            "The Resource '#{resource_name}' was not found.",
            res_id
          )
      end
    else
      {:respond, conn} -> conn
    end
  end

  defp handle_resource_put(conn, raw_type, sub_id, rg_name, resource_name) do
    with :ok <- check_api_version(conn, raw_type),
         {:ok, full_type} <- check_admitted(conn, raw_type),
         # Management-lock write gate (AZURE-FIDELITY lane 4): a covering
         # ReadOnly lock refuses the PUT with 409 ScopeLocked before any
         # mutation (KD-113 leg b law via Smalt.Policy.lock_blocks?/2).
         :ok <-
           check_lock_write(
             conn,
             resource_id(sub_id, rg_name, ns_of(full_type), leaf_of(full_type), resource_name)
           ),
         # Defaults hydrate BEFORE shape validation: every default is
         # validator-acceptable, so validating the merged body preserves
         # refusal semantics for genuinely invalid input while unblocking
         # sku-less storageAccounts PUTs. (SHIM-COURT lane 395)
         merged = Defaults.apply(full_type, conn.body_params),
         :ok <- check_shape(conn, full_type, merged),
         # Fail-closed fence (shacl-fuzz, v26.10.16): a non-map "properties"
         # member (e.g. a JSON array) passes the permissive local shape
         # validator but raises BadMapError in persist-time enrichment
         # (Defaults.enrich + Map.put on the properties member). A hostile
         # body must refuse typed (InvalidResourceShape), never crash the
         # record builder. (SHIM-COURT shacl-fuzz fence)
         :ok <- check_properties_member(conn, merged),
         # AZURE-FIDELITY lane 7: create-blade enforcement — the built record
         # is checked against SKU/region availability BEFORE any persistence
         # or policy evaluation. A virtualMachines PUT whose vmSize is
         # unavailable in the record's location answers the documented
         # SKUNotAvailableAvailability 409 (see the else clause below) and
         # never persists. check_put/1 is exported so lane 1/2 PUT surfaces
         # can share the same law.
         res_id =
           resource_id(sub_id, rg_name, ns_of(full_type), leaf_of(full_type), resource_name),
         payload = conn.body_params,
         record =
           build_resource_record(
             full_type,
             res_id,
             resource_name,
             payload,
             request_authority(conn)
           ),
         record = SkuQuota.ensure_hardware_profile(record, payload),
         :ok <- SkuQuota.check_put(record, payload) do
      # Policy enforcement hook (80/20 Azure Policy, v26.10.16 lane): assigned
      # policies at RG then subscription scope gate the generic resource PUT.
      # deny -> 400 PolicyViolation (typed envelope emitted by Smalt.Policy,
      # inline — NOT send_arm_error, whose (status, code) set the
      # arm_error_corpus meta-test pins).
      case Policy.enforce(sub_id, rg_name, record) do
        :ok ->
          # GL28-2 admission gate (docs/jira/v26.10.28/GL28-2-SMALT-WIRE-SPEC.md
          # §3/§8): a mutation commits only behind the graphlaw_ex admission
          # turnstile — the proof of admission is the in-hand
          # {:admitted_mutation, ...} envelope, not a boolean. This step sits
          # AFTER the last refusal gate (Policy.enforce) and BEFORE the commit
          # (Store.put(:smalt_resources, ...)), so a gate refusal leaves state
          # byte-identical (spec §3.6: no write but the sanctioned OCEL refusal
          # frame).
          #
          # The gate module belongs to the parallel GL28-2 build lane and may
          # not be loaded yet: the call resolves at runtime behind a falsifiable
          # Code.ensure_loaded? + function_exported? guard (see
          # check_admission_gate/2), so this step is the sanctioned no-op stub
          # today and activates the moment the module lands — no further router
          # edit. (A literal Smalt.GraphlawEx.AdmissionGate.gate/3 dot-call
          # would warn "module not available" and fail
          # `mix compile --warnings-as-errors`.)
          with :ok <- check_admission_gate(conn, admission_envelope(conn)) do
            existed? = match?({:ok, _}, Store.get(:smalt_resources, String.downcase(res_id)))
            Store.put(:smalt_resources, String.downcase(res_id), record)

            # AZURE-FIDELITY lane 5: activity-log event for the completed PUT
            # (fail-safe sideband — never alters the response).
            Smalt.ArmGateway.ActivityLog.record(conn, :write, res_id, rg_name)

            # AZURE-FIDELITY lane 1: lifecycle timestamps for the documented
            # $expand=createdTime,changedTime list semantics — createdTime is
            # frozen on first PUT, changedTime advances on every write.
            :ok = ProviderState.touch_lifecycle(res_id)

            # Lifecycle metric point (Azure Monitor parity): every resource PUT is a
            # request datapoint on the resource's Requests series.
            Smalt.Metrics.emit(res_id, "Requests", 1)

            # SHIM-COURT affidavit-seal (lane 611): on every successful resource
            # PUT, ingest through the affidavit ingestion functor — tariff from
            # Smalt.FinOps.Calculator (F lane) with a deterministic local proxy
            # fallback, modality 0x01/0x02 by the $50M threshold, then the
            # fail-safe admit-and-seal sideband. Admission semantics unchanged:
            # a dead engine/refusal never alters the response below.
            affidavit_seal(record, %{
              subject: String.downcase(res_id),
              lease_context: "/subscriptions/#{sub_id}/resourceGroups/#{rg_name}"
            })

            # AZB-10: cross-plane emission — every successful resource PUT emits
            # the Event Grid Microsoft.Resources.ResourceWriteSuccess event to
            # the integration plane (Event Grid topic fan-out + Service Bus
            # bridge enqueue). Never alters the PUT response (fail-safe inside).
            #
            # KD-COVERS: KD-124 — the emission is a POST-STORE SIDEBAND: it runs
            # after Store.put, so any raise here turns a persisted resource into
            # a 500 (KD-124 wire witness: UndefinedFunctionError —
            # Smalt.EgressRouter.Peers not available on a stale substrate build —
            # 500'd the first `PUT .../namespaces/:ns` with sku AFTER the record
            # was stored; retry answered 200). Fail-safe: a raise/exit/throw from
            # the emission is logged and dropped, never propagated into the PUT
            # response.
            try do
              Smalt.EgressRouter.Peers.emit_resource_write_success(record, %{
                subscription: sub_id,
                resource_group: rg_name
              })
            rescue
              e ->
                Logger.warning(
                  "AZB-10 ResourceWriteSuccess emission dropped (KD-124 fail-safe): " <>
                    Exception.format(:error, e)
                )

                :ok
            catch
              :exit, e ->
                Logger.warning(
                  "AZB-10 ResourceWriteSuccess emission dropped (KD-124 fail-safe, exit): " <>
                    inspect(e)
                )

                :ok
            end

            cond do
              lro_type?(full_type) and not existed? ->
                # ARM LRO convention: create -> 202 + async headers (poll to terminal).
                op = LRO.start_op(res_id)
                async_put_response(conn, 202, op)

              lro_async_update_type?(full_type) ->
                # update -> 200 + async headers (ARM LRO PUT update convention).
                # Only the original witness set (storage/compute) is async on
                # update; the KD-111 widening keeps update SYNC per ARM/AZB-25b.
                op = LRO.start_op(res_id)
                async_put_response(conn, 200, op)

              existed? ->
                send_json(conn, 200, Jason.encode!(record))

              true ->
                send_json(conn, 201, Jason.encode!(record))
            end
          else
            # Typed gate refusal: rendered through the pinned GraphLaw refusal
            # face (send_graphlaw_refusal/3 — 400 InvalidResourceShape, message
            # names the SMALT-* code; router.ex:719 "ARM never returns 422"),
            # state untouched. Posture gate: :fail_open admits (spec §8
            # admit-and-seal sideband), so this clause only fires under
            # :fail_closed with the GL28-2 module loaded.
            {:respond, conn} -> conn
          end

        {:deny, body} ->
          conn
          |> put_resp_content_type("application/json")
          |> send_resp(400, body)
      end
    else
      {:respond, conn} ->
        conn

      # AZURE-FIDELITY lane 7: SKU unavailable in the requested region —
      # documented SKUNotAvailableAvailability 409 envelope, nothing persisted.
      {:refuse, sku, location} ->
        send_json(
          conn,
          409,
          Jason.encode!(%{
            "error" => %{
              "code" => "SKUNotAvailableAvailability",
              "message" =>
                "Requested operation could not be completed because the SKU " <>
                  "(#{sku}) is not available in location '#{location}'. " <>
                  "Please try a different location or SKU.",
              "target" => sku,
              "innererror" => %{}
            }
          })
        )
    end
  end

  defp handle_resource_get(conn, sub_id, rg_name, provider_ns, resource_type, resource_name) do
    with :ok <- check_api_version(conn, "#{provider_ns}/#{resource_type}") do
      res_id = resource_id(sub_id, rg_name, provider_ns, resource_type, resource_name)

      case Store.get(:smalt_resources, String.downcase(res_id)) do
        {:ok, record} ->
          if renderable_record?(record) do
            send_json(conn, 200, Jason.encode!(record))
          else
            # Deny-by-default (lens-11): malformed record → 404, never 500.
            send_arm_error(
              conn,
              404,
              "ResourceNotFound",
              "The Resource '#{resource_name}' was not found.",
              res_id
            )
          end

        :error ->
          res_id = resource_id(sub_id, rg_name, provider_ns, resource_type, resource_name)

          send_arm_error(
            conn,
            404,
            "ResourceNotFound",
            "The Resource '#{resource_name}' was not found.",
            res_id
          )
      end
    else
      {:respond, conn} -> conn
    end
  end

  # KD-57 handler: ARM PATCH merge semantics over the stored record.
  # # KD-COVERS: KD-57
  defp handle_resource_patch(conn, raw_type, sub_id, rg_name, resource_name) do
    with :ok <- check_api_version(conn, raw_type),
         {:ok, full_type} <- check_admitted(conn, raw_type),
         # Management-lock write gate (AZURE-FIDELITY lane 4): a covering
         # ReadOnly lock refuses the PATCH with 409 ScopeLocked before any
         # mutation (KD-113 leg b law via Smalt.Policy.lock_blocks?/2).
         :ok <-
           check_lock_write(
             conn,
             resource_id(sub_id, rg_name, ns_of(full_type), leaf_of(full_type), resource_name)
           ),
         # Fail-closed fence parity with PUT (shacl-fuzz): a non-map
         # "properties" member must refuse typed, never crash the merge.
         :ok <- check_properties_member(conn, conn.body_params) do
      res_id = resource_id(sub_id, rg_name, ns_of(full_type), leaf_of(full_type), resource_name)
      key = String.downcase(res_id)

      case Store.get(:smalt_resources, key) do
        {:ok, existing} when is_map(existing) ->
          patched = merge_patch_body(existing, conn.body_params)

          case Policy.enforce(sub_id, rg_name, patched) do
            :ok ->
              Store.put(:smalt_resources, key, patched)

              # AZURE-FIDELITY lane 5: activity-log event for the completed
              # PATCH (fail-safe sideband — never alters the response).
              Smalt.ArmGateway.ActivityLog.record(conn, :write, res_id, rg_name)
              send_json(conn, 200, Jason.encode!(patched))

            {:deny, body} ->
              conn
              |> put_resp_content_type("application/json")
              |> send_resp(400, body)
          end

        _ ->
          send_arm_error(
            conn,
            404,
            "ResourceNotFound",
            "The Resource '#{resource_name}' was not found.",
            res_id
          )
      end
    else
      {:respond, conn} -> conn
    end
  end

  # KD-57: partial-update merge — `properties` deep-ish merge (one level, the
  # ARM PATCH surface azurerm exercises), `tags`/`sku` replace when present.
  defp merge_patch_body(record, body) when is_map(body) do
    record =
      Map.update(record, "properties", %{}, fn props ->
        Map.merge(props, Map.get(body, "properties", %{}))
      end)

    record =
      if Map.has_key?(body, "tags"),
        do: %{record | "tags" => normalize_tags(Map.get(body, "tags"))},
        else: record

    if Map.has_key?(body, "sku"), do: %{record | "sku" => Map.get(body, "sku")}, else: record
  end

  # -- Azure Monitor metrics handlers -------------------------------------------
  # GET: bucketed timeseries for `metricnames` (default Requests); unknown
  # resource -> typed EMPTY value[] envelope (real Azure Monitor semantics —
  # querying metrics for a resource that does not exist 200s with no series).
  defp handle_metrics(conn, sub_id, rg_name, provider_ns, resource_type, resource_name) do
    with :ok <- check_api_version(conn, nil),
         :ok <- check_metrics_api_version(conn) do
      res_id = resource_id(sub_id, rg_name, provider_ns, resource_type, resource_name)

      case Store.get(:smalt_resources, String.downcase(res_id)) do
        {:ok, record} when is_map(record) ->
          metric = conn.query_params["metricnames"] || Smalt.Metrics.default_metric()
          {start_ms, end_ms} = Smalt.Metrics.parse_timespan(conn.query_params["timespan"])

          interval =
            case Smalt.Metrics.parse_interval(conn.query_params["interval"]) do
              {:ok, ms} -> ms
              :error -> 60_000
            end

          series = Smalt.Metrics.query(res_id, metric, start_ms, end_ms, interval)

          send_json(conn, 200, Jason.encode!(%{"value" => [series]}))

        _ ->
          # Telemetry accumulator fallback (wave-6 w6q): resources with no
          # lifecycle/custom metric points may still carry LIVE traffic
          # metrics (Requests/RequestDuration) recorded by
          # Smalt.Monitor.Metrics from real :telemetry events. Serve the
          # accumulator's series when it has rows; else the real-Azure
          # empty-value envelope.
          metric = conn.query_params["metricnames"] || Smalt.Metrics.default_metric()

          {start_ms, end_ms} = Smalt.Metrics.parse_timespan(conn.query_params["timespan"])

          interval =
            case Smalt.Metrics.parse_interval(conn.query_params["interval"]) do
              {:ok, ms} -> ms
              :error -> 60_000
            end

          acc_rows =
            Smalt.Monitor.Metrics.raw_rows()
            # raw_rows/0 is a MAP {%{key => value}}: Enum over it yields
            # {key, value} 2-tuples ({ {r,m,b} => {c,s,mx} }). The old
            # 3-tuple clause {r, m, _b} never matched -> FunctionClauseError
            # -> 500 on every metrics query once platform rows exist
            # (EXPL12-B monitor witness, 2026-10-22). The subsequent
            # pipe-continuation predicate (starts_with? r, res_id <> "|")
            # was likewise dead: record/4 keys rows {downcased resource,
            # metric, bucket} with nothing after the resource — the "|"
            # idiom belongs to Smalt.Metrics' string-keyed table, not this
            # tuple-keyed ETS (BK-MON3-F1, bkmon3r-deadjoin-fix).
            # Match the real shape: exact downcased resource equality.
            |> Enum.count(fn {{r, m, _b}, _v} ->
              r == String.downcase(res_id) and m == metric
            end)

          if acc_rows > 0 do
            series = Smalt.Monitor.Metrics.series(res_id, metric, start_ms, end_ms, interval)
            send_json(conn, 200, Jason.encode!(%{"value" => [series]}))
          else
            send_json(conn, 200, Jason.encode!(%{"value" => []}))
          end
      end
    else
      {:respond, conn} -> conn
    end
  end

  # GET platform pseudo-resource metric face (BK-PLATFORM-ROUTE, v26.10.22).
  # Serves the accumulator's platform rows through the SAME series/5 path the
  # per-resource fallback uses — exact downcased-equality join on
  # `Smalt.Monitor.Metrics.platform_resource()` (the platform key carries no
  # leading slash by construction, unlike parsed ARM ids), else the
  # real-Azure empty envelope. Store-miss semantics are platform-native: the
  # platform pseudo-resource is never in :smalt_resources, so this handler
  # goes straight to the accumulator (no Store probe).
  defp handle_metrics_platform(conn) do
    with :ok <- check_api_version(conn, nil),
         :ok <- check_metrics_api_version(conn) do
      metric = conn.query_params["metricnames"] || Smalt.Metrics.default_metric()

      {start_ms, end_ms} = Smalt.Metrics.parse_timespan(conn.query_params["timespan"])

      interval =
        case Smalt.Metrics.parse_interval(conn.query_params["interval"]) do
          {:ok, ms} -> ms
          :error -> 60_000
        end

      res_id = Smalt.Monitor.Metrics.platform_resource()

      acc_rows =
        Smalt.Monitor.Metrics.raw_rows()
        |> Enum.count(fn {{r, m, _b}, _v} ->
          r == String.downcase(res_id) and m == metric
        end)

      if acc_rows > 0 do
        series = Smalt.Monitor.Metrics.series(res_id, metric, start_ms, end_ms, interval)
        send_json(conn, 200, Jason.encode!(%{"value" => [series]}))
      else
        send_json(conn, 200, Jason.encode!(%{"value" => []}))
      end
    else
      {:respond, conn} -> conn
    end
  end

  # POST: custom metric emit. Body {time, metric, value, unit} (coarse Azure
  # custom-metrics shape); any of time/unit may be omitted (now / Count).
  defp handle_metrics_emit(conn, sub_id, rg_name, provider_ns, resource_type, resource_name) do
    with :ok <- check_api_version(conn, nil),
         :ok <- check_metrics_api_version(conn),
         %{} = body <- conn.body_params,
         metric = body["metric"] || Smalt.Metrics.default_metric(),
         true <- is_number(body["value"]) || {:respond, metrics_bad_request(conn, "value")} do
      res_id = resource_id(sub_id, rg_name, provider_ns, resource_type, resource_name)

      case Store.get(:smalt_resources, String.downcase(res_id)) do
        {:ok, record} when is_map(record) ->
          ts_ms =
            case body["time"] do
              t when is_binary(t) ->
                case DateTime.from_iso8601(t) do
                  {:ok, dt, _} -> DateTime.to_unix(dt, :millisecond)
                  _ -> Smalt.Metrics.now_ms()
                end

              _ ->
                Smalt.Metrics.now_ms()
            end

          unit = if is_binary(body["unit"]), do: body["unit"], else: "Count"

          Smalt.Metrics.emit(res_id, metric, body["value"], ts_ms, unit)
          send_json(conn, 200, Jason.encode!(%{"value" => [metric]}))

        _ ->
          send_arm_error(
            conn,
            404,
            "ResourceNotFound",
            "The Resource '#{resource_name}' was not found.",
            res_id
          )
      end
    else
      {:respond, conn} -> conn
      _ -> metrics_bad_request(conn, "body")
    end
  end

  # Metrics api-version is monotonic per the family pattern (KD-78 shape):
  # any version <= the family latest is accepted; newer/malformed refused.
  defp check_metrics_api_version(conn) do
    version = conn.query_params["api-version"]

    if Smalt.Metrics.version_admitted?(version) do
      :ok
    else
      {:respond,
       send_arm_error(
         conn,
         400,
         "InvalidApiVersionParameter",
         "The api-version '#{version}' is invalid. The latest supported api-version for 'microsoft.insights/metrics' is '#{Smalt.Metrics.latest_api_version()}'."
       )}
    end
  end

  defp metrics_bad_request(conn, field) do
    send_json(
      conn,
      400,
      Jason.encode!(%{
        "error" => %{
          "code" => "BadRequest",
          "message" => "The metrics emit body is missing a valid '#{field}' member."
        }
      })
    )
  end

  # Wave-2 storefront PUT body handling: every PUT handler validates the
  # MERGED body (Defaults-before-check_shape — handle_resource_put,
  # handle_child_put, handle_marketplace_put, handle_cosmos_child_put all
  # share this order); build_resource_record then re-merges so the stored
  # record carries the defaults deep-merged under the user body.
  # location/tags always come from the RAW payload — never the defaults'
  # "[resourceGroup().location]" / "[subscription().tenantId]" template
  # strings, which are DURMT expressions (azurerm interpolation), not values
  # the emulator can resolve.
  defp build_resource_record(full_type, id, name, payload, authority \\ nil)

  defp build_resource_record(full_type, id, name, payload, authority) when is_map(payload) do
    merged = Defaults.apply(full_type, payload)

    record = %{
      "id" => id,
      "name" => name,
      "type" => full_type,
      # location from RAW payload only — never the defaults' template string.
      "location" => Map.get(payload, "location", "eastus"),
      # properties from MERGED (deep-merged defaults under user properties),
      # then name-interpolated enrichment (vaultUri, primaryEndpoints,
      # namespace property sets) deep-merged UNDER at the record level —
      # persist-time only, so GET stays verbatim. The request authority is
      # threaded through so loopback-facing enrichments (vaultUri,
      # KD-T5-F1) resolve from the client's seat.
      "properties" =>
        full_type
        |> Defaults.enrich(name, id, merged, authority)
        |> Map.get("properties", %{})
        |> Map.put("provisioningState", "Succeeded"),
      # SHIM-COURT tags: coerce via normalize_tags/1 (null-when-empty);
      # the RG update full-replace law lives in rg_tags/2 only.
      "tags" => normalize_tags(Map.get(payload, "tags")),
      "systemData" => @system_data
    }

    record
    |> maybe_put_sku(merged)
    |> maybe_put_kind(merged)
  end

  defp build_resource_record(full_type, id, name, _payload, _authority) do
    %{
      "id" => id,
      "name" => name,
      "type" => full_type,
      "location" => "eastus",
      "properties" => %{"provisioningState" => "Succeeded"},
      "tags" => %{},
      "systemData" => @system_data
    }
  end

  # Tolerant of a missing/blank key: only a non-empty sku map or kind string
  # from the merged body is lifted onto the record (storage/cosmos defaults
  # carry them; the vault defaults keep sku inside properties).
  defp maybe_put_sku(record, merged) do
    case Map.get(merged, "sku") do
      %{} = sku when map_size(sku) > 0 -> Map.put(record, "sku", sku)
      _ -> record
    end
  end

  defp maybe_put_kind(record, merged) do
    case Map.get(merged, "kind") do
      kind when is_binary(kind) and kind != "" -> Map.put(record, "kind", kind)
      _ -> record
    end
  end

  # Refusal-tier gate chain for child PUTs (repair lane, refusal-tier
  # ordering): shared by handle_child_put/5 and the parent-missing branch of
  # handle_parented_child/7 so the deep-type refusal tier (api-version →
  # admission → shape → properties-member) fires BEFORE the parent-existence
  # 404. A malformed body on a parented-child route answers 400
  # InvalidResourceShape even when the parent is absent; a well-formed body
  # with a missing parent still answers 404 ResourceNotFound (parent gating).
  defp validate_child_put(conn, child_type) do
    with :ok <- check_api_version(conn, child_type),
         {:ok, full_type} <- check_admitted(conn, child_type),
         # Defaults hydrate BEFORE shape validation (see handle_resource_put).
         merged = Defaults.apply(full_type, conn.body_params),
         :ok <- check_shape(conn, full_type, merged),
         # Fail-closed fence (shacl-fuzz, v26.10.16): a non-map "properties"
         # member (e.g. a JSON array) passes the permissive local shape
         # validator but raises BadMapError in persist-time enrichment
         # (Defaults.enrich + Map.put on the properties member). A hostile
         # body must refuse typed (InvalidResourceShape), never crash the
         # record builder. (SHIM-COURT shacl-fuzz fence)
         :ok <- check_properties_member(conn, merged),
         # GL28-2 admission-gate tier (spec §8 mirror of handle_resource_put):
         # the receipt gate rides the shared child-PUT chain so handle_child_put
         # and handle_parented_child both commit only behind the turnstile —
         # BEFORE the Store.put commit in handle_child_put and at the same
         # refusal tier as the resource PUT. Same runtime-resolved stub until
         # the GL28-2 module lands (see check_admission_gate/2).
         :ok <- check_admission_gate(conn, admission_envelope(conn)) do
      {:ok, full_type, merged}
    else
      {:respond, conn} -> {:respond, conn}
    end
  end

  # KD-COVERS: KD-92 — blob container child PUT with a data-plane mirror.
  # Identical admission to handle_child_put/5 (api-version, shape, record
  # build, 200/201 semantics); on a successful PUT the container record is
  # mirrored into `:smalt_blob_containers` so the blob data plane sees the
  # ARM-created container (real-Azure parity). Mirrors only when absent;
  # skips silently when the blob tables are absent (control plane stays
  # independent of data-plane readiness — same contract as seed_cosmos_child).
  defp handle_storage_container_child_put(conn, sub_id, rg_name, parent, name) do
    handle_child_put(
      conn,
      "Microsoft.Storage/storageAccounts/blobServices/containers",
      sub_id,
      rg_name,
      "storageAccounts/#{parent}/blobServices/default/containers/#{name}",
      &seed_blob_container(parent, name, &1)
    )
  end

  defp seed_blob_container(parent, name, _record) do
    if :ets.info(:smalt_blob_containers) != :undefined do
      key = "#{parent}/#{name}"

      case Store.get(:smalt_blob_containers, key) do
        {:ok, _existing} ->
          # Data plane already has it (or an earlier mirror landed): never
          # clobber live WORM/immutability/policy state from the control plane.
          :ok

        :error ->
          now = System.os_time(:millisecond)

          Store.put(:smalt_blob_containers, key, %{
            "account" => parent,
            "container" => name,
            # KD-COVERS: KD-135 — engine default follows wire parity: writable
            # unless explicitly created immutable.
            "immutable" => false,
            "retention_days" => 1095,
            "created_at" => now,
            "created" => DateTime.from_unix!(now, :millisecond) |> DateTime.to_iso8601()
          })
      end
    end
  end

  defp handle_child_put(conn, child_type, sub_id, rg_name, rel_path, after_put \\ nil) do
    with {:ok, full_type, _merged} <- validate_child_put(conn, child_type) do
      id = "/subscriptions/#{sub_id}/resourceGroups/#{rg_name}/#{rel_path}"
      key = String.downcase(id)
      payload = conn.body_params

      name = rel_path |> String.split("/") |> List.last()
      record = build_resource_record(full_type, id, name, payload)

      existed? = match?({:ok, _}, Store.get(:smalt_resources, key))
      Store.put(:smalt_resources, key, record)

      # KD-COVERS: KD-86 — mirror sb_child_put's AMQP materialization face:
      # an ARM PUT of an AMQP-backed child (ServiceBus queues/topics/
      # subscriptions) must materialize the entity row, never rely on
      # auto-create-on-send. No-op for non-AMQP child types.
      sb_materialize_amqp(child_type, rel_path)

      # KD-COVERS: KD-92 — optional post-PUT data-plane mirror hook (blob
      # containers). Runs only after the resource record landed, so the seed
      # never fires on a refused PUT; seed failures must never fail the ARM
      # PUT (control plane stays independent of data-plane readiness — same
      # contract as seed_cosmos_child).
      if is_function(after_put, 1),
        do: after_put.(record)

      send_json(conn, if(existed?, do: 200, else: 201), Jason.encode!(record))
    else
      {:respond, conn} -> conn
    end
  end

  defp handle_child_get(conn, child_type, sub_id, rg_name, rel_path) do
    with :ok <- check_api_version(conn, child_type) do
      key = String.downcase("/subscriptions/#{sub_id}/resourceGroups/#{rg_name}/#{rel_path}")

      case Store.get(:smalt_resources, key) do
        {:ok, record} ->
          if renderable_record?(record) do
            send_json(conn, 200, Jason.encode!(record))
          else
            # Deny-by-default (lens-11): malformed record → 404, never 500.
            name = rel_path |> String.split("/") |> List.last()

            send_arm_error(
              conn,
              404,
              "ResourceNotFound",
              "The Resource '#{name}' was not found.",
              "/subscriptions/#{sub_id}/resourceGroups/#{rg_name}/#{rel_path}"
            )
          end

        :error ->
          name = rel_path |> String.split("/") |> List.last()

          send_arm_error(
            conn,
            404,
            "ResourceNotFound",
            "The Resource '#{name}' was not found.",
            "/subscriptions/#{sub_id}/resourceGroups/#{rg_name}/#{rel_path}"
          )
      end
    else
      {:respond, conn} -> conn
    end
  end

  defp handle_child_list(conn, child_type, sub_id, rg_name, parent_rel_path) do
    with :ok <- check_api_version(conn, child_type) do
      prefix =
        String.downcase("/subscriptions/#{sub_id}/resourceGroups/#{rg_name}/#{parent_rel_path}/")

      send_list(conn, Store.list_prefix(:smalt_resources, prefix))
    else
      {:respond, conn} -> conn
    end
  end

  # Wave-2 ARM↔engine bridge (w2j) — verb bodies now owned by
  # Smalt.Arm.EhConsumerGroups (wave-6 lane w6j: $default immutability 400s,
  # duplicate-PUT 409, user-metadata echo). The router keeps the admission
  # gates (api-version / shape / properties-member) and delegates.
  # SHIM-COURT cg-default semantics preserved: $default appears in LIST
  # exactly once even if a client PUTs a literal "$default" (synthesis now
  # lives in EhConsumerGroups.list/2).
  @cg_child_type "Microsoft.EventHub/namespaces/eventhubs/consumergroups"

  defp handle_cg_engine(conn, verb, child_type, sub_id, rg_name, parent_rel, rel_path) do
    hub = parent_rel |> String.split("/") |> List.last()
    name = rel_path |> String.split("/") |> List.last()

    base = "/subscriptions/#{sub_id}/resourceGroups/#{rg_name}/#{parent_rel}/consumergroups"

    ctx = %{
      child_type: child_type,
      base: base,
      hub: hub,
      name: name,
      send_json: &send_json/3,
      send_arm_error: &send_arm_error/4,
      send_list: &send_list/2
    }

    case verb do
      :put ->
        with {:ok, _full_type, _merged} <- validate_child_put(conn, child_type) do
          EhConsumerGroups.put(conn, ctx)
        else
          {:respond, conn} -> conn
        end

      :get ->
        with :ok <- check_api_version(conn, child_type) do
          EhConsumerGroups.get(conn, ctx)
        else
          {:respond, conn} -> conn
        end

      :delete ->
        with :ok <- check_api_version(conn, child_type) do
          EhConsumerGroups.delete(conn, ctx)
        else
          {:respond, conn} -> conn
        end

      :list_cg ->
        EhConsumerGroups.list(conn, ctx)
    end
  end

  # Messaging children (ServiceBus queues/topics/subscriptions, EventHub
  # eventhubs/consumergroups) are ARM children of an existing parent namespace
  # (or topic/hub); PUT/GET/LIST/DELETE 404 ResourceNotFound when the parent
  # is absent — unlike the subnet/container pattern which skips parent gating.
  defp handle_parented_child(conn, verb, child_type, sub_id, rg_name, parent_rel, rel_path) do
    # Disclosed cross-lane unblock (api-version matrix fence lane): the tree
    # carries TWO storage conventions — generic-route parents are stored WITH
    # their providers/ prefix (resource_id/5 in handle_resource_put), while
    # child-route records are stored WITHOUT it (handle_child_put/5). Look up
    # the parent under both keys; without this every parented-child request
    # 404'd ResourceNotFound regardless of parent existence.
    provider_ns = child_type |> String.split("/") |> List.first()
    base = String.downcase("/subscriptions/#{sub_id}/resourceGroups/#{rg_name}/")

    parent_key =
      with {:ok, _} <-
             Store.get(
               :smalt_resources,
               String.downcase(base <> "providers/#{provider_ns}/#{parent_rel}")
             ) do
        {:ok, :prefixed}
      else
        _ ->
          with {:ok, _} <- Store.get(:smalt_resources, String.downcase(base <> parent_rel)) do
            {:ok, :unprefixed}
          else
            :error -> :error
          end
      end

    case parent_key do
      {:ok, _} ->
        case verb do
          # Wave-2 cg bridge: EventHub consumer-group children delegate to the
          # wave-1 engine (Smalt.Messaging.EventHubs cg_* surface) — created ts
          # preserved on re-PUT, `$default` undeletable (409), group-scoped
          # checkpoints cascade. The ARM Store still mirrors the record so the
          # shim-court-covered $default LIST keeps its store-driven shape.
          _ when child_type == @cg_child_type ->
            handle_cg_engine(conn, verb, child_type, sub_id, rg_name, parent_rel, rel_path)

          :put ->
            if String.starts_with?(child_type, "Microsoft.DocumentDB/databaseAccounts/sql") do
              handle_cosmos_child_put(conn, child_type, sub_id, rg_name, rel_path)
            else
              handle_child_put(conn, child_type, sub_id, rg_name, rel_path)
            end

          :get ->
            handle_child_get(conn, child_type, sub_id, rg_name, rel_path)

          :list ->
            handle_child_list(conn, child_type, sub_id, rg_name, parent_rel)

          # SHIM-COURT cg-default (2026-10-16, lane 526 KD row: EventHub
          # consumer-group enumeration) — real Azure always carries $default,
          # so the hub-scoped consumergroups LIST merges a synthesized $default
          # ahead of any stored records; a user-created "$default" record
          # renders verbatim exactly once.
          :list_cg ->
            base =
              "/subscriptions/#{sub_id}/resourceGroups/#{rg_name}/#{parent_rel}/consumergroups"

            EhConsumerGroups.list(conn, %{
              child_type: child_type,
              base: base,
              hub: parent_rel |> String.split("/") |> List.last(),
              name: "$default",
              send_json: &send_json/3,
              send_arm_error: &send_arm_error/4,
              send_list: &send_list/2
            })

          :delete ->
            handle_child_delete(conn, child_type, sub_id, rg_name, rel_path)
        end

      :error ->
        parent = parent_rel |> String.split("/") |> List.last()

        # Refusal-tier ordering (repair lane): on PUT the deep-type gate chain
        # (api-version/admission/shape/properties-member) fires BEFORE the
        # parent-existence 404 — a malformed body must answer 400
        # InvalidResourceShape over real dispatch even when the parent is
        # absent. GET/LIST/DELETE keep the bare parent 404.
        if verb == :put do
          case validate_child_put(conn, child_type) do
            {:respond, conn} -> conn
            {:ok, _full_type, _merged} -> parent_not_found(conn, parent)
          end
        else
          parent_not_found(conn, parent)
        end
    end
  end

  defp parent_not_found(conn, parent) do
    send_arm_error(conn, 404, "ResourceNotFound", "The parent #{parent} could not be found.")
  end

  # --- Service Bus topics/subscriptions (SB-TOPICS lane) -----------------------------
  #
  # SB-aware messaging-child handling for the topic + topic-subscription ARM
  # faces, layered on the same gate chain / storage as handle_parented_child:
  #
  #   1. PUT hydration — real Azure Service Bus defaults each entity's unset
  #      runtime properties; without hydration a bare PUT renders a resource
  #      whose GET lacks maxSizeInMegabytes / lockDuration / maxDeliveryCount,
  #      which real SDK models dereference.
  #   2. AMQP entity materialization — an ARM-wired topic (and each of its
  #      subscriptions) is provisioned into the queue store (`:smalt_sb_queues`)
  #      at PUT time, so SDK senders/subscribers attach immediately without
  #      waiting for the lazy ensure_queue on first link attach.
  #
  # KNOWN BRIDGE GAP (typed face, not a silent divergence): delivery is
  # queue-backed — a sender to topic "t" lands in the "t" entity and a
  # subscriber to "t/Subscriptions/s" claims from the "t/Subscriptions/s"
  # entity; messages sent to the topic do NOT fan out into subscription
  # entities. Fan-out belongs in the AMQP delivery engine (connection.ex /
  # queue_store.ex, outside this lane's file ownership). Receivers on a
  # subscription address attach cleanly (get 0 messages until fan-out lands).
  #
  # DELETE teardown removes the entity row from :smalt_sb_queues (and the
  # topic's subscription entities for a topic delete); in-flight message rows
  # keyed {queue, seq} in :smalt_sb_messages are left to the sweeper, matching
  # the queue_store lazy-allocation contract.

  @sb_topic_defaults %{
    "properties" => %{
      "maxSizeInMegabytes" => 1024,
      "defaultMessageTimeToLive" => "P14D",
      "status" => "Active",
      "supportOrdering" => true,
      "enableBatchedOperations" => true,
      "enablePartitioning" => false,
      "enableExpress" => false
    }
  }

  @sb_subscription_defaults %{
    "properties" => %{
      "lockDuration" => "PT5M",
      "maxDeliveryCount" => 10,
      "defaultMessageTimeToLive" => "P14D",
      "requiresSession" => false,
      "deadLetteringOnMessageExpiration" => false,
      "enableBatchedOperations" => true,
      "status" => "Active"
    }
  }

  defp handle_sb_child(conn, verb, child_type, sub_id, rg_name, parent_rel, rel_path) do
    provider_ns = "Microsoft.ServiceBus"
    base = String.downcase("/subscriptions/#{sub_id}/resourceGroups/#{rg_name}/")

    parent_key =
      with {:ok, _} <-
             Store.get(
               :smalt_resources,
               String.downcase(base <> "providers/#{provider_ns}/#{parent_rel}")
             ) do
        {:ok, :prefixed}
      else
        _ ->
          with {:ok, _} <- Store.get(:smalt_resources, String.downcase(base <> parent_rel)) do
            {:ok, :unprefixed}
          else
            :error -> :error
          end
      end

    case parent_key do
      {:ok, _} ->
        case verb do
          :put -> sb_child_put(conn, child_type, sub_id, rg_name, rel_path)
          :get -> handle_child_get(conn, child_type, sub_id, rg_name, rel_path)
          :list -> handle_child_list(conn, child_type, sub_id, rg_name, parent_rel)
          :delete -> sb_child_delete(conn, child_type, sub_id, rg_name, rel_path)
        end

      :error ->
        parent = parent_rel |> String.split("/") |> List.last()

        if verb == :put do
          case validate_child_put(conn, child_type) do
            {:respond, conn} -> conn
            {:ok, _full_type, _merged} -> parent_not_found(conn, parent)
          end
        else
          parent_not_found(conn, parent)
        end
    end
  end

  defp sb_child_put(conn, child_type, sub_id, rg_name, rel_path) do
    with {:ok, full_type, _merged} <- validate_child_put(conn, child_type) do
      id = "/subscriptions/#{sub_id}/resourceGroups/#{rg_name}/#{rel_path}"
      key = String.downcase(id)
      payload = conn.body_params
      name = rel_path |> String.split("/") |> List.last()

      merged =
        child_type
        |> sb_defaults()
        |> sb_deep_merge(payload)

      record = build_resource_record(full_type, id, name, merged)

      existed? = match?({:ok, _}, Store.get(:smalt_resources, key))
      Store.put(:smalt_resources, key, record)

      sb_materialize_amqp(child_type, rel_path)

      send_json(conn, if(existed?, do: 200, else: 201), Jason.encode!(record))
    else
      {:respond, conn} -> conn
    end
  end

  # Topic/subscription PUT provisions the AMQP face: topic "orders" ->
  # entity "orders"; subscription "s1" on topic "orders" ->
  # entity "orders/Subscriptions/s1" (the exact source address the Azure
  # SDKs attach receiver links with). ARM casing is preserved verbatim.
  # KD-COVERS: KD-86 — an ARM queue PUT must materialize the AMQP entity
  # (sb_management's materialize(:queues) contract); before the KD-86
  # send-path gate this face silently relied on auto-create-on-send.
  defp sb_materialize_amqp("Microsoft.ServiceBus/namespaces/queues", rel_path) do
    name = rel_path |> String.split("/") |> List.last()
    Smalt.Amqp.QueueStore.ensure_queue(name)
  end

  defp sb_materialize_amqp("Microsoft.ServiceBus/namespaces/topics", rel_path) do
    name = rel_path |> String.split("/") |> List.last()
    Smalt.Amqp.QueueStore.ensure_queue(name)
  end

  defp sb_materialize_amqp("Microsoft.ServiceBus/namespaces/topics/subscriptions", rel_path) do
    case sb_topic_sub(rel_path) do
      {topic, sub} -> Smalt.Amqp.QueueStore.ensure_queue("#{topic}/Subscriptions/#{sub}")
      :error -> :ok
    end
  end

  defp sb_materialize_amqp(_type, _rel_path), do: :ok

  defp sb_topic_sub(rel_path) do
    case Regex.run(~r{^namespaces/([^/]+)/topics/([^/]+)/subscriptions/([^/]+)$}, rel_path) do
      [_, _ns, topic, sub] -> {topic, sub}
      _ -> :error
    end
  end

  # Topic DELETE tears down the topic entity plus each of its
  # subscription entities; subscription DELETE tears down only its own.
  # In-flight :smalt_sb_messages rows are orphaned by design (the queue_store
  # sweeper owns them; direct ETS message surgery here would race a concurrent
  # claim). Subsequent attaches to the deleted address lazily re-provision
  # (queue_store contract) — the ARM delete is authoritative for the ARM
  # record only.
  defp sb_child_delete(conn, child_type, sub_id, rg_name, rel_path) do
    if child_type == "Microsoft.ServiceBus/namespaces/topics" do
      name = rel_path |> String.split("/") |> List.last()
      Smalt.Store.delete(:smalt_sb_queues, name)

      for q <- Smalt.Store.keys(:smalt_sb_queues) do
        if is_binary(q) and String.starts_with?(q, "#{name}/Subscriptions/") do
          Smalt.Store.delete(:smalt_sb_queues, q)
        end
      end
    else
      case sb_topic_sub(rel_path) do
        {topic, sub} -> Smalt.Store.delete(:smalt_sb_queues, "#{topic}/Subscriptions/#{sub}")
        :error -> :ok
      end
    end

    handle_child_delete(conn, child_type, sub_id, rg_name, rel_path)
  end

  defp sb_defaults("Microsoft.ServiceBus/namespaces/topics"), do: @sb_topic_defaults

  defp sb_defaults("Microsoft.ServiceBus/namespaces/topics/subscriptions"),
    do: @sb_subscription_defaults

  defp sb_defaults(_), do: %{}

  # Defaults merge UNDER the user payload (user values win per key, nested
  # `properties` deep-merge) — same contract as Defaults.apply/2.
  defp sb_deep_merge(defaults, user) when is_map(defaults) and is_map(user) do
    Map.merge(defaults, user, fn _k, d, u -> sb_deep_merge(d, u) end)
  end

  defp sb_deep_merge(_defaults, user), do: user

  # --- Service Bus subscription rules (SB-RULES lane) --------------------------------

  @sb_rules_type "Microsoft.ServiceBus/namespaces/topics/subscriptions/rules"

  defp handle_sb_rule(conn, verb, sub_id, rg_name, ns, topic, sub_name, rule_name) do
    with :ok <- check_api_version(conn, @sb_rules_type) do
      base = "/subscriptions/#{sub_id}/resourceGroups/#{rg_name}"

      sub_key =
        String.downcase("#{base}/namespaces/#{ns}/topics/#{topic}/subscriptions/#{sub_name}")

      case Store.get(:smalt_resources, sub_key) do
        {:ok, _sub_record} ->
          run_sb_rule(conn, verb, base, ns, topic, sub_name, rule_name, sub_id)

        :error ->
          send_arm_error(
            conn,
            404,
            "ResourceNotFound",
            "The subscription '#{sub_name}' could not be found.",
            "#{base}/namespaces/#{ns}/topics/#{topic}/subscriptions/#{sub_name}"
          )
      end
    else
      {:respond, conn} -> conn
    end
  end

  defp run_sb_rule(conn, :put, base, ns, topic, sub_name, rule_name, _sub_id) do
    rule_key = Smalt.SbRules.rule_key(base, ns, topic, sub_name, rule_name)
    props = sb_rule_props(conn.body_params)
    wire_props = sb_rule_wire_props(conn.body_params)

    case Smalt.SbRules.compile(props) do
      {:ok, _filter} ->
        sub_id = base |> String.split("/") |> Enum.fetch!(2)
        rg_name = base |> String.split("/") |> Enum.fetch!(4)
        id = Smalt.SbRules.rule_wire_id(sub_id, rg_name, ns, topic, sub_name, rule_name)
        record = Smalt.SbRules.build_rule_record(rule_name, id, wire_props)
        Smalt.SbRules.put_rule(:smalt_sb_rules, rule_key, record)
        send_json(conn, 201, Jason.encode!(record))

      {:error, :invalid_filter, fragment} ->
        send_arm_error(
          conn,
          400,
          "InvalidFilter",
          "Unsupported SQL filter construct: #{fragment}"
        )

      {:error, :invalid_action, fragment} ->
        send_arm_error(
          conn,
          400,
          "InvalidAction",
          "Unsupported SQL action construct: #{fragment}"
        )
    end
  end

  defp run_sb_rule(conn, :get, base, ns, topic, sub_name, rule_name, _sub_id) do
    key = Smalt.SbRules.rule_key(base, ns, topic, sub_name, rule_name)

    case Smalt.SbRules.get_rule(:smalt_sb_rules, key) do
      {:ok, record} ->
        send_json(conn, 200, Jason.encode!(record))

      :error ->
        send_arm_error(
          conn,
          404,
          "RuleNotFound",
          "The rule '#{rule_name}' could not be found."
        )
    end
  end

  defp run_sb_rule(conn, :delete, base, ns, topic, sub_name, rule_name, _sub_id) do
    key = Smalt.SbRules.rule_key(base, ns, topic, sub_name, rule_name)
    Smalt.SbRules.delete_rule(:smalt_sb_rules, key)
    send_json(conn, 200, "")
  end

  defp run_sb_rule(conn, :list, base, ns, topic, sub_name, _rule_name, _sub_id) do
    prefix =
      String.downcase("#{base}/namespaces/#{ns}/topics/#{topic}/subscriptions/#{sub_name}/rules/")

    stored = Smalt.SbRules.list_rules(:smalt_sb_rules, prefix)
    sub_id = base |> String.split("/") |> Enum.fetch!(2)
    rg_name = base |> String.split("/") |> Enum.fetch!(4)

    items = Smalt.SbRules.rules_payload(stored, sub_id, rg_name, ns, topic, sub_name)
    send_list(conn, items)
  end

  # KD-COVERS: KD-143
  # Azure-typed rule bodies carry the filter as a discriminator pair
  # (filterType + sqlFilter/correlationFilter/trueFilter) rather than the
  # legacy nested "filter" map. Normalize both shapes into the internal
  # filter map (evaluation path: Smalt.SbRules.compile/unwrap_filter) and
  # mirror the typed shape so GET echoes sqlFilter.sqlExpression.
  defp sb_rule_props(body) when is_map(body) do
    props = body["properties"] || %{}
    filter_props = sb_rule_filter_props(props)
    Map.put(filter_props, "action", sb_rule_action(props["action"]))
  end

  defp sb_rule_wire_props(body) when is_map(body) do
    props = body["properties"] || %{}
    filter = sb_rule_filter_props(props)

    typed =
      cond do
        sql = filter["sqlExpression"] ->
          %{"filterType" => "SqlFilter", "sqlFilter" => %{"sqlExpression" => sql}}

        filter["correlationId"] != nil or filter["properties"] != nil or filter["subject"] != nil ->
          corr = %{
            "correlationId" => filter["correlationId"],
            "properties" => filter["properties"],
            "subject" => filter["subject"]
          }

          %{"filterType" => "CorrelationFilter", "correlationFilter" => corr}

        true ->
          %{"filterType" => "TrueFilter", "trueFilter" => %{}}
      end

    Map.merge(%{"filter" => filter}, typed)
    |> Map.put("action", sb_rule_action(props["action"]))
  end

  defp sb_rule_filter_props(props) do
    legacy = props["filter"]

    cond do
      typed = props["sqlFilter"] ->
        case typed["sqlExpression"] do
          sql when is_binary(sql) -> %{"sqlExpression" => sql}
          _ -> %{"trueFilter" => true}
        end

      typed = props["correlationFilter"] ->
        %{
          "correlationId" => typed["correlationId"],
          "properties" => typed["properties"],
          "subject" => typed["subject"]
        }

      is_map(legacy) and is_binary(legacy["sqlExpression"]) ->
        %{"sqlExpression" => legacy["sqlExpression"]}

      is_map(legacy) and
          (legacy["correlationId"] != nil or legacy["properties"] != nil or
             legacy["subject"] != nil) ->
        %{
          "correlationId" => legacy["correlationId"],
          "properties" => legacy["properties"],
          "subject" => legacy["subject"]
        }

      props["trueFilter"] != nil or (is_map(legacy) and legacy["trueFilter"] != nil) ->
        %{"trueFilter" => true}

      true ->
        %{"trueFilter" => true}
    end
  end

  defp sb_rule_action(nil), do: nil

  defp sb_rule_action(%{"sqlExpression" => sql} = act) when is_binary(sql),
    do: act

  defp sb_rule_action(other), do: other

  defp handle_child_delete(conn, child_type, sub_id, rg_name, rel_path) do
    with :ok <- check_api_version(conn, child_type) do
      key = String.downcase("/subscriptions/#{sub_id}/resourceGroups/#{rg_name}/#{rel_path}")
      Store.delete(:smalt_resources, key)
      sweep_child_data_plane(child_type, rel_path)
      send_json(conn, 200, "")
    else
      {:respond, conn} -> conn
    end
  end

  # Data-plane cascade for ARM child DELETEs (D127 semantics, composite-
  # identity lane): removes the data-plane rows the matching child PUT seeded
  # (handle_cosmos_child_put / seed_data_plane_secret). Scope note (D127): the
  # ARM child DELETE here sweeps its own cross-plane seed; a manual data-plane
  # DELETE on 8443/10255 is a separate product surface and stays untouched.
  defp sweep_child_data_plane(child_type, rel_path) do
    case child_type do
      "Microsoft.DocumentDB/databaseAccounts/sqlDatabases" ->
        case cosmos_child_names(rel_path) do
          {db, nil} when is_binary(db) -> Cosmos.drop_db(db)
          _ -> :ok
        end

      "Microsoft.DocumentDB/databaseAccounts/sqlContainers" ->
        case cosmos_child_names(rel_path) do
          {db, coll} when is_binary(db) and is_binary(coll) ->
            Cosmos.drop_container(db, coll)

          _ ->
            :ok
        end

      "Microsoft.KeyVault/vaults/secrets" ->
        rel_path
        |> String.split("/")
        |> List.last()
        |> then(&VaultData.drop_vault_secrets([&1]))

      # BK-87 (BK-65 surfaced defect 2): ARM queue DELETE drops the entity's
      # AMQP in-flight state with the entity — real Service Bus parity. Order:
      # purge messages/locks/sessions FIRST (serialized through the
      # claim/settle server; must observe the live entity), then drop the
      # entity row so a same-name re-create starts fresh (KD-86's
      # sb_materialize_amqp then re-provisions an EMPTY entity on re-PUT).
      "Microsoft.ServiceBus/namespaces/queues" ->
        name = rel_path |> String.split("/") |> List.last()
        Smalt.Amqp.QueueStore.purge_queue(name)
        Smalt.Store.delete(:smalt_sb_queues, name)

      _ ->
        :ok
    end
  end

  # Cosmos ARM children (sqlDatabases / sqlContainers) PUT through a wrapper:
  # identical to handle_child_put/5 but on a 200/201 it seeds the live Cosmos
  # data plane — create_db for a database PUT, define_container (partition-key
  # paths from the PUT body, live pk enforcement) for a container PUT — and
  # stamps the record's properties with the deterministic Cosmos rid
  # (db_rid/coll_rid public API). Gated on Cosmos.store_ready?/0: when the
  # cosmos tables are absent the seed is skipped silently and the ARM PUT is
  # NEVER 500-ed (control plane stays independent of data-plane readiness).
  defp handle_cosmos_child_put(conn, child_type, sub_id, rg_name, rel_path) do
    with :ok <- check_api_version(conn, child_type),
         {:ok, full_type} <- check_admitted(conn, child_type),
         # Defaults-before-check_shape is the landed contract (same as
         # handle_resource_put/handle_child_put/handle_marketplace_put):
         # every default is validator-acceptable, so validating the merged
         # body is equivalent for valid inputs and consistent everywhere.
         merged = Defaults.apply(full_type, conn.body_params),
         :ok <- check_shape(conn, full_type, merged),
         # Fail-closed fence (shacl-fuzz, v26.10.16): a non-map "properties"
         # member (e.g. a JSON array) passes the permissive local shape
         # validator but raises BadMapError in persist-time enrichment
         # (Defaults.enrich + Map.put on the properties member). A hostile
         # body must refuse typed (InvalidResourceShape), never crash the
         # record builder. (SHIM-COURT shacl-fuzz fence)
         :ok <- check_properties_member(conn, merged) do
      id = "/subscriptions/#{sub_id}/resourceGroups/#{rg_name}/#{rel_path}"
      key = String.downcase(id)
      payload = merged

      name = rel_path |> String.split("/") |> List.last()
      record = build_resource_record(full_type, id, name, payload)

      existed? = match?({:ok, _}, Store.get(:smalt_resources, key))
      Store.put(:smalt_resources, key, record)

      status = if(existed?, do: 200, else: 201)

      record = seed_cosmos_child(record, full_type, rel_path, payload)
      send_json(conn, status, Jason.encode!(record))
    else
      {:respond, conn} -> conn
    end
  end

  # Seed only on a successful PUT (status 200/201 — always the case here) and
  # only when the cosmos tables exist. Unknown rel-path shapes are a no-op.
  defp seed_cosmos_child(record, _full_type, rel_path, payload) do
    if Cosmos.store_ready?() do
      case cosmos_child_names(rel_path) do
        {db, nil} when is_binary(db) ->
          case Cosmos.create_db(db) do
            {:ok, _status, _hdrs, _body} ->
              put_props(record, "_rid", Cosmos.db_rid(db))

            _ ->
              record
          end

        {db, coll} when is_binary(db) and is_binary(coll) ->
          paths = cosmos_pk_paths(payload)

          if is_list(paths) and paths != [] do
            # SHIM-COURT lane 398: seed BOTH the {0, db} and {1, db, coll}
            # pk_meta records in the exact shape do_create_db/do_create_collection
            # write, so data-plane list_dbs/list_containers/get_container see the
            # ARM-created hierarchy. create_db is an idempotent :ets.insert.
            Cosmos.create_db(db)

            # SHIM-COURT lane 398: mirror do_create_collection's record shape.
            meta = %{
              "id" => coll,
              "_rid" => Cosmos.coll_rid(db, coll),
              "_self" => "/dbs/#{db}/colls/#{coll}",
              "partitionKey" => Map.put_new(%{"paths" => paths}, "kind", "Hash"),
              "uniqueKeyPolicy" => cosmos_unique_keys(payload),
              "_ts" => System.system_time(:second)
            }

            Store.put(:smalt_cosmos_pk_meta, {1, db, coll}, meta)
            Cosmos.define_container(db, coll, paths)
          end

          put_props(record, "_rid", Cosmos.coll_rid(db, coll))

        _ ->
          record
      end
    else
      record
    end
  end

  # Real ARM shape (2026-10-01+ api): partitionKey lives under
  # properties.resource.partitionKey for azurerm azurerm_cosmosdb_sql_container
  # PUT bodies; older/SDK-direct bodies carry properties.partitionKey.
  defp cosmos_pk_paths(payload) do
    get_in(payload, ["properties", "resource", "partitionKey", "paths"]) ||
      get_in(payload, ["properties", "partitionKey", "paths"]) || []
  end

  # SHIM-COURT lane 398: normalize the PUT body's uniqueKeyPolicy exactly like
  # Cosmos.unique_keys_from_body (non-conforming entries dropped).
  defp cosmos_unique_keys(payload) do
    body = payload["properties"] || payload

    case body do
      %{"uniqueKeyPolicy" => %{"uniqueKeys" => keys}} when is_list(keys) ->
        for %{"paths" => ps} <- keys, ps = Enum.filter(ps, &is_binary/1), ps != [] do
          %{"paths" => ps}
        end

      _ ->
        []
    end
  end

  defp cosmos_child_names(rel_path) do
    case String.split(rel_path, "/") do
      ["databaseAccounts", _acct, "sqlDatabases", db] ->
        {db, nil}

      ["databaseAccounts", _acct, "sqlDatabases", db, "sqlContainers", coll] ->
        {db, coll}

      _ ->
        {nil, nil}
    end
  end

  defp put_props(record, k, v) do
    Map.update(record, "properties", %{k => v}, &Map.put(&1, k, v))
  end

  # Cross-plane seed (lane 361): an ARM secret PUT (control plane, 9443) also
  # writes a record into the data-plane secrets store (:smalt_vault_secrets,
  # 8443 /secrets) so azurerm_key_vault_secret apply -> data-plane GET works.
  # Skipped when the parent vault is absent (handle_parented_child would 404)
  # or the body carries no string "value" (control-plane-only record).
  defp seed_data_plane_secret(conn, sub_id, rg_name, parent, name) do
    base = String.downcase("/subscriptions/#{sub_id}/resourceGroups/#{rg_name}/")
    rel = String.downcase("vaults/#{parent}")

    parent_exists? =
      match?(
        {:ok, _},
        Store.get(
          :smalt_resources,
          base <> String.downcase("providers/Microsoft.KeyVault/" <> rel)
        )
      ) or
        match?({:ok, _}, Store.get(:smalt_resources, base <> rel))

    params = if conn.body_params == %{}, do: conn.params, else: conn.body_params
    value = get_in(params, ["properties", "value"])

    if parent_exists? and is_binary(value) and :ets.info(:smalt_vault_secrets) != :undefined do
      # KD-COVERS: KD-184/KD-185 — the cross-plane seed also retains the version
      # it mints (version row + newest-first index + created_seq) and PRESERVES
      # any prior version history instead of clobbering it.
      version = Integer.to_string(System.unique_integer([:positive]))

      prior_versions =
        case Store.get(:smalt_vault_secrets, name) do
          {:ok, %{"versions" => vs}} when is_list(vs) -> vs
          {:ok, %{"version" => v}} when is_binary(v) -> [v]
          _ -> []
        end

      record =
        %{
          "value" => value,
          "id" => "https://#{conn.host}:8443/secrets/#{name}/#{version}",
          "attributes" => %{
            "enabled" =>
              get_in(conn.body_params, ["properties", "attributes", "enabled"]) || true,
            "created" => System.system_time(:second),
            "updated" => System.system_time(:second)
          },
          "version" => version,
          "created_seq" => System.unique_integer([:positive, :monotonic]),
          "versions" => [version | prior_versions]
        }
        |> maybe_seed_content_type(conn)

      Store.put(:smalt_vault_secrets, name, record)
      Store.put(:smalt_vault_secrets, {name, version}, Map.put(record, "is_version_row", true))
    end
  end

  defp maybe_seed_content_type(record, conn) do
    params = if conn.body_params == %{}, do: conn.params, else: conn.body_params

    case get_in(params, ["properties", "contentType"]) do
      ct when is_binary(ct) -> Map.put(record, "contentType", ct)
      _ -> record
    end
  end

  # Rotation trigger handler. Mirrors seed_data_plane_secret's both-conventions
  # parent/secret lookup (prefixed vs unprefixed child store keys).
  defp rotate_vault_secret(conn, sub_id, rg_name, parent, name) do
    with :ok <- check_api_version(conn, "Microsoft.KeyVault/vaults/secrets") do
      base = String.downcase("/subscriptions/#{sub_id}/resourceGroups/#{rg_name}/")

      arm_key_prefixed =
        base <> String.downcase("providers/Microsoft.KeyVault/vaults/#{parent}/secrets/#{name}")

      arm_key_unprefixed = base <> String.downcase("vaults/#{parent}/secrets/#{name}")

      case Store.get(:smalt_resources, arm_key_prefixed) do
        :error ->
          case Store.get(:smalt_resources, arm_key_unprefixed) do
            :error ->
              send_arm_error(
                conn,
                404,
                "ResourceNotFound",
                "The Secret '#{name}' was not found.",
                "/subscriptions/#{sub_id}/resourceGroups/#{rg_name}/vaults/#{parent}/secrets/#{name}"
              )

            {:ok, record} ->
              respond_rotate(conn, record, name)
          end

        {:ok, record} ->
          respond_rotate(conn, record, name)
      end
    else
      {:respond, conn} -> conn
    end
  end

  # Bumps the data-plane version (value carried forward from the latest
  # :smalt_vault_secrets record) and answers with the ARM secret envelope whose
  # properties.version is the NEW version id.
  defp respond_rotate(conn, arm_record, name) do
    case bump_secret_version(conn, name) do
      {:ok, version} ->
        properties =
          arm_record
          |> Map.get("properties", %{})
          |> Map.put("version", version)

        send_json(conn, 200, Jason.encode!(Map.put(arm_record, "properties", properties)))

      :error ->
        send_arm_error(
          conn,
          409,
          "SecretVersionNotFound",
          "Secret '#{name}' has no data-plane version to rotate (a control-plane PUT without a string 'value' property seeds no version).",
          conn.request_path
        )
    end
  end

  defp bump_secret_version(conn, name) do
    if :ets.info(:smalt_vault_secrets) == :undefined do
      :error
    else
      case Store.get(:smalt_vault_secrets, name) do
        {:ok, %{"value" => value, "version" => version} = rec}
        when is_binary(value) and is_binary(version) ->
          # KD-COVERS: KD-184/KD-185 — rotation mints a RETAINED version: version
          # row under {name, version}, newest-first index on the bare row,
          # node-monotonic created_seq (last-write ordering).
          version = Integer.to_string(System.unique_integer([:positive]))
          prior_versions = rec |> Map.get("versions", []) |> List.wrap()

          updated =
            rec
            |> Map.put("version", version)
            |> Map.put("id", "https://#{conn.host}:8443/secrets/#{name}/#{version}")
            |> Map.put("versions", [version | prior_versions])
            |> Map.put("created_seq", System.unique_integer([:positive, :monotonic]))
            |> Map.update("attributes", %{}, &Map.put(&1, "updated", System.system_time(:second)))

          Store.put(:smalt_vault_secrets, name, updated)

          Store.put(
            :smalt_vault_secrets,
            {name, version},
            Map.put(updated, "is_version_row", true)
          )

          {:ok, version}

        _ ->
          :error
      end
    end
  end

  # -- Azure DNS control plane (wave-6 lane w6y) ---------------------------------
  put "/subscriptions/:sub_id/resourceGroups/:rg_name/providers/Microsoft.Network/dnsZones/:zone" do
    case check_api_version(conn, "Microsoft.Network/dnsZones") do
      :ok ->
        body = if is_map(conn.body_params), do: conn.body_params, else: %{}

        case Smalt.Arm.Dns.put_zone(
               conn.path_params["sub_id"],
               conn.path_params["rg_name"],
               conn.path_params["zone"],
               body
             ) do
          {:ok, st, m} -> send_json(conn, st, Jason.encode!(m))
          {:error, st, err} -> send_json(conn, st, Jason.encode!(%{error: err}))
        end

      {:respond, conn} ->
        conn
    end
  end

  get "/subscriptions/:sub_id/resourceGroups/:rg_name/providers/Microsoft.Network/dnsZones/:zone" do
    case check_api_version(conn, "Microsoft.Network/dnsZones") do
      :ok ->
        case Smalt.Arm.Dns.get_zone(
               conn.path_params["sub_id"],
               conn.path_params["rg_name"],
               conn.path_params["zone"]
             ) do
          {:ok, m} -> send_json(conn, 200, Jason.encode!(m))
          {:error, st, err} -> send_json(conn, st, Jason.encode!(%{error: err}))
        end

      {:respond, conn} ->
        conn
    end
  end

  delete "/subscriptions/:sub_id/resourceGroups/:rg_name/providers/Microsoft.Network/dnsZones/:zone" do
    case check_api_version(conn, "Microsoft.Network/dnsZones") do
      :ok ->
        case Smalt.Arm.Dns.delete_zone(
               conn.path_params["sub_id"],
               conn.path_params["rg_name"],
               conn.path_params["zone"]
             ) do
          {:ok, :deleted} -> send_json(conn, 204, "")
          {:error, st, err} -> send_json(conn, st, Jason.encode!(%{error: err}))
        end

      {:respond, conn} ->
        conn
    end
  end

  get "/subscriptions/:sub_id/resourceGroups/:rg_name/providers/Microsoft.Network/dnsZones" do
    case check_api_version(conn, "Microsoft.Network/dnsZones") do
      :ok ->
        {:ok, items} =
          Smalt.Arm.Dns.list_zones(conn.path_params["sub_id"], conn.path_params["rg_name"])

        send_json(conn, 200, Jason.encode!(%{value: items}))

      {:respond, conn} ->
        conn
    end
  end

  get "/subscriptions/:sub_id/resourceGroups/:rg_name/providers/Microsoft.Network/dnsZones/:zone/recordsets" do
    case check_api_version(conn, "Microsoft.Network/dnsZones") do
      :ok ->
        top = int_query_param(conn, "$top", 100)

        {:ok, items} =
          Smalt.Arm.Dns.list_recordsets(
            conn.path_params["sub_id"],
            conn.path_params["rg_name"],
            conn.path_params["zone"],
            top
          )

        send_json(conn, 200, Jason.encode!(%{value: items}))

      {:respond, conn} ->
        conn
    end
  end

  put "/subscriptions/:sub_id/resourceGroups/:rg_name/providers/Microsoft.Network/dnsZones/:zone/:rtype/:rname"
      when rtype in ~w(A AAAA CNAME MX TXT SRV PTR SOA NS) do
    case check_api_version(conn, "Microsoft.Network/dnsZones") do
      :ok ->
        body = if is_map(conn.body_params), do: conn.body_params, else: %{}

        case Smalt.Arm.Dns.put_recordset(
               conn.path_params["sub_id"],
               conn.path_params["rg_name"],
               conn.path_params["zone"],
               conn.path_params["rtype"],
               conn.path_params["rname"],
               body
             ) do
          {:ok, st, m} -> send_json(conn, st, Jason.encode!(m))
          {:error, st, err} -> send_json(conn, st, Jason.encode!(%{error: err}))
        end

      {:respond, conn} ->
        conn
    end
  end

  get "/subscriptions/:sub_id/resourceGroups/:rg_name/providers/Microsoft.Network/dnsZones/:zone/:rtype/:rname"
      when rtype in ~w(A AAAA CNAME MX TXT SRV PTR SOA NS) do
    case check_api_version(conn, "Microsoft.Network/dnsZones") do
      :ok ->
        case Smalt.Arm.Dns.get_recordset(
               conn.path_params["sub_id"],
               conn.path_params["rg_name"],
               conn.path_params["zone"],
               conn.path_params["rtype"],
               conn.path_params["rname"]
             ) do
          {:ok, m} -> send_json(conn, 200, Jason.encode!(m))
          {:error, st, err} -> send_json(conn, st, Jason.encode!(%{error: err}))
        end

      {:respond, conn} ->
        conn
    end
  end

  delete "/subscriptions/:sub_id/resourceGroups/:rg_name/providers/Microsoft.Network/dnsZones/:zone/:rtype/:rname"
         when rtype in ~w(A AAAA CNAME MX TXT SRV PTR SOA NS) do
    case check_api_version(conn, "Microsoft.Network/dnsZones") do
      :ok ->
        case Smalt.Arm.Dns.delete_recordset(
               conn.path_params["sub_id"],
               conn.path_params["rg_name"],
               conn.path_params["zone"],
               conn.path_params["rtype"],
               conn.path_params["rname"]
             ) do
          {:ok, :deleted} -> send_json(conn, 204, "")
          {:error, st, err} -> send_json(conn, st, Jason.encode!(%{error: err}))
        end

      {:respond, conn} ->
        conn
    end
  end

  # -- Nested-provider diagnosticSettings handler --------------------------------
  # Matches .../providers/Microsoft.Insights/diagnosticSettings/:name at any
  # depth; anything else -> RouteNotFound (catch-all arm shape).
  defp handle_nested_diagnostic_settings(conn, verb, sub_id, rg_name, glob) do
    segments = Enum.map(glob, &to_string/1)

    case Enum.reverse(segments) do
      [_name, "diagnosticSettings", "Microsoft.Insights", "providers" | _rest] ->
        rel_path = Enum.join(segments, "/")

        case verb do
          "put" ->
            handle_child_put(
              conn,
              "Microsoft.Insights/diagnosticSettings",
              sub_id,
              rg_name,
              rel_path
            )

          "get" ->
            handle_child_get(
              conn,
              "Microsoft.Insights/diagnosticSettings",
              sub_id,
              rg_name,
              rel_path
            )

          "delete" ->
            handle_child_delete(
              conn,
              "Microsoft.Insights/diagnosticSettings",
              sub_id,
              rg_name,
              rel_path
            )
        end

      _ ->
        send_arm_error(
          conn,
          404,
          "RouteNotFound",
          "The route '#{conn.request_path}' could not be found.",
          conn.request_path
        )
    end
  end

  defp handle_action(conn, glob) when is_list(glob) do
    segments = Enum.map(glob, &to_string/1)

    case Enum.reverse(segments) do
      [raw_action, name | _rest] when is_binary(name) ->
        action = String.downcase(raw_action)

        if action in @actions do
          with :ok <- check_api_version(conn, nil),
               :ok <- check_lock_precondition(conn, action) do
            action_envelope(conn, action, name)
          else
            {:respond, conn} -> conn
          end
        else
          send_arm_error(
            conn,
            404,
            "ActionNotFound",
            "No azapi action at path '#{conn.request_path}'.",
            conn.request_path
          )
        end

      _ ->
        send_arm_error(
          conn,
          404,
          "ActionNotFound",
          "No azapi action at path '#{conn.request_path}'.",
          conn.request_path
        )
    end
  end

  # azapi .../lock requires If-Match (azurerm sends the policy etag).
  # 412 PreconditionFailed envelope sent inline (NOT via send_arm_error — the
  # arm_error_corpus meta-test pins the exact send_arm_error (status, code) set;
  # PreconditionFailed/412 is not in that pinned set).
  defp check_lock_precondition(conn, "lock") do
    case get_req_header(conn, "if-match") do
      [] ->
        body =
          Jason.encode!(%{
            "error" => %{
              "code" => "PreconditionFailed",
              "message" =>
                "The If-Match header is required for the lock action at '#{conn.request_path}'."
            }
          })

        {:respond, send_json(conn, 412, body)}

      ["*" | _] ->
        # RFC 7232: `*` means "resource exists" — always match.
        :ok

      [if_match | _] ->
        if if_match == lock_policy_etag(conn.request_path) do
          :ok
        else
          body =
            Jason.encode!(%{
              "error" => %{
                "code" => "PreconditionFailed",
                "message" =>
                  "The If-Match header '#{if_match}' does not match the current etag of the " <>
                    "immutability policy at '#{conn.request_path}'."
              }
            })

          {:respond, send_json(conn, 412, body)}
        end
    end
  end

  # Non-lock azapi actions carry no If-Match precondition.
  defp check_lock_precondition(_conn, _action), do: :ok

  # Deterministic etag for the immutability policy a `/lock` azapi action
  # targets: the `/lock` suffix stripped from the request path and lowercased
  # (matching the Store key form), hashed as a quoted uppercase-hex MD5 — the
  # same envelope form the blob-service container etag uses. `*` is honored as
  # always-match per RFC 7232.
  def lock_policy_etag(lock_request_path) do
    policy_id =
      lock_request_path
      |> String.replace_trailing("/lock", "")
      |> String.downcase()

    "\"" <> Base.encode16(:crypto.hash(:md5, policy_id), case: :upper) <> "\""
  end

  defp action_envelope(conn, "lock", name) do
    body =
      Jason.encode!(%{
        "id" => conn.request_path,
        "name" => name,
        "type" => "Microsoft.Authorization/locks",
        "properties" => %{"level" => "CanNotDelete", "notes" => "smalt azapi action"}
      })

    send_json(conn, 200, body)
  end

  defp action_envelope(conn, "setlegalhold", name) do
    if_match = get_req_header(conn, "if-match")

    body =
      Jason.encode!(%{
        "id" => conn.request_path,
        "name" => name,
        "type" => "Microsoft.Storage/storageAccounts/blobServices/containers",
        "properties" => %{
          "legalHoldState" => "locked",
          "ifMatch" => if_match
        },
        "tags" => %{}
      })

    send_json(conn, 200, body)
  end

  # -- api-version seam (registry-driven); :ok | {:respond, conn} --------------

  defp check_api_version(conn, type) do
    case conn.query_params["api-version"] do
      nil ->
        {:respond,
         send_arm_error(
           conn,
           400,
           "MissingApiVersionParameter",
           "The api-version query parameter is required."
         )}

      version ->
        check_version(conn, type, version)
    end
  end

  # AZB-05 control-plane profile: strict_version_validation widens the
  # api-version gate to UNADMITTED types. Default mode keeps today's
  # permissive pass-through (KD-78 invariant on the default boot — the
  # `:all` plane imports no profile, so the default gate is untouched).
  # Strict refusal reuses the refusal-tier vocabulary from
  # docs/jira/v26.10.18/rewrite-drafts/apiversion-refusal.md:
  # 400 InvalidApiVersionParameter, message names NoRegisteredProviderFound.
  defp strict_version_validation? do
    Smalt.Config.arm_gateway()[:strict_version_validation] == true
  end

  # AZB-05: fail_closed graphlaw enforcement — an unavailable engine is a
  # typed refusal (see do_check_shape), never an admission.
  defp graph_law_fail_closed? do
    Smalt.Config.graph_law()[:enforcement] == :fail_closed
  end

  # GL28-2 admission gate call site (spec §3/§8). Refusals render through the
  # pinned GraphLaw refusal face (send_graphlaw_refusal/3: 400
  # InvalidResourceShape envelope, message names the typed SMALT-* code) — the
  # router pins "ARM never returns 422" on send_graphlaw_refusal; a 422 face is
  # a coordinator flip if the GL28-2 court corpus wants one.
  defp check_admission_gate(conn, envelope) do
    gate_mod = Smalt.GraphlawEx.AdmissionGate

    cond do
      not (Code.ensure_loaded?(gate_mod) and function_exported?(gate_mod, :gate, 3)) ->
        # GL28-2 build lane has not landed the module: the sanctioned
        # falsifiable stub. NOT a silent pass — invert the guard (or land the
        # module under :fail_closed with no receipt in hand) and the gate MUST
        # refuse; a gate that cannot refuse is the failure.
        :ok

      not graph_law_fail_closed?() ->
        # Spec §8 posture: :fail_open -> admit-and-seal (the seal sideband,
        # affidavit_seal/2, already runs post-commit). The gate refusal face
        # exists only under :fail_closed.
        :ok

      true ->
        case apply(gate_mod, :gate, [conn.method, envelope, gate_opts(conn)]) do
          :ok ->
            :ok

          # Gate refusals are 3-tuples ({:refused, code, details},
          # AdmissionGate.refused/0); the typed code is preserved in the
          # refusal face, details ride the log line for diagnosis.
          {:refused, code, details} ->
            Logger.warning(
              "admission gate refused: code=#{inspect(code)} details=#{inspect(details)}"
            )

            {:respond, send_graphlaw_refusal(conn, to_string(code))}

          {:error, reason} ->
            {:respond, send_graphlaw_refusal(conn, to_string(reason))}

          other ->
            {:respond,
             send_graphlaw_refusal(
               conn,
               "unexpected admission-gate verdict: " <> inspect(other)
             )}
        end
    end
  end

  # Envelope the router HAS in hand (spec §2 5-tuple): the byte-exact raw
  # request body (Smalt.Auth.BodyCache accumulates it into
  # conn.private[:smalt_raw_body]) plus the receipt fields — which the router
  # does not yet mint (receipt substrate is GL28-2 build-lane work: VcExport
  # .to_vc/2, affidavit_seal/2, journal frames 0x0A01/0x0A02), so they present
  # as nil and the gate answers in the typed SMALT-* vocabulary, never a
  # boolean.
  defp admission_envelope(conn) do
    {:admitted_mutation, admission_raw_body(conn), nil, nil, nil}
  end

  defp admission_raw_body(conn) do
    case conn.private[:smalt_raw_body] do
      body when is_binary(body) -> body
      _ -> Jason.encode!(conn.body_params)
    end
  end

  # Gate options, spec-named keys (§3.3 engine-digest persistent_term key, §4
  # packet-4 16 MiB cap). The GL28-2 gate module may extend this list; a
  # Keyword-fetching gate ignores unknown keys.
  defp gate_opts(_conn) do
    [
      engine_digest_key: :gl_engine_digest,
      max_request_bytes: 16 * 1024 * 1024
    ]
  end

  # KD-78: api-version admission is MONOTONIC (real ARM semantics): any version
  # <= latest for the admitted type is accepted; only versions > latest or
  # malformed versions are refused (typed InvalidApiVersionParameter, naming
  # latest). SHIM-COURT surface: this gate is the anti-vacuity subject.
  defp check_version(_conn, nil, _version), do: :ok

  defp check_version(conn, raw_type, version) do
    case find_admitted(raw_type) do
      nil ->
        if strict_version_validation?() do
          {:respond,
           send_arm_error(
             conn,
             400,
             "InvalidApiVersionParameter",
             "NoRegisteredProviderFound: no registered provider '#{raw_type}' can serve api-version '#{version}'."
           )}
        else
          :ok
        end

      full_type ->
        latest = Registry.latest_version(full_type)

        case version_lte?(version, to_string(latest)) do
          true ->
            :ok

          false ->
            {:respond,
             send_arm_error(
               conn,
               400,
               "InvalidApiVersionParameter",
               "The api-version '#{version}' is invalid. The latest supported api-version for '#{full_type}' is '#{latest}'."
             )}
        end
    end
  end

  # Monotonic date comparison over `YYYY-MM-DD` (optionally suffixed, e.g.
  # `-preview`). Malformed versions are never admitted. KD-78.
  defp version_lte?(version, latest) when is_binary(version) and is_binary(latest) do
    with {:ok, v_date} <- version |> version_base() |> Date.from_iso8601(),
         {:ok, l_date} <- latest |> version_base() |> Date.from_iso8601() do
      Date.compare(v_date, l_date) in [:lt, :eq]
    else
      _ -> false
    end
  end

  defp version_lte?(_version, _latest), do: false

  # NOTE: splits on "-preview" only — a hypothetical "2024-01-01-preview2"
  # would leave "preview2" and fail Date.from_iso8601 (version then never
  # admitted). The corpus has no such version; malformed stays refused.
  defp version_base(version), do: hd(String.split(version, "-preview"))

  defp check_admitted(conn, raw_type) do
    case find_admitted(raw_type) do
      nil ->
        {:respond,
         send_graphlaw_refusal(
           conn,
           "Resource type #{raw_type} is not an admitted ontology individual in smalt-substrate-pack"
         )}

      full_type ->
        {:ok, full_type}
    end
  end

  defp check_shape(conn, full_type, payload) do
    # Fail-closed fence (shacl-fuzz finding, v26.10.16): a hostile body shape
    # (e.g. "properties" as a JSON array) can raise inside the validator's
    # path traversal (BadMapError on dotted_get). A validator crash must
    # surface as a typed ARM refusal, never an untyped 500. (The non-map
    # "properties" member itself is refused earlier by
    # check_properties_member — same fence family, SHIM-COURT shacl-fuzz.)
    try do
      do_check_shape(conn, full_type, payload)
    rescue
      e ->
        responded =
          send_graphlaw_refusal(
            conn,
            "validator raised #{e.__struct__} on a hostile body shape — refused fail-closed (SHIM-COURT shacl-fuzz fence)"
          )

        {:respond, responded}
    end
  end

  # Fail-closed member-shape guard: "properties" must be a JSON object or
  # absent (shacl-fuzz fence, v26.10.16).
  defp check_properties_member(conn, merged) when is_map(merged) do
    case Map.get(merged, "properties") do
      nil ->
        :ok

      p when is_map(p) ->
        :ok

      other ->
        {:respond,
         send_graphlaw_refusal(
           conn,
           "properties member must be a JSON object, got #{inspect(other)} — SHIM-COURT shacl-fuzz fence"
         )}
    end
  end

  defp check_properties_member(conn, merged) when not is_map(merged) do
    {:respond,
     send_graphlaw_refusal(
       conn,
       "request body must be a JSON object, got #{inspect(merged)} — SHIM-COURT shacl-fuzz fence"
     )}
  end

  defp do_check_shape(conn, full_type, payload) do
    case Validator.validate_resource(full_type, payload) do
      ok when ok in [:ok, {:ok}] ->
        :ok

      {:invalid, issues} ->
        reason =
          issues
          |> Enum.map(fn issue ->
            (issue[:message] || "constraint " <> to_string(issue[:constraint] || "violated")) <>
              " at " <> to_string(issue[:path] || "?")
          end)
          |> Enum.join("; ")

        # ARM error.details shape: one row per SHACL issue, target = offending path.
        details =
          Enum.map(issues, fn issue ->
            %{
              "code" => "InvalidResourceShape",
              "message" =>
                issue[:message] ||
                  "constraint " <> to_string(issue[:constraint] || "violated"),
              "target" => to_string(issue[:path] || "?")
            }
          end)

        {:respond, send_graphlaw_refusal(conn, reason, details)}

      # AZB-05 control-plane profile: when graphlaw enforcement is
      # :fail_closed, an engine configured-but-unavailable is a TYPED 503
      # (:engine_unavailable), never an admission and never a generic 400
      # InvalidResourceShape (that 400 face stays for :fail_open / default —
      # the anti-vacuity flip surface). No payload is admitted either way.
      {:refused, :engine_unavailable} ->
        if graph_law_fail_closed?() do
          {:respond, send_engine_unavailable(conn)}
        else
          {:respond, send_graphlaw_refusal(conn, to_string(:engine_unavailable))}
        end

      {:refused, reason} ->
        {:respond, send_graphlaw_refusal(conn, to_string(reason))}

      {:error, reason} ->
        {:respond, send_graphlaw_refusal(conn, to_string(reason))}
    end
  end

  defp find_admitted(raw_type) do
    down = String.downcase(raw_type)
    Enum.find(Registry.admitted_resource_types(), fn t -> String.downcase(t) == down end)
  end

  defp resource_id(sub_id, rg_name, provider_ns, resource_type, resource_name) do
    "/subscriptions/#{sub_id}/resourceGroups/#{rg_name}/providers/#{provider_ns}/#{resource_type}/#{resource_name}"
  end

  defp ns_of(full_type), do: full_type |> String.split("/") |> List.first()
  defp leaf_of(full_type), do: full_type |> String.split("/") |> Enum.at(1)

  # LRO PUT async response: polling URLs resolve from the client's seat — the
  # same request-authority derivation the OIDC envelopes use (never a hardcoded
  # management.smalt.local).
  defp async_put_response(conn, status, op) do
    authority = request_authority(conn)

    conn
    |> put_resp_header("azure-asyncoperation", "#{authority}#{op["id"]}")
    |> put_resp_header("location", "#{authority}#{op["id"]}")
    |> put_resp_header("retry-after", "1")
    |> send_json(status, Jason.encode!(op))
  end

  # LRO-async types (azurerm polls these via Azure-AsyncOperation)
  # KD-COVERS: KD-111 — widening to the full Azure async set. PUT create ->
  # 202 async for every type below; PUT update stays SYNC 200 for the
  # widened types (AZB-25b law: only create is async at ARM), while the
  # original witness set keeps its 200-async update (lro_async_update_type?/1).
  # DELETE for these types is already sync 200 (handle_child_delete /
  # dedicated delete routes) — no change needed.
  # The LRO Sweeper (Smalt.ArmGateway.LRO.Sweeper.flip_pass/0) is
  # TYPE-BLIND: it drives every InProgress record in :smalt_operations by
  # startedAtMs + delayMs, so new types need no sweeper change.
  defp lro_type?(type) do
    type in [
      "Microsoft.Storage/storageAccounts",
      "Microsoft.Compute/virtualMachines",
      "Microsoft.ServiceBus/namespaces",
      "Microsoft.EventHub/namespaces",
      "Microsoft.KeyVault/vaults",
      "Microsoft.DocumentDB/databaseAccounts"
    ]
  end

  # The subset whose PUT UPDATE is also async (original azurerm witness set
  # only — the KD-111 widening deliberately keeps update sync per ARM).
  defp lro_async_update_type?(type) do
    type in ["Microsoft.Storage/storageAccounts", "Microsoft.Compute/virtualMachines"]
  end

  # KD-T5-F3: real ARM async-operation terminal bodies carry only operation
  # fields, but azurerm 4.54's storage LRO poller synthesizes the Terraform
  # resource identity from the FINAL poll body — with the bare operation
  # record it produced "Missing Resource Identity After Create" (T5
  # cleanroom wire evidence, tf-apply.log). The terminal wire body is
  # enriched with the target resource's id/name/type plus its stored
  # properties/location; the STORED operation record is untouched (the
  # subscription-scope ownership check still runs on the operation id), so
  # this is a render-time transform only.
  # KD-COVERS: KD-81
  defp lro_wire_body(%{"status" => "InProgress"} = op), do: op

  defp lro_wire_body(%{"resourceId" => res_id} = op) when is_binary(res_id) do
    enrichment =
      case String.split(res_id, "/") do
        ["", "subscriptions", _sub, "resourceGroups", _rg, "providers", ns, leaf, name] ->
          %{"id" => res_id, "name" => name, "type" => "#{ns}/#{leaf}"}

        _ ->
          %{}
      end

    stored =
      case Store.get(:smalt_resources, String.downcase(res_id)) do
        {:ok, %{"properties" => props, "location" => loc}}
        when is_map(props) and is_binary(loc) ->
          %{"properties" => props, "location" => loc}

        _ ->
          %{}
      end

    # merge order: op base → stored record (resource-like properties/
    # location/tags) → identity enrichment (resource id/name/type wins).
    op
    |> Map.merge(stored)
    |> Map.merge(enrichment)
  end

  defp lro_wire_body(op), do: op

  # ===========================================================================
  # SHIM-COURT affidavit-seal ingestion functor (lane 611, best-effort sideband)
  #
  # Wire-up law: on a successful resource PUT and on the RG-delete cascade the
  # canonical stored-record bytes are admitted through the affidavit WASM
  # engine (ML-DSA-65 seal). The seal is a SIDEBAND — a dead engine, a refused
  # seal, or an unavailable tariff calculator NEVER changes the HTTP outcome
  # and never crashes the PUT/DELETE (fail-safe rescue -> typed
  # :PQC_NOT_PROVISIONED witness-absent). Witnesses land in an ETS sideband
  # table (`:smalt_affidavit_witnesses`) plus the log, not in the wire records,
  # so stored/wire byte-parity is untouched.
  # ===========================================================================

  @affidavit_witness_table :smalt_affidavit_witnesses
  @affidavit_high_tariff_cents 5_000_000_000

  # Sealed-witness sideband reader (test + receipt surface).
  @doc false
  def affidavit_witness(subject) when is_binary(subject) do
    ensure_witness_table()

    case :ets.lookup(@affidavit_witness_table, subject) do
      [{^subject, witness}] -> witness
      [] -> :error
    end
  end

  defp ensure_witness_table do
    if :ets.info(@affidavit_witness_table) == :undefined do
      try do
        :ets.new(@affidavit_witness_table, [
          :named_table,
          :public,
          :set,
          read_concurrency: true
        ])
      rescue
        ArgumentError -> :ok
      end
    end

    @affidavit_witness_table
  end

  defp affidavit_seal(record, %{subject: subject, lease_context: lease_context})
       when is_map(record) do
    state_delta = Jason.encode!(record)
    tariff = affidavit_tariff(record, state_delta)
    modality = if is_integer(tariff) and tariff < @affidavit_high_tariff_cents, do: 1, else: 2

    witness =
      case affidavit_engine_seal(state_delta, tariff, modality, lease_context) do
        {:ok, witness} -> normalize_witness(witness, tariff, modality)
        {:error, reason} -> witness_absent(reason)
      end

    ensure_witness_table()
    :ets.insert(@affidavit_witness_table, {subject, Map.put(witness, "subject", subject)})

    unless witness["sealed"] do
      Logger.warning(
        "SHIM-COURT affidavit-seal: :PQC_NOT_PROVISIONED witness-absent for #{subject} (#{witness["reason"]})"
      )
    end

    affidavit_ocel_emit(state_delta, witness)
    witness
  end

  # SHIM-COURT lane622: registry-gated OCEL sideband — one `affidavit.seal`
  # event per completed seal through Smalt.Telemetry.AffidavitOcel.seal/1
  # (matter-isolation: SHA-256 of the canonical state_delta + verdict +
  # engine receipt identity only; no receipt payloads). Fail-safe: any
  # emission failure is logged and dropped, NEVER raised into the sealer —
  # admission outcome is untouched.
  defp affidavit_ocel_emit(state_delta, witness) do
    verdict = if witness["sealed"], do: "admitted", else: "refused"

    engine_hash =
      case witness["receipt"] do
        nil -> "unknown"
        receipt -> "sha256:" <> (:crypto.hash(:sha256, receipt) |> Base.encode16(case: :lower))
      end

    subject_sha = :crypto.hash(:sha256, state_delta) |> Base.encode16(case: :lower)

    case Smalt.Telemetry.AffidavitOcel.seal(
           subject_sha: subject_sha,
           verdict: verdict,
           engine_hash: engine_hash
         ) do
      # {:ok, _} covers {:ok, :dropped}; both map to :ok
      {:ok, _} ->
        :ok

      {:error, reason} ->
        Logger.warning("SHIM-COURT lane622: affidavit.seal OCEL dropped: #{inspect(reason)}")
    end
  rescue
    e ->
      Logger.warning(
        "SHIM-COURT lane622: affidavit.seal OCEL emission failed: #{Exception.message(e)}"
      )
  end

  # Tariff: Smalt.FinOps.Calculator.avoided_tariff_cents/2 (F lane, contract:
  # type :: String.t() x proxy :: %{bytes: pos_integer()}) when loaded, with a
  # single non-blocking load check; otherwise a deterministic local proxy
  # (1_000_000 cents + 100 cents per canonical byte) so the seal path stays
  # exercisable before the calculator lands.
  defp affidavit_tariff(record, state_delta) do
    if finops_loaded?() do
      proxy = %{"bytes" => byte_size(state_delta)}

      try do
        apply(Smalt.FinOps.Calculator, :avoided_tariff_cents, [
          Map.get(record, "type", "unknown"),
          proxy
        ])
      rescue
        _ -> proxy_tariff(state_delta)
      end
    else
      proxy_tariff(state_delta)
    end
  end

  defp finops_loaded? do
    case :persistent_term.get({__MODULE__, :finops_loaded}, nil) do
      true ->
        true

      _cache ->
        # Single non-blocking readiness check (sleep deleted 2026-10-18: the
        # old 5x100ms retry loop is gone). The calculator module is either
        # already loaded (steady state) or the caller fails closed to
        # proxy_tariff immediately — never a blocking wait on module load.
        loaded? = match?({:module, _}, Code.ensure_loaded(Smalt.FinOps.Calculator))

        if loaded?, do: :persistent_term.put({__MODULE__, :finops_loaded}, true)

        loaded?
    end
  end

  defp proxy_tariff(state_delta), do: 1_000_000 + byte_size(state_delta)

  # Prefer the D-lane 4-arity wrapper (`call_admit_and_seal/4`); when it is
  # not yet compiled, fall back to the landed `affi_admit_and_seal/1` export
  # by folding tariff/modality/lease into the canonical request document.
  defp affidavit_engine_seal(state_delta, tariff, modality, lease_context) do
    cond do
      function_exported?(Smalt.Affidavit.WasmEngine, :call_admit_and_seal, 4) ->
        apply(Smalt.Affidavit.WasmEngine, :call_admit_and_seal, [
          state_delta,
          tariff,
          modality,
          lease_context
        ])

      function_exported?(Smalt.Affidavit.WasmEngine, :affi_admit_and_seal, 1) ->
        request =
          Jason.encode!(%{
            "op" => "admit_and_seal",
            "state_delta" => state_delta,
            "tariff_cents" => tariff,
            "modality" => modality,
            "lease_context" => lease_context
          })

        apply(Smalt.Affidavit.WasmEngine, :affi_admit_and_seal, [request])

      true ->
        {:error, :engine_unavailable}
    end
  rescue
    # JA-R1 (V3): fail-closed envelope unchanged; the crash is no longer
    # silent — every engine-down refusal here is operator-visible.
    e ->
      Logger.error(
        "arm_gateway affidavit seal: engine crash -> :engine_unavailable (#{Exception.message(e)})"
      )

      {:error, :engine_unavailable}
  catch
    # A WASM engine crash surfaces client-side as :exit (the GenServer dies
    # mid-call); the sideband must stay fail-safe through exits too.
    :exit, reason ->
      Logger.error(
        "arm_gateway affidavit seal: engine exit -> :engine_unavailable (#{inspect(reason)})"
      )

      {:error, :engine_unavailable}
  end

  # {:ok, witness} — accept the D-lane structured map
  # %{ctrt_bytes: binary(), pqc_receipt: binary()}, a generic string-keyed
  # map, or a raw sealed CTRT binary; the block always carries ctrt hex.
  defp normalize_witness(%{ctrt_bytes: ctrt, pqc_receipt: receipt}, tariff, modality)
       when is_binary(ctrt) do
    %{
      "ctrt" => Base.encode16(ctrt, case: :lower),
      "receipt" => to_string(receipt),
      "tariff_cents" => tariff,
      "modality" => modality,
      "sealed" => true
    }
  end

  defp normalize_witness(%{} = witness, tariff, modality) do
    witness
    |> Map.put_new("ctrt", "affidavit-wasm")
    |> Map.put_new("receipt", "sealed")
    |> Map.put("tariff_cents", tariff)
    |> Map.put("modality", modality)
    |> Map.put("sealed", true)
  end

  defp normalize_witness(ctrt, tariff, modality) when is_binary(ctrt) do
    %{
      "ctrt" => Base.encode16(ctrt, case: :lower),
      "receipt" => "affidavit-wasm ctrt sealed token",
      "tariff_cents" => tariff,
      "modality" => modality,
      "sealed" => true
    }
  end

  # Typed witness-absent fallback: never a crash, admission unchanged.
  defp witness_absent(reason) do
    %{
      "ctrt" => nil,
      "receipt" => "PQC_NOT_PROVISIONED",
      "sealed" => false,
      "reason" => to_string(reason)
    }
  end

  # ===========================================================================
  # Routes (first-match-wins: deeper/collection routes precede shallower ones)
  # ===========================================================================

  # -- STS / OAuth2 Token Issuance --------------------------------------------
  post "/oauth2/v2.0/token" do
    handle_token(conn, "00000000-0000-0000-0000-000000000000")
  end

  post "/:tenant_id/oauth2/v2.0/token" do
    handle_token(conn, tenant_id)
  end

  # -- IMDS / managed identity (w6r) -------------------------------------------
  # Leaf route ahead of the bearer-guarded generic routes; Plug.Router matched
  # the path only (query string excluded). Serves ARM 9443 and the TLS twin.
  get "/metadata/identity/oauth2/token" do
    Smalt.Auth.Imds.handle_token(conn)
  end

  # -- Bootstrap / discovery endpoints ----------------------------------------
  get "/metadata/endpoints" do
    authority = request_authority(conn)

    body =
      Jason.encode!(%{
        # 2022-09-01 schema (go-azure-sdk metadata.Client.GetMetaData; the
        # azurerm ARM_METADATA_HOSTNAME path requires name, resourceManager
        # and a TOP-LEVEL microsoftGraphResourceId — the parser reads
        # metadata.MicrosoftGraphResourceId (json "microsoftGraphResourceId",
        # flat), NOT a nested "resourceIdentifiers" object; witnessed by
        # azurerm 4.54.0 "no `microsoftGraphResourceId` was returned" until
        # the flat key landed (tf-plan probe lane, 2026-10-16).
        "name" => "smalt-sovereign",
        # Echo the request authority, not a hardcoded 9443: the metadata doc
        # is what go-azure-sdk builds its Environment from, so a hardcoded
        # port silently re-points every lane-private substrate's clients at
        # the shared 9443 substrate (witnessed: cross-substrate STS
        # SignatureVerificationFailed 401s, tf-plan probe lane 2026-10-16).
        # KD-T5-F2: azurerm joins resourceManager verbatim with "/subscriptions/..."
        # (no TrimSuffix "/") — a trailing slash built
        # https://localhost:39391//subscriptions/... and the connection was
        # reset (T5 cleanroom tf-apply.log). The management-plane roots are
        # emitted WITHOUT the trailing slash; real Azure's roots carry it,
        # so this is a join-semantics deviation, deliberate.
        "resourceManagerEndpoint" => String.trim_trailing(authority, "/"),
        # KD-COVERS: KD-80 (metadata resourceManager trailing-slash join semantics)
        "resourceManager" => String.trim_trailing(authority, "/"),
        "managementEndpoint" => String.trim_trailing(authority, "/"),
        "activeDirectoryEndpoint" => "#{authority}/",
        "microsoftGraphResourceId" => "https://graph.smalt.local/",
        # legacy consumers (SDK docs surface a resourceIdentifiers object);
        # go-azure-sdk itself ignores this nesting, kept for shape parity.
        "resourceIdentifiers" => %{
          "microsoftGraphResourceId" => "https://graph.smalt.local/"
        },
        # go-azure-sdk metadata parser reads json key "suffixes" (flat Azure
        # suffix names); "dnsSuffixes" is the shape OTHER clients document but
        # the Go parser never reads it — witnessed: azurerm 4.54.0 Storage
        # authorizer "endpoint AzureStorage is not supported" until the
        # suffixes map landed (tf-plan probe lane, 2026-10-16).
        "suffixes" => %{
          "keyVaultDns" => "vault.smalt.local",
          "storage" => "smalt.local",
          "sqlServerHostname" => "database.smalt.local",
          "acrLoginServer" => "registry.smalt.local",
          "mhsmDns" => "managedhsm.smalt.local",
          "attestationEndpoint" => "attest.smalt.local",
          "azureFrontDoorEndpointSuffix" => "afd.smalt.local",
          "storageSyncEndpointSuffix" => "afshare.smalt.local",
          "synapseAnalytics" => "dev.smalt.local",
          "mysqlServerEndpoint" => "mysql.smalt.local",
          "postgresqlServerEndpoint" => "postgres.smalt.local",
          "mariadbServerEndpoint" => "mariadb.smalt.local",
          "azureDataLakeStoreFileSystem" => "azuredatalakestore.smalt.local"
        },
        "dnsSuffixes" => %{
          "keyVault" => "vault.smalt.local",
          "storage" => "smalt.local",
          "sqlServer" => "database.smalt.local",
          "containerRegistry" => "registry.smalt.local",
          "attestation" => "attest.smalt.local",
          "frontDoor" => "afd.smalt.local",
          "managedHSM" => "managedhsm.smalt.local",
          "storageSync" => "afshare.smalt.local",
          "synapse" => "dev.smalt.local",
          "dataLakeStore" => "azuredatalakestore.smalt.local",
          "mariaDb" => "mariadb.smalt.local",
          "mySql" => "mysql.smalt.local",
          "postgresql" => "postgres.smalt.local"
        },
        "authentication" => %{
          # Same host the client used (TLS-twin clients get a working
          # https envelope; azidentity permits plaintext http only for
          # localhost, which is the documented local form).
          "loginEndpoint" => "#{request_authority(conn)}/",
          "audiences" => ["https://management.azure.com"],
          # go-azure-sdk Environment.IsAzureStack() classifies the
          # environment as Azure Stack (hard-rejected by azurerm) unless
          # identityProvider == "AAD" and tenant == "common".
          "identityProvider" => "AAD",
          "tenant" => "common"
        },
        # legacy (api-version<=2018-01) shape kept for older consumers
        # (managementEndpoint/resourceManager/activeDirectoryEndpoint now echo
        # the request authority — see above).
        "graphEndpoint" => "https://graph.smalt.local/",
        "graph" => "https://graph.smalt.local/",
        "sqlManagement" => "https://management.core.smalt.local/",
        "galleryEndpoint" => "https://gallery.smalt.local/",
        "activeDirectoryResourceId" => "https://management.azure.com/"
      })

    send_json(conn, 200, body)
  end

  # -- Health probe faces (BK-PROBE, BK-ARM1 F-1) ------------------------------
  # The kernel's self-report (Smalt.Health) rendered as typed HTTP: 200/503.
  # kubelet's probes point here (k8s/smalt-backend.yaml) — previously both
  # probes polled /metadata/endpoints, a static always-200 metadata handler,
  # so kubelet could only ever detect a dead listener, never a degraded BEAM.
  # Declared before the flat ATOM aliases and the /:entity_name catch-alls;
  # the three-segment paths cannot collide with them regardless. Paths sit in
  # the /.well-known/ bearer-exempt namespace (Smalt.Auth.Bearer
  # @exempt_prefixes) — kubelet probes are tokenless bootstrap-class
  # requests, same as /metadata/endpoints.
  get "/.well-known/health/live" do
    case Smalt.Health.liveness() do
      :alive -> send_json(conn, 200, Jason.encode!(%{status: "alive"}))
    end
  end

  get "/.well-known/health/ready" do
    verdict = Smalt.Health.readiness()

    send_json(
      conn,
      Smalt.Health.http_status(verdict),
      Jason.encode!(Smalt.Health.to_json_map(verdict))
    )
  end

  get "/common/discovery/instance" do
    tid = "00000000-0000-0000-0000-000000000000"
    base = request_authority(conn)

    body =
      Jason.encode!(%{
        "tenantId" => tid,
        "name" => "smalt-sovereign",
        "authorization_endpoint" => "#{base}/#{tid}/oauth2/v2.0/authorize",
        "token_endpoint" => "#{base}/#{tid}/oauth2/v2.0/token",
        "issuer" => "#{base}/#{tid}/v2.0",
        "tenant_discovery_endpoint" => "#{base}/#{tid}/v2.0/.well-known/openid-configuration",
        # msal instance discovery (the envelope that unblocks
        # ClientSecretCredential): AAD-shape metadata array. Each entry MUST
        # carry tenant_discovery_endpoint (msal-common's
        # CloudInstanceDiscoveryResponse validates it per-entry — a flat
        # top-level one alone answers invalid_instance). The request
        # authority's HOST (scheme+port stripped) rides the aliases so the
        # emulator's own authority is admitted as an instance alias.
        "metadata" => [
          %{
            "preferred_network" => "login.microsoftonline.com",
            "preferred_cache" => "login.windows.net",
            "aliases" =>
              ["login.microsoftonline.com", "login.windows.net", "login.microsoft.com"] ++
                [instance_alias_host(base)],
            "tenant_discovery_endpoint" => "#{base}/#{tid}/v2.0/.well-known/openid-configuration"
          }
        ]
      })

    send_json(conn, 200, body)
  end

  get "/.well-known/openid-configuration" do
    send_json(conn, 200, Jason.encode!(openid_envelope(conn, "organizations")))
  end

  get "/:tenant_id/v2.0/.well-known/openid-configuration" do
    send_json(conn, 200, Jason.encode!(openid_envelope(conn, tenant_id)))
  end

  # JWKS endpoint: under :rs256 the STS public key is published (kty/n/e/use/
  # alg/kid); under :hs256_dev the shared secret is never published, so the
  # key set stays honestly empty (an OIDC-compliant doc must not advertise a
  # jwks_uri that 404s).
  get "/:tenant_id/discovery/v2.0/keys" do
    keys =
      case Smalt.Auth.StsKey.mode() do
        :rs256 -> [Smalt.Auth.StsKey.jwk_map()]
        :hs256_dev -> []
      end

    send_json(conn, 200, Jason.encode!(%{"keys" => keys}))
  end

  get "/tenant" do
    send_tenant_list(conn)
  end

  get "/tenants" do
    send_tenant_list(conn)
  end

  # -- Subscriptions -----------------------------------------------------------
  # api-version PRESENCE required on both subscription routes (real ARM requires
  # api-version on GET /subscriptions and GET /subscriptions/:sub; lens-2
  # typed receipt, coordinator-authorized Raise). Presence-only: the
  # subscriptions list/read is not an admitted Registry individual, so no
  # latest-version validation (mirrors the azapi action + inventory gates).
  # LRO polling (`/operations/:op_id`) stays versionless by convention — pinned
  # EXEMPT, do not gate it.
  get "/subscriptions" do
    with :ok <- check_api_version(conn, nil) do
      send_json(conn, 200, Jason.encode!(%{"value" => Store.list(:smalt_subscriptions)}))
    else
      {:respond, conn} -> conn
    end
  end

  get "/subscriptions/:sub_id" do
    with :ok <- check_api_version(conn, nil) do
      case Store.get(:smalt_subscriptions, sub_id) do
        {:ok, sub} ->
          send_json(conn, 200, Jason.encode!(sub))

        :error ->
          send_arm_error(
            conn,
            404,
            "SubscriptionNotFound",
            "The subscription '#{sub_id}' was not found.",
            "/subscriptions/#{sub_id}"
          )
      end
    else
      {:respond, conn} -> conn
    end
  end

  # -- LRO polling -------------------------------------------------------------
  get "/subscriptions/:sub_id/operations/:op_id" do
    case LRO.get_op(op_id, sub_id) do
      {:ok, op} ->
        # Only "InProgress" renders 202 — every other status is treated as
        # terminal (default-terminal, no wedge). Lens-9 cycle-1 fixed the
        # Failed face (a Failed terminal rendered as 202); cycle-4 widened to
        # the default so any other terminal vocabulary (Cancelled, …) can
        # never poll 202 forever.
        status = if op["status"] == "InProgress", do: 202, else: 200
        send_json(conn, status, Jason.encode!(lro_wire_body(op)))

      :error ->
        send_arm_error(
          conn,
          404,
          "OperationNotFound",
          "Operation '#{op_id}' was not found.",
          conn.request_path
        )
    end
  end

  # -- Resource group LIST collection (must precede :rg_name routes) -----------
  get "/subscriptions/:sub_id/resourcegroups" do
    handle_rg_list(conn, sub_id)
  end

  get "/subscriptions/:sub_id/resourceGroups" do
    handle_rg_list(conn, sub_id)
  end

  # -- Resource groups (case-normalized) ----------------------------------------
  put "/subscriptions/:sub_id/resourcegroups/:rg_name" do
    handle_rg_put(conn, sub_id, rg_name)
  end

  put "/subscriptions/:sub_id/resourceGroups/:rg_name" do
    handle_rg_put(conn, sub_id, rg_name)
  end

  get "/subscriptions/:sub_id/resourcegroups/:rg_name" do
    handle_rg_get(conn, sub_id, rg_name)
  end

  get "/subscriptions/:sub_id/resourceGroups/:rg_name" do
    handle_rg_get(conn, sub_id, rg_name)
  end

  patch "/subscriptions/:sub_id/resourcegroups/:rg_name" do
    handle_rg_patch(conn, sub_id, rg_name)
  end

  patch "/subscriptions/:sub_id/resourceGroups/:rg_name" do
    handle_rg_patch(conn, sub_id, rg_name)
  end

  get "/subscriptions/:sub_id/resourcegroups/:rg_name/resources" do
    handle_rg_resources_list(conn, sub_id, rg_name)
  end

  get "/subscriptions/:sub_id/resourceGroups/:rg_name/resources" do
    handle_rg_resources_list(conn, sub_id, rg_name)
  end

  get "/subscriptions/:sub_id/locations" do
    handle_locations_list(conn, sub_id)
  end

  # AZURE-FIDELITY lane 5: Activity Log — the documented eventtypes/management
  # surface. Events are assembled from the generic-resource CRUD hook
  # (Smalt.ArmGateway.ActivityLog.record/4, fail-safe post-store sideband in
  # the PUT/PATCH/DELETE handlers). $filter subset: eventTimestamp ge/le,
  # resourceId eq, operationName eq (and-combined).
  get "/subscriptions/:sub_id/providers/microsoft.insights/eventtypes/management/values" do
    case Smalt.ArmGateway.ActivityLog.handle_query(conn, sub_id) do
      {:ok, status, body} ->
        conn
        |> put_resp_content_type("application/json")
        |> send_resp(status, body)
    end
  end

  # AZURE-FIDELITY lane 7: create-blade validation surface. ResourceSkus
  # list (documented shape incl. restrictions) + regional quota usage for
  # Compute and Network (currentValue derived from real stored resources).
  get "/subscriptions/:sub_id/providers/Microsoft.Compute/skus" do
    with :ok <- check_api_version(conn, nil) do
      send_json(
        conn,
        200,
        Jason.encode!(SkuQuota.list_skus(sub_id, conn.query_params["$filter"]))
      )
    else
      {:respond, conn} -> conn
    end
  end

  get "/subscriptions/:sub_id/providers/Microsoft.Compute/locations/:location/usages" do
    with :ok <- check_api_version(conn, nil) do
      send_json(conn, 200, Jason.encode!(SkuQuota.usage("Microsoft.Compute", location, sub_id)))
    else
      {:respond, conn} -> conn
    end
  end

  get "/subscriptions/:sub_id/providers/Microsoft.Network/locations/:location/usages" do
    with :ok <- check_api_version(conn, nil) do
      send_json(conn, 200, Jason.encode!(SkuQuota.usage("Microsoft.Network", location, sub_id)))
    else
      {:respond, conn} -> conn
    end
  end

  delete "/subscriptions/:sub_id/resourcegroups/:rg_name" do
    handle_rg_delete(conn, sub_id, rg_name)
  end

  delete "/subscriptions/:sub_id/resourceGroups/:rg_name" do
    handle_rg_delete(conn, sub_id, rg_name)
  end

  # -- KD-113 tags leg: tags AT SCOPE (Microsoft.Resources/tags) ---------------
  # ARM shape: the tags API at any scope is /providers/Microsoft.Resources/tags
  # (optionally /default). PUT replaces, PATCH merges; GET renders the tags
  # API envelope. Tags at RG scope live on the RG record's "tags" member, so
  # the RG delete cascade clears them for free and the RG GET/normalize path
  # (normalize_tags/1 null-when-empty law) renders them identically.
  get "/subscriptions/:sub_id/resourcegroups/:rg_name/providers/Microsoft.Resources/tags" do
    handle_scope_tags_get(conn, sub_id, rg_name)
  end

  get "/subscriptions/:sub_id/resourceGroups/:rg_name/providers/Microsoft.Resources/tags" do
    handle_scope_tags_get(conn, sub_id, rg_name)
  end

  get "/subscriptions/:sub_id/resourcegroups/:rg_name/providers/Microsoft.Resources/tags/default" do
    handle_scope_tags_get(conn, sub_id, rg_name)
  end

  get "/subscriptions/:sub_id/resourceGroups/:rg_name/providers/Microsoft.Resources/tags/default" do
    handle_scope_tags_get(conn, sub_id, rg_name)
  end

  put "/subscriptions/:sub_id/resourcegroups/:rg_name/providers/Microsoft.Resources/tags" do
    handle_scope_tags_put(conn, sub_id, rg_name, :replace)
  end

  put "/subscriptions/:sub_id/resourceGroups/:rg_name/providers/Microsoft.Resources/tags" do
    handle_scope_tags_put(conn, sub_id, rg_name, :replace)
  end

  put "/subscriptions/:sub_id/resourcegroups/:rg_name/providers/Microsoft.Resources/tags/default" do
    handle_scope_tags_put(conn, sub_id, rg_name, :replace)
  end

  put "/subscriptions/:sub_id/resourceGroups/:rg_name/providers/Microsoft.Resources/tags/default" do
    handle_scope_tags_put(conn, sub_id, rg_name, :replace)
  end

  patch "/subscriptions/:sub_id/resourcegroups/:rg_name/providers/Microsoft.Resources/tags" do
    handle_scope_tags_put(conn, sub_id, rg_name, :merge)
  end

  patch "/subscriptions/:sub_id/resourceGroups/:rg_name/providers/Microsoft.Resources/tags" do
    handle_scope_tags_put(conn, sub_id, rg_name, :merge)
  end

  patch "/subscriptions/:sub_id/resourcegroups/:rg_name/providers/Microsoft.Resources/tags/default" do
    handle_scope_tags_put(conn, sub_id, rg_name, :merge)
  end

  patch "/subscriptions/:sub_id/resourceGroups/:rg_name/providers/Microsoft.Resources/tags/default" do
    handle_scope_tags_put(conn, sub_id, rg_name, :merge)
  end

  # -- KD-COVERS: KD-58 — tenant-level tagNames CRUD (Microsoft.Resources/tags).
  # Real ARM: /tagNames (list), /tagNames/{name} (get/delete), /tagNames/{name}/
  # tagValues/{value} (put/get/delete). Rows share the :smalt_policy table under
  # a "tagname:" key prefix — same discriminated-prefix law as the KD-125
  # rem:/rs: rows (Policy owns the table; tag rows never collide with
  # lock:/definition:/rem:/rs: keys).
  get "/tagNames" do
    handle_tenant_tags_list(conn)
  end

  get "/tagNames/:tag_name" do
    handle_tenant_tags_get(conn, tag_name)
  end

  delete "/tagNames/:tag_name" do
    handle_tenant_tags_delete(conn, tag_name)
  end

  put "/tagNames/:tag_name/tagValues/:tag_value" do
    handle_tenant_tag_value_put(conn, tag_name, tag_value)
  end

  get "/tagNames/:tag_name/tagValues/:tag_value" do
    handle_tenant_tag_value_get(conn, tag_name, tag_value)
  end

  delete "/tagNames/:tag_name/tagValues/:tag_value" do
    handle_tenant_tag_value_delete(conn, tag_name, tag_value)
  end

  # -- KD-COVERS: KD-59 — resource-group exportTemplate + moveResources.
  # exportTemplate delegates to Smalt.Arm.ExportTemplate.export_rg/3 (the
  # wave-6 export face, previously unrouted); an RG with no exportable
  # resources is a typed 404 (ResourceGroupResourceNotFound). Responds 200
  # synchronous (terminal for ARM LRO pollers) — documented boundary.
  post "/subscriptions/:sub_id/resourcegroups/:rg_name/exportTemplate" do
    handle_export_template(conn, sub_id, rg_name)
  end

  post "/subscriptions/:sub_id/resourceGroups/:rg_name/exportTemplate" do
    handle_export_template(conn, sub_id, rg_name)
  end

  # moveResources / validateMoveResources: TYPED UNSUPPORTED (row KD-59 close
  # condition admits routes OR typed refusal; falsifier: "never 404").
  post "/subscriptions/:sub_id/resourcegroups/:rg_name/moveResources" do
    handle_move_resources(conn, sub_id, rg_name)
  end

  post "/subscriptions/:sub_id/resourceGroups/:rg_name/moveResources" do
    handle_move_resources(conn, sub_id, rg_name)
  end

  post "/subscriptions/:sub_id/resourcegroups/:rg_name/validateMoveResources" do
    handle_move_resources(conn, sub_id, rg_name)
  end

  post "/subscriptions/:sub_id/resourceGroups/:rg_name/validateMoveResources" do
    handle_move_resources(conn, sub_id, rg_name)
  end

  # -- Management locks (KD-113 leg b): wired to Smalt.Policy (wave-4 lane w4d).
  # api-version 2016-09-01 is admitted monotonic (<= latest 2020-05-01).
  # Subscription scope first (exact path prefix, no :ns shadow risk — the
  # single-namespace route matches one segment only).
  get "/subscriptions/:sub_id/providers/Microsoft.Authorization/locks" do
    handle_locks_list(conn, "/subscriptions/#{sub_id}")
  end

  get "/subscriptions/:sub_id/providers/Microsoft.Authorization/locks/:lock_name" do
    handle_lock_get(conn, "/subscriptions/#{sub_id}", lock_name)
  end

  put "/subscriptions/:sub_id/providers/Microsoft.Authorization/locks/:lock_name" do
    handle_lock_put(conn, "/subscriptions/#{sub_id}", lock_name)
  end

  delete "/subscriptions/:sub_id/providers/Microsoft.Authorization/locks/:lock_name" do
    handle_lock_delete(conn, "/subscriptions/#{sub_id}", lock_name)
  end

  get "/subscriptions/:sub_id/resourcegroups/:rg_name/providers/Microsoft.Authorization/locks" do
    handle_locks_list(conn, "/subscriptions/#{sub_id}/resourceGroups/#{rg_name}")
  end

  get "/subscriptions/:sub_id/resourceGroups/:rg_name/providers/Microsoft.Authorization/locks" do
    handle_locks_list(conn, "/subscriptions/#{sub_id}/resourceGroups/#{rg_name}")
  end

  get "/subscriptions/:sub_id/resourcegroups/:rg_name/providers/Microsoft.Authorization/locks/:lock_name" do
    handle_lock_get(conn, "/subscriptions/#{sub_id}/resourceGroups/#{rg_name}", lock_name)
  end

  get "/subscriptions/:sub_id/resourceGroups/:rg_name/providers/Microsoft.Authorization/locks/:lock_name" do
    handle_lock_get(conn, "/subscriptions/#{sub_id}/resourceGroups/#{rg_name}", lock_name)
  end

  put "/subscriptions/:sub_id/resourcegroups/:rg_name/providers/Microsoft.Authorization/locks/:lock_name" do
    handle_lock_put(conn, "/subscriptions/#{sub_id}/resourceGroups/#{rg_name}", lock_name)
  end

  put "/subscriptions/:sub_id/resourceGroups/:rg_name/providers/Microsoft.Authorization/locks/:lock_name" do
    handle_lock_put(conn, "/subscriptions/#{sub_id}/resourceGroups/#{rg_name}", lock_name)
  end

  delete "/subscriptions/:sub_id/resourcegroups/:rg_name/providers/Microsoft.Authorization/locks/:lock_name" do
    handle_lock_delete(conn, "/subscriptions/#{sub_id}/resourceGroups/#{rg_name}", lock_name)
  end

  delete "/subscriptions/:sub_id/resourceGroups/:rg_name/providers/Microsoft.Authorization/locks/:lock_name" do
    handle_lock_delete(conn, "/subscriptions/#{sub_id}/resourceGroups/#{rg_name}", lock_name)
  end

  # -- Cost Management query + Consumption usageDetails (AZURE-FIDELITY lane 6).
  # Both delegate to Smalt.ArmGateway.CostManagement over the seeded
  # :smalt_cost_usage event store. api-version presence-checked only (neither
  # namespace is an admitted Registry individual; default permissive gate).
  post "/subscriptions/:sub_id/providers/Microsoft.CostManagement/query" do
    with :ok <- check_api_version(conn, nil) do
      CostManagement.seed_defaults(sub_id)

      case CostManagement.query(sub_id, conn.body_params) do
        {:ok, body} ->
          send_json(conn, 200, Jason.encode!(body))

        {:error, {:unsupported_type, t}} ->
          send_arm_error(
            conn,
            400,
            "InvalidRequest",
            "Unsupported query type '#{t}'. Only 'ActualCost' is served."
          )

        {:error, {:unsupported_timeframe, tf}} ->
          send_arm_error(
            conn,
            400,
            "InvalidRequest",
            "Unsupported timeframe '#{tf}'."
          )

        {:error, :missing_time_period} ->
          send_arm_error(
            conn,
            400,
            "InvalidRequest",
            "Either timeframe or timePeriod (from/to) is required."
          )

        {:error, :invalid_date} ->
          send_arm_error(
            conn,
            400,
            "InvalidRequest",
            "timePeriod from/to must be ISO-8601 dates."
          )

        {:error, :invalid_request} ->
          send_arm_error(conn, 400, "InvalidRequest", "The query body is not a valid object.")
      end
    else
      {:respond, conn} -> conn
    end
  end

  post "/subscriptions/:sub_id/providers/Microsoft.CostManagement/forecast" do
    with :ok <- check_api_version(conn, nil) do
      CostManagement.seed_defaults(sub_id)

      case CostManagement.forecast(sub_id, conn.body_params) do
        {:ok, body} ->
          send_json(conn, 200, Jason.encode!(body))

        {:error, {:unsupported_type, t}} ->
          send_arm_error(
            conn,
            400,
            "InvalidRequest",
            "Unsupported query type '#{t}'. Only 'ActualCost' is served."
          )

        {:error, {:unsupported_timeframe, tf}} ->
          send_arm_error(
            conn,
            400,
            "InvalidRequest",
            "Unsupported timeframe '#{tf}'."
          )

        {:error, :missing_time_period} ->
          send_arm_error(
            conn,
            400,
            "InvalidRequest",
            "Either timeframe or timePeriod (from/to) is required."
          )

        {:error, :invalid_date} ->
          send_arm_error(
            conn,
            400,
            "InvalidRequest",
            "timePeriod from/to must be ISO-8601 dates."
          )

        {:error, :invalid_request} ->
          send_arm_error(conn, 400, "InvalidRequest", "The query body is not a valid object.")
      end
    else
      {:respond, conn} -> conn
    end
  end

  get "/subscriptions/:sub_id/providers/Microsoft.Consumption/usageDetails" do
    with :ok <- check_api_version(conn, nil) do
      CostManagement.seed_defaults(sub_id)
      send_json(conn, 200, Jason.encode!(CostManagement.usage_details(sub_id, conn.query_params)))
    else
      {:respond, conn} -> conn
    end
  end

  # -- AZURE-FIDELITY lane 4: tags at SUBSCRIPTION scope ------------------------
  # Microsoft.Resources/tags at subscription scope rides the :smalt_subscriptions
  # record's "tags" member (same null-when-empty render law as the RG-scope
  # tags leg). Must precede the /providers/:ns catch-all shape-wise; declared
  # here for cohesion with the lock routes it mirrors.
  get "/subscriptions/:sub_id/providers/Microsoft.Resources/tags" do
    handle_subscription_tags_get(conn, sub_id)
  end

  get "/subscriptions/:sub_id/providers/Microsoft.Resources/tags/default" do
    handle_subscription_tags_get(conn, sub_id)
  end

  put "/subscriptions/:sub_id/providers/Microsoft.Resources/tags" do
    handle_subscription_tags_put(conn, sub_id, :replace)
  end

  put "/subscriptions/:sub_id/providers/Microsoft.Resources/tags/default" do
    handle_subscription_tags_put(conn, sub_id, :replace)
  end

  patch "/subscriptions/:sub_id/providers/Microsoft.Resources/tags" do
    handle_subscription_tags_put(conn, sub_id, :merge)
  end

  patch "/subscriptions/:sub_id/providers/Microsoft.Resources/tags/default" do
    handle_subscription_tags_put(conn, sub_id, :merge)
  end

  # -- Subscription-level provider listing (ProviderMatrix projection) ----------
  # api-version PRESENCE required (Microsoft.Resources/providers is not an
  # admitted Registry individual — no latest-version validation, mirroring the
  # azapi action gate). Wave-2: the listing is the Registry-projected
  # ProviderMatrix.provider_listing/1 — the store-scan inventory (and its
  # top-level subscriptionId field) is gone; azurerm reads "value" rows.
  get "/subscriptions/:sub_id/providers" do
    with :ok <- check_api_version(conn, nil) do
      # AZURE-FIDELITY lane 1: the subscription-scope listing overlays the
      # persisted registration state per namespace (register/unregister are
      # stateful per subscription; the tenant listing keeps the constant).
      listing =
        ProviderMatrix.provider_listing()
        |> Map.update!("value", fn providers ->
          Enum.map(providers, fn p ->
            stored = ProviderState.registration_state(sub_id, p["namespace"], p["registrationState"])
            Map.put(p, "registrationState", stored)
          end)
        end)

      send_json(conn, 200, Jason.encode!(listing))
    else
      {:respond, conn} -> conn
    end
  end

  # Single provider namespace: 404 ResourceNotFound for an unknown namespace
  # (no fabricated provider — ProviderMatrix.provider/1 returns nil).
  get "/subscriptions/:sub_id/providers/:ns" do
    with :ok <- check_api_version(conn, nil) do
      case ProviderMatrix.provider(ns) do
        nil ->
          send_arm_error(
            conn,
            404,
            "ResourceNotFound",
            "Provider namespace '#{ns}' could not be found.",
            "/subscriptions/#{sub_id}/providers/#{ns}"
          )

        provider ->
          # AZURE-FIDELITY lane 1: registration lifecycle is STATEFUL per
          # subscription — register/unregister persists a row and every later
          # GET of the provider reflects the stored transition. Subscriptions
          # with no transition keep the ProviderMatrix constant posture.
          stored = ProviderState.registration_state(sub_id, ns, provider["registrationState"])
          send_json(conn, 200, Jason.encode!(Map.put(provider, "registrationState", stored)))
      end
    else
      {:respond, conn} -> conn
    end
  end

  # AZURE-FIDELITY lane 1: per-provider operations index (documented ARM
  # surface every RP serves: GET /subscriptions/{s}/providers/{ns}/operations).
  # Derived from the same ProviderMatrix projection the provider object uses —
  # read/write/delete per admitted resource type plus the operations/read
  # self row. Unknown namespaces 404 ResourceNotFound (no fabricated provider).
  get "/subscriptions/:sub_id/providers/:ns/operations" do
    provider_operations(conn, ns, "/subscriptions/#{sub_id}/providers/#{ns}")
  end

  # Provider register/unregister (azurerm resource provider registration wire
  # form). READ-ONLY ENCLAVE TRUTH: registration state is not persisted —
  # register acknowledges "Registered" and unregister acknowledges
  # "Unregistering", while every GET of the provider keeps reporting
  # "Registered" (ProviderMatrix constant). Unknown namespaces 404
  # ResourceNotFound on all three verbs.
  post "/subscriptions/:sub_id/providers/:ns/register" do
    provider_registration(conn, sub_id, ns, "Registered")
  end

  post "/subscriptions/:sub_id/providers/:ns/unregister" do
    provider_registration(conn, sub_id, ns, "Unregistering")
  end

  # KD-56: providerPermissions (azurerm/SDK probe surface). Read-only enclave
  # truth: the envelope carries one Owner allow row — no RBAC store exists.
  # # KD-COVERS: KD-56
  get "/subscriptions/:sub_id/providers/:ns/providerPermissions" do
    with :ok <- check_api_version(conn, nil) do
      send_json(
        conn,
        200,
        Jason.encode!(%{
          "value" => [
            %{
              "actions" => ["*"],
              "noActions" => [],
              "dataActions" => [],
              "noDataActions" => []
            }
          ]
        })
      )
    else
      {:respond, conn} -> conn
    end
  end

  # KD-55: tenant-scope provider listing (`GET /providers`) and per-namespace
  # (`GET /providers/:ns`) — the same ProviderMatrix projection the
  # subscription-scope routes serve; unknown namespace 404s ResourceNotFound.
  # # KD-COVERS: KD-55
  get "/providers" do
    with :ok <- check_api_version(conn, nil) do
      send_json(conn, 200, Jason.encode!(ProviderMatrix.provider_listing()))
    else
      {:respond, conn} -> conn
    end
  end

  get "/providers/:ns" do
    with :ok <- check_api_version(conn, nil) do
      case ProviderMatrix.provider(ns) do
        nil ->
          send_arm_error(
            conn,
            404,
            "ResourceNotFound",
            "Provider namespace '#{ns}' could not be found.",
            "/providers/#{ns}"
          )

        provider ->
          send_json(conn, 200, Jason.encode!(provider))
      end
    else
      {:respond, conn} -> conn
    end
  end

  # AZURE-FIDELITY lane 1: tenant-scope per-provider operations index.
  get "/providers/:ns/operations" do
    provider_operations(conn, ns, "/providers/#{ns}")
  end

  # KD-55: Microsoft.Resources operations list (tenant + subscription scope).
  # Static arm-operations envelope — SDKs probe it for the az/SDK operations
  # index; the emulator exposes a minimal deterministic set.
  # # KD-COVERS: KD-55
  get "/providers/Microsoft.Resources/operations" do
    with :ok <- check_api_version(conn, nil) do
      send_json(conn, 200, Jason.encode!(arm_operations_listing()))
    else
      {:respond, conn} -> conn
    end
  end

  get "/subscriptions/:sub_id/providers/Microsoft.Resources/operations" do
    with :ok <- check_api_version(conn, nil) do
      send_json(conn, 200, Jason.encode!(arm_operations_listing()))
    else
      {:respond, conn} -> conn
    end
  end

  defp arm_operations_listing do
    %{
      "value" => [
        %{
          "name" => "Microsoft.Resources/operations/read",
          "display" => %{
            "provider" => "Microsoft Resources",
            "resource" => "Operations",
            "operation" => "List Operations",
            "description" => "List available operations"
          },
          "is_data_action" => false
        }
      ]
    }
  end

  defp provider_registration(conn, sub_id, ns, state) do
    with :ok <- check_api_version(conn, nil) do
      case ProviderMatrix.provider(ns) do
        nil ->
          send_arm_error(
            conn,
            404,
            "ResourceNotFound",
            "Provider namespace '#{ns}' could not be found.",
            "/subscriptions/#{sub_id}/providers/#{ns}"
          )

        provider ->
          # AZURE-FIDELITY lane 1: registration transitions PERSIST — a later
          # GET of the provider (any request, any scope) reads the stored
          # state back (registration lifecycle is stateful, not echoed).
          :ok = ProviderState.set_registration(sub_id, ns, state)
          send_json(conn, 200, Jason.encode!(Map.put(provider, "registrationState", state)))
      end
    else
      {:respond, conn} -> conn
    end
  end

  # AZURE-FIDELITY lane 1: per-provider operations envelope derived from the
  # ProviderMatrix resourceTypes (read/write/delete per type + operations/read).
  # Unknown namespaces 404 ResourceNotFound — same fence as provider/1 GET.
  defp provider_operations(conn, ns, target) do
    with :ok <- check_api_version(conn, nil) do
      case ProviderMatrix.provider(ns) do
        nil ->
          send_arm_error(
            conn,
            404,
            "ResourceNotFound",
            "Provider namespace '#{ns}' could not be found.",
            target
          )

        provider ->
          ops =
            [
              %{
                "name" => "#{ns}/operations/read",
                "display" => %{
                  "provider" => ns,
                  "resource" => "Operations",
                  "operation" => "Read Operations",
                  "description" => "List available operations"
                },
                "is_data_action" => false
              }
            ] ++
              Enum.flat_map(provider["resourceTypes"] || [], fn rt ->
                type = "#{ns}/#{rt["resourceType"]}"

                for action <- ["read", "write", "delete"] do
                  %{
                    "name" => "#{type}/#{action}",
                    "display" => %{
                      "provider" => ns,
                      "resource" => rt["resourceType"],
                      "operation" => String.capitalize(action) <> "s " <> rt["resourceType"],
                      "description" => "#{String.capitalize(action)} #{type}"
                    },
                    "is_data_action" => false
                  }
                end
              end)

          send_json(conn, 200, Jason.encode!(%{"value" => ops}))
      end
    else
      {:respond, conn} -> conn
    end
  end

  # -- Subscription-wide resource LIST (KD-54) ------------------------------------
  # GET /subscriptions/:sub/resources — list resources across all RGs. Same
  # deny-by-default fence + send_list pagination as the type-scoped LIST
  # (repair lane R18); data from a prefix scan over :smalt_resources.
  get "/subscriptions/:sub_id/resources" do
    with :ok <- check_api_version(conn, nil) do
      items =
        Store.list_prefix(:smalt_resources, "/subscriptions/#{sub_id}/")
        |> Enum.filter(&renderable_record?/1)
        |> Enum.filter(&subscription_resource_filter(conn, &1))
        |> apply_lifecycle_expand(conn)

      send_list(conn, items)
    else
      {:respond, conn} -> conn
    end
  end

  # KD-54 $filter: support the eq-clauses a registry-backed record can answer:
  # resourceType, resourceGroup, name, location. Unknown/unparseable clauses
  # deny by default (match nothing) rather than silently listing everything.
  defp subscription_resource_filter(conn, %{"id" => id} = record)
       when is_binary(id) do
    case conn.query_params["$filter"] do
      nil ->
        true

      filter when is_binary(filter) ->
        parse_filter_clauses(filter)
        |> Enum.all?(fn {field, wanted} ->
          case field do
            "resourceType" ->
              is_binary(record["type"]) and
                String.downcase(record["type"]) == String.downcase(wanted)

            "resourceGroup" ->
              rg_from_resource_id(id) == String.downcase(wanted)

            "name" ->
              is_binary(record["name"]) and record["name"] == wanted

            "location" ->
              is_binary(record["location"]) and
                String.downcase(record["location"]) == String.downcase(wanted)

            _ ->
              false
          end
        end)
    end
  end

  defp subscription_resource_filter(_conn, _record), do: false

  # AZURE-FIDELITY lane 1: documented $expand semantics for list operations
  # (Resources - List, ResourceGroups - List): `$expand=createdTime,changedTime`
  # projects the resource lifecycle timestamps onto each item; the fields are
  # ABSENT unless requested (real ARM omits them by default). Rows are read
  # from ProviderState (frozen createdTime / advancing changedTime per write).
  defp apply_lifecycle_expand(items, conn) when is_list(items) do
    requested =
      case conn.query_params["$expand"] do
        value when is_binary(value) ->
          value
          |> String.split(",")
          |> Enum.map(&String.trim(&1))
          |> MapSet.new()

        _ ->
          MapSet.new()
      end

    want_created = MapSet.member?(requested, "createdTime")
    want_changed = MapSet.member?(requested, "changedTime")

    if want_created or want_changed do
      Enum.map(items, fn item ->
        if is_map(item) and is_binary(item["id"]) do
          times = ProviderState.lifecycle(item["id"])

          item =
            if want_created and is_binary(times["createdTime"]),
              do: Map.put(item, "createdTime", times["createdTime"]),
              else: item

          if want_changed and is_binary(times["changedTime"]),
            do: Map.put(item, "changedTime", times["changedTime"]),
            else: item
        else
          item
        end
      end)
    else
      items
    end
  end

  defp apply_lifecycle_expand(items, _conn), do: items

  # Split `a eq 'x' and b eq 'y'` into [{a, x}, {y}...]. Not a full ARM filter
  # grammar — eq/and only, quoted single-word-or-quoted values.
  defp parse_filter_clauses(filter) do
    filter
    |> String.split(" and ")
    |> Enum.flat_map(fn clause ->
      case String.split(String.trim(clause), " eq ") do
        [field, value] ->
          [{String.trim(field), strip_quotes(String.trim(value))}]

        _ ->
          # Unparseable clause: clause set that can never match.
          [{"__unmatched__", ""}]
      end
    end)
  end

  defp strip_quotes(value) do
    first = String.first(value)
    last = String.last(value)

    if byte_size(value) >= 2 and first == last and first in ["'", "\""] do
      binary_part(value, 1, byte_size(value) - 2)
    else
      value
    end
  end

  defp rg_from_resource_id(id) do
    case Regex.run(~r{/resourcegroups?/([^/]+)}i, id) do
      [_, rg] -> String.downcase(rg)
      _ -> nil
    end
  end

  # -- Child-resource routes (declared BEFORE generic provider routes) ----------

  # Microsoft.Network/virtualNetworks/:vnet/subnets (registry type: Microsoft.Network/subnets)
  put "/subscriptions/:sub_id/resourceGroups/:rg_name/providers/Microsoft.Network/virtualNetworks/:parent/subnets/:name" do
    handle_child_put(
      conn,
      "Microsoft.Network/subnets",
      sub_id,
      rg_name,
      "virtualNetworks/#{parent}/subnets/#{name}"
    )
  end

  get "/subscriptions/:sub_id/resourceGroups/:rg_name/providers/Microsoft.Network/virtualNetworks/:parent/subnets/:name" do
    handle_child_get(
      conn,
      "Microsoft.Network/subnets",
      sub_id,
      rg_name,
      "virtualNetworks/#{parent}/subnets/#{name}"
    )
  end

  get "/subscriptions/:sub_id/resourceGroups/:rg_name/providers/Microsoft.Network/virtualNetworks/:parent/subnets" do
    handle_child_list(
      conn,
      "Microsoft.Network/subnets",
      sub_id,
      rg_name,
      "virtualNetworks/#{parent}/subnets"
    )
  end

  delete "/subscriptions/:sub_id/resourceGroups/:rg_name/providers/Microsoft.Network/virtualNetworks/:parent/subnets/:name" do
    handle_child_delete(
      conn,
      "Microsoft.Network/subnets",
      sub_id,
      rg_name,
      "virtualNetworks/#{parent}/subnets/#{name}"
    )
  end

  # Microsoft.KeyVault/vaults/:vault/keys
  put "/subscriptions/:sub_id/resourceGroups/:rg_name/providers/Microsoft.KeyVault/vaults/:parent/keys/:name" do
    handle_child_put(
      conn,
      "Microsoft.KeyVault/vaults/keys",
      sub_id,
      rg_name,
      "vaults/#{parent}/keys/#{name}"
    )
  end

  get "/subscriptions/:sub_id/resourceGroups/:rg_name/providers/Microsoft.KeyVault/vaults/:parent/keys/:name" do
    handle_child_get(
      conn,
      "Microsoft.KeyVault/vaults/keys",
      sub_id,
      rg_name,
      "vaults/#{parent}/keys/#{name}"
    )
  end

  get "/subscriptions/:sub_id/resourceGroups/:rg_name/providers/Microsoft.KeyVault/vaults/:parent/keys" do
    handle_child_list(
      conn,
      "Microsoft.KeyVault/vaults/keys",
      sub_id,
      rg_name,
      "vaults/#{parent}/keys"
    )
  end

  delete "/subscriptions/:sub_id/resourceGroups/:rg_name/providers/Microsoft.KeyVault/vaults/:parent/keys/:name" do
    handle_child_delete(
      conn,
      "Microsoft.KeyVault/vaults/keys",
      sub_id,
      rg_name,
      "vaults/#{parent}/keys/#{name}"
    )
  end

  # KD-COVERS: KD-82
  # KD-T5-F4: synthesized singleton storage service child (real-ARM
  # FileService/QueueService/TableService default shapes). Auto-provisioned
  # by real Azure with every account; present once the parent account
  # exists in the store, else 404 ResourceNotFound (deny-by-default).
  defp storage_service_default_get(conn, service, sub_id, rg_name, acct) do
    with :ok <- check_api_version(conn, "Microsoft.Storage/storageAccounts/#{service}") do
      parent_id =
        "/subscriptions/#{sub_id}/resourceGroups/#{rg_name}/providers/Microsoft.Storage/storageAccounts/#{acct}"

      case Store.get(:smalt_resources, String.downcase(parent_id)) do
        {:ok, _} ->
          body = %{
            "id" => "#{parent_id}/#{service}/default",
            "name" => "default",
            "type" => "Microsoft.Storage/storageAccounts/#{service}",
            "properties" => service_default_properties(service)
          }

          send_json(conn, 200, Jason.encode!(body))

        :error ->
          send_arm_error(
            conn,
            404,
            "ResourceNotFound",
            "The storage account '#{acct}' was not found.",
            parent_id
          )
      end
    else
      {:respond, conn} -> conn
    end
  end

  defp service_default_properties("fileServices"),
    do: %{
      "protocolSettings" => %{"smb" => %{}},
      "shareDeleteRetentionPolicy" => %{"enabled" => true, "days" => 5}
    }

  defp service_default_properties("queueServices"),
    do: %{"queueProperties" => %{"cors" => []}}

  defp service_default_properties("tableServices"),
    do: %{"tableProperties" => %{"cors" => []}}

  defp service_default_properties(_), do: %{}

  # -- FR-5 TF-divergence closures (azurerm 4.54 wire evidence, 2026-10-16) ------
  # networkRuleSets/default GET + authorizationRules listKeys POST for
  # ServiceBus/EventHub namespaces; storageAccounts listKeys POST.

  defp handle_network_rule_set_get(conn, sub_id, rg_name, provider_ns, parent) do
    base =
      "/subscriptions/#{sub_id}/resourceGroups/#{rg_name}/providers/#{provider_ns}/namespaces/#{parent}"

    parent_key = String.downcase(base)

    case Store.get(:smalt_resources, parent_key) do
      {:ok, _} ->
        send_json(
          conn,
          200,
          Jason.encode!(%{
            "id" => "#{base}/networkRuleSets/default",
            "name" => "default",
            "type" => "#{provider_ns}/namespaces/networkRuleSets",
            "properties" => %{
              "defaultAction" => "Allow",
              "publicNetworkAccess" => "Enabled",
              "ipRules" => [],
              "virtualNetworkRules" => []
            }
          })
        )

      :error ->
        send_arm_error(conn, 404, "ResourceNotFound", "The parent #{parent} could not be found.")
    end
  end

  defp handle_authorization_rule_list_keys(conn, sub_id, rg_name, provider_ns, parent, rule) do
    base =
      "/subscriptions/#{sub_id}/resourceGroups/#{rg_name}/providers/#{provider_ns}/namespaces/#{parent}"

    parent_key = String.downcase(base)

    case Store.get(:smalt_resources, parent_key) do
      {:ok, _} ->
        primary = Base.encode64(:crypto.hash(:sha256, "#{provider_ns}/#{parent}/#{rule}/primary"))

        secondary =
          Base.encode64(:crypto.hash(:sha256, "#{provider_ns}/#{parent}/#{rule}/secondary"))

        endpoint = "https://#{parent}.servicebus.smalt.local:443/"

        send_json(
          conn,
          200,
          Jason.encode!(%{
            "keyName" => rule,
            "primaryKey" => primary,
            "secondaryKey" => secondary,
            "primaryConnectionString" =>
              "Endpoint=#{endpoint};SharedAccessKeyName=#{rule};SharedAccessKey=#{primary}",
            "secondaryConnectionString" =>
              "Endpoint=#{endpoint};SharedAccessKeyName=#{rule};SharedAccessKey=#{secondary}"
          })
        )

      :error ->
        send_arm_error(conn, 404, "ResourceNotFound", "The parent #{parent} could not be found.")
    end
  end

  defp handle_storage_list_keys(conn, sub_id, rg_name, parent) do
    base =
      "/subscriptions/#{sub_id}/resourceGroups/#{rg_name}/providers/Microsoft.Storage/storageAccounts/#{parent}"

    parent_key = String.downcase(base)

    case Store.get(:smalt_resources, parent_key) do
      {:ok, _} ->
        key1 = Base.encode64(:crypto.hash(:sha256, "storage/#{parent}/key1"))
        key2 = Base.encode64(:crypto.hash(:sha256, "storage/#{parent}/key2"))

        send_json(
          conn,
          200,
          Jason.encode!(%{
            "keys" => [
              %{"keyName" => "key1", "value" => key1, "permissions" => "FULL"},
              %{"keyName" => "key2", "value" => key2, "permissions" => "FULL"}
            ],
            "storageAccountName" => parent
          })
        )

      :error ->
        send_arm_error(conn, 404, "ResourceNotFound", "The parent #{parent} could not be found.")
    end
  end

  defp fr5_parent_exists?(sub_id, rg_name, providers_rel) do
    base = String.downcase("/subscriptions/#{sub_id}/resourceGroups/#{rg_name}/")

    match?({:ok, _}, Store.get(:smalt_resources, base <> String.downcase(providers_rel)))
  end

  get "/subscriptions/:sub_id/resourceGroups/:rg_name/providers/Microsoft.ServiceBus/namespaces/:parent/networkRuleSets/default" do
    if fr5_parent_exists?(sub_id, rg_name, "providers/Microsoft.ServiceBus/namespaces/#{parent}") do
      handle_network_rule_set_get(conn, sub_id, rg_name, "Microsoft.ServiceBus", parent)
    else
      send_arm_error(conn, 404, "ResourceNotFound", "The parent #{parent} could not be found.")
    end
  end

  get "/subscriptions/:sub_id/resourceGroups/:rg_name/providers/Microsoft.EventHub/namespaces/:parent/networkRuleSets/default" do
    if fr5_parent_exists?(sub_id, rg_name, "providers/Microsoft.EventHub/namespaces/#{parent}") do
      handle_network_rule_set_get(conn, sub_id, rg_name, "Microsoft.EventHub", parent)
    else
      send_arm_error(conn, 404, "ResourceNotFound", "The parent #{parent} could not be found.")
    end
  end

  post "/subscriptions/:sub_id/resourceGroups/:rg_name/providers/Microsoft.ServiceBus/namespaces/:parent/authorizationRules/:rule/listKeys" do
    if fr5_parent_exists?(sub_id, rg_name, "providers/Microsoft.ServiceBus/namespaces/#{parent}") do
      handle_authorization_rule_list_keys(
        conn,
        sub_id,
        rg_name,
        "Microsoft.ServiceBus",
        parent,
        rule
      )
    else
      send_arm_error(conn, 404, "ResourceNotFound", "The parent #{parent} could not be found.")
    end
  end

  post "/subscriptions/:sub_id/resourceGroups/:rg_name/providers/Microsoft.EventHub/namespaces/:parent/authorizationRules/:rule/listKeys" do
    if fr5_parent_exists?(sub_id, rg_name, "providers/Microsoft.EventHub/namespaces/#{parent}") do
      handle_authorization_rule_list_keys(
        conn,
        sub_id,
        rg_name,
        "Microsoft.EventHub",
        parent,
        rule
      )
    else
      send_arm_error(conn, 404, "ResourceNotFound", "The parent #{parent} could not be found.")
    end
  end

  post "/subscriptions/:sub_id/resourceGroups/:rg_name/providers/Microsoft.Storage/storageAccounts/:parent/listKeys" do
    if fr5_parent_exists?(
         sub_id,
         rg_name,
         "providers/Microsoft.Storage/storageAccounts/#{parent}"
       ) do
      handle_storage_list_keys(conn, sub_id, rg_name, parent)
    else
      send_arm_error(conn, 404, "ResourceNotFound", "The parent #{parent} could not be found.")
    end
  end

  # Microsoft.KeyVault/vaults/:vault/secrets (registry type:
  # Microsoft.KeyVault/vaults/secrets) — ARM control-plane children; the PUT
  # cross-plane seeds the data-plane /secrets store (:smalt_vault_secrets) so
  # an azurerm_key_vault_secret apply is visible on the 8443 data plane.
  put "/subscriptions/:sub_id/resourceGroups/:rg_name/providers/Microsoft.KeyVault/vaults/:parent/secrets/:name" do
    seed_data_plane_secret(conn, sub_id, rg_name, parent, name)

    handle_parented_child(
      conn,
      :put,
      "Microsoft.KeyVault/vaults/secrets",
      sub_id,
      rg_name,
      "vaults/#{parent}",
      "vaults/#{parent}/secrets/#{name}"
    )
  end

  get "/subscriptions/:sub_id/resourceGroups/:rg_name/providers/Microsoft.KeyVault/vaults/:parent/secrets/:name" do
    handle_parented_child(
      conn,
      :get,
      "Microsoft.KeyVault/vaults/secrets",
      sub_id,
      rg_name,
      "vaults/#{parent}",
      "vaults/#{parent}/secrets/#{name}"
    )
  end

  get "/subscriptions/:sub_id/resourceGroups/:rg_name/providers/Microsoft.KeyVault/vaults/:parent/secrets" do
    handle_parented_child(
      conn,
      :list,
      "Microsoft.KeyVault/vaults/secrets",
      sub_id,
      rg_name,
      "vaults/#{parent}",
      "vaults/#{parent}/secrets"
    )
  end

  delete "/subscriptions/:sub_id/resourceGroups/:rg_name/providers/Microsoft.KeyVault/vaults/:parent/secrets/:name" do
    handle_parented_child(
      conn,
      :delete,
      "Microsoft.KeyVault/vaults/secrets",
      sub_id,
      rg_name,
      "vaults/#{parent}",
      "vaults/#{parent}/secrets/#{name}"
    )
  end

  # Rotation trigger (v26.10.16 console C4 server-side half): azurerm / the
  # console POST .../secrets/:secret/rotate?api-version=... to bump a secret's
  # version WITHOUT a re-PUT. Must stay ABOVE the azapi POST glob routes
  # (handle_action 404s unknown actions). Fail-closed: unknown secret or absent
  # parent -> typed 404 ResourceNotFound; ARM record present but no data-plane
  # version to carry forward -> typed 409 SecretVersionNotFound.
  post "/subscriptions/:sub_id/resourceGroups/:rg_name/providers/Microsoft.KeyVault/vaults/:parent/secrets/:name/rotate" do
    rotate_vault_secret(conn, sub_id, rg_name, parent, name)
  end

  # Microsoft.Storage/storageAccounts/:acct/blobServices/default (singleton)
  put "/subscriptions/:sub_id/resourceGroups/:rg_name/providers/Microsoft.Storage/storageAccounts/:parent/blobServices/default" do
    handle_child_put(
      conn,
      "Microsoft.Storage/storageAccounts/blobServices",
      sub_id,
      rg_name,
      "storageAccounts/#{parent}/blobServices/default"
    )
  end

  get "/subscriptions/:sub_id/resourceGroups/:rg_name/providers/Microsoft.Storage/storageAccounts/:parent/blobServices/default" do
    # AZB-25 (KD-class divergence, witnessed by azurerm 4.54 apply): real ARM
    # auto-provisions the blobServices/default singleton with every storage
    # account; the azurerm storage create flow GETs it and 404-loops otherwise.
    # Synthesize the real-ARM default shape when the account exists (same
    # treatment as fileServices/default below).
    storage_service_default_get(conn, "blobServices", sub_id, rg_name, parent)
  end

  delete "/subscriptions/:sub_id/resourceGroups/:rg_name/providers/Microsoft.Storage/storageAccounts/:parent/blobServices/default" do
    handle_child_delete(
      conn,
      "Microsoft.Storage/storageAccounts/blobServices",
      sub_id,
      rg_name,
      "storageAccounts/#{parent}/blobServices/default"
    )
  end

  # KD-T5-F4: real Azure auto-provisions the singleton service children
  # (fileServices/default, queueServices/default, tableServices/default)
  # with every storage account; azurerm 4.54's storage create flow GETs
  # fileServices/default and loops forever on 404 (T5-adjacent wire
  # evidence, /tmp/t5verify-work/substrate.log). GET synthesizes the
  # real-ARM default shape when the account exists; PUT/DELETE for the
  # file service stay out of scope (not exercised by the azurerm flow).
  get "/subscriptions/:sub_id/resourceGroups/:rg_name/providers/Microsoft.Storage/storageAccounts/:parent/fileServices/default" do
    storage_service_default_get(conn, "fileServices", sub_id, rg_name, parent)
  end

  get "/subscriptions/:sub_id/resourceGroups/:rg_name/providers/Microsoft.Storage/storageAccounts/:parent/queueServices/default" do
    storage_service_default_get(conn, "queueServices", sub_id, rg_name, parent)
  end

  get "/subscriptions/:sub_id/resourceGroups/:rg_name/providers/Microsoft.Storage/storageAccounts/:parent/tableServices/default" do
    storage_service_default_get(conn, "tableServices", sub_id, rg_name, parent)
  end

  # .../blobServices/default/containers
  # KD-COVERS: KD-92 — an ARM-created container is immediately visible to the
  # blob data plane in real Azure. The child PUT mirrors the container record
  # into `:smalt_blob_containers` (same record shape do_create_container
  # writes) on a successful PUT; a data-plane blob PUT then answers 201,
  # never 404 ContainerNotFound. Mirror-only-when-absent keeps the ARM PUT
  # idempotent (200) and never clobbers a data-plane-created container's
  # WORM/immutability state; the data plane stays authoritative for policy.
  put "/subscriptions/:sub_id/resourceGroups/:rg_name/providers/Microsoft.Storage/storageAccounts/:parent/blobServices/default/containers/:name" do
    handle_storage_container_child_put(conn, sub_id, rg_name, parent, name)
  end

  get "/subscriptions/:sub_id/resourceGroups/:rg_name/providers/Microsoft.Storage/storageAccounts/:parent/blobServices/default/containers/:name" do
    handle_child_get(
      conn,
      "Microsoft.Storage/storageAccounts/blobServices/containers",
      sub_id,
      rg_name,
      "storageAccounts/#{parent}/blobServices/default/containers/#{name}"
    )
  end

  get "/subscriptions/:sub_id/resourceGroups/:rg_name/providers/Microsoft.Storage/storageAccounts/:parent/blobServices/default/containers" do
    handle_child_list(
      conn,
      "Microsoft.Storage/storageAccounts/blobServices/containers",
      sub_id,
      rg_name,
      "storageAccounts/#{parent}/blobServices/default/containers"
    )
  end

  delete "/subscriptions/:sub_id/resourceGroups/:rg_name/providers/Microsoft.Storage/storageAccounts/:parent/blobServices/default/containers/:name" do
    handle_child_delete(
      conn,
      "Microsoft.Storage/storageAccounts/blobServices/containers",
      sub_id,
      rg_name,
      "storageAccounts/#{parent}/blobServices/default/containers/#{name}"
    )
  end

  # .../containers/:name/immutabilityPolicies
  put "/subscriptions/:sub_id/resourceGroups/:rg_name/providers/Microsoft.Storage/storageAccounts/:parent/blobServices/default/containers/:container/immutabilityPolicies/:name" do
    handle_child_put(
      conn,
      "Microsoft.Storage/storageAccounts/blobServices/containers/immutabilityPolicies",
      sub_id,
      rg_name,
      "storageAccounts/#{parent}/blobServices/default/containers/#{container}/immutabilityPolicies/#{name}"
    )
  end

  get "/subscriptions/:sub_id/resourceGroups/:rg_name/providers/Microsoft.Storage/storageAccounts/:parent/blobServices/default/containers/:container/immutabilityPolicies/:name" do
    handle_child_get(
      conn,
      "Microsoft.Storage/storageAccounts/blobServices/containers/immutabilityPolicies",
      sub_id,
      rg_name,
      "storageAccounts/#{parent}/blobServices/default/containers/#{container}/immutabilityPolicies/#{name}"
    )
  end

  get "/subscriptions/:sub_id/resourceGroups/:rg_name/providers/Microsoft.Storage/storageAccounts/:parent/blobServices/default/containers/:container/immutabilityPolicies" do
    handle_child_list(
      conn,
      "Microsoft.Storage/storageAccounts/blobServices/containers/immutabilityPolicies",
      sub_id,
      rg_name,
      "storageAccounts/#{parent}/blobServices/default/containers/#{container}/immutabilityPolicies"
    )
  end

  delete "/subscriptions/:sub_id/resourceGroups/:rg_name/providers/Microsoft.Storage/storageAccounts/:parent/blobServices/default/containers/:container/immutabilityPolicies/:name" do
    handle_child_delete(
      conn,
      "Microsoft.Storage/storageAccounts/blobServices/containers/immutabilityPolicies",
      sub_id,
      rg_name,
      "storageAccounts/#{parent}/blobServices/default/containers/#{container}/immutabilityPolicies/#{name}"
    )
  end

  # Microsoft.ServiceBus/namespaces/:ns/queues (registry type: .../namespaces/queues)
  put "/subscriptions/:sub_id/resourceGroups/:rg_name/providers/Microsoft.ServiceBus/namespaces/:parent/queues/:name" do
    handle_parented_child(
      conn,
      :put,
      "Microsoft.ServiceBus/namespaces/queues",
      sub_id,
      rg_name,
      "namespaces/#{parent}",
      "namespaces/#{parent}/queues/#{name}"
    )
  end

  get "/subscriptions/:sub_id/resourceGroups/:rg_name/providers/Microsoft.ServiceBus/namespaces/:parent/queues/:name" do
    handle_parented_child(
      conn,
      :get,
      "Microsoft.ServiceBus/namespaces/queues",
      sub_id,
      rg_name,
      "namespaces/#{parent}",
      "namespaces/#{parent}/queues/#{name}"
    )
  end

  get "/subscriptions/:sub_id/resourceGroups/:rg_name/providers/Microsoft.ServiceBus/namespaces/:parent/queues" do
    handle_parented_child(
      conn,
      :list,
      "Microsoft.ServiceBus/namespaces/queues",
      sub_id,
      rg_name,
      "namespaces/#{parent}",
      "namespaces/#{parent}/queues"
    )
  end

  delete "/subscriptions/:sub_id/resourceGroups/:rg_name/providers/Microsoft.ServiceBus/namespaces/:parent/queues/:name" do
    handle_parented_child(
      conn,
      :delete,
      "Microsoft.ServiceBus/namespaces/queues",
      sub_id,
      rg_name,
      "namespaces/#{parent}",
      "namespaces/#{parent}/queues/#{name}"
    )
  end

  # .../namespaces/:ns/topics — SB-TOPICS lane: routes through the SB-aware
  # handler (defaults hydration + AMQP entity materialization) instead of the
  # generic messaging-child path. See handle_sb_child/8.
  # .../namespaces/:ns/topics — SB-TOPICS lane: SB-aware child handling
  # (defaults hydration + AMQP entity materialization on PUT, queue-store
  # entity teardown on DELETE) instead of the generic messaging-child path.
  # See handle_sb_child/7.
  put "/subscriptions/:sub_id/resourceGroups/:rg_name/providers/Microsoft.ServiceBus/namespaces/:parent/topics/:name" do
    handle_sb_child(
      conn,
      :put,
      "Microsoft.ServiceBus/namespaces/topics",
      sub_id,
      rg_name,
      "namespaces/#{parent}",
      "namespaces/#{parent}/topics/#{name}"
    )
  end

  get "/subscriptions/:sub_id/resourceGroups/:rg_name/providers/Microsoft.ServiceBus/namespaces/:parent/topics/:name" do
    handle_sb_child(
      conn,
      :get,
      "Microsoft.ServiceBus/namespaces/topics",
      sub_id,
      rg_name,
      "namespaces/#{parent}",
      "namespaces/#{parent}/topics/#{name}"
    )
  end

  get "/subscriptions/:sub_id/resourceGroups/:rg_name/providers/Microsoft.ServiceBus/namespaces/:parent/topics" do
    handle_sb_child(
      conn,
      :list,
      "Microsoft.ServiceBus/namespaces/topics",
      sub_id,
      rg_name,
      "namespaces/#{parent}",
      "namespaces/#{parent}/topics"
    )
  end

  delete "/subscriptions/:sub_id/resourceGroups/:rg_name/providers/Microsoft.ServiceBus/namespaces/:parent/topics/:name" do
    handle_sb_child(
      conn,
      :delete,
      "Microsoft.ServiceBus/namespaces/topics",
      sub_id,
      rg_name,
      "namespaces/#{parent}",
      "namespaces/#{parent}/topics/#{name}"
    )
  end

  # .../namespaces/:ns/topics/:t/subscriptions — SB-TOPICS lane (see above).
  put "/subscriptions/:sub_id/resourceGroups/:rg_name/providers/Microsoft.ServiceBus/namespaces/:parent/topics/:topic/subscriptions/:name" do
    handle_sb_child(
      conn,
      :put,
      "Microsoft.ServiceBus/namespaces/topics/subscriptions",
      sub_id,
      rg_name,
      "namespaces/#{parent}/topics/#{topic}",
      "namespaces/#{parent}/topics/#{topic}/subscriptions/#{name}"
    )
  end

  get "/subscriptions/:sub_id/resourceGroups/:rg_name/providers/Microsoft.ServiceBus/namespaces/:parent/topics/:topic/subscriptions/:name" do
    handle_sb_child(
      conn,
      :get,
      "Microsoft.ServiceBus/namespaces/topics/subscriptions",
      sub_id,
      rg_name,
      "namespaces/#{parent}/topics/#{topic}",
      "namespaces/#{parent}/topics/#{topic}/subscriptions/#{name}"
    )
  end

  get "/subscriptions/:sub_id/resourceGroups/:rg_name/providers/Microsoft.ServiceBus/namespaces/:parent/topics/:topic/subscriptions" do
    handle_sb_child(
      conn,
      :list,
      "Microsoft.ServiceBus/namespaces/topics/subscriptions",
      sub_id,
      rg_name,
      "namespaces/#{parent}/topics/#{topic}",
      "namespaces/#{parent}/topics/#{topic}/subscriptions"
    )
  end

  delete "/subscriptions/:sub_id/resourceGroups/:rg_name/providers/Microsoft.ServiceBus/namespaces/:parent/topics/:topic/subscriptions/:name" do
    handle_sb_child(
      conn,
      :delete,
      "Microsoft.ServiceBus/namespaces/topics/subscriptions",
      sub_id,
      rg_name,
      "namespaces/#{parent}/topics/#{topic}",
      "namespaces/#{parent}/topics/#{topic}/subscriptions/#{name}"
    )
  end

  # .../namespaces/:ns/topics/:t/subscriptions/:s/rules — 80/20 Service Bus
  # subscription rules (SB-RULES lane). Storage: :smalt_sb_rules keyed by
  # downcased full ARM id (no /providers/ segment, matching SB child
  # convention). $Default true-filter is synthesized on LIST when no user
  # rules exist (same pattern as EventHub consumer-group $default), so no
  # create-path hook is needed. Unsupported SQL filter/action constructs
  # refuse at rule-create time with typed 400 InvalidFilter/InvalidAction.
  put "/subscriptions/:sub_id/resourceGroups/:rg_name/providers/Microsoft.ServiceBus/namespaces/:ns/topics/:topic/subscriptions/:sub_name/rules/:rule_name" do
    handle_sb_rule(conn, :put, sub_id, rg_name, ns, topic, sub_name, rule_name)
  end

  get "/subscriptions/:sub_id/resourceGroups/:rg_name/providers/Microsoft.ServiceBus/namespaces/:ns/topics/:topic/subscriptions/:sub_name/rules/:rule_name" do
    handle_sb_rule(conn, :get, sub_id, rg_name, ns, topic, sub_name, rule_name)
  end

  delete "/subscriptions/:sub_id/resourceGroups/:rg_name/providers/Microsoft.ServiceBus/namespaces/:ns/topics/:topic/subscriptions/:sub_name/rules/:rule_name" do
    handle_sb_rule(conn, :delete, sub_id, rg_name, ns, topic, sub_name, rule_name)
  end

  get "/subscriptions/:sub_id/resourceGroups/:rg_name/providers/Microsoft.ServiceBus/namespaces/:ns/topics/:topic/subscriptions/:sub_name/rules" do
    handle_sb_rule(conn, :list, sub_id, rg_name, ns, topic, sub_name, nil)
  end

  # Microsoft.EventHub/namespaces/:ns/eventhubs
  put "/subscriptions/:sub_id/resourceGroups/:rg_name/providers/Microsoft.EventHub/namespaces/:parent/eventhubs/:name" do
    handle_parented_child(
      conn,
      :put,
      "Microsoft.EventHub/namespaces/eventhubs",
      sub_id,
      rg_name,
      "namespaces/#{parent}",
      "namespaces/#{parent}/eventhubs/#{name}"
    )
  end

  get "/subscriptions/:sub_id/resourceGroups/:rg_name/providers/Microsoft.EventHub/namespaces/:parent/eventhubs/:name" do
    handle_parented_child(
      conn,
      :get,
      "Microsoft.EventHub/namespaces/eventhubs",
      sub_id,
      rg_name,
      "namespaces/#{parent}",
      "namespaces/#{parent}/eventhubs/#{name}"
    )
  end

  get "/subscriptions/:sub_id/resourceGroups/:rg_name/providers/Microsoft.EventHub/namespaces/:parent/eventhubs" do
    handle_parented_child(
      conn,
      :list,
      "Microsoft.EventHub/namespaces/eventhubs",
      sub_id,
      rg_name,
      "namespaces/#{parent}",
      "namespaces/#{parent}/eventhubs"
    )
  end

  delete "/subscriptions/:sub_id/resourceGroups/:rg_name/providers/Microsoft.EventHub/namespaces/:parent/eventhubs/:name" do
    handle_parented_child(
      conn,
      :delete,
      "Microsoft.EventHub/namespaces/eventhubs",
      sub_id,
      rg_name,
      "namespaces/#{parent}",
      "namespaces/#{parent}/eventhubs/#{name}"
    )
  end

  # .../namespaces/:ns/eventhubs/:hub/consumergroups
  put "/subscriptions/:sub_id/resourceGroups/:rg_name/providers/Microsoft.EventHub/namespaces/:parent/eventhubs/:hub/consumergroups/:name" do
    handle_parented_child(
      conn,
      :put,
      "Microsoft.EventHub/namespaces/eventhubs/consumergroups",
      sub_id,
      rg_name,
      "namespaces/#{parent}/eventhubs/#{hub}",
      "namespaces/#{parent}/eventhubs/#{hub}/consumergroups/#{name}"
    )
  end

  get "/subscriptions/:sub_id/resourceGroups/:rg_name/providers/Microsoft.EventHub/namespaces/:parent/eventhubs/:hub/consumergroups/:name" do
    handle_parented_child(
      conn,
      :get,
      "Microsoft.EventHub/namespaces/eventhubs/consumergroups",
      sub_id,
      rg_name,
      "namespaces/#{parent}/eventhubs/#{hub}",
      "namespaces/#{parent}/eventhubs/#{hub}/consumergroups/#{name}"
    )
  end

  get "/subscriptions/:sub_id/resourceGroups/:rg_name/providers/Microsoft.EventHub/namespaces/:parent/eventhubs/:hub/consumergroups" do
    handle_parented_child(
      conn,
      :list_cg,
      "Microsoft.EventHub/namespaces/eventhubs/consumergroups",
      sub_id,
      rg_name,
      "namespaces/#{parent}/eventhubs/#{hub}",
      "namespaces/#{parent}/eventhubs/#{hub}/consumergroups"
    )
  end

  delete "/subscriptions/:sub_id/resourceGroups/:rg_name/providers/Microsoft.EventHub/namespaces/:parent/eventhubs/:hub/consumergroups/:name" do
    handle_parented_child(
      conn,
      :delete,
      "Microsoft.EventHub/namespaces/eventhubs/consumergroups",
      sub_id,
      rg_name,
      "namespaces/#{parent}/eventhubs/#{hub}",
      "namespaces/#{parent}/eventhubs/#{hub}/consumergroups/#{name}"
    )
  end

  # Microsoft.DocumentDB databaseAccounts children (registry types:
  # .../databaseAccounts/sqlDatabases, .../sqlContainers) — parented children
  # with DUAL-KEY parent lookup (the account PUT via the generic route stores
  # WITH the providers/ prefix; bare handle_child_put would 404 the parent).
  # The PUT rides handle_cosmos_child_put, which seeds the live Cosmos data
  # plane on 200/201 (see handle_cosmos_child_put/5).
  put "/subscriptions/:sub_id/resourceGroups/:rg_name/providers/Microsoft.DocumentDB/databaseAccounts/:parent/sqlDatabases/:name" do
    handle_parented_child(
      conn,
      :put,
      "Microsoft.DocumentDB/databaseAccounts/sqlDatabases",
      sub_id,
      rg_name,
      "databaseAccounts/#{parent}",
      "databaseAccounts/#{parent}/sqlDatabases/#{name}"
    )
  end

  get "/subscriptions/:sub_id/resourceGroups/:rg_name/providers/Microsoft.DocumentDB/databaseAccounts/:parent/sqlDatabases/:name" do
    handle_parented_child(
      conn,
      :get,
      "Microsoft.DocumentDB/databaseAccounts/sqlDatabases",
      sub_id,
      rg_name,
      "databaseAccounts/#{parent}",
      "databaseAccounts/#{parent}/sqlDatabases/#{name}"
    )
  end

  get "/subscriptions/:sub_id/resourceGroups/:rg_name/providers/Microsoft.DocumentDB/databaseAccounts/:parent/sqlDatabases" do
    handle_parented_child(
      conn,
      :list,
      "Microsoft.DocumentDB/databaseAccounts/sqlDatabases",
      sub_id,
      rg_name,
      "databaseAccounts/#{parent}",
      "databaseAccounts/#{parent}/sqlDatabases"
    )
  end

  delete "/subscriptions/:sub_id/resourceGroups/:rg_name/providers/Microsoft.DocumentDB/databaseAccounts/:parent/sqlDatabases/:name" do
    handle_parented_child(
      conn,
      :delete,
      "Microsoft.DocumentDB/databaseAccounts/sqlDatabases",
      sub_id,
      rg_name,
      "databaseAccounts/#{parent}",
      "databaseAccounts/#{parent}/sqlDatabases/#{name}"
    )
  end

  # .../databaseAccounts/:acct/sqlDatabases/:db/sqlContainers
  put "/subscriptions/:sub_id/resourceGroups/:rg_name/providers/Microsoft.DocumentDB/databaseAccounts/:parent/sqlDatabases/:db/sqlContainers/:name" do
    handle_parented_child(
      conn,
      :put,
      "Microsoft.DocumentDB/databaseAccounts/sqlContainers",
      sub_id,
      rg_name,
      "databaseAccounts/#{parent}/sqlDatabases/#{db}",
      "databaseAccounts/#{parent}/sqlDatabases/#{db}/sqlContainers/#{name}"
    )
  end

  get "/subscriptions/:sub_id/resourceGroups/:rg_name/providers/Microsoft.DocumentDB/databaseAccounts/:parent/sqlDatabases/:db/sqlContainers/:name" do
    handle_parented_child(
      conn,
      :get,
      "Microsoft.DocumentDB/databaseAccounts/sqlContainers",
      sub_id,
      rg_name,
      "databaseAccounts/#{parent}/sqlDatabases/#{db}",
      "databaseAccounts/#{parent}/sqlDatabases/#{db}/sqlContainers/#{name}"
    )
  end

  get "/subscriptions/:sub_id/resourceGroups/:rg_name/providers/Microsoft.DocumentDB/databaseAccounts/:parent/sqlDatabases/:db/sqlContainers" do
    handle_parented_child(
      conn,
      :list,
      "Microsoft.DocumentDB/databaseAccounts/sqlContainers",
      sub_id,
      rg_name,
      "databaseAccounts/#{parent}/sqlDatabases/#{db}",
      "databaseAccounts/#{parent}/sqlDatabases/#{db}/sqlContainers"
    )
  end

  delete "/subscriptions/:sub_id/resourceGroups/:rg_name/providers/Microsoft.DocumentDB/databaseAccounts/:parent/sqlDatabases/:db/sqlContainers/:name" do
    handle_parented_child(
      conn,
      :delete,
      "Microsoft.DocumentDB/databaseAccounts/sqlContainers",
      sub_id,
      rg_name,
      "databaseAccounts/#{parent}/sqlDatabases/#{db}",
      "databaseAccounts/#{parent}/sqlDatabases/#{db}/sqlContainers/#{name}"
    )
  end

  # Microsoft.Network/privateDnsZones/:zone/virtualNetworkLinks (registry type:
  # .../privateDnsZones/virtualNetworkLinks, latest 2018-09-01)
  put "/subscriptions/:sub_id/resourceGroups/:rg_name/providers/Microsoft.Network/privateDnsZones/:parent/virtualNetworkLinks/:name" do
    handle_parented_child(
      conn,
      :put,
      "Microsoft.Network/privateDnsZones/virtualNetworkLinks",
      sub_id,
      rg_name,
      "privateDnsZones/#{parent}",
      "privateDnsZones/#{parent}/virtualNetworkLinks/#{name}"
    )
  end

  get "/subscriptions/:sub_id/resourceGroups/:rg_name/providers/Microsoft.Network/privateDnsZones/:parent/virtualNetworkLinks/:name" do
    handle_parented_child(
      conn,
      :get,
      "Microsoft.Network/privateDnsZones/virtualNetworkLinks",
      sub_id,
      rg_name,
      "privateDnsZones/#{parent}",
      "privateDnsZones/#{parent}/virtualNetworkLinks/#{name}"
    )
  end

  get "/subscriptions/:sub_id/resourceGroups/:rg_name/providers/Microsoft.Network/privateDnsZones/:parent/virtualNetworkLinks" do
    handle_parented_child(
      conn,
      :list,
      "Microsoft.Network/privateDnsZones/virtualNetworkLinks",
      sub_id,
      rg_name,
      "privateDnsZones/#{parent}",
      "privateDnsZones/#{parent}/virtualNetworkLinks"
    )
  end

  delete "/subscriptions/:sub_id/resourceGroups/:rg_name/providers/Microsoft.Network/privateDnsZones/:parent/virtualNetworkLinks/:name" do
    handle_parented_child(
      conn,
      :delete,
      "Microsoft.Network/privateDnsZones/virtualNetworkLinks",
      sub_id,
      rg_name,
      "privateDnsZones/#{parent}",
      "privateDnsZones/#{parent}/virtualNetworkLinks/#{name}"
    )
  end

  # -- Azure Monitor metrics (microsoft.insights/metrics) ----------------------
  # Nested-provider form {resourceId}/providers/microsoft.insights/metrics —
  # the extra `providers` segment falls past the generic 3-segment routes, so
  # these must stay declared BEFORE the azapi glob routes (the POST glob
  # otherwise shadows the metrics emit). GET queries bucketed timeseries;
  # POST emits a custom metric point. Unknown resource answers real-Azure
  # semantics: 200 with an EMPTY value[] envelope.
  get "/subscriptions/:sub_id/resourceGroups/:rg_name/providers/:provider_ns/:resource_type/:resource_name/providers/microsoft.insights/metrics" do
    handle_metrics(conn, sub_id, rg_name, provider_ns, resource_type, resource_name)
  end

  post "/subscriptions/:sub_id/resourceGroups/:rg_name/providers/:provider_ns/:resource_type/:resource_name/providers/microsoft.insights/metrics" do
    handle_metrics_emit(conn, sub_id, rg_name, provider_ns, resource_type, resource_name)
  end

  # Platform pseudo-resource metric face (BK-PLATFORM-ROUTE, v26.10.22 —
  # BK-MON5 typed carry-forward PLATFORM-FACE-UNROUTED): the accumulator keys
  # non-ARM traffic and platform events (EgressRefused, SentinelDropped/
  # SentinelKept) under the 2-segment id `providers/Smalt.Monitor/platform`
  # (no name segment), which the 3-segment metrics route family above cannot
  # match — wire GETs answered 404 RouteNotFound while in-process series/5 on
  # the platform key was coherent. Real Azure Monitor exposes platform
  # metric faces (Microsoft.Monitor platform shape), so route it: the
  # literal 2-segment face at the platform's own scope serves the SAME
  # series/5 accumulator path (exact downcased-equality join, bkmon3r law).
  get "/subscriptions/_smalt_monitor/resourceGroups/_smalt_monitor/providers/Smalt.Monitor/platform/providers/microsoft.insights/metrics" do
    handle_metrics_platform(conn)
  end

  @pr_type "Microsoft.Authorization/policyRemediations"

  # NOTE: the RG-scope trigger POST is declared early (before the azapi POST
  # glob routes) — Plug builds route order from declaration order and the
  # `post .../resourceGroups/:rg_name/providers/*glob` action route otherwise
  # shadows it. See the policyRemediations block near the policyExemptions
  # block for the rest of the family.
  post "/subscriptions/:sub_id/resourceGroups/:rg_name/providers/Microsoft.Authorization/policyRemediations/:name/trigger" do
    with :ok <- check_api_version(conn, @pr_type) do
      scope = "/subscriptions/#{sub_id}/resourceGroups/#{rg_name}"

      case Policy.trigger_policy_remediation(scope, name) do
        {:ok, record} ->
          send_json(conn, 200, Jason.encode!(record))

        :error ->
          send_arm_error(
            conn,
            404,
            "ResourceNotFound",
            "The policy remediation '#{name}' was not found."
          )
      end
    else
      {:respond, conn} -> conn
    end
  end

  # -- ARM deployments routes (wave-6 lane w6i-2) ---------------------------------

  put "/subscriptions/:sub_id/resourcegroups/:rg_name/providers/Microsoft.Resources/deployments/:dep_name" do
    deployments_put(
      conn,
      conn.path_params["sub_id"],
      conn.path_params["rg_name"],
      conn.path_params["dep_name"]
    )
  end

  put "/subscriptions/:sub_id/resourceGroups/:rg_name/providers/Microsoft.Resources/deployments/:dep_name" do
    deployments_put(
      conn,
      conn.path_params["sub_id"],
      conn.path_params["rg_name"],
      conn.path_params["dep_name"]
    )
  end

  put "/subscriptions/:sub_id/providers/Microsoft.Resources/deployments/:dep_name" do
    deployments_put(conn, conn.path_params["sub_id"], nil, conn.path_params["dep_name"])
  end

  get "/subscriptions/:sub_id/resourcegroups/:rg_name/providers/Microsoft.Resources/deployments/:dep_name" do
    deployments_get(
      conn,
      conn.path_params["sub_id"],
      conn.path_params["rg_name"],
      conn.path_params["dep_name"]
    )
  end

  get "/subscriptions/:sub_id/resourceGroups/:rg_name/providers/Microsoft.Resources/deployments/:dep_name" do
    deployments_get(
      conn,
      conn.path_params["sub_id"],
      conn.path_params["rg_name"],
      conn.path_params["dep_name"]
    )
  end

  get "/subscriptions/:sub_id/providers/Microsoft.Resources/deployments/:dep_name" do
    deployments_get(conn, conn.path_params["sub_id"], nil, conn.path_params["dep_name"])
  end

  get "/subscriptions/:sub_id/providers/Microsoft.Resources/deployments" do
    deployments_list(conn, conn.path_params["sub_id"], nil)
  end

  get "/subscriptions/:sub_id/resourcegroups/:rg_name/providers/Microsoft.Resources/deployments" do
    deployments_list(conn, conn.path_params["sub_id"], conn.path_params["rg_name"])
  end

  get "/subscriptions/:sub_id/resourceGroups/:rg_name/providers/Microsoft.Resources/deployments" do
    deployments_list(conn, conn.path_params["sub_id"], conn.path_params["rg_name"])
  end

  delete "/subscriptions/:sub_id/resourcegroups/:rg_name/providers/Microsoft.Resources/deployments/:dep_name" do
    deployments_delete(
      conn,
      conn.path_params["sub_id"],
      conn.path_params["rg_name"],
      conn.path_params["dep_name"]
    )
  end

  delete "/subscriptions/:sub_id/resourceGroups/:rg_name/providers/Microsoft.Resources/deployments/:dep_name" do
    deployments_delete(
      conn,
      conn.path_params["sub_id"],
      conn.path_params["rg_name"],
      conn.path_params["dep_name"]
    )
  end

  delete "/subscriptions/:sub_id/providers/Microsoft.Resources/deployments/:dep_name" do
    deployments_delete(conn, conn.path_params["sub_id"], nil, conn.path_params["dep_name"])
  end

  post "/subscriptions/:sub_id/resourcegroups/:rg_name/providers/Microsoft.Resources/deployments/:dep_name/validate" do
    deployments_validate(
      conn,
      conn.path_params["sub_id"],
      conn.path_params["rg_name"],
      conn.path_params["dep_name"]
    )
  end

  post "/subscriptions/:sub_id/resourceGroups/:rg_name/providers/Microsoft.Resources/deployments/:dep_name/validate" do
    deployments_validate(
      conn,
      conn.path_params["sub_id"],
      conn.path_params["rg_name"],
      conn.path_params["dep_name"]
    )
  end

  post "/subscriptions/:sub_id/providers/Microsoft.Resources/deployments/:dep_name/validate" do
    deployments_validate(conn, conn.path_params["sub_id"], nil, conn.path_params["dep_name"])
  end

  # -- AZURE-FIDELITY gap closure (G1): deployment what-if ---------------------
  # POST .../deployments/{name}/what-if: diff the body's template.resources
  # against the LIVE :smalt_resources store (Smalt.Arm.Deployments.what_if/3,
  # wave-6 lane w6aq logic) WITHOUT materializing anything. Wire shape per the
  # documented contract: 200 {properties: {changes: [{resourceId, changeType,
  # before, after, delta}], status}} + a Location header on the deployment.
  post "/subscriptions/:sub_id/resourcegroups/:rg_name/providers/Microsoft.Resources/deployments/:dep_name/what-if" do
    deployments_what_if(
      conn,
      conn.path_params["sub_id"],
      conn.path_params["rg_name"],
      conn.path_params["dep_name"]
    )
  end

  post "/subscriptions/:sub_id/resourceGroups/:rg_name/providers/Microsoft.Resources/deployments/:dep_name/what-if" do
    deployments_what_if(
      conn,
      conn.path_params["sub_id"],
      conn.path_params["rg_name"],
      conn.path_params["dep_name"]
    )
  end

  post "/subscriptions/:sub_id/providers/Microsoft.Resources/deployments/:dep_name/what-if" do
    deployments_what_if(conn, conn.path_params["sub_id"], nil, conn.path_params["dep_name"])
  end

  get "/subscriptions/:sub_id/resourcegroups/:rg_name/providers/Microsoft.Resources/deployments/:dep_name/operations" do
    deployments_ops(
      conn,
      conn.path_params["sub_id"],
      conn.path_params["rg_name"],
      conn.path_params["dep_name"]
    )
  end

  get "/subscriptions/:sub_id/resourceGroups/:rg_name/providers/Microsoft.Resources/deployments/:dep_name/operations" do
    deployments_ops(
      conn,
      conn.path_params["sub_id"],
      conn.path_params["rg_name"],
      conn.path_params["dep_name"]
    )
  end

  get "/subscriptions/:sub_id/providers/Microsoft.Resources/deployments/:dep_name/operations" do
    deployments_ops(conn, conn.path_params["sub_id"], nil, conn.path_params["dep_name"])
  end

  # -- azapi POST actions (.../lock, .../setLegalHold) at any depth -------------
  post "/subscriptions/:sub_id/resourcegroups/:rg_name/providers/*glob" do
    handle_action(conn, glob)
  end

  post "/subscriptions/:sub_id/resourceGroups/:rg_name/providers/*glob" do
    handle_action(conn, glob)
  end

  # ===========================================================================
  # Microsoft.EventGrid topics + systemTopics (80/20 ARM control plane)
  # ===========================================================================
  # Dedicated routes for `Microsoft.EventGrid/topics` and
  # `Microsoft.EventGrid/systemTopics`. Records live in the dedicated
  # `:smalt_eg_topics` Store table (NOT :smalt_resources, so the ETS-identity
  # baseline test is unaffected); every ARM topic row carries
  # {name, location, endpoint (loopback ingest URL), inputSchema
  # (CloudEvents | EventGrid)}. The declared inputSchema gates the 8443 ingest
  # (`POST /topics/:name/events`): topics declared "EventGrid" accept the EG1
  # envelope; everything else keeps CloudEvents 1.0-only admission (the EG1
  # refusal stays the default). Binary-keyed event rows share the table under
  # the "eg events:<topic>:" prefix (binaries starting with "eg events:" sort
  # before "/subscriptions..." record keys); a per-topic name index uses a
  # tuple key (tuples sort before all binaries, so prefix scans never see it).
  put "/subscriptions/:sub_id/resourceGroups/:rg_name/providers/Microsoft.EventGrid/topics/:name" do
    eg_topic_put(conn, "topics", sub_id, rg_name, name)
  end

  get "/subscriptions/:sub_id/resourceGroups/:rg_name/providers/Microsoft.EventGrid/topics/:name" do
    eg_topic_get(conn, sub_id, rg_name, "topics", name)
  end

  get "/subscriptions/:sub_id/resourceGroups/:rg_name/providers/Microsoft.EventGrid/topics" do
    eg_topic_list(conn, sub_id, rg_name, "topics")
  end

  delete "/subscriptions/:sub_id/resourceGroups/:rg_name/providers/Microsoft.EventGrid/topics/:name" do
    eg_topic_delete(conn, sub_id, rg_name, name)
  end

  put "/subscriptions/:sub_id/resourceGroups/:rg_name/providers/Microsoft.EventGrid/systemTopics/:name" do
    eg_topic_put(conn, "systemTopics", sub_id, rg_name, name)
  end

  get "/subscriptions/:sub_id/resourceGroups/:rg_name/providers/Microsoft.EventGrid/systemTopics/:name" do
    eg_topic_get(conn, sub_id, rg_name, "systemTopics", name)
  end

  get "/subscriptions/:sub_id/resourceGroups/:rg_name/providers/Microsoft.EventGrid/systemTopics" do
    eg_topic_list(conn, sub_id, rg_name, "systemTopics")
  end

  delete "/subscriptions/:sub_id/resourceGroups/:rg_name/providers/Microsoft.EventGrid/systemTopics/:name" do
    eg_topic_delete(conn, sub_id, rg_name, name)
  end

  # -- systemTopics/{name}/eventSubscriptions (KD-101 in-proc face) -------------
  # Child routes for event subscriptions on a system topic. The in-proc face
  # is real (records + delivery through the registered webhook-receiver
  # subscribers); webhook PUSH to a remote endpoint is forbidden by the
  # air-gap law and answers a typed 400 (KD-101 divergence stays registered).
  put "/subscriptions/:sub_id/resourceGroups/:rg_name/providers/Microsoft.EventGrid/systemTopics/:name/eventSubscriptions/:es_name" do
    eg_es_put(conn, sub_id, rg_name, name, es_name)
  end

  get "/subscriptions/:sub_id/resourceGroups/:rg_name/providers/Microsoft.EventGrid/systemTopics/:name/eventSubscriptions/:es_name" do
    eg_es_get(conn, sub_id, rg_name, name, es_name)
  end

  get "/subscriptions/:sub_id/resourceGroups/:rg_name/providers/Microsoft.EventGrid/systemTopics/:name/eventSubscriptions" do
    eg_es_list(conn, sub_id, rg_name, name)
  end

  delete "/subscriptions/:sub_id/resourceGroups/:rg_name/providers/Microsoft.EventGrid/systemTopics/:name/eventSubscriptions/:es_name" do
    eg_es_delete(conn, sub_id, rg_name, name, es_name)
  end

  @eg_es_table :smalt_eg_topics
  @eg_es_prefix "eg es:"

  defp eg_es_key(sub_id, rg_name, topic, es_name) do
    String.downcase(
      "#{@eg_es_prefix}/subscriptions/#{sub_id}/resourceGroups/#{rg_name}/providers/Microsoft.EventGrid/systemTopics/#{topic}/eventSubscriptions/#{es_name}"
    )
  end

  defp eg_es_put(conn, sub_id, rg_name, topic, es_name) do
    with :ok <- check_api_version(conn, "Microsoft.EventGrid/systemTopics"),
         {:ok, _topic_record} <- eg_es_parent(conn, sub_id, rg_name, topic),
         {:ok, destination} <- eg_es_destination(conn, es_name) do
      topic_id =
        eg_res_id(sub_id, rg_name, "systemTopics", topic)

      es_id =
        "/subscriptions/#{sub_id}/resourceGroups/#{rg_name}/providers/Microsoft.EventGrid/systemTopics/#{topic}/eventSubscriptions/#{es_name}"

      key = eg_es_key(sub_id, rg_name, topic, es_name)
      existed? = match?({:ok, _}, Store.get(@eg_es_table, key))

      record = %{
        "id" => es_id,
        "name" => es_name,
        "type" => "Microsoft.EventGrid/systemTopics/eventSubscriptions",
        "properties" => %{
          "topic" => topic_id,
          "provisioningState" => "Succeeded",
          "destination" => destination,
          "eventDeliverySchema" => "CloudEventSchemaV1_0"
        },
        "tags" => normalize_tags(Map.get(conn.body_params, "tags")),
        "systemData" => @system_data
      }

      Store.put(@eg_es_table, key, record)
      send_json(conn, if(existed?, do: 200, else: 201), Jason.encode!(record))
    else
      {:respond, conn} -> conn
    end
  end

  # Destination gate: `destination.endpointType == "WebHook"` is admitted ONLY
  # when the endpoint URL is loopback (air-gap law); a loopback webhook is a
  # real deliverable push face (the delivery engine POSTs over real loopback
  # HTTP). Remote endpoints remain the KD-101 registered divergence — refused
  # typed. Non-WebHook/absent destinations keep the in-proc face admitted.
  defp eg_es_destination(conn, es_name) do
    props = conn.body_params["properties"] || %{}

    case props["destination"] do
      %{"endpointType" => "WebHook"} = dest ->
        case eg_es_webhook_loopback?(dest) do
          {:ok, url} ->
            dest =
              dest
              |> Map.put_new("properties", %{})
              |> put_in(["properties", "endpointUrl"], url)

            {:ok, dest}

          {:refuse, why} ->
            {:respond,
             send_arm_error(
               conn,
               400,
               if(why == :remote,
                 do: "EventGridWebhookPushUnsupported",
                 else: "InvalidResourceShape"
               ),
               if(why == :remote,
                 do:
                   "Webhook push delivery to remote endpoints is not supported by the loopback emulator (KD-101); use the in-proc webhook receiver face (/eventgrid/hooks/:subscriber) or a loopback https endpoint. Subscription '#{es_name}' was not created.",
                 else:
                   "properties.destination.properties.endpointUrl must be an https loopback URL (https://127.0.0.1, https://localhost, https://[::1]). Subscription '#{es_name}' was not created."
               )
             )}
        end

      %{"endpointType" => other} when is_binary(other) ->
        {:ok, %{"endpointType" => other}}

      %{"endpointType" => other} when is_binary(other) ->
        {:ok, %{"endpointType" => other}}

      %{} = dest ->
        {:ok, dest}

      nil ->
        {:ok, %{"endpointType" => "InProc"}}

      _other ->
        {:respond,
         send_arm_error(
           conn,
           400,
           "InvalidResourceShape",
           "properties.destination must be an object when present."
         )}
    end
  end

  @loopback_hosts MapSet.new(["127.0.0.1", "localhost", "::1", "[::1]"])

  # A WebHook destination is admitted only for loopback endpoint URLs
  # (https://127.0.0.1:..., https://localhost:..., https://[::1]:...).
  # Returns {:ok, url} | {:refuse, :remote | :shape}.
  defp eg_es_webhook_loopback?(%{"properties" => %{"endpointUrl" => url}} = _dest)
       when is_binary(url) do
    case URI.new(url) do
      {:ok, %URI{scheme: scheme, host: host}}
      when scheme in ["https", "http"] and is_binary(host) ->
        if MapSet.member?(@loopback_hosts, String.downcase(host)),
          do: {:ok, url},
          else: {:refuse, :remote}

      _ ->
        {:refuse, :shape}
    end
  end

  defp eg_es_webhook_loopback?(_dest), do: {:refuse, :shape}

  defp eg_es_parent(conn, sub_id, rg_name, topic) do
    case Store.get(
           @eg_es_table,
           String.downcase(eg_res_id(sub_id, rg_name, "systemTopics", topic))
         ) do
      {:ok, record} -> {:ok, record}
      :error -> {:respond, eg_topic_404(conn, topic)}
    end
  end

  defp eg_es_get(conn, sub_id, rg_name, topic, es_name) do
    with :ok <- check_api_version(conn, "Microsoft.EventGrid/systemTopics") do
      key = eg_es_key(sub_id, rg_name, topic, es_name)

      case Store.get(@eg_es_table, key) do
        {:ok, record} -> send_json(conn, 200, Jason.encode!(record))
        :error -> {:respond, eg_topic_404(conn, es_name)}
      end
    else
      {:respond, conn} -> conn
    end
  end

  defp eg_es_list(conn, sub_id, rg_name, topic) do
    with :ok <- check_api_version(conn, "Microsoft.EventGrid/systemTopics"),
         {:ok, _} <- eg_es_parent(conn, sub_id, rg_name, topic) do
      prefix =
        String.downcase(
          "#{@eg_es_prefix}#{eg_res_id(sub_id, rg_name, "systemTopics", topic)}/eventSubscriptions/"
        )

      send_list(conn, Store.list_prefix(@eg_es_table, prefix))
    else
      {:respond, conn} -> conn
    end
  end

  defp eg_es_delete(conn, sub_id, rg_name, topic, es_name) do
    with :ok <- check_api_version(conn, "Microsoft.EventGrid/systemTopics") do
      key = eg_es_key(sub_id, rg_name, topic, es_name)

      case Store.get(@eg_es_table, key) do
        {:ok, _} ->
          Store.delete(@eg_es_table, key)
          send_json(conn, 200, "")

        :error ->
          {:respond, eg_topic_404(conn, es_name)}
      end
    else
      {:respond, conn} -> conn
    end
  end

  defp eg_topic_404(conn, name) do
    send_arm_error(
      conn,
      404,
      "ResourceNotFound",
      "The Resource '#{name}' was not found."
    )
  end

  @eg_schemas ~w(CloudEvents EventGrid)

  defp eg_topic_put(conn, kind, sub_id, rg_name, name) do
    with :ok <- check_api_version(conn, "Microsoft.EventGrid/#{kind}"),
         # Refusal-tier law: shape gate BEFORE record build/hydration — a
         # malformed body answers 400 InvalidResourceShape, never a 201
         # admission with defaults papering over it (wire-tier refusal sweep).
         # Gated only for Registry-admitted kinds (topics); systemTopics is
         # not Registry-admitted and keeps its dedicated route semantics.
         merged = Defaults.apply("Microsoft.EventGrid/#{kind}", conn.body_params),
         :ok <- maybe_check_eg_shape(conn, kind, merged),
         {:ok, schema} <- eg_input_schema_param(conn) do
      res_id =
        "/subscriptions/#{sub_id}/resourceGroups/#{rg_name}/providers/Microsoft.EventGrid/#{kind}/#{name}"

      key = String.downcase(res_id)
      existed? = match?({:ok, _}, Store.get(:smalt_eg_topics, key))

      base_props = %{
        "provisioningState" => "Succeeded",
        "inputSchema" => schema,
        "endpoint" =>
          "http://localhost:#{Application.get_env(:smalt, :egress_port, 8443)}/topics/#{name}/events"
      }

      # systemTopics carry the ARM identity face real Event Grid echoes: the
      # `source` (the ARM resource id events flow FROM) and the `topicType`
      # (e.g. "Microsoft.EventGrid.Topics"). Both are pass-through echoes of
      # the PUT body's properties (real ARM semantics), absent when the body
      # omits them.
      base_props =
        if kind == "systemTopics" do
          body_props = conn.body_params["properties"] || %{}

          base_props
          |> eg_put_if_present("source", body_props["source"])
          |> eg_put_if_present("topicType", body_props["topicType"])
        else
          base_props
        end

      record = %{
        "id" => res_id,
        "name" => name,
        "type" => "Microsoft.EventGrid/#{kind}",
        "location" => Map.get(conn.body_params, "location", "eastus"),
        "properties" => base_props,
        "tags" => normalize_tags(Map.get(conn.body_params, "tags")),
        "systemData" => @system_data
      }

      Store.put(:smalt_eg_topics, key, record)
      Store.put(:smalt_eg_topics, {:eg_topic_name, String.downcase(name)}, key)

      send_json(conn, if(existed?, do: 200, else: 201), Jason.encode!(record))
    else
      {:respond, conn} -> conn
    end
  end

  # inputSchema is optional (default CloudEvents — the EG1-refusal default for
  # un-schema'd topics); a present-but-invalid value is a typed 400.
  # Shape gate for EventGrid topic PUTs, Registry-admission-gated: topics is
  # admitted (DefaultShape — location required) and must refuse malformed
  # bodies 400 InvalidResourceShape BEFORE hydration/record build; systemTopics
  # is not Registry-admitted and keeps its dedicated-route semantics.
  defp maybe_check_eg_shape(conn, kind, merged) do
    full_type = "Microsoft.EventGrid/#{kind}"

    if Smalt.Registry.admitted?(full_type) do
      with :ok <- check_shape(conn, full_type, merged),
           :ok <- check_properties_member(conn, merged) do
        :ok
      else
        {:respond, conn} -> {:respond, conn}
      end
    else
      :ok
    end
  end

  defp eg_input_schema_param(conn) do
    props = conn.body_params["properties"] || %{}

    schema =
      case props["inputSchema"] || conn.body_params["inputSchema"] do
        nil -> "CloudEvents"
        s when is_binary(s) -> s
        _ -> :invalid
      end

    if schema in @eg_schemas do
      {:ok, schema}
    else
      {:respond,
       send_arm_error(
         conn,
         400,
         "InvalidResourceShape",
         "properties.inputSchema must be one of: CloudEvents, EventGrid."
       )}
    end
  end

  defp eg_topic_get(conn, sub_id, rg_name, kind, name) do
    with :ok <- check_api_version(conn, "Microsoft.EventGrid/#{kind}") do
      key = String.downcase(eg_res_id(sub_id, rg_name, kind, name))

      case Store.get(:smalt_eg_topics, key) do
        {:ok, record} ->
          if renderable_record?(record) do
            send_json(conn, 200, Jason.encode!(record))
          else
            send_arm_error(
              conn,
              404,
              "ResourceNotFound",
              "The Resource '#{name}' was not found.",
              key
            )
          end

        :error ->
          send_arm_error(
            conn,
            404,
            "ResourceNotFound",
            "The Resource '#{name}' was not found.",
            key
          )
      end
    else
      {:respond, conn} -> conn
    end
  end

  defp eg_topic_list(conn, sub_id, rg_name, kind) do
    with :ok <- check_api_version(conn, "Microsoft.EventGrid/#{kind}") do
      prefix =
        String.downcase(
          "/subscriptions/#{sub_id}/resourceGroups/#{rg_name}/providers/Microsoft.EventGrid/#{kind}/"
        )

      send_list(conn, Store.list_prefix(:smalt_eg_topics, prefix))
    else
      {:respond, conn} -> conn
    end
  end

  defp eg_topic_delete(conn, sub_id, rg_name, name) do
    with :ok <- check_api_version(conn, "Microsoft.EventGrid/topics") do
      dn_name = String.downcase(name)

      Enum.each(["topics", "systemTopics"], fn kind ->
        key = String.downcase(eg_res_id(sub_id, rg_name, kind, name))

        case Store.get(:smalt_eg_topics, key) do
          {:ok, _} ->
            Store.delete(:smalt_eg_topics, key)
            Store.delete(:smalt_eg_topics, {:eg_topic_name, dn_name})

          :error ->
            :ok
        end
      end)

      # Cascade: sweep the topic's stored ingest events ("eg events:<topic>:"
      # keys) so a deleted topic never leaves readback rows behind.
      :smalt_eg_topics
      |> Store.list_prefix("eg events:#{dn_name}:")
      |> Enum.each(fn event ->
        Store.delete(:smalt_eg_topics, "eg events:#{dn_name}:#{event["seq"]}")
      end)

      # Cascade: sweep the topic's child event subscriptions ("eg es:" keys).
      eg_es_cascade_delete(sub_id, rg_name, name)

      send_json(conn, 200, "")
    else
      {:respond, conn} -> conn
    end
  end

  defp eg_res_id(sub_id, rg_name, kind, name) do
    "/subscriptions/#{sub_id}/resourceGroups/#{rg_name}/providers/Microsoft.EventGrid/#{kind}/#{name}"
  end

  defp eg_put_if_present(props, _key, nil), do: props
  defp eg_put_if_present(props, key, value), do: Map.put(props, key, value)

  # Cascade: deleting a system topic sweeps its child event-subscription
  # records ("eg es:" keys, lowercased ids), so no orphaned subscription
  # survives its parent.
  defp eg_es_cascade_delete(sub_id, rg_name, name) do
    prefix =
      String.downcase(
        "#{@eg_es_prefix}#{eg_res_id(sub_id, rg_name, "systemTopics", name)}/eventSubscriptions/"
      )

    :smalt_eg_topics
    |> Store.list_prefix(prefix)
    |> Enum.each(fn es ->
      key = "#{@eg_es_prefix}#{String.downcase(es["id"])}"
      Store.delete(:smalt_eg_topics, key)
    end)
  end

  # ---------------------------------------------------------------------------
  # EG1 (native Event Grid schema) ingest support — called from the 8443
  # EgressRouter. Public: the ingest surface reads the declared inputSchema and
  # publishes/reads back EG1 events through these three functions only.
  # ---------------------------------------------------------------------------

  @doc """
  Returns the inputSchema declared for `topic` ("CloudEvents" | "EventGrid"),
  or nil when no ARM topic record exists (un-declared topics keep the
  CloudEvents-only default, i.e. the EG1 refusal).
  """
  def eg_topic_input_schema(topic) do
    case Store.get(:smalt_eg_topics, {:eg_topic_name, String.downcase(topic)}) do
      {:ok, key} when is_binary(key) ->
        case Store.get(:smalt_eg_topics, key) do
          {:ok, %{"properties" => %{"inputSchema" => schema}}} when is_binary(schema) -> schema
          _ -> nil
        end

      _ ->
        nil
    end
  end

  @doc """
  Validates + stores EG1 (native Event Grid schema) events on `topic`.
  Accepts a single envelope map or a list. Each event requires non-empty
  `id`, `subject`, `eventType`, `eventTime` and a present `data` member.
  All-or-nothing: nothing is stored when any event fails validation.
  Returns `{:ok, [id]}` or `{:error, :invalid_eg1_event}`.
  """
  def eg1_publish(topic, events) when is_list(events) do
    if Enum.all?(events, &eg1_valid?/1) do
      ids =
        for event <- events do
          # Shared seq domain with EventStream (premise sweep #5): the readback
          # GET /topics/:topic/events merges this feed with CloudEvents events
          # by seq — two counters meant two non-comparable domains and the
          # merged insertion order broke. Stamp from EventStream's single
          # counter so one topic's feed is one feed. (The :smalt_eg_topics
          # `{:eg_seq_counter}` row is retired; the tuple key was never listed.)
          seq = Smalt.Messaging.EventStream.next_seq()
          id = event["id"]

          event
          |> Map.put("topic", to_string(topic))
          |> Map.put("seq", seq)
          |> then(&Store.put(:smalt_eg_topics, "eg events:#{String.downcase(topic)}:#{seq}", &1))

          id
        end

      {:ok, ids}
    else
      {:error, :invalid_eg1_event}
    end
  end

  def eg1_publish(_topic, _other), do: {:error, :invalid_eg1_event}

  @doc """
  Lists the EG1 events stored for `topic` in insertion order (stored `seq`).
  """
  def eg_topic_events(topic) do
    :smalt_eg_topics
    |> Store.list_prefix("eg events:#{String.downcase(topic)}:")
    |> Enum.sort_by(fn ev -> ev["seq"] || 0 end)
  end

  defp eg1_valid?(%{} = event) do
    present?(event["id"]) and present?(event["subject"]) and
      present?(event["eventType"]) and present?(event["eventTime"]) and
      Map.has_key?(event, "data")
  end

  defp eg1_valid?(_), do: false

  defp present?(value), do: is_binary(value) and value != ""

  # -- 80/20 Azure Policy + RBAC (Microsoft.Authorization + PolicyInsights) -----
  # Role assignments / role definitions / policy definitions / policy
  # assignments / non-compliance insights. These MUST precede the nested-
  # diagnosticSettings glob routes below (the glob would swallow them).
  # api-version gate uses the resource types already admitted in
  # Smalt.Registry for roleAssignments; the policy types are not Registry-
  # admitted (check_version returns :ok for unknown types — api-version
  # still required, never validated).

  @ra_type "Microsoft.Authorization/roleAssignments"
  @pd_type "Microsoft.Authorization/policyDefinitions"
  @pa_type "Microsoft.Authorization/policyAssignments"
  @pe_type "Microsoft.Authorization/policyExemptions"
  @psd_type "Microsoft.Authorization/policySetDefinitions"

  # Subscription-scope role assignments
  put "/subscriptions/:sub_id/providers/Microsoft.Authorization/roleAssignments/:name" do
    with :ok <- check_api_version(conn, @ra_type),
         merged = Defaults.apply(@ra_type, conn.body_params),
         :ok <- check_shape(conn, @ra_type, merged),
         :ok <- check_properties_member(conn, merged) do
      record = Policy.put_role_assignment("/subscriptions/#{sub_id}", name, conn.body_params)
      send_json(conn, 201, Jason.encode!(record))
    else
      {:respond, conn} -> conn
    end
  end

  get "/subscriptions/:sub_id/providers/Microsoft.Authorization/roleAssignments/:name" do
    with :ok <- check_api_version(conn, @ra_type) do
      case Policy.get_role_assignment("/subscriptions/#{sub_id}", name) do
        {:ok, record} ->
          send_json(conn, 200, Jason.encode!(record))

        :error ->
          send_arm_error(
            conn,
            404,
            "ResourceNotFound",
            "The role assignment '#{name}' was not found."
          )
      end
    else
      {:respond, conn} -> conn
    end
  end

  get "/subscriptions/:sub_id/providers/Microsoft.Authorization/roleAssignments" do
    with :ok <- check_api_version(conn, @ra_type) do
      send_list(conn, Policy.list_role_assignments("/subscriptions/#{sub_id}"))
    else
      {:respond, conn} -> conn
    end
  end

  delete "/subscriptions/:sub_id/providers/Microsoft.Authorization/roleAssignments/:name" do
    with :ok <- check_api_version(conn, @ra_type) do
      Policy.delete_role_assignment("/subscriptions/#{sub_id}", name)
      send_json(conn, 200, "")
    else
      {:respond, conn} -> conn
    end
  end

  # RG-scope (scope-scoped) role assignments. Refusal-tier law: the shape
  # gate runs BEFORE the record is built — a malformed body (e.g. missing
  # location, DefaultShape's single required path) answers 400
  # InvalidResourceShape, never a 201 admission (wire-tier refusal sweep).
  put "/subscriptions/:sub_id/resourceGroups/:rg_name/providers/Microsoft.Authorization/roleAssignments/:name" do
    with :ok <- check_api_version(conn, @ra_type),
         merged = Defaults.apply(@ra_type, conn.body_params),
         :ok <- check_shape(conn, @ra_type, merged),
         :ok <- check_properties_member(conn, merged) do
      scope = "/subscriptions/#{sub_id}/resourceGroups/#{rg_name}"
      record = Policy.put_role_assignment(scope, name, conn.body_params)
      send_json(conn, 201, Jason.encode!(record))
    else
      {:respond, conn} -> conn
    end
  end

  get "/subscriptions/:sub_id/resourceGroups/:rg_name/providers/Microsoft.Authorization/roleAssignments/:name" do
    with :ok <- check_api_version(conn, @ra_type) do
      scope = "/subscriptions/#{sub_id}/resourceGroups/#{rg_name}"

      case Policy.get_role_assignment(scope, name) do
        {:ok, record} ->
          send_json(conn, 200, Jason.encode!(record))

        :error ->
          send_arm_error(
            conn,
            404,
            "ResourceNotFound",
            "The role assignment '#{name}' was not found."
          )
      end
    else
      {:respond, conn} -> conn
    end
  end

  get "/subscriptions/:sub_id/resourceGroups/:rg_name/providers/Microsoft.Authorization/roleAssignments" do
    with :ok <- check_api_version(conn, @ra_type) do
      scope = "/subscriptions/#{sub_id}/resourceGroups/#{rg_name}"
      send_list(conn, Policy.list_role_assignments(scope))
    else
      {:respond, conn} -> conn
    end
  end

  delete "/subscriptions/:sub_id/resourceGroups/:rg_name/providers/Microsoft.Authorization/roleAssignments/:name" do
    with :ok <- check_api_version(conn, @ra_type) do
      Policy.delete_role_assignment("/subscriptions/#{sub_id}/resourceGroups/#{rg_name}", name)
      send_json(conn, 200, "")
    else
      {:respond, conn} -> conn
    end
  end

  # Built-in role definitions (Owner / Contributor / Reader) — served
  # deterministically by Smalt.Policy, never stored.
  get "/subscriptions/:sub_id/providers/Microsoft.Authorization/roleDefinitions/:name" do
    with :ok <- check_api_version(conn, "Microsoft.Authorization/roleDefinitions") do
      case Policy.role_definition("/subscriptions/#{sub_id}", name) do
        {:ok, record} ->
          send_json(conn, 200, Jason.encode!(record))

        :error ->
          send_arm_error(
            conn,
            404,
            "ResourceNotFound",
            "The role definition '#{name}' was not found."
          )
      end
    else
      {:respond, conn} -> conn
    end
  end

  # Policy definitions (subscription scope)
  put "/subscriptions/:sub_id/providers/Microsoft.Authorization/policyDefinitions/:name" do
    with :ok <- check_api_version(conn, @pd_type) do
      record = Policy.put_policy_definition(sub_id, name, conn.body_params)
      send_json(conn, 201, Jason.encode!(record))
    else
      {:respond, conn} -> conn
    end
  end

  get "/subscriptions/:sub_id/providers/Microsoft.Authorization/policyDefinitions/:name" do
    with :ok <- check_api_version(conn, @pd_type) do
      case Policy.get_policy_definition(sub_id, name) do
        {:ok, record} ->
          send_json(conn, 200, Jason.encode!(record))

        :error ->
          send_arm_error(
            conn,
            404,
            "ResourceNotFound",
            "The policy definition '#{name}' was not found."
          )
      end
    else
      {:respond, conn} -> conn
    end
  end

  get "/subscriptions/:sub_id/providers/Microsoft.Authorization/policyDefinitions" do
    with :ok <- check_api_version(conn, @pd_type) do
      send_list(conn, Policy.list_policy_definitions(sub_id))
    else
      {:respond, conn} -> conn
    end
  end

  # Policy assignments (subscription scope AND RG scope — the scope is the
  # placement, derived from the request path by Smalt.Policy)
  put "/subscriptions/:sub_id/providers/Microsoft.Authorization/policyAssignments/:name" do
    with :ok <- check_api_version(conn, @pa_type) do
      record = Policy.put_policy_assignment("/subscriptions/#{sub_id}", name, conn.body_params)
      send_json(conn, 201, Jason.encode!(record))
    else
      {:respond, conn} -> conn
    end
  end

  get "/subscriptions/:sub_id/providers/Microsoft.Authorization/policyAssignments/:name" do
    with :ok <- check_api_version(conn, @pa_type) do
      case Policy.get_policy_assignment("/subscriptions/#{sub_id}", name) do
        {:ok, record} ->
          send_json(conn, 200, Jason.encode!(record))

        :error ->
          send_arm_error(
            conn,
            404,
            "ResourceNotFound",
            "The policy assignment '#{name}' was not found."
          )
      end
    else
      {:respond, conn} -> conn
    end
  end

  get "/subscriptions/:sub_id/providers/Microsoft.Authorization/policyAssignments" do
    with :ok <- check_api_version(conn, @pa_type) do
      send_list(conn, Policy.list_policy_assignments("/subscriptions/#{sub_id}"))
    else
      {:respond, conn} -> conn
    end
  end

  delete "/subscriptions/:sub_id/providers/Microsoft.Authorization/policyAssignments/:name" do
    with :ok <- check_api_version(conn, @pa_type) do
      Policy.delete_policy_assignment("/subscriptions/#{sub_id}", name)
      send_json(conn, 200, "")
    else
      {:respond, conn} -> conn
    end
  end

  put "/subscriptions/:sub_id/resourceGroups/:rg_name/providers/Microsoft.Authorization/policyAssignments/:name" do
    with :ok <- check_api_version(conn, @pa_type) do
      scope = "/subscriptions/#{sub_id}/resourceGroups/#{rg_name}"
      record = Policy.put_policy_assignment(scope, name, conn.body_params)
      send_json(conn, 201, Jason.encode!(record))
    else
      {:respond, conn} -> conn
    end
  end

  get "/subscriptions/:sub_id/resourceGroups/:rg_name/providers/Microsoft.Authorization/policyAssignments/:name" do
    with :ok <- check_api_version(conn, @pa_type) do
      scope = "/subscriptions/#{sub_id}/resourceGroups/#{rg_name}"

      case Policy.get_policy_assignment(scope, name) do
        {:ok, record} ->
          send_json(conn, 200, Jason.encode!(record))

        :error ->
          send_arm_error(
            conn,
            404,
            "ResourceNotFound",
            "The policy assignment '#{name}' was not found."
          )
      end
    else
      {:respond, conn} -> conn
    end
  end

  get "/subscriptions/:sub_id/resourceGroups/:rg_name/providers/Microsoft.Authorization/policyAssignments" do
    with :ok <- check_api_version(conn, @pa_type) do
      scope = "/subscriptions/#{sub_id}/resourceGroups/#{rg_name}"
      send_list(conn, Policy.list_policy_assignments(scope))
    else
      {:respond, conn} -> conn
    end
  end

  delete "/subscriptions/:sub_id/resourceGroups/:rg_name/providers/Microsoft.Authorization/policyAssignments/:name" do
    with :ok <- check_api_version(conn, @pa_type) do
      Policy.delete_policy_assignment("/subscriptions/#{sub_id}/resourceGroups/#{rg_name}", name)
      send_json(conn, 200, "")
    else
      {:respond, conn} -> conn
    end
  end

  # Policy exemptions (subscription scope AND RG scope). put returns
  # {:ok, record} | {:error, PolicyExemptionInvalid envelope} — the error is
  # the typed-400 body, never a 201 admission.
  put "/subscriptions/:sub_id/providers/Microsoft.Authorization/policyExemptions/:name" do
    with :ok <- check_api_version(conn, @pe_type) do
      case Policy.put_policy_exemption("/subscriptions/#{sub_id}", name, conn.body_params) do
        {:ok, record} ->
          send_json(conn, 201, Jason.encode!(record))

        {:error, body} ->
          send_json(conn, 400, Jason.encode!(body))
      end
    else
      {:respond, conn} -> conn
    end
  end

  get "/subscriptions/:sub_id/providers/Microsoft.Authorization/policyExemptions/:name" do
    with :ok <- check_api_version(conn, @pe_type) do
      case Policy.get_policy_exemption("/subscriptions/#{sub_id}", name) do
        {:ok, record} ->
          send_json(conn, 200, Jason.encode!(record))

        :error ->
          send_arm_error(
            conn,
            404,
            "ResourceNotFound",
            "The policy exemption '#{name}' was not found."
          )
      end
    else
      {:respond, conn} -> conn
    end
  end

  get "/subscriptions/:sub_id/providers/Microsoft.Authorization/policyExemptions" do
    with :ok <- check_api_version(conn, @pe_type) do
      send_list(conn, Policy.list_policy_exemptions("/subscriptions/#{sub_id}"))
    else
      {:respond, conn} -> conn
    end
  end

  delete "/subscriptions/:sub_id/providers/Microsoft.Authorization/policyExemptions/:name" do
    with :ok <- check_api_version(conn, @pe_type) do
      Policy.delete_policy_exemption("/subscriptions/#{sub_id}", name)
      send_json(conn, 200, "")
    else
      {:respond, conn} -> conn
    end
  end

  put "/subscriptions/:sub_id/resourceGroups/:rg_name/providers/Microsoft.Authorization/policyExemptions/:name" do
    with :ok <- check_api_version(conn, @pe_type) do
      scope = "/subscriptions/#{sub_id}/resourceGroups/#{rg_name}"

      case Policy.put_policy_exemption(scope, name, conn.body_params) do
        {:ok, record} ->
          send_json(conn, 201, Jason.encode!(record))

        {:error, body} ->
          send_json(conn, 400, Jason.encode!(body))
      end
    else
      {:respond, conn} -> conn
    end
  end

  get "/subscriptions/:sub_id/resourceGroups/:rg_name/providers/Microsoft.Authorization/policyExemptions/:name" do
    with :ok <- check_api_version(conn, @pe_type) do
      scope = "/subscriptions/#{sub_id}/resourceGroups/#{rg_name}"

      case Policy.get_policy_exemption(scope, name) do
        {:ok, record} ->
          send_json(conn, 200, Jason.encode!(record))

        :error ->
          send_arm_error(
            conn,
            404,
            "ResourceNotFound",
            "The policy exemption '#{name}' was not found."
          )
      end
    else
      {:respond, conn} -> conn
    end
  end

  get "/subscriptions/:sub_id/resourceGroups/:rg_name/providers/Microsoft.Authorization/policyExemptions" do
    with :ok <- check_api_version(conn, @pe_type) do
      scope = "/subscriptions/#{sub_id}/resourceGroups/#{rg_name}"
      send_list(conn, Policy.list_policy_exemptions(scope))
    else
      {:respond, conn} -> conn
    end
  end

  delete "/subscriptions/:sub_id/resourceGroups/:rg_name/providers/Microsoft.Authorization/policyExemptions/:name" do
    with :ok <- check_api_version(conn, @pe_type) do
      Policy.delete_policy_exemption("/subscriptions/#{sub_id}/resourceGroups/#{rg_name}", name)
      send_json(conn, 200, "")
    else
      {:respond, conn} -> conn
    end
  end

  # Policy remediations (subscription scope AND RG scope). put returns
  # {:ok, record} | {:error, PolicyRemediationInvalid envelope} — the error is
  # the typed-400 body, never a 201 admission. POST trigger re-runs the
  # assignment evaluation per resourceId at trigger time (never PUT time) and
  # answers 200 with the updated record carrying perResourceStatus.
  put "/subscriptions/:sub_id/providers/Microsoft.Authorization/policyRemediations/:name" do
    with :ok <- check_api_version(conn, @pr_type) do
      case Policy.put_policy_remediation("/subscriptions/#{sub_id}", name, conn.body_params) do
        {:ok, record} ->
          send_json(conn, 201, Jason.encode!(record))

        {:error, body} ->
          send_json(conn, 400, Jason.encode!(body))
      end
    else
      {:respond, conn} -> conn
    end
  end

  get "/subscriptions/:sub_id/providers/Microsoft.Authorization/policyRemediations/:name" do
    with :ok <- check_api_version(conn, @pr_type) do
      case Policy.get_policy_remediation("/subscriptions/#{sub_id}", name) do
        {:ok, record} ->
          send_json(conn, 200, Jason.encode!(record))

        :error ->
          send_arm_error(
            conn,
            404,
            "ResourceNotFound",
            "The policy remediation '#{name}' was not found."
          )
      end
    else
      {:respond, conn} -> conn
    end
  end

  get "/subscriptions/:sub_id/providers/Microsoft.Authorization/policyRemediations" do
    with :ok <- check_api_version(conn, @pr_type) do
      send_list(conn, Policy.list_policy_remediations("/subscriptions/#{sub_id}"))
    else
      {:respond, conn} -> conn
    end
  end

  delete "/subscriptions/:sub_id/providers/Microsoft.Authorization/policyRemediations/:name" do
    with :ok <- check_api_version(conn, @pr_type) do
      Policy.delete_policy_remediation("/subscriptions/#{sub_id}", name)
      send_json(conn, 200, "")
    else
      {:respond, conn} -> conn
    end
  end

  put "/subscriptions/:sub_id/resourceGroups/:rg_name/providers/Microsoft.Authorization/policyRemediations/:name" do
    with :ok <- check_api_version(conn, @pr_type) do
      scope = "/subscriptions/#{sub_id}/resourceGroups/#{rg_name}"

      case Policy.put_policy_remediation(scope, name, conn.body_params) do
        {:ok, record} ->
          send_json(conn, 201, Jason.encode!(record))

        {:error, body} ->
          send_json(conn, 400, Jason.encode!(body))
      end
    else
      {:respond, conn} -> conn
    end
  end

  get "/subscriptions/:sub_id/resourceGroups/:rg_name/providers/Microsoft.Authorization/policyRemediations/:name" do
    with :ok <- check_api_version(conn, @pr_type) do
      scope = "/subscriptions/#{sub_id}/resourceGroups/#{rg_name}"

      case Policy.get_policy_remediation(scope, name) do
        {:ok, record} ->
          send_json(conn, 200, Jason.encode!(record))

        :error ->
          send_arm_error(
            conn,
            404,
            "ResourceNotFound",
            "The policy remediation '#{name}' was not found."
          )
      end
    else
      {:respond, conn} -> conn
    end
  end

  get "/subscriptions/:sub_id/resourceGroups/:rg_name/providers/Microsoft.Authorization/policyRemediations" do
    with :ok <- check_api_version(conn, @pr_type) do
      scope = "/subscriptions/#{sub_id}/resourceGroups/#{rg_name}"
      send_list(conn, Policy.list_policy_remediations(scope))
    else
      {:respond, conn} -> conn
    end
  end

  delete "/subscriptions/:sub_id/resourceGroups/:rg_name/providers/Microsoft.Authorization/policyRemediations/:name" do
    with :ok <- check_api_version(conn, @pr_type) do
      Policy.delete_policy_remediation(
        "/subscriptions/#{sub_id}/resourceGroups/#{rg_name}",
        name
      )

      send_json(conn, 200, "")
    else
      {:respond, conn} -> conn
    end
  end

  # Trigger: POST .../policyRemediations/:name/trigger — 200 with the updated
  # record (perResourceStatus), 404 ResourceNotFound when absent.
  post "/subscriptions/:sub_id/providers/Microsoft.Authorization/policyRemediations/:name/trigger" do
    with :ok <- check_api_version(conn, @pr_type) do
      case Policy.trigger_policy_remediation("/subscriptions/#{sub_id}", name) do
        {:ok, record} ->
          send_json(conn, 200, Jason.encode!(record))

        :error ->
          send_arm_error(
            conn,
            404,
            "ResourceNotFound",
            "The policy remediation '#{name}' was not found."
          )
      end
    else
      {:respond, conn} -> conn
    end
  end

  # KD-COVERS: KD-112
  # Policy set definitions (initiatives, subscription scope). Members are
  # policyDefinitions references; evaluate_assignment/2 resolves an
  # assignment's policyDefinitionId through the set (worst-effect wins).
  put "/subscriptions/:sub_id/providers/Microsoft.Authorization/policySetDefinitions/:name" do
    with :ok <- check_api_version(conn, @psd_type) do
      case Policy.put_policy_set_definition(sub_id, name, conn.body_params) do
        {:ok, record} ->
          send_json(conn, 201, Jason.encode!(record))

        {:error, body} ->
          send_json(conn, 400, Jason.encode!(body))
      end
    else
      {:respond, conn} -> conn
    end
  end

  get "/subscriptions/:sub_id/providers/Microsoft.Authorization/policySetDefinitions/:name" do
    with :ok <- check_api_version(conn, @psd_type) do
      case Policy.get_policy_set_definition(sub_id, name) do
        {:ok, record} ->
          send_json(conn, 200, Jason.encode!(record))

        :error ->
          send_arm_error(
            conn,
            404,
            "ResourceNotFound",
            "The policy set definition '#{name}' was not found."
          )
      end
    else
      {:respond, conn} -> conn
    end
  end

  get "/subscriptions/:sub_id/providers/Microsoft.Authorization/policySetDefinitions" do
    with :ok <- check_api_version(conn, @psd_type) do
      send_list(conn, Policy.list_policy_set_definitions(sub_id))
    else
      {:respond, conn} -> conn
    end
  end

  # -- Microsoft.ResourceHealth/availabilityStatuses faces (V9 lane) -----------
  # Subscription-scope list + per-resource list/current faces. Backed by
  # Smalt.Arm.ResourceHealth (synthetic-Available law: existing row ->
  # Available, unknown -> 404); envelope built in the arm_gateway seam module
  # (Smalt.ArmGateway.ResourceHealth), never inline in the router.
  get "/subscriptions/:sub_id/providers/Microsoft.ResourceHealth/availabilityStatuses" do
    with :ok <- check_api_version(conn, "Microsoft.ResourceHealth/availabilityStatuses") do
      case ResourceHealth.list(sub_id) do
        {:ok, 200, env} -> send_json(conn, 200, Jason.encode!(env))
        {:error, 404, err} -> send_arm_error(conn, 404, err["error"]["code"], err["error"]["message"])
      end
    else
      {:respond, conn} -> conn
    end
  end

  get "/subscriptions/:sub_id/resourcegroups/:rg_name/providers/:provider_ns/:resource_type/:resource_name/providers/Microsoft.ResourceHealth/availabilityStatuses" do
    with :ok <- check_api_version(conn, "Microsoft.ResourceHealth/availabilityStatuses") do
      {:ok, 200, env} =
        ResourceHealth.list_for_resource(sub_id, rg_name, "#{provider_ns}/#{resource_type}", resource_name)

      send_json(conn, 200, Jason.encode!(env))
    else
      {:respond, conn} -> conn
    end
  end

  get "/subscriptions/:sub_id/resourceGroups/:rg_name/providers/:provider_ns/:resource_type/:resource_name/providers/Microsoft.ResourceHealth/availabilityStatuses" do
    with :ok <- check_api_version(conn, "Microsoft.ResourceHealth/availabilityStatuses") do
      {:ok, 200, env} =
        ResourceHealth.list_for_resource(sub_id, rg_name, "#{provider_ns}/#{resource_type}", resource_name)

      send_json(conn, 200, Jason.encode!(env))
    else
      {:respond, conn} -> conn
    end
  end

  get "/subscriptions/:sub_id/resourcegroups/:rg_name/providers/:provider_ns/:resource_type/:resource_name/providers/Microsoft.ResourceHealth/availabilityStatuses/current" do
    with :ok <- check_api_version(conn, "Microsoft.ResourceHealth/availabilityStatuses") do
      case ResourceHealth.get_current(sub_id, rg_name, "#{provider_ns}/#{resource_type}", resource_name) do
        {:ok, 200, env} -> send_json(conn, 200, Jason.encode!(env))
        {:error, 404, err} -> send_arm_error(conn, 404, err["error"]["code"], err["error"]["message"])
      end
    else
      {:respond, conn} -> conn
    end
  end

  get "/subscriptions/:sub_id/resourceGroups/:rg_name/providers/:provider_ns/:resource_type/:resource_name/providers/Microsoft.ResourceHealth/availabilityStatuses/current" do
    with :ok <- check_api_version(conn, "Microsoft.ResourceHealth/availabilityStatuses") do
      case ResourceHealth.get_current(sub_id, rg_name, "#{provider_ns}/#{resource_type}", resource_name) do
        {:ok, 200, env} -> send_json(conn, 200, Jason.encode!(env))
        {:error, 404, err} -> send_arm_error(conn, 404, err["error"]["code"], err["error"]["message"])
      end
    else
      {:respond, conn} -> conn
    end
  end

  # Policy insights: per-assignment non-compliance (from the policy store's
  # receipt rows, written by Smalt.Policy.enforce/3 on deny AND audit effects).
  get "/subscriptions/:sub_id/providers/Microsoft.PolicyInsights/policyStates/latest/summarize" do
    with :ok <- check_api_version(conn, "Microsoft.PolicyInsights/policyStates") do
      send_json(conn, 200, Jason.encode!(%{"value" => Policy.non_compliance_summary()}))
    else
      {:respond, conn} -> conn
    end
  end

  get "/subscriptions/:sub_id/providers/Microsoft.PolicyInsights/policyStates/latest/queryResults" do
    with :ok <- check_api_version(conn, "Microsoft.PolicyInsights/policyStates") do
      assignment_id = conn.query_params["policyAssignmentId"] || ""

      resources =
        if assignment_id == "" do
          []
        else
          Policy.non_compliant_resources(assignment_id)
        end

      send_json(conn, 200, Jason.encode!(%{"value" => resources}))
    else
      {:respond, conn} -> conn
    end
  end

  # -- ARM data collection rules (Microsoft.Insights/dataCollectionRules) -------
  # Sentinel DCR family at the RG provider scope: PUT/GET/DELETE/LIST.
  # Declared BEFORE the generic provider routes below — Plug.Router matches in
  # declaration order, and the generic PUT gates through check_admitted, which
  # refuses types absent from the generated registry (`mix smalt.gen` —
  # dataCollectionRules is not yet a registry individual; adding it is the
  # registry lane's move, never hand-edit generated files).
  #
  # Sentinel coupling (store shape read-only over data_plane/sentinel.ex):
  # PUT seeds the `{:dcr_created, name}` marker in `:smalt_sentinel_streams`
  # (the row `Sentinel.dcr_exists?/1` consults) and DELETE clears the DCR's
  # stream-meta prefix so the `:sentinel_dcr_strict` ingest fence refuses the
  # deleted rule with the typed 404 DCRNotFound envelope. Row data under
  # `:smalt_sentinel_rows` is preserved (real Azure keeps workspace data after
  # a DCR delete).
  @dcr_type "Microsoft.Insights/dataCollectionRules"

  put "/subscriptions/:sub_id/resourceGroups/:rg_name/providers/Microsoft.Insights/dataCollectionRules/:name" do
    with :ok <- check_api_version(conn, @dcr_type) do
      res_id = resource_id(sub_id, rg_name, "Microsoft.Insights", "dataCollectionRules", name)
      key = String.downcase(res_id)

      existed? = match?({:ok, _}, Store.get(:smalt_resources, key))

      record = build_resource_record(@dcr_type, res_id, name, conn.body_params)

      Store.put(:smalt_resources, key, record)
      Store.put(:smalt_sentinel_streams, {:dcr_created, name}, true)

      send_json(conn, if(existed?, do: 200, else: 201), Jason.encode!(record))
    else
      {:respond, conn} -> conn
    end
  end

  get "/subscriptions/:sub_id/resourceGroups/:rg_name/providers/Microsoft.Insights/dataCollectionRules/:name" do
    with :ok <- check_api_version(conn, @dcr_type) do
      res_id = resource_id(sub_id, rg_name, "Microsoft.Insights", "dataCollectionRules", name)

      case Store.get(:smalt_resources, String.downcase(res_id)) do
        {:ok, record} ->
          send_json(conn, 200, Jason.encode!(record))

        :error ->
          send_arm_error(
            conn,
            404,
            "ResourceNotFound",
            "The data collection rule '#{name}' was not found.",
            res_id
          )
      end
    else
      {:respond, conn} -> conn
    end
  end

  get "/subscriptions/:sub_id/resourceGroups/:rg_name/providers/Microsoft.Insights/dataCollectionRules" do
    with :ok <- check_api_version(conn, @dcr_type) do
      prefix = String.downcase("/subscriptions/#{sub_id}/resourceGroups/#{rg_name}/")

      items =
        Store.list_prefix(:smalt_resources, prefix)
        |> Enum.filter(&(&1["type"] == @dcr_type))

      send_list(conn, items)
    else
      {:respond, conn} -> conn
    end
  end

  delete "/subscriptions/:sub_id/resourceGroups/:rg_name/providers/Microsoft.Insights/dataCollectionRules/:name" do
    with :ok <- check_api_version(conn, @dcr_type) do
      res_id = resource_id(sub_id, rg_name, "Microsoft.Insights", "dataCollectionRules", name)
      key = String.downcase(res_id)

      case Store.get(:smalt_resources, key) do
        {:ok, _record} ->
          Store.delete(:smalt_resources, key)
          # Sentinel lifecycle: drop the creation marker + stream-meta rows so
          # the strict-mode ingest fence sees a genuinely absent DCR. Row data
          # (:smalt_sentinel_rows) is preserved.
          Store.delete(:smalt_sentinel_streams, {:dcr_created, name})

          :smalt_sentinel_streams
          |> Store.prefix_keys("#{name}/")
          |> Enum.each(&Store.delete(:smalt_sentinel_streams, &1))

          send_json(conn, 200, "")

        :error ->
          send_arm_error(
            conn,
            404,
            "ResourceNotFound",
            "The data collection rule '#{name}' was not found.",
            res_id
          )
      end
    else
      {:respond, conn} -> conn
    end
  end

  # -- ARM Log Analytics workspace tables (Microsoft.OperationalInsights) -------
  # GET tables family for a workspace: per-stream table rows wired to
  # `Sentinel.table_stats/1` (count + oldest/newest TimeGenerated, landed
  # wave-3). Workspace<->DCR binding: the workspace name IS the DCR name (the
  # egress ingest path `POST /dataCollectionRules/:dcr/streams/:stream` keys
  # stream state by DCR name), so tables of workspace `ws` = `table_stats(ws)`
  # keyed "{ws}/{stream}".
  @la_type "Microsoft.OperationalInsights/workspaces"

  get "/subscriptions/:sub_id/resourceGroups/:rg_name/providers/Microsoft.OperationalInsights/workspaces/:ws_name/tables" do
    with :ok <- check_api_version(conn, @la_type) do
      res_id =
        resource_id(sub_id, rg_name, "Microsoft.OperationalInsights", "workspaces", ws_name)

      case Store.get(:smalt_resources, String.downcase(res_id)) do
        {:ok, _record} ->
          prefix = "#{ws_name}/"

          items =
            for {key, %{count: count, oldest: oldest, newest: newest}} <-
                  Sentinel.table_stats(ws_name) do
              stream = String.slice(key, String.length(prefix)..-1//1)
              retention = retention_days_for(ws_name, stream)

              %{
                "id" => "#{res_id}/tables/#{stream}",
                "name" => stream,
                "type" => "Microsoft.OperationalInsights/workspaces/tables",
                "properties" => %{
                  "retentionInDays" => retention,
                  "totalRecords" => count,
                  "oldestTimeGenerated" => oldest,
                  "newestTimeGenerated" => newest
                }
              }
            end

          send_list(conn, items)

        :error ->
          send_arm_error(
            conn,
            404,
            "ResourceNotFound",
            "The workspace '#{ws_name}' was not found.",
            res_id
          )
      end
    else
      {:respond, conn} -> conn
    end
  end

  get "/subscriptions/:sub_id/resourceGroups/:rg_name/providers/Microsoft.OperationalInsights/workspaces/:ws_name/tables/:table_name" do
    with :ok <- check_api_version(conn, @la_type) do
      res_id =
        resource_id(sub_id, rg_name, "Microsoft.OperationalInsights", "workspaces", ws_name)

      workspace? = match?({:ok, _}, Store.get(:smalt_resources, String.downcase(res_id)))

      stats =
        if workspace? do
          Map.get(Sentinel.table_stats(ws_name), "#{ws_name}/#{table_name}")
        else
          nil
        end

      cond do
        not workspace? ->
          send_arm_error(
            conn,
            404,
            "ResourceNotFound",
            "The workspace '#{ws_name}' was not found.",
            res_id
          )

        is_nil(stats) ->
          send_arm_error(
            conn,
            404,
            "TableNotFound",
            "The table '#{table_name}' was not found in workspace '#{ws_name}'.",
            "#{res_id}/tables/#{table_name}"
          )

        true ->
          retention = retention_days_for(ws_name, table_name)

          send_json(
            conn,
            200,
            Jason.encode!(%{
              "id" => "#{res_id}/tables/#{table_name}",
              "name" => table_name,
              "type" => "Microsoft.OperationalInsights/workspaces/tables",
              "properties" => %{
                "retentionInDays" => retention,
                "totalRecords" => stats.count,
                "oldestTimeGenerated" => stats.oldest,
                "newestTimeGenerated" => stats.newest
              }
            })
          )
      end
    else
      {:respond, conn} -> conn
    end
  end

  # Retention mirror of sentinel.ex retention_days/2 (private there): the
  # stream-meta row carries "retention_days" only when `Sentinel.set_retention/3`
  # configured it; unset -> real-LA default 730 days.
  defp retention_days_for(dcr, stream) do
    case Store.get(:smalt_sentinel_streams, "#{dcr}/#{stream}") do
      {:ok, %{"retention_days" => days}} when is_integer(days) and days > 0 -> days
      _ -> 730
    end
  end

  # -- Generic ARM provider routes ----------------------------------------------
  # roleAssignments / diagnosticSettings / DevTestLab schedules ride these;
  # Registry.admitted?/1 (via find_admitted) gates them.
  put "/subscriptions/:sub_id/resourceGroups/:rg_name/providers/:provider_ns/:resource_type/:resource_name" do
    handle_resource_put(conn, "#{provider_ns}/#{resource_type}", sub_id, rg_name, resource_name)
  end

  get "/subscriptions/:sub_id/resourceGroups/:rg_name/providers/:provider_ns/:resource_type/:resource_name" do
    handle_resource_get(conn, sub_id, rg_name, provider_ns, resource_type, resource_name)
  end

  # KD-57: generic ARM PATCH on the 3-segment provider route (updateByName).
  # ARM PATCH is a partial update: `properties` merge key-wise into the stored
  # record; `tags` and `sku` replace wholesale when present; location/id/name
  # are immutable. Refusal tier mirrors the PUT (api-version -> admission ->
  # properties-member fence -> existence) minus full-shape validation (a
  # partial body legitimately omits required members). Policy gate rides the
  # same enforce/2 the PUT uses.
  patch "/subscriptions/:sub_id/resourceGroups/:rg_name/providers/:provider_ns/:resource_type/:resource_name" do
    handle_resource_patch(conn, "#{provider_ns}/#{resource_type}", sub_id, rg_name, resource_name)
  end

  # -- AZURE-FIDELITY lane 4: locks at RESOURCE scope, tags at RESOURCE scope,
  # and the generic resource DELETE lock gate ----------------------------------
  # Locks reuse the router's existing handle_lock_* handlers (Smalt.Policy owns
  # the law; a resource-scoped lock's properties.scope IS the resource id, and
  # lock_blocks?/2 prefix-covers children/parents identically to RBAC scope
  # inheritance). Tags ride the :smalt_resources record's "tags" member. The
  # generic DELETE consults the lock store FIRST: a covering CanNotDelete or
  # ReadOnly lock answers the documented 409 ScopeLocked and the resource
  # SURVIVES; unlocked deletes cascade children + metrics + lifecycle row.
  get "/subscriptions/:sub_id/resourceGroups/:rg_name/providers/:provider_ns/:resource_type/:resource_name/providers/Microsoft.Authorization/locks" do
    handle_locks_list(
      conn,
      resource_id(sub_id, rg_name, provider_ns, resource_type, resource_name)
    )
  end

  get "/subscriptions/:sub_id/resourceGroups/:rg_name/providers/:provider_ns/:resource_type/:resource_name/providers/Microsoft.Authorization/locks/:lock_name" do
    handle_lock_get(
      conn,
      resource_id(sub_id, rg_name, provider_ns, resource_type, resource_name),
      lock_name
    )
  end

  put "/subscriptions/:sub_id/resourceGroups/:rg_name/providers/:provider_ns/:resource_type/:resource_name/providers/Microsoft.Authorization/locks/:lock_name" do
    handle_lock_put(
      conn,
      resource_id(sub_id, rg_name, provider_ns, resource_type, resource_name),
      lock_name
    )
  end

  delete "/subscriptions/:sub_id/resourceGroups/:rg_name/providers/:provider_ns/:resource_type/:resource_name/providers/Microsoft.Authorization/locks/:lock_name" do
    handle_lock_delete(
      conn,
      resource_id(sub_id, rg_name, provider_ns, resource_type, resource_name),
      lock_name
    )
  end

  get "/subscriptions/:sub_id/resourcegroups/:rg_name/providers/:provider_ns/:resource_type/:resource_name/providers/Microsoft.Resources/tags" do
    handle_resource_tags_get(conn, sub_id, rg_name, provider_ns, resource_type, resource_name)
  end

  get "/subscriptions/:sub_id/resourceGroups/:rg_name/providers/:provider_ns/:resource_type/:resource_name/providers/Microsoft.Resources/tags" do
    handle_resource_tags_get(conn, sub_id, rg_name, provider_ns, resource_type, resource_name)
  end

  get "/subscriptions/:sub_id/resourceGroups/:rg_name/providers/:provider_ns/:resource_type/:resource_name/providers/Microsoft.Resources/tags/default" do
    handle_resource_tags_get(conn, sub_id, rg_name, provider_ns, resource_type, resource_name)
  end

  put "/subscriptions/:sub_id/resourceGroups/:rg_name/providers/:provider_ns/:resource_type/:resource_name/providers/Microsoft.Resources/tags" do
    handle_resource_tags_put(
      conn,
      sub_id,
      rg_name,
      provider_ns,
      resource_type,
      resource_name,
      :replace
    )
  end

  put "/subscriptions/:sub_id/resourceGroups/:rg_name/providers/:provider_ns/:resource_type/:resource_name/providers/Microsoft.Resources/tags/default" do
    handle_resource_tags_put(
      conn,
      sub_id,
      rg_name,
      provider_ns,
      resource_type,
      resource_name,
      :replace
    )
  end

  patch "/subscriptions/:sub_id/resourceGroups/:rg_name/providers/:provider_ns/:resource_type/:resource_name/providers/Microsoft.Resources/tags" do
    handle_resource_tags_put(
      conn,
      sub_id,
      rg_name,
      provider_ns,
      resource_type,
      resource_name,
      :merge
    )
  end

  patch "/subscriptions/:sub_id/resourceGroups/:rg_name/providers/:provider_ns/:resource_type/:resource_name/providers/Microsoft.Resources/tags/default" do
    handle_resource_tags_put(
      conn,
      sub_id,
      rg_name,
      provider_ns,
      resource_type,
      resource_name,
      :merge
    )
  end

  # Generic resource DELETE with the management-lock gate (lane 4 law): the
  # lock consult happens BEFORE any mutation — a locked delete answers the
  # documented 409 ScopeLocked envelope and the resource survives; an
  # unlocked delete is an ARM LRO (202 + Location + Retry-After) that sweeps
  # the record, its children (store-key prefix cascade), its metrics series
  # and its lane-1 lifecycle row.
  delete "/subscriptions/:sub_id/resourceGroups/:rg_name/providers/:provider_ns/:resource_type/:resource_name" do
    handle_resource_delete(conn, sub_id, rg_name, provider_ns, resource_type, resource_name)
  end

  # LIST: per-RG provider-type listing, e.g. GET .../providers/Microsoft.Network/virtualNetworks
  get "/subscriptions/:sub_id/resourceGroups/:rg_name/providers/:provider_ns/:resource_type" do
    with :ok <- check_api_version(conn, "#{provider_ns}/#{resource_type}") do
      prefix =
        String.downcase(
          "/subscriptions/#{sub_id}/resourceGroups/#{rg_name}/providers/#{provider_ns}/#{resource_type}/"
        )

      # Real-ARM parity: a type-scoped LIST returns ONLY the requested type —
      # deep-type descendants (e.g. containers under storageAccounts) must not
      # leak into the parent type's page (probe: lens-3 cycle-1 receipt).
      wanted = String.downcase("#{provider_ns}/#{resource_type}")

      # SHIM-COURT-adjacent fence parity (repair lane R18, audit A11 finding 1):
      # deny-by-default before type filtering — a non-map record under the
      # prefix previously raised in the &1["type"] projection and 500-ed the
      # whole type-scoped LIST forever (store poisoning), bypassing the
      # renderable_record? fence send_list applies.
      items =
        Store.list_prefix(:smalt_resources, prefix)
        |> Enum.filter(&renderable_record?/1)
        |> Enum.filter(&(String.downcase(&1["type"] || "") == wanted))

      send_list(conn, items)
    else
      {:respond, conn} -> conn
    end
  end

  # Microsoft.Storage storageAccounts DELETE: ARM LRO (202 + Azure-Async-
  # Operation + Location + Retry-After via async_put_response + a fresh
  # LRO.start_op), account-level only — and a cascade sweep that removes every
  # child record stored under the account (both store-key conventions), so a
  # deleted account never leaves GETable children behind. Existence fence:
  # 404 ResourceNotFound for a delete of a nonexistent account.
  delete "/subscriptions/:sub_id/resourceGroups/:rg_name/providers/Microsoft.Storage/storageAccounts/:resource_name" do
    with :ok <- check_api_version(conn, "Microsoft.Storage/storageAccounts") do
      res_id =
        resource_id(sub_id, rg_name, "Microsoft.Storage", "storageAccounts", resource_name)

      # Cascade law: DELETE drops the resource's own metrics series
      # (destroy residue gate: a deleted resource leaves no
      # :smalt_metrics rows).
      Smalt.Metrics.drop(res_id)

      key = String.downcase(res_id)

      case Store.get(:smalt_resources, key) do
        {:ok, record} when is_map(record) ->
          Store.delete(:smalt_resources, key)

          # Cascade by STORE KEY (both conventions): prefixed
          # (.../providers/Microsoft.Storage/storageAccounts/<acct>/...) and
          # unprefixed (.../storageaccounts/<acct>/... child-route form).
          cascade_sweep(:smalt_resources, String.downcase(res_id <> "/"))

          cascade_sweep(
            :smalt_resources,
            String.downcase(
              "/subscriptions/#{sub_id}/resourceGroups/#{rg_name}/storageAccounts/#{resource_name}/"
            )
          )

          # D127: the account's data-plane rows (containers/blobs/policies,
          # "acct/..." keys) must not orphan on account teardown.
          BlobStorage.drop_account_data(resource_name)

          # AZB-25b: real ARM storage-account DELETE is SYNCHRONOUS (200 OK)
          # — azurerm 4.54's delete path does not poll a 202 (witnessed:
          # "unexpected status 202 with response {operation record}").
          # Only the PUT create flow is LRO-async for this type.
          send_resp(conn, 200, "")

        _ ->
          send_arm_error(
            conn,
            404,
            "ResourceNotFound",
            "The Resource '#{resource_name}' was not found.",
            res_id
          )
      end
    else
      {:respond, conn} -> conn
    end
  end

  # cascade_sweep/2: exact prefix-key deletion over a Store table. Returns the
  # swept STORE KEYS so callers can capture-then-sweep data-plane tables from
  # them (storage_account_names/1, VaultData.vault_secret_names/1).
  defp cascade_sweep(table, base) do
    for key <- Store.prefix_keys(table, base) do
      Store.delete(table, key)
      key
    end
  end

  defp vault_secret_sweep(swept_keys) do
    swept_keys
    |> VaultData.vault_secret_names()
    |> VaultData.drop_vault_secrets()
  end

  # Cosmos pk_meta cascade (capture-then-sweep over swept ARM store keys, same
  # shape as storage_account_names/1 + vault_secret_sweep/1). Containers drop
  # first so each `{1, db, coll}`/`"db/coll"` row is named by its own swept
  # key; then databases drop `{0, db}` plus any remaining child rows.
  defp cosmos_sweep(swept_keys) do
    colls =
      for {db, coll} <- cosmos_swept_containers(swept_keys) do
        Cosmos.drop_container(db, coll)
        {db, coll}
      end

    for db <- cosmos_swept_dbs(swept_keys, colls) do
      Cosmos.drop_db(db)
    end
  end

  defp cosmos_swept_containers(keys) do
    keys
    |> Enum.flat_map(fn key ->
      case Regex.run(
             ~r/databaseaccounts\/[^\/]+\/sqldatabases\/([^\/]+)\/sqlcontainers\/([^\/]+)/i,
             key,
             capture: :all_but_first
           ) do
        [db, coll] -> [{db, coll}]
        _ -> []
      end
    end)
    |> Enum.uniq()
  end

  # Databases swept either by their own key (no trailing /sqlContainers) or
  # implicitly via a swept container (reverse-topological cascade where the
  # account key carries the whole subtree).
  defp cosmos_swept_dbs(keys, colls) do
    from_containers = Enum.map(colls, &elem(&1, 0))

    from_keys =
      keys
      |> Enum.flat_map(fn key ->
        case Regex.run(~r/databaseaccounts\/[^\/]+\/sqldatabases\/([^\/]+)$/i, key,
               capture: :all_but_first
             ) do
          [db] -> [db]
          _ -> []
        end
      end)

    Enum.uniq(from_containers ++ from_keys)
  end

  # Extract storageAccount names from swept ARM store keys (capture-then-sweep
  # for the D127 data-plane cascade). Matches both store-key conventions:
  # prefixed (.../providers/microsoft.storage/storageaccounts/<acct>/...) and
  # the child-route form (.../storageaccounts/<acct>/...).
  defp storage_account_names(keys) do
    keys
    |> Enum.flat_map(fn key ->
      case Regex.run(~r/storageaccounts\/([^\/]+)/i, key, capture: :all_but_first) do
        [acct] -> [acct]
        _ -> []
      end
    end)
    |> Enum.uniq()
  end

  # Microsoft.KeyVault vaults DELETE (FR-6): a deleted vault must not leave
  # GETable ARM children (secrets/keys under both store-key conventions) or
  # orphaned data-plane secret rows on the 8443 /secrets surface. Capture-then-
  # sweep: cascade_sweep/2 returns the swept store keys, from which the bare
  # secret names are extracted for the VaultData sweep (keys in
  # :smalt_vault_secrets are bare names, no vault scoping).
  delete "/subscriptions/:sub_id/resourceGroups/:rg_name/providers/Microsoft.KeyVault/vaults/:resource_name" do
    with :ok <- check_api_version(conn, "Microsoft.KeyVault/vaults") do
      res_id =
        resource_id(sub_id, rg_name, "Microsoft.KeyVault", "vaults", resource_name)

      # Cascade law: DELETE drops the resource's own metrics series
      # (destroy residue gate: a deleted resource leaves no
      # :smalt_metrics rows).
      Smalt.Metrics.drop(res_id)

      key = String.downcase(res_id)

      case Store.get(:smalt_resources, key) do
        {:ok, record} when is_map(record) ->
          Store.delete(:smalt_resources, key)

          swept =
            cascade_sweep(:smalt_resources, key <> "/") ++
              cascade_sweep(
                :smalt_resources,
                String.downcase(
                  "/subscriptions/#{sub_id}/resourceGroups/#{rg_name}/vaults/#{resource_name}/"
                )
              )

          vault_secret_sweep(swept)

          send_json(conn, 200, "")

        _ ->
          send_arm_error(
            conn,
            404,
            "ResourceNotFound",
            "The Resource '#{resource_name}' was not found.",
            res_id
          )
      end
    else
      {:respond, conn} -> conn
    end
  end

  # Microsoft.KeyVault deleted-vault purge (azurerm destroy calls
  # POST .../providers/Microsoft.KeyVault/locations/:loc/deletedVaults/:name/purge
  # after DELETE; RouteNotFound here failed tf destroy — c11-tf-loop lane,
  # tmp/c11-tf-loop-34762.log, 2026-10-16).
  post "/subscriptions/:sub_id/providers/Microsoft.KeyVault/locations/:loc/deletedVaults/:name/purge" do
    with :ok <- check_api_version(conn, "Microsoft.KeyVault/deletedVaults") do
      send_json(conn, 200, "")
    else
      {:respond, conn} -> conn
    end
  end

  delete "/subscriptions/:sub_id/resourceGroups/:rg_name/providers/:provider_ns/:resource_type/:resource_name" do
    with :ok <- check_api_version(conn, "#{provider_ns}/#{resource_type}") do
      res_id = resource_id(sub_id, rg_name, provider_ns, resource_type, resource_name)
      key = String.downcase(res_id)
      # Cascade law: DELETE drops the resource's own metrics series. A delete
      # EMITTING a Requests datapoint would strand the row forever (the
      # resource is gone; destroy residue gate would flag it).
      Smalt.Metrics.drop(res_id)
      Store.delete(:smalt_resources, key)

      # AZURE-FIDELITY lane 1: DELETE drops the lifecycle row with the
      # resource (a deleted id never resurrects a stale createdTime).
      :ok = ProviderState.drop_lifecycle(res_id)

      # Cosmos account cascade (composite-identity lane): capture-then-sweep
      # the pk_meta rows under a deleted databaseAccounts resource. Mirrors the
      # RG cascade's swept-keys shape; no-op for every other resource type.
      swept = cascade_sweep(:smalt_resources, key <> "/")
      cosmos_sweep(swept)

      send_json(conn, 200, "")
    else
      {:respond, conn} -> conn
    end
  end

  # -- Nested-provider diagnosticSettings (azurerm wire form) --------------------
  # {resourceId}/providers/Microsoft.Insights/diagnosticSettings/{name} — the
  # nested `providers` segment makes these fall through the generic 3-segment
  # provider routes, so they are handled by glob AFTER those routes.
  put "/subscriptions/:sub_id/resourceGroups/:rg_name/providers/*glob" do
    handle_nested_diagnostic_settings(conn, "put", sub_id, rg_name, glob)
  end

  get "/subscriptions/:sub_id/resourceGroups/:rg_name/providers/*glob" do
    handle_nested_diagnostic_settings(conn, "get", sub_id, rg_name, glob)
  end

  delete "/subscriptions/:sub_id/resourceGroups/:rg_name/providers/*glob" do
    handle_nested_diagnostic_settings(conn, "delete", sub_id, rg_name, glob)
  end

  # -- HEAD existence checks (azurerm CheckNameExists) ----------------------------
  # KD-COVERS: KD-91
  # azurerm 4.54 sends `HEAD /subscriptions/{sub}/providers/Microsoft.DocumentDB/
  # databaseAccountNames/{name}` with NO api-version before create (witnessed:
  # /tmp/tf-plan-probe.EBIxd7/cosmos/apply.log — CheckNameExists StatusCode=400,
  # autorest cannot parse a JSON body on HEAD). Real ARM answers HEAD existence
  # checks 204 (exists) / 404 (not) with EMPTY bodies and no api-version
  # requirement. Existence = any stored resource record whose lowercased id ends
  # with /providers/microsoft.documentdb/databaseaccounts/{name}.
  head "/subscriptions/:sub_id/providers/Microsoft.DocumentDB/databaseAccountNames/:name" do
    suffix = "/providers/microsoft.documentdb/databaseaccounts/#{String.downcase(name)}"

    exists? =
      :smalt_resources
      |> Store.keys()
      |> Enum.any?(fn key -> String.ends_with?(key, suffix) end)

    # HEAD responses carry EMPTY bodies (autorest parses nothing).
    send_resp(conn, if(exists?, do: 204, else: 404), "")
  end

  # GAP-AZB20-6: Resource Graph query on the ARM (9443) surface — the handler
  # previously existed only behind the TLS twin (EgressRouter, 8443); plain-HTTP
  # ARM answered catch-all 404. First top-level /providers prefix on ARM.
  post "/providers/Microsoft.ResourceGraph/resources" do
    # A hostile body (invalid JSON raises in Plug.Parsers; a non-map decoded
    # body) refuses typed 400, never a crash-path 500.
    try do
      body = if is_map(conn.body_params), do: conn.body_params, else: %{}

      # Clause-gate adoption (lane F2): the arm_gateway seam
      # (Smalt.ArmGateway.ResourceGraph.query/2 — body + api-version) fronts
      # the one evaluator, refusing unsupported KQL clauses with a typed 400
      # UnsupportedClause before evaluation.
      case Smalt.ArmGateway.ResourceGraph.query(
             body,
             Map.get(conn.query_params || %{}, "api-version", "")
           ) do
        {:ok, status, resp} -> send_json(conn, status, Jason.encode!(resp))
        {:error, status, resp} -> send_json(conn, status, Jason.encode!(resp))
      end
    rescue
      e ->
        send_arm_error(
          conn,
          400,
          "InvalidBody",
          "The request body could not be processed: #{e.__struct__}"
        )
    end
  end

  defp deployments_put(conn, sub, rg, name) do
    with {:ok, raw} <- deployments_body(conn),
         {:ok, m} <- Smalt.Arm.Deployments.put_deployment(sub, rg, name, raw) do
      # V7 lane: deployment completions join the activity log. resourceId is
      # the deployment's ARM id (RG-scoped or subscription-scoped); a
      # subscription-level deployment has no resource group — empty string.
      dep_id =
        if rg do
          "/subscriptions/#{sub}/resourceGroups/#{rg}/providers/Microsoft.Resources/deployments/#{name}"
        else
          "/subscriptions/#{sub}/providers/Microsoft.Resources/deployments/#{name}"
        end

      Smalt.ArmGateway.ActivityLog.record(conn, :write, dep_id, rg || "")

      send_json(conn, 200, Jason.encode!(m))
    else
      {:error, st, err} -> send_json(conn, st, Jason.encode!(%{error: err}))
    end
  end

  defp deployments_body(conn) do
    if is_map(conn.body_params),
      do: {:ok, conn.body_params},
      else: {:error, 400, %{code: "InvalidBody", message: "request body must be a JSON object"}}
  end

  defp deployments_validate(conn, _sub, _rg, _name) do
    with {:ok, raw} <- deployments_body(conn),
         {:ok, :valid} <- Smalt.Arm.Deployments.validate_deployment(raw) do
      # DIVERGENCE lane D4 (2026-10-25): documented success face is
      # DeploymentValidateResult {properties: DeploymentPropertiesExtended}
      # — no top-level status. provisioningState Succeeded is the documented
      # success member (validate writes nothing, so no timestamps/correlation).
      send_json(
        conn,
        200,
        Jason.encode!(%{
          properties: %{
            provisioningState: "Succeeded",
            mode: raw["properties"]["mode"] || "Incremental"
          }
        })
      )
    else
      {:error, st, err} -> send_json(conn, st, Jason.encode!(%{error: err}))
    end
  end

  defp deployments_what_if(conn, sub, rg, name) do
    with {:ok, raw} <- deployments_body(conn) do
      props = raw["properties"] || %{}
      template = props["template"] || %{}
      mode = props["mode"] || "Incremental"

      case Smalt.Arm.Deployments.what_if(template, props["parameters"] || %{},
             sub: sub,
             rg: rg,
             mode: mode
           ) do
        {:ok, result} ->
          wire =
            {:ok, result}
            |> Smalt.Arm.Deployments.what_if_wire()
            |> Map.update!("properties", &Map.put(&1, "status", result["status"]))

          dep_link =
            if rg do
              "/subscriptions/#{sub}/resourceGroups/#{rg}/providers/Microsoft.Resources/deployments/#{name}"
            else
              "/subscriptions/#{sub}/providers/Microsoft.Resources/deployments/#{name}"
            end

          conn
          |> put_resp_header("location", dep_link)
          |> send_json(200, Jason.encode!(wire))

        {:error, st, err} ->
          send_json(conn, st, Jason.encode!(%{error: err}))
      end
    else
      {:error, st, err} -> send_json(conn, st, Jason.encode!(%{error: err}))
    end
  end

  defp deployments_get(conn, sub, rg, name) do
    case Smalt.Arm.Deployments.get_deployment(sub, rg, name) do
      {:ok, m} -> send_json(conn, 200, Jason.encode!(m))
      {:error, st, err} -> send_json(conn, st, Jason.encode!(%{error: err}))
    end
  end

  defp deployments_list(conn, sub, rg) do
    {:ok, items} = Smalt.Arm.Deployments.list_deployments(sub, rg)
    send_json(conn, 200, Jason.encode!(%{value: items}))
  end

  defp deployments_delete(conn, sub, rg, name) do
    case Smalt.Arm.Deployments.delete_deployment(sub, rg, name) do
      {:ok, :deleted} -> send_json(conn, 200, Jason.encode!(%{status: "Succeeded"}))
      {:error, st, err} -> send_json(conn, st, Jason.encode!(%{error: err}))
    end
  end

  defp deployments_ops(conn, sub, rg, name) do
    case Smalt.Arm.Deployments.list_operations(sub, rg, name) do
      {:ok, items} -> send_json(conn, 200, Jason.encode!(%{value: items}))
      {:error, st, err} -> send_json(conn, st, Jason.encode!(%{error: err}))
    end
  end

  # KD-COVERS: KD-51 — flat Service Bus ATOM management URL space over HTTPS.
  # azure-servicebus >= 7.x ServiceBusAdministrationClient hardcodes
  # `https://` as the management endpoint scheme (_management_client.py:
  # `self._endpoint = "https://" <> fully_qualified_namespace`), so the sb://
  # -port ATOM plane (Smalt.Amqp.AtomBridge serve/2) is unreachable from the
  # Python admin client: PUT /{queue} landed on this router's catch-all as
  # 404 RouteNotFound (witness: docs/jira/v26.10.20/receipts/kd51-admin-urlspace-witness.md,
  # captured `PUT https://localhost:9444/{queue}?api-version=2024-05`).
  # These alias routes serve the SAME flat dispatcher (identical records in
  # :smalt_resources, identical ATOM+XML rendering) on the control plane and
  # its TLS twin. Declared last, before the catch-all: every earlier static
  # route keeps precedence, so single-segment faces like /tenant, /tenants,
  # /subscriptions and /healthz are unaffected.
  # T27LQ-r (KD-158 candidate): the node ServiceBusAdministrationClient
  # listQueues face sends GET /$Resources/Queues?api-version=...&$top=N&$skip=M
  # — a TWO-segment path, which never matched the single-segment flat aliases
  # below and fell through to the catch-all as 404 RouteNotFound (wire repro:
  # docs/jira/v26.10.20/receipts/t27lqr-listqueues-paging-witness.md). The
  # $Resources paged-list face forwards to the SAME flat dispatcher; declared
  # before the catch-all like the other aliases.
  get "/$Resources/:resource" do
    sb_atom_alias(conn, "GET", conn.request_path)
  end

  put "/:entity_name" do
    sb_atom_alias(conn, "PUT", conn.request_path)
  end

  get "/:entity_name" do
    sb_atom_alias(conn, "GET", conn.request_path)
  end

  delete "/:entity_name" do
    sb_atom_alias(conn, "DELETE", conn.request_path)
  end

  defp sb_atom_alias(conn, method, path) do
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
