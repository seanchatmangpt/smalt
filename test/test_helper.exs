# Test isolation contract: docs/TEST_ISOLATION.md
#
# Default-excluded tags are NAMED, in-flight/known-gap exceptions — each is a
# deliberate exclusion with an owner lane and a re-enable condition documented
# in docs/TEST_ISOLATION.md. This is not a blanket skip: any untagged test
# runs. Re-enable individual tiers with `mix test --include <tag>`.
# Shifted substrate ports: when the app needs (re)starting, suites use the
# per-run probed ports from SmaltTest.Lifecycle.shifted_envs/0 (see below) so
# concurrent `mix test` runs on this shared checkout never collide on a fixed
# shifted set. Wire-tier tests take ephemeral ports themselves.
# NOTE (2026-10-14): the listener ports for the shared tree now come from
# config/test.exs (config-level free-port probe, see docs/TEST_ISOLATION.md
# §2), so `mix test` boots on ephemeral ports by default. Runtime
# `Application.put_env` still overrides config; Lifecycle.shifted_envs/0
# remains the contract for suites that stop/restart the shared tree.
ExUnit.configure(
  exclude: [
    :amqp_wire,
    # :stress tier (v26.10.18): 15 expensive test bodies (replay-identity
    # fences, DETS churn, 10k-op fuzz, 1000-PUT corpus sweep). Excluded from
    # plain `mix test`; run with `mix test --include stress` / `just
    # test-stress`. Population fenced by test/stress_tier_census_test.exs.
    :stress
  ]
)

# Per-run shared name registry for SmaltTest.Singleton (started ONCE per
# run here — per-test registry starts race under async).
{:ok, _} = Registry.start_link(keys: :unique, name: SmaltTest.Registry)

# Degraded-host law (runs 21-30): timing-sensitive suites flip under CPU
# contention (Metadata indexer / concurrent builds). SMALT_MAX_CASES caps
# ExUnit concurrency without touching any assertion — same tests, same
# law, less parallel timing pressure. Unset = default (schedulers online).
max_cases = String.to_integer(System.get_env("SMALT_MAX_CASES") || "0")
if max_cases > 0, do: ExUnit.start(max_cases: max_cases), else: ExUnit.start()

