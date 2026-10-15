defmodule Smalt.OcelRevopsTest do
  use ExUnit.Case, async: true

  @moduletag :ocel_revops

  alias Smalt.Ocel.Conformance
  alias Smalt.Ocel.DeviationAdmission
  alias Smalt.Ocel.RevOps.FitnessVerdict
  alias Smalt.Ocel.RevOps.OcelDeviation
  alias Smalt.Ocel.RevOps.OcelTrace

  @tmp_dir "tmp/ocel_revops_test_#{System.system_time(:nanosecond)}"

  setup do
    File.rm_rf!(@tmp_dir)
    File.mkdir_p!(@tmp_dir)
    on_exit(fn -> File.rm_rf!(@tmp_dir) end)

    happy = Conformance.happy_path_trace()
    broken = ~w(arm.resource.transition blob.custody.transition)

    # Real NDJSON sink lines: res-1 replays the full happy path; res-2 is
    # the broken trace from the conformance court (skipped mid-path).
    lines =
      Enum.flat_map([{happy, "res-1"}, {broken, "res-2"}], fn {trace, obj} ->
        Enum.map(Enum.with_index(trace, 1), fn {type, i} ->
          Jason.encode!(%{
            "ocel:eventTypes" => [%{"name" => type}],
            "ocel:objectTypes" => [%{"name" => "resource"}],
            "ocel:events" => [
              %{
                "id" => "e-#{obj}-#{i}",
                "type" => type,
                "time" => "2026-10-14T00:00:0#{rem(i, 10)}.0Z",
                "attributes" => %{},
                "relationships" => [%{"objectId" => obj, "qualifier" => "resource"}]
              }
            ],
            "ocel:objects" => [%{"id" => obj, "type" => "resource", "attributes" => %{}}]
          })
        end)
      end)

    events_path = Path.join(@tmp_dir, "events.ndjson")
    File.write!(events_path, Enum.join(lines, "\n") <> "\n")

    deviations_path = Path.join(@tmp_dir, "deviations.jsonl")

    {:ok, events_path: events_path, deviations_path: deviations_path, broken: broken}
  end

  test "OcelTrace: two traces read back through Ash with real counts and windows", %{
    events_path: events_path
  } do
    traces =
      OcelTrace
      |> Ash.Query.for_read(:read, events_path: events_path)
      |> Ash.read!()

    assert length(traces) == 2

    by_id = Map.new(traces, &{&1.trace_id, &1})

    assert by_id["res-1"].event_count == 3
    assert by_id["res-2"].event_count == 2
    assert "blob.custody.transition" in by_id["res-2"].event_types
    assert %DateTime{} = by_id["res-1"].start_time
    assert DateTime.compare(by_id["res-1"].start_time, by_id["res-1"].end_time) == :lt
  end

  test "FitnessVerdict: happy trace conforms at 1.0, broken trace does not", %{
    events_path: events_path
  } do
    verdicts =
      FitnessVerdict
      |> Ash.Query.for_read(:read, events_path: events_path)
      |> Ash.read!()

    by_id = Map.new(verdicts, &{&1.trace_id, &1})
    assert Map.keys(by_id) |> Enum.sort() == ["res-1", "res-2"]

    assert by_id["res-1"].conforms == true
    assert by_id["res-1"].fitness == 1.0
    assert by_id["res-1"].deviation_count == 0

    # Net-selection law, pinned: FitnessVerdict replays against the ONE
    # canonical emittable net (happy_path_net) by construction — no
    # multi-net ambiguity exists. The same emitted trace scores 1.0
    # under the canonical net vs 0.4666666666666667 (live-computed)
    # under the historical full_courier_net; the verdict MUST be the
    # canonical one.
    assert by_id["res-1"].fitness == Conformance.check_trace(Conformance.happy_path_net(), Conformance.happy_path_trace()).fitness
    assert by_id["res-1"].fitness != Conformance.check_trace(Conformance.full_courier_net(), Conformance.happy_path_trace()).fitness

    assert by_id["res-2"].conforms == false

    # Exact replay of [arm, blob.custody.transition] over the emittable
    # happy_path_net: blob.custody underfed (m1 c1); its produced p_end
    # token lands; end {p_armed:1, p_end:1}: deficit 0, excess 1.
    # c=2 m=1 p=3 r=1 -> ((1 - 1/2) + (1 - 1/3)) / 2 = 0.5833333333333334
    assert by_id["res-2"].fitness == (1 - 1 / 2 + (1 - 1 / 3)) / 2
    assert by_id["res-2"].deviation_count == 2
  end

  test "a conformance-false deviation appears as an evidence record through Ash", %{
    deviations_path: deviations_path,
    broken: broken
  } do
    # Real conformance court verdict on the real broken trace...
    result = Conformance.check_trace(Conformance.happy_path_net(), broken)
    assert result.conforms == false

    # ...durably admitted to a real deviations.jsonl...
    assert {:ok, record_id} =
             DeviationAdmission.admit(result,
               path: deviations_path,
               trace: broken,
               reference_trace_id: "res-1",
               candidate_trace_id: "res-2"
             )

    assert is_binary(record_id)

    # ...and read back through the Ash surface.
    deviations =
      OcelDeviation
      |> Ash.Query.for_read(:read, path: deviations_path)
      |> Ash.read!()

    assert length(deviations) == 1
    record = hd(deviations)

    assert record.id == record_id
    assert record.status == "observed"
    assert record.reference_trace_id == "res-1"
    assert record.candidate_trace_id == "res-2"
    assert record.deviating_move == "blob.custody.transition/missing_tokens"
    assert record.fitness == result.fitness
    assert record.trace == broken

    # Empty ledger reads as an empty surface, not an error.
    empty_path = Path.join(@tmp_dir, "empty.jsonl")

    assert OcelDeviation
           |> Ash.Query.for_read(:read, path: empty_path)
           |> Ash.read!() == []
  end
end
