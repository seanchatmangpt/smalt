defmodule PopcornDemo.LiveTopicTest do
  @moduledoc """
  X3 lane Chicago tests for the Service Bus TOPIC leg: the only collaborators
  are the REAL substrate (ARM face on 127.0.0.1:9443, SB AMQP plane on
  127.0.0.1:5672) over real :gen_tcp / :httpc. No mocks. Skips loudly only
  when the SB plane is down.
  """

  use ExUnit.Case, async: false

  sb_port = String.to_integer(System.get_env("X3_SB_AMQP_PORT") || "5672")

  sb_down? =
    case :gen_tcp.connect(~c"127.0.0.1", sb_port, [:binary, active: false], 2_000) do
      {:ok, sock} ->
        :gen_tcp.close(sock)
        false

      _ ->
        true
    end

  # SAS put-token needs the substrate's key; without it the walk cannot
  # authenticate (loud SKIP, never a fake pass)
  no_key? = is_nil(System.get_env("SMALT_SB_SHARED_KEY"))

  sb_skip =
    cond do
      no_key? -> "SMALT_SB_SHARED_KEY unset - SB CBS SAS cannot authenticate"
      sb_down? -> "SB plane down on " <> Integer.to_string(sb_port) <> " - boot the lane substrate"
      true -> false
    end

  if is_binary(sb_skip) do
    IO.puts(:stderr, "[popcorn_demo] SKIP: " <> sb_skip)
  end

  @tag skip: sb_skip
  test "topic walk publishes 2 messages and delivers both byte-exact on the subscription" do
    topic = "popcorn-tx-#{System.system_time(:millisecond)}-#{:rand.uniform(999_999)}"

    assert {:ok, "topic=OK(" <> rest} = PopcornDemo.LiveTopic.run(topic)
    assert rest == "#{topic}:2-delivered)"
  end

  @tag skip: sb_skip
  test "walk is repeatable (second run on a fresh topic also OK)" do
    assert {:ok, "topic=OK(" <> _} = PopcornDemo.LiveTopic.run()
    assert {:ok, "topic=OK(" <> _} = PopcornDemo.LiveTopic.run()
  end

  @tag skip: sb_skip
  test "two distinct topics stay isolated (no cross-topic delivery)" do
    ms = System.system_time(:millisecond)
    t1 = "popcorn-tx-#{ms}-iso-a"
    t2 = "popcorn-tx-#{ms}-iso-b"

    assert {:ok, "topic=OK(" <> r1} = PopcornDemo.LiveTopic.run(t1)
    assert r1 == "#{t1}:2-delivered)"
    assert {:ok, "topic=OK(" <> r2} = PopcornDemo.LiveTopic.run(t2)
    assert r2 == "#{t2}:2-delivered)"
  end
end
