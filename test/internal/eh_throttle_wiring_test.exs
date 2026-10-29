defmodule Smalt.Internal.EhThrottleWiringTest do
  # T30-F1/F2 (retry-after-audit): EhThrottle wiring + RouteNotReady hint.
  # Chicago: real throttle ETS, real send_event storage, real router faces —
  # no mocks.
  use ExUnit.Case, async: false
  import Plug.Conn

  alias Smalt.EgressRouter
  alias Smalt.Messaging.EhThrottle
  alias Smalt.Messaging.EventHubs

  # long window so the test never crosses a reset mid-assert
  @window 60_000

  setup do
    hub = "t30-throttle-#{System.unique_integer([:positive])}"

    on_exit(fn ->
      EhThrottle.clear(hub)
      Application.put_env(:smalt, :eh_ingress_quota, nil)
    end)

    Application.put_env(:smalt, :eh_ingress_quota, nil)
    %{hub: hub}
  end

  test "unit: admit/2 admits under quota and denies over quota with a typed face", %{hub: hub} do
    EhThrottle.set_quota(hub, 2, @window)

    assert {:ok, :admitted} = EhThrottle.admit(hub, 1)
    assert {:ok, :admitted} = EhThrottle.admit(hub, 1)

    assert {:throttled, face} = EhThrottle.admit(hub, 1)
    assert face.limit == 2
    assert face.window_ms == @window
    assert is_integer(face.retry_after_s) and face.retry_after_s >= 1
    assert EhThrottle.window_counts(hub) == 2
  end

  test "unit: amqp_refusal maps the face to the server-busy class", %{hub: hub} do
    EhThrottle.set_quota(hub, 1, @window)

    assert {:ok, :admitted} = EhThrottle.admit(hub, 1)
    assert {:throttled, face} = EhThrottle.admit(hub, 1)

    assert {:error, {:resource_limit_exceeded, desc}} = EhThrottle.amqp_refusal(face)
    assert desc =~ "retry after"
  end

  test "wire: send_event admits unthrottled (default-off, witnessed shape)", %{hub: hub} do
    key = "#{hub}/partitions/0"

    assert {:ok, seq, event} = EventHubs.send_event(key, "t30-default-off")
    assert is_integer(seq) and seq >= 1
    assert event["offset"] == Integer.to_string(seq)
  end

  test "wire: over-quota publish is a typed throttle refusal, not a silent accept", %{hub: hub} do
    EhThrottle.set_quota(hub, 1, @window)

    assert {:ok, _seq, _} = EventHubs.send_event("#{hub}/partitions/0", "first")

    assert {:error, {:throttled, face}} = EventHubs.send_event("#{hub}/partitions/0", "second")
    assert face.limit == 1
    assert face.retry_after_s >= 1

    assert {:error, {:resource_limit_exceeded, desc}} = EhThrottle.amqp_refusal(face)
    assert desc =~ "retry after"
  end

  test "wire: config :smalt, :eh_ingress_quota opt-in throttles without manual set_quota", %{
    hub: hub
  } do
    Application.put_env(:smalt, :eh_ingress_quota, {1, @window})

    assert {:ok, _, _} = EventHubs.send_event("#{hub}/partitions/1", "a")
    assert {:error, {:throttled, _face}} = EventHubs.send_event("#{hub}/partitions/1", "b")
  end

  @tag :t30_f2
  test "503 RouteNotReady carries retry-after: 1" do
    conn =
      Plug.Test.conn("GET", "/blob/t30-notready")
      |> EgressRouter.route_not_ready()

    assert conn.status == 503
    assert get_resp_header(conn, "retry-after") == ["1"]
    assert get_resp_header(conn, "x-ms-request-id") != []
  end
end
