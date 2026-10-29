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
  Parse the Produce message-set framing: repeated
  {int64 offset, int32 size, batch bytes}. Returns `{:ok, [batch_binary]}`
  (wrapper stripped, raw batch bytes kept verbatim for byte-exact re-serving)
  or `{:error, reason}`. CRC/magic verification is `verify_batch/1`'s
  fail-closed job, not this parser's.
  """
  @spec parse_message_set(binary()) :: {:ok, [binary()]} | {:error, term()}
  def parse_message_set(bin) when is_binary(bin), do: parse_ms(bin, [])

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
end
