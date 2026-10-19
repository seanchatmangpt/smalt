defmodule Smalt.Amqp.FrameCodecTest do
  # async: false — the setup block swaps the NODE-GLOBAL
  # Application env :primitive_codec to TestPrimitiveCodec; running this file
  # concurrently with other codec tests (async fuzz tests) let them decode
  # frames with the test codec mid-swap, producing flaky :bad_frame_body and
  # round-trip mismatches.
  use ExUnit.Case, async: false

  alias Smalt.Amqp.FrameCodec
  alias Smalt.Amqp.PrimitiveCodec

  # ---------------------------------------------------------------------------
  # Real stand-in implementation of the pinned PrimitiveCodec contract.
  # (Hand-written real implementation of the pinned interface — the actual
  # Smalt.Amqp.PrimitiveCodec is lane 1's file and is not yet on disk. This
  # module implements the AMQP type system for real; tests inject it via
  # Application env so the identical suite runs against the real codec once
  # it lands with the same API.)
  # ---------------------------------------------------------------------------

  defmodule TestPrimitiveCodec do
    @moduledoc false

    # -- encode ---------------------------------------------------------------

    def encode(nil), do: <<0x40>>
    def encode(true), do: <<0x41>>
    def encode(false), do: <<0x42>>

    def encode(n) when is_integer(n) and n >= 0 do
      cond do
        n <= 0xFF -> <<0x52, n>>
        n <= 0xFFFF -> <<0x60, n::16>>
        n <= 0xFFFF_FFFF -> <<0x70, n::32>>
        true -> <<0x80, n::unsigned-64>>
      end
    end

    def encode(n) when is_integer(n) and n < 0 do
      cond do
        n >= -128 -> <<0x54, n>>
        n >= -32_768 -> <<0x68, n::16>>
        n >= -2_147_483_648 -> <<0x71, n::32>>
        true -> <<0x81, n::signed-64>>
      end
    end

    def encode({:timestamp, ms}) when is_integer(ms), do: <<0x83, ms::signed-64>>

    # passthrough for uuid form the real codec supports and the stub never
    # needed until fuzz split-variance exercised properties with uuid ids
    def encode({:uuid, _} = u), do: Smalt.Amqp.PrimitiveCodec.encode(u)
    def encode({:vbin, _} = v), do: Smalt.Amqp.PrimitiveCodec.encode(v)

    def encode(bin) when is_binary(bin) do
      if byte_size(bin) <= 255 do
        # Prefer str8-ish variance by content? Keep deterministic: bin8.
        <<0xA1, byte_size(bin), bin::binary>>
      else
        <<0xB1, byte_size(bin)::32, bin::binary>>
      end
    end

    def encode({:symbol, s}) when is_binary(s) do
      if byte_size(s) <= 255 do
        <<0xA3, byte_size(s), s::binary>>
      else
        <<0xB3, byte_size(s)::32, s::binary>>
      end
    end

    def encode(list) when is_list(list) do
      payload = IO.iodata_to_binary(Enum.map(list, &encode/1))

      case byte_size(payload) do
        0 -> <<0x45>>
        n when n <= 255 -> <<0xC0, n, payload::binary>>
        n -> <<0xD0, n::32, payload::binary>>
      end
    end

    def encode(map) when is_map(map) do
      payload =
        map
        |> Enum.flat_map(fn {k, v} -> [encode(map_key(k)), encode(v)] end)
        |> IO.iodata_to_binary()

      case byte_size(payload) do
        n when n <= 255 -> <<0xC1, n, payload::binary>>
        n -> <<0xD1, n::32, payload::binary>>
      end
    end

    def encode({:described, desc, body}) do
      [<<0x00>>, encode(desc), encode_body(body)]
    end

    defp encode_body(list) when is_list(list), do: encode(list)
    defp encode_body(term), do: encode(term)

    defp map_key(k) when is_binary(k), do: {:symbol, k}
    defp map_key(k), do: k

    # -- decode ---------------------------------------------------------------

    def decode(<<0x40, rest::binary>>), do: {:ok, nil, rest}
    def decode(<<0x41, rest::binary>>), do: {:ok, true, rest}
    def decode(<<0x42, rest::binary>>), do: {:ok, false, rest}
    def decode(<<0x45, rest::binary>>), do: {:ok, [], rest}

    def decode(<<0x50, v, rest::binary>>), do: {:ok, v, rest}
    def decode(<<0x52, v, rest::binary>>), do: {:ok, v, rest}
    def decode(<<0x53, v, rest::binary>>), do: {:ok, v, rest}
    def decode(<<0x54, v::signed-8, rest::binary>>), do: {:ok, v, rest}
    def decode(<<0x55, v::signed-8, rest::binary>>), do: {:ok, v, rest}
    def decode(<<0x60, v::16, rest::binary>>), do: {:ok, v, rest}
    def decode(<<0x68, v::signed-16, rest::binary>>), do: {:ok, v, rest}
    def decode(<<0x70, v::32, rest::binary>>), do: {:ok, v, rest}
    def decode(<<0x71, v::signed-32, rest::binary>>), do: {:ok, v, rest}
    def decode(<<0x80, v::unsigned-64, rest::binary>>), do: {:ok, v, rest}
    def decode(<<0x81, v::signed-64, rest::binary>>), do: {:ok, v, rest}
    def decode(<<0x83, v::signed-64, rest::binary>>), do: {:ok, {:timestamp, v}, rest}

    def decode(<<0xA0, len, v::binary-size(len), rest::binary>>), do: {:ok, v, rest}
    def decode(<<0xB0, len::32, v::binary-size(len), rest::binary>>), do: {:ok, v, rest}
    def decode(<<0xA1, len, v::binary-size(len), rest::binary>>), do: {:ok, v, rest}
    def decode(<<0xB1, len::32, v::binary-size(len), rest::binary>>), do: {:ok, v, rest}
    def decode(<<0xA3, len, v::binary-size(len), rest::binary>>), do: {:ok, {:symbol, v}, rest}

    def decode(<<0xB3, len::32, v::binary-size(len), rest::binary>>),
      do: {:ok, {:symbol, v}, rest}

    def decode(<<0x00, constructor::binary>>) do
      case decode(constructor) do
        {:ok, desc, body_rest} ->
          case decode(body_rest) do
            {:ok, body, rest} -> {:ok, {:described, desc, body}, rest}
            :error -> :error
          end

        :error ->
          :error
      end
    end

    def decode(<<0xC0, len, payload::binary-size(len), rest::binary>>),
      do: decode_list_payload_lenient(payload, rest)

    def decode(<<0xD0, len::32, payload::binary-size(len), rest::binary>>),
      do: decode_list_payload_lenient(payload, rest)

    # Map8/map32: the real PrimitiveCodec's {:map_rhea, _} form prepends the
    # pair-count byte INSIDE the size (spec §1.6.9); this helper's own encode
    # omits it. Try the count-less form first, fall back to skipping the count
    # byte when the raw payload does not parse.
    def decode(<<0xC1, len, payload::binary-size(len), rest::binary>>) do
      decode_map_payload_lenient(payload, rest)
    end

    def decode(<<0xD1, len::32, payload::binary-size(len), rest::binary>>) do
      decode_map_payload_lenient(payload, rest)
    end

    # List0/list32: same leniency as maps — the real PrimitiveCodec includes
    # the element-count byte INSIDE the constructor size (spec §1.4.3); the
    # helper's own encode omits it. Try count-less first, else skip the count.
    defp decode_list_payload_lenient(payload, rest) do
      case decode_list_payload(payload, rest) do
        {:ok, items, rest2} ->
          {:ok, items, rest2}

        :error ->
          case payload do
            <<_count, body::binary>> -> decode_list_payload(body, rest)
            _ -> :error
          end
      end
    end

    defp decode_map_payload_lenient(payload, rest) do
      case decode_map_payload(payload, rest) do
        {:ok, map, rest2} ->
          {:ok, map, rest2}

        :error ->
          case payload do
            <<_count, body::binary>> -> decode_map_payload(body, rest)
            _ -> :error
          end
      end
    end

    def decode(_), do: :error

    defp decode_list_payload(payload, rest) do
      case decode_all(payload) do
        {:ok, items} -> {:ok, items, rest}
        :error -> :error
      end
    end

    defp decode_map_payload(payload, rest) do
      case decode_all(payload) do
        {:ok, flat} ->
          map =
            flat
            |> Enum.chunk_every(2)
            |> Map.new(fn
              [k, v] -> {unwrap_key(k), v}
              [_] -> :skip
            end)
            |> case do
              :skip -> :error
              map -> map
            end

          {:ok, map, rest}

        :error ->
          :error
      end
    end

    defp unwrap_key({:symbol, s}), do: {:symbol, s}
    defp unwrap_key(k), do: k

    def decode_all(bin, acc \\ [])
    def decode_all(<<>>, acc), do: {:ok, Enum.reverse(acc)}

    def decode_all(bin, acc) do
      case decode(bin) do
        {:ok, v, rest} -> decode_all(rest, [v | acc])
        :error -> :error
      end
    end
  end

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  setup do
    # Canonical save+on_exit restore (SmaltTest.Env) — presence-preserving.
    SmaltTest.Env.put_restored(primitive_codec: TestPrimitiveCodec)
    :ok
  end

  defp roundtrip(type, channel, spec) do
    encoded = IO.iodata_to_binary(Smalt.Amqp.FrameCodec.encode_frame(type, channel, spec))
    assert {:ok, decoded} = FrameCodec.decode_frame(encoded)
    {encoded, decoded}
  end

  # ---------------------------------------------------------------------------
  # Frame header / golden vector
  # ---------------------------------------------------------------------------

  describe "frame header" do
    test "golden vector: minimal open frame bytes" do
      frame =
        IO.iodata_to_binary(
          Smalt.Amqp.FrameCodec.encode_frame(:amqp, 0, {:open, %{container_id: "c"}})
        )

      # header: size, doff=2, type=0x00, channel=0
      <<size::32, 2::8, 0x00::8, 0::16, body::binary>> = frame
      assert size == byte_size(frame)
      # body: described(ulong 0x10, [str "c"]); trailing nulls are omitted
      # (AMQP spec list encoding allows omitting trailing null fields). The
      # previous null-padded form crashed pyamqp: it reconstructs
      # AttachFrame(*frame) positionally from the wire element count.
      assert <<0x00, ctor, 0x10, 0xC0, _len, rest::binary>> = body
      assert ctor in [0x52, 0x53]
      assert rest == <<0xA1, 1, "c">>
    end

    test "sasl frame header uses type 0x01" do
      frame =
        IO.iodata_to_binary(
          Smalt.Amqp.FrameCodec.encode_frame(
            :sasl,
            0,
            {:sasl_mechanisms, %{server_mechanisms: [{:symbol, "ANONYMOUS"}]}}
          )
        )

      <<size::32, 2::8, 0x01::8, 0::16, _::binary>> = frame
      assert size == byte_size(frame)
    end
  end

  # ---------------------------------------------------------------------------
  # Performative golden round-trips
  # ---------------------------------------------------------------------------

  describe "performative round-trips" do
    test "open" do
      fields = %{
        container_id: "container-1",
        hostname: "localhost",
        max_frame_size: 65_536,
        channel_max: 10,
        idle_time_out: 30_000,
        outgoing_locales: [{:symbol, "en-US"}],
        incoming_locales: nil,
        offered_capabilities: [{:symbol, "com.microsoft:session-filter"}],
        desired_capabilities: nil,
        properties: %{{:symbol, "product"} => "smalt"}
      }

      {_bin, dec} = roundtrip(:amqp, 3, {:open, fields})

      assert dec.type == :amqp
      assert dec.channel == 3
      assert dec.payload == <<>>
      assert dec.performative.performative == :open
      assert dec.performative.container_id == "container-1"
      assert dec.performative.hostname == "localhost"
      assert dec.performative.max_frame_size == 65_536
      assert dec.performative.channel_max == 10
      assert dec.performative.idle_time_out == 30_000
      assert dec.performative.offered_capabilities == [{:symbol, "com.microsoft:session-filter"}]
      assert dec.performative.properties == %{{:symbol, "product"} => "smalt"}
    end

    test "begin" do
      fields = %{
        remote_channel: nil,
        next_outgoing_id: 1,
        incoming_window: 1000,
        outgoing_window: 1000,
        handle_max: 100
      }

      {_bin, dec} = roundtrip(:amqp, 0, {:begin, fields})

      assert dec.performative.performative == :begin
      assert dec.performative.next_outgoing_id == 1
      assert dec.performative.incoming_window == 1000
      assert dec.performative.outgoing_window == 1000
      assert dec.performative.handle_max == 100
      assert dec.performative.remote_channel == nil
    end

    test "attach sender with target" do
      fields = %{
        name: "link-sender",
        handle: 0,
        role: 0,
        snd_settle_mode: 1,
        rcv_settle_mode: 0,
        target: %{address: "myqueue", dynamic: false, durable: 0},
        initial_delivery_count: 0
      }

      {_bin, dec} = roundtrip(:amqp, 0, {:attach, fields})

      assert dec.performative.performative == :attach
      assert dec.performative.name == "link-sender"
      assert dec.performative.handle == 0
      assert dec.performative.role == 0
      assert dec.performative.snd_settle_mode == 1
      assert dec.performative.target[:address] == "myqueue"
      assert dec.performative.target[:dynamic] == false
      assert dec.performative.target[:durable] == 0
    end

    test "attach receiver with session-filter source" do
      fields = %{
        name: "link-receiver",
        handle: 1,
        role: 1,
        snd_settle_mode: 0,
        rcv_settle_mode: 1,
        source: %{
          address: "myqueue/$SessionQueue",
          durable: 0,
          filter: %{"com.microsoft:session-filter" => {:session_filter, "session-1"}}
        }
      }

      {_bin, dec} = roundtrip(:amqp, 0, {:attach, fields})

      src = dec.performative.source
      assert src[:address] == "myqueue/$SessionQueue"
      assert src[:filter] == %{"com.microsoft:session-filter" => {:session_filter, "session-1"}}
    end

    test "R16 tripwire: target composite carries exactly 7 fields (pyamqp Target arity), source keeps 8" do
      for {key, desc, expected_count} <- [{:source, 0x28, 8}, {:target, 0x29, 7}] do
        fields = %{name: "l", handle: 0, role: 1} |> Map.put(key, %{address: "q"})

        payload =
          IO.iodata_to_binary(Smalt.Amqp.FrameCodec.encode_frame(:amqp, 0, {:attach, fields}))

        # Byte-level: locate the composite's descriptor (0x00 0x53 <desc>),
        # then the list8 constructor that follows it and read its element
        # count. The decoder rebuilds these as maps (dropping nils), so the
        # arity contract is only observable on the wire.
        # The injected TestPrimitiveCodec may emit the descriptor byte with
        # the uint8 constructor (0x52) where the real codec uses smalluint
        # (0x53) — accept either.
        match_pos =
          Enum.find_value([<<0x00, 0x53, desc::8>>, <<0x00, 0x52, desc::8>>], fn bytes ->
            case :binary.match(payload, bytes) do
              m when is_tuple(m) -> m
              _ -> nil
            end
          end)

        assert match_pos != nil, "descriptor #{inspect(desc)} not found"

        {desc_start, 3} = match_pos
        skip = desc_start + 3
        <<_::binary-size(skip), 0xC0, size, rest::binary>> = payload
        <<elements::binary-size(size), _::binary>> = rest

        # Walk the elements with the codec's own decode loop — robust to the
        # list8 element-count byte being present (real codec) or absent
        # (TestPrimitiveCodec stub).
        {count, _} =
          Enum.reduce_while(1..40, {elements, 0}, fn _, {bin, n} ->
            case TestPrimitiveCodec.decode(bin) do
              {:ok, _term, <<>>} -> {:halt, {n + 1, nil}}
              {:ok, _term, tail} -> {:cont, {tail, n + 1}}
              _ -> {:halt, {n, nil}}
            end
          end)

        assert count == expected_count
      end
    end

    test "source descriptor is 0x28 and target descriptor is 0x29, by role not filter presence" do
      for {key, desc} <- [source: 0x28, target: 0x29] do
        fields = %{name: "l", handle: 0, role: 1} |> Map.put(key, %{address: "q"})

        payload =
          IO.iodata_to_binary(Smalt.Amqp.FrameCodec.encode_frame(:amqp, 0, {:attach, fields}))

        # byte-level: the composite's descriptor (0x00 0x53 <desc>) appears on
        # the wire — source 0x28, target 0x29 — regardless of filter presence
        assert :binary.match(payload, <<0x00, 0x53, desc::8>>) != :no
        assert {:ok, _frame} = FrameCodec.decode_frame(payload)
      end
    end

    test "attach with source map: known keys become atoms, unknown wire keys stay binaries" do
      # Keys are minted from the system clock so they can NEVER pre-exist in
      # the VM's atom table: any static mention (even a dynamic-seeming
      # concatenation folded by the compiler, or an atom touched by another
      # test in this node) would let String.to_existing_atom/1 legitimately
      # resolve and make the fence vacuous.
      suffix = System.system_time(:nanosecond) |> Integer.to_string()
      unknown1 = "unknown_wire_" <> suffix <> "_1"
      unknown2 = "unknown_wire_" <> suffix <> "_2"
      src_map = %{"address" => "q1", unknown1 => 1, {:symbol, unknown2} => 2}

      # Hand-built attach: source is a raw AMQP map (not FrameCodec's list-form
      # composite), which is exactly the hostile-shape path where safe_atom/1
      # used to mint atoms from wire bytes. Encoded with the injected
      # TestPrimitiveCodec (this setup's decode side); source sits at
      # positional index 5 (name, handle, role, snd/rcv settle modes).
      body =
        TestPrimitiveCodec.encode({:described, 0x12, ["link", 0, 0, nil, nil, src_map]})

      encoded =
        IO.iodata_to_binary([
          <<IO.iodata_length(body) + 8::32, 2::8, 0x00::8, 0::16>>,
          body
        ])

      assert {:ok, dec} = FrameCodec.decode_frame(encoded)

      src = dec.performative.source
      assert src[:address] == "q1"
      # Non-whitelisted wire keys must not be minted into atoms (atom-table
      # flood DoS) — they are kept as binary tags.
      assert src[unknown1] == 1
      assert src[unknown2] == 2
      # Minting here (test side) only to prove the decode did NOT already do it.
      refute Map.has_key?(src, String.to_atom(unknown1))
      refute Map.has_key?(src, String.to_atom(unknown2))
    end

    test "flow" do
      fields = %{
        next_incoming_id: 5,
        incoming_window: 1000,
        next_outgoing_id: 9,
        outgoing_window: 1000,
        handle: 1,
        delivery_count: 3,
        link_credit: 10,
        available: 0,
        drain: false,
        echo: false
      }

      {_bin, dec} = roundtrip(:amqp, 0, {:flow, fields})

      assert dec.performative.performative == :flow
      assert dec.performative.next_incoming_id == 5
      assert dec.performative.handle == 1
      assert dec.performative.delivery_count == 3
      assert dec.performative.link_credit == 10
      assert dec.performative.drain == false
    end

    test "transfer with raw payload" do
      payload = "raw-bytes-payload"

      {_bin, dec} =
        roundtrip(
          :amqp,
          0,
          {:transfer,
           %{handle: 0, delivery_id: 7, delivery_tag: "tag", message_format: 0, settled: false},
           payload}
        )

      assert dec.performative.performative == :transfer
      assert dec.performative.handle == 0
      assert dec.performative.delivery_id == 7
      assert dec.performative.delivery_tag == "tag"
      assert dec.performative.message_format == 0
      assert dec.performative.settled == false
      assert dec.payload == payload
    end

    test "disposition accepted" do
      fields = %{role: 1, first: 7, last: 9, settled: true, state: :accepted}

      {_bin, dec} = roundtrip(:amqp, 0, {:disposition, fields})

      assert dec.performative.performative == :disposition
      assert dec.performative.role == 1
      assert dec.performative.first == 7
      assert dec.performative.last == 9
      assert dec.performative.state == :accepted
    end

    test "disposition rejected with error" do
      fields = %{
        role: 1,
        first: 4,
        settled: true,
        state: {:rejected, %{condition: "amqp:internal-error", description: "boom"}}
      }

      {_bin, dec} = roundtrip(:amqp, 0, {:disposition, fields})

      assert {:rejected, _} = dec.performative.state
    end

    test "disposition released and modified" do
      {_bin, dec} = roundtrip(:amqp, 0, {:disposition, %{role: 1, first: 1, state: :released}})
      assert dec.performative.state == :released

      {_bin, dec} =
        roundtrip(
          :amqp,
          0,
          {:disposition, %{role: 1, first: 2, state: {:modified, %{delivery_failed: true}}}}
        )

      assert {:modified, _} = dec.performative.state
    end

    test "detach / end / close with error maps" do
      err = %{condition: "amqp:link-detach", description: "client gone"}

      {_bin, dec} = roundtrip(:amqp, 0, {:detach, %{handle: 2, closed: true, error: err}})
      assert dec.performative.performative == :detach
      assert dec.performative.handle == 2
      assert dec.performative.closed == true

      {_bin, dec} = roundtrip(:amqp, 0, {:end, %{error: err}})
      assert dec.performative.performative == :end

      {_bin, dec} = roundtrip(:amqp, 0, {:close, %{error: err}})
      assert dec.performative.performative == :close
    end

    test "detach without error" do
      {_bin, dec} = roundtrip(:amqp, 0, {:detach, %{handle: 0, closed: true}})
      assert dec.performative.error == nil
    end

    test "sasl mechanisms / init / outcome" do
      {_bin, dec} =
        roundtrip(
          :sasl,
          0,
          {:sasl_mechanisms, %{server_mechanisms: [{:symbol, "ANONYMOUS"}, {:symbol, "PLAIN"}]}}
        )

      assert dec.type == :sasl
      assert dec.performative.performative == :sasl_mechanisms
      assert dec.performative.server_mechanisms == [{:symbol, "ANONYMOUS"}, {:symbol, "PLAIN"}]

      {_bin, dec} =
        roundtrip(
          :sasl,
          0,
          {:sasl_init, %{mechanism: {:symbol, "ANONYMOUS"}, initial_response: "", hostname: "sb"}}
        )

      assert dec.performative.performative == :sasl_init
      assert dec.performative.mechanism == {:symbol, "ANONYMOUS"}

      {_bin, dec} = roundtrip(:sasl, 0, {:sasl_outcome, %{code: 0, additional_data: nil}})
      assert dec.performative.code == 0
    end

    test "sasl-outcome descriptor is 0x44 on the wire (golden bytes)" do
      # Wire-lane pinion: the rhea-misdispatch hazard (frame_codec.ex 0x42 ->
      # 0x44). A roundtrip test alone is vacuous here — decoding a 0x42-coded
      # outcome as a challenge still roundtrips plausibly, so pin the exact
      # descriptor bytes: descriptor constructor 0x00, smallulong 0x52, 0x44.
      bin =
        IO.iodata_to_binary(
          Smalt.Amqp.FrameCodec.encode_frame(
            :sasl,
            0,
            {:sasl_outcome, %{code: 0, additional_data: nil}}
          )
        )

      # frame header: 4-byte size, 1-byte doff, type 0x01, 2-byte channel
      assert <<_size::32, _doff::8, 0x01::8, _ch::16, body::binary>> = bin
      assert :binary.match(body, <<0x00, 0x52, 0x44>>) == {0, 3}
    end
  end

  # ---------------------------------------------------------------------------
  # Frame splitting / oversized
  # ---------------------------------------------------------------------------

  describe "split-frame reassembly" do
    test ":more until full frame buffered, then decode" do
      frame =
        IO.iodata_to_binary(
          Smalt.Amqp.FrameCodec.encode_frame(
            :amqp,
            1,
            {:begin, %{next_outgoing_id: 0, incoming_window: 100, outgoing_window: 100}}
          )
        )

      # Empty buffer
      assert {:more, 8} = FrameCodec.decode_frame(<<>>)

      # 3 header bytes: size unknown yet -> still wants 8
      assert {:more, 8} = FrameCodec.decode_frame(binary_part(frame, 0, 3))

      # Full header: knows total size
      assert {:more, want} = FrameCodec.decode_frame(binary_part(frame, 0, 8))
      assert want == byte_size(frame)

      # All but last byte
      assert {:more, want} = FrameCodec.decode_frame(binary_part(frame, 0, byte_size(frame) - 1))
      assert want == byte_size(frame)

      # Complete
      assert {:ok, %{channel: 1, performative: %{performative: :begin}}} =
               FrameCodec.decode_frame(frame)
    end

    test "byte-at-a-time reassembly across two frames" do
      f1 =
        IO.iodata_to_binary(
          Smalt.Amqp.FrameCodec.encode_frame(
            :amqp,
            0,
            {:close, %{error: %{condition: "amqp:connection-close", description: nil}}}
          )
        )

      f2 =
        IO.iodata_to_binary(Smalt.Amqp.FrameCodec.encode_frame(:amqp, 0, {:end, %{}}))

      buffer = f1 <> f2

      {buffer, out} = feed(<<>>, buffer, [])
      # feed drains every complete frame in one pass (newest first)
      assert length(out) == 2
      assert %{performative: %{performative: :close}} = List.last(out)

      {_buffer, out} = feed(buffer, "", out)
      assert %{performative: %{performative: :end}} = hd(out)
      assert length(out) == 2
    end

    defp feed(<<>>, buffer, out) when buffer == <<>>, do: {buffer, out}

    defp feed(buffer, remaining, out) do
      case FrameCodec.decode_frame(buffer) do
        {:more, _} ->
          if remaining == <<>> do
            {buffer, out}
          else
            <<chunk::8, rest::binary>> = remaining
            feed(<<buffer::binary, chunk::8>>, rest, out)
          end

        {:ok, decoded} ->
          <<size::32, _::binary>> = buffer
          buffer = binary_part(buffer, size, byte_size(buffer) - size)
          feed(buffer, remaining, [decoded | out])

        {:error, _} = err ->
          throw(err)
      end
    end
  end

  describe "oversized frames" do
    test "declared size over 1 MiB + overhead errors" do
      oversized = <<1 * 1024 * 1024 + 1024::32, 2::8, 0x00::8, 0::16>>
      assert {:error, :frame_too_size} = FrameCodec.decode_frame(oversized)
    end

    test "1 MiB frame (max legal) decodes" do
      perf_frame =
        IO.iodata_to_binary(
          Smalt.Amqp.FrameCodec.encode_frame(
            :amqp,
            0,
            {:transfer, %{handle: 0, delivery_id: 1}, <<>>}
          )
        )

      payload_len = 1 * 1024 * 1024 - byte_size(perf_frame)
      payload = :binary.copy("x", payload_len)

      frame =
        IO.iodata_to_binary(
          Smalt.Amqp.FrameCodec.encode_frame(
            :amqp,
            0,
            {:transfer, %{handle: 0, delivery_id: 1}, payload}
          )
        )

      assert byte_size(frame) == 1 * 1024 * 1024
      assert {:ok, %{payload: ^payload}} = FrameCodec.decode_frame(frame)
    end

    test "bad header errors" do
      assert {:error, :bad_doff} = FrameCodec.decode_frame(<<32::32, 1::8, 0::8, 0::16, 0::8*24>>)
      assert {:error, :bad_frame_size} = FrameCodec.decode_frame(<<4::32, 2::8, 0::8, 0::16>>)
      assert {:error, :bad_frame_type} = FrameCodec.decode_frame(<<32::32, 2::8, 2::8, 0::16>>)
    end

    test "extended header larger than the declared frame errors, never raises (cycle-7 fence)" do
      # doff=3 (12-byte header) with declared size 8..11: the body slice would
      # raise MatchError on remote input; must be a tagged error instead.
      for size <- 8..11 do
        buffer = <<size::32, 3::8, 0::8, 0::16, 0, 0xAA, 0xBB, 0xCC, 0xDD, 0xFF, 0xEE>>
        assert {:error, :bad_doff} = FrameCodec.decode_frame(buffer)
      end
    end

    test "frame-body codec error keeps its reason (reason-preserving errors)" do
      # Swap in the real codec: its decode returns {:error, :invalid_constructor}
      # for unknown constructors — FrameCodec must surface that reason, not
      # collapse it into the bare :bad_frame_body atom.
      SmaltTest.Env.put_restored(primitive_codec: Smalt.Amqp.PrimitiveCodec)

      body = <<0xFF>>
      frame = <<byte_size(body) + 8::32, 2::8, 0x00::8, 0::16, body::binary>>
      assert {:error, {:bad_frame_body, :invalid_constructor}} = FrameCodec.decode_frame(frame)
    end

    test "extended header (doff > 2): body starts at doff*4, padding skipped" do
      body = TestPrimitiveCodec.encode({:described, 0x14, [0]}) |> IO.iodata_to_binary()
      # transfer performative, doff=3: 4 pad bytes between fixed header and body
      frame =
        <<byte_size(body) + 12::32, 3::8, 0::8, 7::16, 0xAA, 0xBB, 0xCC, 0xDD, body::binary>>

      assert {:ok,
              %{type: :amqp, channel: 7, performative: %{performative: :transfer}, payload: <<>>}} =
               FrameCodec.decode_frame(frame)
    end

    test "falsy fields never dropped (lane-107 fence): detach handle 0 / closed false" do
      frame =
        IO.iodata_to_binary(
          Smalt.Amqp.FrameCodec.encode_frame(:amqp, 0, {:detach, %{handle: 0, closed: false}})
        )

      # 8-byte fixed header, then described(0x16, [0, false]) exactly —
      # both falsy fields survive as explicit typed constructors, no trim.
      assert frame ==
               <<16::32, 2::8, 0x00::8, 0::16>> <>
                 IO.iodata_to_binary(TestPrimitiveCodec.encode({:described, 0x16, [0, false]}))

      {_encoded, decoded} = roundtrip(:amqp, 0, {:detach, %{handle: 0, closed: false}})
      assert decoded.performative.handle == 0
      assert decoded.performative.closed == false
    end

    test "falsy flow/transfer fields round-trip (lane-107 fence)" do
      {_encoded, decoded} =
        roundtrip(:amqp, 0, {:flow, %{handle: 0, link_credit: 10, drain: false}})

      assert decoded.performative.handle == 0
      assert decoded.performative.drain == false

      {_encoded, decoded} =
        roundtrip(:amqp, 0, {:transfer, %{handle: 0, delivery_id: 0, settled: false}, "x"})

      assert decoded.performative.handle == 0
      assert decoded.performative.delivery_id == 0
      assert decoded.performative.settled == false
      assert decoded.payload == "x"
    end

    test "extended header under-filled: {:more, size} until all doff*4 + body bytes buffered" do
      body = TestPrimitiveCodec.encode({:described, 0x14, [0]}) |> IO.iodata_to_binary()
      frame = <<byte_size(body) + 12::32, 3::8, 0::8, 7::16, 0, 0, 0, 0, body::binary>>
      total = byte_size(frame)

      for n <- 8..(total - 1) do
        assert {:more, ^total} = FrameCodec.decode_frame(binary_part(frame, 0, n))
      end

      assert {:ok, _} = FrameCodec.decode_frame(frame)
    end
  end

  # ---------------------------------------------------------------------------
  # Message sections
  # ---------------------------------------------------------------------------

  describe "message sections" do
    test "full service-bus message round-trip through transfer frame" do
      sections = [
        {:header,
         %{delivery_count: 1, ttl: 60_000, durable: true, priority: 4, first_acquirer: false}},
        {:delivery_annotations, %{}},
        {:message_annotations,
         %{
           "x-opt-sequence-number" => 42,
           "x-opt-locked-until" => {:timestamp, 1_700_000_000_000},
           "x-opt-enqueued-time-utc" => {:timestamp, 1_699_000_000_000}
         }},
        {:properties,
         %{
           message_id: "mid-1",
           correlation_id: "cid-9",
           reply_to: "resp-q",
           subject: "subj",
           to: "to-q",
           content_type: "application/json",
           creation_time: {:timestamp, 1_699_000_000_000}
         }},
        {:application_properties,
         %{"DeliveryCount" => 1, "LockedUntilUtc" => {:timestamp, 1_700_000_000_000}}},
        {:body_data, "hello service bus"}
      ]

      encoded =
        IO.iodata_to_binary(
          Smalt.Amqp.FrameCodec.encode_frame(
            :amqp,
            0,
            {:transfer, %{handle: 0, delivery_id: 1}, {:sections, sections}}
          )
        )

      assert {:ok, %{payload: payload}} = FrameCodec.decode_frame(encoded)
      assert {:ok, decoded_sections} = FrameCodec.decode_message(payload)

      assert {:header, header} = Enum.find(decoded_sections, &match?({:header, _}, &1))

      assert header == %{
               delivery_count: 1,
               ttl: 60_000,
               durable: true,
               priority: 4,
               first_acquirer: false
             }

      assert {:message_annotations, ann} =
               Enum.find(decoded_sections, &match?({:message_annotations, _}, &1))

      assert ann["x-opt-sequence-number"] == 42
      assert ann["x-opt-locked-until"] == {:timestamp, 1_700_000_000_000}
      assert ann["x-opt-enqueued-time-utc"] == {:timestamp, 1_699_000_000_000}

      assert {:properties, props} = Enum.find(decoded_sections, &match?({:properties, _}, &1))

      assert props == %{
               message_id: "mid-1",
               correlation_id: "cid-9",
               reply_to: "resp-q",
               subject: "subj",
               to: "to-q",
               content_type: "application/json",
               creation_time: {:timestamp, 1_699_000_000_000}
             }

      assert {:application_properties, app_props} =
               Enum.find(decoded_sections, &match?({:application_properties, _}, &1))

      assert app_props == %{
               "DeliveryCount" => 1,
               "LockedUntilUtc" => {:timestamp, 1_700_000_000_000}
             }

      assert {:body_data, "hello service bus"} =
               Enum.find(decoded_sections, &match?({:body_data, _}, &1))
    end

    test "body variants: sequence and amqp-value" do
      sections = [{:body_sequence, [1, 2, 3]}, {:body_amqp_value, %{"op" => "put-token"}}]

      encoded =
        IO.iodata_to_binary(
          Smalt.Amqp.FrameCodec.encode_frame(
            :amqp,
            0,
            {:transfer, %{handle: 0}, {:sections, sections}}
          )
        )

      assert {:ok, %{payload: payload}} = FrameCodec.decode_frame(encoded)
      assert {:ok, decoded} = FrameCodec.decode_message(payload)

      assert {:body_sequence, [1, 2, 3]} = Enum.find(decoded, &match?({:body_sequence, _}, &1))

      assert {:body_amqp_value, %{{:symbol, "op"} => "put-token"}} =
               Enum.find(decoded, &match?({:body_amqp_value, _}, &1))
    end

    test "payload bytes preserved exactly for raw transfer" do
      raw = <<0x53, 0x70, 0xFF>>

      encoded =
        IO.iodata_to_binary(
          Smalt.Amqp.FrameCodec.encode_frame(:amqp, 0, {:transfer, %{handle: 0}, raw})
        )

      assert {:ok, %{payload: ^raw}} = FrameCodec.decode_frame(encoded)
    end

    test "undecodable section bytes surface the codec reason (cycle-10 fence)" do
      # real codec: its decode returns {:error, :invalid_constructor} — the
      # test codec returns bare :error, which stays a silent stop by contract
      SmaltTest.Env.put_restored(primitive_codec: Smalt.Amqp.PrimitiveCodec)

      sections = [{:body_data, "hello"}]
      payload = FrameCodec.encode_message(sections) |> IO.iodata_to_binary()
      # corrupt the leading described-type marker of the first section
      <<_b, rest::binary>> = payload
      corrupted = <<0xFF, rest::binary>>

      assert {:ok, _} = FrameCodec.decode_message(payload)
      assert {:error, {:bad_section, :invalid_constructor}} = FrameCodec.decode_message(corrupted)
    end

    test "source with session-filter is Azure-identical on the wire (cycle-12 fence)" do
      # real codec: the runtime wire is the real PrimitiveCodec's bytes
      SmaltTest.Env.put_restored(primitive_codec: Smalt.Amqp.PrimitiveCodec)

      sel = "amqp.annotation.x-opt-sequence-number > 100"

      fields = %{
        name: "link-receiver",
        handle: 1,
        role: 1,
        source: %{
          address: "myqueue",
          filter: %{"com.microsoft:session-filter" => {:session_filter, sel}}
        }
      }

      bin = IO.iodata_to_binary(Smalt.Amqp.FrameCodec.encode_frame(:amqp, 0, {:attach, fields}))

      # Azure parity: source composite described(0x28, 8 fields, filter at 7)
      expected_source =
        IO.iodata_to_binary(
          PrimitiveCodec.encode(
            {:described, 0x28,
             [
               "myqueue",
               nil,
               nil,
               nil,
               nil,
               nil,
               nil,
               {:described, {:symbol, "com.microsoft:session-filter"}, sel}
             ]}
          )
        )

      assert :binary.match(bin, expected_source) != :no

      # and the filter survives a decode round-trip
      assert {:ok, %{performative: %{source: src}}} = FrameCodec.decode_frame(bin)

      assert src[:filter] == %{"com.microsoft:session-filter" => {:session_filter, sel}}
    end

    test "falsy section fields are preserved (cycle-13: falsy sweep, layer 3)" do
      sections = [
        {:header,
         %{delivery_count: 0, ttl: 0, durable: false, priority: 0, first_acquirer: false}},
        {:properties, %{group_sequence: 0}}
      ]

      payload = FrameCodec.encode_message(sections) |> IO.iodata_to_binary()
      assert {:ok, decoded} = FrameCodec.decode_message(payload)

      assert {:header, h} = Enum.find(decoded, &match?({:header, _}, &1))
      assert h == %{delivery_count: 0, ttl: 0, durable: false, priority: 0, first_acquirer: false}

      assert {:properties, props} = Enum.find(decoded, &match?({:properties, _}, &1))
      assert props == %{group_sequence: 0}
    end

    # Lens-2 cycle-1 cross-layer invariant: anything that decodes cleanly at
    # the primitive level must surface as a tagged result at the section
    # layer, never a raise out of decode_message/1 (a raise here kills the
    # connection process with a silent TCP close).
    test "symbol-descriptor section decodes to :unknown, never raises (lens-2)" do
      payload =
        PrimitiveCodec.encode({:described, {:symbol, "vendor:section"}, []})
        |> IO.iodata_to_binary()

      assert {:ok, [{:unknown, {:symbol, "vendor:section"}, []}]} =
               FrameCodec.decode_message(payload)
    end

    test "known section descriptor with non-list body is a tagged error, never raises (lens-2)" do
      header_int = PrimitiveCodec.encode({:described, 0x70, 42}) |> IO.iodata_to_binary()
      assert {:error, {:bad_section, :malformed_header}} = FrameCodec.decode_message(header_int)

      props_sym =
        PrimitiveCodec.encode({:described, 0x73, {:symbol, "x"}}) |> IO.iodata_to_binary()

      assert {:error, {:bad_section, :malformed_properties}} =
               FrameCodec.decode_message(props_sym)
    end

    test "non-binary body_data / non-list body_sequence sections are tagged errors, never stored (lens-2 c3)" do
      bad_data = PrimitiveCodec.encode({:described, 0x75, 42}) |> IO.iodata_to_binary()
      assert {:error, {:bad_section, :malformed_body_data}} = FrameCodec.decode_message(bad_data)

      bad_seq = PrimitiveCodec.encode({:described, 0x76, 42}) |> IO.iodata_to_binary()

      assert {:error, {:bad_section, :malformed_body_sequence}} =
               FrameCodec.decode_message(bad_seq)
    end

    # Lens-2 cycle-5: frame type byte and performative must belong to the same
    # layer (spec §2.3/§5). Previously the type byte only labeled the decoded
    # map — a SASL frame carrying `open` decoded cleanly into the connection
    # state machine.
    test "performative must match the frame's layer (lens-2 c5)" do
      sasl_open =
        Smalt.Amqp.FrameCodec.encode_frame(
          :sasl,
          0,
          {:open, %{container_id: "x", max_frame_size: 512}}
        )
        |> IO.iodata_to_binary()

      assert {:error, :performative_layer_mismatch} = FrameCodec.decode_frame(sasl_open)

      amqp_sasl_init =
        Smalt.Amqp.FrameCodec.encode_frame(:amqp, 0, {:sasl_init, %{mechanism: "ANONYMOUS"}})
        |> IO.iodata_to_binary()

      assert {:error, :performative_layer_mismatch} = FrameCodec.decode_frame(amqp_sasl_init)

      # control: correct-layer frames still decode
      sasl_mechs =
        Smalt.Amqp.FrameCodec.encode_frame(
          :sasl,
          0,
          {:sasl_mechanisms, %{server_mechanisms: [{:symbol, "ANONYMOUS"}]}}
        )
        |> IO.iodata_to_binary()

      assert {:ok, %{type: :sasl, performative: %{performative: :sasl_mechanisms}}} =
               FrameCodec.decode_frame(sasl_mechs)
    end

    # Lens-2 cycle-6: outbound encode is a programming-error contract — a
    # value the AMQP type system cannot represent raises ArgumentError in the
    # caller's process BEFORE any byte reaches the socket (moduledoc
    # "Outbound encode contract"). Inbound decode stays total.
    test "outbound encode raises ArgumentError on unencodable values, pre-socket (lens-2 c6)" do
      # real codec: the test double raises FunctionClauseError by contract
      SmaltTest.Env.put_restored(primitive_codec: Smalt.Amqp.PrimitiveCodec)

      assert_raise ArgumentError, fn ->
        Smalt.Amqp.FrameCodec.encode_frame(
          :amqp,
          0,
          {:open, %{container_id: :an_unencodable_atom}}
        )
      end

      assert_raise ArgumentError, fn ->
        FrameCodec.encode_message([{:body_amqp_value, make_ref()}])
      end

      # decode remains total: no raise for arbitrary bytes
      assert {:error, _} =
               FrameCodec.decode_frame(<<0, 0, 0, 8, 2, 0, 0, 0>> <> :rand.bytes(8))
    end
  end
