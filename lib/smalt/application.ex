defmodule Smalt.Application do
  @moduledoc false
  use Application

  @impl true
  def start(_type, _args) do
    # AZB-09: Plane-scoped supervision subtrees.
    # Shared top-level infra: RollingCounters, MCP router, and HIL virtual hardware.
    # Planes: Data, Control, Integration, Identity subtrees.
    # BOOTPROF cut #2 (RELCUT, NFR-FOOTPRINT): phased listener start.
    # Default (deferred_listeners: false) is byte-identical current behavior —
    # MCP is a direct child. With :deferred_listeners true the MCP listener
    # (and every other deferred listener) starts on a 0 ms tick via
    # Smalt.Application.ListenerDeferral after the front-door planes serve.
    mcp_tail =
      if deferred_listeners?() do
        [deferred_listeners_child(), listener_deferral_child()]
      else
        [mcp_bandit_child()]
      end

    children =
      plane_children() ++
        [
          Smalt.Apim,
          Smalt.Telemetry.RollingCounters,
          Smalt.Monitor.Metrics
        ] ++ mcp_tail ++ virtual_hw_child() ++ journal_sink_child() ++ cluster_child()

    # SBKEY: a configured :sb_shared_key below SasVerifier's 32-byte floor is a
    # boot-config defect (M4: 12-byte key made CBS SAS signing impossible, real
    # clients got 401 INVALID_LOCAL_SAS). Refuse loudly here; nil boots on the
    # deterministic dev_env-derived key.
    :ok = Smalt.Amqp.SasVerifier.validate_boot_key!()

    Smalt.Telemetry.attach()

    # NOTE (lane 2 compile-unblock, disclosed): EventHubs.Listener is already a
    # child of the Smalt.AmqpBroker supervisor (amqp_broker.ex) — starting it
    # here too crashed app boot with "already started" for every mix test run.
    # Smalt.AmqpBroker owns it.

    opts = [strategy: :one_for_one, name: Smalt.Supervisor]
    Supervisor.start_link(children, opts)
  end

  # SJ-4: config-gated journal sink (default OFF — nil config starts no child,
  # byte-identical boot). Under :journal_sink_dir the named sink process backs
  # the OcelEmitter journal frames.
  defp journal_sink_child do
    case Application.get_env(:smalt, :journal_sink_dir) do
      nil ->
        []

      dir ->
        [
          Supervisor.child_spec({Smalt.Storage.JournalSink, dir: Path.expand(dir)},
            restart: :transient
          )
        ]
    end
  end

  # BK-110 / SPOF-A A-7: Smalt.Cluster's lawful start site. Config-gated
  # (default OFF — solo boots stay byte-identical); when enabled: true the
  # DNS poller is a permanent supervised child instead of first-caller-linked.
  defp cluster_child do
    if Application.get_env(:smalt, :cluster, []) |> Keyword.get(:enabled, false) do
      [Smalt.Cluster]
    else
      []
    end
  end

  # BOOTPROF cut #2: config gate for phased listener start.
  @doc false
  def deferred_listeners? do
    Application.get_env(:smalt, :deferred_listeners, false)
  end

  # Deferred-mode faces: DeferredListeners is the supervisor that will own
  # the MCP listener; ListenerDeferral is the GenServer that, on a single
  # 0 ms scheduler tick after the front-door planes are already serving,
  # starts every deferred listener under its owning supervisor. Default
  # mode starts neither child (byte-identical current behavior).
  defmodule DeferredListeners do
    @moduledoc false
    use Supervisor

    def start_link(_init_arg),
      do: Supervisor.start_link(__MODULE__, nil, name: __MODULE__)

    @impl true
    def init(nil), do: Supervisor.init([], strategy: :one_for_one)

    # BOOTPROF cut #2: deferred MCP start, invoked by ListenerDeferral.
    @doc false
    def start_deferred_listener do
      Supervisor.start_child(__MODULE__, Smalt.Application.mcp_bandit_child())
    end
  end

  defmodule ListenerDeferral do
    @moduledoc false
    use GenServer

    def start_link(_init_arg),
      do: GenServer.start_link(__MODULE__, nil, name: __MODULE__)

    @impl true
    def init(nil) do
      # SLEEP-CLASS: SCHEDULING - a single 0 ms scheduler tick, not a timed
      # wait: deferral fires on the message the runtime delivers next. No
      # fixed sleep anywhere on this path.
      Process.send_after(self(), :start_deferred_listeners, 0)
      {:ok, nil}
    end

    @impl true
    def handle_info(:start_deferred_listeners, state) do
      {:ok, _} = Smalt.Plane.ControlSupervisor.start_deferred_listener()
      {:ok, _} = Smalt.Plane.IntegrationSupervisor.start_deferred_listener()
      {:ok, _} = Smalt.Application.DeferredListeners.start_deferred_listener()
      {:stop, :shutdown, state}
    end
  end

  defp deferred_listeners_child do
    Supervisor.child_spec({Smalt.Application.DeferredListeners, nil}, shutdown: 10_000)
  end

  defp listener_deferral_child do
    Supervisor.child_spec({Smalt.Application.ListenerDeferral, nil}, shutdown: 5_000)
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
  # path prefix. Egress owns `/attest`, `/app`, `/dbs`, `/keys`, `/secrets`,
  # `/kv`, `/topics`, `/atlas`, `/dataCollectionRules`, `/v1`, `/providers`,
  # and the deleted-bundle recovery plane (`/deletedkeys`, `/deletedsecrets`,
  # `/deletedcertificates` — PY wf6 xfail: real-SDK LRO recovery rides these
  # on the twin) and the certificates plane (`/certificates` — KD-104: the
  # TLS twin leg is the one real Azure SDK CertificateClient requires) — none of which are
  # ARM top-level prefixes on this host EXCEPT `/providers` since GAP-AZB20-6:
  # the ARM router now owns `POST /providers/Microsoft.ResourceGraph/resources`
  # (first top-level /providers prefix on ARM); on the TLS twin that path still
  # routes to EgressRouter — same handler engine, so parity holds on both seats.
  #
  # KD-COVERS: KD-114 (blob data-plane on the twin seat) + KD-35 (bearer-bearing
  # egress planes ride the twin): the remaining twin gap is the storage
  # catch-all family — blob `/{account}/{container}/{blob}`, the queue plane and
  # the Files plane all live on arbitrary `/{account}/...` path shapes, so no
  # enumerable prefix can name them. Invert the default instead: paths that are
  # NOT an ARM-owned top-level prefix route to EgressRouter, whose guarded
  # catch-all + queue/file arms serve them exactly as on http 8443 (same
  # handler engine, byte-identical requests). ARM keeps its whole surface:
  # every ARM route is `/subscriptions[...]`-scoped or one of the identity/
  # tagging top-levels named in @arm_only_prefixes (oauth2 STS, tenant listing,
  # tagNames, metadata identity endpoint) — 404s under those stay ARM-shaped.
  defmodule TlsTwinDispatch do
    @moduledoc false

    # KD-COVERS: KD-117 (deleted-bundle recovery on the twin seat)
    @egress_prefixes [
      "/attest/",
      "/app/",
      "/dbs/",
      "/keys",
      "/secrets",
      "/certificates",
      "/kv",
      "/deletedkeys",
      "/deletedsecrets",
      "/deletedcertificates",
      "/topics/",
      "/atlas/",
      "/dataCollectionRules",
      "/v1/",
      "/providers/"
    ]

    # Top-level prefixes the ARM router exclusively owns on the twin seat
    # (everything else on ARM is /subscriptions-scoped). Anything not in here
    # and not in @egress_prefixes is storage catch-all shape → EgressRouter.
    @arm_only_prefixes [
      "/subscriptions",
      "/tagNames",
      "/tenants",
      "/metadata",
      "/oauth2"
    ]

    def init(opts), do: opts

    def call(%Plug.Conn{request_path: path} = conn, _opts) do
      # KD-COVERS: KD-117 (deleted-bundle recovery on the twin seat)
      # KD-COVERS: KD-114 — storage catch-all family on the twin seat.
      router =
        cond do
          Enum.any?(@egress_prefixes, &String.starts_with?(path, &1)) ->
            Smalt.EgressRouter

          Enum.any?(@arm_only_prefixes, &String.starts_with?(path, &1)) ->
            Smalt.ArmGateway.Router

          # POST /:tenant/oauth2/v2.0/token — tenant-scoped STS, ARM-owned.
          String.contains?(path, "/oauth2/") ->
            Smalt.ArmGateway.Router

          # KD-COVERS: KD-51 — the flat Service Bus ATOM management URL space
          # (PUT/GET/DELETE /{entity}?api-version=2024-05, /$Resources/...,
          # /$namespaceinfo) served by ArmGateway.Router's KD-51 alias routes.
          # Discriminator: every SB management call carries an ARM-style
          # `api-version=` query; storage-service requests (restype=/comp=)
          # never do, so the storage catch-all keeps every face it owns.
          String.contains?(conn.query_string, "api-version=") ->
            Smalt.ArmGateway.Router

          # Default flips from ArmGateway to EgressRouter (KD-114): unknown
          # non-ARM paths now hit the guarded storage catch-all (blob/queue/
          # file arms or its typed 404) exactly as on http 8443.
          true ->
            Smalt.EgressRouter
        end

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
