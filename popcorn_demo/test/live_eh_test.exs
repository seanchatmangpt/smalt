defmodule PopcornDemo.LiveEhTest do
  @moduledoc """
  Chicago-school test for the W2-7 Event Hubs leg: the only collaborators are
  the REAL substrate EH plane (AMQP 1.0 on 127.0.0.1:5673) over a real
  `:gen_tcp` socket. No mocks. Skips loudly only when the EH plane is down.
  """

  use ExUnit.Case, async: false

  eh_down? =
    case :gen_tcp.connect(~c"127.0.0.1", 5673, [:binary, active: false], 2_000) do
      {:ok, sock} ->
        :gen_tcp.close(sock)
        false

      _ ->
        true
    end

  @eh_skip if(eh_down?, do: "EH plane down — run 9>&- just substrate-up", else: false)

  if eh_down? do
    IO.puts(:stderr, "[popcorn_demo] SKIP: EH plane down on 5673")
  end

  @tag skip: @eh_skip
  test "EH walk publishes a unique event and receives the same bytes back on the pinned partition" do
    assert {:ok, "eh=OK(popcorn-eh/0:" <> rest} = PopcornDemo.LiveEh.run()
    # <token>-roundtrip-<n>-events-scanned) — token itself starts "w27-evt-"
    assert Regex.match?(~r/w27-evt-\d+-roundtrip-\d+-events-scanned\)$/, rest)
    [_, n_str] = Regex.run(~r/-roundtrip-(\d+)-events-scanned\)$/, rest)
    assert String.to_integer(n_str) > 0
  end

  @tag skip: @eh_skip
  test "walk is repeatable (second run also OK — fresh token, same partition)" do
    assert {:ok, "eh=OK(" <> _} = PopcornDemo.LiveEh.run()
    assert {:ok, "eh=OK(" <> _} = PopcornDemo.LiveEh.run()
  end

  @tag skip: @eh_skip
  test "selector floor scans O(new events) against a seeded backlog (W13-R)" do
    # seed a REAL backlog over the real wire, then the walk must scan ONLY
    # its own post-floor event — the pre-publish @latest attach floor means
    # the roundtrip is O(new events), never O(backlog)
    assert {:ok, 20} = PopcornDemo.LiveEh.publish_events(20)
    assert {:ok, msg} = PopcornDemo.LiveEh.run()
    assert "eh=OK(" <> _ = msg

    [n_str] = Regex.run(~r/-roundtrip-(\d+)-events-scanned\)$/, msg, capture: :all_but_first)
    assert String.to_integer(n_str) == 1
  end

  @tag skip: @eh_skip
  test "selector floor is repeatable across runs (each run scans only its own event)" do
    assert {:ok, _} = PopcornDemo.LiveEh.publish_events(5)
    assert {:ok, msg1} = PopcornDemo.LiveEh.run()
    assert {:ok, msg2} = PopcornDemo.LiveEh.run()

    for msg <- [msg1, msg2] do
      [n_str] = Regex.run(~r/-roundtrip-(\d+)-events-scanned\)$/, msg, capture: :all_but_first)
      assert String.to_integer(n_str) == 1
    end
  end

  @tag skip: @eh_skip
  test "outcomes are typed: run/0 never returns an untagged value" do
    outcome = PopcornDemo.LiveEh.run()

    assert match?({:ok, _}, outcome) or match?({:skip, _}, outcome) or
             match?({:error, _}, outcome)
  end
end
