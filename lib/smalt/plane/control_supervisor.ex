defmodule Smalt.Plane.ControlSupervisor do
  @moduledoc """
  Supervision subtree for the Control Plane:
  - ARM Gateway HTTP router (9443) — front door (starts first)
  - ARM Gateway TLS twin (9444) — deferred listener under :deferred_listeners
  - LRO Notifier and Sweeper
  - WasmEngine Supervisor
  """
  use Supervisor

  def start_link(init_arg) do
    Supervisor.start_link(__MODULE__, init_arg, name: __MODULE__)
  end

  @impl true
  def init(_init_arg) do
    children =
      store_child() ++
        [
          # AZB-22b: bound graceful-stop on every Bandit listener (default for
          # a type :supervisor child is :infinity; a stuck ThousandIsland
          # listener hung the tree's stop >60s in the burn ring).
          Supervisor.child_spec(
            # AZURE-FIDELITY lane 18: latency realism on the ARM control plane.
            # Gate-off cost is ONE Application.get_env, then straight to the
            # router (same posture as the egress listener in DataSupervisor).
            {Bandit,
             plug: {Smalt.Egress.LatencyPlug, [router: Smalt.ArmGateway.Router]},
             scheme: :http,
             port: arm_port(),
             ip: bind_ip()},
            shutdown: 10_000
          ),
          Smalt.ArmGateway.LRO.Notifier,
          Smalt.ArmGateway.LRO.Sweeper,
          Smalt.Affidavit.WasmEngine.Supervisor
        ] ++ wasm_pool_child()

    children =
      if Smalt.Application.deferred_listeners?() do
        # BOOTPROF cut #2 (RELCUT, NFR-FOOTPRINT): the TLS twin (9444) is a
        # deferred listener - it starts on the next scheduler tick (see
        # handle_info) so the ARM front door (9443) binds and accepts first.
        children
      else
        children ++ [tls_twin_child()]
      end

    spec =
      Supervisor.init(children, strategy: :one_for_one, max_restarts: 5, max_seconds: 5)

    spec
  end

  # BOOTPROF cut #2: deferred TLS-twin start, invoked by
  # Smalt.Application.ListenerDeferral on the tick after the front door
  # (ARM 9443) is already bound and accepting.
  @doc false
  def start_deferred_listener do
    Supervisor.start_child(__MODULE__, tls_twin_child())
  end

  # BK-110 / SPOF-A A-7: Smalt.Wasm.Pool has a real production consumer
  # (EgressRouter -> SyncRoutes -> Sync.Guard -> Wasm.Bridge -> Pool.checkout)
  # but no supervised start site. Config-gated (default OFF) so the default
  # boot stays byte-identical; the :wasm governance face gets a supervised
  # pool instead of a first-caller-linked one.
  defp wasm_pool_child do
    if Application.get_env(:smalt, :sync_guard) == :wasm do
      [Smalt.Wasm.Pool]
    else
      []
    end
  end

  # GAP-AZB20-1/4 Option A: on a control-only boot (`SMALT_PLANES=control` or
  # any plane list without :data), `Smalt.Store` never started, so
  # `:smalt_resources` etc. were undefined — ARM handlers dereferenced Store
  # unguarded (ArgumentError -> naked 500) and EgressRouter answered 503
  # RouteNotReady. Store.init is idempotent (creates each table only when
  # :ets.info/1 == :undefined, lib/smalt/store.ex:29-43), so prepending is a
  # no-op double-start risk on :all / data-inclusive boots — hence the guard.
  defp store_child do
    planes = Application.get_env(:smalt, :planes, :all)

    case planes do
      :all ->
        []

      list when is_list(list) ->
        # Compile-freeze unblock (lane verification/py, disclosed): `:data in
        # list` is not a legal guard over a runtime list (Elixir 1.19 raises
        # ArgumentError at compile). Same semantics via Enum.member?.
        # prepend FIRST: Store tables must exist before the ARM listener serves
        if Enum.member?(list, :data), do: [], else: [Smalt.Store]

      _ ->
        [Smalt.Store]
    end
  end

  defp arm_port, do: Smalt.Config.arm_port()
  defp arm_tls_port, do: Application.get_env(:smalt, :arm_tls_port, 9444)

  defp arm_tls_opts do
    Smalt.TLS.bandit_opts(Smalt.Application.TlsTwinDispatch, arm_tls_port())
  end

  defp tls_twin_child do
    # AZB-22b: bound graceful-stop on every Bandit listener.
    Supervisor.child_spec(
      {Bandit, arm_tls_opts() ++ [ip: bind_ip()]},
      shutdown: 10_000
    )
  end

  defp bind_ip do
    case Application.get_env(:smalt, :bind_all_interfaces, false) do
      true -> {0, 0, 0, 0}
      _ -> {127, 0, 0, 1}
    end
  end
end
