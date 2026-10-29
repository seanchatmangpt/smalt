defmodule Smalt.Internal.Expl6r1JournalCourtTest do
  @moduledoc """
  EXPL6-R1 court (lane EXPL6-R1): repairs for EXPL-6 findings F1/F2/F3 in the
  journal reader/sink. Chicago legs over real segment files on disk and real
  sink processes — no mocks, no sleeps.

  F1: corrupt sealed segments (bad magic; frame_len < CRC width) answer typed
      refusals from `JournalReader.read_sealed_segment/1`, never a raw
      MatchError.
  F2: `JournalSink.seal(matter_scope: never_appended)` answers
      `{:error, :empty_segment}` and the sink survives.
  F3: a seal failure during pre-write rotation (legacy + scoped) degrades per
      SPOF-A1 — the append still replies `{:ok, seq}` (accepted-and-dropped),
      the sink stays up, no CaseClauseError.
  """

  use ExUnit.Case, async: true

  alias Smalt.Storage.JournalReader
  alias Smalt.Storage.JournalSink

  @seg "seg-" <> String.pad_leading("0", 20, "0") <> ".journal"

  defp tmp_dir(tags), do: Path.join([System.tmp_dir!(), "expl6r1-court", Enum.join(tags, "-")])

  # per-test unique sink name — tests are async, the sink falls back to the
  # global module name when :name is absent
  defp sink_name(tag), do: String.to_atom("expl6r1_sink_" <> tag <> "_#{System.unique_integer([:positive])}")

  # -- F1: corrupt sealed segments must be typed refusals -------------------

  defp write_sealed_segment!(dir, bytes) do
    File.mkdir_p!(Path.join(dir, "sealed"))
    seg = Path.join([dir, "sealed", @seg])
    File.write!(seg, bytes)
    File.write!(seg <> ".seal", "")
    File.write!(seg <> ".meta.json", Jason.encode!(%{"sha256" => Base.encode16(:crypto.hash(:sha256, bytes), case: :lower)}))
    seg
  end

  test "F1a: segment whose first bytes are not SMAL magic is a typed {:bad_magic, ...} refusal" do
    dir = tmp_dir(["f1a", Integer.to_string(System.unique_integer([:positive]))])
    File.mkdir_p!(dir)
    corrupt = <<88, 88, 88, 88, 16::unsigned-integer-size(32), 0::integer-size(64)>>
    write_sealed_segment!(dir, corrupt)

    assert {:error, {:bad_magic, offset: 0}} = JournalReader.read_sealed_segment(Path.join([dir, "sealed", @seg]))
  end

  test "F1b: valid magic with frame_len < CRC width is a typed {:truncated_frame, ...} refusal" do
    for frame_len <- 0..3 do
      dir = tmp_dir(["f1b", Integer.to_string(frame_len), Integer.to_string(System.unique_integer([:positive]))])
      File.mkdir_p!(dir)
      # well-formed magic + hostile tiny frame_len + plenty of trailing bytes
      corrupt = <<"SMAL", frame_len::unsigned-integer-size(32), 0::integer-size(512)>>
      write_sealed_segment!(dir, corrupt)

      assert {:error, {:truncated_frame, offset: 0, reason: :bad_frame_len, have: _}} =
               JournalReader.read_sealed_segment(Path.join([dir, "sealed", @seg]))
    end
  end

  test "F1c regression: magic-only truncated tail stays typed {:truncated_tail, ...}" do
    dir = tmp_dir(["f1c", Integer.to_string(System.unique_integer([:positive]))])
    File.mkdir_p!(dir)
    write_sealed_segment!(dir, "SMAL")

    assert {:error, {:truncated_tail, offset: 0, have: 4}} =
             JournalReader.read_sealed_segment(Path.join([dir, "sealed", @seg]))
  end

  test "F1 round-trip regression: a real sink-sealed segment still reads back {:ok, frames}" do
    dir = tmp_dir(["f1-ok", Integer.to_string(System.unique_integer([:positive]))])
    File.mkdir_p!(dir)
    sink = sink_name("f1ok")
    start_supervised!({JournalSink, dir: dir, name: sink, sync_interval_ms: 60_000})
    assert {:ok, 0} = JournalSink.append(sink, 1, 1, "k", "v")
    meta = JournalSink.seal(sink)
    assert is_map(meta)

    assert {:ok, [frame]} =
             JournalReader.read_sealed_segment(Path.join([dir, "sealed", meta["segment"]]))

    assert frame.key == "k" and frame.payload == "v"
  end

  # -- F2: sealing a never-appended matter scope ----------------------------

  test "F2: seal of a never-appended scope is {:error, :empty_segment} and the sink survives" do
    dir = tmp_dir(["f2", Integer.to_string(System.unique_integer([:positive]))])
    File.mkdir_p!(dir)
    sink = sink_name("f2")
    start_supervised!({JournalSink, dir: dir, name: sink, sync_interval_ms: 60_000})

    assert {:error, :empty_segment} = JournalSink.seal(sink, matter_scope: "neverused")

    # the sink process is still up and answering
    assert %{mode: :active} = JournalSink.status(sink)
  end

  # -- F3: seal failure during pre-write rotation degrades, never crashes ---

  defp block_seal_target!(root, scope \\ nil) do
    sealed =
      if scope do
        Path.join([JournalSink.matter_root(root, scope), "sealed"])
      else
        Path.join([root, "sealed"])
      end

    # a DIRECTORY at the sealed target path makes File.rename fail (EISDIR),
    # a real filesystem condition do_seal converts to {:error, {:seal_failed,
    # {:rename, ...}}}
    File.mkdir_p!(Path.join(sealed, @seg))
    sealed
  end

  test "F3 legacy: rotation-leg seal failure degrades the sink and drops the append, no crash" do
    dir = tmp_dir(["f3-legacy", Integer.to_string(System.unique_integer([:positive]))])
    File.mkdir_p!(dir)
    block_seal_target!(dir)

    sink = sink_name("f3legacy")
    start_supervised!(
      {JournalSink, dir: dir, name: sink, segment_ceiling: 1, sync_interval_ms: 60_000}
    )

    # first append: active segment empty -> no rotation, real write
    assert {:ok, 0} = JournalSink.append(sink, 1, 1, "k0", "v0")

    # second append crosses the ceiling -> pre-write rotation -> seal fails
    assert {:ok, 1} = JournalSink.append(sink, 1, 1, "k1", "v1")

    status = JournalSink.status(sink)
    assert status.mode == :degraded
    assert status.dropped == 1
    assert {:rename, _path, :eisdir} = status.degraded_reason
  end

  test "F3 scoped: rotation-leg seal failure degrades only that scope, no crash" do
    dir = tmp_dir(["f3-scope", Integer.to_string(System.unique_integer([:positive]))])
    File.mkdir_p!(dir)
    block_seal_target!(dir, "t1")

    sink = sink_name("f3scope")
    start_supervised!(
      {JournalSink, dir: dir, name: sink, segment_ceiling: 1, sync_interval_ms: 60_000}
    )

    assert {:ok, 0} = JournalSink.append_frame(sink, 1, 1, "k0", "v0", matter_scope: "t1")
    assert {:ok, 1} = JournalSink.append_frame(sink, 1, 1, "k1", "v1", matter_scope: "t1")

    status = JournalSink.status(sink, matter_scope: "t1")
    assert status.mode == :degraded
    assert status.dropped == 1

    # isolation law: the legacy journal and another scope are untouched
    assert %{mode: :active} = JournalSink.status(sink)
    assert {:ok, 0} = JournalSink.append_frame(sink, 1, 1, "k", "v", matter_scope: "t2")
  end

  test "F3 legacy regression: seal/1 on an active sink whose seal fails is a typed refusal" do
    dir = tmp_dir(["f3-seal", Integer.to_string(System.unique_integer([:positive]))])
    File.mkdir_p!(dir)
    block_seal_target!(dir)

    sink = sink_name("f3seal")
    start_supervised!({JournalSink, dir: dir, name: sink, sync_interval_ms: 60_000})
    assert {:ok, 0} = JournalSink.append(sink, 1, 1, "k", "v")

    assert {:error, {:seal_failed, {:rename, _path, :eisdir}}} = JournalSink.seal(sink)
    assert %{mode: :degraded} = JournalSink.status(sink)
  end

  test "F2/F3 regression: explicit scope seal on a real appended scope still works" do
    dir = tmp_dir(["f3-ok", Integer.to_string(System.unique_integer([:positive]))])
    File.mkdir_p!(dir)

    sink = sink_name("f3ok")
    start_supervised!({JournalSink, dir: dir, name: sink, sync_interval_ms: 60_000})
    assert {:ok, 0} = JournalSink.append_frame(sink, 1, 1, "k", "v", matter_scope: "ok")

    meta = JournalSink.seal(sink, matter_scope: "ok")
    assert is_map(meta)
    assert meta["frames"] == 1
  end
end
