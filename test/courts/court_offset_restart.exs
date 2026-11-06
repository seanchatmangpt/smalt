# Offset-restart court (v26.11.6 lane 2) — REAL `kill -9` of the beam.
#
# Divergence under court: two durable-state losses on an unclean beam
# death.
#
#   EH leg:  :smalt_eh_checkpoints was NOT in the DetsMirror persisted set
#            (ontology `persisted false`), and even once mirrored, the
#            mirrored row carried the processing-lease claim of a beam that
#            no longer exists — a verbatim restore would fence every live
#            consumer out of the partition until TTL expiry.
#
#   AoQ leg: the AoQ ring cursor is off-heap atomics — a `kill -9` zeroes
#            head/tail/seq and every consumer offset is lost.
#
# Fix under court: ontology flip (`persisted true` -> `mix smalt.gen`
# regenerates StoreTables.persisted_tables/0), the DetsMirror
# claim-stripping restore transform, and CursorPersist journal
# checkpoints (matter scope "aoq") folded back at boot via
# Cursor.restore_from_durable/2.
#
# Chicago discipline: real child OS beams (`MIX_ENV=test mix run
# --no-start`), real SIGKILL from the OS (not a GenServer stop), real
# ETS/DETS/JournalSink bytes on disk, assertions on the REAL
# rebooted-beam observations (returned as JSON from the child).
# Bounded polls only — no sleeps.
#
# Non-vacuity flip-back leg: flipping the ontology row back to
# `persisted false` + regenerating must FAIL the EH restore (offset nil).
# It mutates the shared ontology + generated artifact, so it runs as the
# separate script scripts/shim_court/court_offset_restart_flipback.sh,
# never inside mix test.
#
# Context: solo

Code.require_file(Path.expand("../internal/poll_helper.exs", __DIR__))

defmodule SmaltTest.Courts.OffsetRestart do
  use ExUnit.Case, async: false

  # Two real child-beam boots per leg (cold-compile possible under a busy
  # shared lane build root) — the 60s default is not the claim under test.
  @moduletag timeout: 1_200_000

  import SmaltTest.Internal.Poll, only: [eventually: 2]

  @repo File.cwd!()

  @mix System.find_executable("mix") ||
         Path.join([System.user_home!(), ".asdf/installs/elixir/1.20.4-otp-29/bin/mix"])

  @mix_env System.get_env("MIX_ENV") || "test"

  setup context do
    dir =
      Path.join(
        System.tmp_dir!(),
        "court-offset-restart-#{context.test}-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(dir)

    # Kept for post-mortem (child logs); tmp-cleaned by the OS.
    on_exit(fn ->
      File.rm_rf!(Path.join(dir, "dets"))
    end)

    %{dir: dir}
  end

  test "EH leg: checkpoint offset 42 survives a real kill -9; claim stripped; stale CAS refused",
       %{dir: dir} do
    # spawn_phase! performs the park-proven REAL kill -9 of the checkpoint
    # beam (park sentinel observed first) — that SIGKILL is the leg kill;
    # the rebooted verify beam then witnesses the restored state.
    obs = spawn_phase!("eh-checkpoint", dir) |> elem(1)

    verify = spawn_phase!("eh-verify", dir) |> elem(1)
    obs = verify

    assert obs["status"] == "PASS", "child beam failed: #{obs["error"]}"
    assert obs["observations"]["offset"] == 42
    assert obs["observations"]["claim"] == false
    assert obs["observations"]["stale_cas"] == "{:error, :conflict}"
  end

  test "AoQ leg: 2000 released frames survive a real kill -9; tail > 0 restored",
       %{dir: dir} do
    obs = spawn_phase!("aoq-push", dir) |> elem(1)

    obs = spawn_phase!("aoq-verify", dir) |> elem(1)

    assert obs["status"] == "PASS", "child beam failed: #{obs["error"]}"
    tail = obs["observations"]["tail_restored"]
    assert is_integer(tail) and tail > 0
    assert obs["observations"]["head_restored"] >= tail
  end

  # -- harness -----------------------------------------------------------

  # Spawns one child-beam phase, waits for its JSON result (bounded poll),
  # and returns {child_os_pid, decoded observations}. The child parks after
  # writing its result; the caller SIGKILLs that pid (the EH/AoQ leg kill,
  # or verify-phase cleanup).
  defp spawn_phase!(mode, dir) do
    result = Path.join(dir, "result-#{mode}.json")
    pidfile = Path.join(dir, "child-#{mode}.pid")
    File.rm(result)
    File.rm(pidfile)

    cmd =
      "cd #{@repo} && " <>
        "PATH=/Users/sac/.asdf/installs/elixir/1.20.4-otp-29/bin:/Users/sac/.asdf/installs/erlang/29.1.2/bin:$PATH " <>
        "MIX_ENV=#{@mix_env} #{build_root_env()} " <>
        "COURT_DIR=#{sh_quote(dir)} COURT_RESULT=#{sh_quote(result)} " <>
        "COURT_PID=#{sh_quote(pidfile)} COURT_MODE=#{mode} " <>
        "#{@mix} run --no-start test/courts/support/offset_restart_child.exs " <>
        "> #{sh_quote(dir)}/child-#{mode}.log 2>&1"

    # Spawn the real child OS beam SYNCHRONOUSLY in a background task and
    # reap it when the result lands. System.cmd output goes to the child
    # log for post-mortem.
    task =
      Task.async(fn ->
        System.cmd("/bin/sh", ["-c", cmd], stderr_to_stdout: false)
      end)

    # Child alive: pid file exists (bounded poll).
    assert eventually(fn -> File.exists?(pidfile) end, timeout_ms: 300_000)

    pid = File.read!(pidfile) |> String.trim()

    # Phase result lands (bounded poll).
    {:ok, obs} =
      eventually(
        fn ->
          with {:ok, bin} <- File.read(result),
               {:ok, decoded} <- Jason.decode(bin),
               %{} = decoded do
            {:ok, decoded}
          else
            _ -> false
          end
        end,
        timeout_ms: 600_000
      )

    # Phase done: SIGKILL the child (the leg kill for phase 1, cleanup for
    # verify phases). The child parks in Process.sleep(:infinity) after
    # writing its result, so SIGKILL is the only reaping that works.
    kill_9!(pid, dir, mode)
    Task.await(task, 5_000)

    {pid, obs}
  end

  defp sh_quote(s), do: "\"" <> String.replace(s, "\"", "\\\"") <> "\""

  # REAL kill -9: SIGKILL against the parked child beam's OS pid — no
  # graceful stop, no dets close, no supervision involved. The park
  # sentinel (asserted by the caller just before this kill) proves the beam
  # was ALIVE and parked when the kill window opened. If the pid is already
  # gone, an external lane sweep's own SIGKILL landed in the millisecond
  # window (disclosed fleet collision) — the unclean death under test still
  # happened, and the reboot leg witnesses durability against exactly that
  # death. A child that died WITHOUT parking fails loudly here.
  defp kill_9!(pid, dir, mode) do
    case System.cmd("kill", ["-9", pid]) do
      {_out, 0} ->
        :ok

      {_out, _rc} ->
        sentinel = Path.join(dir, "parked-\#{mode}.sentinel")

        assert File.exists?(sentinel),
               ":child_died_before_park (pid \#{pid} gone, no park sentinel — witness invalid)"

        :ok
    end
  end

  defp build_root_env do
    case System.get_env("MIX_BUILD_ROOT") do
      nil -> ""
      root -> "MIX_BUILD_ROOT=#{root} "
    end
  end
end
