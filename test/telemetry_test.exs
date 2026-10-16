defmodule Smalt.TelemetryTest do
  use ExUnit.Case, async: false

  alias Smalt.Telemetry
  alias Smalt.Telemetry.RollingCounters

  setup do
    handler_id = "smalt-telemetry-test-#{System.unique_integer([:positive])}"

    :telemetry.attach_many(
      handler_id,
      Telemetry.smalt_events() ++ [[:bandit, :request, :stop]],
      &__MODULE__.test_handler/4,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler_id) end)
    on_exit(fn -> :telemetry.detach("smalt-telemetry") end)

    :ok = Telemetry.attach()

    # The app tree owns a RollingCounters child; do not fight the supervisor
    # for it — reuse the running instance when present (one_for_one would
    # restart a stopped child between whereis/1 and start_link/1).
    case RollingCounters.start_link([]) do
      {:ok, _} -> :ok
      {:error, {:already_started, _}} -> :ok
    end

    :ok
  end

  def test_handler(event, measurements, metadata, _config) do
    send(self(), {:telemetry_event, event, measurements, metadata})
  end

  describe "smalt-native emitters" do
    test "admit/1 emits [:smalt, :admit] with whitelisted metadata only" do
      :ok = Telemetry.admit(:ok, route: "/arm/shapes")

      assert_received {:telemetry_event, [:smalt, :admit], measurements, metadata}
      assert measurements == %{}
      assert metadata == %{event: :ok, route: "/arm/shapes"}
    end

    test "refuse/2 emits [:smalt, :refuse] with typed code" do
      :ok = Telemetry.refuse(:UNAUTHORIZED_ROUTE, code: :UNAUTHORIZED_ROUTE, route: "/egress/x")

      assert_received {:telemetry_event, [:smalt, :refuse], _, metadata}

      assert metadata == %{
               event: :UNAUTHORIZED_ROUTE,
               code: :UNAUTHORIZED_ROUTE,
               route: "/egress/x"
             }
    end

    test "sb_delivery/2 emits [:smalt, :sb_delivery] without payloads" do
      :ok = Telemetry.sb_delivery(:delivered)

      assert_received {:telemetry_event, [:smalt, :sb_delivery], _, metadata}
      assert metadata == %{event: :delivered}
    end

    test "emitters drop non-whitelisted keys (no payload leakage)" do
      :ok =
        Telemetry.sb_delivery(:delivered,
          event: :delivered,
          payload: %{"body" => "secret-message", "sender" => "identity-123"},
          route: "/sb/in"
        )

      assert_received {:telemetry_event, [:smalt, :sb_delivery], _, metadata}
      refute Map.has_key?(metadata, :payload)
      assert metadata == %{event: :delivered, route: "/sb/in"}
    end

    test "metadata keys are always a subset of the module whitelist" do
      Telemetry.admit(:ok, route: "/r", bogus: "x")
      assert_received {:telemetry_event, _, _, metadata}
      assert_whitelisted(metadata)
    end
  end

  describe "bandit span normalization" do
    test "handle_event/4 normalizes [:bandit, :request, :stop] into a span" do
      conn = %Plug.Conn{request_path: "/arm/shapes", status: 200}
      measurements = %{duration: System.convert_time_unit(5, :millisecond, :native)}

      span =
        Telemetry.handle_event(
          [:bandit, :request, :stop],
          measurements,
          %{conn: conn, plug: {Smalt.ArmGateway.Router, []}},
          :test
        )

      assert %Telemetry{} = span
      assert span.route == "/arm/shapes"
      assert span.status == 200
      assert span.duration_ms == 5
    end

    test "span tolerates missing conn (error-path requests)" do
      span =
        Telemetry.handle_event(
          [:bandit, :request, :stop],
          %{duration: 0},
          %{plug: {Smalt.ArmGateway.Router, []}},
          :test
        )

      assert %Telemetry{route: nil, status: nil, duration_ms: 0} = span
    end
  end

  describe "RollingCounters" do
    test "counters increment and dump/0 returns event-keyed counts" do
      # Counters are cumulative over the shared app lifetime and this module's
      # own tests emit the same bare keys in ExUnit's random order — assert
      # deltas over a pre-test baseline instead of absolute counts.
      baseline = Telemetry.dump()

      Telemetry.admit(:ok)
      Telemetry.admit(:ok)
      Telemetry.refuse(:SHAPE_INVALID)

      dump = Telemetry.dump()
      assert (dump[{[:smalt, :admit], %{event: :ok}}] || 0) - (baseline[{[:smalt, :admit], %{event: :ok}}] || 0) == 2

      assert (dump[{[:smalt, :refuse], %{event: :SHAPE_INVALID}}] || 0) -
               (baseline[{[:smalt, :refuse], %{event: :SHAPE_INVALID}}] || 0) == 1
    end

    test "bandit stops are counted by route and status; 4xx/5xx bucket as :error" do
      baseline = Telemetry.dump()
      conn = %Plug.Conn{request_path: "/egress/dispatch", status: 404}

      Telemetry.handle_event([:bandit, :request, :stop], %{duration: 0}, %{conn: conn}, :test)

      dump = Telemetry.dump()
      assert (dump[{:bandit_request_stop, "/egress/dispatch", 404}] || 0) - (baseline[{:bandit_request_stop, "/egress/dispatch", 404}] || 0) == 1
      assert (dump[{:bandit_request_stop, :error}] || 0) - (baseline[{:bandit_request_stop, :error}] || 0) == 1
    end

    test "dump/0 shape: map of tuple-key => positive integer" do
      Telemetry.sb_delivery(:delivered)

      dump = Telemetry.dump()
      assert is_map(dump)

      # Counters are cumulative over the shared app lifetime, so assert the
      # emitted key's shape/count rather than whole-map singleton equality.
      assert dump[{[:smalt, :sb_delivery], %{event: :delivered}}] > 0

      for {_key, count} <- dump do
        assert is_integer(count) and count > 0
      end
    end

    test "dump/0 sums the same key across minute windows" do
      # Seed directly into the ETS table: same logical key in the previous and
      # current minute window. dump/0 must SUM (3 + 4 = 7), not overwrite.
      table = :smalt_rolling_counters
      now = System.system_time(:millisecond) |> div(60_000)
      key = {:bandit_request_stop, "/telemetry-sum-test/window", 200}
      baseline = Telemetry.dump()

      :ets.insert(table, {{now - 1, key, :self}, 3})
      :ets.insert(table, {{now, key, :self}, 4})

      assert Telemetry.dump()[key] - (baseline[key] || 0) == 7
    end

    test "per_minute/0 keys counters by {minute, key}" do
      Telemetry.admit(:ok)
      per_minute = RollingCounters.per_minute()

      assert is_map(per_minute)
      assert map_size(per_minute) >= 1

      # Key-scoped: the shared counters accumulate other suites' bandit stops.
      assert Enum.any?(per_minute, fn {{_minute, key}, count} ->
               key == {[:smalt, :admit], %{event: :ok}} and is_integer(count) and count >= 1
             end)

      for {{minute, _key}, count} <- per_minute do
        assert is_integer(minute)
        assert is_integer(count) and count >= 1
      end
    end
  end

  defp assert_whitelisted(metadata) do
    for {k, _v} <- metadata do
      assert k in Telemetry.metadata_keys(), "metadata key #{inspect(k)} is not whitelisted"
    end
  end
end
