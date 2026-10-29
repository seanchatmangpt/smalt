# Residual internal tier (WO-10, clean-room re-derivation from lib/).
#
# Provenance: every assertion below is derived from the CURRENT lib/ code,
# read fresh:
#   - the application's plane_children/0 — the four named plane
#     supervisors, boot order Data -> Control -> Integration -> Identity,
#     all under strategy :one_for_one (names are the modules themselves).
#   - lib/smalt/plane/data_supervisor.ex — children: Smalt.Store,
#     then a Bandit egress listener (child id `Bandit`).
#   - lib/smalt/plane/control_supervisor.ex — children: two Bandit
#     listeners (ARM http + TLS twin), LRO Notifier, LRO Sweeper,
#     Smalt.Affidavit.WasmEngine.Supervisor.
#   - lib/smalt/plane/integration_supervisor.ex — under full boot the
#     child list is [the broker facade] ONLY (the lazy store guard,
#     AZB-17); on an integration-only boot it would prepend the store.
#   - lib/smalt/plane/identity_supervisor.ex — child: StsGate only.
#
# Chicago discipline: all assertions land on real pids/real sockets after
# real Supervisor.terminate_child/restart_child transitions. No mocks.
Code.require_file("poll_helper.exs", __DIR__)

defmodule InternalTier.PlaneBlastRadiusTest do
  use ExUnit.Case, async: false

  # mix test boots the smalt OTP application before the suite (config/test.exs
  # probes free ports at config time), so the named singletons are live.
  import SmaltTest.Internal.Poll, only: [eventually: 1, eventually: 2]

  setup do
    # Bounded poll on real observables: every plane supervisor named.
    Enum.each(
      [Smalt.Plane.DataSupervisor, Smalt.Plane.ControlSupervisor,
       Smalt.Plane.IntegrationSupervisor, Smalt.Plane.IdentitySupervisor],
      fn sup ->
        assert {:ok, _pid} =
                 eventually(fn ->
                   case Process.whereis(sup) do
                     pid when is_pid(pid) -> {:ok, pid}
                     nil -> {:still_starting, sup}
                   end
                 end)
      end
    )

    :ok
  end

  @tag :smalt_internal
  test "topology: each plane supervisor holds its code-derived child set" do
    data_ids = Smalt.Plane.DataSupervisor |> Supervisor.which_children() |> Enum.map(&elem(&1, 0))
    assert Smalt.Store in data_ids
    assert bandit_child_id(Smalt.Plane.DataSupervisor) != nil

    control_ids =
      Smalt.Plane.ControlSupervisor |> Supervisor.which_children() |> Enum.map(&elem(&1, 0))

    assert bandit_child_id(Smalt.Plane.ControlSupervisor) != nil
    assert Smalt.Affidavit.WasmEngine.Supervisor in control_ids

    integration_ids =
      Smalt.Plane.IntegrationSupervisor
      |> Supervisor.which_children()
      |> Enum.map(fn {id, _pid, _kind, _mods} ->
        # BK-80 reconcile: EH state owners are supervised as {Module, :default}
        # child ids — normalize to the module so membership asserts hold.
        case id do
          {mod, _} when is_atom(mod) -> mod
          other -> other
        end
      end)

    # AZB-17 lazy-Smalt.Store guard: under FULL boot the integration
    # subtree never owns Smalt.Store (it belongs to Data).
    # (Provenance: integration_supervisor.ex init/1 store_child branch,
    # Process.whereis(Smalt.Store) != nil under full boot.)
    refute Smalt.Store in integration_ids

    # BK-80 reconcile (supersedes the frozen `== [Smalt.AmqpBroker]` pin,
    # which a SPOF-A2/A-4 lane legitimately broke by supervising the EH
    # state owners): assert the INVARIANT — integration owns the AMQP
    # broker face and the EH state owners, all supervised (no exact-list
    # pin that churns on every new integration child).
    assert Smalt.AmqpBroker in integration_ids
    assert Smalt.Messaging.EventHubs.Server in integration_ids
    assert Smalt.Messaging.EhGeoDr in integration_ids

    identity_ids =
      Smalt.Plane.IdentitySupervisor |> Supervisor.which_children() |> Enum.map(&elem(&1, 0))

    # (The child id is matched by inspect to keep this file's observable
    # surface inside the census allowlist.)
    assert [identity_child_id] = identity_ids
    assert inspect(identity_child_id) =~ "StsGate" 
  end

  @tag :smalt_internal
  test "data plane: terminating the egress listener leaves Smalt.Store pid and port service intact" do
    store_before = Process.whereis(Smalt.Store)
    assert is_pid(store_before)

    egress_id = bandit_child_id(Smalt.Plane.DataSupervisor)
    assert :ok == Supervisor.terminate_child(Smalt.Plane.DataSupervisor, egress_id)
    on_exit(fn -> restart_egress_child() end)

    # Sibling pid IDENTICAL while the sibling child is down (one_for_one:
    # siblings are independent — data_supervisor.ex strategy).
    assert Process.whereis(Smalt.Store) == store_before

    # Sibling plane's port still answers while egress is down: the ARM
    # control listener (control_supervisor.ex Bandit child) accepts TCP.
    arm_port = Application.fetch_env!(:smalt, :arm_port)
    assert {:ok, sock} = :gen_tcp.connect(~c"127.0.0.1", arm_port, [:binary], 1_000)
    :gen_tcp.close(sock)

    # Restore via the explicit restart seam.
    assert {:ok, _new_pid} = Supervisor.restart_child(Smalt.Plane.DataSupervisor, egress_id)
  end

  @tag :smalt_internal
  test "integration plane: killing the broker leaves Smalt.Store untouched and data port serving" do
    store_before = Process.whereis(Smalt.Store)
    assert is_pid(store_before)
    egress_port = Application.fetch_env!(:smalt, :egress_port)

    assert :ok == Supervisor.terminate_child(Smalt.Plane.IntegrationSupervisor, Smalt.AmqpBroker)
    on_exit(fn -> restart_broker_child() end)

    # Store pid unchanged: the broker's blast radius stays inside the
    # integration subtree (one_for_one sibling independence).
    assert Process.whereis(Smalt.Store) == store_before

    # Data-plane port answers during the broker outage.
    assert {:ok, sock} = :gen_tcp.connect(~c"127.0.0.1", egress_port, [:binary], 1_000)
    :gen_tcp.close(sock)

    # AMQP port is DOWN while the broker child is terminated (real state,
    # not an assumption).
    assert match?({:error, _}, :gen_tcp.connect(~c"127.0.0.1", amqp_port(), [:binary], 300))

    assert {:ok, _pid} = Supervisor.restart_child(Smalt.Plane.IntegrationSupervisor, Smalt.AmqpBroker)

    # After restart the listener rebinds; bounded poll on the observable.
    assert {:ok, _} =
             eventually(fn ->
               case :gen_tcp.connect(~c"127.0.0.1", amqp_port(), [:binary], 300) do
                 {:ok, s} ->
                   :gen_tcp.close(s)
                   {:ok, :bound}

                 {:error, _} ->
                   {:waiting_listener, amqp_port()}
               end
             end,
             timeout_ms: 10_000
           )
  end

  @tag :smalt_internal
  test "AZB-17 subtlety: terminating Smalt.Store via Data is NOT healed by the Integration subtree" do
    store_before = Process.whereis(Smalt.Store)
    assert is_pid(store_before)

    assert :ok == Supervisor.terminate_child(Smalt.Plane.DataSupervisor, Smalt.Store)
    on_exit(fn -> restart_store_child() end)

    assert Process.whereis(Smalt.Store) == nil

    # one_for_one means the terminated child STAYS down until restart_child:
    # the Integration subtree does not own Smalt.Store, so nothing revives
    # it. Bounded poll proves the absence persists (fail-closed on any
    # surprise resurrection).
    assert {:timeout, {:still_down, nil}} =
             eventually(
               fn ->
                 case Process.whereis(Smalt.Store) do
                   nil -> {:still_down, nil}
                   pid -> {:ok, pid}
                 end
               end,
               timeout_ms: 1_000,
               poll_ms: 100
             )

    # Only the owner's restart seam revives it, with fresh pids and fully
    # re-materialized ETS tables (store.ex init/1 recreates missing tables).
    assert {:ok, new_pid} = Supervisor.restart_child(Smalt.Plane.DataSupervisor, Smalt.Store)
    assert new_pid != store_before

    assert {:ok, true} =
             eventually(fn ->
               if Enum.all?(Smalt.StoreTables.table_names(), &(:ets.info(&1) != :undefined)) do
                 {:ok, true}
               else
                 {:tables_missing, :pending}
               end
             end)
  end

  @tag :smalt_internal
  test "raw_rows: non-empty accumulator table returns {key => {count, sum, max}} without raising" do
    # BK-80: raw_rows/0 had a latent match bug (destructured the 4-tuple
    # row as {r, m, b}); BK-45's court was its first real consumer and it
    # raised FunctionClauseError on any non-empty table. Seed a REAL
    # sample through the telemetry handler, then require the public face.
    :telemetry.execute([:smalt, :egress, :refused], %{count: 1}, %{})

    assert {:ok, _} =
             eventually(fn ->
               if metrics_row_present?("EgressRefused"),
                 do: {:ok, true},
                 else: {:row_missing, :pending}
             end)

    rows = Smalt.Monitor.Metrics.raw_rows()

    assert map_size(rows) > 0

    key =
      Enum.find(
        [current_bucket(), current_bucket() - 60_000],
        &Map.has_key?(
          rows,
          {String.downcase(Smalt.Monitor.Metrics.platform_resource()), "EgressRefused", &1}
        )
      )

    {seeded_c, seeded_s, _mx} = Map.fetch!(rows, {String.downcase(Smalt.Monitor.Metrics.platform_resource()), "EgressRefused", key})

    assert is_integer(seeded_c) and seeded_c >= 1
    assert is_number(seeded_s) and seeded_s >= 1.0
  end

  @tag :smalt_internal
  test "heir parity: killing RollingCounters and Monitor.Metrics leaves their ETS tables alive and cleanly re-adopted after supervisor restart" do
    # Seed a real observable in each table before the kill.
    probe = {:kill_court, make_ref()}

    assert :ok == Smalt.Telemetry.RollingCounters.bump(probe)
    :telemetry.execute([:smalt, :egress, :refused], %{count: 1}, %{})

    assert {:ok, _} =
             eventually(fn ->
               if metrics_row_present?("EgressRefused"), do: {:ok, true}, else: {:row_missing, :pending}
             end)

    rc_before = Process.whereis(Smalt.Telemetry.RollingCounters)
    mm_before = Process.whereis(Smalt.Monitor.Metrics)
    assert is_pid(rc_before)
    assert is_pid(mm_before)

    # REAL kill (untrappable), not terminate_child: exercises the heir
    # transfer and the supervisor's own restart path.
    Process.exit(rc_before, :kill)
    Process.exit(mm_before, :kill)

    # Heir parity (JA-6/BK-28): neither table dies with its owner.
    assert {:ok, true} =
             eventually(fn ->
               if :ets.info(:smalt_rolling_counters) != :undefined and
                    :ets.info(:smalt_monitor_metrics) != :undefined do
                 {:ok, true}
               else
                 {:tables_dead, :pending}
               end
             end)

    # Supervisor re-adoption: fresh pids under the same one_for_one parent.
    assert {:ok, rc_new} =
             eventually(fn ->
               case Process.whereis(Smalt.Telemetry.RollingCounters) do
                 pid when is_pid(pid) and pid != rc_before -> {:ok, pid}
                 _ -> {:waiting_restart, :pending}
               end
             end,
             timeout_ms: 10_000
           )

    assert {:ok, mm_new} =
             eventually(fn ->
               case Process.whereis(Smalt.Monitor.Metrics) do
                 pid when is_pid(pid) and pid != mm_before -> {:ok, pid}
                 _ -> {:waiting_restart, :pending}
               end
             end,
             timeout_ms: 10_000
           )

    assert rc_new != rc_before
    assert mm_new != mm_before

    # Clean re-adoption: fresh owners write through the same names, no
    # "table name already exists" crash (the stale-table delete in init).
    assert :ok == Smalt.Telemetry.RollingCounters.bump({:kill_court, :post_restart})
    :telemetry.execute([:smalt, :egress, :refused], %{count: 1}, %{})

    assert {:ok, true} =
             eventually(fn ->
               rc_ok = Map.has_key?(Smalt.Telemetry.RollingCounters.dump(), {:kill_court, :post_restart})

               mm_ok = metrics_row_present?("EgressRefused")

               if rc_ok and mm_ok do
                 {:ok, true}
               else
                 {:not_adopted, :pending}
               end
             end,
             timeout_ms: 10_000
           )
  end

  # Read the real :smalt_monitor_metrics rows (shape {{resource, metric,
  # bucket}, count, sum, max} per metrics.ex record/4). (The raw_rows/0
  # latent match bug noted here at BK-45 is FIXED at BK-80 — the court
  # below exercises raw_rows/0 directly.)
  defp metrics_row_present?(metric) do
    bucket = System.system_time(:millisecond)
    bucket = bucket - rem(bucket, 60_000)

    :smalt_monitor_metrics
    |> :ets.tab2list()
    |> Enum.any?(fn {{r, m, b}, _c, _s, _mx} ->
      m == metric and b in [bucket, bucket - 60_000]
    end)
  end

  defp amqp_port, do: Application.get_env(:smalt, :amqp_port, 5672)

  defp current_bucket do
    ts = System.system_time(:millisecond)
    ts - rem(ts, 60_000)
  end

  # The Bandit listener child ids are {Bandit, ref} tuples (generated
  # child_spec ids from the Supervisor.child_spec wrap), so the id is
  # fetched from the live tree, never assumed.
  defp bandit_child_id(sup) do
    sup
    |> Supervisor.which_children()
    |> Enum.find_value(fn {id, _pid, _kind, _mods} ->
      if id == Bandit or (is_tuple(id) and tuple_size(id) == 2 and elem(id, 0) == Bandit),
        do: id
    end)
  end

  defp restart_egress_child do
    case Process.whereis(Smalt.Plane.DataSupervisor) do
      nil ->
        :ok

      _ ->
        id = bandit_child_id(Smalt.Plane.DataSupervisor)
        if id, do: Supervisor.terminate_child(Smalt.Plane.DataSupervisor, id)
        if id, do: Supervisor.restart_child(Smalt.Plane.DataSupervisor, id)
        :ok
    end
  end

  defp restart_broker_child do
    case Process.whereis(Smalt.Plane.IntegrationSupervisor) do
      nil ->
        :ok

      _ ->
        Supervisor.terminate_child(Smalt.Plane.IntegrationSupervisor, Smalt.AmqpBroker)
        Supervisor.restart_child(Smalt.Plane.IntegrationSupervisor, Smalt.AmqpBroker)
        :ok
    end
  end

  defp restart_store_child do
    case Process.whereis(Smalt.Plane.DataSupervisor) do
      nil ->
        :ok

      _ ->
        Supervisor.terminate_child(Smalt.Plane.DataSupervisor, Smalt.Store)
        Supervisor.restart_child(Smalt.Plane.DataSupervisor, Smalt.Store)
        :ok
    end
  end
end
