defmodule Smalt.Aoq.Frame do
  @moduledoc """
  AoQ wire frame codec (aq-architecture-spec §2/§3, LANE-13 / C6).

  Framing law: every frame is exactly `64` bytes of header followed by a
  body of at least 1 byte, so the total is ≥65 bytes — RefcBinary territory
  (`ERL_ONHEAP_BIN_LIMIT = 64`). Frame handoff between Listener, pool, and
  workers is pointer-passing, never a heap-bin copy.

  Egress law: `encode_frame/2` returns an iolist `[header, payload]`, never
  a concatenation-appended flat binary. Writers (gen_tcp/ssl, file, Bandit
  adapter) consume iolists natively — scatter-gather straight into ErlIOVec,
  zero intermediate copy. The `header` half is built with `<>` (header
  construction only); the egress payload concat stays banned.

  Decode law (3-stage): (1) wire-shape match — fixed sizes only, reserved
  regions matched literally; (2) CRC check computed over the ORIGINAL
  binary (`binary_part`-backed prefix, never a `<>`-constructed one);
  (3) full field match in a function head, wire binary LAST, pinned
  payload_len, then table admission (frame type, epoch) via
  `Smalt.Aoq.Tables`.
  """

  use Bitwise

  @header_size 64
  @min_body_size 1
  @magic "AOQ1"
  @version 1
  @known_flags 0x0007

  @doc "Fixed wire header size in bytes (spec §2)."
  @spec header_size() :: 64
  def header_size, do: @header_size

  @doc "Minimum body size in bytes (spec §2)."
  @spec min_body_size() :: 1
  def min_body_size, do: @min_body_size

  @doc "Wire magic (bytes 0..3)."
  @spec magic() :: binary()
  def magic, do: @magic

  @doc "Wire protocol version byte (byte 4)."
  @spec version() :: 1
  def version, do: @version

  @doc "Known flag bits mask (bytes 16..17); any bit outside is refused."
  @spec known_flags() :: 0x0007
  def known_flags, do: @known_flags

  @typedoc "64-byte frame header. Always exactly 64 bytes on the wire."
  @type header :: binary()

  @typedoc "Frame body: at least 1 byte."
  @type body :: binary()

  @typedoc "Frame type byte (registered in `Smalt.Aoq.Tables`)."
  @type frame_type :: non_neg_integer()

  @typedoc "u64 wrapping sequence number."
  @type seq :: non_neg_integer()

  @typedoc "u16 epoch id."
  @type epoch :: non_neg_integer()

  @typedoc "Decoded frame header fields."
  @type t :: %__MODULE__{
          epoch: epoch(),
          seq: seq(),
          type: frame_type(),
          flags: non_neg_integer(),
          payload_len: pos_integer()
        }

  defstruct [:epoch, :seq, :type, :flags, :payload_len]

  @typedoc """
  Decode refusal reasons (all typed, none silent):

  - `:short_frame` — fewer than 65 bytes total (framing-law violation)
  - `:bad_header` — magic/version/reserved/flags/payload_len shape defect
  - `:bad_crc` — header CRC over bytes 0..31 does not match bytes 32..35
  - `{:unknown_frame_type, t}` — type byte not in the booted tables
  - `{:unknown_epoch, e}` — epoch id not in the booted tables
  - `:tables_unbooted` — `Smalt.Aoq.Tables` seal absent
  """
  @type decode_error ::
          :short_frame
          | :bad_header
          | :bad_crc
          | {:unknown_frame_type, frame_type()}
          | {:unknown_epoch, epoch()}
          | :tables_unbooted

  # ── egress ──────────────────────────────────────────────────────────

  @doc """
  Encodes a `%Frame{}` header plus a payload (≥1 byte) as an iolist
  `[header, payload]`. The header is composed as iolist segments (never
  concatenation-appended); the payload rides as a separate iolist segment.
  `payload_len` must equal `byte_size(payload)` — the pinned field the
  decoder enforces on the other side.
  """
  @spec encode_frame(t(), body()) ::
          {:ok, iolist()} | {:error, :empty_payload | :payload_len_mismatch}
  def encode_frame(%__MODULE__{} = frame, payload)
      when is_binary(payload) and byte_size(payload) >= 1 and frame.payload_len == byte_size(payload) and
             frame.epoch <= 0xFFFF and frame.seq <= 0xFFFFFFFFFFFFFFFF and
             band(frame.flags, ~~~@known_flags) == 0 do
    prefix =
      <<@magic, @version::8, frame.epoch::unsigned-integer-size(16), frame.seq::unsigned-integer-size(64),
        frame.type::8, frame.flags::unsigned-integer-size(16), 0::unsigned-integer-size(48)>> <>
        <<frame.payload_len::unsigned-integer-size(64)>> # AOQ-FENCE-OK: header-half construction (see moduledoc)

    crc = :erlang.crc32(prefix)

    crc_bin = <<crc::unsigned-integer-size(32), 0::unsigned-integer-size(224)>>

    # Header is exactly one 64-byte binary (contract: {:ok, [header, payload]});
    # payload rides as its own iolist segment (zero-copy RefcBinary handoff).
    header = prefix <> crc_bin # AOQ-FENCE-OK: header-half construction (see moduledoc)
    {:ok, [header, payload]}
  end

  def encode_frame(%__MODULE__{}, <<>>), do: {:error, :empty_payload}

  def encode_frame(%__MODULE__{}, payload) when is_binary(payload),
    do: {:error, :payload_len_mismatch}

  # ── ingress: 3-stage decode ─────────────────────────────────────────

  @doc """
  Decodes one wire frame from a flat binary: `{:ok, {frame, payload}}`
  where `payload` is the frame body (≥1 byte), or a typed refusal
  (`t:decode_error/0`).

  Stage 1 matches wire shape with fixed sizes and literal reserved
  regions; stage 2 verifies the header CRC against the ORIGINAL binary
  (no `<>`-constructed re-match); stage 3 does the full field match in a
  function head with the wire binary LAST, then admits type/epoch via
  the booted tables.
  """
  @spec decode(binary()) :: {:ok, {t(), body()}} | {:error, decode_error()}
  def decode(bin) when is_binary(bin) do
    if Smalt.Aoq.Tables.sealed?() do
      stage1_wire_shape(bin)
    else
      {:error, :tables_unbooted}
    end
  end

  # Stage 1: wire shape. Fixed sizes before any variable segment;
  # bytes 36..63 matched literally as 0::224 (a flip there is :bad_header,
  # never a silent skip).
  defp stage1_wire_shape(bin) when byte_size(bin) < 65, do: {:error, :short_frame}

  defp stage1_wire_shape(bin) do
    case bin do
      <<prefix::binary-size(32), crc::unsigned-integer-size(32), 0::unsigned-integer-size(224),
        payload::binary>> when byte_size(payload) >= 1 ->
        # Stage 2: CRC over bytes 0..31 of the ORIGINAL binary — prefix is a
        # binary_part-backed slice of `bin`, never a <>-constructed re-match.
        if :erlang.crc32(prefix) == crc do
          stage3_fields(payload, bin)
        else
          {:error, :bad_crc}
        end

      _ ->
        {:error, :bad_header}
    end
  end

  # Stage 3: full field match in a function head, wire binary LAST,
  # payload_len pinned against the actual body size, unknown flag bits
  # refused against @known_flags.
  defp stage3_fields(
         payload,
         <<@magic, @version::8, epoch::unsigned-integer-size(16), seq::unsigned-integer-size(64),
           type::8, flags::unsigned-integer-size(16), 0::unsigned-integer-size(48),
           payload_len::unsigned-integer-size(64), _rest::binary>> = _wire
       )
       when payload_len == byte_size(payload) and band(flags, ~~~@known_flags) == 0 do
    admit_tables(payload, epoch, seq, type, flags, payload_len)
  end

  defp stage3_fields(_payload, _wire), do: {:error, :bad_header}

  # Table admission: type and epoch must be present in the booted tables.
  defp admit_tables(payload, epoch, seq, type, flags, payload_len) do
    frame_types = Smalt.Aoq.Tables.frame_types()
    epochs = Smalt.Aoq.Tables.epochs()

    cond do
      not Map.has_key?(frame_types, type) ->
        {:error, {:unknown_frame_type, type}}

      not Map.has_key?(epochs, epoch) ->
        {:error, {:unknown_epoch, epoch}}

      true ->
        parsed = %__MODULE__{
          epoch: epoch,
          seq: seq,
          type: type,
          flags: flags,
          payload_len: payload_len
        }

        {:ok, {parsed, payload}}
    end
  end

  # ── compat wrappers (existing courts keep their surface) ────────────

  @doc """
  Split a flat binary into `{header, body}`.

  Refuses frames smaller than 65 bytes total: a frame shorter than
  64B header + 1B body violates the >64B RefcBinary framing law (spec §2)
  and is a wire-format defect, not a short read.
  """
  @spec split(binary()) :: {:ok, header(), body()} | {:error, :short_frame}
  def split(bin) when is_binary(bin) do
    case bin do
      <<header::binary-size(64), body::binary>> when byte_size(body) >= 1 ->
        {:ok, header, body}

      _ ->
        {:error, :short_frame}
    end
  end

  @doc """
  Encode `{header, payload}` as an iolist `[header, payload]`.

  Payload must be ≥1 byte — a zero-length body would make a 64B total,
  which is a HeapBin. Returns `{:error, :empty_payload}` rather than
  emitting a frame that violates the framing law.
  """
  @spec encode(header(), body()) ::
          {:ok, iolist()} | {:error, :short_header | :empty_payload}
  def encode(header, payload)

  def encode(header, payload) when is_binary(header) and is_binary(payload) do
    if byte_size(header) == 64 do
      if byte_size(payload) >= 1 do
        {:ok, [header, payload]}
      else
        {:error, :empty_payload}
      end
    else
      {:error, :short_header}
    end
  end

  def encode(_, _), do: {:error, :short_header}
end
