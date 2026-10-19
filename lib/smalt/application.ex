defmodule Smalt.Application do
  @moduledoc false
  use Application

  @impl true
  def start(_type, _args) do
    # AZB-09: Plane-scoped supervision subtrees.
    # Shared top-level infra: RollingCounters, MCP router, and HIL virtual hardware.
    # Planes: Data, Control, Integration, Identity subtrees.
    children =
      plane_children() ++
      [
        Smalt.Telemetry.RollingCounters,
        mcp_bandit_child()
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

  # AZB-22b: bound graceful-stop on the MCP listener (see plane supervisors;
  # a stuck ThousandIsland listener hung tree stop >60s in the burn ring).
  @doc false
  def mcp_bandit_child do
    Supervisor.child_spec(
      {Bandit,
       plug: {Smalt.Mcp.Router, []},
       scheme: :http,
       port: Application.get_env(:smalt, :mcp_port, 9545),
       ip: bind_ip()},
      shutdown: 10_000
    )
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

  # AZB-09: Partitioned plane supervisors preserving boot order:
  # Data (Store) -> Control (ARM + Sweeper) -> Integration (AMQP) -> Identity
  defp plane_children do
    case Application.get_env(:smalt, :planes, :all) do
      :all ->
        [
          Smalt.Plane.DataSupervisor,
          Smalt.Plane.ControlSupervisor,
          Smalt.Plane.IntegrationSupervisor,
          Smalt.Plane.IdentitySupervisor
        ]

      planes when is_list(planes) ->
        Enum.flat_map(planes, fn
          :data -> [Smalt.Plane.DataSupervisor]
          :control -> [Smalt.Plane.ControlSupervisor]
          :integration -> [Smalt.Plane.IntegrationSupervisor]
          :identity -> [Smalt.Plane.IdentitySupervisor]
          _ -> []
        end)
    end
  end

end
