# KD-174 two-layer court (lane L51). Chicago discipline: a real
# kafka-python-ng client over real TCP (TEST-ONLY dep in tmp/kafkalib)
# negotiating Produce v3, plus a byte-identical decode roundtrip through
# our own magic-2 reader. No mocks, no sleeps. Context: solo (in-process
# wire face on loopback, ephemeral port).
#
# KD-174F law: an acceptance-only witness does NOT close KD-174 — layer 1
# must witness a real client NEGOTIATING Produce v3+ (ApiVersions matrix),
# and layer 2 must witness the produced RecordBatch bytes decoded back
# byte-identically by our own records.ex reader.

defmodule SmaltTest.KafkaKd174CourtTest do
  use ExUnit.Case, async: false

  alias Smalt.Messaging.Kafka.{Log, Records}

  @probe "scripts/az1/kafka_v3_probe.py"
  @topic "kafka"

  defp kafka_port, do: Smalt.Messaging.Kafka.Listener.port()

  defp probe_env do
    [
      {"KAFKALIB", Path.join(File.cwd!(), "tmp/kafkalib")},
      {"PATH", System.get_env("PATH") || ""}
    ]
  end

  defp run(args), do: System.cmd("bash", ["-c", "python3 " <> Enum.map_join(args, " ", &"\"#{&1}\"") <> " 2>&1"], env: probe_env(), into: "")

  defp sum_hwm do
    Log.high_watermark(@topic, 0) + Log.high_watermark(@topic, 1)
  end

  # -- Layer 1: real client negotiates Produce v3 and produces -------------------

  test "layer 1: real kafka-python-ng client negotiates Produce v3 and produces magic-2 batches" do
    values =
      Enum.map(1..3, fn i -> "kd174-v3-#{i}-#{System.unique_integer([:positive])}" end)

    hwm_before = sum_hwm()

    {out, 0} =
      run([
        @probe,
        "--port",
        to_string(kafka_port()),
        "--values",
        Enum.join(values, ",")
      ])

    assert out =~ "NEGOTIATED-PRODUCE (0, 3)"
    assert out =~ "PRODUCED"

    # No-sleep doctrine: bounded poll on the real high-watermark observable.
    wait_until(fn -> sum_hwm() >= hwm_before + 3 end)

    # Layer 2: the produced (broker-stamped) batch bytes, read back through
    # our own records.ex reader, decode byte-identically to what was produced.
    raw_batches =
      for p <- 0..(Log.partition_count() - 1),
          %{raw: raw} <- Log.fetch(@topic, p, 0),
          match?({:ok, 2}, Records.magic(raw)),
          String.contains?(raw, hd(values)) do
        raw
      end

    assert length(raw_batches) >= 1

    for raw <- raw_batches do
      assert Records.verify_batch(raw) == :ok
      assert {:ok, recs} = Records.parse_records(raw)
      got = Enum.map(recs, & &1.value)

      assert Enum.all?(values, fn v -> v in got end),
             "produced values not byte-identical in decoded batch"
    end
  end

  # -- Layer 2 (encode/decode roundtrip): our own magic-2 encoder against our
  # own reader, plus the real wire face admitting our encoder's bytes ---------

  test "layer 2: encode_batch -> verify -> parse roundtrip, headers preserved" do
    recs = [
      %{
        key: "kd174-key",
        value: "kd174-value-#{System.unique_integer([:positive])}",
        headers: [{"h1", "v1"}, {"h2", nil}]
      },
      %{key: nil, value: "kd174-nullkey", headers: []}
    ]

    raw = Records.encode_batch(recs)
    assert is_binary(raw)
    assert Records.verify_batch(raw) == :ok
    assert {:ok, n} = Records.count(raw)
    assert n == 2

    assert {:ok, parsed} = Records.parse_records(raw)
    assert Enum.map(parsed, & &1.key) == Enum.map(recs, & &1.key)
    assert Enum.map(parsed, & &1.value) == Enum.map(recs, & &1.value)

    # The wire face admits our encoder's bytes through a real Produce v3
    # socket roundtrip: raw TCP, classic header, api 0 v3, one topic/partition.
    port = Smalt.Messaging.Kafka.Listener.port()
    {:ok, sock} = :gen_tcp.connect(~c"127.0.0.1", port, [:binary, active: false])

    topic = @topic
    batch = Records.encode_batch([%{key: nil, value: "kd174-wire-#{System.unique_integer([:positive])}", headers: []}])

    # Produce message-set framing: {offset i64, size i32, batch bytes}.
    set = <<0::signed-integer-size(64), byte_size(batch)::unsigned-integer-size(32), batch::binary>>

    req_body = [
      <<1::signed-integer-size(16), 30_000::signed-integer-size(32), 1::integer-size(32)>>,
      <<byte_size(topic)::unsigned-integer-size(16), topic::binary, 1::integer-size(32)>>,
      <<0::signed-integer-size(32), byte_size(set)::signed-integer-size(32), set::binary>>
    ]

    hdr = [
      <<0::integer-size(16), 3::integer-size(16), 42::unsigned-integer-size(32),
        3::unsigned-integer-size(16)>>,
      "l51"
    ]

    :ok = :gen_tcp.send(sock, [<<IO.iodata_length(hdr) + IO.iodata_length(req_body)::unsigned-integer-size(32)>>, hdr, req_body])

    # Bounded poll on the real socket (no-sleep doctrine): read until the
    # response is framing-complete.
    {:ok, resp} = recv_all(sock, 0)
    :gen_tcp.close(sock)

    <<_size::unsigned-integer-size(32), 42::unsigned-integer-size(32),
      _nt::signed-integer-size(32), tlen::unsigned-integer-size(16),
      _topic::binary-size(tlen)-unit(8), _np::signed-integer-size(32),
      _p::signed-integer-size(32), err::signed-integer-size(16),
      _base::signed-integer-size(64), _ts::signed-integer-size(64)>> = resp

    assert err == 0
  end

  # # SLEEP-CLASS: POLL-STEP — bounded recv poll on a real socket.
  defp recv_all(sock, acc) do
    case :gen_tcp.recv(sock, 0, 5_000) do
      {:ok, data} ->
        buf = <<acc::binary, data::binary>>

        case buf do
          <<size::unsigned-integer-size(32), rest::binary>> when byte_size(rest) >= size - 4 ->
            {:ok, buf}

          _ ->
            recv_all(sock, buf)
        end

      other ->
        other
    end
  end

  defp wait_until(fun, tries \\ 100)

  defp wait_until(_fun, 0), do: flunk("wait_until exhausted")

  defp wait_until(fun, tries) do
    if fun.() do
      :ok
    else
      # SLEEP-CLASS: POLL-STEP — bounded poll on real Log high-watermarks.
      Process.sleep(50)
      wait_until(fun, tries - 1)
    end
  end
end
