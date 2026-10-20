# Residual internal tier (WO-10, clean-room re-derivation from lib/).
#
# Provenance (lib/ read fresh):
#   - lib/smalt/messaging/amqp_broker.ex: the broker facade supervises a
#     DynamicSupervisor named Smalt.AmqpBroker.ConnSup (conn_sup_name/0)
#     that owns one child per accepted connection; connection crashes are
#     contained there (:temporary children, :one_for_one).
#   - lib/smalt/messaging/amqp/queue_store.ex: Smalt.Amqp.QueueStore is a
#     LAZY named singleton — `start_link(opts \\ [])` names __MODULE__;
#     nothing in the plane supervisors owns it.
#   - lib/smalt/messaging/event_grid.ex: Smalt.Messaging.EventGrid is a
#     lazy named singleton — `start_link(_opts \\ [])` names __MODULE__.
#   - lib/smalt/security/ledger_writer.ex: Smalt.Security.LedgerWriter is
#     a lazy named singleton — `start_link(opts)` names __MODULE__ and
#     init/1 starts Smalt.Store only when it is not already running.
#   - lib/smalt/store.ex + lib/smalt/store_tables.ex: the Store owns the
#     generated table registry `Smalt.StoreTables.table_names/0`; shadow
#     tables are owner-managed and visible via `Smalt.StoreTables.all_tables/0`.
#
# Chicago discipline: real kills (Process.exit /2), real restarts, census
# on the real VM (:erlang.processes/0, :ets.all/0, :atom.all/0, real
# monitor links). Final state asserted, never call counts.
Code.require_file("poll_helper.exs", __DIR__)

