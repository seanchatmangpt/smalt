defmodule Smalt.Sync.Frame do
  # BK-39 unblock fix (compile-freeze SLA, disclosed in both lanes' receipts):
  # bxor/2 needs Bitwise; the owner lane was mid-write and the shared compile
  # was frozen for all lanes.
  import Bitwise

  @moduledoc """
  ATH-1 wire frame codec (domain-blind binary sync ingress). Byte-identical
  to the landed ATH-2 client codec (`workspace/lib/engine/codec.ts`).

  Frame layout (all integers big-endian, fixed 41-byte header):

      offset size field
      0      4    magic   = 0x534D4C54 ("SMLT")
      4      4    len     = payload byte length
      8      8    client_id (u64, producer identity as integer)
      16     8    seq       (u64, strictly monotonic per client)
      24     8    ts_ms     (u64, producer epoch millis)
      32     4    crc32     (IEEE CRC-32 over PAYLOAD only; vector 0xCBF43926)
      36     1    op        (integer opcode, checked never interpreted)
      37     4    reserved  (zero pad)
      41     len  payload

  Typed decode failures — every violation is a value, never a raise; the
  codes match the client codec's `CodecError` discriminants:

      {:error, {:bad_frame, "SHORT_FRAME"}}   # < 41 bytes for a header
      {:error, {:bad_frame, "BAD_MAGIC"}}     # MAGIC mismatch
      {:error, {:bad_frame, "BAD_LEN"}}       # declared LEN not fully present
      {:error, {:bad_frame, "BAD_RESERVED"}}  # reserved pad (offset 37..40) not zero

  A boundary-well-formed frame whose payload CRC fails is still returned as
  `{:ok, frame, rest}` with `frame.crc_ok == false` — the receiver turns
  that into the per-frame "BAD_CRC32" refusal; the batch continues.

  No domain word appears in this module: frames move opaque bytes; the `op`
  byte is checked as an integer, never interpreted.
  """

  @magic 0x534D4C54
  @header_bytes 41

  @doc "Wire magic (0x534D4C54)."
  def magic, do: @magic

  @doc "Fixed header size in bytes (41, including the 4-byte reserved pad)."
  def header_bytes, do: @header_bytes

  @doc """
  Encodes one frame. `frame` is a map with `:client_id`, `:seq`, `:ts_ms`
  (non-negative integers), optional `:op` (0..255, default 0) and
  `:payload` (binary). CRC32 is computed over the payload.
  """
  @spec encode(%{
          required(:client_id) => non_neg_integer(),
          required(:seq) => non_neg_integer(),
          required(:ts_ms) => non_neg_integer(),
          optional(:op) => non_neg_integer(),
          required(:payload) => binary()
        }) :: binary()
  def encode(%{client_id: c, seq: s, ts_ms: ts, payload: p} = f)
      when is_integer(c) and c >= 0 and is_integer(s) and s >= 0 and
             is_integer(ts) and ts >= 0 and is_binary(p) do
    op = Map.get(f, :op, 0)

    op in 0..255 ||
      raise ArgumentError,
            "Smalt.Sync.Frame.encode/1: :op must be an integer in 0..255, got: #{inspect(op)}"

    crc = :erlang.crc32(p)
    <<@magic::32, byte_size(p)::32, c::64, s::64, ts::64, crc::32, op::8, 0::32, p::binary>>
  end

  @doc """
  Decodes the first frame in `bin`. Returns `{:ok, frame, rest}` where
  `frame` carries `:client_id, :seq, :ts_ms, :op, :payload, :crc32,
  :crc_ok, :wire` (the exact bytes this frame occupied — the store feeds
  `:wire` to the receipt chain), or a typed
  `{:error, {:bad_frame, code}}` with code a `CodecError`-matching string.
  """
  @spec decode(binary()) ::
          {:ok, map(), binary()} | {:error, {:bad_frame, String.t()}}
  def decode(bin) when is_binary(bin) and byte_size(bin) < @header_bytes do
    {:error, {:bad_frame, "SHORT_FRAME"}}
  end

  def decode(bin) when is_binary(bin) do
    case bin do
      <<@magic::32, len::32, c::64, s::64, ts::64, crc::32, op::8, pad::binary-size(4),
        rest::binary>> ->
        if pad != <<0::32>> do
          # Reserved-zero law (doc/guard gap, EXPL8-R typed residue): the
          # header's reserved bytes pad the enumerated fields to the pinned
          # 41-byte wire header and are zero on the wire (ath1 court pins
          # pad == 0 on the encode side); a nonzero pad is a malformed
          # frame, refused typed, never silently accepted.
          {:error, {:bad_frame, "BAD_RESERVED"}}
        else
          case rest do
          <<payload::binary-size(^len), remainder::binary>> ->
            {:ok,
             %{
               client_id: c,
               seq: s,
               ts_ms: ts,
               op: op,
               payload: payload,
               crc32: crc,
               crc_ok: len == 0 or :erlang.crc32(payload) == crc,
               wire: binary_part(bin, 0, @header_bytes + len)
             }, remainder}

          _ ->
            {:error, {:bad_frame, "BAD_LEN"}}
          end
        end

      _ ->
        {:error, {:bad_frame, "BAD_MAGIC"}}
    end
  end

  @doc """
  Court fixture helper: flips the first payload byte so the stored CRC no
  longer matches. Requires a non-empty payload.
  """
  def corrupt_payload(frame_bin) do
    <<@magic::32, len::32, c::64, s::64, ts::64, crc::32, op::8, pad::32, first::8,
      rest::binary>> = frame_bin

    <<@magic::32, len::32, c::64, s::64, ts::64, crc::32, op::8, pad::32, bxor(first, 0xFF)::8,
      rest::binary>>
  end
end
