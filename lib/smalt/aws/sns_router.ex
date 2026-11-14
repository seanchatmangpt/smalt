defmodule Smalt.AWS.SNS.Router do
  @moduledoc """
  SNS query-protocol wire face (AS3). Plug; opts: `server:` (SNS agent name),
  `creds:`, `verify:` (default true). Claims only SigV4 scope service `sns`.
  MOUNT (coordinator, egress_router.ex): `plug(Smalt.AWS.SNS.Router, server: Smalt.AWS.SNS.Default, creds: ...)`.
  """
  @behaviour Plug
  import Plug.Conn
  alias Smalt.AWS.{SigV4, SNS}
  alias Smalt.Egress.Sqs.SqsQuery

  def init(o), do: o

  def call(conn, opts) do
    case get_req_header(conn, "authorization") do
      ["AWS4-HMAC-SHA256" <> _ = a] ->
        case SigV4.parse_auth(a) do
          {:ok, %{service: "sns", region: r}} -> conn |> serve(opts, r) |> halt()
          _ -> conn
        end

      _ -> conn
    end
  end

  defp serve(conn, opts, region) do
    {:ok, body, conn} = read_body(conn, length: 1_000_000)

    verified =
      if Keyword.get(opts, :verify, true), do: SigV4.verify(conn, body, Keyword.fetch!(opts, :creds)), else: {:ok, nil}

    case verified do
      {:ok, _} -> action(conn, URI.decode_query(body), Keyword.fetch!(opts, :server), region)
      {:error, :mismatch} -> err(conn, 403, "SignatureDoesNotMatch", "The request signature we calculated does not match the signature you provided.")
      {:error, :unknown_key} -> err(conn, 403, "InvalidClientTokenId", "The security token included in the request is invalid.")
      {:error, _} -> err(conn, 403, "AccessDenied", "Access Denied")
    end
  end

  defp action(conn, p, s, region) do
    case p["Action"] do
      "CreateTopic" -> r(conn, SNS.create_topic(s, region, p["Name"]), fn arn -> "<CreateTopicResult><TopicArn>#{arn}</TopicArn></CreateTopicResult>" end)
      "DeleteTopic" -> SNS.delete_topic(s, p["TopicArn"]); ok(conn, "DeleteTopic", "")
      "ListTopics" ->
        m = SNS.list_topics(s) |> Enum.map_join(fn a -> "<member><TopicArn>#{a}</TopicArn></member>" end)
        ok(conn, "ListTopics", "<ListTopicsResult><Topics>#{m}</Topics></ListTopicsResult>")
      "Subscribe" ->
        attrs = SqsQuery.entries_all(p, "Attributes.entry") |> Map.new(&{&1["key"], &1["value"]})
        r(conn, SNS.subscribe(s, p["TopicArn"], p["Protocol"], p["Endpoint"], attrs), fn a -> "<SubscribeResult><SubscriptionArn>#{a}</SubscriptionArn></SubscribeResult>" end)
      "Unsubscribe" -> SNS.unsubscribe(s, p["SubscriptionArn"]); ok(conn, "Unsubscribe", "")
      "SetSubscriptionAttributes" ->
        r(conn, SNS.set_subscription_attribute(s, p["SubscriptionArn"], p["AttributeName"], p["AttributeValue"]), fn _ -> "" end, "SetSubscriptionAttributes")
      "GetSubscriptionAttributes" ->
        r(conn, SNS.get_subscription_attributes(s, p["SubscriptionArn"]), fn m ->
          e = Enum.map_join(m, fn {k, v} -> "<entry><key>#{esc(k)}</key><value>#{esc(v)}</value></entry>" end)
          "<GetSubscriptionAttributesResult><Attributes>#{e}</Attributes></GetSubscriptionAttributesResult>"
        end, "GetSubscriptionAttributes")
      a when a in ["ListSubscriptions", "ListSubscriptionsByTopic"] ->
        m = SNS.list_subscriptions(s, if(a == "ListSubscriptionsByTopic", do: p["TopicArn"]))
            |> Enum.map_join(fn v -> "<member><SubscriptionArn>#{v.arn}</SubscriptionArn><TopicArn>#{v.topic}</TopicArn><Protocol>#{v.protocol}</Protocol><Endpoint>#{v.endpoint}</Endpoint></member>" end)
        ok(conn, a, "<#{a}Result><Subscriptions>#{m}</Subscriptions></#{a}Result>")
      "Publish" ->
        attrs =
          for e <- SqsQuery.entries_all(p, "MessageAttributes.entry"), into: %{} do
            {e["Name"], %{type: e["Value.DataType"], value: e["Value.StringValue"]}}
          end
        topic = p["TopicArn"] || p["TargetArn"]
        r(conn, SNS.publish(s, region, topic, p["Message"], attrs, p["Subject"]), fn id -> "<PublishResult><MessageId>#{id}</MessageId></PublishResult>" end)
      other -> err(conn, 400, "InvalidAction", "Unknown action #{inspect(other)}")
    end
  end

  defp r(conn, res, f, name \\ nil)
  defp r(conn, {:ok, v}, f, name), do: ok(conn, name || action_name(f.(v)), f.(v))
  defp r(conn, :ok, f, name), do: ok(conn, name, f.(nil))
  defp r(conn, {:error, c, m}, _, _), do: err(conn, if(c == "NotFound", do: 404, else: 400), c, m)

  defp action_name(x), do: x |> String.slice(1..-1//1) |> String.split("Result") |> hd()

  defp ok(conn, name, inner) do
    inner = if String.starts_with?(inner, "<#{name}Result"), do: inner, else: inner
    sns_resp(conn, 200, "<#{name}Response xmlns=\"http://sns.amazonaws.com/doc/2010-03-31/\">#{inner}<ResponseMetadata><RequestId>#{rid()}</RequestId></ResponseMetadata></#{name}Response>")
  end

  defp err(conn, status, code, msg) do
    sns_resp(conn, status, "<ErrorResponse xmlns=\"http://sns.amazonaws.com/doc/2010-03-31/\"><Error><Type>Sender</Type><Code>#{code}</Code><Message>#{esc(msg)}</Message></Error><RequestId>#{rid()}</RequestId></ErrorResponse>")
  end

  defp sns_resp(conn, status, xml), do: conn |> put_resp_content_type("text/xml") |> send_resp(status, xml)
  defp rid, do: :crypto.strong_rand_bytes(8) |> Base.encode16(case: :lower)
  defp esc(s), do: s |> to_string() |> String.replace("&", "&amp;") |> String.replace("<", "&lt;") |> String.replace(">", "&gt;")
end
