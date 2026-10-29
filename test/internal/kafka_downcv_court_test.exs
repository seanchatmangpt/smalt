# KD-181 down-conversion court (lane BK-DOWNCV). Chicago discipline: real
# binary RecordBatch frames, real wire frames over a real TCP socket to the
# real listener, real Log tables. No mocks. No sleeps (bounded polls only on
# the subprocess probe, matching the exp4 court pattern).
# Context: solo (in-process wire face on a loopback port).
#
# Close-condition legs (KD-181 row, KNOWN_DIVERGENCES.md):
#   F1: Fetch v0/v1 of a magic-2-stored partition serves down-converted
#       legacy message-set v0 frames — real-client byte-exact values.
#   F2: mixed legacy + magic-2 sets fetch correctly per-version (v0 face all
#       legacy v0; v2 face verbatim both).
#   F3: magic-2 clients on v2 fetches still get verbatim batches (no
#       regression of the byte-exact serve).
#   F4: the KD-180 legacy-count law holds (hwm +1 per legacy record; +N per
#       magic-2 batch of N records).

defmodule SmaltTest.KafkaDowncvCourtTest do
  use ExUnit.Case, async: false

  import Bitwise
  alias Smalt.Messaging.Kafka.{Log, Records, Wire}
  @topic "kafka"
  # Partition 0 is the magic-2 face of the exp4 F3 legs — the down-conversion
  # legs belong here. Partition 1 stays legacy-only: BK-KFKC's real-client
  # probe consumes it with an auto-detect (Fetch v2) consumer that must never
  # meet verbatim magic-2 bytes (the exact KD-181 divergence face).
  @part 0

  # -- F3: v2 fetch keeps the byte-exact verbatim magic-2 serve -------------------

  test "F3: Fetch v2 serves a stored magic-2 batch verbatim (no down-conversion)" do
    uniq = Base.encode16(:crypto.strong_rand_bytes(4))
    value = "DNCV" <> uniq <> String.duplicate("F", 30)
    batch = stamp_base(magic2_batch(1, [m2_record("dncv-key-" <> uniq, value)]), hwm())

    assert :ok = Records.verify_batch(batch)
    assert {:ok, base, 1} = Log.produce(@topic, @part, [batch])

    port = Smalt.Messaging.Kafka.Listener.port()

    {:ok, sock} =
      :gen_tcp.connect(~c"127.0.0.1", port, [:binary, packet: :raw, active: false], 5_000)

    fetch_body =
      <<-1::signed-32, 100::signed-32, 0::signed-32>> <>
        topics(1, @topic, [<<@part::signed-32, 0::signed-64, 1_048_576::signed-32>>])

    :ok = :gen_tcp.send(sock, req(1, 2, fetch_body))
    assert {:ok, resp} = resp(sock)

    {set, hwm_seen} = parse_fetch_v2(resp, @topic, @part)
    assert hwm_seen == base + 1

    # verbatim: the stored batch bytes appear exactly, under {base, size}
    frames = parse_message_set(set)

    assert [{^base, ^batch}] =
             Enum.filter(frames, fn {off, _raw} -> off == base end)
             |> Enum.map(fn {off, raw} -> {off, raw} end)

    :gen_tcp.close(sock)
  end

  # -- F2 (wire face): mixed set on the v0 face is all legacy v0 ------------------

  test "F2: Fetch v0 of a magic-2-stored partition down-converts to valid legacy v0 frames" do
    uniq = Base.encode16(:crypto.strong_rand_bytes(4))
    value = "DNCV" <> uniq <> String.duplicate("M", 40)
    key = "dncv-wire-" <> uniq
    batch = stamp_base(magic2_batch(1, [m2_record(key, value)]), hwm())
    assert {:ok, base, 1} = Log.produce(@topic, @part, [batch])

    port = Smalt.Messaging.Kafka.Listener.port()

    {:ok, sock} =
      :gen_tcp.connect(~c"127.0.0.1", port, [:binary, packet: :raw, active: false], 5_000)

    fetch_body =
      <<-1::signed-32, 100::signed-32, 0::signed-32>> <>
        topics(1, @topic, [<<@part::signed-32, 0::signed-64, 1_048_576::signed-32>>])

    :ok = :gen_tcp.send(sock, req(1, 0, fetch_body))
    assert {:ok, resp} = resp(sock)

    {set, hwm_seen} = parse_fetch_v2(resp, @topic, @part)
    assert hwm_seen == base + 1

    frames = parse_message_set(set)
    assert length(frames) >= 1

    ours =
      Enum.filter(frames, fn {_off, rec} ->
        match?({:ok, [%{value: ^value}]}, Records.parse_records(rec))
      end)

    assert [{off, rec}] = ours
    assert off == base

    # legacy v0 face: magic 0, CRC32 (IEEE) valid via the produce-side verifier
    <<crc::unsigned-32, 0::8, _attrs::8, _::binary>> = rec
    <<_::binary-size(4), body::binary>> = rec
    assert :erlang.crc32(body) == crc

    assert :ok = Records.verify_batch(rec)
    assert {:ok, [%{key: ^key, value: ^value}]} = Records.parse_records(rec)

    # the raw magic-2 bytes must NOT appear anywhere on the v0 face
    assert :binary.match(IO.iodata_to_binary(set), batch) == :nomatch

    :gen_tcp.close(sock)
  end

  # -- F4: count laws on the mixed partition --------------------------------------

  test "F4: KD-180 count law — legacy frame counts 1, magic-2 batch counts its records" do
    uniq = Base.encode16(:crypto.strong_rand_bytes(4))

    legacy = legacy_frame("dncv-k-" <> uniq, "DNCV" <> uniq <> "L")
    assert {:ok, 1} = Records.count(legacy)

    hwm_before = Log.high_watermark(@topic, @part)
    assert {:ok, base, 1} = Log.produce(@topic, @part, [legacy])
    assert base == hwm_before
    assert Log.high_watermark(@topic, @part) == hwm_before + 1

    two = stamp_base(magic2_batch(2, [m2_record(nil, "DNCV" <> uniq <> "A"), m2_record(nil, "DNCV" <> uniq <> "B")]), hwm())
    assert {:ok, 2} = Records.count(two)

    assert {:ok, base2, 2} = Log.produce(@topic, @part, [two])
    assert base2 == hwm_before + 1
    assert Log.high_watermark(@topic, @part) == hwm_before + 3
  end

  # -- F1: real kafka-python-ng client, api_version=(0,9) -> Fetch v0 -------------

  @tag timeout: 240_000
  test "F1 falsifier: real legacy client fetches a magic-2-stored partition byte-exact" do
    uniq = Base.encode16(:crypto.strong_rand_bytes(6))
    prefix = "DNCV" <> uniq
    m2_value = prefix <> "-m2-" <> String.duplicate("Z", 20)

    # in-matrix store of a real magic-2 batch (Produce-face-verified path)
    assert {:ok, _base, 1} =
             Log.produce(@topic, @part, [
               stamp_base(magic2_batch(1, [m2_record(nil, m2_value)]), hwm())
             ])

    port = Smalt.Messaging.Kafka.Listener.port()

    {out, exit} =
      System.cmd("python3", [
        "tmp/bkdowncv_probe.py",
        "--port",
        to_string(port),
        "--part",
        to_string(@part),
        "--prefix",
        prefix,
        "--m2value",
        m2_value
      ],
        env: [{"KAFKALIB", Path.join(File.cwd!(), "tmp/kafkalib")}, {"PATH", System.get_env("PATH") || ""}],
        into: "",
        stderr_to_stdout: true
      )

    unless exit == 0 do
      flunk("down-convert probe failed (exit #{exit}):\n#{String.slice(out, -3000, 3000)}")
    end

    assert out =~ "PASS down-convert byte-exact n=3"
  end

  # -- helpers --------------------------------------------------------------------

  defp hwm, do: Log.high_watermark(@topic, @part)

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

  defp req(api_key, api_ver, body) do
    client_id = "downcv"

    frame =
      <<api_key::signed-16, api_ver::signed-16, 0::signed-32, byte_size(client_id)::16,
        client_id::binary, body::binary>>

    <<byte_size(frame)::unsigned-32, frame::binary>>
  end

  # FetchResponse v0/v2 share the topics array shape on this face; extract the
  # message-set bytes + hwm for {topic, part}.
  defp parse_fetch_v2(resp, topic, part) do
    tlen = byte_size(topic)

    # v1/v2 prepend throttle before the topics array — scan for the topic
    # name to be layout-robust (v0 has no throttle).
    case :binary.match(resp, topic) do
      :nomatch -> flunk("topic not in fetch response")
      {pos, _} ->
        <<_::binary-size(pos), _::binary-size(^tlen)-unit(8), nparts::signed-32,
          rest2::binary>> = resp

        {blocks, _} = take_blocks(rest2, nparts, [])

        case Enum.find(blocks, fn {p, _e, _h, _s, _b} -> p == part end) do
          {^part, 0, h, _s, b} -> {b, h}
          {^part, err, _h, _s, _b} -> flunk("fetch error #{err}")
          nil -> flunk("partition block missing")
        end
    end
  end

  defp take_blocks(rest, 0, acc), do: {Enum.reverse(acc), rest}

  defp take_blocks(<<p::signed-32, err::signed-16, h::signed-64, set_size::unsigned-32,
                     b::binary-size(set_size)-unit(8), rest::binary>>, n, acc) do
    take_blocks(rest, n - 1, [{p, err, h, set_size, b} | acc])
  end

  defp parse_message_set(set), do: parse_ms(set, [])

  defp parse_ms(<<>>, acc), do: Enum.reverse(acc)

  defp parse_ms(<<off::signed-64, size::unsigned-32, frame::binary-size(size)-unit(8),
                  rest::binary>>, acc) do
    parse_ms(rest, [{off, frame} | acc])
  end

  # RecordBatch (magic 2) builder: real CRC32C over attrs..end.
  defp magic2_batch(count, records_iodata) do
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

  defp m2_record(key, value) do
    key_part =
      if key,
        do: zvarint(byte_size(key)) <> key,
        else: zvarint(-1)

    body =
      <<0>> <>
        zvarint(0) <> zvarint(0) <> key_part <> zvarint(byte_size(value)) <> value <> <<0>>

    zvarint(byte_size(body)) <> body
  end

  defp zvarint(n), do: do_varint(:erlang.bxor(n <<< 1, n >>> 63), [])

  defp do_varint(n, acc) when n >= 0x80, do: do_varint(n >>> 7, [acc | [0x80 + band_by(n, 0x7F)]])
  defp do_varint(n, acc), do: IO.iodata_to_binary([acc | [n]])

  defp band_by(n, m), do: :erlang.band(n, m)

  # Broker base-offset patch (bytes 0..7, outside CRC and batchLength).
  defp stamp_base(<<_::binary-size(8), rest::binary>>, base),
    do: <<base::signed-integer-size(64), rest::binary>>

  # Legacy magic-0 frame: crc u32 | magic 0 | attrs 0 | keyLen | key |
  # valueLen | value. IEEE CRC32 over post-CRC bytes.
  defp legacy_frame(key, value) do
    key_part = if key, do: <<byte_size(key)::signed-32, key::binary>>, else: <<-1::signed-32>>
    body = <<0::8>> <> key_part <> <<byte_size(value)::signed-32, value::binary>>
    <<:erlang.crc32(<<0::8, body::binary>>)::unsigned-32, 0::8, body::binary>>
  end
end
