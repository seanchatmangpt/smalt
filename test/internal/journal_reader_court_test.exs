defmodule Smalt.Storage.JournalReaderCourtTest do
  @moduledoc """
  SJ-2 reader courts (Chicago: real files on disk, real bytes, no mocks).

  Cross-writer court: segments are written by the REAL writer
  (`Smalt.Storage.JournalSink`, SJ-1) through its GenServer — append + seal —
  then read back by the reader. Tamper courts corrupt real bytes and assert
  the typed refusal (1-bit flip → CRC failure, never admission).
  """

  use ExUnit.Case, async: true

  alias Smalt.Storage.JournalReader
  alias Smalt.Storage.JournalSink

  @suffix ".journal"

  setup do
    dir = Path.join(System.tmp_dir!(), "sj2-court-#{:erlang.unique_integer([:positive])}")
    File.mkdir_p!(Path.join(dir, "sealed"))
    on_exit(fn -> File.rm_rf!(dir) end)
    {:ok, dir: dir}
  end

  # -- segment builders (real bytes via the sink codec; court-only helpers) --

  defp synth_segment(dir, name, frames, opts \\ []) do
    sealed? = Keyword.get(opts, :sealed?, true)
    with_meta? = Keyword.get(opts, :meta?, true)
    seg = Path.join([dir, "sealed", name <> @suffix])

    bin =
      Enum.map_join(frames, fn {seq, key, payload} ->
        {f, _sz, _s} = JournalSink.encode_frame(seq, 1_760_000_000_000 + seq, 1, 1, key, payload)
        f
      end)

    File.write!(seg, bin)

    if with_meta? do
      seqs = for {seq, _, _} <- frames, do: seq

      meta = %{
        "segment" => name <> @suffix,
        "bytes" => byte_size(bin),
        "frames" => length(frames),
        "first_seq" => List.first(seqs) || nil,
        "last_seq" => List.last(seqs) || nil,
        "sha256" => Base.encode16(:crypto.hash(:sha256, bin), case: :lower)
      }

      File.write!(seg <> ".meta.json", Jason.encode!(meta))
    end

    if sealed?, do: File.touch!(seg <> ".seal")
    seg
  end

  defp frames_from_to(first, last) do
    for seq <- first..last, do: {seq, <<"k-", seq::32-big>>, <<"payload-", seq::32-big>>}
  end

  defp tamper_byte(path, offset) do
    bin = File.read!(path)
    <<byte::8>> = binary_part(bin, offset, 1)
    flipped = :erlang.bxor(byte, 1)
    prefix = binary_part(bin, 0, offset)
    rest = binary_part(bin, offset + 1, byte_size(bin) - offset - 1)
    File.write!(path, <<prefix::binary, flipped::8, rest::binary>>)
  end


  defp restamp_manifest(seg) do
    bin = File.read!(seg)

    meta =
      Jason.decode!(File.read!(seg <> ".meta.json"))
      |> Map.put("sha256", Base.encode16(:crypto.hash(:sha256, bin), case: :lower))
      |> Map.put("bytes", byte_size(bin))

    File.write!(seg <> ".meta.json", Jason.encode!(meta))
    seg
  end

  # -- courts --

  describe "clean parse of writer-produced sealed segments" do
    test "sink-written segment round-trips through the reader", %{dir: dir} do
      # REAL writer, REAL bytes: start the sink, append, seal
      root = Path.join(dir, "live")
      {:ok, sink} = JournalSink.start_link(dir: root, sync_interval_ms: 60_000)

      expected =
        for i <- 0..9 do
          {:ok, seq} = JournalSink.append(sink, 3, 7, "key-#{i}", <<"body-", i::32-big>>)
          {seq, "key-#{i}", <<"body-", i::32-big>>}
        end

      meta = JournalSink.seal(sink)
      GenServer.stop(sink)
      assert meta["frames"] == 10
      assert meta["first_seq"] == 0 and meta["last_seq"] == 9

      assert {:ok, [seg]} = JournalReader.discover_sealed_segments(root)
      assert {:ok, frames} = JournalReader.read_sealed_segment(seg)

      assert length(frames) == 10

      assert Enum.zip(frames, expected) |> Enum.all?(fn {f, {seq, key, payload}} ->
               f.seq_id == seq and f.key == key and f.payload == payload and
                 is_integer(f.ts) and f.event_type == 3 and f.table_id == 7
             end)

      assert (for f <- frames, do: f.seq_id) == Enum.to_list(0..9)
    end

    test "multi-segment discovery: only sealed listed, sorted", %{dir: dir} do
      synth_segment(dir, "seg-#{String.pad_leading("20", 20, "0")}", frames_from_to(20, 21))
      synth_segment(dir, "seg-#{String.pad_leading("0", 20, "0")}", frames_from_to(0, 1))
      # active (unsealed) and meta-less segments are NOT listed
      synth_segment(dir, "seg-#{String.pad_leading("10", 20, "0")}", frames_from_to(10, 11), sealed?: false)
      synth_segment(dir, "seg-#{String.pad_leading("30", 20, "0")}", frames_from_to(30, 31), meta?: false)

      assert {:ok, segs} = JournalReader.discover_sealed_segments(dir)
      assert length(segs) == 2
      assert segs == Enum.sort(segs)
      assert Enum.all?(segs, &String.contains?(&1, "seg-000000000000000000"))
    end

    test "discovery on empty dir returns []", %{dir: dir} do
      assert {:ok, []} = JournalReader.discover_sealed_segments(dir)
    end

    test "empty segment parses to []", %{dir: dir} do
      seg = synth_segment(dir, "seg-#{String.pad_leading("0", 20, "0")}", [])
      assert {:ok, []} = JournalReader.read_sealed_segment(seg)
    end
  end

  describe "sentinel law (active segments refused)" do
    test "segment bytes without .seal are typed {:not_sealed, path}", %{dir: dir} do
      seg =
        synth_segment(dir, "seg-#{String.pad_leading("0", 20, "0")}", frames_from_to(0, 3),
          sealed?: false
        )

      assert {:error, {:not_sealed, ^seg}} = JournalReader.read_sealed_segment(seg)
    end

    test "seal sentinel without meta.json is typed {:missing_meta, path}", %{dir: dir} do
      seg =
        synth_segment(dir, "seg-#{String.pad_leading("0", 20, "0")}", frames_from_to(0, 3),
          meta?: false
        )

      assert {:error, {:missing_meta, ^seg}} = JournalReader.read_sealed_segment(seg)
    end
  end

  describe "tamper courts (1-bit flip -> typed CRC failure, never admission)" do
    test "bit flip in a payload", %{dir: dir} do
      seg = synth_segment(dir, "seg-#{String.pad_leading("0", 20, "0")}", frames_from_to(0, 9))

      # frame 0: magic(4)+framelen(4)+seq(8)+ts(8)+et(2)+tid(2)+keylen(4)+key(6)
      # = 38 → first payload byte at offset 38
      tamper_byte(seg, 38)
      restamp_manifest(seg)
      assert {:error, {:crc_mismatch, kw}} = JournalReader.read_sealed_segment(seg)
      assert kw[:offset] == 0
    end

    test "bit flip in the CRC field itself", %{dir: dir} do
      seg = synth_segment(dir, "seg-#{String.pad_leading("0", 20, "0")}", frames_from_to(0, 9))
      # frame 0 payload/CRC gate: forge a consistent manifest, CRC must refuse
      tamper_byte(seg, 38 + 12)
      restamp_manifest(seg)
      assert {:error, {:crc_mismatch, kw}} = JournalReader.read_sealed_segment(seg)
      assert kw[:offset] == 0
    end

    test "bit flip in the seq field", %{dir: dir} do
      seg = synth_segment(dir, "seg-#{String.pad_leading("0", 20, "0")}", frames_from_to(0, 9))
      tamper_byte(seg, 8)
      # seq byte after magic+framelen; forge manifest so the CRC gate refuses
      restamp_manifest(seg)
      assert {:error, {:crc_mismatch, kw}} = JournalReader.read_sealed_segment(seg)
      assert kw[:offset] == 0
    end

    test "manifest sha256 mismatch is refused before any frame parse", %{dir: dir} do
      seg = synth_segment(dir, "seg-#{String.pad_leading("0", 20, "0")}", frames_from_to(0, 4))
      tamper_byte(seg, 38)
      assert {:error, {:manifest_mismatch, kw}} = JournalReader.read_sealed_segment(seg)
      assert kw[:path] == seg

      # stronger adversary: also forges the manifest over the tampered bytes —
      # now the per-frame CRC gate itself must refuse
      restamp_manifest(seg)
      assert {:error, {:crc_mismatch, kw}} = JournalReader.read_sealed_segment(seg)
      assert kw[:offset] == 0
    end
  end

  describe "truncation courts" do
    test "dangling partial header is a typed truncated_tail", %{dir: dir} do
      seg = synth_segment(dir, "seg-#{String.pad_leading("0", 20, "0")}", frames_from_to(0, 4))
      bin = File.read!(seg)
      # leave only 3 bytes of frame 4: a dangling partial header (< 8 bytes)
      File.write!(seg, binary_part(bin, 0, 4 * 58 + 3))
      restamp_manifest(seg)
      assert {:error, {:truncated_tail, kw}} = JournalReader.read_sealed_segment(seg)
      assert kw[:have] == 3
    end

    test "header present but frame cut mid-payload is a typed truncated_frame", %{dir: dir} do
      seg = synth_segment(dir, "seg-#{String.pad_leading("0", 20, "0")}", frames_from_to(0, 4))
      bin = File.read!(seg)
      keep = byte_size(bin) - 2
      File.write!(seg, binary_part(bin, 0, keep))
      restamp_manifest(seg)

      assert {:error, {:truncated_frame, kw}} = JournalReader.read_sealed_segment(seg)
      assert kw[:have] == keep - 4 * 58
    end

    test "zero-byte segment with valid sentinels parses to []", %{dir: dir} do
      seg = synth_segment(dir, "seg-#{String.pad_leading("0", 20, "0")}", [])
      assert byte_size(File.read!(seg)) == 0
      assert {:ok, []} = JournalReader.read_sealed_segment(seg)
    end
  end

  describe "seq monotonicity courts" do
    test "replayed seq inside a segment is a typed regression", %{dir: dir} do
      frames = frames_from_to(0, 3) ++ [{2, "k-replay", "replay"}]
      seg = synth_segment(dir, "seg-#{String.pad_leading("0", 20, "0")}", frames)
      assert {:error, {:seq_regression, kw}} = JournalReader.read_sealed_segment(seg)
      assert kw[:expected] == 4 and kw[:got] == 2
    end

    test "a gap in seq ids is a regression (strict +1 law)", %{dir: dir} do
      seg =
        synth_segment(dir, "seg-#{String.pad_leading("0", 20, "0")}", [
          {0, "a", "a"},
          {5, "b", "b"}
        ])

      assert {:error, {:seq_regression, kw}} = JournalReader.read_sealed_segment(seg)
      assert kw[:expected] == 1 and kw[:got] == 5
    end
  end
end