defmodule InternalTier.VmZeroGrowthTest do
  use ExUnit.Case, async: false

  import SmaltTest.Internal.Poll, only: [eventually: 1, eventually: 2]

  # -- census ---------------------------------------------------------------

  defp census do
    pids = :erlang.processes()

    # The zero-growth law's subject is the LONG-LIVED population. ConnSup's
    # connection children are the documented unstable population (each socket
    # is a temporary DynamicSupervisor child whose supervisor<->child monitor
    # PAIR double-counts in a naive monitors sum and vanishes on any socket
    # churn, moving the total by ±2 per connection — witnessed as a
    # deterministic `monitors: -2` drift under concurrent census runs).
    # Exclude that subtree from the monitor sum; the process count still
    # includes them and the conn-sup churn test asserts restoration separately.
    conn_sup = Process.whereis(Smalt.AmqpBroker.ConnSup)

    conn_sup_children =
      if conn_sup,
        do: MapSet.new(DynamicSupervisor.which_children(conn_sup) |> Enum.map(&elem(&1, 1))),
        else: MapSet.new()

    monitors =
      Enum.reduce(pids, 0, fn pid, acc ->
        cond do
          MapSet.member?(conn_sup_children, pid) ->
            acc

          true ->
            case :erlang.process_info(pid, [:monitors, :monitored_by]) do
              :undefined ->
                acc

              info ->
                # count the supervisor->child monitor exactly once (via the
                # supervisor side); skip the child's mirrored :monitored_by
                acc + length(Keyword.get(info, :monitors, []))
            end
        end
      end)

    %{
      processes: length(pids),
      ets: length(:ets.all()),
      atoms: :erlang.system_info(:atom_count),
      monitors: monitors
    }
  end

  defp census_deltas(before, after_census) do
    [
      {:processes, after_census.processes - before.processes},
      {:ets, after_census.ets - before.ets},
      {:monitors, after_census.monitors - before.monitors}
    ]
  end

  setup do
    # Bounded poll: all four plane supervisors named before we snapshot
    # any baseline (same observables as the blast-radius tier).
    Enum.each(
      [Smalt.Plane.DataSupervisor, Smalt.Plane.ControlSupervisor,
       Smalt.Plane.IntegrationSupervisor, Smalt.Plane.IdentitySupervisor],
      fn sup ->
        assert {:ok, _} =
                 eventually(fn ->
                   case Process.whereis(sup) do
                     pid when is_pid(pid) -> {:ok, pid}
                     nil -> {:still_starting, sup}
                   end
                 end)
      end
    )

    # Lazy singletons up before baseline (their own public start seams).
    assert {:ok, _} = start_singleton(Smalt.Amqp.QueueStore, fn -> Smalt.Amqp.QueueStore.start_link([]) end)

    assert {:ok, _} =
             start_singleton(Smalt.Messaging.EventGrid, fn -> Smalt.Messaging.EventGrid.start_link([]) end)

    assert {:ok, _} = start_singleton(Smalt.Security.LedgerWriter, fn -> Smalt.Security.LedgerWriter.start_link([]) end)

    :ok
  end

  @tag :smalt_internal
  test "conn-sup churn: kill all children, supervisor restores count, VM census deltas zero" do
    conn_sup = Smalt.AmqpBroker.ConnSup
    baseline_children = length(DynamicSupervisor.which_children(conn_sup))
    before = census()

    # Real child processes under the real DynamicSupervisor: two
    # :temporary holders (supervisor does NOT restart them — amqp_broker.ex
    # strategy) and one :permanent holder (the supervisor DOES replace it).
    # Park form (`after :infinity`): the holder never times out — the test
    # kills it; a literal 86_400_000 park is a delay primitive to the gate.
    holder = fn -> receive do after :infinity -> :ok end end

    temp_specs =
      for _ <- 1..2 do
        %{
          id: make_ref(),
          start: {Task, :start_link, [holder]},
          restart: :temporary
        }
      end

    perm_spec = %{id: make_ref(), start: {Task, :start_link, [holder]}, restart: :permanent}

    specs = temp_specs ++ [perm_spec]

    started =
      Enum.map(specs, fn spec ->
        assert {:ok, pid} = DynamicSupervisor.start_child(conn_sup, spec)
        pid
      end)

    perm_pid = List.last(started)
    assert length(DynamicSupervisor.which_children(conn_sup)) == baseline_children + 3

    # Violently kill every child. The supervisor's restart policy then
    # plays out for real: the two temporaries are gone (DynamicSupervisor
    # does not restart :temporary children) and the :permanent child is
    # REPLACED by a fresh pid (count restored to baseline + 1).
    Enum.each(DynamicSupervisor.which_children(conn_sup), fn {_id, pid, _type, _mods} ->
      if pid != conn_sup, do: Process.exit(pid, :kill)
    end)

    assert {:ok, :permanent_replaced} =
             eventually(
               fn ->
                 kids = DynamicSupervisor.which_children(conn_sup)
                 n = length(kids)

                 cond do
                   n != baseline_children + 1 ->
                     {:churning, n}

                   true ->
                     new_perm = Enum.map(kids, &elem(&1, 1)) -- [perm_pid]
                     if new_perm != [] and hd(new_perm) != perm_pid do
                       {:ok, :permanent_replaced}
                     else
                       {:stale_generation, new_perm}
                     end
                 end
               end,
               timeout_ms: 10_000
             )

    # Now terminate the replaced permanent through the supervisor's own
    # seam so the count returns to the true baseline.
    surviving =
      DynamicSupervisor.which_children(conn_sup)
      |> Enum.map(&elem(&1, 1))
      |> Kernel.--([conn_sup])

    Enum.each(surviving, &DynamicSupervisor.terminate_child(conn_sup, &1))

    assert {:ok, :at_baseline} =
             eventually(
               fn ->
                 n = length(DynamicSupervisor.which_children(conn_sup))

                 if n == baseline_children do
                   {:ok, :at_baseline}
                 else
                   {:churning, n}
                 end
               end,
               timeout_ms: 10_000
             )

    assert {:ok, :quiesced} =
             eventually(
               fn ->
                 after_census = census()
                 deltas = census_deltas(before, after_census)
                 zero? = Enum.all?(deltas, fn {_k, d} -> d == 0 end)

                 if zero? do
                   {:ok, :quiesced}
                 else
                   {:drifting, deltas}
                 end
               end,
               timeout_ms: 10_000,
               poll_ms: 100
             )

    # Atom growth is bounded, not zero (literals mint atoms legitimately):
    # fenced below 64 — the observed baseline drift for a full churn cycle.
    assert :erlang.system_info(:atom_count) - before.atoms < 64
  end

  @tag :smalt_internal
  test "lazy singleton churn: killed named singletons re-materialize with fresh pids and full table set" do
    singletons = [
      {Smalt.Amqp.QueueStore, fn -> Smalt.Amqp.QueueStore.start_link([]) end},
      {Smalt.Messaging.EventGrid, fn -> Smalt.Messaging.EventGrid.start_link([]) end},
      {Smalt.Security.LedgerWriter, fn -> Smalt.Security.LedgerWriter.start_link([]) end}
    ]

    # Materialize all three, remember their pids.
    pids =
      Map.new(singletons, fn {mod, start} ->
        assert {:ok, pid} = start_singleton(mod, start)
        {mod, pid}
      end)

    before = census()
    baseline_tables = for t <- Smalt.StoreTables.all_tables(), :ets.info(t) != :undefined, do: t

    # Kill all three named processes violently.
    Enum.each(pids, fn {_mod, pid} -> Process.exit(pid, :kill) end)

    # Bounded-poll for a NEW pid per singleton (fresh start seam, never the
    # old pid resurrected — names are re-registered by new processes).
    new_pids =
      Map.new(singletons, fn {mod, start} ->
        stale = pids[mod]

        assert {:ok, new_pid} =
                 eventually(
                   fn ->
                     case Process.whereis(mod) do
                       nil ->
                         case start.() do
                           {:ok, pid} -> {:ok, pid}
                           {:error, {:already_started, pid}} -> {:ok, pid}
                           {:error, other} -> {:refused, other}
                         end

                       # The STALE pid still registered: keep waiting for a
                       # genuinely new registration.
                       ^stale -> {:same_pid_stale, stale}
                       # A DIFFERENT pid already registered: fine, take it.
                       other when is_pid(other) -> {:ok, other}
                     end
                   end,
                   timeout_ms: 10_000
                 )

        {mod, new_pid}
      end)

    Enum.each(singletons, fn {mod, _start} ->
      assert is_pid(new_pids[mod]) and new_pids[mod] != pids[mod],
             "expected a fresh pid for #{inspect(mod)}"
    end)

    # Final state: the churn killed no tables. All owner-generated tables
    # (store.ex init/1 creates table_names(); shadow tables are
    # owner-managed) that were alive at baseline are alive at the end.
    Enum.each(baseline_tables, fn table ->
      assert :ets.info(table) != :undefined, "table #{inspect(table)} not alive after churn"
    end)

    Enum.each(Smalt.StoreTables.table_names(), fn table ->
      assert :ets.info(table) != :undefined,
             "Store-owned table #{inspect(table)} not alive after churn"
    end)

    # VM census back to baseline: zero net process/ets/monitor growth.
    assert {:ok, :quiesced} =
             eventually(
               fn ->
                 after_census = census()
                 deltas = census_deltas(before, after_census)

                 if Enum.all?(deltas, fn {_k, d} -> d == 0 end) do
                   {:ok, :quiesced}
                 else
                   {:drifting, deltas}
                 end
               end,
               timeout_ms: 10_000,
               poll_ms: 100
             )

    assert :erlang.system_info(:atom_count) - before.atoms < 64
  end

  defp start_singleton(mod, start) do
    eventually(
      fn ->
        case Process.whereis(mod) do
          pid when is_pid(pid) ->
            {:ok, pid}

          nil ->
            case start.() do
              {:ok, pid} ->
                # The lazy start seam is start_link: unlink so a later
                # violent kill of the singleton does not take the test
                # process with it (the supervisor of record for these
                # singletons is their lazy-start contract, not this test).
                Process.unlink(pid)
                {:ok, pid}

              {:error, {:already_started, pid}} -> {:ok, pid}
              {:error, other} -> {:refused, other}
            end
        end
      end,
      timeout_ms: 5_000
    )
  end
end
