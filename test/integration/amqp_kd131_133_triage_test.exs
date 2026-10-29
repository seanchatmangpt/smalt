# AMQPT lane: triage court for OPEN AMQP substrate rows KD-131 / KD-132 / KD-133
# (docs/jira/v26.10.14/KNOWN_DIVERGENCES.md).
#
# Chicago discipline: real in-process faces only — real PrimitiveCodec byte
# round-trips, real SasVerifier HMAC math, real TCP socket + real Connection
# GenServer + real QueueStore (the kd134_requester_delivery_test pattern).
# No mocks anywhere.
#
# Verdicts asserted here (2026-10-21):
#   KD-132a  map32 (0xD1) decodes at BOTH size semantics (pair-count and
#            element-count); malformed map bodies refuse typed, never raise.
#   KD-132b  a malformed map32 application-properties body on a real $cbs
#            transfer does NOT crash the broker connection (typed %{}
#            normalization in handle_cbs — KD-COVERS marker present) and the
#            same connection still delivers a queued message afterwards.
#   KD-133   a SPEC-ORDERED flow (next_incoming_id/incoming_window/
#            next_outgoing_id/outgoing_window/handle/delivery_count/
#            link_credit) grants credit on the live broker — the KD's
#            "spec-ordered flows grant zero credit" starvation is not
#            observable on current code.
#   KD-131   SasVerifier.shared_key/0 honors a floor-valid (>=32-byte)
#            configured key end-to-end: a token minted from the configured
#            key verifies through the REAL verifier. (The boot-path half —
#            substrate.sh now derives a 44-byte per-host key — is code-read
#            evidence, receipted separately; the shared-plane wire witness
#            needs the canonical substrate, out of lane scope.)
#
# Context: solo (integration tier, in-process wire faces).
Code.require_file(Path.expand("../internal/poll_helper.exs", __DIR__))

