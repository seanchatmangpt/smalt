defmodule Smalt.AWS.SNS do
  @moduledoc """
  SNS core (AS3): topics, subscriptions, publish fan-out into the real SQS
  queues (`Smalt.Egress.Sqs.SqsActions`, same engine as AMQP/SB). Endpoint of
  an `sqs` subscription is a queue ARN `arn:aws:sqs:REGION:000000000000:name`.
  Filter policy subset (MessageAttributes scope): exact string match, `prefix`,
  `anything-but`, `exists`. `RawMessageDelivery=true` delivers the bare body,
  else the SNS JSON envelope.
  """
  use Agent
  alias Smalt.Egress.Sqs.SqsActions

  @acct "000000000000"

  def start_link(opts) do
    Agent.start_link(fn -> %{topics: %{}, subs: %{}} end, name: Keyword.get(opts, :name, __MODULE__))
  end

  def child_spec(opts), do: %{id: Keyword.get(opts, :name, __MODULE__), start: {__MODULE__, :start_link, [opts]}}

  def topic_arn(region, name), do: "arn:aws:sns:#{region}:#{@acct}:#{name}"

  def create_topic(s, region, name) do
    if Regex.match?(~r/^[A-Za-z0-9_-]{1,256}$/, name || "") do
      arn = topic_arn(region, name)
      Agent.update(s, fn st -> %{st | topics: Map.put_new(st.topics, arn, %{name: name, attrs: %{}}) } end)
      {:ok, arn}
    else
      {:error, "InvalidParameter", "Invalid parameter: Topic Name"}
    end
  end

  def delete_topic(s, arn) do
    Agent.update(s, fn st ->
      %{st | topics: Map.delete(st.topics, arn), subs: Map.reject(st.subs, fn {_, v} -> v.topic == arn end)}
    end)
  end

  def list_topics(s), do: Agent.get(s, fn st -> st.topics |> Map.keys() |> Enum.sort() end)

  def subscribe(s, topic, protocol, endpoint, attrs \\ %{}) do
    Agent.get_and_update(s, fn st ->
      cond do
        not Map.has_key?(st.topics, topic) -> {{:error, "NotFound", "Topic does not exist"}, st}
        protocol not in ["sqs"] -> {{:error, "InvalidParameter", "Invalid parameter: Protocol (supported: sqs)"}, st}
        sqs_name(endpoint) == :error -> {{:error, "InvalidParameter", "Invalid parameter: SQS endpoint ARN"}, st}
        true ->
          dup = Enum.find(st.subs, fn {_, v} -> v.topic == topic and v.endpoint == endpoint end)
          case dup do
            {arn, _} -> {{:ok, arn}, st}
            nil ->
              arn = topic <> ":" <> uuid()
              sub = %{topic: topic, protocol: protocol, endpoint: endpoint, attrs: attrs}
              {{:ok, arn}, %{st | subs: Map.put(st.subs, arn, sub)}}
          end
      end
    end)
  end

  def unsubscribe(s, arn), do: Agent.update(s, fn st -> %{st | subs: Map.delete(st.subs, arn)} end)

  def set_subscription_attribute(s, arn, name, value) do
    Agent.get_and_update(s, fn st ->
      case st.subs do
        %{^arn => sub} -> {:ok, %{st | subs: Map.put(st.subs, arn, %{sub | attrs: Map.put(sub.attrs, name, value)})}}
        _ -> {{:error, "NotFound", "Subscription does not exist"}, st}
      end
    end)
  end

  def get_subscription_attributes(s, arn) do
    Agent.get(s, fn st ->
      case st.subs do
        %{^arn => v} ->
          {:ok, Map.merge(v.attrs, %{"SubscriptionArn" => arn, "TopicArn" => v.topic, "Protocol" => v.protocol, "Endpoint" => v.endpoint})}
        _ -> {:error, "NotFound", "Subscription does not exist"}
      end
    end)
  end

  def list_subscriptions(s, topic \\ nil) do
    Agent.get(s, fn st ->
      for {arn, v} <- st.subs, topic in [nil, v.topic], do: Map.put(v, :arn, arn)
    end)
  end

  @doc "Publish; msg_attrs is %{name => %{type, value}}. Returns {:ok, message_id}."
  def publish(s, region, topic, message, msg_attrs \\ %{}, subject \\ nil) do
    st = Agent.get(s, & &1)

    if Map.has_key?(st.topics, topic) do
      id = uuid()
      for {sub_arn, sub} <- st.subs, sub.topic == topic, matches?(sub.attrs["FilterPolicy"], msg_attrs) do
        deliver(sub_arn, sub, region, id, message, msg_attrs, subject)
      end
      {:ok, id}
    else
      {:error, "NotFound", "Topic does not exist"}
    end
  end

  defp deliver(sub_arn, sub, region, id, message, msg_attrs, subject) do
    body =
      if sub.attrs["RawMessageDelivery"] == "true" do
        message
      else
        env = %{
          "Type" => "Notification", "MessageId" => id, "TopicArn" => sub.topic, "Message" => message,
          "Timestamp" => DateTime.utc_now() |> DateTime.to_iso8601(), "SignatureVersion" => "1",
          "UnsubscribeURL" => "http://localhost/?Action=Unsubscribe&SubscriptionArn=" <> sub_arn,
          "MessageAttributes" => Map.new(msg_attrs, fn {k, %{type: t, value: v}} -> {k, %{"Type" => t, "Value" => v}} end)
        }
        env = if subject, do: Map.put(env, "Subject", subject), else: env
        Jason.encode!(env)
      end

    _ = region
    SqsActions.send_message("localhost", %{"QueueUrl" => "http://localhost/#{@acct}/" <> sqs_name(sub.endpoint), "MessageBody" => body})
  end

  def sqs_name("arn:aws:sqs:" <> rest) do
    case String.split(rest, ":") do
      [_region, _acct, name] when name != "" -> name
      _ -> :error
    end
  end

  def sqs_name(_), do: :error

  # -- filter policy ---------------------------------------------------------------

  def matches?(nil, _), do: true
  def matches?(policy, attrs) when is_binary(policy) do
    case Jason.decode(policy) do
      {:ok, p} when is_map(p) -> matches?(p, attrs)
      _ -> false
    end
  end

  def matches?(policy, attrs) when is_map(policy) do
    Enum.all?(policy, fn {key, rules} ->
      v = case attrs do
        %{^key => %{value: v}} -> v
        _ -> nil
      end
      Enum.any?(List.wrap(rules), &rule?(&1, v))
    end)
  end

  defp rule?(%{"exists" => true}, v), do: v != nil
  defp rule?(%{"exists" => false}, v), do: v == nil
  defp rule?(_, nil), do: false
  defp rule?(%{"prefix" => p}, v), do: String.starts_with?(v, p)
  defp rule?(%{"anything-but" => x}, v), do: v not in List.wrap(x)
  defp rule?(x, v) when is_binary(x), do: x == v
  defp rule?(_, _), do: false

  defp uuid do
    <<a::32, b::16, c::16, d::16, e::48>> = :crypto.strong_rand_bytes(16)
    :io_lib.format("~8.16.0b-~4.16.0b-4~3.16.0b-~4.16.0b-~12.16.0b", [a, b, Bitwise.band(c, 0x0FFF), Bitwise.bor(Bitwise.band(d, 0x3FFF), 0x8000), e]) |> IO.iodata_to_binary()
  end
end
