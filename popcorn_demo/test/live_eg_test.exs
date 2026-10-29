defmodule PopcornDemo.LiveEGTest do
  @moduledoc """
  Chicago-school test for the W3-9 Event Grid walk: the only collaborators
  are the REAL substrate (control plane 9443 + data plane 8443) over raw
  `:gen_tcp` sockets. No mocks. Skips loudly only when the substrate is
  actually down.

  The walk opens NO listener of its own (push delivery is not wired — the
  KD-101 typed refusal is the webhook face), so there is no ephemeral socket
  to reclaim: the on_exit law is satisfied vacuously and loudly, by
  construction, not by a swallowed cleanup.
  """

  use ExUnit.Case, async: false

  @skip "substrate down — run 9>&- just substrate-up"
  substrate_down? =
    with {:ok, sock} <- :gen_tcp.connect(~c"127.0.0.1", 9443, [:binary, active: false], 2_000) do
      :gen_tcp.close(sock)
      false
    else
      _ -> true
    end

  @substrate_skip if(substrate_down?, do: @skip, else: false)

  if substrate_down? do
    IO.puts(:stderr, "[popcorn_demo] SKIP: #{@skip}")
  end

  @tag skip: @substrate_skip
  test "full walk: bearer -> systemTopics PUT -> EG1 publish -> readback -> KD-101 refusal" do
    assert {:ok, "eg=OK(" <> rest} = PopcornDemo.LiveEG.run()
    assert rest =~ ":bearer-topic-publish-readback-kd101refusal)"
  end

  @tag skip: @substrate_skip
  test "walk is hermetic: a second run picks a fresh topic and passes again" do
    assert {:ok, "eg=OK(" <> _} = PopcornDemo.LiveEG.run()

    assert {:ok, "eg=OK(" <> rest2} = PopcornDemo.LiveEG.run()
    assert rest2 =~ ":bearer-topic-publish-readback-kd101refusal)"
  end
end
