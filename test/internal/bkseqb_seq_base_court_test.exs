# BK-SEQB — Journal seq BASE pin (EXPL11-R1 observation chase-down).
#
# EXPL11-R1 (docs/jira/v26.10.22/receipts/expl11r1-ledger-range.md, "Note on
# scope") recorded that an isolated --no-start boot showed 0-based JournalSink
# seqs and flagged a possible divergence from "historical 1-based" ids.
# Root cause (BK-SEQB): there is no 1-based path anywhere. JournalSink.init/1
# seeds `next_seq: 0` (lib/smalt/storage/journal_sink.ex:266) and no boot,
# plane-subset, or TTV-4 replay path ever adds an offset — the first append on
# ANY shape gets seq 0. The merged-tree az3/az3b courts agree (their expected
# ["2.1","3.1","4.1"] follows two setup appends that received 0.1/1.1).
#
# This court PINS the base so it cannot silently drift: production boot
# (the ConfidentialLedger.Supervisor mount) and the isolated shape must agree
# on first-seq 0. A future "fix" to 1-based flips these legs red loudly.
#
# Chicago: real JournalSink on real disk, real supervised ACL mount, no mocks.
#
# Run: MIX_BUILD_ROOT=_build-seqb mix test test/internal/bkseqb_seq_base_court_test.exs

defmodule BkSeqb.SeqBaseCourt do
  use ExUnit.Case, async: false

  alias Smalt.ConfidentialLedger.Service
  alias Smalt.Storage.JournalSink

  setup ctx do
    # AZ-3b law: the Service/Sink names are owned by the supervised data-plane
    # mount. Private-instance legs lawfully terminate the mount subtree for the
    # test's duration and restart it on exit (same pattern as az3 setup).
    mount_restart =
      case Supervisor.terminate_child(Smalt.Plane.DataSupervisor, Smalt.ConfidentialLedger.Supervisor) do
        :ok -> :restart
        {:error, _} -> :noop
      end

    root = Path.join(System.tmp_dir!(), "seqb-#{ctx.test}-#{:erlang.unique_integer([:positive])}")
    File.mkdir_p!(root)
    dir = Path.join(root, "journal")

    {:ok, _} =
      JournalSink.start_link(
        dir: dir,
        name: JournalSink,
        segment_ceiling: 4_000,
        sync_interval_ms: 3_600_000
      )

    on_exit(fn ->
      case mount_restart do
        :restart ->
          _ = Supervisor.restart_child(Smalt.Plane.DataSupervisor, Smalt.ConfidentialLedger.Supervisor)

        :noop ->
          :ok
      end
    end)

    %{dir: dir, root: root}
  end

  @tag :seqb
  test "leg 1: isolated shape (fresh named sink, no app boot) first append gets seq 0", %{
    dir: dir
  } do
    {:ok, seq} = JournalSink.append(JournalSink, 0x0A01, 0, "seqb-leg1", ~s({"leg":1}))
    assert seq == 0

    st = JournalSink.status(JournalSink)
    assert %{frames: 1, next_seq: 1, mode: :active} = st
  end

  @tag :seqb
  test "leg 2: production mount shape (supervisor opts: dedicated sink + Service) first tx id is 0.1", %{
    dir: dir,
    root: root
  } do
    # Same child opts as Smalt.ConfidentialLedger.Supervisor.init/1 for the
    # dedicated sink, then the Service over it (real certification path).
    {:ok, _} =
      JournalSink.start_link(
        dir: dir,
        name: Smalt.ConfidentialLedger.Sink,
        segment_ceiling: 8 * 1024 * 1024
      )

    {:ok, _} = Service.start_link(dir: dir, sink: Smalt.ConfidentialLedger.Sink, certify_interval_ms: 40)

    {:ok, tx_id} = Service.append(%{"subject" => "seqb-leg2"})
    assert tx_id == "0.1"

    # second append is monotone 1-based-off-zero, never 1.1
    {:ok, tx2} = Service.append(%{"subject" => "seqb-leg2-b"})
    assert tx2 == "1.1"

    st = JournalSink.status(Smalt.ConfidentialLedger.Sink)
    assert %{frames: 2, next_seq: 2, mode: :active} = st
  end

  @tag :seqb
  test "leg 3: seq law (SYNC-RECEIPT-CHAIN §2) — assigned seqs are dense and monotone from 0", %{
    dir: dir
  } do
    seqs =
      for i <- 1..5 do
        {:ok, s} = JournalSink.append(JournalSink, 0x0A03, 0, "seqb-leg3-#{i}", ~s({"i":#{i}}))
        s
      end

    assert seqs == [0, 1, 2, 3, 4]
  end
end
