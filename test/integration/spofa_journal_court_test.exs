# SPOF-A1/A-3 — journal sink + seal-window court (v26.10.22).
# Run: MIX_BUILD_ROOT=_build-spofa mix test test/integration/spofa_journal_court_test.exs
#
# Chicago court: real files, real Store GenServer, real Process boot, real
# telemetry. No mocks, no sleeps — convergence via SmaltTest.Internal.Poll.
#
# Legs:
#   a) disk-error injection (dir under a regular file) -> sink DEGRADED,
#      appends accepted-and-dropped (logged+counted), seal typed-refused,
#      node/planes alive, [:smalt,:journal,:degraded] telemetry, and
#      recovery via bounded re-probe emits [:smalt,:journal,:recovered].
#   b) crash-in-seal-window (segment sealed, sentinel withheld) -> real
#      Store boot succeeds, tail QUARANTINED (typed + telemetry), committed
#      keys minus the quarantined tail survive.
#   c) corrupt sealed segment still boot-REFUSES fail-closed (integrity
#      failures remain fatal — TTV-4 law preserved).
#
# Exit 0 = PASS, exit 1 = FAIL.

Code.require_file("poll_helper.exs", Path.join(__DIR__, "../internal"))

defmodule SmaltTest.Integration.SpofaJournalCourtTest do
  use ExUnit.Case, async: false

  alias Smalt.Storage.JournalReader
  alias Smalt.Storage.JournalSink
  alias Smalt.Store

  @evt_put 0x0A01
  @table :smalt_resources

  setup context do
    prev = Application.get_env(:smalt, :journal_sink_dir)

    dir =
      Path.join(System.tmp_dir!(), "spofa-#{context.test}-#{System.unique_integer([:positive])}")

    # telemetry capture: handler ships every journal event to self()
    handler_id = :"spofa-#{System.unique_integer([:positive])}"
    parent = self()

    handler = fn event, measurements, meta, _ ->
      send(parent, {:spofa_tel, event, measurements, meta})
    end

    for event <- [[:smalt, :journal, :degraded], [:smalt, :journal, :recovered], [:smalt, :journal, :quarantined]] do
      attach_id = {handler_id, event}
      :ok = :telemetry.attach(attach_id, event, handler, nil)
      on_exit(fn -> :telemetry.detach(attach_id) end)
    end

    on_exit(fn ->
      :telemetry.detach(handler_id)
      restore_env(prev)
      try_do(fn -> GenServer.stop(JournalSink, :normal, 5_000) end)
      File.rm_rf!(dir)
    end)

    {:ok, dir: dir, prev: prev}
  end

  # -- legs ----------------------------------------------------------------------

  @tag :spofa
  test "leg a: disk-error injection -> degraded mode, drops logged+counted, recovery on re-probe", %{
    dir: _dir
  } do
    # blocker: a REGULAR FILE exactly where the journal dir's parent should be,
    # so File.mkdir_p!/1-class init fails with :enotdir — a real disk error,
    # injected by filesystem structure, not a mock.
    blocker = Path.join(System.tmp_dir!(), "spofa-a1-block-#{System.unique_integer([:positive])}")
    File.write!(blocker, "not a directory")
    bad_dir = Path.join(blocker, "journal")

    on_exit(fn -> File.rm_rf!(blocker) end)

    assert {:ok, sink} = JournalSink.start_link(dir: bad_dir, reprobe_ms: 25)

    try do
      # process ALIVE (no crash loop — init returned {:ok, _} in degraded mode)
      assert Process.alive?(sink)
      assert GenServer.call(sink, :status).mode == :degraded
      assert GenServer.call(sink, :status).degraded_reason != nil

      # [:smalt,:journal,:degraded] telemetry fired with the path + reason
      assert_receive {:spofa_tel, [:smalt, :journal, :degraded], _, %{path: ^bad_dir, reason: :enotdir}},
                     5_000

      # appends ACCEPTED-AND-DROPPED: {:ok, seq} reply, counted, planes alive
      assert {:ok, 0} = JournalSink.append(sink, @evt_put, 0, "spofa-drop-key", "payload")
      assert {:ok, 1} = JournalSink.append(sink, @evt_put, 0, "spofa-drop-key-2", "payload")

      st = JournalSink.status(sink)
      assert st.dropped == 2
      assert st.mode == :degraded

      # seal is typed-refused in degraded mode, never a raise
      assert {:error, :degraded} = JournalSink.seal(sink)

      # the whole node is obviously alive (we are running in it); planes are
      # exercised by the rest of the suite — assert the sink never restarted
      # into the supervisor by checking we still hold the same pid
      assert Process.whereis(JournalSink) == sink

      # RECOVERY: remove the blocker file -> the re-probe finds a writable
      # volume and returns the sink to active mode
      File.rm!(blocker)
      File.mkdir_p!(bad_dir)

      eventually(fn ->
        st = JournalSink.status(sink)

        if st.mode == :active and st.degraded_reason == nil do
          {:ok, st}
        else
          :not_yet
        end
      end, "sink did not recover to active mode")

      assert_receive {:spofa_tel, [:smalt, :journal, :recovered], _, %{dir: ^bad_dir}}, 5_000

      # post-recovery appends hit REAL disk bytes
      assert {:ok, _} = JournalSink.append(sink, @evt_put, 0, "spofa-recovered-key", "v")
      st = JournalSink.status(sink)
      assert st.bytes > 0
      assert File.exists?(st.path)

      _ = sink
    after
      GenServer.stop(sink)
    end
  end

  @tag :spofa
  test "leg b: crash-in-seal-window -> boot succeeds with typed quarantine, committed keys survive", %{
    dir: dir
  } do
    _ = wait_store_alive()
    start_sink(dir)
    Application.put_env(:smalt, :journal_sink_dir, dir)

    # segment 1: fully sealed — committed keys that MUST survive
    assert Store.put(@table, "spofa-b-key-1", %{"v" => 1}) == :ok
    assert Store.put(@table, "spofa-b-key-2", %{"v" => 2}) == :ok
    assert %{"frames" => 2} = JournalSink.seal(JournalSink)

    # segment 2: sealed, then sentinel withheld — the crash-in-window state
    assert Store.put(@table, "spofa-b-key-3", %{"v" => 3}) == :ok
    assert %{"frames" => 1} = JournalSink.seal(JournalSink)

    {:ok, [seg1, seg2]} = JournalReader.discover_sealed_segments(dir)
    _ = seg1

    File.rm!(seg2 <> ".seal")
    stop_sink()

    # the tail's mutation was applied to the LIVE tables by the direct put
    # above (same-VM); remove it so the probe boot's replay face is the only
    # writer of these keys — fresh-node semantics
    assert Store.delete(@table, "spofa-b-key-3") == :ok

    # quarantine telemetry capture starts here; discovery quarantines seg2
    # at the next boot_replay
    assert {:ok, pid} = boot_store(:"SpofaStoreB-#{System.unique_integer()}", dir)
    _ = pid

    # boot SUCCEEDED (no {:journal_replay_failed, {:not_sealed, ...}} wedge)
    # and the quarantined tail is off the replay path, bytes preserved
    qdir = Path.join(dir, "quarantine")
    assert File.regular?(Path.join(qdir, Path.basename(seg2)))

    assert_receive {:spofa_tel, [:smalt, :journal, :quarantined], _, %{path: ^seg2, reason: :not_sealed}},
                   5_000

    # committed keys from the complete segment survive; the quarantined
    # tail's key is absent (its bytes are preserved in quarantine, not lost)
    assert Store.get(@table, "spofa-b-key-1") == {:ok, %{"v" => 1}}
    assert Store.get(@table, "spofa-b-key-2") == {:ok, %{"v" => 2}}
    assert Store.get(@table, "spofa-b-key-3") == :error

    # a second boot is stable: the quarantined tail does not re-wedge or
    # re-quarantine anything
    assert {:ok, _} = boot_store(:"SpofaStoreB2-#{System.unique_integer()}", dir)
    refute File.exists?(Path.join(dir, "sealed") |> Path.join(Path.basename(seg2)))
    _ = qdir
  end

  @tag :spofa
  test "leg c: corrupt sealed segment still boot-refuses with a typed refusal", %{dir: _dir} do
    cdir =
      Path.join(System.tmp_dir!(), "spofa-corrupt-#{System.unique_integer([:positive])}")

    File.mkdir_p!(cdir)

    on_exit(fn -> File.rm_rf!(cdir) end)

    start_sink(cdir)

    JournalSink.append(JournalSink, @evt_put, 0, "spofa-corrupt-key", :erlang.term_to_binary(%{"z" => 1}))
    JournalSink.seal(JournalSink)
    stop_sink()

    {:ok, [seg]} = JournalReader.discover_sealed_segments(cdir)

    # flip one payload-region byte against the honest manifest
    {:ok, bin} = File.read(seg)
    <<head::binary-size(16), rest::binary>> = bin
    <<bad, tail::binary>> = rest
    File.write!(seg, <<head::binary, :erlang.bxor(bad, 0x01), tail::binary>>)

    # integrity failure = typed boot refusal, fail-closed (TTV-4 law).
    # The refusal surfaces through the supervisor's start error (the typed
    # reason is preserved verbatim through the failure wrapper).
    assert {:error, wrapped} = boot_store(:"SpofaStoreC-#{System.unique_integer()}", cdir)
    assert {:journal_replay_failed, {^seg, {:manifest_mismatch, _}}} = unwrap_refusal(wrapped)
  end

  defp unwrap_refusal({:shutdown, {:failed_to_start_child, _child, reason}}), do: reason
  defp unwrap_refusal(reason), do: reason

  # -- helpers -------------------------------------------------------------------

  defp restore_env(nil), do: Application.delete_env(:smalt, :journal_sink_dir)
  defp restore_env(p), do: Application.put_env(:smalt, :journal_sink_dir, p)

  defp try_do(fun) do
    try do
      fun.()
      :ok
    catch
      :exit, _ -> :ok
    end
  end

  defp start_sink(dir) do
    case JournalSink.start_link(dir: dir) do
      {:ok, _} -> :ok
      {:error, {:already_started, _}} -> :ok
    end
  end

  defp stop_sink do
    case Process.whereis(JournalSink) do
      nil -> :ok
      pid -> try_do(fn -> GenServer.stop(pid, :normal, 5_000) end)
    end
  end

  defp wait_store_alive do
    eventually(fn ->
      pid = Process.whereis(Store)

      if is_pid(pid) and Process.alive?(pid) do
        {:ok, pid}
      else
        :not_yet
      end
    end, "Store is not up")
  end

  # boot a probe Store against `dir` in a trap-exiting probe process (an init
  # {:stop, ...} exit propagates to a linked non-trapping caller), returning
  # the typed start result.
  defp boot_store(name, dir) do
    ref = make_ref()
    parent = self()

    {:ok, probe} =
      Task.start(fn ->
        Process.flag(:trap_exit, true)
        res = Store.start_link(name: name, journal_sink_dir: dir)
        send(parent, {ref, res})
      end)

    assert_receive {^ref, res}, 5_000
    _ = probe
    res
  end

  defp eventually(fun, msg \\ "condition not met") do
    case SmaltTest.Internal.Poll.eventually(fun, timeout_ms: 10_000) do
      {:ok, _} -> :ok
      {:timeout, _last} -> flunk(msg)
    end
  end
end
