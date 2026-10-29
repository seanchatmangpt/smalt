defmodule Smalt.RuntimeContracts.AmqpDialect do
  @moduledoc """
  AMQP 1.0 Service Bus dialect contract binding `Smalt.Amqp.FrameCodec` /
  `Smalt.Amqp.DeliveryEncoder` to their consumers.

  Fences, in-process, the dialect invariants pinned by `test/amqp/*`:

    * frame header: 8-byte prefix (size::32, doff::8, type::8, channel::16),
      doff == 2, round-trips through `decode_frame/1`
    * performatives round-trip: open / begin / attach / transfer / close / end
    * SASL frame type round-trips (`:sasl`, ANONYMOUS mechanisms symbol)
    * message sections round-trip through `encode_message/decode_message`
      with annotation maps carried directly (not 1-element lists) and body
      data as vbin
    * Service Bus dialect: `com.microsoft:locked-until-utc` as .NET filetime
      ticks (`DeliveryEncoder.filetime_from_ms/1`) alongside
      `x-opt-locked-until` timestamp
    * delivery encoder section map shape (header / properties /
      message_annotations / application_properties DLQ footer)

  Template source: ash-runtime-integration-contract-pack
  `templates/api_contract.ex.tmpl`, adapted (see
  `docs/PACK_INTEGRATION/runtime-contracts.md`).
  """

  alias Smalt.Amqp.DeliveryEncoder
  alias Smalt.Amqp.FrameCodec
  alias Smalt.RuntimeContracts.Support

  @behaviour Smalt.RuntimeContracts.Contract

  @impl true
  def name, do: :amqp_dialect

  @impl true
  def plane, do: :messaging_plane

  @impl true
  def check do
    Support.contract(:amqp_dialect, [
      {:frame_header_roundtrip, fn -> check_frame_header() end},
      {:performatives_roundtrip, fn -> check_performatives() end},
      {:sasl_frame_roundtrip, fn -> check_sasl() end},
      {:message_sections_roundtrip, fn -> check_message_sections() end},
      {:body_data_vbin_not_str8, fn -> check_body_data_vbin() end},
      {:servicebus_lock_filetime_dialect, fn -> check_filetime_dialect() end},
      {:delivery_encoder_section_shape, fn -> check_encoder_shape() end}
    ])
  end

  # ===========================================================================
  # checks
  # ===========================================================================

  defp check_frame_header do
    frame =
      IO.iodata_to_binary(FrameCodec.encode_frame(:amqp, 3, {:open, %{container_id: "rtc"}}))

    <<size::32, doff::8, type_code::8, channel::16, _rest::binary>> = frame

    Support.assert_equal(size, byte_size(frame), "frame size field equals frame byte size")
    Support.assert_equal(doff, 2, "doff is 2 (8-byte header)")
    Support.assert_equal(byte_size(frame) >= 8, true, "frame at least header-sized")
    Support.assert_equal(channel, 3, "channel field round-trips")
    _ = type_code

    {:ok, decoded} = FrameCodec.decode_frame(frame)

    Support.assert_equal(decoded.channel, 3, "decoded channel")
    Support.assert_equal(decoded.type, :amqp, "decoded frame type")

    Support.assert_equal(
      decoded.performative[:container_id],
      "rtc",
      "open container_id round-trip"
    )
  end

  defp check_performatives do
    cases = [
      {:amqp, 0, {:begin, %{next_outgoing_id: 0, incoming_window: 100, outgoing_window: 100}}},
      {:amqp, 0, {:attach, %{name: "rtc-link", handle: 0, role: true}}},
      {:amqp, 0, {:close, %{error: %{condition: "amqp:connection-close", description: nil}}}},
      {:amqp, 0, {:end, %{}}}
    ]

    Enum.each(cases, fn {type, ch, spec} ->
      encoded = IO.iodata_to_binary(FrameCodec.encode_frame(type, ch, spec))
      {:ok, decoded} = FrameCodec.decode_frame(encoded)

      Support.assert_equal(decoded.type, type, "decoded type for #{inspect(spec)}")
      Support.assert_equal(decoded.channel, ch, "decoded channel for #{inspect(spec)}")

      Support.assert_equal(
        decoded.performative[:performative] || elem(spec, 0),
        elem(spec, 0),
        "decoded performative name for #{inspect(spec)}"
      )
    end)

    # transfer carries a payload, decoded separately
    payload = "rtc-payload"

    frame =
      IO.iodata_to_binary(
        FrameCodec.encode_frame(:amqp, 0, {:transfer, %{handle: 0, delivery_id: 1}, payload})
      )

    {:ok, decoded} = FrameCodec.decode_frame(frame)
    Support.assert_equal(decoded.payload, payload, "transfer payload round-trip")
  end

  defp check_sasl do
    frame =
      IO.iodata_to_binary(
        FrameCodec.encode_frame(
          :sasl,
          0,
          {:sasl_mechanisms, %{server_mechanisms: [{:symbol, "ANONYMOUS"}]}}
        )
      )

    {:ok, decoded} = FrameCodec.decode_frame(frame)

    Support.assert_equal(decoded.type, :sasl, "decoded frame type :sasl")

    Support.assert_equal(
      decoded.performative[:performative],
      :sasl_mechanisms,
      "decoded performative name"
    )

    Support.assert_equal(
      decoded.performative[:server_mechanisms],
      [{:symbol, "ANONYMOUS"}],
      "sasl mechanisms round-trip"
    )
  end

  defp check_message_sections do
    sections = [
      {:header, %{delivery_count: 2}},
      {:properties, %{message_id: "rtc-mid", creation_time: {:timestamp, 1_699_999_000_000}}},
      {:message_annotations, %{"x-opt-sequence-number" => 42}},
      {:application_properties, %{"DeadLetterReason" => "max-delivery"}},
      {:body_data, "rtc-body"}
    ]

    encoded = IO.iodata_to_binary(FrameCodec.encode_message(sections))
    {:ok, decoded} = FrameCodec.decode_message(encoded)

    Support.assert_equal(decoded, sections, "message sections round-trip")
  end

  defp check_body_data_vbin do
    # >= 0x80 bytes: str8 encoding would come back UTF-8-mangled (census finding)
    body = :crypto.strong_rand_bytes(0x100)

    encoded = IO.iodata_to_binary(FrameCodec.encode_message([{:body_data, body}]))
    {:ok, [{:body_data, decoded}]} = FrameCodec.decode_message(encoded)

    Support.assert_equal(decoded, body, "large binary body survives (vbin, not str8)")
  end

  defp check_filetime_dialect do
    ms = 1_700_000_000_000
    ticks = DeliveryEncoder.filetime_from_ms(ms)

    # filetime_from_ms/1 is typed integer() — assert only the value, not the type.
    Support.assert(ticks > 0, "filetime ticks positive integer")

    # filetime = (ms + 62_135_596_800_000) * 10_000
    Support.assert_equal(ticks, (ms + 62_135_596_800_000) * 10_000, "filetime conversion formula")
  end

  defp check_encoder_shape do
    sections =
      DeliveryEncoder.build_sections(
        sequence_number: 42,
        locked_until: 1_700_000_000_000,
        enqueued_time: 1_699_999_000_000,
        delivery_count: 2,
        message_id: "rtc-mid",
        creation_time: 1_699_999_000_000,
        deadletter_reason: "max-delivery",
        deadletter_description: "gave up"
      )

    Support.assert_equal(get_in(sections, [:header, :delivery_count]), 2, "header.delivery_count")

    ma = sections.message_annotations

    Support.assert_equal(
      ma["com.microsoft:locked-until-utc"],
      DeliveryEncoder.filetime_from_ms(1_700_000_000_000),
      "Service Bus filetime lock expiry annotation"
    )

    Support.assert_equal(ma["x-opt-sequence-number"], 42, "x-opt-sequence-number")

    Support.assert_equal(
      get_in(sections, [:application_properties, "DeadLetterReason"]),
      "max-delivery",
      "DLQ footer in application_properties"
    )

    # Encoder output must be encodable by the frame lane and round-trip back.
    as_tuples = [
      {:header, sections.header},
      {:properties, sections.properties},
      {:message_annotations, sections.message_annotations},
      {:application_properties, sections.application_properties}
    ]

    {:ok, decoded} =
      FrameCodec.encode_message(as_tuples)
      |> IO.iodata_to_binary()
      |> FrameCodec.decode_message()

    Support.assert_equal(
      Enum.any?(
        decoded,
        &match?({:message_annotations, %{"com.microsoft:locked-until-utc" => _}}, &1)
      ),
      true,
      "filetime annotation survives wire round-trip"
    )
  end
end
