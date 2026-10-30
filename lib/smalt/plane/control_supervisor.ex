defmodule Smalt.Plane.ControlSupervisor do
  @moduledoc """
  Supervision subtree for the Control Plane:
  - Standards admission engine (Smalt.Posh.*) — the control-plane face
  - LRO Notifier and Sweeper (serve the CORE vendor-neutral LRO state
    machine, lib/smalt/lro.ex — wave-1 L3 ruling: they stay with core)
  - WasmEngine Supervisor

  v26.10.31 cordon (WO-32): the BEAM no longer binds 9443/9444. The ARM
  gateway listener (Bandit front door on 9443) and the ARM TLS twin (9444)
  are REMOVED — posh (Go membrane) owns the 9443 wire; the ARM router module
  remains callable in-process for dialect-conformance courts. LRO Notifier/Sweeper REMAIN (ruling documented: LRO record store
  + Sweeper/Notifier serve the vendor-neutral LRO state machine; only the
  ARM wire spelling leaves with the dialect).
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
          # v26.10.31 WO-32: the standards admission engine IS the control
          # plane now. Mounted with plane-namespaced names so a config-gated
          # standalone Smalt.Posh.Supervisor (application.ex posh_child) can
          # never collide on registered names.
          {Smalt.Posh.Supervisor,
           [
             name: __MODULE__.PoshEngine,
             ingress_name: __MODULE__.PoshIngress,
             egress_name: __MODULE__.PoshEgress,
             ring_name: __MODULE__.PoshRing,
             log_name: __MODULE__.PoshEventLog
           ]},
          Smalt.ArmGateway.LRO.Notifier,
          Smalt.ArmGateway.LRO.Sweeper,
          Smalt.Affidavit.WasmEngine.Supervisor
        ] ++ wasm_pool_child()

    # BOOTPROF cut #2 (RELCUT, NFR-FOOTPRINT): with the ARM listeners gone
    # there is no front door left to defer — the control plane has no
    # listener to start on a later tick. The seam is preserved as a typed
    # no-op so ListenerDeferral (application.ex) and the config gate
    # (:deferred_listeners) stay byte-identical in behavior.
    Supervisor.init(children, strategy: :one_for_one, max_restarts: 5, max_seconds: 5)
  end

  # BOOTPROF cut #2 seam (kept for ListenerDeferral compatibility): the ARM
  # front door (9443) and TLS twin (9444) are cordoned; there is no deferred
  # listener left in the control plane. Returns a typed no-op.
  @doc false
  def start_deferred_listener, do: {:ok, :none}

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
        # prepend FIRST: Store tables must exist before the control plane serves
        if Enum.member?(list, :data), do: [], else: [Smalt.Store]

      _ ->
        [Smalt.Store]
    end
  end
end
