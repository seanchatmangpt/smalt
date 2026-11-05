# KD-190 court (lane L1, v26.11.6). Chicago discipline: raw-TCP falsifiers
# (layer 1), a real kafka-python-ng probe (layer 2), and the KD-190 honest
# divergence leg (layer 3). No mocks, no fixed sleeps: bounded polls on
# real observables (ETS snapshots, sockets, probe exit). Context: solo
# (in-process wire face on loopback, ephemeral port).
#
# NOTE: the plan named this row KD-189; KD-189 was already minted by the
# blob legalhold lane (first-minted-wins law) — this row is KD-190.

defmodule SmaltTest.KafkaGroupCourtTest do
  use ExUnit.Case, async: false

  alias Smalt.Messaging.Kafka.GroupManager

  @probe "scripts/az1/kafka_group_probe.py"
  @topic "kafka"

  defp kafka_port, do: Smalt.Messaging.Kafka.Listener.port()

  defp probe_env do
    [
      {"KAFKALIB", Path.join(File.cwd!(), "tmp/kafkalib")},
      {"PATH", System.get_env("PATH") || ""}
    ]
  end

  defp run(args),
    do: System.cmd("python3", args, env: probe_env(), into: "")

  defp wait_until(fun, tries \\ 200)

  defp wait_until(_fun, 0), do: flunk("wait_until exhausted")

  defp wait_until(fun, tries) do
    if fun.() do
      :ok
    else
      # SLEEP-CLASS: POLL-STEP — bounded poll on real GroupManager ETS state.
      Process.sleep(50)
      wait_until(fun, tries - 1)
    end
  end

  # -- raw-TCP helpers ------------------------------------------------------------

  defp connect do
    {:ok, sock} = :gen_tcp.connect(~c"127.0.0.1", kafka_port(), [:binary, active: false, packet: :raw])
    sock
  end

  # classic header: key i16 | ver i16 | corr u32 | client_id str
  defp req(key, ver, corr, body, cid \\ ~c"g") do
    hdr = [<<key::16, ver::16, corr::32, length(cid)::unsigned-16>>, cid]
    [<<IO.iodata_length(hdr) + IO.iodata_length(body)::unsigned-32>>, hdr, body]
  end

  # read one size-prefixed frame (bounded recv poll)
  defp recv_frame(sock, acc \\ <<>>) do
    case :gen_tcp.recv(sock, 0, 10_000) do
      {:ok, data} ->
        buf = <<acc::binary, data::binary>>

        case buf do
          <<size::unsigned-32, rest::binary>> when byte_size(rest) >= size - 4 -> buf
          _ -> recv_frame(sock, buf)
        end

      other ->
        other
    end
  end

  # JoinGroup request body builder
  defp join_body(group, member_id, session_timeout, ptype, protos) do
    protos_io =
      Enum.map(protos, fn {name, meta} ->
        [<<byte_size(name)::unsigned-16>>, name, <<byte_size(meta)::signed-32>> | meta]
      end)

    [
      <<byte_size(group)::unsigned-16>>, group,
      <<session_timeout::signed-32>>,
      # rebalance_timeout present only at v1+; callers choose version
      <<byte_size(member_id)::unsigned-16>>, member_id,
      <<byte_size(ptype)::unsigned-16>>, ptype,
      <<length(protos)::signed-32>> | protos_io
    ]
  end

  defp sub_meta(topics) do
    t = Enum.map(topics, fn name -> [<<byte_size(name)::unsigned-16>>, name] end)
    [<<0::signed-16, length(topics)::signed-32>>, t, <<-1::signed-32>>] |> IO.iodata_to_binary()
  end

  defp sync_body(group, gen, mid, assigns) do
    a =
      Enum.map(assigns, fn {mid, bytes} ->
        [<<byte_size(mid)::unsigned-16>>, mid, <<byte_size(bytes)::signed-32>> | bytes]
      end)

    [
      <<byte_size(group)::unsigned-16>>, group,
      <<gen::signed-32>>,
      <<byte_size(mid)::unsigned-16>>, mid,
      <<length(assigns)::signed-32>> | a
    ]
  end

  defp hb_body(group, gen, mid) do
    [<<byte_size(group)::unsigned-16>>, group, <<gen::signed-32>>, <<byte_size(mid)::unsigned-16>> | mid]
  end

  # -- layer 1: raw-TCP crash-only + state-machine falsifiers -----------------------
  # {generation, error_code, members_count} from a JoinGroup response
  defp join_gen_err_nm(frame) do
    <<
      _::unsigned-32, _::unsigned-32, err::signed-16, gen::signed-32,
      plen::unsigned-16, _::binary-size(plen)-unit(8),
      llen::unsigned-16, _::binary-size(llen)-unit(8),
      mlen::unsigned-16, _::binary-size(mlen)-unit(8),
      nm::signed-32, _::binary
    >> = frame

    {gen, err, nm}
  end

  # first successful JoinGroup response member_id (err i16 | gen i32 | proto str | leader str | member str ...)

  # -- layer 1 tests ------------------------------------------------------------

  # KD-HC-2 falsifier: FindCoordinator v1 carries the KIP-113
  # throttle_time_ms i32 head (27-byte body) — librdkafka _UNDERFLOWs on the
  # short form. v0 stays bare (19-byte body, no throttle, no error_message).
  test "layer1: FindCoordinator v0/v1 byte-exact (v1 carries throttle_time_ms head)" do
    sock = connect()

    # v0: key str only.
    body0 = [<<byte_size("g")::unsigned-16>>, "g"]
    :ok = :gen_tcp.send(sock, req(10, 0, 7, body0))

    assert {:ok,
            <<
              _::unsigned-32, 7::unsigned-32, err0::signed-16,
              cid0::signed-32, hlen0::unsigned-16, host0::binary-size(hlen0)-unit(8),
              port0::signed-32
            >>} = recv_frame(sock)

    assert err0 == 0
    assert host0 == "127.0.0.1"

    # v1: key str + coordinator_type i8. Response: throttle i32 | err i16 |
    # error_message null string | coordinator_id i32 | host str | port i32.
    body1 = [<<byte_size("g")::unsigned-16>>, "g", <<0::signed-8>>]
    :ok = :gen_tcp.send(sock, req(10, 1, 8, body1))

    assert {:ok,
            <<
              _::unsigned-32, 8::unsigned-32, throttle::signed-32, err1::signed-16,
              -1::signed-16, cid1::signed-32, hlen1::unsigned-16,
              host1::binary-size(hlen1)-unit(8), port1::signed-32
            >>} = recv_frame(sock)

    assert throttle == 0
    assert err1 == 0
    assert host1 == "127.0.0.1"
    assert port1 == port0

    :gen_tcp.close(sock)
  end

  test "layer1: JoinGroup v5 (first flexible JoinGroup) is crash-only killed, not parsed" do
    parent = self()

    ref =
      :telemetry.attach(:kd190_join_v5, [:smalt, :kafka, :conn_killed],
        fn _e, _m, meta, _ -> send(parent, {:killed, meta}) end, %{})

    sock = connect()
    body = join_body("kd190-v5", "", 30_000, "consumer", [{"roundrobin", sub_meta([@topic])}])
    payload = IO.iodata_to_binary(body) <> <<0::signed-32>>
    :ok = :gen_tcp.send(sock, req(11, 5, 1, payload))

    assert recv_frame(sock) == {:error, :closed}
    assert_receive {:killed, %{reason: {:unsupported_version, 11, 5}}}, 10_000
    :telemetry.detach(ref)
  end

  test "layer1: protocol_type != consumer answered in-band 23, conn survives" do
    sock = connect()
    body = join_body("kd190-ptype", "", 30_000, "connect", [{"roundrobin", sub_meta([@topic])}])
    :ok = :gen_tcp.send(sock, req(11, 0, 2, body))

    <<_::unsigned-32, 2::unsigned-32, err::signed-16, _::binary>> = recv_frame(sock)
    assert err == 23
    :gen_tcp.close(sock)
  end

  test "layer1: cooperative-sticky protocol refused in-band 23" do
    sock = connect()
    body = join_body("kd190-coop", "", 30_000, "consumer", [{"cooperative-sticky", sub_meta([@topic])}])
    :ok = :gen_tcp.send(sock, req(11, 0, 3, body))

    <<_::unsigned-32, 3::unsigned-32, g::signed-16, _::binary>> = recv_frame(sock)
    assert g == 23
  end

  test "layer1: two members join, generation bumps, leader sees subscriptions" do
    group = "kd190-gen"
    sock1 = connect()
    sock2 = connect()

    jb = fn mid ->
      join_body(group, mid, 30_000, "consumer", [{"roundrobin", sub_meta([@topic])}])
    end

    :ok = :gen_tcp.send(sock1, req(11, 0, 10, jb.("")))
    # a lone first member completes immediately (real broker semantics)
    frame1 = recv_frame(sock1)
    assert <<_::unsigned-32, 10::unsigned-32, 0::signed-16, 1::signed-32, _::binary>> = frame1

    # second member triggers a fresh rebalance and PARKS until m1 rejoins
    :ok = :gen_tcp.send(sock2, req(11, 0, 11, jb.("")))
    assert {:error, :timeout} = recv_frame(sock2, <<>>)

    # m1's client rejoins -> rebalance completes, both get gen 2
    m1 = member_id_from_join(frame1)
    :ok = :gen_tcp.send(sock1, req(11, 0, 12, jb.(m1)))

    f1b = recv_frame(sock1)
    f2 = recv_frame(sock2)

    {gen2, err1b, nm1} = join_gen_err_nm(f1b)
    {gen2b, err2, nm2} = join_gen_err_nm(f2)

    assert err1b == 0 and err2 == 0
    assert gen2 == 2 and gen2b == 2
    # leader sees the subscription list; follower sees empty members array
    assert nm1 == 2
    assert nm2 == 0

    g = GroupManager.groups()[group]
    assert g.state == :completing
    assert g.generation == 2
    assert map_size(g.members) == 2
    :gen_tcp.close(sock1)
    :gen_tcp.close(sock2)
  end

  test "layer1: sync completes rebalance; follower parked reply carries assignment" do
    group = "kd190-sync"
    sock1 = connect()
    sock2 = connect()

    jb = fn mid ->
      join_body(group, mid, 30_000, "consumer", [{"roundrobin", sub_meta([@topic])}])
    end

    :ok = :gen_tcp.send(sock1, req(11, 0, 20, jb.("")))
    frame1 = recv_frame(sock1)
    m1 = member_id_from_join(frame1)

    :ok = :gen_tcp.send(sock2, req(11, 0, 21, jb.("")))
    assert {:error, :timeout} = recv_frame(sock2, <<>>)

    # m1 rejoins -> gen 2 completing; both join responses landed
    :ok = :gen_tcp.send(sock1, req(11, 0, 22, jb.(m1)))
    f1b = recv_frame(sock1)
    f2 = recv_frame(sock2)
    m2 = member_id_from_join(f2)

    # leader (lexicographically-first member id) submits broker roundrobin:
    # empty group_assignment -> GroupManager computes it
    :ok = :gen_tcp.send(sock1, req(14, 0, 23, sync_body(group, 2, m1, [])))
    <<_::unsigned-32, 23::unsigned-32, err::signed-16, alen::signed-32,
      _a::binary-size(alen)-unit(8)>> = recv_frame(sock1)
    assert err == 0
    assert alen > 0

    # follower's parked sync answered with its own assignment
    :ok = :gen_tcp.send(sock2, req(14, 0, 24, sync_body(group, 2, m2, [])))
    <<_::unsigned-32, 24::unsigned-32, err2::signed-16, alen2::signed-32,
      _a2::binary-size(alen2)-unit(8)>> = recv_frame(sock2)
    assert err2 == 0 and alen2 > 0

    g = GroupManager.groups()[group]
    assert g.state == :stable
    assert g.members[m1].assignment != nil
    assert g.members[m2].assignment != nil

    :gen_tcp.close(sock1)
    :gen_tcp.close(sock2)
  end

  test "layer1: heartbeat wrong generation -> 22; unknown member -> 25" do
    sock = connect()
    :ok = :gen_tcp.send(sock, req(12, 0, 30, hb_body("kd190-hb", 99, "ghost")))
    <<_::unsigned-32, 30::unsigned-32, err::signed-16>> = recv_frame(sock)
    assert err == 25

    body = join_body("kd190-hb", "", 60_000, "consumer", [{"roundrobin", sub_meta([@topic])}])
    :ok = :gen_tcp.send(sock, req(11, 0, 31, body))
    jf = recv_frame(sock)
    mid = member_id_from_join(jf)

    sock2 = connect()
    :ok = :gen_tcp.send(sock2, req(12, 0, 32, hb_body("kd190-hb", 99, mid)))
    <<_::unsigned-32, 32::unsigned-32, err2::signed-16>> = recv_frame(sock2)
    assert err2 == 22

    :gen_tcp.close(sock)
    :gen_tcp.close(sock2)
  end

  test "layer1: session-timeout sweeper evicts member; group returns to empty" do
    group = "kd190-sweep"
    sock = connect()
    body = join_body(group, "", 1_000, "consumer", [{"roundrobin", sub_meta([@topic])}])
    :ok = :gen_tcp.send(sock, req(11, 0, 40, body))
    recv_frame(sock)
    :gen_tcp.close(sock)

    wait_until(fn ->
      case GroupManager.groups()[group] do
        nil -> false
        g -> g.state == :empty and map_size(g.members) == 0
      end
    end)
  end

  test "layer1: commit with live generation stores offsets; fetch reads them back" do
    group = "kd190-offsets"
    sock = connect()
    topic = @topic
    body = join_body(group, "", 60_000, "consumer", [{"roundrobin", sub_meta([topic])}])
    :ok = :gen_tcp.send(sock, req(11, 0, 50, body))
    jf = recv_frame(sock)
    mid = member_id_from_join(jf)
    <<_::unsigned-32, _::unsigned-32, _::signed-16, gen::signed-32, _::binary>> = jf

    commit_body = [
      <<byte_size(group)::unsigned-16>>, group,
      <<gen::signed-32>>,
      <<byte_size(mid)::unsigned-16>>, mid,
      <<10_000::signed-64>>,
      <<1::signed-32>>,
      <<byte_size(topic)::unsigned-16>>, topic,
      <<1::signed-32>>,
      <<0::signed-32, 7::signed-64, 0::unsigned-16>>
    ]

    :ok = :gen_tcp.send(sock, req(8, 2, 51, commit_body))
    <<_::unsigned-32, 51::unsigned-32, _tt::signed-32, nt::signed-32, _::binary>> = recv_frame(sock)
    assert nt == 1
    assert GroupManager.offsets()[{group, topic, 0}] == 7

    tlen = byte_size(topic)

    fetch_body = [
      <<byte_size(group)::unsigned-16>>, group,
      <<1::signed-32>>,
      <<tlen::unsigned-16>>, topic,
      <<1::signed-32>>,
      <<0::signed-32>>
    ]

    :ok = :gen_tcp.send(sock, req(9, 1, 52, fetch_body))
    <<_::unsigned-32, 52::unsigned-32, _n1::signed-32, tl::unsigned-16,
      _t::binary-size(tl)-unit(8), _np::signed-32,
      p::signed-32, off::signed-64, _ml::unsigned-16, _err::signed-16>> = recv_frame(sock)

    assert p == 0 and off == 7
    :gen_tcp.close(sock)
  end

  test "layer3 KD-190: offsets survive a GroupManager restart (journal close-condition)" do
    group = "kd190-restart-" <> Integer.to_string(System.unique_integer([:positive]))
    sock = connect()
    topic = @topic
    body = join_body(group, "", 60_000, "consumer", [{"roundrobin", sub_meta([topic])}])
    :ok = :gen_tcp.send(sock, req(11, 0, 60, body))
    jf = recv_frame(sock)
    mid = member_id_from_join(jf)
    <<_::unsigned-32, _::unsigned-32, _::signed-16, gen::signed-32, _::binary>> = jf
    commit_body =
      IO.iodata_to_binary([
        <<byte_size(group)::unsigned-16>>, group,
        <<gen::signed-32>>,
        <<byte_size(mid)::unsigned-16>>, mid,
        <<10_000::signed-64>>,
        <<1::signed-32>>,
        <<byte_size(topic)::unsigned-16>>, topic,
        <<1::signed-32>>,
        <<1::signed-32, 3::signed-64, 0::unsigned-16>>
      ])
    :ok = :gen_tcp.send(sock, req(8, 2, 61, commit_body))
    recv_frame(sock)
    assert GroupManager.offsets()[{group, topic, 1}] == 3
    pid = Process.whereis(GroupManager)
    Process.exit(pid, :kill)
    wait_until(fn ->
      p2 = Process.whereis(GroupManager)
      p2 != nil and p2 != pid and Process.alive?(p2)
    end)
    # KD-190 close condition met: the OffsetJournal lands journaled offsets
    # (lane-coordinated; the former honest divergence is witnessed as CLOSED
    # by persistence across restart)
    wait_until(fn -> GroupManager.offsets()[{group, topic, 1}] == 3 end)
    assert Map.has_key?(GroupManager.offsets(), {group, topic, 1})
    :gen_tcp.close(sock)
  end

  @tag timeout: 240_000

  test "layer2: real kafka-python-ng consumer group lifecycle (join/sync/heartbeat/commit/resume/leave)" do
    tag = "kd190-#{System.unique_integer([:positive])}"
    {out, 0} = run([@probe, "--port", to_string(kafka_port()), "--tag", tag])
    assert out =~ "PASS legA"
    assert out =~ "PASS legB"
    assert out =~ "PASS legC"
    assert out =~ "PASS ALL"
  end

  # {generation, error_code, members_count} from a JoinGroup response
  # leader str | member str ...)
  defp member_id_from_join(frame) do
    <<
      _::unsigned-32, _::unsigned-32, 0::signed-16, _::signed-32,
      plen::unsigned-16, _::binary-size(plen)-unit(8),
      llen::unsigned-16, _::binary-size(llen)-unit(8),
      mlen::unsigned-16, mid::binary-size(mlen)-unit(8), _::binary
    >> = frame

    mid
  end
end
