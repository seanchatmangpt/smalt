defmodule Smalt.Amqp.DeliveryEncoderTest do
  use ExUnit.Case, async: true

  alias Smalt.Amqp.DeliveryEncoder

  describe "message_annotations" do
    test "x-opt-sequence-number passes the raw ulong through (monotonic seq)" do
      sections =
        DeliveryEncoder.build_sections(sequence_number: 1)
        |> then(fn s ->
          assert s.message_annotations["x-opt-sequence-number"] == 1
          s
        end)

      # Monotonic passthrough across a sequence of sequence numbers.
      for seq <- [1, 2, 3, 9_007_199_254_740_992, 18_446_744_073_709_551_615] do
        assert DeliveryEncoder.build_sections(sequence_number: seq).message_annotations[
                 "x-opt-sequence-number"
               ] == seq
      end

      assert is_map(sections)
    end

    test "negative sequence numbers are not annotated" do
      sections = DeliveryEncoder.build_sections(sequence_number: -5)
      refute Map.has_key?(Map.get(sections, :message_annotations) || %{}, "x-opt-sequence-number")
    end

    test "timestamps normalize integers and pass {:timestamp, ms} through" do
      sections =
        DeliveryEncoder.build_sections(
          locked_until: 1_700_000_000_000,
          enqueued_time: {:timestamp, 1_699_999_000_000}
        )

      assert sections.message_annotations["x-opt-locked-until"] ==
               {:timestamp, 1_700_000_000_000}

      assert sections.message_annotations["x-opt-enqueued-time-utc"] ==
               {:timestamp, 1_699_999_000_000}
    end

    test "x-opt-session-id present only when set" do
      with_session = DeliveryEncoder.build_sections(session_id: "s1")
      assert with_session.message_annotations["x-opt-session-id"] == "s1"

      without = DeliveryEncoder.build_sections(sequence_number: 1)
      refute Map.has_key?(without.message_annotations, "x-opt-session-id")
    end

    test "no annotations key when nothing annotated" do
      assert DeliveryEncoder.build_sections(delivery_count: 0)[:message_annotations] == nil
    end
  end

  describe "header" do
    test "delivery_count passthrough" do
      assert DeliveryEncoder.build_sections(delivery_count: 3).header == %{delivery_count: 3}
      assert DeliveryEncoder.build_sections(delivery_count: 0).header == %{delivery_count: 0}
    end

    test "header omitted without delivery_count" do
      refute Map.has_key?(DeliveryEncoder.build_sections(sequence_number: 1), :header)
    end
  end

  describe "properties" do
    test "message-id and creation-time" do
      props =
        DeliveryEncoder.build_sections(
          message_id: "mid-9",
          creation_time: 1_700_000_000_000
        ).properties

      assert props == %{message_id: "mid-9", creation_time: {:timestamp, 1_700_000_000_000}}
    end

    test "properties omitted when empty" do
      refute Map.has_key?(DeliveryEncoder.build_sections(sequence_number: 1), :properties)
    end
  end

  describe "DLQ footer (application-properties)" do
    test "DeadLetterReason / DeadLetterErrorDescription only on DLQ delivery" do
      dlq =
        DeliveryEncoder.build_sections(
          sequence_number: 7,
          deadletter_reason: "max-delivery-count",
          deadletter_description: "10 attempts"
        ).application_properties

      assert dlq == %{
               "DeadLetterReason" => "max-delivery-count",
               "DeadLetterErrorDescription" => "10 attempts"
             }

      normal = DeliveryEncoder.build_sections(sequence_number: 7)
      refute Map.has_key?(normal, :application_properties)
    end

    test "description alone still produces footer" do
      footer =
        DeliveryEncoder.build_sections(deadletter_description: "oops").application_properties

      assert footer == %{"DeadLetterErrorDescription" => "oops"}
    end
  end

  describe "full outbound delivery" do
    test "all sections together" do
      sections =
        DeliveryEncoder.build_sections(
          sequence_number: 42,
          locked_until: 1_700_000_000_000,
          enqueued_time: 1_699_999_000_000,
          session_id: "sess",
          delivery_count: 2,
          message_id: "mid-1",
          creation_time: 1_699_999_000_000
        )

      assert sections == %{
               header: %{delivery_count: 2},
               properties: %{message_id: "mid-1", creation_time: {:timestamp, 1_699_999_000_000}},
               message_annotations: %{
                 "x-opt-sequence-number" => 42,
                 "x-opt-locked-until" => {:timestamp, 1_700_000_000_000},
                 "com.microsoft:locked-until-utc" => 638_355_968_000_000_000,
                 "x-opt-enqueued-time-utc" => {:timestamp, 1_699_999_000_000},
                 "x-opt-session-id" => "sess"
               }
             }
    end
  end

  describe "filetime_from_ms/1 (Service Bus .NET filetime)" do
    @tag :filetime_round_trip
    test "known vectors" do
      # .NET epoch 0001-01-01 UTC offset, in ms.
      assert DeliveryEncoder.filetime_from_ms(0) == 621_355_968_000_000_000

      # 2026-10-14T00:00:00Z == 1_791_936_000_000 epoch ms.
      assert DeliveryEncoder.filetime_from_ms(1_791_936_000_000) ==
               639_275_328_000_000_000
    end

    test "round-trips: filetime back to ms recovers the input" do
      for ms <- [0, 1, 1_700_000_000_000, 1_791_936_000_000, 4_102_444_799_999] do
        ticks = DeliveryEncoder.filetime_from_ms(ms)
        assert div(ticks - 621_355_968_000_000_000, 10_000) == ms
      end
    end

    test "millisecond precision preserved (low 4 ticks always zero)" do
      for ms <- 0..99 do
        assert rem(DeliveryEncoder.filetime_from_ms(ms * 1_000_000), 10_000) == 0
      end
    end
  end

  describe "locked-until-utc annotation" do
    test "present as ulong ticks when locked_until given" do
      annotations =
        DeliveryEncoder.build_sections(locked_until: 1_791_936_000_000).message_annotations

      assert annotations["com.microsoft:locked-until-utc"] == 639_275_328_000_000_000
      # timestamp(ms) form still present alongside it
      assert annotations["x-opt-locked-until"] == {:timestamp, 1_791_936_000_000}
    end

    test "accepts {:timestamp, ms} form too" do
      annotations =
        DeliveryEncoder.build_sections(locked_until: {:timestamp, 0}).message_annotations

      assert annotations["com.microsoft:locked-until-utc"] == 621_355_968_000_000_000
    end

    test "absent without locked_until" do
      annotations = DeliveryEncoder.build_sections(sequence_number: 1).message_annotations
      refute Map.has_key?(annotations || %{}, "com.microsoft:locked-until-utc")
    end
  end
end
