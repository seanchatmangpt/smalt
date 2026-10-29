Code.require_file("poll_helper.exs", Path.join(__DIR__, "../internal"))

defmodule SmaltTest.Integration.Ttv4JournalBootReplayCourt do
  @moduledoc """
  TTV-4 — JournalReader boot-replay wired into `Smalt.Store` (PROD-1).

  Chicago court: REAL Store GenServer, REAL JournalSink writer, REAL sealed
  bytes on disk, REAL Process.exit kill + supervisor restart. No mocks, no
  sleeps — convergence is observed via `SmaltTest.Internal.Poll.eventually/2`
  (the one audited poll implementation, test/internal/poll_helper.exs).
  """

  use ExUnit.Case, async: false

  alias Smalt.Storage.JournalReader
  alias Smalt.Storage.JournalSink
  alias Smalt.Store

  @tables Smalt.StoreTables.table_names()
  @evt_put 0x0A01
  @evt_delete 0x0A02

  setup context do
    prev = Application.get_env(:smalt, :journal_sink_dir)

    dir =
      Path.join(System.tmp_dir!(), "ttv4-#{context.test}-#{System.unique_integer([:positive])}")

    File.mkdir_p!(dir)

    on_exit(fn ->
      restore_env(prev)
      try_do(fn -> GenServer.stop(JournalSink, :normal, 5_000) end)
      File.rm_rf!(dir)
      File.rm_rf!(corrupt_dir(context))
    end)

    {:ok, dir: dir, prev: prev}
  end

  # -- helpers ----------------------------------------------------------------

  defp restore_env(nil), do: Application.delete_env(:smalt, :journal_sink_dir)
  defp restore_env(p), do: Application.put_env(:smalt, :journal_sink_dir, p)

  defp corrupt_dir(context), do: Path.join(System.tmp_dir!(), "ttv4-corrupt-#{context.test}")

  defp try_do(fun) do
    try do
      fun.()
      :ok
    catch
      :exit, _ -> :ok
    end
  end

  # Start the real named sink if the config-gated Application child is absent.
  defp start_sink(dir) do
    case JournalSink.start_link(dir: dir) do
      {:ok, _} -> :ok
      {:error, {:already_started, _}} -> :ok
    end
  end

  defp wait_store_alive do
    case SmaltTest.Internal.Poll.eventually(
           fn ->
             pid = Process.whereis(Store)

             if is_pid(pid) and Process.alive?(pid) and tables_up?() do
               {:ok, pid}
             else
               :not_yet
             end
           end,
           timeout_ms: 10_000
         ) do
      {:ok, pid} -> pid
      {:timeout, last} -> flunk("Store is not up: #{inspect(last)}")
    end
  end

  defp wait_store_up(prev_pid) do
    case SmaltTest.Internal.Poll.eventually(
           fn ->
             pid = Process.whereis(Store)

             if is_pid(pid) and pid != prev_pid and Process.alive?(pid) and tables_up?() do
               {:ok, pid}
             else
               :not_yet
             end
           end,
           timeout_ms: 10_000
         ) do
      {:ok, pid} -> pid
      {:timeout, last} -> flunk("Store did not come back up: #{inspect(last)}")
    end
  end

  defp stop_sink do
    case Process.whereis(Smalt.Storage.JournalSink) do
      nil -> :ok
      pid -> try_do(fn -> GenServer.stop(pid, :normal, 5_000) end)
    end
  end

  defp tables_up?, do: Enum.all?(@tables, &(:ets.info(&1) != :undefined))

  # Attempt a boot against the given journal dir in a trap-exiting probe
  # process (an `init {:stop, ...}` exit propagates to a linked non-trapping
  # caller), returning the typed start result.
  defp boot_refusal(dir, name) do
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

  defp assert_get(table, key, expected) do
    assert Store.get(table, key) == {:ok, expected}
  end

  # -- legs ---------------------------------------------------------------------

  @tag :ttv4
  test "leg1: default OFF is byte-identical — put/get/delete work with no sink process" do
    assert Application.get_env(:smalt, :journal_sink_dir) == nil
    refute Process.whereis(Smalt.Storage.JournalSink)

    table = :smalt_resources

    assert Store.put(table, "ttv4-off-key", %{"v" => 1}) == :ok
    assert_get(table, "ttv4-off-key", %{"v" => 1})
    assert Store.delete(table, "ttv4-off-key") == :ok
    assert Store.get(table, "ttv4-off-key") == :error
  end

  @tag :ttv4
  test "leg2: crash court — committed keys survive kill + supervisor restart via journal replay", %{
    dir: dir
  } do
    _ = wait_store_alive()
    start_sink(dir)
    Application.put_env(:smalt, :journal_sink_dir, dir)

    t_res = :smalt_resources
    t_sub = :smalt_subscriptions

    assert Store.put(t_res, "ttv4-crash-key-1", %{"x" => 42}) == :ok
    assert Store.put(t_res, "ttv4-crash-key-2", %{"y" => [1, 2, 3]}) == :ok
    assert Store.put(t_sub, "ttv4-sub-key", %{"subscriptionId" => "ttv4"}) == :ok
    # tombstone leg: deleted key must NOT resurrect on replay
    assert Store.delete(t_res, "ttv4-crash-key-1") == :ok

    # seal so the frames live in sealed segments (replay reads sealed only)
    assert %{"frames" => sealed_frame_count} = JournalSink.seal(JournalSink)
    assert sealed_frame_count >= 3

    # sealed-bytes face: the store's own frames are on the wire correctly
    {:ok, segs} = JournalReader.discover_sealed_segments(dir)
    assert length(segs) >= 1

    {:ok, frames} = JournalReader.read_sealed_segment(Enum.fetch!(segs, 0))
    store_frames = Enum.filter(frames, &(&1.event_type in [@evt_put, @evt_delete]))
    # 3 puts + 1 tombstone, exactly our mutations
    assert length(store_frames) == 4

    assert Enum.any?(
             store_frames,
             &(&1.key == "ttv4-crash-key-1" and &1.event_type == @evt_delete)
           )

    # REAL kill — no mocks. Supervisor (Smalt.Plane.DataSupervisor) restarts.
    pid = Process.whereis(Store)
    Process.exit(pid, :kill)
    _new_pid = wait_store_up(pid)

    # every committed key survives; the deleted key does not resurrect
    assert_get(t_res, "ttv4-crash-key-2", %{"y" => [1, 2, 3]})
    assert Store.get(t_res, "ttv4-crash-key-1") == :error
    assert_get(t_sub, "ttv4-sub-key", %{"subscriptionId" => "ttv4"})
  end

  @tag :ttv4
  test "leg3: corrupt sealed segment boot-refuses with a typed refusal", %{dir: _dir} do
    cdir = corrupt_dir(%{test: "leg3"})

    # A 1-bit flip against the honest manifest -> {:manifest_mismatch, ...}
    # (reader refuses BEFORE any frame parse). Build the segment with the real
    # writer, then flip one payload byte in the sealed file.
    start_sink(cdir)

    JournalSink.append(JournalSink, @evt_put, 0, "ttv4-corrupt-key", :erlang.term_to_binary(%{
      "z" => 1
    }))

    JournalSink.seal(JournalSink)
    stop_sink()

    {:ok, [seg]} = JournalReader.discover_sealed_segments(cdir)
    {:ok, bin} = File.read(seg)
    # flip the first payload-region byte (well past the 8-byte frame header)
    <<head::binary-size(16), rest::binary>> = bin
    <<bad, tail::binary>> = rest
    File.write!(seg, <<head::binary, :erlang.bxor(bad, 0x01), tail::binary>>)

    # BK-69 envelope note: under the TTV-5 ensemble, Boot is a supervised
    # child, so the same typed refusal surfaces as a child-start failure of
    # the ensemble — the refusal is intact, one envelope deeper.
    assert {:error, {:shutdown, {:failed_to_start_child, Smalt.Store.Boot,
                                  {:journal_replay_failed, {^seg, {:manifest_mismatch, _}}}}}} =
             boot_refusal(cdir, Ttv4CorruptStoreA)
  end

  @tag :ttv4
  test "leg4: truncated tail segment boot-refuses with a typed refusal", %{dir: _dir} do
    cdir = corrupt_dir(%{test: "leg4"})

    start_sink(cdir)
    JournalSink.append(JournalSink, @evt_put, 0, "ttv4-trunc-key", :erlang.term_to_binary(%{"w" => 2}))
    JournalSink.seal(JournalSink)
    stop_sink()

    {:ok, [seg]} = JournalReader.discover_sealed_segments(cdir)
    {:ok, bin} = File.read(seg)
    # truncate to a dangling partial header (< 8 bytes) and re-stamp the
    # manifest sha256 so the truncation reaches the per-frame gate
    <<good::binary-size(5), _::binary>> = bin
    File.write!(seg, good)
    rewrite_manifest_sha(cdir, seg)

    # BK-69 envelope note (same law as leg3): typed refusal intact, surfaced
    # as the ensemble's Boot child-start failure.
    assert {:error, {:shutdown, {:failed_to_start_child, Smalt.Store.Boot,
                                  {:journal_replay_failed, {^seg, {:truncated_tail, _}}}}}} =
             boot_refusal(cdir, Ttv4CorruptStoreB)
  end

  defp rewrite_manifest_sha(_dir, seg) do
    meta_path = seg <> ".meta.json"
    {:ok, body} = File.read(meta_path)
    meta = Jason.decode!(body)
    {:ok, new_bin} = File.read(seg)
    meta = Map.put(meta, "sha256", Base.encode16(:crypto.hash(:sha256, new_bin), case: :lower))
    File.write!(meta_path, Jason.encode!(meta))
  end
end