# Shared lifecycle helper for suites that stop the main app tree to boot a
# private tree on ephemeral ports (wire tier, metadata, eventgrid). Contract:
#   1. Stopping the shared tree must never raise (bounded stop + kill fallback);
#      a raising stop leaks an in-flight shutdown that invalidates the shared
#      Store's ETS tables under concurrently-running modules.
#   2. Any module that stops the shared tree MUST restore it in on_exit with
#      the shifted ports (docs/TEST_ISOLATION.md section 2), so downstream
#      modules never observe a dead Store regardless of module run order.
defmodule SmaltTest.Lifecycle do
  # Per-RUN shifted ports: probe free ports once at load so concurrent test
  # runs (multiple lanes share this checkout) never collide on a fixed
  # shifted set like 29443.
  @shifted (
             base_envs = [
               arm_port: 29_443,
               arm_tls_port: 29_444,
               egress_port: 28_443,
               amqp_port: 25_672,
               event_hubs_port: 25_673
             ]

             Enum.map(base_envs, fn {k, default} ->
               {k,
                case :gen_tcp.listen(0, [:binary, active: false]) do
                  {:ok, sock} ->
                    {:ok, port} = :inet.port(sock)
                    :gen_tcp.close(sock)
                    port

                  _ ->
                    default
                end}
             end)
           )

  def shifted_envs, do: @shifted

  # Non-raising stop of the shared app tree.
  def stop_shared_tree do
    case Process.whereis(Smalt.Supervisor) do
      nil ->
        :ok

      sup ->
        try do
          Supervisor.stop(sup, :normal, 10_000)
        catch
          _, _ -> Process.exit(sup, :kill)
        end

        wait_gone(Smalt.Store)
        wait_gone(Smalt.Supervisor)
    end
  end

  @doc """
  `stop_shared_tree/0` plus a nil-supervisor fallback that stops the
  Store/AmqpBroker children directly (the egress/amqp wire suites' former
  private `stop_existing_tree/0`, folded here per e2e-wire D4).
  """
  def stop_shared_tree_with_children do
    case Process.whereis(Smalt.Supervisor) do
      nil ->
        for name <- [Smalt.Store, Smalt.AmqpBroker] do
          if pid = Process.whereis(name), do: GenServer.stop(pid)
        end

      sup ->
        stop_shared_tree()
    end
  end

  @doc """
  Public bounded wait for a registered name to disappear (100 x 10ms by
  default; the wire suites' former private `wait_until_gone/2`, e2e-wire D4).
  """
  def await_gone(name, n \\ 100)

  def await_gone(_name, 0), do: :ok

  def await_gone(name, n) do
    if Process.whereis(name) == nil do
      :ok
    else
      Process.sleep(10)
      await_gone(name, n - 1)
    end
  end

  # Private in spirit: used only by stop_shared_tree/0 to bound the shutdown
  # wait. All clauses defp (same-module calls only; mixed def/defp on one
  # name is a compile error — SHIM-COURT-lane-R185i unblock, disclosed).
  defp wait_gone(name, n \\ 300)

  defp wait_gone(_name, 0), do: :ok

  defp wait_gone(name, n) do
    if Process.whereis(name) == nil do
      :ok
    else
      Process.sleep(10)
      wait_gone(name, n - 1)
    end
  end

  # Re-apply shifted ports and (re)start the shared app. Tolerant of
  # already-started (no-op) and of a failed start (returns the reason without
  # raising, so on_exit never fails the run).
  def restore_app do
    Enum.each(@shifted, fn {k, v} -> Application.put_env(:smalt, k, v) end)

    case Application.ensure_all_started(:smalt) do
      {:ok, _} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Child-aware guarantee that the shared Store GenServer is up under the shared
  supervision tree, with all Store ETS tables materialized.

  Unlike `restore_app/0` (a no-op when :smalt is *started* but Store was
  Supervisor.terminate_child'd), this:

    1. ensure_all_started(:smalt) — covers the fully-stopped case;
    2. if Process.whereis(Smalt.Store) is still nil, restarts the child
       (ignore {:error, :already_present} / {:error, {:already_started, _}} —
       both are success for our purposes);
    3. waits (bounded, ~3s) until :ets.info/1 != :undefined for ALL Store
       tables, so callers never see the half-initialized window.

  Idempotent and non-raising: returns :ok, or {:error, :store_not_running}
  on a hopeless tree (never raises — safe from on_exit).
  """
  def ensure_store_up, do: do_ensure_store_up(3)

  defp do_ensure_store_up(0), do: {:error, :store_not_running}

  defp do_ensure_store_up(retries) do
    case Process.whereis(Smalt.Store) do
      nil ->
        # Fully-stopped (or Store-only-down) case: re-apply the run's shifted
        # envs + ensure_all_started, then force the child back under the
        # supervisor if ensure_all_started was a no-op (app "started" but the
        # Store child was terminate_child'd).
        _ = restore_app()

        case Process.whereis(Smalt.Store) do
          nil ->
            _ = restart_store_child()

            case wait_store_tables() do
              :ok ->
                :ok

              _error ->
                Process.sleep(100)
                do_ensure_store_up(retries - 1)
            end

          _pid ->
            wait_store_tables()
        end

      _pid ->
        # Tree healthy: never touch envs here — re-applying the shifted port
        # set over a live, differently-bound tree desyncs env from listeners
        # (measured: crash_isolation connected to a port no listener held).
        wait_store_tables()
    end
  end

  # Restart is best-effort: {:error, :already_present} / {:error,
  # {:already_started, _}} are both success for our purposes; the table wait
  # below is the real gate.
  defp restart_store_child do
    # If the supervision tree itself is gone (Application.stop raced another
    # module's on_exit while the application master still reports :started),
    # restart_child would GenServer.call a dead name and crash the on_exit
    # runner (witnessed: warm-up 2026-10-18, AmqpWireTest on_exit vs
    # canonical_projection's Application.stop). Force a true reboot instead.
    if Process.whereis(Smalt.Supervisor) == nil do
      _ = Application.stop(:smalt)
      _ = restore_app()
      :ok
    else
      case Supervisor.restart_child(Smalt.Supervisor, Smalt.Store) do
        {:error, _} = e -> e
        {:ok, _pid} -> :ok
        other -> {:error, other}
      end
    end
  end

  defp wait_store_tables, do: wait_store_tables(300)

  defp wait_store_tables(0) do
    if Process.whereis(Smalt.Store) == nil do
      {:error, :store_not_running}
    else
      {:error, :store_tables_not_materialized}
    end
  end

  defp wait_store_tables(n) do
    store_up? = Process.whereis(Smalt.Store) != nil

    tables_up? =
      store_up? and
        Enum.all?(Smalt.Store.table_names(), fn t -> :ets.info(t) != :undefined end)

    if tables_up? do
      :ok
    else
      Process.sleep(10)
      wait_store_tables(n - 1)
    end
  end
end
