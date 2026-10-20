defmodule Smalt.EventGridWebhookTest do
  use ExUnit.Case, async: false

  import Plug.Test

  alias Smalt.EventGridWebhook
  alias Smalt.EventGridWebhookPlug, as: Plug0

  setup do
    start_supervised!(EventGridWebhook)
    EventGridWebhook.reset()
    :ok
  end

  defp ev(id, extra \\ %{}) do
    Map.merge(
      %{
        "specversion" => "1.0",
        "id" => id,
        "source" => "/smalt/probe",
        "type" => "smalt.probe.kd101"
      },
      extra
    )
  end

  defp post_events(sub, body, headers \\ []) do
    Plug0.call(
      conn(:post, "/eventgrid/hooks/#{sub}", body)
      |> Plug.Conn.put_req_header("content-type", "application/cloudevents-batch+json")
      |> then(&put_headers(&1, headers)),
      []
    )
  end

  defp put_headers(conn, headers) do
    Enum.reduce(headers, conn, fn {k, v}, c -> Plug.Conn.put_req_header(c, k, v) end)
  end

  test "validation handshake 1: WebHook-Request-Origin answered, no delivery consumed" do
    conn =
      Plug0.call(
        conn(:options, "/eventgrid/hooks/sub-a")
        |> Plug.Conn.put_req_header("webhook-request-origin", "eg.example")
        |> Plug.Conn.put_req_header("webhook-request-rate", "500K"),
        []
      )

    assert conn.status == 200
    assert Enum.member?(conn.resp_headers, {"webhook-allowed-origin", "eg.example"})
    assert Enum.member?(conn.resp_headers, {"webhook-allowed-rate", "500K"})
    assert EventGridWebhook.delivered("sub_a") == %{}
  end

  test "handshake 1 rides POST too and echoes handler version" do
    conn =
      post_events("sub_a", "", [{"webhook-request-origin", "eg.example"}])

    assert conn.status == 200
    assert Plug.Conn.get_resp_header(conn, "webhook-allowed-origin") == ["eg.example"]
    assert EventGridWebhook.delivered("sub_a") == %{}
  end

  test "handshake 2: SubscriptionValidationEvent answers validationResponse, not delivered" do
    EventGridWebhook.register("sub_val")

    conn =
      post_events(
        "sub_val",
        Jason.encode!([
          ev("val-1", %{
            "type" => "Microsoft.EventGrid.SubscriptionValidationEvent",
            "data" => %{"validationCode" => "CODE123"}
          })
        ])
      )

    assert conn.status == 200
    assert Jason.decode!(conn.resp_body) == %{"validationResponse" => "CODE123"}
    refute EventGridWebhook.delivered?("sub_val", "val-1")
  end

  test "delivery roundtrip: registered in-proc subscriber receives CloudEvent + pull record" do
    EventGridWebhook.register("sub_rt")

    conn =
      post_events(
        "sub_rt",
        Jason.encode!([ev("kd101-1", %{"data" => %{"note" => "roundtrip"}})]),
        [{"aeg-event-type", "Notification"}, {"aeg-delivery-count", "1"}]
      )

    assert conn.status == 200

    # In-proc message face.
    assert_receive {:event_grid_webhook, "sub_rt", "kd101-1", %{"data" => %{"note" => "roundtrip"}}}

    # Pull face: recorded with aeg-* metadata.
    recs = EventGridWebhook.delivered("sub_rt")
    assert Map.has_key?(recs, "kd101-1")
    assert recs["kd101-1"]["meta"]["aeg-event-type"] == "Notification"
    assert recs["kd101-1"]["meta"]["aeg-delivery-count"] == "1"
    assert %DateTime{} = recs["kd101-1"]["delivered_at"]
  end

  test "single-event body (non-batch) delivers" do
    EventGridWebhook.register("sub_single")

    conn = post_events("sub_single", Jason.encode!(ev("single-1")))

    assert conn.status == 200
    assert EventGridWebhook.delivered?("sub_single", "single-1")
  end

  test "unknown subscriber -> typed 404, no record" do
    conn = post_events(:never_registered, Jason.encode!([ev("x-1")]))

    assert conn.status == 404
    assert %{"error" => %{"code" => "UnknownSubscriber"}} = Jason.decode!(conn.resp_body)
  end

  test "invalid CloudEvent -> typed 400" do
    EventGridWebhook.register("sub_bad")

    conn = post_events("sub_bad", Jason.encode!([%{"id" => "no-specversion"}]))

    assert conn.status == 400
    assert %{"error" => %{"code" => "InvalidCloudEvent"}} = Jason.decode!(conn.resp_body)
    assert EventGridWebhook.delivered("sub_bad") == %{}
  end

  test "malformed JSON -> typed 400" do
    EventGridWebhook.register("sub_j")

    conn = post_events("sub_j", "{not json")

    assert conn.status == 400
    assert %{"error" => %{"code" => "InvalidJsonBody"}} = Jason.decode!(conn.resp_body)
  end

  test "non-eventgrid paths pass through untouched" do
    conn = Plug0.call(conn(:get, "/blob/container"), [])
    assert conn.status == nil
  end

  test "bridge: integration-plane fan-out and webhook receiver are separate faces" do
    start_supervised!(Smalt.Messaging.EventGrid)
    Smalt.Messaging.EventGrid.reset("t-bridge")
    Smalt.Messaging.EventGrid.subscribe("t-bridge", "sub_bridge")
    EventGridWebhook.register("sub_bridge")

    # Integration-plane channel: publish -> {:event_grid, ...} delivery.
    assert Smalt.Messaging.EventGrid.publish("t-bridge", %{id: "br-1", specversion: "1.0"}) ==
             :fresh

    assert_receive {:event_grid, "t-bridge", "sub_bridge", "br-1", _}

    # Webhook receiver channel: POST -> {:event_grid_webhook, ...} + record.
    conn = post_events("sub_bridge", Jason.encode!([ev("br-2")]))

    assert conn.status == 200

    assert_receive {:event_grid_webhook, "sub_bridge", "br-2", _}
    assert EventGridWebhook.delivered?("sub_bridge", "br-2")
  end
end
