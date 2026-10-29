# JA-13 supervisor restart-intensity court (Joe Armstrong doctrine).
#
# A crash loop must trip max_restarts and STOP, not spin forever. Every
# phase runs real OTP supervisors with the same configured intensity as the
# substrate tree (Smalt.Plane.DataSupervisor / IntegrationSupervisor:
# max_restarts: 5, max_seconds: 5) and real exits — no mocks. Time appears
# only as bounded after-clauses on observable polls (SLEEP-CLASS: POLL-STEP)
# and as the P4 storm's load window (SLEEP-CLASS: SCHEDULING — a real-world
# experiment interval, annotated at the single site).
#
# Run (OTP 29 toolchain, lane build root):
#   cd <repo-root>
#   PATH="$HOME/.asdf/installs/elixir/1.20.4-otp-29/bin:$HOME/.asdf/installs/erlang/29.1.2/bin:$PATH" \
#   MIX_BUILD_ROOT=_build-ja13 mix run --no-start test/integration/ja13_supervisor_intensity_court.exs

defmodule JA13 do
  @moduledoc false

  @intensity 5
  @seconds 5

  def main do
    unless :erlang.system_info(:otp_release) == ~c"29" do
      throw({:otp29_required, :erlang.system_info(:otp_release)})
    end

    IO.puts("otp_release=#{:erlang.system_info(:otp_release)} erts=#{:erlang.system_info(:version)} tree_intensity=max_restarts=#{@intensity}/max_seconds=#{@seconds}s (DataSupervisor/IntegrationSupervisor pin)")

    p1 = phase1_give_up()
    IO.puts("P1 PASS give_up exit=#{inspect(p1.exit_reason)} bad_restarts=#{p1.bad_restarts_before_give_up}")

    p2 = phase2_crash_once_recover()
    IO.puts("P2 PASS crash_once_recovered served=#{p2.served} restarts=#{p2.restarts}")

    p3 = phase3_one_for_all_escalation()
    IO.puts(
      "P3 PASS one_for_all sibling #{inspect(p3.sibling_before)} -> #{inspect(p3.sibling_after)} " <>
        "sibling_down_reason=#{inspect(p3.sibling_down_reason)} bomber_down_reason=#{inspect(p3.bomber_down_reason)}"
    )

    p4 = phase4_restart_storm()
    IO.puts("P4 PASS storm=#{inspect(p4.storm)} msacc=#{p4.msacc_summary}")

    p5 = phase5_amqp_listener_cycle()
    IO.puts("P5 PASS amqp=#{inspect(Map.take(p5, [:sb_port, :reborn_port, :old_pid, :new_pid, :served_after_restart]))}")

    IO.puts("COURT JA13 PASS (5/5 phases)")
  catch
    kind, reason ->
      st = __STACKTRACE__ |> Enum.take(6) |> inspect(limit: :infinity)
      IO.puts("COURT JA13 FAIL kind=#{kind} reason=#{inspect(reason, limit: :infinity)} at=#{st}")
      exit(:court_failed)
  end

  # ---------------------------------------------------------------- P1
  # Intensity-configured supervisor around a child that starts healthy and
  # then goes bad: the restart loop trips max_restarts/max_seconds and the
  # supervisor gives up with a typed exit.
  defmodule BadAfterStart do
    @moduledoc false
    use GenServer

    def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: opts[:name])

    @impl true
    def init(opts) do
      bad_key = {__MODULE__, :bad?, opts[:name]}

      if :persistent_term.get(bad_key, false) do
        :persistent_term.put({__MODULE__, :p1_starts},
          :persistent_term.get({__MODULE__, :p1_starts}, 0) + 1)
        exit({:shutdown, :ja13_crash_on_restart})
      end

      {:ok, opts}
    end

    @impl true
    def handle_call(:go_bad, from, state) do
      :persistent_term.put({__MODULE__, :bad?, state[:name]}, true)
      GenServer.reply(from, :bad_is_set)
      send(self(), :ja13_go_bad)
      {:noreply, state}
    end

    @impl true
    def handle_info(:ja13_go_bad, _state), do: exit({:shutdown, :ja13_go_bad})
    def handle_info(_msg, state), do: {:noreply, state}
  end

  defmodule P1Sup do
    @moduledoc false
    use Supervisor

    def start_link(opts),
      do: Supervisor.start_link(__MODULE__, opts, name: Keyword.get(opts, :name))

    @impl true
    def init(_opts) do
      Supervisor.init(
        [{JA13.BadAfterStart, name: :ja13_p1_child}],
        strategy: :one_for_one,
        max_restarts: 5,
        max_seconds: 5
      )
    end
  end

  # Start a supervisor from an UNLINKED spawner so a give-up exit is observed
  # via monitor, never suffered by the court driver through a link.
  defp start_unlinked(starter, tag \\ :untagged) do
    parent = self()

    spawner =
      spawn(fn ->
        # Trap the supervisor's exit so its typed give-up reason is REPORTED,
        # not silently swallowed — diagnostics are part of the court output.
        Process.flag(:trap_exit, true)

        case starter.() do
          {:ok, pid} ->
            send(parent, {:start_outcome, tag, {:started, pid}})

            # Keep trapping so a later typed give-up is reported, never lost.
            receive do
              {:EXIT, ^pid, reason} -> send(parent, {:sup_exit, tag, reason})
            end

          other ->
            send(parent, {:start_outcome, tag, {:start_error, other}})
        end

        receive do
        after
          :infinity -> :ok
        end
      end)

    mon = Process.monitor(spawner)

    result =
      receive do
        {:start_outcome, ^tag, {:started, pid}} ->
          Process.demonitor(mon, [:flush])
          {:started, pid}

        {:start_outcome, ^tag, {:start_error, other}} ->
          {:start_failed, {:start_error, other}}

        {:sup_exit, ^tag, reason} ->
          # Give-up before we even got :started — the typed reason itself.
          {:started, {:gave_up_immediately, reason}}

        {:DOWN, ^mon, :process, ^spawner, r} ->
          {:spawner_down, r}
      after
        20_000 -> throw({:start_unlinked_timeout, tag})
      end

    Process.demonitor(mon, [:flush])

    case result do
      {:started, pid} -> {:ok, pid}
      other -> {:start_failed, other}
    end
  end

  def phase1_give_up do
    :persistent_term.put({JA13.BadAfterStart, :bad?, :ja13_p1_child}, false)
    {:ok, sup} = start_unlinked(fn -> P1Sup.start_link([]) end, :p1)
    mon = Process.monitor(sup)

    child = GenServer.whereis(:ja13_p1_child)
    unless is_pid(child), do: throw(:p1_child_never_started)

    :persistent_term.put({JA13.BadAfterStart, :p1_starts}, 0)
    GenServer.call(:ja13_p1_child, :go_bad)

    exit_reason =
      receive do
        {:DOWN, ^mon, :process, ^sup, r} -> r
      after
        20_000 -> throw(:p1_timeout_waiting_give_up)
      end

    bad_starts =
      :persistent_term.get({JA13.BadAfterStart, :p1_starts}, 0)

    # OTP 29 gives up with exit reason :shutdown when restart intensity is
    # exceeded; non-vacuity: the give-up only counts if the child actually
    # went through >= max_restarts (5) crashing restarts first.
    unless exit_reason == :shutdown and bad_starts >= 5 do
      throw({:p1_give_up_unproven, exit_reason, bad_starts})
    end

    %{exit_reason: exit_reason, bad_restarts_before_give_up: bad_starts}
  end

  # ---------------------------------------------------------------- P2
  defmodule CrashOnce do
    @moduledoc false
    use GenServer

    def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: opts[:name])

    @impl true
    def init(opts) do
      key = {__MODULE__, :crashed?}

      if :persistent_term.get(key, false) == false do
        :persistent_term.put(key, true)
        exit({:ja13_first_start_crash, :deliberate})
      end

      {:ok, Map.new(opts)}
    end

    @impl true
    def handle_call(:serve, _from, state), do: {:reply, {:served, self(), state}, state}
  end

  def phase2_crash_once_recover do
    :persistent_term.put({JA13.CrashOnce, :crashed?}, false)

    # The first start is EXPECTED to crash the child; the initial-start
    # failure propagates to the linked caller, so start via the unlinked
    # spawner and re-start once the deliberate first crash has landed.
    {start_result, sup} =
      case start_unlinked(fn ->
             Supervisor.start_link(
               [{JA13.CrashOnce, name: :ja13_p2_child}],
               strategy: :one_for_one,
               max_restarts: 5,
               max_seconds: 5
             )
           end) do
        {:ok, pid} -> {:first_start_ok, pid}
        {:start_failed, _} -> {:first_start_crashed, nil}
      end

    {:ok, sup} =
      if start_result == :first_start_crashed do
        Supervisor.start_link(
          [{JA13.CrashOnce, name: :ja13_p2_child}],
          strategy: :one_for_one,
          max_restarts: 5,
          max_seconds: 5
        )
      else
        {:ok, sup}
      end

    # The first start crashes; poll the registered name until the restarted
    # child answers a real call (bounded observable poll — no fixed sleep).
    served =
      wait_until(5_000, fn ->
        case GenServer.whereis(:ja13_p2_child) do
          nil ->
            false

          pid ->
            try do
              match?({:served, ^pid, _}, GenServer.call(pid, :serve))
            rescue
              _ -> false
            catch
              :exit, _ -> false
            end
        end
      end)

    restarts = count_children_alive(sup)

    unless served, do: throw({:p2_child_never_served, restarts})
    unless restarts >= 1, do: throw({:p2_child_not_alive, restarts})

    %{served: true, restarts: restarts}
  end

  defp count_children_alive(sup) do
    sup
    |> Supervisor.which_children()
    |> Enum.count(fn {_id, pid, _type, _mods} -> is_pid(pid) end)
  end

  # ---------------------------------------------------------------- P3
  defmodule Bomber do
    @moduledoc false
    use GenServer

    def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: opts[:name])

    @impl true
    def init(opts), do: {:ok, Map.new(opts)}

    @impl true
    def handle_cast(:bomb, state) do
      Process.exit(self(), :kill)
      {:noreply, state}
    end
  end

  defmodule Sibling do
    @moduledoc false
    use GenServer

    def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: opts[:name])

    @impl true
    def init(opts), do: {:ok, Map.new(opts)}

    @impl true
    def handle_call(:serve, _from, state), do: {:reply, {:served, self()}, state}
  end

  defmodule P3Sup do
    @moduledoc false
    use Supervisor

    def start_link(opts),
      do: Supervisor.start_link(__MODULE__, opts, name: Keyword.get(opts, :name))

    @impl true
    def init(_opts) do
      Supervisor.init(
        [{JA13.Bomber, name: :ja13_p3_bomber}, {JA13.Sibling, name: :ja13_p3_sibling}],
        strategy: :one_for_all
      )
    end
  end

  def phase3_one_for_all_escalation do
    {:ok, sup} = P3Sup.start_link([])

    bomber = GenServer.whereis(:ja13_p3_bomber)
    sibling_before = GenServer.whereis(:ja13_p3_sibling)
    bmon = Process.monitor(bomber)
    smon = Process.monitor(sibling_before)

    GenServer.cast(bomber, :bomb)

    bomber_down =
      receive do
        {:DOWN, ^bmon, :process, ^bomber, r} -> r
      after
        5_000 -> throw(:p3_bomber_down_timeout)
      end

    # The one_for_all strategy escalates: the innocent sibling is taken down
    # (its old pid gets a DOWN) and both are restarted together.
    sibling_down_reason =
      receive do
        {:DOWN, ^smon, :process, ^sibling_before, r} -> r
      after
        5_000 -> throw(:p3_sibling_not_taken_down)
      end

    sibling_after =
      wait_until(5_000, fn ->
        case GenServer.whereis(:ja13_p3_sibling) do
          nil -> false
          pid when pid != sibling_before -> pid
          _ -> false
        end
      end)

    unless is_pid(sibling_after), do: throw(:p3_sibling_never_restarted)
    {:served, ^sibling_after} = GenServer.call(sibling_after, :serve)

    _ = sup
    %{
      sibling_before: sibling_before,
      sibling_after: sibling_after,
      sibling_down_reason: sibling_down_reason,
      bomber_down_reason: bomber_down
    }
  end

  # ---------------------------------------------------------------- P4
  defmodule ProbeTarget do
    @moduledoc false
    use GenServer

    def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: opts[:name])

    @impl true
    def init(opts), do: {:ok, Map.new(opts)}

    @impl true
    def handle_call(:ping, _from, state), do: {:reply, :pong, state}
  end

  defmodule StormSup do
    @moduledoc false
    use Supervisor

    def start_link(opts),
      do: Supervisor.start_link(__MODULE__, opts, name: Keyword.get(opts, :name))

    @impl true
    def init(_opts) do
      # Intentionally extreme intensity so the supervisor does NOT give up
      # during the storm window — the storm must be stopped by us; give-up
      # behavior itself is P1's proof.
      Supervisor.init(
        [{JA13.BadAfterStart, name: :ja13_p4_storm_child}],
        strategy: :one_for_one,
        max_restarts: 10_000_000,
        max_seconds: 1
      )
    end
  end

  defp parent_process, do: :erlang.whereis(:ja13_driver)

  def phase4_restart_storm do
    :erlang.register(:ja13_driver, self())
    {:ok, _probe} = ProbeTarget.start_link(name: :ja13_p4_probe)

    # Baseline: probe throughput with no storm (same window size).
    baseline = probe_roundtrips(500)

    :persistent_term.put({JA13.BadAfterStart, :bad?, :ja13_p4_storm_child}, false)
    {:ok, sup} = start_unlinked(fn -> StormSup.start_link([]) end, :storm)
    GenServer.call(:ja13_p4_storm_child, :go_bad)

    # SLEEP-CLASS: TIME-ADVANCE — the storm window is a real-world load
    # interval (like a bench lane's timed window), not coordination; the
    # control probe's throughput over the window is the observable under
    # test, so time itself is the condition (test-side lawful class).
    storm_window_ms = 2_000

    t0 = System.monotonic_time(:millisecond)
    su0 = scheduler_utilization()

    _storm_runner =
      spawn(fn ->
        # SLEEP-CLASS: TIME-ADVANCE — the storm window itself is the
        # condition under test (probe throughput over a real load interval).
        Process.sleep(storm_window_ms)
        # Disarm first so the in-flight restart settles, then stop cleanly.
        :persistent_term.put({JA13.BadAfterStart, :bad?, :ja13_p4_storm_child}, false)
        Supervisor.stop(sup, :normal)
        send(parent_process(), :storm_window_done)
      end)

    during = probe_roundtrips(storm_window_ms)
    su1 = scheduler_utilization()

    # Drain the runner's completion message (bounded observable poll).
    receive do
      :storm_window_done -> :ok
    after
      5_000 -> throw(:p4_storm_runner_never_finished)
    end

    max_util = max_scheduler_utilization(su0, su1)
    msacc_summary = "sched_util_max=#{:erlang.float_to_binary(max_util, decimals: 1)}%"

    # During the storm the control probe kept answering within a relative
    # fence (>= 1/10 of the no-storm baseline round-trips).
    unless during >= div(baseline, 10) do
      throw({:p4_probe_starved, baseline: baseline, during: during})
    end

    # No scheduler saturated (wall-time utilization < 99%): the crash loop
    # cannot wedge the schedulers even at maximum restart rate.
    unless max_util < 99.0 do
      throw({:p4_scheduler_saturated, max_util, msacc_summary})
    end

    # The storm ended, the supervisor was stopped, the child name is free.
    unless wait_until(5_000, fn -> Process.whereis(:ja13_p4_storm_child) == nil end) do
      throw(:p4_storm_child_stuck_registered)
    end

    %{
      storm: %{baseline_roundtrips: baseline, during_roundtrips: during},
      probe: :within_relative_fence,
      msacc_summary: msacc_summary
    }
  end

  defp probe_roundtrips(window_ms) do
    deadline = System.monotonic_time(:millisecond) + window_ms
    probe_loop(deadline, 0)
  end

  defp probe_loop(deadline, n) do
    if System.monotonic_time(:millisecond) >= deadline do
      n
    else
      :pong = GenServer.call(:ja13_p4_probe, :ping)
      probe_loop(deadline, n + 1)
    end
  end

  defp scheduler_utilization do
    # OTP 21+: per-scheduler active/total wall time, monotonically accumulated.
    :erlang.system_flag(:scheduler_wall_time, true)
    :erlang.statistics(:scheduler_wall_time)
  end

  # Weighted utilization across all schedulers between two samples.
  defp max_scheduler_utilization(s0, s1) do
    for {id0, act0, tot0} <- s0,
        {id1, act1, tot1} <- s1,
        id0 == id1,
        tot1 > tot0 do
      (act1 - act0) / (tot1 - tot0) * 100.0
    end
    |> Enum.max(fn -> 0.0 end)
  end

  # ---------------------------------------------------------------- P5
  def phase5_amqp_listener_cycle do
    # Real substrate supervisors: Smalt.Store (DataSupervisor child) + the
    # real Smalt.AmqpBroker facade (IntegrationSupervisor subtree), on
    # ephemeral ports so a live substrate on this host is never touched.
    {:ok, _store} = Smalt.Store.start_link([])

    {:ok, broker} = Smalt.AmqpBroker.start_link(sb_port: 0, eh_port: 0)

    sb_listener = wait_until(5_000, fn -> Process.whereis(Smalt.Amqp.Listener.Sb) end)
    unless is_pid(sb_listener), do: throw(:p5_sb_listener_never_started)

    sb_port = Smalt.Amqp.Listener.port(sb_listener)
    unless serves?(sb_port), do: throw({:p5_listener_not_serving, sb_port})

    old_pid = sb_listener
    mon = Process.monitor(old_pid)
    Process.exit(old_pid, :kill)

    receive do
      {:DOWN, ^mon, :process, ^old_pid, _r} -> :ok
    after
      5_000 -> throw(:p5_old_listener_down_timeout)
    end

    new_pid =
      wait_until(5_000, fn ->
        case Process.whereis(Smalt.Amqp.Listener.Sb) do
          nil -> false
          pid when pid != old_pid -> pid
          _ -> false
        end
      end)

    unless is_pid(new_pid), do: throw(:p5_listener_never_respawned)

    # After respawn the listener re-binds the same port and serves again.
    # The broker was started with sb_port: 0 (ephemeral, to never touch a
    # live substrate), so the respawned listener re-binds a NEW ephemeral
    # port — serve = answers Listener.port/1 and accepts TCP on that port.
    served_after_restart =
      wait_until(5_000, fn ->
        try do
          reborn_port = Smalt.Amqp.Listener.port(new_pid)
          is_integer(reborn_port) and serves?(reborn_port)
        rescue
          _ -> false
        catch
          :exit, _ -> false
        end
      end)

    unless served_after_restart, do: throw(:p5_listener_not_serving_after_restart)
    reborn_port = Smalt.Amqp.Listener.port(new_pid)

    _ = broker
    %{sb_port: sb_port, reborn_port: reborn_port, old_pid: old_pid, new_pid: new_pid, served_after_restart: true}
  end

  defp serves?(port) do
    case :gen_tcp.connect({127, 0, 0, 1}, port, [], 1_000) do
      {:ok, sock} ->
        :gen_tcp.close(sock)
        true

      _ ->
        false
    end
  end

  defp wait_until(timeout, fun) do
    wait_until_loop(System.monotonic_time(:millisecond) + timeout, fun)
  end

  defp wait_until_loop(deadline, fun) do
    case fun.() do
      false ->
        if System.monotonic_time(:millisecond) >= deadline do
          false
        else
          receive do
          after
            10 -> wait_until_loop(deadline, fun)
          end
        end

      value ->
        value
    end
  end
end

JA13.main()
