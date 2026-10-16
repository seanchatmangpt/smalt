defmodule Smalt.Compliance.C5ServicebusTest do
  @moduledoc """
  C5 compliance fences: AMQP 1.0 (OASIS) + Azure Service Bus dialect.

  Two tiers, per docs/compliance/C5_SERVICEBUS.md:

    1. **Byte-level encode fences** (pure `FrameCodec`/`PrimitiveCodec`):
       performative field order, map count = 2 x pairs, trailing-null
       omission, described-type descriptors (delivery states, session
       filter), error list shape, x-opt-* annotations, filetime lock expiry.

    2. **Live session round-trip** over a REAL `:gen_tcp` socket against a
       REAL `Smalt.AmqpBroker` listener on an ephemeral port: SASL
       ANONYMOUS -> open -> begin -> $cbs put-token -> sender attach ->
       transfer -> server disposition(accepted) -> receiver attach -> flow
       credit -> delivery -> disposition(accepted), plus error-condition
       probes (unauthorized-entity detach, session-cannot-be-locked).

  Gate:
    `mix test test/compliance/c5_servicebus.exs --include amqp_wire`
  """

  use ExUnit.Case, async: false
  @moduletag :amqp_wire

  alias Smalt.Amqp.{DeliveryEncoder, FrameCodec, PrimitiveCodec}

  @header "AMQP\x00\x01\x00\x00"
  @sasl_header "AMQP\x03\x01\x00\x00"
  @recv_timeout 5_000
  @cbs_type "servicebus.windows.net:sastoken"

  # ===========================================================================
  # Tier 1: byte-level encode fences (OASIS core)
  # ===========================================================================

  describe "open performative (OASIS 2.7.1)" do
    test "descriptor is ulong 0x10 and fields land in mandated order" do
      frame =
        FrameCodec.encode_frame(:amqp, 0, {
          :open,
          %{
            container_id: "c5-client",
            hostname: "host",
            max_frame_size: 65_536,
            channel_max: 100,
            idle_time_out: 60_000
          }
        })

      <<size::32, doff::8, type::8, channel::16, body::binary>> = IO.iodata_to_binary(frame)

      assert size == byte_size(<<size::32, doff::8, type::8, channel::16, body::binary>>)
      assert doff == 2 and type == 0x00 and channel == 0

      # 0x00 described, 0x53 ulong-small 0x10, 0xC0 list8, size, count
      assert <<0x00, 0x53, 0x10, 0xC0, _sz, count, _rest::binary>> = body
      assert count == 5

      assert {:ok, {:described, 0x10, fields}, <<>>} = PrimitiveCodec.decode(body)
      assert fields == ["c5-client", "host", 65_536, 100, 60_000]
    end

    test "trailing null fields are omitted (spec 1.4.3 list encoding)" do
      frame = IO.iodata_to_binary(FrameCodec.encode_frame(:amqp, 0, {:open, %{container_id: "x"}}))

      <<_::32, 2, 0, 0::16, 0x00, 0x53, 0x10, 0xC0, sz, count, 0xA1, 1, "x">> = frame

      # the list8 body carries exactly the string element, no null padding
      assert sz == 4 and count == 1
    end
  end

  describe "begin/attach/flow field orders (OASIS 2.7.2-2.7.4)" do
    test "begin field order: remote-channel, next-outgoing-id, incoming-window, outgoing-window, handle-max" do
      body =
        frame_body(
          FrameCodec.encode_frame(:amqp, 0, {
            :begin,
            %{remote_channel: 0, next_outgoing_id: 1, incoming_window: 10_000, outgoing_window: 10_000, handle_max: 100}
          })
        )

      assert {:ok, {:described, 0x11, [0, 1, 10_000, 10_000, 100]}, <<>>} =
               PrimitiveCodec.decode(body)
    end

    # Was GAP R6 (docs/compliance/C5_SERVICEBUS.md), fixed: the descriptor is
    # now chosen by ROLE in source_or_target/2 (frame_codec.ex) — a filter-less
    # SOURCE carries 0x28, a TARGET carries 0x29 — never by filter presence.
    test "attach is a 14-field composite; bare-minimum attach trims to 5 fields" do
      body =
        frame_body(
          FrameCodec.encode_frame(:amqp, 0, {
            :attach,
            %{name: "link", handle: 0, role: true, source: %{address: "q"}}
          })
        )

      assert {:ok, {:described, 0x12, fields}, <<>>} = PrimitiveCodec.decode(body)
      # name, handle, role(true=receiver), snd-settle-mode(null), source
      assert Enum.at(fields, 0) == "link"
      assert Enum.at(fields, 1) == 0
      assert Enum.at(fields, 2) == true
      # snd/rcv settle-mode nulls occupy indexes 3-4; source lands at index 5
      assert Enum.at(fields, 3) == nil and Enum.at(fields, 4) == nil
      # fixed R6: source carries the SOURCE descriptor 0x28
      assert match?({:described, 0x28, _}, Enum.at(fields, 5))

      # source composite: address at index 0, filter at index 7
      {:described, 0x28, src} = Enum.at(fields, 5)
      assert Enum.at(src, 0) == "q"

      # PARTIAL (R7): trailing nulls are NOT trimmed inside source/target
      # composites (trim_trailing_nulls/1 only applies to the performative
      # list) — spec-legal but non-minimal 8-element encoding.
      assert length(src) == 8
    end

    test "flow carries next-incoming-id..properties in order with drain/echo slots" do
      body =
        frame_body(
          FrameCodec.encode_frame(:amqp, 0, {
            :flow,
            %{next_incoming_id: 5, incoming_window: 1000, next_outgoing_id: 7, outgoing_window: 1000, handle: 1, delivery_count: 0, link_credit: 10, drain: false, echo: true}
          })
        )

      assert {:ok, {:described, 0x13, fields}, <<>>} = PrimitiveCodec.decode(body)

      # trailing null (properties) is omitted
      assert fields == [5, 1000, 7, 1000, 1, 0, 10, nil, false, true]
    end

    test "disposition: role, first, last, settled, state, batchable" do
      body =
        frame_body(
          FrameCodec.encode_frame(:amqp, 0, {
            :disposition,
            %{role: true, first: 3, last: 5, settled: true, state: :accepted}
          })
        )

      # trailing null batchable omitted
      assert {:ok, {:described, 0x15, [true, 3, 5, true, {:described, 0x24, []}]}, <<>>} =
               PrimitiveCodec.decode(body)
    end
  end

  describe "settlement outcomes (OASIS 2.7.6 delivery states)" do
    test "accepted 0x24 / released 0x26 empty bodies; rejected 0x25 carries error list; modified 0x27 field set" do
      for {state, desc} <- [:accepted, :released] do
        body = frame_body(disposition_frame(%{role: true, first: 1, state: state}))

        assert {:ok, {:described, 0x15, [true, 1, nil, nil, {:described, ^desc, []}]}, <<>>} =
                 PrimitiveCodec.decode(body)
      end

      body =
        frame_body(
          disposition_frame(%{
            role: true,
            first: 1,
            state: {:rejected, %{condition: "amqp:internal-error", description: "boom", info: %{"k" => 1}}}
          })
        )

      assert {:ok,
              {:described, 0x15,
               [
                 true,
                 1,
                 nil,
                 nil,
                 {:described, 0x25, [{:symbol, "amqp:internal-error"}, "boom", %{"k" => 1}]}
               ]}, <<>>} =
               PrimitiveCodec.decode(body)

      body =
        frame_body(
          disposition_frame(%{role: true, first: 1, state: {:modified, %{delivery_failed: true, undeliverable_here: false}}})
        )

      # modified field set: deliveryFailed, undeliverableHere, annotations(nil
      # retained inside the described body — trailing-null trim applies to the
      # performative list, not described delivery-state bodies)
      assert {:ok, {:described, 0x15, [true, 1, nil, nil, {:described, 0x27, [true, false, nil]}]}, <<>>} =
               PrimitiveCodec.decode(body)
    end
  end

  describe "map count = pairs (OASIS 1.6.9 map encoding)" do
    test "application-properties map8 writes count 2 x entries" do
      payload =
        IO.iodata_to_binary(FrameCodec.encode_message([{:application_properties, %{"a" => 1, "b" => 2}}]))

      # 0x00 desc(0x53 0x74), 0xC1 map8, size, count=4 (2 pairs x 2)
      # uint values 1 and 2 encode as 0x52 (u8); count field = 2 pairs x 2
      assert <<0x00, 0x53, 0x74, 0xC1, 11, 4, 0xA1, 1, "a", 0x52, 1, 0xA1, 1, "b", 0x52, 2>> =
               payload
    end

    test "message_annotations with x-opt keys round-trips" do
      payload =
        IO.iodata_to_binary(
          FrameCodec.encode_message([{:message_annotations, %{"x-opt-sequence-number" => 7}}])
        )

      assert {:ok, {:described, 0x72, %{"x-opt-sequence-number" => 7}}, <<>>} =
               PrimitiveCodec.decode(payload)
    end
  end

  describe "SB extensions" do
    test "session filter descriptor com.microsoft:session-filter inside source" do
      body =
        frame_body(
          FrameCodec.encode_frame(:amqp, 0, {
            :attach,
            %{
              name: "s",
              handle: 0,
              role: true,
              source: %{address: "q", filter: %{"com.microsoft:session-filter" => {:session_filter, "sess-1"}}}
            }
          })
        )

      assert {:ok, {:described, 0x12, fields}, <<>>} = PrimitiveCodec.decode(body)

      {:described, 0x28, src} = Enum.at(fields, 5)

      # filter-set is a MAP of filter-name -> described filter instance
      assert %{"com.microsoft:session-filter" =>
               {:described, {:symbol, "com.microsoft:session-filter"}, "sess-1"}} = Enum.at(src, 7)
    end

    test "locked-until-utc filetime conversion (100ns ticks since 0001-01-01)" do
      assert DeliveryEncoder.filetime_from_ms(0) == 621_355_968_000_000_000

      # 2023-11-14T22:13:20Z = 1_700_000_000_000 epoch ms
      assert DeliveryEncoder.filetime_from_ms(1_700_000_000_000) == 638_355_968_000_000_000

      sections = DeliveryEncoder.build_sections(sequence_number: 1, locked_until: 1_700_000_000_000)
      annotations = sections.message_annotations

      assert annotations["com.microsoft:locked-until-utc"] == 638_355_968_000_000_000
      assert annotations["x-opt-locked-until"] == {:timestamp, 1_700_000_000_000}
      assert annotations["x-opt-sequence-number"] == 1
    end

    test "delivery-count present in broker flow grant (rhea sender-credit contract)" do
      # FrameCodec field order must keep delivery_count at index 5 so the
      # broker's grant flow (Connection handle_attach) encodes it positionally.
      body =
        frame_body(
          FrameCodec.encode_frame(:amqp, 0, {
            :flow,
            %{next_incoming_id: 0, incoming_window: 10_000, next_outgoing_id: 0, outgoing_window: 10_000, handle: 0, delivery_count: 0, link_credit: 1000}
          })
        )

      assert {:ok, {:described, 0x13, [0, 10_000, 0, 10_000, 0, 0, 1000 | _]}, <<>>} =
               PrimitiveCodec.decode(body)
    end

    test "delivery annotations carry x-opt-enqueued-time-utc as timestamp and session id as binary" do
      sections =
        DeliveryEncoder.build_sections(
          sequence_number: 3,
          enqueued_time: 1_700_000_000_000,
          session_id: "sess-c5"
        )

      annotations = sections.message_annotations
      assert annotations["x-opt-enqueued-time-utc"] == {:timestamp, 1_700_000_000_000}
      assert annotations["x-opt-session-id"] == "sess-c5"

      payload =
        IO.iodata_to_binary(FrameCodec.encode_message([{:message_annotations, annotations}]))

      assert {:ok, {:described, 0x72, decoded}, <<>>} = PrimitiveCodec.decode(payload)

      assert decoded["x-opt-enqueued-time-utc"] == {:timestamp, 1_700_000_000_000}
      assert decoded["x-opt-session-id"] == "sess-c5"
    end
  end

  # ===========================================================================
  # Tier 2: live session round-trip over a real socket
  # ===========================================================================

  describe "live broker session" do
    setup do
      port = get_free_port()

      SmaltTest.Lifecycle.stop_shared_tree()

      Application.put_env(:smalt, :arm_port, get_free_port())
      Application.put_env(:smalt, :egress_port, get_free_port())
      Application.put_env(:smalt, :amqp_port, port)
      Application.put_env(:smalt, :event_hubs_port, get_free_port())
      Application.put_env(:smalt, :sb_shared_key, Base.encode64(:crypto.strong_rand_bytes(48)))

      on_exit(fn -> Application.delete_env(:smalt, :sb_shared_key) end)

      {:ok, _sup} =
        Supervisor.start_link([Smalt.Store, {Smalt.AmqpBroker, []}],
          strategy: :one_for_one,
          name: Smalt.C5ServicebusTestSup
        )

      on_exit(fn ->
        # bounded stop: connection GenServers block in :gen_tcp.recv and can
        # hang a graceful supervisor shutdown — kill fallback per the
        # SmaltTest.Lifecycle contract (test_helper.exs).
        case Process.whereis(Smalt.C5ServicebusTestSup) do
          nil ->
            :ok

          sup ->
            try do
              Supervisor.stop(sup, :normal, 500)
            catch
              _, _ -> Process.exit(sup, :kill)
            end
        end

        SmaltTest.Lifecycle.restore_app()
        SmaltTest.Lifecycle.ensure_store_up()
      end)

      {:ok, port: port, queue: "c5-queue-#{System.unique_integer([:positive])}"}
    end

    @tag :c5_live
    test "open -> begin -> put-token -> send -> accepted -> receive -> accepted round-trip", %{
      port: port,
      queue: queue
    } do
      c = connect(port) |> handshake() |> authorize(queue)

      # sender link
      c = send_frame(c, {:attach, %{name: "c5-tx", handle: 0, role: false, target: %{address: queue}}})
      c = await_sender_link(c)

      c =
        send_frame(c, {
          :transfer,
          %{handle: 0, delivery_id: 1, delivery_tag: <<1>>, message_format: 0, settled: true, more: false},
          {:sections, [{:properties, %{message_id: "c5-msg-1"}}, {:body_amqp_value, "c5-payload"}]}
        })

      {disp, _c} = await_disposition(c)
      assert disp.state == :accepted
      assert disp.first == 1

      # receiver link on the same connection, new handle
      c = send_frame(c, {:attach, %{name: "c5-rx", handle: 1, role: true, source: %{address: queue}}})
      {%{performative: %{performative: :attach}}, c} = next_frame(c)

      c = send_frame(c, {:flow, %{handle: 1, link_credit: 10}})

      {[transfer], c} = collect_transfers(c, 1)
      assert transfer.performative.delivery_tag != nil

      {:ok, sections} = FrameCodec.decode_message(transfer.payload)
      props = Enum.find(sections, &match?({:properties, _}, &1))

      assert match?({:properties, %{message_id: "c5-msg-1"}}, props)

      # settle accepted
      id = transfer.performative.delivery_id

      send_frame(c, {:disposition, %{role: true, first: id, last: id, settled: true, state: :accepted}})
      :gen_tcp.close(c.sock)
    end

    @tag :c5_live
    test "unauthorized entity attach gets detach with amqp:unauthorized-access", %{port: port} do
      c = connect(port) |> handshake()

      # fresh CbsRouter with NO claim for this audience -> unauthorized
      if GenServer.whereis(Smalt.Amqp.CbsRouter) do
        GenServer.stop(Smalt.Amqp.CbsRouter)
      end

      {:ok, _} = GenServer.start(Smalt.Amqp.CbsRouter, [], name: Smalt.Amqp.CbsRouter)

      c = send_frame(c, {:attach, %{name: "nope", handle: 0, role: true, source: %{address: "c5-no-auth"}}})

      {detach, _c} = await_performative(c, :detach)
      # error decodes as the positional list [condition(symbol), description, info]
      assert [{:symbol, "amqp:unauthorized-access"}, "UNAUTHORIZED_ENTITY", nil] = detach.error
    end

    @tag :c5_live
    test "second acceptSession on a locked session gets com.microsoft:session-cannot-be-locked", %{
      port: port,
      queue: queue
    } do
      c = connect(port) |> handshake() |> authorize(queue)

      # enqueue a session message
      c = send_frame(c, {:attach, %{name: "s-tx", handle: 0, role: false, target: %{address: queue}}})
      c = await_sender_link(c)

      c =
        send_frame(c, {
          :transfer,
          %{handle: 0, delivery_id: 1, delivery_tag: <<1>>, message_format: 0, settled: true, more: false},
          {:sections, [{:properties, %{group_id: "sess-c5"}}, {:body_amqp_value, "s"}]}
        })

      {_disp, c} = await_disposition(c)

      # first acceptSession acquires the lock
      c =
        send_frame(c, {
          :attach,
          %{name: "s-rx-1", handle: 1, role: true, source: %{address: queue, filter: %{"com.microsoft:session-filter" => {:session_filter, "sess-c5"}}}}
        })

      {%{performative: %{performative: :attach}}, c} = next_frame(c)

      # second acceptSession on the same session id -> session-cannot-be-locked
      c = send_frame(c, {:attach, %{name: "s-rx-2", handle: 2, role: true, source: %{address: queue, filter: %{"com.microsoft:session-filter" => {:session_filter, "sess-c5"}}}}})

      # Was GAP R9 (docs/compliance/C5_SERVICEBUS.md), fixed:
      # decode_source_target/1 now unwraps the {:described, ...} wrapper on the
      # selector, so extract_session_filter/1 yields the raw binary and
      # handle_attach engages session locking. The broker answers the second
      # acceptSession with a detach carrying the real Service Bus error.
      {detach, _c} = await_performative(c, :detach)
      assert detach.handle == 2
      assert [{:symbol, "com.microsoft:session-cannot-be-locked"}, "SESSION_CANNOT_BE_LOCKED", nil] =
               detach.error
    end
  end

  # ===========================================================================
  # Helpers
  # ===========================================================================

  defp disposition_frame(fields), do: FrameCodec.encode_frame(:amqp, 0, {:disposition, fields})


  defp frame_body(frame) do
    <<_::binary-size(8), body::binary>> = IO.iodata_to_binary(frame)
    body
  end

  defp get_free_port do
    {:ok, sock} = :gen_tcp.listen(0, [:binary, active: false])
    {:ok, port} = :inet.port(sock)
    :gen_tcp.close(sock)
    port
  end

  defp connect(port) do
    {:ok, sock} = :gen_tcp.connect(~c"127.0.0.1", port, [:binary, packet: :raw, active: false], 5_000)
    %{sock: sock, buf: <<>>}
  end

  defp authorize(c, queue) do
    audience = Smalt.Amqp.SasVerifier.endpoint() <> "/" <> queue
    key = Application.fetch_env!(:smalt, :sb_shared_key)
    se = System.system_time(:second) + 600
    enc_sr = URI.encode_www_form(audience)

    sig =
      :crypto.mac(:hmac, :sha256, key, "#{enc_sr}\n#{se}")
      |> Base.encode64()
      |> URI.encode_www_form()

    token = "SharedAccessSignature sr=#{enc_sr}&sig=#{sig}&se=#{se}&skn=RootManageSharedAccessKey"

    c = send_frame(c, {:attach, %{name: "cbs-tx", handle: 2, role: false, target: %{address: "$cbs"}}})
    c = send_frame(c, {:attach, %{name: "cbs-rx", handle: 3, role: true, source: %{address: "$cbs"}}})

    send_frame(c, {
      :transfer,
      %{handle: 2, delivery_id: 100, delivery_tag: <<100>>, message_format: 0, settled: true, more: false},
      {:sections, [
        {:application_properties, %{"operation" => "put-token", "type" => @cbs_type, "name" => audience}},
        {:body_amqp_value, token}
      ]}
    })

    wait_cbs_reply(c, 60)
  end

  defp wait_cbs_reply(_c, 0), do: flunk("no $cbs put-token reply arrived")

  defp wait_cbs_reply(c, n) do
    case pop_frame(c.buf) do
      {:ok, %{performative: %{performative: :transfer}} = f, rest} ->
        {:ok, sections} = FrameCodec.decode_message(f.payload)

        if Enum.any?(sections, fn
             {:application_properties, %{"statusCode" => 200}} -> true
             {:application_properties, %{"status-code" => 200}} -> true
             _ -> false
           end) do
          %{c | buf: rest}
        else
          wait_cbs_reply(%{c | buf: rest}, n - 1)
        end

      {:ok, _other, rest} ->
        wait_cbs_reply(%{c | buf: rest}, n)

      :incomplete ->
        assert {:ok, data} = :gen_tcp.recv(c.sock, 0, @recv_timeout)
        wait_cbs_reply(%{c | buf: <<c.buf::binary, data::binary>>}, n)
    end
  end

  defp handshake(c) do
    :ok = :gen_tcp.send(c.sock, @sasl_header)
    {:ok, @sasl_header, c} = recv_exact(c, 8)

    {%{performative: %{performative: :sasl_mechanisms}}, c} = next_frame(c)
    c = send_frame(c, {:sasl_init, %{mechanism: "ANONYMOUS"}})
    {%{performative: %{performative: :sasl_outcome, code: 0}}, c} = next_frame(c)

    :ok = :gen_tcp.send(c.sock, @header)
    {:ok, @header, c} = recv_exact(c, 8)

    c = send_frame(c, {:open, %{container_id: "c5-client", max_frame_size: 65_536, channel_max: 65_535}})
    {%{performative: %{performative: :open}}, c} = next_frame(c)

    c =
      send_frame(c, {:begin, %{next_outgoing_id: 1, incoming_window: 10_000, outgoing_window: 10_000, handle_max: 100}})

    {%{performative: %{performative: :begin}}, c} = next_frame(c)

    c
  end

  defp send_frame(%{sock: sock} = c, {name, fields}) do
    layer = if name in [:sasl_init, :sasl_mechanisms, :sasl_outcome], do: :sasl, else: :amqp
    :ok = :gen_tcp.send(sock, FrameCodec.encode_frame(layer, 0, {name, fields}))
    c
  end

  defp send_frame(%{sock: sock} = c, {:transfer, fields, {:sections, _} = sections}) do
    :ok = :gen_tcp.send(sock, FrameCodec.encode_frame(:amqp, 0, {:transfer, fields, sections}))
    c
  end

  defp recv_exact(c, n) do
    case c.buf do
      <<got::binary-size(n), rest::binary>> ->
        {:ok, got, %{c | buf: rest}}

      _ ->
        assert {:ok, data} = :gen_tcp.recv(c.sock, 0, @recv_timeout)
        recv_exact(%{c | buf: <<c.buf::binary, data::binary>>}, n)
    end
  end

  defp next_frame(c, timeout \\ @recv_timeout) do
    case pop_frame(c.buf) do
      {:ok, frame, rest} ->
        {frame, %{c | buf: rest}}

      :incomplete ->
        assert {:ok, data} = :gen_tcp.recv(c.sock, 0, timeout)
        next_frame(%{c | buf: <<c.buf::binary, data::binary>>}, timeout)
    end
  end

  defp await_performative(c, name), do: do_await_performative(c, name, 100)

  defp do_await_performative(_c, name, 0), do: flunk("no #{inspect(name)} frame arrived")

  defp do_await_performative(c, name, n) do
    case pop_frame(c.buf) do
      {:ok, %{performative: %{performative: ^name}} = f, rest} ->
        {f.performative, %{c | buf: rest}}

      {:ok, _other, rest} ->
        do_await_performative(%{c | buf: rest}, name, n - 1)

      :incomplete ->
        assert {:ok, data} = :gen_tcp.recv(c.sock, 0, @recv_timeout)
        do_await_performative(%{c | buf: <<c.buf::binary, data::binary>>}, name, n - 1)
    end
  end

  defp await_sender_link(c), do: do_await_sender_link(c, false, false)

  defp do_await_sender_link(c, a?, f?) do
    cond do
      a? and f? ->
        c

      true ->
        case pop_frame(c.buf) do
          {:ok, %{performative: %{performative: :attach}}, rest} ->
            do_await_sender_link(%{c | buf: rest}, true, f?)

          {:ok, %{performative: %{performative: :flow}}, rest} ->
            do_await_sender_link(%{c | buf: rest}, a?, true)

          {:ok, _other, rest} ->
            do_await_sender_link(%{c | buf: rest}, a?, f?)

          :incomplete ->
            assert {:ok, data} = :gen_tcp.recv(c.sock, 0, @recv_timeout)
            do_await_sender_link(%{c | buf: <<c.buf::binary, data::binary>>}, a?, f?)
        end
    end
  end

  defp await_disposition(c), do: do_await_disposition(c, 100)

  defp do_await_disposition(_c, 0), do: flunk("no disposition frame arrived")

  defp do_await_disposition(c, n) do
    case pop_frame(c.buf) do
      {:ok, %{performative: %{performative: :disposition}} = f, rest} ->
        {f.performative, %{c | buf: rest}}

      {:ok, _other, rest} ->
        do_await_disposition(%{c | buf: rest}, n - 1)

      :incomplete ->
        assert {:ok, data} = :gen_tcp.recv(c.sock, 0, @recv_timeout)
        do_await_disposition(%{c | buf: <<c.buf::binary, data::binary>>}, n - 1)
    end
  end

  defp collect_transfers(c, n), do: do_collect(c, n, [])

  defp do_collect(c, n, acc) when length(acc) >= n, do: {Enum.reverse(acc), c}

  defp do_collect(c, n, acc) do
    case pop_frame(c.buf) do
      {:ok, %{performative: %{performative: :transfer}} = frame, rest} ->
        do_collect(%{c | buf: rest}, n, [frame | acc])

      {:ok, _other, rest} ->
        do_collect(%{c | buf: rest}, n, acc)

      :incomplete ->
        assert {:ok, data} = :gen_tcp.recv(c.sock, 0, @recv_timeout)
        do_collect(%{c | buf: <<c.buf::binary, data::binary>>}, n, acc)
    end
  end

  defp pop_frame(buf) do
    case FrameCodec.decode_frame(buf) do
      {:ok, frame} ->
        <<size::32, _::binary>> = buf
        {:ok, frame, binary_part(buf, size, byte_size(buf) - size)}

      {:more, _} ->
        :incomplete

      {:error, reason} ->
        raise "frame decode error: #{inspect(reason)}"
    end
  end
end
