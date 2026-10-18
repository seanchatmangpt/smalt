defmodule Smalt.Application do
  @moduledoc false
  use Application

  @impl true
  def start(_type, _args) do
    children =
      [
        Smalt.Store,
        {Bandit, plug: Smalt.ArmGateway.Router, scheme: :http, port: arm_port(), ip: bind_ip()},
        # TLS twin of the ARM gateway (https), for https-only clients such as
        # azurerm's ARM_METADATA_HOST fetch, which hardcodes the https scheme.
        # Also serves the Key Vault data-plane surface (/keys/*) over TLS so
        # real Key Vault SDKs (azure-keyvault-keys, azure-security-keyvault-*)
        # — which refuse plaintext http — can complete key create/get/release
        # against the local substrate. Disclosed: listener wiring touches
        # application.ex (owned by another lane); additive single child, cert
        # via Smalt.TLS.ensure_dev_cert/0.
        {Bandit, arm_tls_opts() ++ [ip: bind_ip()]},
        {Bandit, plug: Smalt.EgressRouter, scheme: :http, port: egress_port(), ip: bind_ip()},
        # MCP read-only tool surface (lane I15): JSON-RPC 2.0, actuation
        # refused by the router's @actuation_fragments gate (SHIM-COURT:
        # unregistered+verb id -> ACTUATION_REFUSED; other unknown id ->
        # TOOL_NOT_FOUND; registered ids via Descriptor.describe/1) — no DO
        # from MCP.
        {Bandit,
         plug: {Smalt.Mcp.Router, []},
         scheme: :http,
         port: Application.get_env(:smalt, :mcp_port, 9545),
         ip: bind_ip()},
        {Smalt.AmqpBroker, []},
        Smalt.Telemetry.RollingCounters,
        # ARM LRO at-rest sweeper (lane 05, V261014-05 — disclosed additive
        # child, application.ex shared this wave): closes
        # GAP(lro-lazy-terminality) by driving terminal flips without a poll,
        # plus opt-in :lro_retention_ms eviction (default :infinity).
        # v26.10.18 one-writer redesign: the sweeper is the SINGLE terminal
        # writer; the Notifier (before it, so it is up first) is its explicit
        # completion-signal hub for LRO.await waiters.
        Smalt.ArmGateway.LRO.Notifier,
        Smalt.ArmGateway.LRO.Sweeper,
        # Supervised WasmEngine restart envelope (v26.10.18 lib redesign
        # Part 1, disclosed additive child): one_for_one 3/1s around an
        # owner GenServer that start_links + monitors the named engine and
        # owns every retry in its own mailbox (zero caller-path sleeps;
        # engine module is structurally sleep-free, fence 10).
        Smalt.Affidavit.WasmEngine.Supervisor
        # HIL virtual device (lane S-5): opt-in only via SMALT_SIMULATE_HARDWARE=1
        # — default startup is untouched (child spec is [] when unset).
        | virtual_hw_child()
      ]

    Smalt.Telemetry.attach()

    # NOTE (lane 2 compile-unblock, disclosed): EventHubs.Listener is already a
    # child of the Smalt.AmqpBroker supervisor (amqp_broker.ex) — starting it
    # here too crashed app boot with "already started" for every mix test run.
    # Smalt.AmqpBroker owns it.

    opts = [strategy: :one_for_one, name: Smalt.Supervisor]
    Supervisor.start_link(children, opts)
  end

  # Virtual HIL device child spec — [] unless SMALT_SIMULATE_HARDWARE=1.
  # Optional :device_path attachment additionally via SMALT_HW_PTY.
  defp virtual_hw_child do
    if System.get_env("SMALT_SIMULATE_HARDWARE") == "1" do
      path = System.get_env("SMALT_HW_PTY")

      if is_binary(path) do
        [{Smalt.Hw.VirtualSerial, [device_path: path]}]
      else
        [{Smalt.Hw.VirtualSerial, []}]
      end
    else
      []
    end
  end

  # W1a exemplar (plain-default class): default copy now lives ONLY in the
  # ontology (smalt:ck-arm-port) via the Smalt.Config projection.
  defp arm_port, do: Smalt.Config.arm_port()

  # Default bind: loopback only. This is a local air-gapped
  # emulator — binding 0.0.0.0 by default exposed every surface to the LAN.
  # Override for LAN SDK testing via SMALT_BIND_IP (e.g. SMALT_BIND_IP=0.0.0.0)
  # or `config :smalt, bind_ip: {192,168,1,10}`.
  # KD-COVERS: KD-54
  defp bind_ip do
    # W1a exemplar (env-first class): the accessor mirrors the SMALT_BIND_IP
    # override order exactly; the app-env nilable default lives in the ontology.
    case Smalt.Config.bind_ip() do
      nil ->
        {127, 0, 0, 1}

      "loopback" ->
        {127, 0, 0, 1}

      str when is_binary(str) ->
        case :inet.parse_address(String.to_charlist(str)) do
          {:ok, ip} ->
            ip

          {:error, _} ->
            raise ArgumentError,
                  "SMALT_BIND_IP=#{str} is not a valid IPv4/IPv6 address"
        end

      ip when is_tuple(ip) ->
        # KD-COVERS: KD-54 — config-tuple branch validated with the same
        # strictness as the :inet.parse_address string path (fail-closed at boot).
        valid? =
          case ip do
            {a, b, c, d} when a in 0..255 and b in 0..255 and c in 0..255 and d in 0..255 ->
              true

            {a, b, c, d, e, f, g, h}
            when a in 0..0xFFFF and b in 0..0xFFFF and c in 0..0xFFFF and d in 0..0xFFFF and
                   e in 0..0xFFFF and f in 0..0xFFFF and g in 0..0xFFFF and h in 0..0xFFFF ->
              true

            _ ->
              false
          end

        if valid? do
          ip
        else
          raise ArgumentError,
                "config :smalt, bind_ip: #{inspect(ip)} is not a valid IPv4/IPv6 address"
        end
    end
  end

  defp arm_tls_port, do: Application.get_env(:smalt, :arm_tls_port, 9444)

  # TLS twin dispatch: ARM paths to ArmGateway.Router, Key Vault / data-plane
  # egress paths to EgressRouter. Plug.Cascade is NOT usable here: both routers
  # define a catch-all `match _` that *sends* a 404, so cascade would stop at
  # the first router's 404 instead of falling through. Dispatch is by top-level
  # path prefix. Egress owns `/attest`, `/app`, `/dbs`, `/keys`, `/topics`,
  # `/atlas`, `/dataCollectionRules`, `/v1`, `/providers` — none of which are
  # ARM top-level prefixes on this host (ARM nests its `/providers` only under
  # `/subscriptions/...`). The blob guarded catch-all (`/{account}/{container}`)
  # stays reachable on http 8443 only; it is out of scope for the TLS twin.
  defmodule TlsTwinDispatch do
    @moduledoc false

    @egress_prefixes [
      "/attest/",
      "/app/",
      "/dbs/",
      "/keys",
      "/secrets",
      "/kv",
      "/topics/",
      "/atlas/",
      "/dataCollectionRules",
      "/v1/",
      "/providers/"
    ]

    def init(opts), do: opts

    def call(%Plug.Conn{request_path: path} = conn, _opts) do
      router =
        if Enum.any?(@egress_prefixes, &String.starts_with?(path, &1)),
          do: Smalt.EgressRouter,
          else: Smalt.ArmGateway.Router

      router.call(conn, [])
    end
  end

  # TLS twin of the ARM gateway. Cert material comes from SMALT_TLS_CERTFILE /
  # SMALT_TLS_KEYFILE (minted by scripts/gen_dev_cert.sh) when set, else the
  # Smalt.TLS dev-cert path. Falls back to :http when no cert is available.
  # R90/D52: cert resolution (env pair first, config pair, dev-cert) and the
  # unconditional TLS 1.2 + cipher pin now live in Smalt.TLS.bandit_opts/2;
  # this is the single call site (repair lane R123: no KD row — internal
  # reduction, not a divergence).
  defp arm_tls_opts do
    Smalt.TLS.bandit_opts(TlsTwinDispatch, arm_tls_port())
  end

  defp egress_port, do: Application.get_env(:smalt, :egress_port, 8443)
end
