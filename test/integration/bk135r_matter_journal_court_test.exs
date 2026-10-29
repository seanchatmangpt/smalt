# BK-135r — matter-partitioned journal paths (v26.10.22).
# Run: MIX_BUILD_ROOT=_build-bk135r mix test test/integration/bk135r_matter_journal_court.exs
#
# Chicago court: real files, real sink GenServer, real Store boot, real
# telemetry. No mocks, no sleeps — convergence via SmaltTest.Internal.Poll.
#
# Legs:
#   a) two matters' frames interleave in time but replay strictly per-scope.
#   b) quarantine in matter ALPHA never affects matter BRAVO's boot.
#   c) legacy no-scope path byte-identical in law (SJ-1/TTV-4 stay green;
#      scope validation refuses traversal-class scope names).
#   d) shim leg: scripts/shim_court/bk135r_scoping_court.sh — disabling
#      scoping must turn leg (a) red.
#
# Exit 0 = PASS, exit 1 = FAIL.

Code.require_file("poll_helper.exs", Path.join(__DIR__, "../internal"))

defmodule SmaltTest.Integration.Bk135rMatterJournalCourtTest do
  use ExUnit.Case, async: false

  alias Smalt.Storage.JournalReader
  alias Smalt.Storage.JournalSink
  alias Smalt.Store

  @evt_put 0x0A01
  @table :smalt_resources

  defp tid(table) do
    Smalt.StoreTables.table_names()
    |> Enum.with_index()
    |> Enum.find_value(fn {t, i} -> if t == table, do: i end)
  end

  setup context do
    dir =
      Path.join(System.tmp_dir!(), "bk135r-#{context.test}-#{System.unique_integer([:positive])}")

    on_exit(fn -> File.rm_rf!(dir) end)

    handler_id = :"bk135r-#{System.unique_integer([:positive])}"
    parent = self()

    handler = fn event, measurements, meta, _ ->
      send(parent, {:bk135r_tel, event, measurements, meta})
    end

    for event <- [
          [:smalt, :journal, :degraded],
          [:smalt, :journal, :recovered],
          [:smalt, :journal, :quarantined]
        ] do
      attach_id = {handler_id, event}
      :ok = :telemetry.attach(attach_id, event, handler, nil)
      on_exit(fn -> :telemetry.detach(attach_id) end)
    end

    {:ok, dir: dir}
  end

  # -- legs ----------------------------------------------------------------------

  @tag :bk135r
  test "leg a: interleaved matters replay strictly per-scope", %{dir: dir} do
    sink_name = :"Bk135rSinkA-#{System.unique_integer()}"
    assert {:ok, sink} = JournalSink.start_link(name: sink_name, dir: dir)

    try do
      # time-interleaved appends to ONE sink: a1, b1, a2, b2
      assert {:ok, 0} =
               JournalSink.append_frame(sink, @evt_put, tid(:smalt_resources), "a1", <<1>>,
                 matter_scope: "alpha"
               )

      assert {:ok, 0} =
               JournalSink.append_frame(sink, @evt_put, tid(:smalt_resources), "b1", <<2>>,
                 matter_scope: "bravo"
               )

      assert {:ok, 1} =
               JournalSink.append_frame(sink, @evt_put, tid(:smalt_resources), "a2", <<3>>,
                 matter_scope: "alpha"
               )

      assert {:ok, 1} =
               JournalSink.append_frame(sink, @evt_put, tid(:smalt_resources), "b2", <<4>>,
                 matter_scope: "bravo"
               )

      # per-scope seal
      meta_a = JournalSink.seal(sink, matter_scope: "alpha")
      assert %{"frames" => 2, "first_seq" => 0, "last_seq" => 1} = meta_a

      meta_b = JournalSink.seal(sink, matter_scope: "bravo")
      assert %{"frames" => 2, "first_seq" => 0, "last_seq" => 1} = meta_b

      # discovery is per-scope
      assert {:ok, [seg_a]} = JournalReader.discover_sealed_segments(dir, matter_scope: "alpha")
      assert {:ok, [seg_b]} = JournalReader.discover_sealed_segments(dir, matter_scope: "bravo")

      assert String.contains?(seg_a, "matter_alpha")
      assert String.contains?(seg_b, "matter_bravo")
      refute String.contains?(seg_a, "matter_bravo")
      refute String.contains?(seg_b, "matter_alpha")

      # replay is strictly per-scope: alpha's frames only, alpha's SeqIDs
      assert {:ok, frames_a} = JournalReader.read_sealed_segment(seg_a)
      assert [%{key: "a1", seq_id: 0, payload: <<1>>}, %{key: "a2", seq_id: 1, payload: <<3>>}] =
               frames_a

      assert {:ok, frames_b} = JournalReader.read_sealed_segment(seg_b)
      assert [%{key: "b1", seq_id: 0, payload: <<2>>}, %{key: "b2", seq_id: 1, payload: <<4>>}] =
               frames_b

      # an unseen scope is an empty replay, not an error
      assert {:ok, []} = JournalReader.discover_sealed_segments(dir, matter_scope: "charlie")

      # an invalid scope is a typed refusal BEFORE any filesystem effect
      assert {:error, {:bad_matter_scope, "../escape"}} =
               JournalSink.append_frame(sink, @evt_put, 0, "x", "y", matter_scope: "../escape")

      assert {:error, {:bad_matter_scope, "a/b"}} =
               JournalSink.append_frame(sink, @evt_put, 0, "x", "y", matter_scope: "a/b")

      assert {:ok, []} = JournalReader.discover_sealed_segments(dir, matter_scope: "../escape")

      # no stray roots: exactly the two lawful scope dirs exist beside the
      # legacy active/sealed dirs the sink mints at init
      assert Enum.sort(File.ls!(dir)) == ["active", "matter_alpha", "matter_bravo", "sealed"]
    after
      GenServer.stop(sink)
    end
  end

  @tag :bk135r
  test "leg b: quarantine in matter alpha never affects matter bravo's boot", %{dir: dir} do
    sink_name = :"Bk135rSinkB-#{System.unique_integer()}"
    assert {:ok, sink} = JournalSink.start_link(name: sink_name, dir: dir)

    try do
      # bravo: fully sealed committed key (MUST survive B's boot)
      assert {:ok, _} =
               JournalSink.append_frame(sink, @evt_put, tid(:smalt_resources), "bk135r-b-key",
                 :erlang.term_to_binary(%{"v" => 1}),
                 matter_scope: "bravo"
               )

      assert %{"frames" => 1} = JournalSink.seal(sink, matter_scope: "bravo")

      # alpha: sealed, then the .seal sentinel withheld — the crash-window tail
      assert {:ok, _} =
               JournalSink.append_frame(sink, @evt_put, tid(:smalt_resources), "bk135r-a-key",
                 :erlang.term_to_binary(%{"v" => 2}),
                 matter_scope: "alpha"
               )

      assert %{"frames" => 1} = JournalSink.seal(sink, matter_scope: "alpha")

      {:ok, [seg_a]} = JournalReader.discover_sealed_segments(dir, matter_scope: "alpha")
      File.rm!(seg_a <> ".seal")
    after
      GenServer.stop(sink)
    end

    bravo_root = JournalSink.matter_root(dir, "bravo")

    # ALPHA discovery quarantines ALPHA's tail under ALPHA's root only
    assert {:ok, []} = JournalReader.discover_sealed_segments(dir, matter_scope: "alpha")

    alpha_root = JournalSink.matter_root(dir, "alpha")

    assert File.regular?(
             Path.join([alpha_root, "quarantine", "seg-00000000000000000000.journal"])
           )

    assert_receive {:bk135r_tel, [:smalt, :journal, :quarantined], _,
                    %{dir: ^alpha_root, reason: :not_sealed}},
                   5_000

    # BRAVO discovery is untouched: its segment still listed, replay intact
    assert {:ok, [seg_b]} = JournalReader.discover_sealed_segments(dir, matter_scope: "bravo")
    assert {:ok, [%{key: "bk135r-b-key"}]} = JournalReader.read_sealed_segment(seg_b)

    # BRAVO boots a REAL probe Store against B's scope root: replay succeeds,
    # committed keys restored, and a second boot is stable
    assert {:ok, _pid} = boot_store(:"Bk135rStoreB-#{System.unique_integer()}", bravo_root)
    assert Store.get(@table, "bk135r-b-key") == {:ok, %{"v" => 1}}

    assert {:ok, _pid2} = boot_store(:"Bk135rStoreB2-#{System.unique_integer()}", bravo_root)

    # the quarantined alpha bytes are preserved, never deleted
    assert byte_size(File.read!(Path.join([alpha_root, "quarantine", "seg-00000000000000000000.journal"]))) > 0
  end

  @tag :bk135r
  test "leg c: legacy no-scope path is byte-identical in law", %{dir: dir} do
    sink_name = :"Bk135rSinkC-#{System.unique_integer()}"
    assert {:ok, sink} = JournalSink.start_link(name: sink_name, dir: dir)

    try do
      # legacy append API — the pre-BK-135r call shape, unchanged
      assert {:ok, 0} = JournalSink.append(sink, @evt_put, tid(:smalt_resources), "legacy-key",
        :erlang.term_to_binary(%{"v" => 9}))

      st = JournalSink.status(sink)
      assert st.bytes > 0 and st.frames == 1 and st.mode == :active
      refute String.contains?(st.path, "matter_")

      assert %{"frames" => 1} = JournalSink.seal(sink)

      # legacy layout: no matter_* dirs minted by the legacy path
      assert Enum.sort(File.ls!(dir)) == ["active", "sealed"]

      {:ok, [seg]} = JournalReader.discover_sealed_segments(dir)
      assert {:ok, [%{key: "legacy-key", seq_id: 0}]} = JournalReader.read_sealed_segment(seg)
      refute String.contains?(seg, "matter_")

      # append_frame with NO scope rides the same legacy path and layout
      assert {:ok, 1} = JournalSink.append_frame(sink, @evt_put, tid(:smalt_resources), "legacy-key-2",
        :erlang.term_to_binary(%{"v" => 10}))

      assert JournalSink.status(sink).path |> String.contains?("active")
    after
      GenServer.stop(sink)
    end
  end

  # -- helpers -------------------------------------------------------------------

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
