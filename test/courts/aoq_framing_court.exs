defmodule AoqFramingCourt do
  @moduledoc """
  R1-I v3 byte-fidelity court for the AoQ framing laws (24 legs).

  Asserts on the wire format itself, not on call counts:
  - 64B header, LE field layout per the landed ontology (magic LE bytes
    "1QOA", version 3 u16 LE @4, epoch/key_id/ordinal/seq LE, reserved
    36B zeros, FNV-1a32 @60 over [0,60))
  - body ≥1 byte; total ≥65 — RefcBinary law; iolist egress fidelity
  - digest mutate law: every raw flip in [0,60) is :bad_digest (reserved
    flips included — the digest covers the reserved region); field
    refusals with a recomputed digest follow refusal order
    magic → version → epoch (closed enum) → stream dispatch
  - seq wraps at u32 (2^32-1); golden bytes assert both directions
    against the committed fixture `test/data/aoq_v3_golden.hex`
  """

  use ExUnit.Case, async: true

  alias Smalt.Aoq.Cursor
  alias Smalt.Aoq.Frame
  alias Smalt.Aoq.Tables

  @header_size 64
  @max_u32 0xFFFFFFFF
  @max_u64 0xFFFFFFFFFFFFFFFF
  @golden_path "test/data/aoq_v3_golden.hex"

  setup do
    on_exit(fn -> :persistent_term.erase({:aoq, :sealed}) end)
    Tables.boot()
    :ok
  end

  defp frame(opts \\ []) do
    %Frame{
      epoch: Keyword.get(opts, :epoch, 1),
      key_id: Keyword.get(opts, :key_id, 0x0102030405060708),
      frame_ordinal: Keyword.get(opts, :frame_ordinal, 7),
      seq: Keyword.get(opts, :seq, 42)
    }
  end

  # ── helpers ─────────────────────────────────────────────────────────


  # Rewrite one header byte and recompute the FNV digest over [0,60), so
  # the mutation lands on the FIELD check rather than being swallowed by
  # :bad_digest.
  defp mutate(bin, idx, value) do
    patched =
      binary_part(bin, 0, idx) <>
        <<value>> <>
        binary_part(bin, idx + 1, byte_size(bin) - idx - 1)

    digest = Frame.fnv1a32(binary_part(patched, 0, 60))

    binary_part(patched, 0, 60) <>
      <<digest::unsigned-little-integer-size(32)>> <>
      binary_part(patched, 64, byte_size(patched) - 64)
  end

  defp flip_byte_raw(bin, idx) do
    byte = :binary.at(bin, idx)

    binary_part(bin, 0, idx) <>
      <<:erlang.bxor(byte, 1)>> <>
      binary_part(bin, idx + 1, byte_size(bin) - idx - 1)
  end

  # Independent reference encoder: builds the v3 wire bytes directly from
  # the field table (deliberately independent of Frame.encode_frame) so
  # corrupt-field cases the encoder refuses can still be emitted.
  defp lawful_wire(opts \\ []) do
    epoch = Keyword.get(opts, :epoch, 1)
    key_id = Keyword.get(opts, :key_id, 0x0102030405060708)
    frame_ordinal = Keyword.get(opts, :frame_ordinal, 7)
    seq = Keyword.get(opts, :seq, 42)
    stream_type = Keyword.get(opts, :stream_type, 0)
    body_rest = Keyword.get(opts, :body_rest, <<0xDE, 0xAD>>)

    prefix =
      <<0x414F5131::unsigned-little-integer-size(32), 3::unsigned-little-integer-size(16),
        epoch::unsigned-little-integer-size(16), key_id::unsigned-little-integer-size(64),
        frame_ordinal::unsigned-little-integer-size(32), seq::unsigned-little-integer-size(32),
        0::unsigned-integer-size(288)>>

    digest = Frame.fnv1a32(prefix)
    header = prefix <> <<digest::unsigned-little-integer-size(32)>>
    IO.iodata_to_binary([header, <<stream_type>>, body_rest])
  end

  defp ok_iolist({:ok, iolist}), do: iolist

  # ── leg 1: constants ────────────────────────────────────────────────

  test "leg 01: header size 64, min body 1, magic accessor is LE bytes 1QOA, version pin 3" do
    assert Frame.header_size() == 64
    assert Frame.min_body_size() == 1
    assert Frame.magic() == <<"1QOA">>
    assert Frame.version() == 3
  end

  # ── wire layout ─────────────────────────────────────────────────────

  test "leg 02: encode_frame emits the exact v3 LE field layout (64B header + body iolist)" do
    body = <<0, 9, 8, 7, 6>>
    {:ok, [header, ^body]} = Frame.encode_frame(frame(epoch: 0), body)

    assert byte_size(header) == 64
    # magic: LE bytes of 0x414F5131
    assert binary_part(header, 0, 4) == <<"1QOA">>
    assert :binary.decode_unsigned(binary_part(header, 0, 4), :little) == 0x414F5131
    # version: u16 LE at offset 4
    assert :binary.decode_unsigned(binary_part(header, 4, 2), :little) == 3
    # epoch u16 LE @6, key_id u64 LE @8, ordinal u32 LE @16, seq u32 LE @20
    assert :binary.decode_unsigned(binary_part(header, 6, 2), :little) == 0
    assert :binary.decode_unsigned(binary_part(header, 8, 8), :little) == 0x0102030405060708
    assert :binary.decode_unsigned(binary_part(header, 16, 4), :little) == 7
    assert :binary.decode_unsigned(binary_part(header, 20, 4), :little) == 42
    # reserved [24,60) is zeros
    assert binary_part(header, 24, 36) == <<0::288>>
    # digest: FNV-1a32 over [0,60), stored LE at 60
    digest = :binary.decode_unsigned(binary_part(header, 60, 4), :little)
    assert digest == Frame.fnv1a32(binary_part(header, 0, 60))
    assert digest == 192_470_349 # golden genesis digest 0x0B78DD4D (needs epoch 0 below)
  end

  # ── egress + framing law ────────────────────────────────────────────

  test "leg 03: encode returns an iolist [header | body], never a flat binary" do
    header = :crypto.strong_rand_bytes(@header_size)
    body = :crypto.strong_rand_bytes(200)

    assert {:ok, frame} = Frame.encode(header, body)
    assert is_list(frame)
    assert frame == [header, body]
    refute is_binary(frame)
  end

  test "leg 04: encoded frame is ≥65 bytes — RefcBinary territory, never a HeapBin" do
    {:ok, frame} = Frame.encode(:crypto.strong_rand_bytes(@header_size), <<0xFF>>)
    total = :erlang.iolist_size(frame)
    assert total >= 65
    assert byte_size(IO.iodata_to_binary(frame)) >= 65
  end

  test "leg 05: byte fidelity — iolist egress == <> reference encode" do
    header = :crypto.strong_rand_bytes(@header_size)
    body = :crypto.strong_rand_bytes(1000)

    {:ok, iolist_frame} = Frame.encode(header, body)
    assert IO.iodata_to_binary(iolist_frame) == header <> body
  end

  test "leg 06: zero-length body is refused (would total exactly 64 — HeapBin)" do
    assert {:error, :empty_body} = Frame.encode(:crypto.strong_rand_bytes(@header_size), <<>>)
    assert {:error, :empty_body} = Frame.encode_frame(frame(), <<>>)
  end

  test "leg 07: short header / non-binary header is refused by compat encode" do
    assert {:error, :short_header} = Frame.encode(<<0::size(8 * 63)>>, <<1>>)
    assert {:error, :short_header} = Frame.encode("not-a-binary", <<1>>)
  end

  test "leg 08: split round-trips a lawful frame and refuses sub-65B frames" do
    header = :crypto.strong_rand_bytes(@header_size)
    body = :crypto.strong_rand_bytes(97)

    wire = IO.iodata_to_binary([header, body])
    assert {:ok, ^header, ^body} = Frame.split(wire)

    for n <- [63, 64] do
      assert {:error, :short_frame} = Frame.split(:crypto.strong_rand_bytes(n))
    end
  end

  # ── roundtrip falsifiers ────────────────────────────────────────────

  test "leg 09: encode/decode roundtrips across the body-size boundary sweep" do
    for n <- [1, 32, 64, 65, 128, 4096, 65_536] do
      body = <<0>> <> :crypto.strong_rand_bytes(n)
      wire = frame() |> then(&Frame.encode_frame(&1, body)) |> ok_iolist()

      assert :erlang.iolist_size(wire) == @header_size + n + 1

      assert {:ok, {parsed, ^body}} = Frame.decode(IO.iodata_to_binary(wire))
      assert parsed == frame()
    end
  end

  test "leg 10: epoch boundaries 0/1/2 roundtrip; retired 65535 admits on decode (read-only)" do
    for epoch <- [0, 1, 2, 65_535] do
      body = <<0, 1, 2>>
      wire = lawful_wire(epoch: epoch, stream_type: 0, body_rest: <<1, 2>>)

      assert {:ok, {parsed, ^body}} = Frame.decode(wire)
      assert parsed.epoch == epoch
      assert parsed.key_id == 0x0102030405060708
    end
  end

  test "leg 11: seq wrap — u32 2^32-1 roundtrips on the wire; Cursor ordering stays u64-locked" do
    body = <<0, 1>>
    wire = frame(seq: @max_u32) |> then(&Frame.encode_frame(&1, body)) |> ok_iolist()

    assert {:ok, {%Frame{seq: @max_u32}, ^body}} = Frame.decode(IO.iodata_to_binary(wire))

    # Cursor remains u64-locked (its own wrap law, @mod = 2^64) — u64
    # ordering legs, independent of the header seq field width.
    assert Cursor.seq_before?(@max_u64, 0)
    refute Cursor.seq_before?(0, @max_u64)
    refute Cursor.seq_before?(@max_u64, @max_u64)
  end

  test "leg 12: stream prefixes 0/1/2 (data/control/eos) all admit" do
    for {st, rest} <- [{0, <<1, 2, 3>>}, {1, <<0x07, 0>>}, {2, <<>>}] do
      wire = lawful_wire(stream_type: st, body_rest: rest)
      body = IO.iodata_to_binary([<<st>>, rest])

      assert {:ok, {%Frame{}, ^body}} = Frame.decode(wire)
    end
  end

  # ── digest mutate law ───────────────────────────────────────────────

  test "leg 13: FNV mutate law — EVERY raw flip in [0,60) is refused (:bad_digest)" do
    base = lawful_wire()

    for idx <- Enum.to_list(0..59) do
      assert {:error, :bad_digest} = Frame.decode(flip_byte_raw(base, idx)),
             "byte #{idx} raw flip must be :bad_digest"
    end
  end

  test "leg 14: reserved-region flips are :bad_digest (digest covers [24,60))" do
    base = lawful_wire()

    for idx <- Enum.to_list(24..59) do
      assert {:error, :bad_digest} = Frame.decode(flip_byte_raw(base, idx)),
             "reserved byte #{idx} flip must be :bad_digest"
    end
  end

  test "leg 15: digest-field flips (60..63) are :bad_digest" do
    base = lawful_wire()

    for idx <- Enum.to_list(60..63) do
      assert {:error, :bad_digest} = Frame.decode(flip_byte_raw(base, idx)),
             "digest byte #{idx} flip must be :bad_digest"
    end
  end

  # ── refusal order: magic → version → epoch → dispatch ───────────────

  test "leg 16: bad magic with a recomputed digest is refused (:bad_header)" do
    wire = lawful_wire()
    assert {:error, :bad_header} = Frame.decode(mutate(wire, 0, ?X))
  end

  test "leg 17: version pin — 2 and 4 are refused with a recomputed digest (:bad_header)" do
    wire = lawful_wire()

    patched_v2 =
      binary_part(wire, 0, 4) <> <<2::unsigned-little-integer-size(16)>> <> binary_part(wire, 6, byte_size(wire) - 6)

    patched_v4 =
      binary_part(wire, 0, 4) <> <<4::unsigned-little-integer-size(16)>> <> binary_part(wire, 6, byte_size(wire) - 6)

    assert {:error, :bad_header} = Frame.decode(mutate(patched_v2, 4, 2))
    assert {:error, :bad_header} = Frame.decode(mutate(patched_v4, 4, 4))
  end

  test "leg 18: out-of-enum epoch 7 (valid digest) is refused ({:unknown_epoch, 7})" do
    wire = lawful_wire(epoch: 7)
    assert {:error, {:unknown_epoch, 7}} = Frame.decode(wire)
  end

  test "leg 19: unknown stream prefix 0x42 is refused ({:unknown_stream_type, 0x42})" do
    wire = lawful_wire(stream_type: 0x42, body_rest: <<1>>)
    assert {:error, {:unknown_stream_type, 0x42}} = Frame.decode(wire)
  end

  test "leg 20: EOS strictness — exactly the 1-byte prefix admits; a payload refuses" do
    assert {:ok, {%Frame{}, <<2>>}} = Frame.decode(lawful_wire(stream_type: 2, body_rest: <<>>))
    assert {:error, {:bad_stream_body, 2}} = Frame.decode(lawful_wire(stream_type: 2, body_rest: <<9, 9>>))
  end

  test "leg 21: sub-65B frames are refused (:short_frame)" do
    for n <- [0, 1, 32, 63, 64] do
      assert {:error, :short_frame} = Frame.decode(:crypto.strong_rand_bytes(n))
    end
  end

  test "leg 22: unbooted tables refuse with :tables_unbooted" do
    :persistent_term.erase({:aoq, :sealed})
    wire = lawful_wire()
    assert {:error, :tables_unbooted} = Frame.decode(wire)
    Tables.boot() # restore for the async siblings (seal is shared state)
  end

  # ── golden bytes (derived, never guessed) ───────────────────────────

  test "leg 23: encode of the genesis frame == committed golden hex, byte-identical" do
    body = <<0>> # StreamType 0 (data), 1-byte body
    {:ok, iolist} = Frame.encode_frame(%Frame{epoch: 0, key_id: 0x0102030405060708, frame_ordinal: 7, seq: 42}, body)

    assert IO.iodata_to_binary(iolist) == golden_hex_bytes()
  end

  test "leg 24: decode of the committed golden hex == genesis struct + body (both directions)" do
    golden = golden_hex_bytes()

    assert {:ok, {parsed, <<0>>}} = Frame.decode(golden)
    assert parsed == %Frame{epoch: 0, key_id: 0x0102030405060708, frame_ordinal: 7, seq: 42}

    # reverse direction: our own encode of the genesis frame re-derives the fixture
    {:ok, iolist} =
      Frame.encode_frame(%Frame{epoch: 0, key_id: 0x0102030405060708, frame_ordinal: 7, seq: 42}, <<0>>)

    assert IO.iodata_to_binary(iolist) == golden
  end

  defp golden_hex_bytes do
    @golden_path
    |> File.read!()
    |> String.trim()
    |> String.to_charlist()
    |> Enum.chunk_every(2, 2, :discard)
    |> Enum.map(&String.to_integer(List.to_string(&1), 16))
    |> :binary.list_to_bin()
  end
end
