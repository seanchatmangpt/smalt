defmodule AoqFramingCourt do
  @moduledoc """
  LANE-13 / C6 byte-fidelity court for the AoQ framing + egress laws
  (aq-architecture-spec §2/§3).

  Asserts on the wire format itself, not on call counts:
  - header exactly 64 bytes, body ≥1 byte (RefcBinary framing law, §2)
  - encoded payloads ≥65 bytes total — HeapBin territory never entered
  - iolist egress produces byte-identical wire bytes to a `<>` reference
    encode (§3 fidelity)
  - decode: full field layout, CRC over the original binary, typed
    refusal matrix, seq wrap order, byte-fidelity through a real file
  """
  use ExUnit.Case, async: true

  alias Smalt.Aoq.Cursor
  alias Smalt.Aoq.Frame
  alias Smalt.Aoq.Tables

  @header_size 64
  @max_u64 0xFFFFFFFFFFFFFFFF

  setup do
    on_exit(fn -> :persistent_term.erase({:aoq, :sealed}) end)
    Tables.boot(epochs: %{0 => {:key0, 0}, 1 => {:key1, 0}, 0xFFFF => {:key_max, 0}})
    :ok
  end

  defp ref_header, do: :crypto.strong_rand_bytes(@header_size)

  defp frame(opts \\ []) do
    %Frame{
      epoch: Keyword.get(opts, :epoch, 1),
      seq: Keyword.get(opts, :seq, 7),
      type: Keyword.get(opts, :type, 0x01),
      flags: Keyword.get(opts, :flags, 0x0000),
      payload_len: Keyword.get(opts, :payload_len, 4)
    }
  end

  # Rewrite one header byte and recompute the CRC over bytes 0..31, so the
  # mutation lands on the FIELD check rather than being swallowed by :bad_crc.
  defp mutate(bin, idx, value) do
    patched =
      binary_part(bin, 0, idx) <>
        <<value>> <>
        binary_part(bin, idx + 1, byte_size(bin) - idx - 1)

    crc = :erlang.crc32(binary_part(patched, 0, 32))

    binary_part(patched, 0, 32) <>
      <<crc::unsigned-integer-size(32)>> <>
      binary_part(patched, 36, byte_size(patched) - 36)
  end

  defp flip_byte(bin, idx) do
    byte = :binary.at(bin, idx)
    mutate(bin, idx, :erlang.bxor(byte, 0b0000_0001))
  end

  # ── legacy surface (kept green) ─────────────────────────────────────

  test "header size constant is exactly 64" do
    assert Frame.header_size() == 64
  end

  test "encode returns an iolist [header | payload], not a flat binary" do
    header = ref_header()
    payload = :crypto.strong_rand_bytes(200)

    assert {:ok, frame} = Frame.encode(header, payload)
    assert is_list(frame)
    assert frame == [header, payload]
    # iolist, not `<>`-concatenated binary
    refute is_binary(frame)
  end

  test "encoded frame is ≥65 bytes — RefcBinary territory, never a HeapBin" do
    {:ok, frame} = Frame.encode(ref_header(), <<0xFF>>)
    total = :erlang.iolist_size(frame)
    assert total >= 65
    assert byte_size(IO.iodata_to_binary(frame)) >= 65
  end

  test "zero-length payload is refused (would total exactly 64 — HeapBin)" do
    assert {:error, :empty_payload} = Frame.encode(ref_header(), <<>>)
    assert {:error, :empty_payload} = Frame.encode_frame(frame(), <<>>)
  end

  test "short header is refused" do
    assert {:error, :short_header} = Frame.encode(<<0::size(8 * 63)>>, <<1>>)
    assert {:error, :short_header} = Frame.encode("not-a-binary", <<1>>)
  end

  test "split round-trips a lawful frame" do
    header = ref_header()
    body = :crypto.strong_rand_bytes(97)

    wire = IO.iodata_to_binary([header, body])
    assert {:ok, ^header, ^body} = Frame.split(wire)
  end

  test "split refuses sub-65B frames (framing law violation, not a short read)" do
    assert {:error, :short_frame} = Frame.split(:crypto.strong_rand_bytes(64))
    assert {:error, :short_frame} = Frame.split(:crypto.strong_rand_bytes(63))
  end

  test "byte fidelity: iolist egress == <> reference encode" do
    header = ref_header()
    payload = :crypto.strong_rand_bytes(1000)

    {:ok, iolist_frame} = Frame.encode(header, payload)
    reference = header <> payload

    assert IO.iodata_to_binary(iolist_frame) == reference
  end

  test "payload sizes spanning the 64B boundary all land ≥65B total" do
    for n <- [1, 32, 64, 65, 128, 4096] do
      {:ok, frame} = Frame.encode(ref_header(), :crypto.strong_rand_bytes(n))
      assert :erlang.iolist_size(frame) == @header_size + n
      assert :erlang.iolist_size(frame) >= 65
    end
  end

  # ── wire layout ─────────────────────────────────────────────────────

  test "encode_frame emits the exact field layout (64B header + payload iolist)" do
    payload = <<9, 8, 7, 6>>
    {:ok, [header, ^payload]} = Frame.encode_frame(frame(payload_len: 4), payload)

    assert byte_size(header) == 64
    assert binary_part(header, 0, 4) == "AOQ1"
    assert :binary.at(header, 4) == 1
    assert :binary.decode_unsigned(binary_part(header, 5, 2)) == 1
    assert :binary.decode_unsigned(binary_part(header, 7, 8)) == 7
    assert :binary.at(header, 15) == 0x01
    assert :binary.decode_unsigned(binary_part(header, 16, 2)) == 0x0000
    assert binary_part(header, 18, 6) == <<0::48>>
    assert :binary.decode_unsigned(binary_part(header, 24, 8)) == 4
    assert :binary.decode_unsigned(binary_part(header, 32, 4)) ==
             :erlang.crc32(binary_part(header, 0, 32))
    assert binary_part(header, 36, 28) == <<0::224>>
  end

  # ── roundtrip falsifiers ────────────────────────────────────────────

  test "encode/decode roundtrips across the payload-size boundary sweep" do
    for n <- [1, 32, 64, 65, 128, 4096, 65_536] do
      payload = :crypto.strong_rand_bytes(n)
      wire = frame(payload_len: n) |> then(&Frame.encode_frame(&1, payload)) |> ok_iolist()

      assert :erlang.iolist_size(wire) == @header_size + n

      assert {:ok, {parsed, ^payload}} = Frame.decode(IO.iodata_to_binary(wire))
      assert parsed == frame(payload_len: n)
    end
  end

  test "seq wrap: 2^64-1 roundtrips and Cursor.seq_before? orders the wrap" do
    payload = <<1>>
    wire = frame(seq: @max_u64, payload_len: 1) |> then(&Frame.encode_frame(&1, payload)) |> ok_iolist()

    assert {:ok, {%Frame{seq: @max_u64}, ^payload}} = Frame.decode(IO.iodata_to_binary(wire))

    assert Cursor.seq_before?(@max_u64, 0)
    refute Cursor.seq_before?(0, @max_u64)
    refute Cursor.seq_before?(@max_u64, @max_u64)
  end

  test "boundary epoch / type / flags roundtrip" do
    for {epoch, type, flags} <- [{0, 0x01, 0}, {0xFFFF, 0x02, 0x0007}, {1, 0x7F, 0b101}] do
      payload = <<0xDE, 0xAD>>
      wire = frame(epoch: epoch, type: type, flags: flags, payload_len: 2) |> then(&Frame.encode_frame(&1, payload)) |> ok_iolist()

      assert {:ok, {parsed, ^payload}} = Frame.decode(IO.iodata_to_binary(wire))
      assert parsed.epoch == epoch
      assert parsed.type == type
      assert parsed.flags == flags
    end
  end

  # ── corrupt-field refusal matrix ────────────────────────────────────

  test "bad magic is refused (:bad_header)" do
    wire = lawful_wire()
    assert {:error, :bad_header} = Frame.decode(mutate(wire, 0, ?X))
  end

  test "version=2 is refused (:bad_header)" do
    wire = lawful_wire()
    assert {:error, :bad_header} = Frame.decode(mutate(wire, 4, 2))
  end

  test "unknown frame type 0x42 is refused ({:unknown_frame_type, 0x42})" do
    wire = lawful_wire(type: 0x42)
    assert {:error, {:unknown_frame_type, 0x42}} = Frame.decode(wire)
  end

  test "unknown epoch 0xBEEF is refused ({:unknown_epoch, 0xBEEF})" do
    wire = lawful_wire(epoch: 0xBEEF)
    assert {:error, {:unknown_epoch, 0xBEEF}} = Frame.decode(wire)
  end

  test "nonzero reserved byte at EVERY reserved position is refused (:bad_header)" do
    base = lawful_wire()

    for idx <- Enum.to_list(18..23) ++ Enum.to_list(36..63) do
      assert {:error, :bad_header} = Frame.decode(flip_byte(base, idx)),
             "reserved byte #{idx} flip must refuse"
    end
  end

  test "payload_len mismatch is refused (:bad_header)" do
    wire = lawful_wire(payload_len: 4)
    # declared len 4 → set to 5 (recompute CRC so the field check fires)
    assert {:error, :bad_header} = Frame.decode(mutate(wire, 31, 5))
  end

  test "bit-flip in bytes 0..31 is refused (:bad_crc) — CRC over original bytes" do
    base = lawful_wire()

    for idx <- Enum.to_list(0..31) do
      # raw flip: CRC field deliberately NOT recomputed
      flipped = flip_byte_raw(base, idx)
      assert {:error, :bad_crc} = Frame.decode(flipped), "byte #{idx} flip must be :bad_crc"
    end
  end

  test "unknown flags bit 0x0008 is refused (:bad_header)" do
    wire = lawful_wire(flags: 0x0008)
    assert {:error, :bad_header} = Frame.decode(wire)
  end

  test "sub-65B frames are refused (:short_frame)" do
    for n <- [0, 1, 32, 63, 64] do
      assert {:error, :short_frame} = Frame.decode(:crypto.strong_rand_bytes(n))
    end
  end

  test "unbooted tables refuse with :tables_unbooted" do
    :persistent_term.erase({:aoq, :sealed})
    wire = lawful_wire()
    assert {:error, :tables_unbooted} = Frame.decode(wire)
    # restore for the async siblings of this process (seal is shared state)
    Tables.boot(epochs: %{0 => {:key0, 0}, 1 => {:key1, 0}, 0xFFFF => {:key_max, 0}})
  end

  # ── byte fidelity ───────────────────────────────────────────────────

  test "byte fidelity: decode of iolist-written file bytes == decode of flat bytes" do
    payload = :crypto.strong_rand_bytes(300)
    iolist = frame(payload_len: 300) |> then(&Frame.encode_frame(&1, payload)) |> ok_iolist()
    flat = IO.iodata_to_binary(iolist)

    path = Path.join(System.tmp_dir(), "aoq-framing-court-#{System.unique_integer()}.bin")
    on_exit(fn -> File.rm(path) end)

    assert :ok = :file.write_file(String.to_charlist(path), iolist, [:binary])
    assert {:ok, from_file} = File.read(path)

    assert from_file == flat
    assert {:ok, {a, ^payload}} = Frame.decode(from_file)
    assert {:ok, {b, ^payload}} = Frame.decode(flat)
    assert a == b
  end

  # ── helpers ─────────────────────────────────────────────────────────

  defp ok_iolist({:ok, iolist}), do: iolist

  defp flip_byte_raw(bin, idx) do
    byte = :binary.at(bin, idx)

    binary_part(bin, 0, idx) <>
      <<:erlang.bxor(byte, 1)>> <>
      binary_part(bin, idx + 1, byte_size(bin) - idx - 1)
  end

  # Reference encoder: builds the wire bytes directly from the field table
  # (deliberately independent of Frame.encode_frame so corrupt-field cases
  # like unknown flag bits — which encode_frame refuses — can be emitted).
  defp lawful_wire(opts \\ []) do
    epoch = Keyword.get(opts, :epoch, 1)
    seq = Keyword.get(opts, :seq, 7)
    type = Keyword.get(opts, :type, 0x01)
    flags = Keyword.get(opts, :flags, 0x0000)
    payload_len = Keyword.get(opts, :payload_len, 4)
    payload = :crypto.strong_rand_bytes(payload_len)

    prefix =
      <<("AOQ1")::binary, 1::size(8), epoch::unsigned-integer-size(16),
        seq::unsigned-integer-size(64), type::size(8), flags::unsigned-integer-size(16),
        0::unsigned-integer-size(48)>> <> <<payload_len::unsigned-integer-size(64)>>

    crc = :erlang.crc32(prefix)
    header = prefix <> <<crc::unsigned-integer-size(32), 0::unsigned-integer-size(224)>>
    IO.iodata_to_binary([header, payload])
  end
end
