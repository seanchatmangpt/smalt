# v26.11.6 L6 — cross-face read-your-write court: an AoQ append must be
# readable on the Kafka wire face. Chicago discipline: real AoQ Storage
# append, real Kafka fetch projection, real TCP ListOffsets v0 + Fetch v0
# over the real listener, real CRC verify of the served frame. No mocks.
# Real wire court (:wire class). Context: solo (in-process wire faces on
# loopback).
defmodule SmaltTest.Internal.CrossFaceRywCourtTest do
  use ExUnit.Case, async: false

  @topic Smalt.Aoq.Storage.topic()
  @frame_type 0
  @server Smalt.Aoq.Storage.Server

  # -- isolation: snapshot/restore the AoQ topic rows on the SHARED tables --

  defp snapshot do
    batches =
      :ets.tab2list(:smalt_kafka_batches)
      |> Enum.filter(fn {{t, _p, _b}, _} -> t == @topic end)

    next =
      :ets.tab2list(:smalt_kafka_next)
      |> Enum.filter(fn {{t, _p}, _} -> t == @topic end)

    {batches, next}
  end

  defp restore({batches, next}) do
    Enum.each(batches, fn {k, _} -> :ets.delete(:smalt_kafka_batches, k) end)

    kept = Enum.map(next, fn {k, _} -> k end)

    Enum.each(:ets.tab2list(:smalt_kafka_next), fn {k, _} = kv ->
      if k in kept do
        :ets.insert(:smalt_kafka_next, kv)
      else
        case k do
          {t, _p} when t == @topic -> :ets.delete(:smalt_kafka_next, k)
          _ -> :ok
        end
      end
    end)
  end

  setup do
    Smalt.Messaging.PartitionLog.ensure_tables(
      batches: :smalt_kafka_batches,
      next: :smalt_kafka_next
    )

    snap = snapshot()
    on_exit(fn -> restore(snap) end)
    :ok
  end

  # -- the read-your-write law ----------------------------------------------------

  test "AoQ append is read-your-write visible on the Kafka wire face" do
    payload = "aoq-kafka-ryw-" <> Integer.to_string(System.unique_integer([:positive]))

    pid0 = :ets.whereis(:smalt_kafka_batches)
    server0 = Process.whereis(@server)

    # 1. AoQ face append (bare store law: nothing wrapped at store time)
    assert {:ok, _off} = Smalt.Aoq.Storage.append(@frame_type, payload)

    # 2. AoQ face read-back byte-exact (bare payload)
    assert {:ok, entries} = Smalt.Aoq.Storage.fetch(@topic, 0)
    assert payload in Enum.map(entries, & &1.payload)

    # 3. Kafka face projection: the serve-time framing law builds the
    # minimal legal legacy frame; conn.ex serve_batch's legacy clause then
    # serves it verbatim (down-conversion never triggers — already magic-0).
    assert Smalt.Messaging.Kafka.Log.partition_known?(@topic, @frame_type)
    assert [%{base_offset: _base, count: 1, raw: framed}] =
             Smalt.Messaging.Kafka.Log.fetch(@topic, @frame_type, 0)

    {_off_proj, frame_proj} = parse_message_set(framed)

    <<_crc_p::unsigned-integer-size(32), 0::8, 0::8, -1::signed-32, vlen_p::signed-32,
      value_p::binary-size(vlen_p)-unit(8), _restp::binary>> = frame_proj

    assert value_p == payload, "kafka-face projection payload not byte-exact"

    # 4. Real wire: ListOffsets v0 sees the hwm; Fetch v0 returns the frame
    port = Smalt.Messaging.Kafka.Listener.port()

    {:ok, sock} =
      :gen_tcp.connect(~c"127.0.0.1", port, [:binary, packet: :raw, active: false], 5_000)

    lo_body =
      <<0::signed-32>> <>
        lo_topics(1, @topic, [<<@frame_type::signed-32, -1::signed-64, 1::signed-32>>])

    :ok = :gen_tcp.send(sock, req(2, 0, lo_body))
    assert {:ok, resp} = recv_resp(sock)

    <<_corr::signed-32, 1::signed-32, tlen::16, _t::binary-size(tlen)-unit(8), 1::signed-32,
      _p::signed-32, err_lo::signed-16, _::binary>> = resp

    assert err_lo == 0

    fetch_body =
      <<0::signed-32, 100::signed-32, 1::signed-32>> <>
        lo_topics(1, @topic, [<<@frame_type::signed-32, 0::signed-64, 1_048_576::signed-32>>])

    :ok = :gen_tcp.send(sock, req(1, 0, fetch_body))
    assert {:ok, resp2} = recv_resp(sock)

    <<_corr2::signed-32, 1::signed-32, tlen2::16, _t2::binary-size(tlen2)-unit(8), 1::signed-32,
      _p2::signed-32, err_f::signed-16, hwm::signed-64, set_size::unsigned-32,
      message_set::binary-size(set_size)-unit(8), _::binary>> = resp2

    assert err_f == 0
    assert hwm >= 1
    assert set_size > 0

    # 5. The served message-set frame parses; the inner value is the AoQ
    # payload BYTE-EXACT; the frame verifies under the legacy CRC face.
    {offset, frame} = parse_message_set(message_set)
    assert offset >= 0

    <<crc::unsigned-integer-size(32), 0::8, 0::8, -1::signed-32, vlen::signed-32,
      value::binary-size(vlen)-unit(8), _rest::binary>> = frame

    assert value == payload, "cross-face serve payload not byte-exact"

    crc_body = :binary.part(frame, 4, byte_size(frame) - 4)
    assert :erlang.crc32(crc_body) == crc, "served frame fails the legacy CRC face"

    # 6. Split-instance mutation guard: the SAME ets table identity pre/post,
    # and the AoQ server did not restart (one shared instance, isolation by
    # topic — never a second table or a face-split process).
    assert :ets.whereis(:smalt_kafka_batches) == pid0
    assert Process.whereis(@server) == server0

    :gen_tcp.close(sock)
  end

  # -- helpers ----------------------------------------------------------------------

  defp req(api_key, api_ver, body) do
    client_id = "ryw"
    cid_size = byte_size(client_id)

    header_body =
      <<api_key::signed-16, api_ver::signed-16, 0::signed-32, cid_size::16, client_id::binary,
        body::binary>>

    <<byte_size(header_body)::unsigned-32>> <> header_body
  end

  defp lo_topics(n, topic, parts) do
    tlen = byte_size(topic)

    <<n::signed-32, tlen::16, topic::binary, length(parts)::signed-32,
      IO.iodata_to_binary(parts)::binary>>
  end

  # Size-prefixed Kafka response reader with a real buffer (a recv can
  # return two concatenated responses or a partial frame — accumulate).
  defp recv_resp(sock) do
    buf = Process.get({:ryw_buf, sock}) || <<>>

    case read_frame(buf) do
      {:ok, resp, rest} ->
        Process.put({:ryw_buf, sock}, rest)
        {:ok, resp}

      :partial ->
        case :gen_tcp.recv(sock, 0, 5_000) do
          {:ok, data} ->
            Process.put({:ryw_buf, sock}, buf <> data)
            recv_resp(sock)

          other ->
            other
        end
    end
  end

  defp read_frame(<<len::unsigned-32, resp::binary-size(len)-unit(8), rest::binary>>),
    do: {:ok, resp, rest}

  defp read_frame(_), do: :partial

  # {offset i64, size i32, frame bytes} message-set head.
  defp parse_message_set(
         <<offset::signed-64, size::unsigned-32, frame::binary-size(size)-unit(8), _::binary>>
       ) do
    {offset, frame}
  end
end
