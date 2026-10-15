defmodule Smalt.Application do
  @moduledoc false
  use Application

  @impl true
  def start(_type, _args) do
    children =
      [
        Smalt.Store,
        {Bandit, plug: Smalt.ArmGateway.Router, scheme: :http, port: arm_port()},
        # TLS twin of the ARM gateway (https), for https-only clients such as
        # azurerm's ARM_METADATA_HOST fetch, which hardcodes the https scheme.
        # Also serves the Key Vault data-plane surface (/keys/*) over TLS so
        # real Key Vault SDKs (azure-keyvault-keys, azure-security-keyvault-*)
        # — which refuse plaintext http — can complete key create/get/release
        # against the local substrate. Disclosed: listener wiring touches
        # application.ex (owned by another lane); additive single child, cert
        # via Smalt.TLS.ensure_dev_cert/0.
        {Bandit, arm_tls_opts()},
        {Bandit, plug: Smalt.EgressRouter, scheme: :http, port: egress_port()},
        # MCP read-only tool surface (lane I15): JSON-RPC 2.0, actuation
        # refused by Descriptor.requires_authority?/1 — no DO from MCP.
        {Bandit, plug: {Smalt.Mcp.Router, []}, scheme: :http,
         port: Application.get_env(:smalt, :mcp_port, 9545)},
        {Smalt.AmqpBroker, []},
        Smalt.Telemetry.RollingCounters
      ]

    Smalt.Telemetry.attach()

    # NOTE (lane 2 compile-unblock, disclosed): EventHubs.Listener is already a
    # child of the Smalt.AmqpBroker supervisor (amqp_broker.ex) — starting it
    # here too crashed app boot with "already started" for every mix test run.
    # Smalt.AmqpBroker owns it.

    opts = [strategy: :one_for_one, name: Smalt.Supervisor]
    Supervisor.start_link(children, opts)
  end

  defp arm_port, do: Application.get_env(:smalt, :arm_port, 9443)
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
  defp arm_tls_opts do
    cert = System.get_env("SMALT_TLS_CERTFILE")
    key = System.get_env("SMALT_TLS_KEYFILE")

    if is_binary(cert) and is_binary(key) and File.regular?(cert) and File.regular?(key) do
      [
        plug: TlsTwinDispatch,
        port: arm_tls_port(),
        scheme: :https,
        # TLS 1.2 only: recent Go clients (azurerm/azidentity) offer
        # X25519MLKEM768 key shares that the OTP 28 ssl app rejects, killing
        # the handshake before the cert is even evaluated. Go falls back to
        # TLS 1.2 + ECDHE-RSA happily.
        thousand_island_options: [
          transport_options: [
            versions: [:"tlsv1.2"],
            ciphers: [
              ~c"ECDHE-RSA-AES256-GCM-SHA384",
              ~c"ECDHE-RSA-AES128-GCM-SHA256"
            ],
            certfile: to_charlist(cert),
            keyfile: to_charlist(key)
          ]
        ]
      ]
    else
      Smalt.TLS.bandit_opts(TlsTwinDispatch, arm_tls_port())
    end
  end
  defp egress_port, do: Application.get_env(:smalt, :egress_port, 8443)
end
