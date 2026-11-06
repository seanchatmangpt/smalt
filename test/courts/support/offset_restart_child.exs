# Offset-restart court child beam (court_offset_restart.exs harness).
#
# Spawned by the court as a real child OS beam (`MIX_ENV=test mix run
# --no-start <script>`). Mode from env COURT_MODE:
#
#   eh-checkpoint — real Smalt.Store + EH Server + DetsMirror; write
#                   checkpoint offset 42 with a live claim, sync the
#                   dets mirror, write the sentinel.
#   eh-verify     — rebooted beam: same tables + mirror dir; DetsMirror
#                   restore (repair: true — the kill -9 leaves torn dets)
#                   with the claim-stripping transform; assert offset 42
#                   restored, claim stripped, stale-CAS refused
#                   {:error, :conflict}.
#   aoq-push      — real JournalSink (matter scope "aoq") + CursorPersist;
#                   release_tail 2000 + note_release 2000 + flush + seal
#                   the scope + sentinel.
#   aoq-verify    — rebooted beam: JournalSink + CursorPersist boot fold;
#                   assert Cursor.tail == 2000 (> 0).
#
# The child writes a JSON result file (env COURT_RESULT) and a park
# sentinel; the parent court asserts on those real rebooted-beam values.
defmodule Courts.OffsetRestartChild do
  @checkpoints :smalt_eh_checkpoints

  def run do
    dir = env_required("COURT_DIR")
    result = env_required("COURT_RESULT")
    mode = env_required("COURT_MODE")

    # Parent kills THIS OS pid with a real `kill -9` between phases.
    File.write!(env_required("COURT_PID"), :os.getpid() |> List.to_string())

    payload =
      try do
        %{"status" => "PASS", "observations" => run_mode(mode, dir)}
      rescue
        e ->
          %{"status" => "FAIL", "error" => Exception.format(:error, e, __STACKTRACE__)}
      catch
        :exit, reason ->
          %{"status" => "FAIL", "error" => "exit: #{inspect(reason)}"}
      end

    File.write!(result, Jason.encode!(payload))

    # Park until the parent SIGKILLs this beam: the phase result is durable
    # on disk; the process has nothing lawful left to do. The park sentinel
    # is written FIRST so the parent's kill -9 provably lands on a live,
    # parked beam (never a silently already-dead pid). SLEEP-CLASS:
    # SCHEDULING (parks until externally killed by the court harness).
    File.write!(Path.join(dir, "parked-#{mode}.sentinel"), :os.getpid() |> List.to_string())
    Process.sleep(:infinity)
  end

  # -- EH leg -----------------------------------------------------------

  defp run_mode("eh-checkpoint", dir) do
    store!()
    {:ok, _} = Smalt.Messaging.EventHubs.Server.start_link()
    :ok = Smalt.Messaging.EventHubs.ensure_tables()
    start_mirror!(dir)

    checkpoint = %{
      "offset" => 42,
      "claim" => %{"owner" => "court-owner", "until" => 9_999_999_999_999}
    }

    :ok = Smalt.Store.put(@checkpoints, {group(), part()}, checkpoint)
    :ok = Smalt.Store.DetsMirror.sync(mirror_name())

    %{"phase" => "eh-checkpoint", "offset_written" => 42}
  end

  defp run_mode("eh-verify", dir) do
    store!()
    {:ok, _} = Smalt.Messaging.EventHubs.Server.start_link()
    :ok = Smalt.Messaging.EventHubs.ensure_tables()
    start_mirror!(dir)
    {:ok, _counts} = Smalt.Store.DetsMirror.restore(mirror_name())

    restored =
      case :ets.lookup(@checkpoints, {group(), part()}) do
        [{_k, cp}] -> cp
        [] -> nil
      end

    # CAS with the STALE claim (the pre-crash lease) must be refused: the
    # restored row is claim-stripped, so expect != current.
    stale_expect = %{"offset" => 42, "claim" => %{"owner" => "court-owner"}}
    cas = Smalt.Messaging.EventHubs.Checkpoints.compare_and_swap(group(), part(), stale_expect, %{"offset" => 43})

    # The child asserts, fail-closed: the rebooted beam itself proves the
    # restore. Under the FLIPPED registry (flip-back leg) the checkpoints
    # table is not mirrored, so restored is nil and this raise IS the
    # court flip the non-vacuity leg witnesses.
    restored || raise(":checkpoint_row_not_restored")
    42 = restored["offset"]
    false = Map.has_key?(restored, "claim")
    {:error, :conflict} = cas

    %{
      "phase" => "eh-verify",
      "offset" => restored["offset"],
      "claim" => false,
      "stale_cas" => inspect(cas)
    }
  end

  # -- AoQ leg ----------------------------------------------------------

  defp run_mode("aoq-push", dir) do
    {sink, cursor, persist} = aoq_boot!(dir)
    n = 2000

    # Real consumer behavior: release tail slots on the ring, THEN notify
    # the checkpoint surface (CursorPersist observes; it never owns the
    # cursor). At least one auto-checkpoint fires past `every` (1024),
    # plus an explicit flush frame; the scope is then SEALED so the bytes
    # are durable before the kill -9 (an unsealed active segment is never
    # read by the boot fold).
    Smalt.Aoq.Cursor.release_tail(cursor, n)
    Smalt.Aoq.CursorPersist.note_release(persist, n)
    {:ok, _seq} = Smalt.Aoq.CursorPersist.flush(persist)

    # seal/2 returns the sealed-segment meta map on success (or {:error,_}).
    case Smalt.Storage.JournalSink.seal(sink, matter_scope: "aoq") do
      m when is_map(m) -> :ok
      :ok -> :ok
      other -> raise ":scope_seal_failed #{inspect(other)}"
    end

    %{
      "phase" => "aoq-push",
      "released" => n,
      "tail_after_push" => Smalt.Aoq.Cursor.tail(cursor),
      "head_after_push" => Smalt.Aoq.Cursor.head(cursor)
    }
  end

  defp run_mode("aoq-verify", dir) do
    {_sink, cursor, _persist} = aoq_boot!(dir)

    %{
      "phase" => "aoq-verify",
      "tail_restored" => Smalt.Aoq.Cursor.tail(cursor),
      "head_restored" => Smalt.Aoq.Cursor.head(cursor)
    }
  end

  # -- helpers ----------------------------------------------------------

  defp aoq_boot!(dir) do
    sink = sink_name()
    persist = persist_name()
    cursor = Smalt.Aoq.Cursor.new()

    {:ok, _} =
      Smalt.Storage.JournalSink.start_link(
        name: sink,
        dir: Path.join(dir, "aoq_journal"),
        sync_interval_ms: 100
      )

    {:ok, _} =
      Smalt.Aoq.CursorPersist.start_link(
        name: persist,
        sink: sink,
        cursor: cursor,
        dir: Path.join(dir, "aoq_journal"),
        checkpoint_every: 1024
      )

    {sink, cursor, persist}
  end

  defp store!() do
    case Smalt.Store.start_link() do
      {:ok, _} -> :ok
      {:error, {:already_started, _}} -> :ok
    end

    # Store partitions materialize asynchronously after the supervisor
    # returns — poll the checkpoint table into existence (bounded, inline
    # audited-poll idiom; no Process.sleep).
    wait_for_table(@checkpoints, System.monotonic_time(:millisecond) + 15_000)
  end

  defp wait_for_table(_table, deadline) do
    cond do
      :ets.info(@checkpoints) != :undefined -> :ok
      System.monotonic_time(:millisecond) >= deadline -> raise ":store_tables_not_up"
      true -> :erlang.yield(); wait_for_table(@checkpoints, deadline)
    end
  end

  defp start_mirror!(dir) do
    dets_dir = Path.join(dir, "dets")
    File.mkdir_p!(dets_dir)

    # A rebooted mirror opens with repair: true — the kill -9 leg leaves the
    # un-closed :dets files needing repair; a synced file survives the
    # repair byte-exact (DetsMirror AZB-06 contract).
    repair = System.get_env("COURT_MODE") == "eh-verify"

    case Smalt.Store.DetsMirror.start_link(dir: dets_dir, name: mirror_name(), repair: repair) do
      {:ok, _} -> :ok
      {:error, {:already_started, _}} -> :ok
    end
  end

  defp mirror_name, do: Courts.OffsetRestartMirror
  defp sink_name, do: Courts.OffsetRestartSink
  defp persist_name, do: Courts.OffsetRestartPersist
  defp group, do: "court-group"
  defp part, do: "0"

  defp env_required(key) do
    case System.get_env(key) do
      nil -> raise "missing env #{key}"
      v -> v
    end
  end
end

Courts.OffsetRestartChild.run()