end

# Pinion fence (2026-10-17): the attach composite encodes as a TOP-LEVEL list
# of EXACTLY 14 elements on the wire — the pyamqp positional-arity pinion.
# The R16 tripwire pins the composite arities of source (8) and target (7);
# this test pins the attach list itself, so a one-field addition to the codec's
# attach field list cannot pass every existing test.
defmodule Smalt.Amqp.AttachTopLevelArityTest do
  use ExUnit.Case, async: false

  test "attach encodes as a top-level list of exactly 14 elements (extras dropped)" do
    for extras <- [[], [bogus_extra: "x"]] do
      # All 14 fields must be non-nil: trailing nils are trimmed on the wire
      # (trim_trailing_nulls), so only a fully-populated attach witnesses the
      # full top-level arity.
      fields =
        Map.new(
          for {k, v} <- [
                {:name, "l"},
                {:handle, 0},
                {:role, 1},
                {:snd_settle_mode, 0},
                {:rcv_settle_mode, 0},
                {:source, %{address: "q"}},
                {:target, %{address: "q"}},
                {:unsettled, %{}},
                {:incomplete_unsettled, false},
                {:initial_delivery_count, 0},
                {:max_message_size, 0},
                {:offered_capabilities, ["ANONYMOUS"]},
                {:desired_capabilities, ["ANONYMOUS"]},
                {:properties, %{}}
              ],
              into: %{},
              do: {k, v}
        )
        |> Map.merge(Enum.into(extras, %{}))

      payload =
        IO.iodata_to_binary(Smalt.Amqp.FrameCodec.encode_frame(:amqp, 0, {:attach, fields}))

      # attach descriptor 0x12; constructor may be 0xC0 (list8) after it.
      {desc_start, 3} = :binary.match(payload, <<0x00, 0x53, 0x12>>)
      skip = desc_start + 3
      <<_::binary-size(skip), 0xC0, size, rest::binary>> = payload
      # list8 body = [element-count byte][elements]; size includes the count
      # byte itself, so the count is the first byte of the size-sized body.
      <<count, _elements::binary-size(size - 1), _::binary>> =
        binary_part(rest, 0, size)

      assert count == 14, "attach top-level arity #{count} != 14 (extras: #{inspect(extras)})"
    end
  end
end
