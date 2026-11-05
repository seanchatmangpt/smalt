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

    on_exit(fn ->
      File.rm_rf!(dir)
    end)

    %{dir: dir}
  end

  test "EH leg: checkpoint offset 42 survives a real kill -9; claim stripped; stale CAS refused",
       %{dir: dir} do
    pid = spawn_phase!("eh-checkpoint", dir) |> elem(0)

    # REAL kill -9: SIGKILL from the OS — no graceful stop, no dets close.
    kill_9!(pid)

    obs = spawn_phase!("eh-verify", dir) |> elem(1)

    assert obs["status"] == "PASS", "child beam failed: #{obs["error"]}"
    assert obs["observations"]["offset"] == 42
    assert obs["observations"]["claim"] == false
    assert obs["observations"]["stale_cas"] == "{:error, :conflict}"
  end

  test "AoQ leg: 2000 released frames survive a real kill -9; tail > 0 restored",
       %{dir: dir} do
    pid = spawn_phase!("aoq-push", dir) |> elem(0)
    kill_9!(pid)

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

    port =
      Port.open(
        {:spawn_executable, "/bin/sh"},
        [
          :exit_status,
          :stderr_to_stdout,
          args: [
            "-c",
            "cd #{@repo} && COURT_DIR=#{dir} COURT_RESULT=#{result} COURT_PID=#{pidfile} " <>
              "MIX_ENV=#{@mix_env} #{build_root_env()} #{@mix} run --no-start --no-compile " <>
              "test/courts/support/offset_restart_child.exs"
          ]
        ]
      )

    # Child alive: pid file exists (bounded poll; a cold lane build root
    # makes the child boot real and slow — the deadline is generous).
    assert eventually(fn -> File.exists?(pidfile) end, timeout_ms: 120_000)

    pid = File.read!(pidfile) |> String.trim()

    # Phase result lands (bounded poll).
    {:ok, obs} =
      eventually(
        fn ->
          with {:ok, bin} <- File.read(result),
               %{} = decoded <- Jason.decode(bin) do
            {:ok, decoded}
          else
            _ -> false
          end
        end,
        timeout_ms: 240_000
      )

    Port.close(port)
    obs
  end

  # REAL kill -9: SIGKILL from the OS against the child beam's OS pid —
  # no graceful stop, no dets close, no supervision involved.
  defp kill_9!(pid) do
    assert {_out, 0} = System.cmd("kill", ["-9", pid])
    :ok
  end

  defp build_root_env do
    case System.get_env("MIX_BUILD_ROOT") do
      nil -> ""
      root -> "MIX_BUILD_ROOT=#{root} "
    end
  end
end
