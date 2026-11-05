defmodule Smalt.Messaging.Kafka.Records do
  # compile-freeze SLA unblock (AZ-4 lane): band/bor/bxor/<<< in guards and
  # bodies need Bitwise; disclose in both lanes' receipts.
  import Bitwise
  @moduledoc """
  AZ-1 — Kafka RecordBatch (magic 2) codec + legacy message-set framing.

  RecordBatch layout per the protocol guide (RecordBatch section,
  https://kafka.apache.org/protocol#The_Messages_Produce):

      baseOffset int64            — assigned by the BROKER at produce time
      batchLength int32           — bytes from partitionLeaderEpoch to batch end
      partitionLeaderEpoch int32
      magic int8 = 2
      crc u32                     — CRC32C over bytes from `attributes` to batch end
      attributes int16
      lastOffsetDelta int32
      baseTimestamp int64
      maxTimestamp int64
      producerId int64
      producerEpoch int16
      baseSequence int32
      recordsCount int32
      records...                  — varint-framed records

  Message-set framing (what Produce/Fetch carry on the wire): repeated
  {int64 offset, int32 size, batch bytes}. Classic clients (kafka-python
  included) parse this same wrapper around magic-2 batches at Fetch v0.
  """

  alias Smalt.Messaging.Kafka.Wire

  @typedoc "One parsed record: nil for null key/value."
  @type kafka_record :: %{key: binary() | nil, value: binary() | nil}

  @typedoc "One verified batch: original wire bytes + parsed records."
  @type batch :: %{raw: binary(), count: pos_integer(), records: [kafka_record()]}

  @batch_header 61
  # Legacy magic-0 frame (stripped of the {offset i64, size i32} wrapper):
  # crc u32 | magic i8 | attributes i8 | keyLen i32 | valueLen i32 minimum.
  @legacy_min 14

  @doc """
  Parse the Produce record_set: EITHER the legacy message-set framing
  (repeated {int64 offset, int32 size, batch bytes}) OR a bare magic-2
  RecordBatch stream (the Produce v3+ record_set face — the batch is
  self-delimiting via baseOffset/batchLength, no wrapper).

  v26.11.6 L6 (witnessed defect, disclosed): the vendored kafka-python-ng
  client at the (0,11,0) posture sends Produce v3 with a BARE magic-2
  batch; the old parser assumed the wrapper framing, ate 12 bytes of the
  batch, and the conn killed with {:corrupt_batch, :too_short} — a real
  client produce was unservable. The bare face is detected mechanically:
  a self-describing magic-2 batch (byte 16 == 2 AND byte_size == 12 +
  batchLength). Returns `{:ok, [batch_binary]}` (raw batch bytes kept
  verbatim for byte-exact re-serving) or `{:error, reason}`. CRC/magic
  verification is `verify_batch/1`'s fail-closed job, not this parser's.
  """
  @spec parse_message_set(binary()) :: {:ok, [binary()]} | {:error, term()}
  def parse_message_set(bin) when is_binary(bin) do
    case bare_magic2_batch?(bin) do
      true -> {:ok, [bin]}
      false -> parse_ms(bin, [])
    end
  end

  # Bare magic-2 RecordBatch (Produce v3+ record_set face): magic at byte
  # 16 and byte_size == 12 + batchLength — the self-description the legacy
  # {offset, size} wrapper framing cannot produce.
  defp bare_magic2_batch?(bin) when is_binary(bin) and byte_size(bin) >= 21 do
    case bin do
      <<_::binary-size(8), blen::signed-integer-size(32), _::binary-size(4),
        2::integer-size(8), _::binary>> ->
        byte_size(bin) == 12 + blen

      _ ->
        false
    end
  end

  defp bare_magic2_batch?(_), do: false

  defp parse_ms(<<>>, acc), do: {:ok, Enum.reverse(acc)}

  defp parse_ms(
         <<_offset::signed-integer-size(64), size::unsigned-integer-size(32),
           batch::binary-size(size)-unit(8), rest::binary>>,
         acc
       )
       when size >= @legacy_min do
    parse_ms(rest, [batch | acc])
  end

  defp parse_ms(_, _), do: {:error, :bad_message_set_frame}

  @doc "The batch magic byte (byte 16 of the RecordBatch)."
  @spec magic(binary()) :: {:ok, non_neg_integer()} | {:error, :too_short}
  def magic(<<_::binary-size(16), magic::integer-size(8), _::binary>>), do: {:ok, magic}
  def magic(_), do: {:error, :too_short}

  @doc """
  Fail-closed batch verification, dispatched on the magic byte: magic 2
  (RecordBatch) verifies CRC32C over bytes from `attributes` to batch end;
  legacy magic 0/1 (message-set records) verifies the IEEE CRC32 over the
  bytes after the CRC field. Returns :ok or a typed error — the caller kills
  the connection per the crash-only law.
  """
  @spec verify_batch(binary()) ::
          :ok | {:error, :too_short | {:bad_magic, integer()} | :crc_mismatch}
  def verify_batch(<<_::binary-size(16), 2::integer-size(8), _::binary>> = batch)
      when is_binary(batch) and byte_size(batch) >= @batch_header do
    # 16 = 8 baseOffset + 4 batchLength + 4 partitionLeaderEpoch; magic at 16,
    # CRC at 17..20, CRC32C covers bytes from `attributes` (21) to batch end.
    <<_::binary-size(17), crc::unsigned-integer-size(32), rest::binary>> = batch

    if Wire.crc32c(rest) == crc, do: :ok, else: {:error, :crc_mismatch}
  end

  def verify_batch(<<crc::unsigned-integer-size(32), magic::integer-size(8), _attrs::8,
                     _rest::binary>> = frame)
      when is_binary(frame) and byte_size(frame) >= @legacy_min and magic in [0, 1] do
    # Legacy: IEEE CRC32 covers everything after the CRC field.
    <<_::binary-size(4), body::binary>> = frame
    if :erlang.crc32(body) == crc, do: :ok, else: {:error, :crc_mismatch}
  end

  def verify_batch(_), do: {:error, :too_short}

  # BK-KFKC: count/1 dispatches on the MAGIC BYTE first. # KD-COVERS: KD-180
  # The old clause
  # ordering read bytes 57..60 of ANY binary >= 61B, so legacy magic-0/1
  # frames >= 61B (value >= 47B) got count = payload bytes (witnessed:
  # a single 60-byte produce jumped hwm 0 -> 1_116_385_94x / 0x42424242).
  # Magic 2: recordsCount int32 at byte 57. Legacy magic-0/1: exactly one
  # record per frame. Anything else (including a magic-2 batch whose
  # recordsCount <= 0): typed error, never a guessed count.
  @doc "Record count, dispatched on magic: magic-2 header recordsCount (byte 57); legacy magic-0/1 = 1."
  @spec count(binary()) :: {:ok, pos_integer()} | {:error, :too_short | {:bad_count, integer()}}
  def count(<<_::binary-size(16), 2::integer-size(8), _::binary>> = batch)
      when is_binary(batch) and byte_size(batch) >= @batch_header do
    <<_::binary-size(57), n::unsigned-integer-size(32), _::binary>> = batch

    if n > 0, do: {:ok, n}, else: {:error, {:bad_count, n}}
  end

  # Legacy magic-0/1 message-set record: exactly one record per frame.
  def count(<<_crc::unsigned-integer-size(32), magic::integer-size(8), _attrs::8, _::binary>>)
      when magic in [0, 1],
      do: {:ok, 1}

  def count(_), do: {:error, :too_short}

  @doc """
  Parse the records region (everything after the 61-byte batch header) into
  individual records (nil = null). Record fields use SIGNED varints
  (zigzag, LEB128) per the record format v2 — keyLength -1 is the null face,
  which is exactly why the signed decode is mandatory here.

  EXPL-4 F3 (fail-closed): the header `recordsCount` is cross-checked
  against the parsed record list — a malformed tail (or any count mismatch)
  answers `{:error, :record_count_mismatch}`; records are never silently
  dropped from the tail of a CRC-valid batch.
  """
  @spec parse_records(binary()) ::
          {:ok, [kafka_record()]} | {:error, :too_short | :record_count_mismatch}
  def parse_records(<<_::binary-size(16), 2::integer-size(8), _::binary>> = batch)
      when is_binary(batch) and byte_size(batch) >= @batch_header do
    <<_::binary-size(@batch_header), records::binary>> = batch
    parsed = parse_records_loop(records, [])

    case count(batch) do
      {:ok, declared} when declared == length(parsed) -> {:ok, parsed}
      {:ok, _declared} -> {:error, :record_count_mismatch}
      err -> err
    end
  end

  # Legacy magic-0/1 frame (crc|magic|attrs[|ts]|keyLen|key|valueLen|value):
  # one record per frame, null face = length -1. BK-KFKC: the F3 cross-check
  # now also fires on the legacy face — the declared count (1, from the magic
  # dispatch in count/1) must equal the parsed record list length, else typed
  # {:error, :record_count_mismatch}.
  def parse_records(<<_crc::unsigned-integer-size(32), magic::integer-size(8), _attrs::8,
                     _::binary>> = frame)
      when magic in [0, 1] do
    with {:ok, recs} <- legacy_parse(magic, :binary.part(frame, 6, byte_size(frame) - 6)),
         {:ok, declared} <- count(frame) do
      if declared == length(recs), do: {:ok, recs}, else: {:error, :record_count_mismatch}
    end
  end

  def parse_records(_), do: {:error, :too_short}

  # v26.11.6 L6: fused count+parse admission — the ONE parse the partition
  # log engine rides ({Smalt.Messaging.Kafka.Records, :parse_verified, []}
  # parser MFA). parse_records/1 already cross-checks recordsCount (F3);
  # this wraps it with the declared-count face so the engine's admit leg
  # gets {count, records} from a single verified pass — never a count from
  # one parse and a record list from another.
  @doc """
  Fused count+parse admission: `{:ok, count, records}` — the declared
  recordsCount cross-checked against the parsed record list in one pass.
  Typed refusals as `parse_records/1` (`:too_short`,
  `:record_count_mismatch`).
  """
  @spec parse_verified(binary()) ::
          {:ok, pos_integer(), [kafka_record()]} | {:error, :too_short | :record_count_mismatch}
  def parse_verified(batch) when is_binary(batch) do
    with {:ok, records} <- parse_records(batch),
         {:ok, declared} <- count(batch) do
      if declared == length(records) do
        {:ok, declared, records}
      else
        {:error, :record_count_mismatch}
      end
    end
  end

  defp legacy_parse(magic, rest) do
    with {:ok, rest} <- legacy_ts(magic, rest),
         {:ok, klen, rest} <- legacy_len(rest),
         {:ok, key, rest} <- legacy_take(klen, rest),
         {:ok, vlen, rest} <- legacy_len(rest),
         {:ok, value, <<>>} <- legacy_take(vlen, rest) do
      {:ok, [%{key: key, value: value}]}
    end
  end

  defp legacy_ts(1, <<_ts::signed-integer-size(64), rest::binary>>), do: {:ok, rest}
  defp legacy_ts(0, rest), do: {:ok, rest}
  defp legacy_ts(_, _), do: {:error, :too_short}

  defp legacy_len(<<n::signed-integer-size(32), rest::binary>>), do: {:ok, n, rest}
  defp legacy_len(_), do: {:error, :too_short}

  defp legacy_take(-1, rest), do: {:ok, nil, rest}

  defp legacy_take(n, bin) when n >= 0 and byte_size(bin) >= n,
    do: {:ok, binary_part(bin, 0, n), binary_part(bin, n, byte_size(bin) - n)}

  defp legacy_take(_, _), do: {:error, :too_short}

  defp parse_records_loop(bin, acc) do
    case parse_one_record(bin) do
      {:ok, rec, rest} -> parse_records_loop(rest, [rec | acc])
      _ -> Enum.reverse(acc)
    end
  end

  @doc """
  One record: length varint | attributes int8 | timestampDelta varint |
  offsetDelta varint | keyLength varint | key | valueLength varint | value |
  headers (varint count + entries). Returns {:ok, record, rest}.
  """
  @spec parse_one_record(binary()) :: {:ok, kafka_record(), binary()} | {:error, term()}
  def parse_one_record(bin) do
    with {:ok, len, rest} <- svarint(bin),
         true <- len >= 0,
         {:ok, body, rest} <- take(len, rest),
         {:ok, _attrs, body} <- take(1, body),
         {:ok, _ts_delta, body} <- svarint(body),
         {:ok, _off_delta, body} <- svarint(body),
         {:ok, key_len, body} <- svarint(body),
         {:ok, key, body} <- take_nullable(key_len, body),
         {:ok, val_len, body} <- svarint(body),
         {:ok, val, body} <- take_nullable(val_len, body),
         {:ok, hcount, body} <- svarint(body),
         true <- hcount >= 0,
         {:ok, body} <- skip_headers(body, hcount),
         true <- body == <<>> do
      {:ok, %{key: key, value: val}, rest}
    else
      _ -> {:error, :bad_record}
    end
  end

  defp skip_headers(bin, 0), do: {:ok, bin}

  defp skip_headers(bin, n) when n > 0 do
    with {:ok, klen, rest} <- svarint(bin),
         {:ok, _k, rest} <- take_nullable(klen, rest),
         {:ok, vlen, rest} <- svarint(rest),
         {:ok, _v, rest} <- take_nullable(vlen, rest) do
      skip_headers(rest, n - 1)
    end
  end

  defp skip_headers(_, _), do: {:error, :bad_headers}

  defp take(n, bin) when byte_size(bin) >= n,
    do: {:ok, binary_part(bin, 0, n), binary_part(bin, n, byte_size(bin) - n)}

  defp take(_, _), do: {:error, :truncated_record}

  defp take_nullable(len, bin) when len < 0, do: {:ok, nil, bin}
  defp take_nullable(len, bin), do: take(len, bin)

  @doc "Unsigned LEB128 varint. {:ok, value, rest} | {:error, :bad_varint}."
  @spec varint(binary()) :: {:ok, non_neg_integer(), binary()} | {:error, :bad_varint}
  def varint(bin), do: uvarint(bin, 0, 0, 1)

  @doc "Signed zigzag varint (record format v2 lengths/deltas)."
  @spec svarint(binary()) :: {:ok, integer(), binary()} | {:error, :bad_varint}
  def svarint(bin) do
    case varint(bin) do
      {:ok, u, rest} -> {:ok, bxor(u >>> 1, -band(u, 1)), rest}
      e -> e
    end
  end

  defp uvarint(<<b, rest::binary>>, acc, shift, _n) when shift < 63 and band(b, 0x80) == 0 do
    {:ok, bor(acc, b <<< shift), rest}
  end

  defp uvarint(<<b, rest::binary>>, acc, shift, n) when shift < 56 and n < 10 do
    uvarint(rest, bor(acc, band(b, 0x7F) <<< shift), shift + 7, n + 1)
  end

  defp uvarint(_, _, _, _), do: {:error, :bad_varint}

  # -- KD-174: magic-2 RecordBatch encoder ---------------------------------------
  # # KD-COVERS: KD-174 — record format v2 ENCODE face (varint lengths,
  # timestamps/offset deltas, headers, CRC32C) complementing the existing
  # read face; used by the KD-174 roundtrip court to prove the produce path
  # admits and byte-exactly re-serves broker-stamped magic-2 batches.

  @typedoc "One record to encode: nil key/value = null; headers = {k, v | nil}."
  @type encode_record :: %{key: binary() | nil, value: binary(), headers: [{binary(), binary() | nil}]}

  @doc """
  Encode records into a CRC-valid magic-2 RecordBatch (broker side is
  normally the reader; this encoder exists for the KD-174 court and any
  future broker-side batch synthesis). attributes=0 (no compression), the
  client supplies producer id/epoch/sequence faces as -1/-1/-1 (legacy
  idempotent-less producers). Returns the full batch binary (61-byte header
  + records region).
  """
  @spec encode_batch([encode_record()]) :: binary()
  def encode_batch(records) when is_list(records) and records != [] do
    ts = System.system_time(:millisecond)

    encoded =
      records
      |> Enum.with_index()
      |> Enum.map(fn {rec, i} -> encode_record(rec, i, ts) end)

    records_region = encoded |> IO.iodata_to_binary()

    # batchLength = bytes from partitionLeaderEpoch to batch end
    # = 61-byte header - 8 baseOffset - 4 batchLength + records region.
    batch_length = byte_size(records_region) + 49

    attrs = 0
    last_offset_delta = length(records) - 1

    header =
      <<0::signed-integer-size(64), batch_length::signed-integer-size(32),
        -1::signed-integer-size(32), 2::integer-size(8), 0::unsigned-integer-size(32),
        attrs::integer-size(16), last_offset_delta::integer-size(32),
        ts::signed-integer-size(64), ts::signed-integer-size(64),
        -1::signed-integer-size(64), -1::signed-integer-size(16),
        -1::signed-integer-size(32), length(records)::unsigned-integer-size(32)>>

    crc = Wire.crc32c(rest_after_crc(header, records_region))
    # Splice the CRC into bytes 17..20.
    <<pre::binary-size(17), _::binary-size(4), post::binary>> =
      IO.iodata_to_binary([header, records_region])

    <<pre::binary, crc::unsigned-integer-size(32), post::binary>>
  end

  def encode_batch(_), do: {:error, :empty_batch}

  defp rest_after_crc(header, records_region),
    do: binary_part(header, 21, byte_size(header) - 21) <> records_region

  defp encode_record(%{key: key, value: value} = rec, idx, ts) do
    headers =
      case Map.get(rec, :headers) do
        nil -> []
        hs -> hs
      end

    body =
      [
        <<0::8>>,
        svarint_bin(0),
        svarint_bin(idx)
      ] ++
        body_rest_iodata(key, value, headers)
      |> IO.iodata_to_binary()

    # record length covers attributes onward (attrs + ts + off + body
    # fields); timestamp delta, offset delta, lengths, header count are
    # ALL signed (zigzag) varints per record format v2.
    [svarint_bin(IO.iodata_length(body)), body]
  end

  defp body_rest(key, value, headers),
    do: key_part(key) <> value_part(value) <> header_parts(headers)

  defp body_rest_iodata(key, value, headers),
    do: [key_part(key), value_part(value), header_parts(headers)]

  defp key_part(nil), do: svarint_bin(-1)
  defp key_part(key), do: svarint_bin(byte_size(key)) <> key

  defp value_part(nil), do: svarint_bin(-1)
  defp value_part(value), do: svarint_bin(byte_size(value)) <> value

  defp header_parts(headers) do
    headers
    |> Enum.map(fn {hk, hv} ->
      [
        svarint_bin(byte_size(hk)),
        hk,
        svarint_bin(if(hv == nil, do: -1, else: byte_size(hv))),
        if(hv == nil, do: [], else: hv)
      ]
    end)
    |> IO.iodata_to_binary()
    |> then(fn bin ->
      IO.iodata_to_binary([svarint_bin(length(headers)), bin])
    end)
  end

  defp uvarint_bin(n) when n >= 0, do: uvarint_encode(n)
  defp uvarint_encode(n), do: do_uvarint(n, [])

  # L59 unblock (compile-freeze-class fix, disclosed in L59 receipt):
  # the acc list was PREPENDED per group then returned head-first, so any
  # varint >= 128 encoded BYTE-REVERSED (263 -> <<4, 0x8E>> not <<0x8E, 0x04>>)
  # and every record whose length needed >1 varint byte failed the broker's
  # own parse_records with :record_count_mismatch. LEB128 is little-endian:
  # reverse the accumulated groups before flattening.
  defp do_uvarint(n, acc) when n >= 0x80 do
    do_uvarint(n >>> 7, [bor(band(n, 0x7F), 0x80) | acc])
  end

  defp do_uvarint(n, acc), do: IO.iodata_to_binary(Enum.reverse([n | acc]))

  defp svarint_bin(n), do: n |> zigzag() |> uvarint_encode()

  defp zigzag(n) when n >= 0, do: n * 2
  defp zigzag(n), do: -n * 2 - 1
end
