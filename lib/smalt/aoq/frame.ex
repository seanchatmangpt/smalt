defmodule Smalt.Aoq.Frame do
  @moduledoc """
  AoQ wire frame codec — v3 wire law (R1-I repositioning wave).

  The header layout is the landed ontology
  `ggen-marketplace/packs/aoq-pack/ontology.ttl`, projected twice: here
  via `Smalt.Aoq.GeneratedAoqHeaderLayout` (the graph twin) and, on the
  Rust side, by cgap-aoq's `generated_aoq_header_layout.rs`. One graph,
  two codecs, byte-identical wire (`test/courts/aoq_cross_repo_court.exs`).

  Wire layout (little-endian throughout, 64-byte header):

  | offset | width | field         |
  |--------|-------|---------------|
  | 0      | 4     | magic `0x414F5131` (LE bytes `"1QOA"`) |
  | 4      | 2     | version = 3   |
  | 6      | 2     | epoch (closed `Smalt.Aoq.Epoch` enum) |
  | 8      | 8     | key_id (u64)  |
  | 16     | 4     | frame_ordinal (u32) |
  | 20     | 4     | seq (u32)     |
  | 24     | 36    | reserved (zeros; digest-covered) |
  | 60     | 4     | FNV-1a32 over `[0,60)` |

  Framing law: every frame is exactly `64` bytes of header followed by a
  body of at least 1 byte, so the total is ≥65 bytes — RefcBinary
  territory (`ERL_ONHEAP_BIN_LIMIT = 64`). Frame handoff between
  Listener, pool, and workers is pointer-passing, never a heap-bin copy.

  Stream law (v3): the retired v2 type/flags bytes are gone. The FIRST
  body byte is the `aoq:StreamType` prefix (0=data, 1=control, 2=eos);
  the remainder is the stream payload. An unknown prefix refuses with
  `{:unknown_stream_type, t}`. EOS strictness: an EOS frame carries
  EXACTLY the 1-byte prefix — no payload — which simultaneously
  satisfies the ≥1-byte BEAM framing law (the prefix IS the body); a
  longer EOS body refuses with `{:bad_stream_body, 2}`.

  Egress law: `encode_frame/2` returns an iolist `[header, body]`, never
  a concatenation-appended flat binary. Writers (gen_tcp/ssl, file,
  Bandit adapter) consume iolists natively — scatter-gather straight into
  ErlIOVec, zero intermediate copy. The `header` half is built with `<>`
  (header construction only); the egress payload concat stays banned.

  Decode law (3-stage): (1) ≥65B guard + wire-shape match — fixed LE
  sizes only, fields extracted as integers (no field literals — a raw
  flip in `[0,60)` must reach the digest gate as `:bad_digest`); (2)
  FNV-1a32 computed over the ORIGINAL binary via `binary_part(bin, 0, 60)`,
  never a binary-append-constructed re-match; (3) full field checks in a
  context-reused head — refusal order magic → version → epoch (closed
  enum) → digest — then reserved literal `0::288`, then stream-type
  dispatch. `:bad_digest` replaces the v2 `:bad_crc`.
  """

  use Bitwise

  alias Smalt.Aoq.GeneratedAoqHeaderLayout, as: Layout
  alias Smalt.Aoq.Tables

  @header_size 64
  @min_body_size 1
  @magic <<"1QOA">>
  @version 3
  @reserved_bits 288
  @digest_span 60

  @doc "Fixed wire header size in bytes (spec §2)."
  @spec header_size() :: 64
  def header_size, do: @header_size

  @doc "Minimum body size in bytes (spec §2)."
  @spec min_body_size() :: 1
  def min_body_size, do: @min_body_size

  @doc "Wire magic — LE bytes of `0x414F5131`, i.e. `\"1QOA\"`."
  @spec magic() :: binary()
  def magic, do: @magic

  @doc "Wire protocol version (u16 LE at offset 4)."
  @spec version() :: 3
  def version, do: @version

  @doc """
  FNV-1a32 over `data` — the header integrity digest named by the landed
  graph (`aoq:hf-header-digest`); byte-identical to cgap-aoq's
  `codec::fnv1a32`.
  """
  @spec fnv1a32(binary()) :: non_neg_integer()
  def fnv1a32(data), do: fnv1a32_loop(data, 0, 0x811C_9DC5)

  defp fnv1a32_loop(<<b, rest::binary>>, i, hash) do
    fnv1a32_loop(rest, i + 1, bxor_oper(hash, b))
  end

  defp fnv1a32_loop(<<>>, _i, hash), do: hash

  defp bxor_oper(hash, b) do
    # hash = (hash xor b) * 0x01000193 mod 2^32
    rem(bxor(hash, b) * 0x0100_0193, 0x1_0000_0000)
  end

  @typedoc "64-byte frame header. Always exactly 64 bytes on the wire."
  @type header :: binary()

  @typedoc "Frame body: at least 1 byte; first byte is the StreamType prefix."
  @type body :: binary()

  @typedoc "u32 wrapping sequence number."
  @type seq :: non_neg_integer()

  @typedoc "u32 frame ordinal."
  @type frame_ordinal :: non_neg_integer()

  @typedoc "u64 key material id."
  @type key_id :: non_neg_integer()

  @typedoc "u16 epoch id (closed `Smalt.Aoq.Epoch` wire value)."
  @type epoch :: non_neg_integer()

  @typedoc "Decoded frame header fields. The v2 type/flags/payload_len fields are RETIRED."
  @type t :: %__MODULE__{
          epoch: epoch(),
          key_id: key_id(),
          frame_ordinal: frame_ordinal(),
          seq: seq()
        }

  defstruct [:epoch, :key_id, :frame_ordinal, :seq]

  @typedoc """
  Decode refusal reasons (all typed, none silent):

  - `:short_frame` — fewer than 65 bytes total (framing-law violation)
  - `:bad_header` — magic/version/epoch-enum/reserved/stream-body defect
    (checked in refusal order magic → version → epoch after a VALID digest;
    the retired sentinel epoch 65535 admits on decode as read-only)
  - `:bad_digest` — FNV-1a32 over `[0,60)` of the original binary does not
    match the stored digest (replaces v2 `:bad_crc`; covers reserved flips)
  - `{:unknown_epoch, e}` — epoch outside the closed enum (decode gate)
  - `{:unknown_stream_type, t}` — body prefix not in the re-keyed tables
  - `{:bad_stream_body, t}` — stream-shape defect (e.g. EOS with a payload)
  - `:tables_unbooted` — `Smalt.Aoq.Tables` seal absent
  """
  @type decode_error ::
          :short_frame
          | :bad_header
          | :bad_digest
          | {:unknown_epoch, epoch()}
          | {:unknown_stream_type, non_neg_integer()}
          | {:bad_stream_body, non_neg_integer()}
          | :tables_unbooted

  # ── egress ──────────────────────────────────────────────────────────

  @doc """
  Encodes a `%Frame{}` header plus a body (≥1 byte, first byte = the
  StreamType prefix) as an iolist `[header, body]`. Refuses `:retired`
  epochs (`:retired_epoch` — read-only sentinel, never written) and
  epochs outside the closed enum (`{:unknown_epoch, raw}`); all integer
  fields are range-guarded against wire-width overflow.
  """
  @spec encode_frame(t(), body()) ::
          {:ok, iolist()}
          | {:error,
             :empty_body
             | :retired_epoch
             | {:unknown_epoch, epoch()}
             | {:field_overflow, atom()}}
  def encode_frame(%__MODULE__{epoch: 65_535}, _body), do: {:error, :retired_epoch}

  def encode_frame(%__MODULE__{} = frame, body)
      when is_binary(body) and byte_size(body) >= @min_body_size and
             frame.epoch <= 0xFFFF and frame.epoch in [0, 1, 2] and
             frame.key_id <= 0xFFFFFFFFFFFFFFFF and
             frame.frame_ordinal <= 0xFFFFFFFF and frame.seq <= 0xFFFFFFFF do
    prefix =
      <<Layout.magic()::unsigned-little-integer-size(32), Layout.version()::unsigned-little-integer-size(16),
        frame.epoch::unsigned-little-integer-size(16), frame.key_id::unsigned-little-integer-size(64),
        frame.frame_ordinal::unsigned-little-integer-size(32), frame.seq::unsigned-little-integer-size(32),
        0::unsigned-integer-size(@reserved_bits)>> # AOQ-FENCE-OK: header-half construction (see moduledoc)

    digest = fnv1a32(prefix)

    # Header is exactly one 64-byte binary (contract: {:ok, [header, body]});
    # body rides as its own iolist segment (zero-copy RefcBinary handoff).
    header = prefix <> <<digest::unsigned-little-integer-size(32)>> # AOQ-FENCE-OK: header-half construction (see moduledoc)
    {:ok, [header, body]}
  end

  def encode_frame(%__MODULE__{}, <<>>), do: {:error, :empty_body}

  def encode_frame(%__MODULE__{epoch: epoch}, _body) when epoch not in [0, 1, 2],
    do: {:error, {:unknown_epoch, epoch}}

  def encode_frame(%__MODULE__{key_id: k}, _body) when k > 0xFFFFFFFFFFFFFFFF,
    do: {:error, {:field_overflow, :key_id}}

  def encode_frame(%__MODULE__{frame_ordinal: o}, _body) when o > 0xFFFFFFFF,
    do: {:error, {:field_overflow, :frame_ordinal}}

  def encode_frame(%__MODULE__{seq: s}, _body) when s > 0xFFFFFFFF,
    do: {:error, {:field_overflow, :seq}}

  # ── ingress: 3-stage decode ─────────────────────────────────────────

  @doc """
  Decodes one wire frame from a flat binary: `{:ok, {frame, body}}`
  where `body` is the frame body (≥1 byte, first byte = StreamType
  prefix), or a typed refusal (`t:decode_error/0`).

  Stage 1 matches wire shape with fixed LE sizes and extracts all fields
  as integers (no field literals); stage 2 computes the FNV-1a32 over
  `[0,60)` of the ORIGINAL binary (`binary_part` slice, never a
  `<>`-constructed re-match); stage 3 validates the fields in a
  context-reused head — refusal order magic → version → epoch — then the
  reserved literal `0::288`, then stream-type admission via the re-keyed
  `Smalt.Aoq.Tables`.
  """
  @spec decode(binary()) :: {:ok, {t(), body()}} | {:error, decode_error()}
  def decode(bin) when is_binary(bin) do
    if Tables.sealed?() do
      stage1_wire_shape(bin)
    else
      {:error, :tables_unbooted}
    end
  end

  # Stage 1: ≥65B guard, then wire shape. Fixed LE sizes before any
  # variable segment; all header fields extracted as integer segments (no
  # field literals — a raw flip anywhere in [0,60) must reach the stage 2
  # digest gate as :bad_digest, reserved flips included).
  defp stage1_wire_shape(bin) when byte_size(bin) < 65, do: {:error, :short_frame}

  defp stage1_wire_shape(bin) do
    case bin do
      <<magic::binary-size(4), version::unsigned-little-integer-size(16),
        epoch::unsigned-little-integer-size(16), key_id::unsigned-little-integer-size(64),
        frame_ordinal::unsigned-little-integer-size(32), seq::unsigned-little-integer-size(32),
        reserved::unsigned-integer-size(@reserved_bits), digest::unsigned-little-integer-size(32),
        _::binary>>
      when byte_size(bin) >= @header_size + @min_body_size ->
        # Stage 2: digest over [0,60) of the ORIGINAL binary —
        # binary_part slice, never a <>-constructed re-match. The digest
        # gate precedes the reserved check, so a reserved flip is
        # :bad_digest (the digest covers the reserved region).
        if fnv1a32(:erlang.binary_part(bin, 0, @digest_span)) == digest do
          stage3_fields(bin, magic, version, epoch, key_id, frame_ordinal, seq, reserved)
        else
          {:error, :bad_digest}
        end

      _ ->
        {:error, :bad_header}
    end
  end

  # Stage 3: field validation on segments extracted by stage 1's single
  # context-reused match, then FORWARDING ONLY into admit_stream — stage 3
  # extracts no sub-binary and re-slices nothing (bin_opt_info
  # context-reuse law). The head begins with a binary match on `bin`
  # (bin_opt law). Refusal order magic → version → epoch (closed enum,
  # retired sentinel included as read-only); then reserved literal 0::288;
  # then stream-type admission.
  defp stage3_fields(
         <<_::binary>> = bin,
         magic,
         version,
         epoch,
         key_id,
         frame_ordinal,
         seq,
         reserved
       )
       when magic == @magic and version == @version and reserved == 0 do
    if epoch in [0, 1, 2, 65_535] do
      admit_stream(bin, epoch, key_id, frame_ordinal, seq)
    else
      {:error, {:unknown_epoch, epoch}}
    end
  end

  defp stage3_fields(_bin, _magic, _version, _epoch, _k, _o, _s, _reserved),
    do: {:error, :bad_header}

  # Stream admission: the head binary-matches `bin` (bin_opt law — the
  # body sub-binary is created HERE, in a callee head, so no caller-side
  # sub-binary can lose its context; no binary_part slice, no <> copy).
  # The first body byte is the aoq:StreamType, admitted against the
  # re-keyed frame_types table; the inner match on `body` reuses its
  # context (sub-binary of a sub-binary stays context-reused). EOS
  # strictness: an EOS frame carries exactly the 1-byte prefix (its body
  # IS the prefix — that is what satisfies the ≥1-byte BEAM framing law);
  # a longer EOS body is a {:bad_stream_body, 2} refusal. Payload law:
  # the returned body includes the stream prefix, zero-copy.
  defp admit_stream(
         <<_header::binary-size(@header_size), body::binary>> = _bin,
         epoch,
         key_id,
         frame_ordinal,
         seq
       ) do
    <<stream_type::unsigned-integer-size(8), _body_rest::binary>> = body
    frame_types = Tables.frame_types()

    cond do
      not Map.has_key?(frame_types, stream_type) ->
        {:error, {:unknown_stream_type, stream_type}}

      stream_type == 2 and byte_size(body) > @min_body_size ->
        {:error, {:bad_stream_body, stream_type}}

      true ->
        parsed = %__MODULE__{
          epoch: epoch,
          key_id: key_id,
          frame_ordinal: frame_ordinal,
          seq: seq
        }

        {:ok, {parsed, body}}
    end
  end

  # ── dispatch handlers (frame_types table targets, re-keyed by
  #    aoq:StreamType) ─────────────────────────────────────────────────

  @doc "Data-stream handler (`aoq:stream-data`, wire value 0)."
  @spec handle_data(t(), body()) :: :ok
  def handle_data(%__MODULE__{}, _body), do: :ok

  @doc "Control-stream handler (`aoq:stream-control`, wire value 1)."
  @spec handle_control(t(), body()) :: :ok
  def handle_control(%__MODULE__{}, _body), do: :ok

  @doc "EOS handler (`aoq:stream-eos`, wire value 2)."
  @spec handle_eos(t(), body()) :: :ok
  def handle_eos(%__MODULE__{}, _body), do: :ok

  @doc """
  Epoch-rotate handler (control-stream contract). The header epoch is the
  CURRENT epoch (admitted by decode against the closed enum); the body is
  the stream prefix `1` (control) followed by exactly 2 bytes: the NEW
  epoch id as u16 big-endian.

  Lawful path: append the new epoch via `Smalt.Aoq.Tables.rotate_epoch/2`
  (whole-map re-put, append-only) storing `{:rotated_from, current_epoch,
  seq}` as the epoch value. Typed refusals:

  - `{:error, {:bad_rotate_payload, payload}}` — body not prefix + 2 bytes
  - `{:error, :tables_unbooted}` — pre-boot rotate
  - `{:error, {:epoch_regression, new, max_existing}}` — stale/regressing epoch
  """
  @spec handle_epoch_rotate(t(), body()) ::
          :ok
          | {:error,
             {:bad_rotate_payload, body()}
             | :tables_unbooted
             | {:epoch_regression, epoch(), non_neg_integer()}}
  def handle_epoch_rotate(%__MODULE__{epoch: current, seq: seq}, <<1, new_epoch::unsigned-integer-size(16)>>) do
    Tables.rotate_epoch(new_epoch, {:rotated_from, current, seq})
  end

  def handle_epoch_rotate(_, other), do: {:error, {:bad_rotate_payload, other}}

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
  Encode `{header, body}` as an iolist `[header, body]`.

  Body must be ≥1 byte — a zero-length body would make a 64B total,
  which is a HeapBin. Returns `{:error, :empty_body}` rather than
  emitting a frame that violates the framing law.
  """
  @spec encode(header(), body()) ::
          {:ok, iolist()} | {:error, :short_header | :empty_body}
  def encode(header, body)

  def encode(header, body) when is_binary(header) and is_binary(body) do
    if byte_size(header) == 64 do
      if byte_size(body) >= 1 do
        {:ok, [header, body]}
      else
        {:error, :empty_body}
      end
    else
      {:error, :short_header}
    end
  end

  def encode(_, _), do: {:error, :short_header}
end
