# AZ-1 — Kafka wire face court. Chicago discipline: real kafka-python-ng
# client over real TCP (TEST-ONLY dep in tmp/kafkalib), real listener on a
# real loopback port, real JournalSink segments on disk, real EH store.
# No mocks. Context: solo (in-process wire faces on loopback).
#
# Probe scripts: scripts/az1/kafka_probe.py, scripts/az1/kafka_negative_probe.py

defmodule SmaltTest.KafkaWireTest do
  use ExUnit.Case, async: false

  @probe "scripts/az1/kafka_probe.py"
  @negative "scripts/az1/kafka_negative_probe.py"
  @topic "kafka"

  defp kafka_port, do: Smalt.Messaging.Kafka.Listener.port()

  defp probe_env do
    [
      {"KAFKALIB", Path.join(File.cwd!(), "tmp/kafkalib")},
      {"PATH", System.get_env("PATH") || ""}
    ]
  end

  defp run(args), do: System.cmd("python3", args, env: probe_env(), into: "")

  # Bounded poll on a real observable (no-sleep doctrine):
  # # SLEEP-CLASS: POLL-STEP
  defp wait_until(fun, tries \\ 100)

  defp wait_until(_fun, 0), do: flunk("wait_until exhausted")

  defp wait_until(fun, tries) do
    if fun.() do
      :ok
    else
      # SLEEP-CLASS: POLL-STEP — bounded wait_until/2 poll (100 tries cap) on
      # real Kafka Log high-watermark observables, never a fixed settle delay.
      Process.sleep(50)
      wait_until(fun, tries - 1)
    end
  end

  defp sum_hwm do
    Smalt.Messaging.Kafka.Log.high_watermark(@topic, 0) +
      Smalt.Messaging.Kafka.Log.high_watermark(@topic, 1)
  end

  test "CRC32C check vector" do
    assert Smalt.Messaging.Kafka.Wire.crc32c("123456789") == 0xE306_9283
  end

  test "produce 5 through the sieve; consume back byte-exact; EH fan-out visible" do
    port = kafka_port()
    values = Enum.map(1..5, fn i -> "az1-msg-#{i}-#{System.unique_integer([:positive])}" end)
    vs = Enum.join(values, ",")

    {out, 0} =
      run([@probe, "--port", to_string(port), "--mode", "produce", "--values", vs])

    assert out =~ "PRODUCED"

    {out, 0} =
      run([
        @probe,
        "--port",
        to_string(port),
        "--mode",
        "consume",
        "--values",
        vs,
        "--filter-prefix",
        "az1-msg-"
      ])

    assert out =~ "PASS consume byte-exact n=5"

    eh0 = Smalt.Messaging.EventHubs.receive_events("#{@topic}/partitions/0", 0, 1000)
    eh1 = Smalt.Messaging.EventHubs.receive_events("#{@topic}/partitions/1", 0, 1000)
    assert MapSet.new(values) |> MapSet.subset?(MapSet.new(Enum.map(eh0 ++ eh1, & &1["body"])))
  end

  test "sieve refusal -> client raises, nothing stored" do
    hwm0 = sum_hwm()
    refused = "refuse-me-#{System.unique_integer([:positive])}"

    Application.put_env(:smalt, :kafka_guard, {
      :fun,
      fn payload ->
        if is_binary(payload) and payload =~ "refuse-me" do
          reason = "law-says-no"
          {:andon, <<1::8, byte_size(reason)::16, reason::binary>>}
        else
          {:admit, <<0::8>>}
        end
      end
    })

    {out, code} =
      run([@probe, "--port", to_string(kafka_port()), "--mode", "produce", "--values", refused])

    assert code != 0, "expected client raise on POLICY_VIOLATION, got: #{out}"
    assert sum_hwm() == hwm0
  after
    Application.delete_env(:smalt, :kafka_guard)
  end

  test "crash-only: bad CRC + Produce v9 kill the connection" do
    {out, 0} = run([@negative, to_string(kafka_port())])
    assert out =~ "SUMMARY: 2/2 PASS"
  end

  test "seal + Log restart: sealed replay restores byte-exact fetch-back" do
    port = kafka_port()
    value = "az1-replay-#{System.unique_integer([:positive])}"

    {out, 0} =
      run([@probe, "--port", to_string(port), "--mode", "produce", "--values", value])

    assert out =~ "PRODUCED"

    hwm_before = sum_hwm()

    assert %{"frames" => _} = Smalt.Storage.JournalSink.seal(Smalt.Messaging.Kafka.Sink)

    pid = Process.whereis(Smalt.Messaging.Kafka.Log)
    Process.exit(pid, :kill)

    wait_until(fn ->
      Process.whereis(Smalt.Messaging.Kafka.Log) != nil and sum_hwm() >= hwm_before
    end)

    {out, 0} =
      run([
        @probe,
        "--port",
        to_string(port),
        "--mode",
        "consume",
        "--values",
        value,
        "--filter-prefix",
        "az1-replay-"
      ])

    assert out =~ "PASS consume byte-exact"
  end

  # -- EXPL-4 repair courts (expl4r-wirefront-repairs) ---------------------------

  # F3 falsifier: a CRC-valid batch declaring recordsCount=2 with one valid
  # record + a malformed tail must NOT parse as {:ok, [1 record]} (the
  # witnessed silent tail-drop) — typed :record_count_mismatch, and
  # Log.produce refuses (nothing stored, hwm unchanged).
  test "F3: recordsCount mismatch is typed, never a silent tail drop" do
    alias Smalt.Messaging.Kafka.{Log, Records}

    valid_rec = expl4_record("expl4-f3")
    batch = expl4_batch(2, valid_rec <> <<0xFF>>)

    hwm_before = Log.high_watermark("kafka", 0)

    assert {:error, :record_count_mismatch} = Records.parse_records(batch)
    assert {:error, :record_count_mismatch} = Log.produce("kafka", 0, [batch])
    assert Log.high_watermark("kafka", 0) == hwm_before
  end

  # F3 happy path: the builder produces a WELL-FORMED single-record batch
  # that verifies and parses to exactly one record (builder non-vacuity).
  test "F3 builder non-vacuity: well-formed batch parses to its declared count" do
    alias Smalt.Messaging.Kafka.Records

    batch = expl4_batch(1, expl4_record("expl4-f3-ok"))

    assert :ok = Records.verify_batch(batch)
    assert {:ok, [%{value: "expl4-f3-ok"}]} = Records.parse_records(batch)
  end

  # F4 falsifier: ListOffsets v0 / Fetch v0 on an unknown {topic, partition}
  # answer error 3 (UNKNOWN_TOPIC_OR_PARTITION), never an empty success.
  test "F4: unknown topic/partition reads answer error 3 on the real wire" do
    alias Smalt.Messaging.Kafka.Listener

    port = Listener.port()

    {:ok, sock} =
      :gen_tcp.connect(~c"127.0.0.1", port, [:binary, packet: :raw, active: false], 5_000)

    # ListOffsets v0, partition 9 of the default topic (unserved index).
    lo_body =
      <<0::signed-32>> <>
        lo_topics(1, "kafka", [<<9::signed-32, -1::signed-64, 1::signed-32>>])

    :ok = :gen_tcp.send(sock, expl4_req(2, 0, lo_body))

    # Fetch v0, unknown topic entirely.
    fetch_body =
      <<0::signed-32, 100::signed-32, 1::signed-32>> <>
        lo_topics(1, "expl4-nope-topic", [<<0::signed-32, 0::signed-64, 1_048_576::signed-32>>])

    :ok = :gen_tcp.send(sock, expl4_req(1, 0, fetch_body))

    assert {:ok, resp} = recv_resp(sock)
    # response: corr(4) topics(4) tlen(2) "kafka" parts(4) part(4) err(2)...
    <<_corr::signed-32, 1::signed-32, 5::16, "kafka", 1::signed-32, _p::signed-32,
      err_lo::signed-16, _::binary>> = resp

    assert err_lo == 3

    assert {:ok, resp2} = recv_resp(sock)

    <<_corr2::signed-32, 1::signed-32, 16::16, "expl4-nope-topic", 1::signed-32, _pf::signed-32,
      err_ft::signed-16, _::binary>> = resp2

    assert err_ft == 3
    :gen_tcp.close(sock)
  end

  # Known-partition reads still answer error 0 (builder/wire non-vacuity).
  test "F4 non-vacuity: known partition ListOffsets still succeeds" do
    alias Smalt.Messaging.Kafka.Listener

    port = Listener.port()

    {:ok, sock} =
      :gen_tcp.connect(~c"127.0.0.1", port, [:binary, packet: :raw, active: false], 5_000)

    lo_body = <<0::signed-32>> <> lo_topics(1, "kafka", [<<0::signed-32, -1::signed-64, 1::signed-32>>])
    :ok = :gen_tcp.send(sock, expl4_req(2, 0, lo_body))

    assert {:ok, resp} = recv_resp(sock)

    <<_::signed-32, 1::signed-32, 5::16, "kafka", 1::signed-32, _p::signed-32, 0::signed-16,
      _::binary>> = resp

    :gen_tcp.close(sock)
  end

  # -- EXPL-4 helpers ------------------------------------------------------------

  defp expl4_req(api_key, api_ver, body) do
    client_id = "expl4r"
    cid_size = byte_size(client_id)

    header_body =
      <<api_key::signed-16, api_ver::signed-16, 0::signed-32, cid_size::16, client_id::binary,
        body::binary>>

    # Kafka wire framing: every request carries the 4-byte size prefix.
    <<byte_size(header_body)::unsigned-32>> <> header_body
  end

  defp lo_topics(n, topic, parts) do
    tlen = byte_size(topic)

    <<n::signed-32, tlen::16, topic::binary, length(parts)::signed-32,
      IO.iodata_to_binary(parts)::binary>>
  end

  # Size-prefixed reader with a real buffer: a recv can return two
  # concatenated responses or a partial frame — accumulate until the frame
  # is complete; the leftover after one frame is stashed per socket (the
  # next recv_resp call resumes from it).
  defp recv_resp(sock) do
    buf = Process.get({:resp_buf, sock}) || <<>>

    case parse_frame(buf) do
      {:ok, resp, rest} ->
        Process.put({:resp_buf, sock}, rest)
        {:ok, resp}

      :partial ->
        case :gen_tcp.recv(sock, 0, 5_000) do
          {:ok, data} ->
            Process.put({:resp_buf, sock}, buf <> data)
            recv_resp(sock)

          other ->
            other
        end

      :bad ->
        {:error, :bad_frame}
    end
  end

  defp parse_frame(<<len::unsigned-32, resp::binary-size(len)-unit(8), rest::binary>>),
    do: {:ok, resp, rest}

  defp parse_frame(_), do: :partial

  @doc false
  def expl4_batch(count, records_iodata) do
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

    crc = Smalt.Messaging.Kafka.Wire.crc32c(attrs_to_count <> records)
    batch_length = 61 - 12 + byte_size(records)

    <<
      0::signed-64, batch_length::signed-32, 0::signed-32, 2::8, crc::unsigned-32
    >> <> attrs_to_count <> records
  end

  @doc false
  def expl4_record(value) do
    # attrs(1) tsDelta svarint(0) offDelta svarint(0) keyLen svarint(-1)
    # valueLen svarint(len) value headers svarint(0) — record format v2
    # length/delta fields are SIGNED varints (zigzag LEB128), matching the
    # parser and the real kafka-python client.
    body =
      <<0>> <>
        expl4_varint(0) <> expl4_varint(0) <> expl4_varint(-1) <>
        expl4_varint(byte_size(value)) <> value <> <<0>>

    expl4_varint(byte_size(body)) <> body
  end

  # Zigzag encode (u = (n << 1) ^ (n >> 63)) then unsigned LEB128 — record
  # format v2 signed-varint face, exactly what Records.svarint/1 decodes.
  defp expl4_varint(n) do
    import Bitwise
    u = bxor(bsl(n, 1), bsr(n, 63))
    do_expl4_uvarint(u, [])
  end

  defp do_expl4_uvarint(n, acc) when n >= 0x80,
    do: do_expl4_uvarint(div(n, 128), [acc | [0x80 + rem(n, 128)]])

  defp do_expl4_uvarint(n, acc), do: IO.iodata_to_binary([acc | [n]])
end
