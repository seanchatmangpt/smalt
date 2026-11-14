defmodule Smalt.Gcp.PubSubRouterTest do
  # GS2 Chicago court: real Plug.Test conns through the real router, real
  # engine, real queue substrate. Final-state assertions only.
  use ExUnit.Case, async: false
  import Plug.Test
  import Plug.Conn

  alias Smalt.Gcp.PubSubRouter

  setup do
    :ok = Smalt.Gcp.PubSub.reset()
    on_exit(fn -> Smalt.Gcp.PubSub.reset() end)
    :ok
  end

  defp req(method, path, body \\ nil) do
    conn = conn(method, path, body && Jason.encode!(body)) |> put_req_header("content-type", "application/json") |> Map.put(:host, "pubsub.googleapis.com")
    out = PubSubRouter.route(conn)
    {out.status, Jason.decode!(out.resp_body)}
  end

  test "REST v1 round trip: create, publish, pull, acknowledge" do
    base = "/v1/projects/gs2-rest"
    assert {200, %{"name" => "projects/gs2-rest/topics/tr1"}} = req("PUT", "#{base}/topics/tr1")
    assert {200, %{"topic" => _}} = req("PUT", "#{base}/subscriptions/sr1", %{"topic" => "projects/gs2-rest/topics/tr1"})

    assert {200, %{"messageIds" => [_]}} =
             req("POST", "#{base}/topics/tr1:publish", %{"messages" => [%{"data" => Base.encode64("hi")}]})

    # now_ms is a clock seam; the wire face uses the real clock, and a
    # just-published message is immediately visible.
    assert {200, %{"receivedMessages" => [%{"ackId" => ack, "message" => %{"data" => d}}]}} =
             req("POST", "#{base}/subscriptions/sr1:pull", %{"maxMessages" => 5})

    assert Base.decode64!(d) == "hi"
    assert {200, %{}} = req("POST", "#{base}/subscriptions/sr1:acknowledge", %{"ackIds" => [ack]})
    assert {200, %{"receivedMessages" => []}} = req("POST", "#{base}/subscriptions/sr1:pull", %{"maxMessages" => 5})
    assert {200, %{"topics" => [_]}} = req("GET", "#{base}/topics")
  end

  test "typed errors on the wire; foreign paths fall through" do
    assert {404, %{"error" => %{"status" => "NOT_FOUND", "code" => 404}}} =
             req("GET", "/v1/projects/gs2-rest/topics/missing-topic")

    assert {200, _} = req("PUT", "/v1/projects/gs2-rest/topics/top")
    assert {200, _} = req("PUT", "/v1/projects/gs2-rest/subscriptions/sub1", %{"topic" => "projects/gs2-rest/topics/top"})

    assert {400, %{"error" => %{"status" => "INVALID_ARGUMENT"}}} =
             req("POST", "/v1/projects/gs2-rest/subscriptions/sub1:pull", %{"maxMessages" => 0})

    assert PubSubRouter.route(conn("GET", "/v1/other/thing")) == nil
  end
end
