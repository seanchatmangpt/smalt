# EXPL-4 repair court (lane KAFKA-EXP4). Chicago discipline: real binary
# RecordBatch frames, real wire frames over a real TCP socket to the real
# listener, real Log tables + real EH store. No mocks. No sleeps.
# Context: solo (in-process wire face on a loopback port).
#
# F3: a CRC-valid batch whose header recordsCount disagrees with the parsed
#     record list must be refused typed — never stored with count 2 and
#     fanned out with 1 record (the witnessed watermark-past-undelivered face).
# F4: reads of unknown {topic, partition}
#     answer error 3 (UNKNOWN_TOPIC_OR_PARTITION); the partition index is
#     bounded by partition_count() at the wire face for produce AND reads.

defmodule SmaltTest.KafkaExp4CourtTest do
  use ExUnit.Case, async: false

  import Bitwise
  alias Smalt.Messaging.Kafka.{Log, Records, Wire}
  @topic "kafka"
  # BK-KFKC legs run on the top partition — partition 0 is the shared face
  # of the F3 legs and the real-client wire probes; keep BK-KFKC traffic off
  # it entirely.
  @kfkc_part Smalt.Messaging.Kafka.Log.partition_count() - 1

  # -- F3 -----------------------------------------------------------------------

  test "F3 falsifier: CRC-valid batch, recordsCount=2, malformed tail must not store or fan out" do
    valid_rec = record("exp4-f3-dropped")
    batch = batch(2, valid_rec <> <<0xFF>>)

    hwm_before = Log.high_watermark(@topic, 0)
    # BK-KFKC: ExUnit shuffles test order — the original leg asserted
    # fetch(hwm) == [] (true only on a virgin partition 0). Order-robust
    # form: nothing NEW is stored — the visible fetch set is unchanged.
    stored_before = Log.fetch(@topic, 0, 0)

    assert {:error, :record_count_mismatch} = Records.parse_records(batch)
    assert {:error, :record_count_mismatch} = Log.produce(@topic, 0, [batch])
    assert Log.high_watermark(@topic, 0) == hwm_before
    assert Log.fetch(@topic, 0, 0) == stored_before
  end

  test "F3 non-vacuity: well-formed 2-record batch parses to 2, stores, fans out both" do
    v1 = "exp4-f3-ok-1-#{System.unique_integer([:positive])}"
    v2 = "exp4-f3-ok-2-#{System.unique_integer([:positive])}"
    hwm_before = Log.high_watermark(@topic, 0)
    # BK-KFKC: shuffle-robust — stamp the expected base offset into the built
    # batch (bytes 0..7 lie outside the CRC and batchLength coverage), so the
    # byte-exact fetch-back assert holds regardless of who produced before.
    batch = stamp_base(batch(2, [record(v1), record(v2)]), hwm_before)

    assert :ok = Records.verify_batch(batch)
    assert {:ok, [%{value: ^v1}, %{value: ^v2}]} = Records.parse_records(batch)

    assert {:ok, base, 2} = Log.produce(@topic, 0, [batch])
    assert base == hwm_before

    assert [%{base_offset: ^base, count: 2, raw: rawn}] = Log.fetch(@topic, 0, base)
    assert rawn == batch

    events = Smalt.Messaging.EventHubs.receive_events("#{@topic}/partitions/0", 0, 10_000)
    bodies = Enum.map(events, & &1["body"])
    assert v1 in bodies and v2 in bodies
  end

  test "F3 builder non-vacuity: single-record batch parses to its declared count" do
    batch = batch(1, record("exp4-single"))

    assert :ok = Records.verify_batch(batch)
    assert {:ok, [%{value: "exp4-single"}]} = Records.parse_records(batch)
  end

  # -- F4 -----------------------------------------------------------------------

  test "F4: partition_known? bounds the index by partition_count() and topic knowledge" do
    assert Log.partition_known?(@topic, 0)
    assert Log.partition_known?(@topic, Log.partition_count() - 1)
    refute Log.partition_known?(@topic, Log.partition_count())
    refute Log.partition_known?(@topic, 99)
    refute Log.partition_known?("exp4-unknown-topic", 0)
    refute Log.partition_known?(123, 0)
    refute Log.partition_known?(@topic, -1)
  end

  test "F4 wire: unknown partition reads answer error 3 on the real wire, known answers 0" do
    port = Smalt.Messaging.Kafka.Listener.port()

    {:ok, sock} =
      :gen_tcp.connect(~c"127.0.0.1", port, [:binary, packet: :raw, active: false], 5_000)

    lo_body =
      <<0::signed-32>> <>
        topics(1, @topic, [
          <<9::signed-32, -1::signed-64, 1::signed-32>>,
          <<0::signed-32, -1::signed-64, 1::signed-32>>
        ])

    :ok = :gen_tcp.send(sock, req(2, 0, lo_body))
    assert {:ok, resp} = resp(sock)

    # ListOffsets v0 block: partition i32 | error_code i16 | ts i32 | offset i64
    <<_corr::signed-32, 1::signed-32, tlen::16, topic_echo::binary-size(tlen)-unit(8),
      2::signed-32, _p9::signed-32, err_p9::signed-16, _::binary-size(12),
      _p0::signed-32, err_p0::signed-16, _::binary>> = resp

    assert topic_echo == @topic

    assert err_p9 == Wire.error_code(:unknown_topic_or_partition)
    assert err_p0 == 0
    :gen_tcp.close(sock)
  end

  test "F4 wire: produce to an unserved partition answers error 3, nothing stored" do
    port = Smalt.Messaging.Kafka.Listener.port()

    {:ok, sock} =
      :gen_tcp.connect(~c"127.0.0.1", port, [:binary, packet: :raw, active: false], 5_000)

    hwm_before = Log.high_watermark(@topic, Log.partition_count() - 1)

    b = batch(1, record("exp4-p9"))
    ms = <<0::signed-64, byte_size(b)::unsigned-32, b::binary>>

    # parse_produce reads acks+timeout, then the topics ARRAY — topics/3
    # already emits the array count, so no extra count field here.
    p_body =
      <<-1::signed-16, 100::signed-32>> <>
        topics(1, @topic, [<<9::signed-32, byte_size(ms)::unsigned-32, ms::binary>>])

    :ok = :gen_tcp.send(sock, req(0, 0, p_body))
    assert {:ok, resp} = resp(sock)

    <<_corr::signed-32, 1::signed-32, tlen::16, topic_echo::binary-size(tlen)-unit(8),
      1::signed-32, _p::signed-32, err::signed-16, _off::signed-64, _::binary>> = resp

    assert topic_echo == @topic

    assert err == Wire.error_code(:unknown_topic_or_partition)
    assert Log.high_watermark(@topic, Log.partition_count() - 1) == hwm_before
    :gen_tcp.close(sock)
  end

  # -- BK-KFKC: legacy magic-0/1 count face -------------------------------------

  test "BK-KFKC falsifier: 60-byte-value legacy frame counts 1, hwm advances by 1 (not 0x42424242)" do
    value = :binary.copy("B", 60)
    frame = legacy_frame(0, "kfkc-key", value)

    assert byte_size(frame) >= 61
    # The witnessed defect: bytes 57..60 of this frame are 0x42424242.
    assert {:ok, 1} = Records.count(frame)

    hwm_before = Log.high_watermark(@topic, @kfkc_part)
    assert {:ok, base, 1} = Log.produce(@topic, @kfkc_part, [frame])
    assert base == hwm_before
    assert Log.high_watermark(@topic, @kfkc_part) == hwm_before + 1

    assert [%{base_offset: ^base, count: 1, raw: rawn}] = Log.fetch(@topic, @kfkc_part, base)
    assert {:ok, [%{key: "kfkc-key", value: ^value}]} = Records.parse_records(strip_wrapper(rawn))
  end

  test "BK-KFKC: corrupt legacy frame refuses typed, hwm unchanged" do
    # valueLen claims 100 bytes, frame ends early — parse must refuse typed,
    # and the lying byte at 57..60 must never become a count.
    value = :binary.copy("C", 60)
    body = <<0::8, "kfkc-bad"::binary, 100::signed-32, value::binary>>
    crc = :erlang.crc32(<<0::8>> <> <<0::8>> <> body)
    frame = <<crc::unsigned-32, 0::8, 0::8, body::binary>>

    assert :ok = Records.verify_batch(frame)
    assert {:error, :too_short} = Records.parse_records(frame)

    hwm_before = Log.high_watermark(@topic, @kfkc_part)
    assert {:error, :too_short} = Log.produce(@topic, @kfkc_part, [frame])
    assert Log.high_watermark(@topic, @kfkc_part) == hwm_before
  end

  test "BK-KFKC: legacy magic-1 frame counts and parses 1, F3 cross-check fires on legacy face" do
    frame = legacy_frame(1, nil, "kfkc-magic1-value")

    assert {:ok, 1} = Records.count(frame)
    assert {:ok, [%{key: nil, value: "kfkc-magic1-value"}]} = Records.parse_records(frame)

    hwm_before = Log.high_watermark(@topic, @kfkc_part)
    assert {:ok, _base, 1} = Log.produce(@topic, @kfkc_part, [frame])
    assert Log.high_watermark(@topic, @kfkc_part) == hwm_before + 1
  end

  @tag timeout: 240_000
  test "BK-KFKC real-client probe: 60-byte kafka-python-ng produce advances hwm by 1, consume byte-exact" do
    port = Smalt.Messaging.Kafka.Listener.port()

    # BK-B7CR (fixes BK-WIT3R item 5): per-run unique prefix. The consume probe
    # reads partition 1 from the beginning and filters by prefix; a FIXED value
    # ("KKKK…") made retries state-dependent — a timed-out first consume left a
    # straggler record that every retry also matched, so n=1 could never hold
    # again. A unique prefix scopes each run to exactly its own record even on
    # a shared/log-replayed partition; value stays 60 bytes (legacy-face pin).
    uniq = Base.encode16(:crypto.strong_rand_bytes(6))
    prefix = "K" <> uniq
    value = prefix <> String.duplicate("K", 60 - byte_size(prefix))

    hwm_before = Log.high_watermark(@topic, 0) + Log.high_watermark(@topic, 1)

    env = [{"KAFKALIB", Path.join(File.cwd!(), "tmp/kafkalib")}]

    {out, 0} =
      System.cmd("python3", [probe_path(), "--port", to_string(port), "--mode", "produce",
                             "--value", value], env: env, into: "")

    assert out =~ "PRODUCED"

    hwm_after = Log.high_watermark(@topic, 0) + Log.high_watermark(@topic, 1)
    assert hwm_after == hwm_before + 1,
           "hwm advanced by #{hwm_after - hwm_before}, expected 1 (the 0x42424242 defect face)"

    # Bounded poll on a real observable (no-sleep doctrine): under heavy
    # machine load the probe's 20s consumer timeout can exhaust before the
    # fetch — retry the consume probe, never a fixed settle delay.
    assert consume_probe_passes?(port, value, prefix),
           "consume probe never returned PASS within 4 bounded tries"
  end

  defp consume_probe_passes?(port, value, prefix, tries \\ 4)

  defp consume_probe_passes?(_port, _value, _prefix, 0), do: false

  defp consume_probe_passes?(port, value, prefix, tries) do
    {out, _exit} =
      System.cmd("python3", [probe_path(), "--port", to_string(port), "--mode", "consume",
                             "--value", value, "--filter-prefix", prefix],
                 env: [{"KAFKALIB", Path.join(File.cwd!(), "tmp/kafkalib")}],
                 into: "", stderr_to_stdout: true)

    if out =~ "PASS consume byte-exact n=1" do
      true
    else
      File.write!("/tmp/kfkc_probe_fail.txt",
        "try #{5 - tries}: #{String.slice(out, -400, 400)}\n", [:append])

      consume_probe_passes?(port, value, prefix, tries - 1)
    end
  end

  defp probe_path, do: Path.join(File.cwd!(), "tmp/bkkfkc_probe.py")

  # -- helpers --------------------------------------------------------------------

  defp resp(sock) do
    case :gen_tcp.recv(sock, 0, 5_000) do
      {:ok, <<len::unsigned-32, resp::binary-size(len)-unit(8)>>} -> {:ok, resp}
      other -> other
    end
  end

  defp topics(n, topic, parts) do
    tlen = byte_size(topic)

    <<n::signed-32, tlen::16, topic::binary, length(parts)::signed-32,
      IO.iodata_to_binary(parts)::binary>>
  end

  # Wire requests are size-prefixed (int32) — the conn reads size first.
  defp req(api_key, api_ver, body) do
    client_id = "exp4"

    frame =
      <<api_key::signed-16, api_ver::signed-16, 0::signed-32, byte_size(client_id)::16,
        client_id::binary, body::binary>>

    <<byte_size(frame)::unsigned-32, frame::binary>>
  end

  # RecordBatch (magic 2) builder: real CRC32C over attrs..end.
  defp batch(count, records_iodata) do
    records = IO.iodata_to_binary(records_iodata)

    attrs_to_count = <<
      0::signed-16,
      0::signed-32,
      0::signed-64,
      0::signed-64,
      0::signed-64,
      0::signed-16,
      0::signed-32,
      count::signed-32
    >>

    crc = Wire.crc32c(attrs_to_count <> records)
    batch_length = 61 - 12 + byte_size(records)

    <<0::signed-64, batch_length::signed-32, 0::signed-32, 2::8, crc::unsigned-32>> <>
      attrs_to_count <> records
  end

  # All record lengths/deltas are SIGNED (zigzag) varints per record format
  # v2 — keyLen -1 encodes as 1, valueLen 9 encodes as 18. Encoding these as
  # plain unsigned LEB128 is the mis-encoding that parses as garbage.
  defp record(value) do
    body =
      <<0>> <>
        zvarint(0) <> zvarint(0) <> zvarint(-1) <> zvarint(byte_size(value)) <> value <> <<0>>

    zvarint(byte_size(body)) <> body
  end

  defp zvarint(n), do: do_varint(:erlang.bxor(n <<< 1, n >>> 63), [])

  defp do_varint(n, acc) when n >= 0x80, do: do_varint(n >>> 7, [acc | [0x80 + band_by(n, 0x7F)]])
  defp do_varint(n, acc), do: IO.iodata_to_binary([acc | [n]])

  defp band_by(n, m), do: :erlang.band(n, m)

  # Broker base-offset patch, mirroring Log.stamp_base_offset/2 (bytes 0..7
  # of a magic-2 batch are the baseOffset field, outside both CRC coverage
  # and batchLength) — lets the byte-exact fetch-back leg be order-robust.
  defp stamp_base(<<_::binary-size(8), rest::binary>>, base),
    do: <<base::signed-integer-size(64), rest::binary>>

  # Legacy magic-0/1 frame: crc u32 | magic i8 | attrs i8 [| ts i64] |
  # keyLen i32 | key | valueLen i32 | value. IEEE CRC32 over post-CRC bytes.
  defp legacy_frame(magic, key, value) do
    ts = if magic == 1, do: <<0::signed-64>>, else: <<>>
    key_part = if key, do: <<byte_size(key)::signed-32, key::binary>>, else: <<-1::signed-32>>

    body =
      <<0::8>> <> ts <> key_part <> <<byte_size(value)::signed-32, value::binary>>

    <<:erlang.crc32(<<magic::8>> <> body)::unsigned-32, magic::8, body::binary>>
  end

  # Stored legacy frames keep the {offset i64, size i32} wrapper.
  defp strip_wrapper(<<_::binary-size(12), frame::binary>>), do: frame
end
