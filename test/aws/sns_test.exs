defmodule Smalt.AWS.SNSTest do
  use ExUnit.Case, async: true
  import Plug.Test
  import Plug.Conn
  alias Smalt.AWS.SigV4
  alias Smalt.AWS.SNS.Router
  alias Smalt.Egress.Sqs.SqsActions

  @creds %{"AKIDTEST" => "secretTEST"}

  setup do
    name = :"sns_#{System.unique_integer([:positive])}"
    start_supervised!({Smalt.AWS.SNS, name: name})
    q = "snsq#{System.unique_integer([:positive])}"
    {:ok, _} = SqsActions.create_queue("localhost", %{"QueueName" => q})
    {:ok, o: Router.init(server: name, creds: @creds), q: q}
  end

  defp call(o, params, signed? \\ true) do
    body = URI.encode_query(params)
    date = "20260101T000000Z"
    hs = [{"host", "localhost"}, {"x-amz-date", date}, {"content-type", "application/x-www-form-urlencoded"}]
    auth = SigV4.sign(%{method: "POST", path: "/", query: "", headers: hs, body: body, access_key_id: "AKIDTEST",
                        secret: if(signed?, do: "secretTEST", else: "wrong"), region: "us-east-1", service: "sns", amz_date: date})
    c = Enum.reduce(hs, conn("POST", "/", body), fn {k, v}, c -> %{c | req_headers: c.req_headers ++ [{k, v}]} end)
    Router.call(put_req_header(c, "authorization", auth), o)
  end

  defp tag(xml, t), do: Regex.run(~r/<#{t}>([^<]*)<\/#{t}>/, xml) |> List.last()

  defp drain(q) do
    {:ok, %{"Messages" => m}} = SqsActions.receive_message("localhost", %{"QueueUrl" => SqsActions.queue_url("localhost", q), "MaxNumberOfMessages" => "10"})
    Enum.map(m, & &1["Body"])
  end

  defp topic(o, name), do: call(o, %{"Action" => "CreateTopic", "Name" => name}).resp_body |> tag("TopicArn")

  defp sub(o, t, q, attrs \\ []) do
    base = %{"Action" => "Subscribe", "TopicArn" => t, "Protocol" => "sqs", "Endpoint" => "arn:aws:sqs:us-east-1:000000000000:" <> q}
    extra = attrs |> Enum.with_index(1) |> Enum.flat_map(fn {{k, v}, i} -> [{"Attributes.entry.#{i}.key", k}, {"Attributes.entry.#{i}.value", v}] end) |> Map.new()
    call(o, Map.merge(base, extra))
  end

  test "bad signature refused; non-sns passes through", %{o: o} do
    assert call(o, %{"Action" => "ListTopics"}, false).status == 403
    assert Router.call(conn("GET", "/"), o).halted == false
  end

  test "publish fans out to a real SQS queue; raw delivery", %{o: o, q: q} do
    t = topic(o, "t1")
    assert t =~ "arn:aws:sns:us-east-1:000000000000:t1"
    assert sub(o, t, q, [{"RawMessageDelivery", "true"}]).status == 200
    p = call(o, %{"Action" => "Publish", "TopicArn" => t, "Message" => "hello"})
    assert p.status == 200 and tag(p.resp_body, "MessageId")
    assert drain(q) == ["hello"]
  end

  test "envelope delivery and filter policy subset", %{o: o, q: q} do
    t = topic(o, "t2")
    sub(o, t, q, [{"FilterPolicy", ~s({"color":["red",{"prefix":"bl"}]})}])
    pub = fn msg, color ->
      call(o, %{"Action" => "Publish", "TopicArn" => t, "Message" => msg,
                "MessageAttributes.entry.1.Name" => "color", "MessageAttributes.entry.1.Value.DataType" => "String",
                "MessageAttributes.entry.1.Value.StringValue" => color})
    end
    for {m, c} <- [{"a", "red"}, {"b", "green"}, {"c", "blue"}], do: assert(pub.(m, c).status == 200)
    bodies = drain(q) |> Enum.map(&Jason.decode!/1)
    assert bodies |> Enum.map(& &1["Message"]) |> Enum.sort() == ["a", "c"]
    assert Enum.all?(bodies, &(&1["Type"] == "Notification" and &1["TopicArn"] == t))
  end

  test "unknown topic is NotFound; delete topic drops subscriptions; list", %{o: o, q: q} do
    assert call(o, %{"Action" => "Publish", "TopicArn" => "arn:aws:sns:us-east-1:000000000000:nope", "Message" => "x"}).status == 404
    t = topic(o, "t3")
    sub(o, t, q)
    assert call(o, %{"Action" => "ListSubscriptionsByTopic", "TopicArn" => t}).resp_body =~ q
    call(o, %{"Action" => "DeleteTopic", "TopicArn" => t})
    refute call(o, %{"Action" => "ListTopics"}).resp_body =~ "t3"
    assert call(o, %{"Action" => "ListSubscriptions"}).resp_body =~ q == false
  end
end
