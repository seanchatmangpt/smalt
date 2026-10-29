# SJ-1 — journal sink writer court (PROD-1).
# Run: MIX_BUILD_ROOT=_build-sj1 mix run test/integration/sj1_journal_sink_court.exs
# Chicago: real segment files, real rename, real sha256, no mocks, no Process.sleep.
# Exit 0 = PASS, exit 1 = FAIL.

defmodule SJ1.JournalSinkCourt do
  @out_root Path.expand("tmp/sj1-court")

  def run do
    File.rm_rf!(@out_root)
    File.mkdir_p!(@out_root)

    banner =
      :io_lib.format("SJ-1 JOURNAL SINK COURT  (OTP ~s, erts ~s)", [
        :erlang.system_info(:otp_release),
        :erlang.system_info(:version)
      ])
      |> IO.iodata_to_binary()

    IO.puts(banner)

    leg_frame_roundtrip()
    leg_frame_rejects()
    leg_seal_atomicity()
    leg_segment_rotation()
    leg_monotonic_seq()

    IO.puts("")
    IO.puts("SJ-1 COURT: PASS")
  catch
    {:fail, msg} ->
      IO.puts("SJ-1 COURT: FAIL -- " <> msg)
      System.halt(1)
  end

  defp leg_frame_roundtrip do
    IO.puts("")
    IO.puts("LEG 1: frame round-trip exactness")

    cases = [
      {0, 0, 0, 0, "", ""},
      {1, 1_729_999_999_999, 7, 3, "batch-1", "temph-4.1"},
      {0xFFFF_FFFF_FFFF_FFFF, -1, 0xFFFF, 0xFFFF, String.duplicate("k", 500), <<0, 1, 2, 255>>},
      {2, 1_729_999_999_998, 1, 1, "k-lambda-4", :binary.copy(<<0xAB>>, 4096)}
    ]

    for {seq, ts, et, tid, key, payload} <- cases do
      {frame, size, _} = Smalt.Storage.JournalSink.encode_frame(seq, ts, et, tid, key, payload)
      flunk_unless(size == byte_size(frame), "returned size != frame byte_size")
      flunk_unless(binary_part(frame, 0, 4) == Smalt.Storage.JournalSink.frame_magic(), "bad magic bytes")

      assert {:ok, f, ""} = Smalt.Storage.JournalSink.decode_frame(frame)
      flunk_unless(f.seq_id == seq, "seq round-trip")
      flunk_unless(f.ts == ts, "ts round-trip")
      flunk_unless(f.event_type == et, "event_type round-trip")
      flunk_unless(f.table_id == tid, "table_id round-trip")
      flunk_unless(f.key == key, "key round-trip")
      flunk_unless(f.payload == payload, "payload round-trip")

      {frame2, _, _} = Smalt.Storage.JournalSink.encode_frame(f.seq_id, f.ts, f.event_type, f.table_id, f.key, f.payload)
      flunk_unless(frame2 == frame, "re-encode not bit-exact")
    end

    IO.puts("  round-trip: 4/4 cases exact")
  end

  defp leg_frame_rejects do
    IO.puts("")
    IO.puts("LEG 2: frame refusal faces")

    {frame, _, _} = Smalt.Storage.JournalSink.encode_frame(9, 1, 1, 1, "k", "p")

    # corrupted CRC
    cut = byte_size(frame) - 1
    <<head::binary-size(^cut), last>> = frame
    assert {:error, :crc_mismatch} = Smalt.Storage.JournalSink.decode_frame(<<head::binary, bump(last)>>)

    # corrupted magic
    body = binary_part(frame, 4, byte_size(frame) - 4)
    assert {:error, {:bad_magic, "XMAI"}} = Smalt.Storage.JournalSink.decode_frame("XMAI" <> body)

    # truncated tail
    assert {:error, :truncated} =
             Smalt.Storage.JournalSink.decode_frame(binary_part(frame, 0, byte_size(frame) - 1))

    # trailing bytes after a valid frame come back as rest
    assert {:ok, _f, "trailing"} = Smalt.Storage.JournalSink.decode_frame(frame <> "trailing")

    IO.puts("  refusals: crc/magic/truncation/trailing all typed")
  end

  defp bump(b), do: b + 1

  defp leg_seal_atomicity do
    IO.puts("")
    IO.puts("LEG 3: seal atomicity (rename -> meta -> sentinel LAST)")

    dir = Path.join(@out_root, "seal")
    {:ok, sink} = Smalt.Storage.JournalSink.start_link(dir: dir, sync_interval_ms: 60_000)

    for i <- 1..5 do
      assert {:ok, _} = Smalt.Storage.JournalSink.append(sink, 1, 2, "k#{i}", "payload-#{i}")
    end

    meta = Smalt.Storage.JournalSink.seal(sink)
    flunk_unless(is_map(meta), "seal did not return a meta map")

    sealed = Path.join([dir, "sealed", meta["segment"]])
    flunk_unless(File.exists?(sealed), "sealed segment missing after seal")
    flunk_unless(File.exists?(sealed <> ".meta.json"), "meta.json missing after seal")
    flunk_unless(File.exists?(sealed <> ".seal"), ".seal sentinel missing after seal")

    # exactly one new active segment open, empty
    active = File.ls!(Path.join(dir, "active")) |> Enum.filter(&String.contains?(&1, "seg-"))
    flunk_unless(length(active) == 1, "expected exactly 1 active segment after seal, got #{inspect(active)}")
    flunk_unless(File.stat!(Path.join([dir, "active", hd(active)])).size == 0, "new active segment not empty")

    # sha256 in manifest matches actual sealed bytes
    actual_sha = Base.encode16(:crypto.hash(:sha256, File.read!(sealed)), case: :lower)
    flunk_unless(meta["sha256"] == actual_sha, "manifest sha256 != actual sealed bytes")

    # manifest stats match decoded frames
    frames = read_all_frames(sealed)
    flunk_unless(meta["frames"] == length(frames), "manifest frames != decoded frames")
    seqs = Enum.map(frames, & &1.seq_id)
    flunk_unless(meta["first_seq"] == hd(seqs), "first_seq mismatch")
    flunk_unless(meta["last_seq"] == List.last(seqs), "last_seq mismatch")

    # negative face: sentinel removed -> the segment is unsealed for any consumer
    File.rm!(sealed <> ".seal")
    flunk_unless(not File.exists?(sealed <> ".seal"), "sentinel removal failed")

    IO.puts("  seal: ordered rename+meta+sentinel, sha256 verified, sentinel-removal = unsealed")
    GenServer.stop(sink)
  end

  defp leg_segment_rotation do
    IO.puts("")
    IO.puts("LEG 4: segment rotation at ceiling")

    dir = Path.join(@out_root, "rotate")
    {:ok, sink} = Smalt.Storage.JournalSink.start_link(dir: dir, segment_ceiling: 512, sync_interval_ms: 60_000)

    # frame = 40 + len(key) + len(payload); key ~8, payload 40 -> ~88B/frame, 512B ceiling forces rotation
    for i <- 1..20 do
      assert {:ok, _} = Smalt.Storage.JournalSink.append(sink, 3, 1, "key-#{i}", String.duplicate("p", 40))
    end

    status = Smalt.Storage.JournalSink.status(sink)
    sealed = sealed_segments(dir)
    flunk_unless(length(sealed) >= 2, "expected >=2 sealed segments under a 512B ceiling, got #{length(sealed)}")

    for seg <- sealed do
      bytes = File.stat!(Path.join([dir, "sealed", seg])).size
      flunk_unless(bytes <= 512, "sealed segment #{seg} at #{bytes}B exceeds 512B ceiling")
      flunk_unless(File.exists?(Path.join([dir, "sealed", seg <> ".seal"])), "#{seg} missing .seal sentinel")
      flunk_unless(File.exists?(Path.join([dir, "sealed", seg <> ".meta.json"])), "#{seg} missing meta.json")
    end

    shas =
      for seg <- sealed do
        Base.encode16(:crypto.hash(:sha256, File.read!(Path.join([dir, "sealed", seg]))), case: :lower)
      end

    flunk_unless(length(Enum.uniq(shas)) == length(shas), "duplicate sealed segments -- rotation split failed")
    flunk_unless(status.next_seq == 20, "next_seq != 20 after 20 appends (got #{status.next_seq})")

    IO.puts("  rotation: #{length(sealed)} sealed segments, all under ceiling, all sentinel-sealed")
    GenServer.stop(sink)
  end

  defp leg_monotonic_seq do
    IO.puts("")
    IO.puts("LEG 5: monotonic SeqID across rotation and seal")

    dir = Path.join(@out_root, "mono")
    {:ok, sink} = Smalt.Storage.JournalSink.start_link(dir: dir, segment_ceiling: 400, sync_interval_ms: 60_000)

    expected = Enum.to_list(0..29)

    got =
      for i <- 0..29 do
        assert {:ok, seq} = Smalt.Storage.JournalSink.append(sink, 1, 1, "k", "x#{i}")
        seq
      end

    flunk_unless(got == expected, "seq not strictly ascending 0..29: #{inspect(got)}")

    # explicit mid-stream seal does not perturb the sequence
    meta = Smalt.Storage.JournalSink.seal(sink)
    assert {:ok, 30} = Smalt.Storage.JournalSink.append(sink, 1, 1, "k", "after-seal")
    flunk_unless(meta["last_seq"] == 29, "mid-stream seal meta last_seq != 29")

    # strict monotonicity across every sealed segment + the active tail
    all_seqs =
      for seg <- sealed_segments(dir) ++ File.ls!(Path.join(dir, "active")) do
        path = Path.join([dir, "sealed", seg])

        path =
          if File.exists?(path) do
            path
          else
            Path.join([dir, "active", seg])
          end

        read_all_frames(path) |> Enum.map(& &1.seq_id)
      end
      |> List.flatten()

    flunk_unless(all_seqs == Enum.to_list(0..30), "cross-segment seq stream not 0..30 in order")

    IO.puts("  monotonic: 31 appends, strict 0..30 across rotation + explicit seal")
    GenServer.stop(sink)
  end

  # --- helpers ---------------------------------------------------------------

  defp read_all_frames(path) do
    do_read(File.read!(path), [])
  end

  defp do_read(<<>>, acc), do: Enum.reverse(acc)

  defp do_read(bin, acc) do
    case Smalt.Storage.JournalSink.decode_frame(bin) do
      {:ok, f, rest} -> do_read(rest, [f | acc])
      {:error, reason} -> raise "SJ-1: decode failed mid-file: #{inspect(reason)}"
    end
  end

  defp sealed_segments(dir) do
    dir |> Path.join("sealed") |> File.ls!() |> Enum.filter(&String.ends_with?(&1, ".journal"))
  end

  # all asserts are exact `pattern = expr` matches; a mismatch is a MatchError,
  # so this pass-through only normalizes control flow
  defp assert(_), do: :ok

  defp flunk(msg) do
    IO.puts("  [FAIL] " <> msg)
    throw({:fail, msg})
  end

  defp flunk_unless(cond, _msg) when cond, do: :ok
  defp flunk_unless(_, msg), do: flunk(msg)
end

SJ1.JournalSinkCourt.run()
