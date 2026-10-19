defmodule Smalt.OcelConformanceTest do
  use ExUnit.Case, async: true

  alias Smalt.Ocel.Conformance
  alias Smalt.Telemetry.OcelNdjson

  @tmp_dir Path.join(["tmp", "ocel_conformance_test_#{System.system_time(:nanosecond)}"])

  setup do
    File.rm_rf!(@tmp_dir)
    File.mkdir_p!(@tmp_dir)
    on_exit(fn -> File.rm_rf!(@tmp_dir) end)
    :ok
  end

  test "fitness_from_stats: perfect replay is 1.0, nothing replayed is 1.0 by convention" do
    assert Conformance.fitness_from_stats(%{consumed: 6, produced: 6, missing: 0, remaining: 0}) ==
             1.0

    assert Conformance.fitness_from_stats(%{consumed: 0, produced: 0, missing: 0, remaining: 0}) ==
             1.0

    # All missing, none remaining: 1/2(1-1) + 1/2(1-0) = 0.5
    assert Conformance.fitness_from_stats(%{consumed: 3, produced: 2, missing: 3, remaining: 0}) ==
             0.5
  end

  test "replay_trace: underfed transition counts missing AND consumed" do
    net = Conformance.net(%{"t" => %{input: %{"a" => 1}, output: %{"b" => 1}}}, %{}, %{"b" => 1})

    stats = Conformance.replay_trace(net, ["t"])
    assert stats.consumed == 1
    assert stats.produced == 1
    assert stats.missing == 1
  end

  test "log_fitness aggregates across traces" do
    net = Conformance.happy_path_net()

    {fitness, _stats} =
      Conformance.log_fitness(net, [
        Conformance.happy_path_trace(),
        Conformance.happy_path_trace()
      ])

    assert fitness == 1.0
  end

  test "drift_decision is the pure typed threshold" do
    assert Conformance.drift_decision(1.0, 0.05) == :NO_DRIFT
    assert Conformance.drift_decision(0.5, 0.05) == :DRIFT
    assert Conformance.drift_decision(0.95, 0.05) == :NO_DRIFT
    assert Conformance.drift_decision(0.949, 0.05) == :DRIFT
  end

  test "happy trace over the sink round-trip: assembled log replays at fitness 1.0" do
    # Write a happy-path log through the real sink, assemble it, and
    # replay the activity sequence from the assembled document.
    happy = Conformance.happy_path_trace()

    lines =
      Enum.map(Enum.with_index(happy, 1), fn {type, i} ->
        Jason.encode!(%{
          "ocel:eventTypes" => [%{"name" => type}],
          "ocel:objectTypes" => [%{"name" => "resource"}],
          "ocel:events" => [
            %{
              "id" => "e#{i}",
              "type" => type,
              "time" => "2026-10-14T00:00:0#{i}Z",
              "attributes" => %{},
              "relationships" => [%{"objectId" => "res-1", "qualifier" => "resource"}]
            }
          ],
          "ocel:objects" => [%{"id" => "res-1", "type" => "resource", "attributes" => %{}}]
        })
      end)

    path = Path.join(@tmp_dir, "happy.ndjson")
    File.write!(path, Enum.join(lines, "\n") <> "\n")

    assert {:ok, doc} = OcelNdjson.read_document(path)
    trace = Enum.map(doc["ocel:events"], & &1["type"])

    {fitness, _stats} = Conformance.log_fitness(Conformance.happy_path_net(), [trace])
    assert fitness == 1.0
  end

  test "deviation from a broken trace is below threshold and typed as drift" do
    broken = ~w(arm.resource.transition blob.put blob.custody.transition)
    result = Conformance.check_trace(Conformance.full_courier_net(), broken)
    assert result.fitness < 1.0
    assert Conformance.drift_decision(result.fitness, 0.0) == :DRIFT
    assert Conformance.drift_decision(result.fitness, 0.0) == :DRIFT and result.conforms == false
  end

  # -- Exact fitness on crafted traces (Definition 7.2, hand-derived) --------
  # Convention per moduledoc: underfed transition counts missing AND
  # consumed; final deficit -> m AND c; final excess -> r AND p.

  test "exact fitness 0.55 for underfed-mid trace (arm, settle, blob.put)" do
    net = Conformance.full_courier_net()

    # arm: fed, c1 p1. settle: input p_locked absent -> missing1 c1 p1.
    # blob.put: FED by settle's produced p_settled token, c1 p1.
    # end marking {p_armed:1, p_blob:1}: deficit 1 (p_end), excess 2.
    # c=3+1=4 m=1+1=2 p=3+2=5 r=0+2=2
    # fitness = ((1 - 2/4) + (1 - 2/5)) / 2 = (0.5 + 0.6) / 2 = 0.55
    broken = ~w(arm.resource.transition amqp.delivery.settled blob.put)
    result = Conformance.check_trace(net, broken)

    assert result.fitness == 0.55

    assert result.deviations == [
             ["amqp.delivery.settled", "missing_tokens"],
             ["final_marking", "deficit"],
             ["final_marking", "excess"]
           ]

    refute result.conforms
  end

  test "exact fitness 1/6 for single-transition trace (amqp.enqueue alone)" do
    net = Conformance.full_courier_net()

    # enqueue underfed (missing1 c1 p1); p_start never consumed, so
    # end {p_start:1, p_enqueued:1}: deficit 1 (p_end), excess 2.
    # c=2 m=2 p=3 r=2 -> ((1 - 2/2) + (1 - 2/3)) / 2 = (1/3) / 2 = 1/6
    result = Conformance.check_trace(net, ["amqp.enqueue"])

    assert result.fitness == (1 - 2 / 3) / 2

    assert result.deviations == [
             ["amqp.enqueue", "missing_tokens"],
             ["final_marking", "deficit"],
             ["final_marking", "excess"]
           ]
  end

  test "exact fitness for excess-only trace (happy prefix stopping at locked)" do
    net = Conformance.full_courier_net()

    # Fully-fed arm->enqueue->lock; end {p_locked:1}: deficit 1, excess 1
    # c=3+1=4 p=3+1=4 m=1 r=1 -> ((1 - 1/4) + (1 - 1/4)) / 2 = 0.75
    result = Conformance.check_trace(net, ~w(arm.resource.transition amqp.enqueue amqp.lock))

    assert result.fitness == 0.75
    # Fully-fed replay: no underfed deviations, only final-marking ones.
    assert result.deviations == [["final_marking", "deficit"], ["final_marking", "excess"]]
  end

  test "aggregate log fitness is the exact token-sum across traces" do
    net = Conformance.full_courier_net()

    {fitness, stats} =
      Conformance.log_fitness(net, [
        Conformance.full_courier_trace(),
        ~w(arm.resource.transition amqp.delivery.settled blob.put),
        ~w(arm.resource.transition amqp.enqueue amqp.lock)
      ])

    # trace2 (arm,settle,blob.put): c=3+1=4 m=1+1=2 p=3+2=5 r=2
    # trace3 (arm,enqueue,lock): fed c=3, end {p_locked:1}: deficit1 excess1
    # totals: c = 6+4+4, m = 0+2+1, p = 6+5+4, r = 0+2+1
    assert stats == %{consumed: 14, produced: 15, missing: 3, remaining: 3}
    assert fitness == (1 - 3 / 14 + (1 - 3 / 15)) / 2
  end

  # -- Emittable happy_path_net (net reversal: registry vocabulary only) ------

  test "happy_path_net contains only registry-emittable types and full_courier_net is kept" do
    emittable = Smalt.Ocel.EventRegistry.event_types()
    assert Map.keys(Conformance.happy_path_net().transitions) -- emittable == []
    assert Conformance.happy_path_trace() -- emittable == []

    courier = Map.keys(Conformance.full_courier_net().transitions) -- emittable
    assert courier == ~w(amqp.enqueue amqp.lock blob.put)
    assert length(Conformance.full_courier_trace()) == 6
  end

  test "emittable net: settle alone is 1/6 (no underfed-free path exists)" do
    result = Conformance.check_trace(Conformance.happy_path_net(), ["amqp.delivery.settled"])

    # settle underfed (m1 c1 p1); p_start never consumed: end {p_start,
    # p_settled}: deficit 1, excess 2. c=2 m=2 p=3 r=2 -> (0 + 1/3)/2
    assert result.fitness == (1 - 2 / 3) / 2

    assert result.deviations == [
             ["amqp.delivery.settled", "missing_tokens"],
             ["final_marking", "deficit"],
             ["final_marking", "excess"]
           ]
  end

  test "emittable net: fed prefix (arm, settle) is exactly 2/3" do
    result =
      Conformance.check_trace(
        Conformance.happy_path_net(),
        ~w(arm.resource.transition amqp.delivery.settled)
      )

    # Fully fed c=2 p=2; end {p_settled:1}: deficit 1 (p_end), excess 1.
    # c=3 m=1 p=3 r=1 -> ((1 - 1/3) + (1 - 1/3)) / 2 = 0.666...67
    assert result.fitness == (1 - 1 / 3 + (1 - 1 / 3)) / 2
    assert result.deviations == [["final_marking", "deficit"], ["final_marking", "excess"]]
  end

  test "emittable net: broken trace (arm, custody) is exactly ((1-1/2)+(1-1/3))/2" do
    result =
      Conformance.check_trace(
        Conformance.happy_path_net(),
        ~w(arm.resource.transition blob.custody.transition)
      )

    # custody underfed (m1 c1); its produced p_end token lands; end
    # {p_armed:1, p_end:1}: deficit 0, excess 1. c=2 m=1 p=3 r=1.
    assert result.fitness == (1 - 1 / 2 + (1 - 1 / 3)) / 2

    assert result.deviations == [
             ["blob.custody.transition", "missing_tokens"],
             ["final_marking", "excess"]
           ]
  end

  test "emittable net: aggregate token-sum across three traces" do
    {fitness, stats} =
      Conformance.log_fitness(Conformance.happy_path_net(), [
        Conformance.happy_path_trace(),
        ~w(arm.resource.transition blob.custody.transition),
        ~w(arm.resource.transition amqp.delivery.settled)
      ])

    # happy: c3 p3 m0 r0; broken: c2 m1 p3 r1 (deficit0 excess1);
    # prefix: c3 m1 p3 r1 (deficit1 excess1).
    assert stats == %{consumed: 8, produced: 9, missing: 2, remaining: 2}
    assert fitness == (1 - 2 / 8 + (1 - 2 / 9)) / 2
  end
end
