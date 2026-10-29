# WASM sandbox verification court (WASM-SANDBOX-SPEC.md, 3 spec gates + 2
# lane additions). Real collaborators: real ports, real stub-runner OS
# processes, real EXIT-driven pool respawn. No mocks.
#
# Context: solo (integration tier, real packet-4 port IPC).

defmodule Smalt.Integration.WasmSandboxCourtTest do
  use ExUnit.Case, async: false

  Code.require_file("../internal/poll_helper.exs", __DIR__)
  Code.require_file("../internal/hang_reap.exs", __DIR__)

  alias Smalt.Wasm.{Bridge, Pool, Worker}

  @pool_opts [size: 3, timeout_ms: 5_000]

  setup do
    # BK-GRAPHREAP: caller-side reap — the gate-5 `--hang` double survives
    # the port kill (it never reads stdio) and would reparent to launchd.
    # Kill only PIDs absent from this run's baseline; fail-closed on a kill
    # that does not verify.
    hang_baseline = SmaltTest.Internal.HangReap.baseline()
    on_exit(fn -> SmaltTest.Internal.HangReap.reap!(hang_baseline) end)

    start_supervised!({Pool, @pool_opts})
    :ok
  end

  defp clean_payload, do: :crypto.strong_rand_bytes(64)

  defp as_ok(true), do: {:ok, true}
  defp as_ok(_), do: :not_yet

  # Gate 1: clean wire evaluation -> the documented 429 RU refusal envelope.
  # Context: solo
  test "gate 1: clean eval admits the frame and returns the refusal envelope" do
    assert {:ok, result} = Bridge.eval(clean_payload())
    assert result["code"] == "refusal_envelope"
    assert result["http"] == 429
    assert result["error"] == "TooManyRequests"
  end

  # Gate 2: 65 MiB memory wall -> {:error, {:sandbox_aborted, _}}, BEAM alive.
  # The worker enforces the same 64 MiB ceiling the OS/runtime boundary does;
  # the oversized frame never crosses the port.
  # Context: solo
  test "gate 2: memory-wall payload aborts the sandbox, BEAM survives" do
    wall_payload = :crypto.strong_rand_bytes(65 * 1024 * 1024)

    assert {:error, {:sandbox_aborted, :memory_wall}} = Bridge.eval(wall_payload)
    # Zero BEAM contamination: the node and the pool both outlive the trap.
    assert Process.whereis(Pool) |> Process.alive?()
    assert :erlang.system_info(:port_count) > 0
  end

  # Gate 3: pool self-healing — after any worker death (trap, panic, kill),
  # the pool respawns crash-only and admits a valid transaction immediately.
  # Context: solo
  test "gate 3: pool respawns a killed worker and admits the next eval" do
    {:ok, dead_worker} = Pool.checkout()
    Process.exit(dead_worker, :kill)
    Pool.checkin(dead_worker)

    # Bounded poll: the EXIT-driven fresh respawn must land within budget.
    assert {:ok, _} = SmaltTest.Internal.Poll.eventually(fn -> as_ok(Pool.idle() == 3) end)

    assert {:ok, born_again} = Pool.checkout()
    assert {:ok, result} = Worker.run(born_again, "clean-frame-after-respawn")
    assert result["http"] == 429
    Pool.checkin(born_again)
  end

  # Gate 4: pool_exhausted is typed when every worker is busy.
  # Context: solo
  test "gate 4: drained pool returns typed pool_exhausted" do
    held = for _ <- 1..3, {:ok, w} = Pool.checkout(), do: w
    assert length(held) == 3

    assert {:error, :pool_exhausted} = Pool.checkout()

    for w <- held, do: Pool.checkin(w)
    assert {:ok, _} = SmaltTest.Internal.Poll.eventually(fn -> as_ok(Pool.idle() == 3) end)
    assert {:ok, _} = Bridge.eval(clean_payload())
  end

  # Gate 5: fail-closed on timeout — a hung guest yields a typed refusal,
  # the port drops with its process, and the pool respawns a fresh worker.
  # Context: solo
  test "gate 5: hung guest times out fail-closed and the pool self-heals" do
    start_supervised!(
      Supervisor.child_spec(
        {Pool, [size: 1, timeout_ms: 300, runner_args: ["--hang"], name: Pool.Hang]},
        id: :hang_pool
      )
    )

    assert {:error, {:gate_timeout, :fail_closed}} = Bridge.eval(clean_payload(), pool: Pool.Hang)
    assert Process.whereis(Pool.Hang) |> Process.alive?()
    assert {:ok, _} = SmaltTest.Internal.Poll.eventually(fn -> as_ok(Pool.idle(Pool.Hang) == 1) end)
  end

  # Gate 6: the memory-wall kill is contained to the port/worker — the
  # admitting pool survives an actual guest trap (exit 86) mid-pool.
  # Context: solo
  test "gate 6: guest trap (exit 86) aborts only its worker" do
    start_supervised!(
      Supervisor.child_spec({Pool, [size: 1, runner_args: ["--crash"], name: Pool.Crash]},
        id: :crash_pool
      )
    )

    {:ok, worker} = Pool.checkout(Pool.Crash)
    assert {:error, {:sandbox_aborted, {:exit_status, 86}}} = Worker.run(worker, "panic")
    # The worker died with its port; the pool must heal over the EXIT.
    # The GenServer `{:stop, reason, reply, state}` arm delivers the reply
    # BEFORE the worker processes its own termination, so death is only
    # observable asynchronously — a bare `refute alive?()` here races the
    # exit and flakes (deterministically when the caller wins the scheduler
    # race). Bounded poll observes the real contract: the worker actually
    # terminates (typed timeout if it ever hangs). No-sleep doctrine: this
    # rides the one audited poll implementation.
    assert {:ok, _} =
             SmaltTest.Internal.Poll.eventually(fn ->
               as_ok(not Process.alive?(worker))
             end)

    assert Process.whereis(Pool.Crash) |> Process.alive?()
  end
end
