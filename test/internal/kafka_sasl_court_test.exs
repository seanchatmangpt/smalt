# KD-191 — Kafka SASL face court. Chicago discipline: real TCP conns on
# real loopback (conns spawned via the real ConnSup), the vendored
# kafka-python-ng client for the positive leg, raw in-process TCP clients
# for the refusal legs. No mocks. Context: solo (in-process wire faces on
# loopback).
#
# Probe scripts: scripts/az1/kafka_sasl_probe.py (positive,
# NEGOTIATED-SASL marker), scripts/az1/kafka_sasl_negative_probe.py
# (raw-TCP refusal corpus).
#
# SHIM-COURT target: mutating Sasl.parse_plain/1 to admit malformed shapes
# must turn this file RED (scripts/shim_court/kafka_sasl_court.sh).

defmodule SmaltTest.KafkaSaslCourtTest do
  use ExUnit.Case, async: false

  alias Smalt.Messaging.Kafka.{Conn, Sasl, Wire}

  @probe "scripts/az1/kafka_sasl_probe.py"
  @negative "scripts/az1/kafka_sasl_negative_probe.py"

  setup do
    orig_kafka = Application.get_env(:smalt, :kafka)
    orig_auth = Application.get_env(:smalt, :auth_mode)

    on_exit(fn ->
      if is_nil(orig_kafka),
        do: Application.delete_env(:smalt, :kafka),
        else: Application.put_env(:smalt, :kafka, orig_kafka)

      if is_nil(orig_auth),
        do: Application.delete_env(:smalt, :auth_mode),
        else: Application.put_env(:smalt, :auth_mode, orig_auth)
    end)

    :ok
  end

  # -- helpers -------------------------------------------------------------------

  defp sasl_env(mechs) do
    [sasl_required: true, sasl_mechanisms: mechs]
  end

  # Boot a real loopback listener; hand the accepted socket to the REAL
  # ConnSup so the connection under test is the real Conn GenServer.
  defp open_conn(opts \\ []) do
    {:ok, l} =
      :gen_tcp.listen(0, [
        :binary,
        packet: :raw,
        active: false,
        reuseaddr: true,
        ip: {127, 0, 0, 1},
        backlog: 1
      ])

    {:ok, port} = :inet.port(l)
    server = self()
    ref = make_ref()

    acceptor =
      spawn_link(fn ->
        {:ok, sock} = :gen_tcp.accept(l, 10_000)

        child = %{
          id: {:kafka_sasl_court_conn, make_ref()},
          start: {Conn, :start_link, [[socket: sock, advertised_port: port]]},
          restart: :temporary
        }

        case DynamicSupervisor.start_child(Smalt.Messaging.Kafka.ConnSup, child) do
          {:ok, _pid} -> send(server, {ref, :conn_up})
          _ -> send(server, {ref, :conn_down})
        end

        # hold the listener socket open for the connection's lifetime
        receive do
          :close -> :ok
        end
      end)

    on_exit(fn -> send(acceptor, :close) end)

    {:ok, client} =
      :gen_tcp.connect({127, 0, 0, 1}, port, [:binary, packet: :raw, active: false], 5_000)

    assert_receive {^ref, :conn_up}, 5_000

    if opts[:set_auth_enforce], do: Application.put_env(:smalt, :auth_mode, :enforce)

    client
  end

  defp req(c, key, ver, corr, body) do
    payload =
      <<key::integer-size(16), ver::integer-size(16), corr::integer-size(32),
        0::integer-size(16)>> <> body

    :ok = :gen_tcp.send(c, <<:erlang.iolist_size(payload)::integer-size(32), payload::binary>>)
  end

  defp recv_resp(c) do
    # response size field counts the correlation id + body (Conn.send_response
    # frames payload = iodata_length(body) + 4)
    {:ok, <<size::integer-size(32)>>} = :gen_tcp.recv(c, 4, 5_000)
    {:ok, <<_corr::integer-size(32), body::binary>>} = :gen_tcp.recv(c, size, 5_000)
    body
  end

  # true when the server closed the connection (crash-only face)
  defp recv_closed(c) do
    case :gen_tcp.recv(c, 0, 5_000) do
      {:ok, <<>>} -> true
      {:error, :closed} -> true
      {:error, _other} -> false
      {:ok, _data} -> false
    end
  end

  defp handshake(c, mech, corr) do
    req(c, 17, 0, corr, <<byte_size(mech)::unsigned-integer-size(16), mech::binary>>)
    recv_resp(c)
  end

  defp authenticate(c, mech, token, corr) do
    body =
      <<byte_size(mech)::unsigned-integer-size(16), mech::binary>> <>
        <<byte_size(token)::unsigned-integer-size(32), token::binary>>

    req(c, 36, 0, corr, body)
    recv_resp(c)
  end

  defp plain_token(user, password) do
    <<0>> <> user <> <<0>> <> password
  end

  # -- pure-module courts --------------------------------------------------------

  test "wire matrix carries the SASL rows" do
    assert Wire.version_matrix()[17] == {0, 0}
    assert Wire.version_matrix()[36] == {0, 1}
    assert Wire.api_keys().sasl_handshake == 17
    assert Wire.api_keys().sasl_authenticate == 36
    assert Wire.error_code(:unsupported_sasl_mechanism) == 33
    assert Wire.error_code(:illegal_sasl_state) == 34
    assert Wire.error_code(:sasl_authentication_failed) == 58
  end

  test "parse_plain admits a well-formed RFC-4616 token" do
    token = "u" <> <<0>> <> "alice" <> <<0>> <> "pw"
    full = <<byte_size(token)::unsigned-integer-size(32), token::binary>>

    assert Sasl.parse_plain(full) == {:ok, "u", "alice", "pw"}
  end

  test "parse_plain refuses shape violations" do
    # length prefix longer than the remaining bytes
    assert Sasl.parse_plain(<<10::unsigned-integer-size(32), "abc">>) ==
             {:error, :malformed_plain}

    # four fields
    token = "a" <> <<0>> <> "b" <> <<0>> <> "c" <> <<0>> <> "d"
    full = <<byte_size(token)::unsigned-integer-size(32), token::binary>>

    assert Sasl.parse_plain(full) == {:error, :malformed_plain}
    assert Sasl.parse_plain(<<>>) == {:error, :malformed_plain}
  end

  test "authenticate: plain blank creds refused, non-blank admitted" do
    assert Sasl.authenticate(:plain, {:ok, "", "", ""}) == {:refused, :invalid_client}
    assert Sasl.authenticate(:plain, {:ok, "", "alice", "pw"}) == {:ok, "alice"}
    assert Sasl.authenticate(:plain, {:error, :malformed_plain}) == {:error, :malformed_plain}
  end

  test "authenticate: anonymous gated on configured AND not-enforce" do
    Application.put_env(:smalt, :kafka, sasl_env([:plain, :anonymous]))
    Application.put_env(:smalt, :auth_mode, :enforce)
    assert Sasl.authenticate(:anonymous, nil) == {:refused, :anonymous_under_enforce}

    Application.put_env(:smalt, :auth_mode, :anonymous)
    assert Sasl.authenticate(:anonymous, nil) == {:ok, :anonymous}

    Application.put_env(:smalt, :kafka, sasl_env([:plain]))
    Application.put_env(:smalt, :auth_mode, :anonymous)
    assert Sasl.authenticate(:anonymous, nil) == {:refused, :anonymous_not_configured}
  end

  # -- default-off regression ------------------------------------------------------

  test "default-off: no sasl env keeps the face open from the first byte" do
    Application.delete_env(:smalt, :kafka)
    assert Sasl.required?() == false

    c = open_conn()
    # Metadata v0 works with zero SASL exchange
    req(c, 3, 0, 1, <<0::integer-size(32)>>)
    <<err::signed-integer-size(16), _rest::binary>> = recv_resp(c)
    assert err == 0
  end

  # -- wire courts (SASL-required posture) ------------------------------------------

  test "handshake advertises configured mechanisms; authenticate flips phase" do
    Application.put_env(:smalt, :kafka, sasl_env([:plain]))
    c = open_conn()

    resp = handshake(c, "PLAIN", 1)
    <<err::signed-integer-size(16), n::integer-size(32), rest::binary>> = resp
    assert err == 0
    assert n == 1
    # mechanisms array: "PLAIN"
    assert rest == <<5::unsigned-integer-size(16), "PLAIN">>

    resp = authenticate(c, "PLAIN", plain_token("alice", "pw"), 2)
    <<err2::signed-integer-size(16), rest2::binary>> = resp
    assert err2 == 0
    # nullable error_message (-1) | auth_bytes size 0
    assert rest2 == <<-1::signed-integer-size(16), 0::signed-integer-size(32)>>

    # phase flipped: Metadata now routable
    req(c, 3, 0, 3, <<0::integer-size(32)>>)
    <<err3::signed-integer-size(16), _::binary>> = recv_resp(c)
    assert err3 == 0
  end

  test "unadvertised mechanism: error 33 then kill (named falsifier)" do
    Application.put_env(:smalt, :kafka, sasl_env([:plain]))
    c = open_conn()

    resp = handshake(c, "GSSAPI", 1)
    <<err::signed-integer-size(16), _n::integer-size(32), _rest::binary>> = resp
    assert err == 33
    assert recv_closed(c)
  end

  test "produce before auth is killed typed, never served" do
    Application.put_env(:smalt, :kafka, sasl_env([:plain]))
    c = open_conn()

    body =
      <<1::integer-size(16), 5000::integer-size(32), 1::integer-size(32),
        0::integer-size(16), 1::integer-size(32), 1::integer-size(32),
        0::integer-size(32), 0::integer-size(32)>>

    req(c, 0, 2, 9, body)
    assert recv_closed(c)
  end

  test "blank credentials: error 58 + kill" do
    Application.put_env(:smalt, :kafka, sasl_env([:plain]))
    c = open_conn()
    _ = handshake(c, "PLAIN", 1)

    resp = authenticate(c, "PLAIN", plain_token("alice", ""), 2)
    <<err::signed-integer-size(16), rest::binary>> = resp
    assert err == 58

    <<mlen::unsigned-integer-size(16), _msg::binary-size(mlen)-unit(8), _::binary>> = rest
    assert mlen > 0
    assert recv_closed(c)
  end

  test "malformed PLAIN token: crash-only kill, never an answer" do
    Application.put_env(:smalt, :kafka, sasl_env([:plain]))
    c = open_conn()
    _ = handshake(c, "PLAIN", 1)

    # token "abc" contains no nul separators -> parse_plain malformed
    body =
      <<5::unsigned-integer-size(16), "PLAIN">> <>
        <<3::unsigned-integer-size(32), "abc">>

    payload = <<36::integer-size(16), 0::integer-size(16), 7::integer-size(32), 0::integer-size(16)>> <> body
    :ok = :gen_tcp.send(c, <<:erlang.iolist_size(payload)::integer-size(32), payload::binary>>)
    assert recv_closed(c)
  end

  test "duplicate handshake after auth: error 34 + kill" do
    Application.put_env(:smalt, :kafka, sasl_env([:plain]))
    c = open_conn()
    _ = handshake(c, "PLAIN", 1)
    _ = authenticate(c, "PLAIN", plain_token("alice", "pw"), 2)

    resp = handshake(c, "PLAIN", 3)
    <<err::signed-integer-size(16), _n::integer-size(32), _rest::binary>> = resp
    assert err == 34
    assert recv_closed(c)
  end

  test "ANONYMOUS under auth_mode :enforce: error 58 + kill" do
    Application.put_env(:smalt, :kafka, sasl_env([:plain, :anonymous]))
    c = open_conn(set_auth_enforce: true)

    resp = handshake(c, "ANONYMOUS", 1)
    <<err::signed-integer-size(16), _::binary>> = resp
    assert err == 0

    resp = authenticate(c, "ANONYMOUS", "", 2)
    <<err2::signed-integer-size(16), _::binary>> = resp
    assert err2 == 58
    assert recv_closed(c)
  end

  test "ANONYMOUS admitted when configured AND auth_mode :anonymous" do
    Application.put_env(:smalt, :kafka, sasl_env([:plain, :anonymous]))
    c = open_conn()

    resp = handshake(c, "ANONYMOUS", 1)
    <<err::signed-integer-size(16), _::binary>> = resp
    assert err == 0

    resp = authenticate(c, "ANONYMOUS", "", 2)
    <<err2::signed-integer-size(16), _::binary>> = resp
    assert err2 == 0

    # phase :open — Metadata routable
    req(c, 3, 0, 3, <<0::integer-size(32)>>)
    <<err3::signed-integer-size(16), _::binary>> = recv_resp(c)
    assert err3 == 0
  end

  # KD-191 note: the full produce roundtrip here is BLOCKED by an in-flight
  # KD-174 defect (Records.parse_message_set {:corrupt_batch, :too_short} on
  # the vendored client's produce bytes — reproduces without the KD-191
  # rows, disclosed cross-lane). Excluded (typed) in the shim court; the
  # leg flips green when KD-174 lands its records fix.
  @tag :vendored_probe
  test "vendored raw-PLAIN continuation: full kafka-python-ng producer roundtrip (NEGOTIATED-SASL)" do
    Application.put_env(:smalt, :kafka, sasl_env([:plain]))

    {out, 0} =
      System.cmd("python3", [@probe, "--port", to_string(Smalt.Messaging.Kafka.Listener.port())],
        env: [
          {"KAFKALIB", Path.join(File.cwd!(), "tmp/kafkalib")},
          {"PATH", System.get_env("PATH") || ""}
        ],
        into: ""
      )

    assert out =~ "NEGOTIATED-SASL"
  end

  test "negative probe corpus: all refusal legs witnessed" do
    Application.put_env(:smalt, :kafka, sasl_env([:plain, :anonymous]))
    Application.put_env(:smalt, :auth_mode, :enforce)

    {out, 0} =
      System.cmd("python3", [@negative, "--port", to_string(Smalt.Messaging.Kafka.Listener.port())],
        env: [
          {"KAFKALIB", Path.join(File.cwd!(), "tmp/kafkalib")},
          {"PATH", System.get_env("PATH") || ""}
        ],
        into: ""
      )

    assert out =~ "SUMMARY: PASS"
  end
end
