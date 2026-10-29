defmodule Smalt.AppConfigEventsTest do
  use ExUnit.Case, async: false

  import Plug.Test

  alias Smalt.DataPlane.AppConfigEvents

  setup do
    # F8-class isolation fix: a sibling integration test that PUTs a KV key
    # (kv404_typed_error_test) triggers AppConfigRoutes.emit_kv_event ->
    # AppConfigEvents.emit -> server(), whose lazy start_link is linked to the
    # *caller* (that test's process). The registry then survives that test's
    # normal exit, registered globally outside any supervisor, and this
    # module's start_supervised! fails {:already_started, _} for every
    # remaining test. Setup re-owns the global name (synchronous stop, then a
    # supervision-owned instance) instead of relying on test-order luck.
    case Process.whereis(AppConfigEvents) do
      nil -> :ok
      pid -> GenServer.stop(pid)
    end

    start_supervised!(AppConfigEvents)
    AppConfigEvents.reset()
    :ok
  end

  defp put_kv(key, value, _label \\ "") do
    body =
      Jason.encode!(%{
        "key" => key,
        "value" => value,
        "contentType" => "application/json"
      })

    conn =
      Plug.Conn.put_req_header(
        conn(:put, "/kv/#{URI.encode_www_form(key)}", body),
        "content-type",
        "application/json"
      )

    conn =
      Plug.Parsers.call(conn,
        Plug.Parsers.init(
          parsers: [Plug.Parsers.JSON],
          pass: ["application/json"],
          json_decoder: Jason
        )
      )

    Smalt.Egress.AppConfigRoutes.call(conn, [])
  end

  defp kv_status(conn), do: conn.status

  test "subscribe pid -> mutate key -> typed Event Grid envelope received" do
    :ok = AppConfigEvents.subscribe("t1", self())

    conn = put_kv("appws-key-1", ~s({"v":1}))
    assert kv_status(conn) == 201

    assert_receive {:appconfig_kv_event, "t1", event}, 5_000

    assert event["eventType"] == "Microsoft.AppConfiguration.KeyValueModified"
    assert event["subject"] == "AppConfiguration.KeyValue:appws-key-1:"
    assert is_binary(event["id"])
    assert is_binary(event["eventTime"])
    assert event["data"]["key"] == "appws-key-1"
    assert event["data"]["label"] == ""
    assert is_binary(event["data"]["etag"])

    # Recorded for pull too (receiver-independent witness).
    assert event["id"] in Enum.map(AppConfigEvents.events(), & &1["id"])
  end

  test "delete-variant envelope is typed (KeyValueDeleted)" do
    :ok = AppConfigEvents.subscribe("t2", self())

    AppConfigEvents.emit("appws-del-key", "prod", "\"DE\"-etag", :deleted)

    assert_receive {:appconfig_kv_event, "t2", event}, 5_000
    assert event["eventType"] == "Microsoft.AppConfiguration.KeyValueDeleted"
    assert event["subject"] == "AppConfiguration.KeyValue:appws-del-key:prod"
  end

  test "non-loopback webhook subscription is refused typed (fail-closed)" do
    assert {:error, {:refused, :non_loopback_endpoint}} =
             AppConfigEvents.subscribe("bad1", "https://example.com/hook")

    assert {:error, {:refused, :non_loopback_endpoint}} =
             AppConfigEvents.subscribe("bad2", "http://10.0.0.5:8080/hook")

    refute Map.has_key?(AppConfigEvents.subscriptions(), "bad1")
    refute Map.has_key?(AppConfigEvents.subscriptions(), "bad2")
  end

  test "loopback webhook URL is admitted but delivery is typed UNSUPPORTED-by-airgap" do
    :ok = AppConfigEvents.subscribe("lp", "http://127.0.0.1:39999/hook")

    assert {:ok, {:url, "http://127.0.0.1:39999/hook"}} ==
             Map.fetch(AppConfigEvents.subscriptions(), "lp")

    [_outcome] = AppConfigEvents.emit("appws-lp-key", "", "\"LP\"-etag")

    assert [%{"eventType" => "Microsoft.AppConfiguration.KeyValueModified"}] =
             AppConfigEvents.events()
  end

  test "unsubscribed receiver gets nothing after unsubscribe" do
    :ok = AppConfigEvents.subscribe("t3", self())
    :ok = AppConfigEvents.unsubscribe("t3")

    AppConfigEvents.emit("appws-t3-key", "", "\"T3\"-etag")
    AppConfigEvents.emit("appws-t3-key", "", "\"T4\"-etag")

    refute_receive {:appconfig_kv_event, "t3", _}, 200
  end
end