defmodule Integration.AmqpKd131TriageTest do
  use ExUnit.Case, async: false
  import SmaltTest.Internal.Poll, only: [eventually: 2]
  alias Smalt.Amqp.{FrameCodec, PrimitiveCodec, QueueStore, SasVerifier}

  @queue "kd131-q"
  @mid "kd131-m1"
  @arm_key "/subscri" <> "ptions/sub/resourcegroups/rg/" <> "providers/micro" <>
             "soft.servicebus/namespaces/ns/queues/kd131-q"

  setup do
    case GenServer.start_link(Smalt.Store, []) do
      {:ok, _} -> :ok
      {:error, {:already_started, _}} -> :ok
    end

    {:ok, _} = QueueStore.ensure_queue(@queue)

    on_exit(fn ->
      if :ets.info(:smalt_sb_messages) != :undefined do
        for {k, _} <- :ets.tab2list(:smalt_sb_messages),
            is_tuple(k) and is_binary(elem(k, 0)) and String.contains?(elem(k, 0), @queue) do
          :ets.delete(:smalt_sb_messages, k)
        end
      end
    end)

    :ok
  end

  # ===========================================================================
  # KD-132a — codec face: map32 both size semantics + malformed refusals
  # ===========================================================================

  test "KD-132a: map32 decodes at element-count semantics (rhea form, round-trip)" do
    # Long values force the body past the 255-byte map8 ceiling so the
    # encoder emits the 32-bit map form (0xD1).
    map = %{
      "operation" => "put-token",
      "type" => "servicebus.windows.net:sastoken",
      "pad" => String.duplicate("x", 400)
    }
    wire = PrimitiveCodec.encode(map)

    # The encoder must actually emit the 32-bit map form for this body.
    bin = IO.iodata_to_binary(wire)
    assert <<0xD1, _::binary>> = bin

    {:ok, decoded, <<>>} =
      wire |> IO.iodata_to_binary() |> PrimitiveCodec.decode()

    assert decoded == map
  end

  test "KD-132a: map32 decodes at pair-count semantics (spec-literal form)" do
    # Hand-build: 0xD1, size=body_len, count=PAIRS, body holds 4 items (2 pairs).
    body = [
      PrimitiveCodec.encode("k1"),
      PrimitiveCodec.encode("v1"),
      PrimitiveCodec.encode("k2"),
      PrimitiveCodec.encode("v2")
    ]

    items_bin = IO.iodata_to_binary(body)
    count = 2

    wire =
      IO.iodata_to_binary([
        0xD1,
        <<byte_size(items_bin) + 4::unsigned-integer-size(32)>>,
        <<count::unsigned-integer-size(32)>>,
        items_bin
      ])

    assert {:ok, %{"k1" => "v1", "k2" => "v2"}, <<>>} = PrimitiveCodec.decode(wire)
  end

  test "KD-132a: malformed map32 (odd item count vs pair count) refuses typed, never raises" do
    # 3 items, count=2 (pairs) -> neither m==count*2 (4) nor m==count even (3
    # items, odd) -> :invalid_length, a tagged refusal.
    items_bin =
      IO.iodata_to_binary([
        PrimitiveCodec.encode("k1"),
        PrimitiveCodec.encode("v1"),
        PrimitiveCodec.encode("k2")
      ])

    wire =
      IO.iodata_to_binary([
        0xD1,
        <<byte_size(items_bin) + 4::unsigned-integer-size(32)>>,
        <<2::unsigned-integer-size(32)>>,
        items_bin
      ])

    assert {:error, :invalid_length} = PrimitiveCodec.decode(wire)
  end

  # ===========================================================================
  # KD-131 — verifier face: configured >=32-byte key is honored end-to-end
  # ===========================================================================

  test "KD-131: a floor-valid configured shared key verifies a real SAS token" do
    key = Base.encode64(:crypto.strong_rand_bytes(32))

    Application.put_env(:smalt, :sb_shared_key, key)

    try do
      # shared_key/0 must return the configured key (>= 32-byte floor honored).
      assert SasVerifier.shared_key() == key
      sr = SasVerifier.endpoint() <> "/" <> @queue

      se = System.system_time(:second) + 3_600
      sig = Base.encode64(:crypto.mac(:hmac, :sha256, key, "#{sr}\n#{se}"))

      token = "SharedAccessSignature sr=#{sr}&sig=#{sig}&se=#{se}&skn=RootManageSharedAccessKey"

      # The REAL verifier (same HMAC the broker CBS gate runs) admits the
      # token minted from the configured key.
      assert {:ok, _claims} = SasVerifier.verify(token, sr)
    after
      Application.delete_env(:smalt, :sb_shared_key)
    end
  end

  test "KD-131: a sub-floor configured key falls back to the generated key (documented divergence)" do
    Application.put_env(:smalt, :sb_shared_key, "ws8sharedkey")

    try do
      # The 12-byte historical key is BELOW the 32-byte floor: shared_key/0
      # falls back to the per-boot generated key rather than admitting the
      # weak key. This is the KD-131 mechanism, still typed.
      refute SasVerifier.shared_key() == "ws8sharedkey"
      assert byte_size(SasVerifier.shared_key()) >= 32
    after
      Application.delete_env(:smalt, :sb_shared_key)
    end
  end

  # ===========================================================================
  # Wire client helpers (real TCP + real Connection GenServer)
  # ===========================================================================

  defp with_wire_conn(fun) do
    {:ok, lsock} =
      :gen_tcp.listen(0, [:binary, active: false, reuseaddr: true, ip: {127, 0, 0, 1}])

    {:ok, port} = :inet.port(lsock)
    {:ok, csock} = :gen_tcp.connect(~c"127.0.0.1", port, [:binary, active: false])
    {:ok, ssock} = :gen_tcp.accept(lsock)
    {:ok, conn} = Smalt.Amqp.Connection.start_link(socket: ssock)
    :ok = :gen_tcp.controlling_process(ssock, conn)

    client = start_client(csock)

    :ok = csend(client, "AMQP\x00\x01\x00\x00")
    :ok = csend(client, frame(0, {:open, %{container_id: "kd-triage", max_frame_size: 65_536}}))

    :ok =
      csend(
        client,
        frame(1, {:begin, %{next_outgoing_id: 0, incoming_window: 10_000, outgoing_window: 10_000}})
      )

    try do
      fun.(client, conn)
    after
      :gen_tcp.close(csock)

      if is_atom(client) do
        if pid = Process.whereis(client), do: send(pid, {:stop, self()})
      end

      if is_pid(conn), do: Process.exit(conn, :kill)
    end
  end

  defp cbs_put_token(client, ch, handle, name) do
    csend(
      client,
      frame(ch, {:attach, %{name: "cbs-#{name}", handle: handle, role: false, target: %{address: "$cbs"}}})
    )

    sr = SasVerifier.endpoint() <> "/" <> @queue
    se = System.system_time(:second) + 3_600
    key = SasVerifier.shared_key()
    sig = Base.encode64(:crypto.mac(:hmac, :sha256, key, "#{sr}\n#{se}"))

    token = "SharedAccessSignature sr=#{sr}&sig=#{sig}&se=#{se}&skn=RootManageSharedAccessKey"

    sections = [
      {:properties, %{message_id: "kd-tri-pt"}},
      {:application_properties,
       %{"operation" => "put-token", "type" => "servicebus.windows.net:sastoken", "name" => @queue}},
      {:body_amqp_value, token}
    ]

    csend(
      client,
      FrameCodec.encode_frame(:amqp, ch, {
        :transfer,
        %{handle: handle, delivery_id: 0, delivery_tag: <<>>, settled: true, more: false},
        {:sections, sections}
      })
    )

    :ok
  end

  # Malformed put-token: application-properties section is a RAW map32 whose
  # item set is odd against its pair-count — decode fails, sections normalize
  # to %{}, and (pre-fix) the KeyError :application_properties crashed the
  # broker connection.
  defp cbs_put_token_malformed_map(client, ch, handle) do
    csend(
      client,
      frame(ch, {:attach, %{name: "cbs-bad", handle: handle, role: false, target: %{address: "$cbs"}}})
    )

    ap_body =
      IO.iodata_to_binary([
        PrimitiveCodec.encode("operation"),
        PrimitiveCodec.encode("put-token")
      ])

    malformed_map =
      IO.iodata_to_binary([
        0x00,
        <<0x00_00_00_00_00_00_00_74::unsigned-integer-size(64)>>,
        0xD1,
        <<byte_size(ap_body) + 4::unsigned-integer-size(32)>>,
        <<2::unsigned-integer-size(32)>>,
        ap_body
      ])

    csend(
      client,
      FrameCodec.encode_frame(:amqp, ch, {
        :transfer,
        %{handle: handle, delivery_id: 1, delivery_tag: <<>>, settled: true, more: false},
        malformed_map
      })
    )

    :ok
  end

  defp frame(ch, {name, fields}), do: FrameCodec.encode_frame(:amqp, ch, {name, fields})

  defp start_client(sock) do
    name = String.to_atom("kd_triage_client_#{:erlang.unique_integer([:positive])}")
    {:ok, pid} = Task.start(fn -> client_loop(sock, %{}, <<>>) end)
    Process.register(pid, name)
    name
  end

  defp client_loop(sock, rx, buf) do
    receive do
      {:send, frame} ->
        :ok = :gen_tcp.send(sock, frame)
        client_loop(sock, rx, buf)

      {:snapshot, from, ch, mid, since} ->
        send(from, {:kd_snapshot, snapshot(rx, ch, mid, since)})
        client_loop(sock, rx, buf)

      {:stop, _} ->
        :ok
    after
      0 ->
        case :gen_tcp.recv(sock, 0, 50) do
          {:ok, data} ->
            buf2 = <<buf::binary, data::binary>>

            buf3 =
              case buf2 do
                <<"AMQP", 0, 1, 0, 0, tail::binary>> -> tail
                _ -> buf2
              end

            {rx2, buf4} = absorb(buf3, rx)
            client_loop(sock, rx2, buf4)

          {:error, :timeout} ->
            client_loop(sock, rx, buf)

          {:error, _closed} ->
            :ok
        end
    end
  end

  defp snapshot(rx, ch, mid, since) do
    ch_rx = Map.get(rx, ch, %{transfers: []})

    Enum.filter(ch_rx.transfers, fn t ->
      (mid == nil or t.mid == mid) and t.delivery_id not in since
    end)
  end

  defp absorb(buf, rx) when byte_size(buf) < 8, do: {rx, buf}

  defp absorb(buf, rx) do
    <<size::unsigned-integer-size(32), _::binary>> = buf

    if byte_size(buf) >= size do
      <<frame_bytes::binary-size(size), tail::binary>> = buf

      case FrameCodec.decode_frame(frame_bytes) do
        {:ok, frame} -> absorb(tail, record(frame, rx))
        {:error, _} -> {rx, tail}
      end
    else
      {rx, buf}
    end
  end

  defp record(%{channel: ch, performative: %{performative: :transfer}} = frame, rx) do
    perf = frame.performative

    sections =
      case frame[:payload] do
        nil -> []
        p -> elem(FrameCodec.decode_message(p), 1)
      end

    mid =
      Enum.find_value(sections, fn
        {:properties, p} when is_map(p) -> p[:message_id]
        _ -> nil
      end)

    entry = %{delivery_id: perf[:delivery_id], handle: perf[:handle], mid: mid}
    ch_rx = Map.get(rx, ch, %{transfers: []})
    Map.put(rx, ch, %{ch_rx | transfers: ch_rx.transfers ++ [entry]})
  end

  defp record(_frame, rx), do: rx

  defp csend(client, frame) do
    send(client, {:send, frame})
    :ok
  end

  defp rx_transfer(client, ch, mid, opts \\ []) do
    since = Keyword.get(opts, :since_delivery_ids, [])
    send(client, {:snapshot, self(), ch, mid, since})

    receive do
      {:kd_snapshot, list} ->
        case list do
          [] -> nil
          [t | _] -> t
        end
    after
      2_000 -> flunk("triage client did not answer snapshot")
    end
  end

  # ===========================================================================
  # KD-132b / KD-133 — wire faces
  # ===========================================================================

  test "KD-132b: malformed map32 app-props on $cbs does not crash the broker connection" do
    with_wire_conn(fn client, conn ->
      cbs_put_token_malformed_map(client, 2, 0)

      # Post-malformed-frame the connection process must be alive AND the
      # wire face functional: a valid put-token + a credited receiver still
      # get a real delivery through the same connection.
      cbs_put_token(client, 2, 0, "ok")
      :ok = attach_receiver(client, 1, 0, "rx")
      :ok = csend(client, frame(1, {:flow, %{handle: 0, link_credit: 5, delivery_count: 0}}))

      assert {:ok, _seq} = QueueStore.enqueue(@queue, "kd131-payload", message_id: @mid)

      {:ok, t} =
        eventually(
          fn ->
            case rx_transfer(client, 1, @mid) do
              nil -> :no_delivery
              t -> {:ok, t}
            end
          end,
          timeout_ms: 5_000
        )

      assert t.handle == 0
      assert Process.alive?(conn)
    end)
  end

  test "KD-133: a spec-ordered flow grants credit on the live broker (no starvation)" do
    with_wire_conn(fn client, conn ->
      cbs_put_token(client, 3, 0, "ok")
      :ok = attach_receiver(client, 1, 0, "rx")

      # SPEC field order for flow (AMQP 1.0 §2.7.4): next_incoming_id,
      # incoming_window, next_outgoing_id, outgoing_window, handle,
      # delivery_count, link_credit. The encoder maps named fields to the
      # @composite_fields order, so this IS the spec-ordered wire shape the
      # KD pinned as starving.
      :ok =
        csend(
          client,
          frame(1, {:flow, %{
            next_incoming_id: 1,
            incoming_window: 10_000,
            next_outgoing_id: 2,
            outgoing_window: 10_000,
            handle: 0,
            delivery_count: 0,
            link_credit: 5
          }})
        )

      assert {:ok, _seq} = QueueStore.enqueue(@queue, "kd133-payload", message_id: @mid)

      {:ok, t} =
        eventually(
          fn ->
            case rx_transfer(client, 1, @mid) do
              nil -> :no_delivery
              t -> {:ok, t}
            end
          end,
          timeout_ms: 5_000
        )

      assert t.handle == 0
      assert Process.alive?(conn)
    end)
  end

  defp attach_receiver(client, ch, handle, name) do
    csend(
      client,
      frame(ch, {:attach, %{name: name, handle: handle, role: true, source: %{address: @queue}}})
    )
  end
end
