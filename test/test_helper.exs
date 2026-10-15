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
    :arm_seam,
    :dp_seam,
    :closed_shape_gap
  ]
)

ExUnit.start()

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
    end
  end

  def wait_gone(name, n \\ 300)

  def wait_gone(_name, 0), do: :ok

  def wait_gone(name, n) do
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
end
