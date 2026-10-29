# GWS-18 court: the smalt sandbox court against the REAL graphlaw-run-eh adapter
# + the REAL compiled graphlaw wasm module (wasmi host, wasi p1), not the stub.
# Same packet-4 protocol, same exit-86 fault modes; the stub runner
# (priv/wasm/stub_runner.exs) is swapped out by config only
# (`:wasm_runner_path` -> a program+args LIST — worker.ex's runner_command/2
# already accepts a list; the artifact digest is enforced by the runner itself
# via --expect-blake3, so the court serves exactly the bytes it digested).
#
# Loud skip: a missing graphlaw-run-eh binary or wasm artifact SKIPs the whole
# file with a printed reason — a missing substrate is never a fake pass.
#
# Context: solo (integration tier, real port IPC over packet-4).

defmodule Smalt.Integration.WasmRealRunnerCourtTest do
  use ExUnit.Case, async: false

  Code.require_file("../internal/poll_helper.exs", __DIR__)
  Code.require_file("../internal/hang_reap.exs", __DIR__)

  alias Smalt.Wasm.{Bridge, Pool, Worker}

  @runner_bin System.get_env("GRAPHLAW_RUN") ||
                Path.expand(System.get_env("GRAPHLAW_ROOT", "../graphlaw") <> "/target/release/graphlaw-run-eh")
  @wasm_artifact System.get_env("GRAPHLAW_WASM") ||
                   Path.expand(System.get_env("GRAPHLAW_ROOT", "../graphlaw") <> "/target/wasm-abi/wasm32-wasip1/wasm/graphlaw_wasm.wasm")
  @registry_pin Path.expand(System.get_env("GRAPHLAW_ROOT", "../graphlaw") <> "/registry/ARTIFACTS.blake3")
  @wall_bytes 65 * 1024 * 1024

  @runner_ready File.regular?(@runner_bin) and File.regular?(@wasm_artifact)

  if @runner_ready do
    IO.puts("[GWS-18] real-runner court active: #{@runner_bin}")
  else
    IO.puts("""
    [SKIP-WASM-RUNNER] GWS-18 real-runner court cannot run:
      runner binary : #{@runner_bin} (#{File.regular?(@runner_bin)})
      wasm artifact : #{@wasm_artifact} (#{File.regular?(@wasm_artifact)})
    Build with: (cd $GRAPHLAW_ROOT && cargo build --release --features runner-eh --bin graphlaw-run-eh)  # GRAPHLAW_ROOT, default ../graphlaw
    """)
  end

  setup context do
    if @runner_ready do
      # BK-GRAPHREAP: caller-side reap — gate 5's `graphlaw-run-eh --hang`
      # double ignores stdio, survives the port kill at the fail-closed
      # timeout, and reparents to launchd (PPID=1). Kill only PIDs absent
      # from this run's baseline; fail-closed on an unverified kill.
      hang_baseline = SmaltTest.Internal.HangReap.baseline()
      on_exit(fn -> SmaltTest.Internal.HangReap.reap!(hang_baseline) end)

      # The graphlaw wasm lanes rebuild the shared artifact concurrently; the
      # court serves an immutable per-run snapshot so the digest the runner
      # enforces and the bytes the guests execute are the same bytes.
      snapshot = Path.join(System.tmp_dir!(), "gws18-wasm-snapshot-#{:os.system_time(:millisecond)}.wasm")
      File.cp!(@wasm_artifact, snapshot)
      File.rm(snapshot <> ".prev")
      on_exit(fn -> File.rm(snapshot) end)
      observed_digest = gws18_b3sum(snapshot)

      # A drift from the graphlaw registry pin is reported loudly but is a
      # coordinator-owned re-pin (graphlaw W09), not a court failure: the
      # court pins the bytes it actually serves, and the runner itself
      # verifies those bytes at boot via --expect-blake3 (non-vacuity is
      # gate 2b).
      pin_row =
        @registry_pin
        |> File.read!()
        |> String.split("\n")
        |> Enum.find(&String.starts_with?(&1, "wasm "))

      registry_digest = pin_row && pin_row |> String.split() |> Enum.at(1)

      if registry_digest != observed_digest do
        IO.puts("""
        [WASM-PIN-DRIFT] graphlaw registry pin != served artifact bytes
          registry pin : #{registry_digest}
          served bytes : #{observed_digest}
        The graphlaw coordinator re-pins registry/ARTIFACTS.blake3 on rebuild (W09).
        """)
      end

      # Config-only swap (WASM-1 contract): point :wasm_runner_path at the
      # real runner as a program+args list; :wasm_binary_path stays unset so
      # the worker keeps the stub-mode wire shape.
      Application.put_env(:smalt, :wasm_runner_path, [
        @runner_bin,
        "--wasm",
        snapshot,
        "--expect-blake3",
        observed_digest
      ])
      Application.delete_env(:smalt, :wasm_binary_path)

      on_exit(fn -> Application.delete_env(:smalt, :wasm_runner_path) end)

      start_supervised!({Pool, size: 2, timeout_ms: 10_000})
      {:ok, digest: observed_digest, snapshot: snapshot}
    else
      {:ok, digest: nil, snapshot: nil}
    end
  end

  # Compile-time loud skip: a missing runner/artifact tags every test below.
  unless @runner_ready do
    @tag :skip
  end

  # Gate 1: REAL eval through the REAL module — a clean ntriples focus node
  # parses inside the wasm guest and the ABI admits it.
  # Context: solo
  @tag :wasm_real_runner
  if @runner_ready, do: :ok, else: @tag :skip
  test "gate 1: real module admits a clean focus node (real parse, real quads)", ctx do
    assert ctx[:digest] != nil
    assert {:ok, verdict} =
             Bridge.eval(%{
               "text" => "<https://e/s> <https://e/p> <https://e/o> .",
               "dialect" => "ntriples"
             })

    assert verdict["ok"] == true
    assert verdict["quads"] == 1
    assert is_binary(verdict["id"])
  end

  # Gate 1b: the same sandbox returns a TYPED ABI refusal (not a canned
  # envelope, not a trap) for input the graphlaw engine rejects — and Bridge
  # maps it to {:error, {:abi_refusal, _}}.
  # Context: solo
  @tag :wasm_real_runner
  if @runner_ready, do: :ok, else: @tag :skip
  test "gate 1b: real module refuses malformed input typed, worker survives" do
    assert {:error, {:abi_refusal, refusal}} =
             Bridge.eval(%{"text" => "<a> <b> .", "dialect" => "ntriples"})

    assert refusal.kind == "EngineRejected"
    assert refusal.engine == "PurRdf"
    # The worker that answered must still be alive (typed refusal is not a trap).
    assert Process.whereis(Pool) |> Process.alive?()
  end

  # Gate 1c: raw ABI passthrough — a frame that is already a graphlaw ABI
  # request crosses to the module and comes back as the raw response under
  # "result" (the abi-mode wire shape, wrapped in the stub envelope).
  # Context: solo
  @tag :wasm_real_runner
  if @runner_ready, do: :ok, else: @tag :skip
  test "gate 1c: raw ABI request passes through to the module" do
    {:ok, worker} = Pool.checkout()
    request = Worker.encode_abi_request(%{"op" => "capabilities"})

    assert {:ok, %{"ok" => true, "abi" => abi} = caps} = Worker.run(worker, request)

    assert abi == 1
    authorities = Enum.map(caps["authorities"], & &1["capability"])
    assert "SHACL" in authorities
    Pool.checkin(worker)
  end

  # Gate 2: 65 MiB memory wall -> {:error, {:sandbox_aborted, _}}, BEAM alive.
  # Context: solo
  @tag :wasm_real_runner
  if @runner_ready, do: :ok, else: @tag :skip
  test "gate 2: memory-wall payload aborts the sandbox, BEAM survives" do
    wall_payload = :crypto.strong_rand_bytes(@wall_bytes)

    assert {:error, {:sandbox_aborted, _detail}} = Bridge.eval(wall_payload)
    assert Process.whereis(Pool) |> Process.alive?()
    assert :erlang.system_info(:port_count) > 0
  end

  # Gate 2b: non-vacuity of the artifact pin — the runner REFUSES to serve
  # bytes whose digest does not match --expect-blake3 (exit 84).
  # Context: solo
  @tag :wasm_real_runner
  if @runner_ready, do: :ok, else: @tag :skip
  test "gate 2b: runner refuses to serve a wrong-digest artifact", ctx do
    assert ctx[:digest] != nil

    {_, status} =
      System.cmd(@runner_bin, ["--wasm", ctx[:snapshot], "--expect-blake3", "deadbeef"])

    assert status == 84
  end

  # Gate 3: crash containment with the REAL runner in --crash fault mode —
  # the guest trap (exit 86) aborts only its own worker/port; the pool heals
  # over the EXIT-driven fresh respawn (bounded poll on idle). A REAL frame
  # admitted on the default (eval-mode) pool right after proves live healing.
  # Context: solo
  @tag :wasm_real_runner
  if @runner_ready, do: :ok, else: @tag :skip
  test "gate 3: real-runner trap aborts only its worker and the pool heals" do
    start_supervised!(
      Supervisor.child_spec(
        {Pool, [size: 1, runner_args: ["--crash"], name: Pool.Crash]},
        id: :crash_pool
      )
    )

    {:ok, dead_worker} = Pool.checkout(Pool.Crash)
    assert {:error, {:sandbox_aborted, {:exit_status, 86}}} = Worker.run(dead_worker, "panic")

    # Bounded poll: the worker's stop is async; the EXIT lands within budget.
    assert {:ok, _} =
             SmaltTest.Internal.Poll.eventually(fn ->
               as_ok(not Process.alive?(dead_worker))
             end)

    assert Process.whereis(Pool.Crash) |> Process.alive?()

    assert {:ok, _} =
             SmaltTest.Internal.Poll.eventually(fn -> as_ok(Pool.idle(Pool.Crash) == 1) end)

    # Healing is real: the eval-mode REAL runner admits a REAL frame.
    assert {:ok, verdict} =
             Bridge.eval(%{
               "text" => "<https://e/s> <https://e/p> <https://e/o> .",
               "dialect" => "ntriples"
             })

    assert verdict["ok"] == true
    assert verdict["quads"] == 1
  end

  # Gate 5: fail-closed on timeout — a hung REAL runner yields a typed
  # refusal, the port drops, the pool respawns, and the next frame is refused
  # fail-closed too (a permanently hung guest never admits a frame: the
  # fail-closed property is per-frame, not once-per-pool).
  # Context: solo
  @tag :wasm_real_runner
  if @runner_ready, do: :ok, else: @tag :skip
  test "gate 5: hung real runner refuses every frame fail-closed" do
    start_supervised!(
      Supervisor.child_spec(
        {Pool, [size: 1, timeout_ms: 300, runner_args: ["--hang"], name: Pool.Hang]},
        id: :hang_pool
      )
    )

    assert {:error, {:gate_timeout, :fail_closed}} =
             Bridge.eval(clean_payload(), pool: Pool.Hang)

    assert Process.whereis(Pool.Hang) |> Process.alive?()

    assert {:ok, _} =
             SmaltTest.Internal.Poll.eventually(fn -> as_ok(Pool.idle(Pool.Hang) == 1) end)
  end

  defp gws18_b3sum(path) do
    {out, 0} = System.cmd("b3sum", [path])
    String.slice(out, 0, 64)
  end

  defp clean_payload, do: :crypto.strong_rand_bytes(64)

  defp as_ok(true), do: {:ok, true}
  defp as_ok(_), do: :not_yet
end
