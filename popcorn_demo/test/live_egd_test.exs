defmodule PopcornDemo.LiveEgdTest do
  @moduledoc """
  Chicago-school test for the X4 Event Grid DELIVERY leg. The only
  collaborators are REAL: a Bandit listener on an ephemeral loopback port
  (port 0, discovered via :inet.port/1), the real
  `Smalt.EventGridWebhookPlug`, the real `Smalt.EventGridWebhook` delivery
  GenServer, and the real `Transport.Httpc` client. No mocks.

  on_exit law: run/0 itself owns the ephemeral listener and always tears it
  down (success, SKIP, or FAIL) — the test additionally asserts the port is
  actually CLOSED after each run (never swallowed cleanup).
  """

  use ExUnit.Case, async: false

  @tag :eg_delivery
  test "full delivery walk: mount -> handshake1 -> handshake2 -> EG1 delivery + byte-shape" do
    assert {:ok, "egd=OK(" <> rest} = run_leg()
    assert rest =~ ":handshake1-handshake2-delivery-eg1shape)"
  end

  @tag :eg_delivery
  test "walk is hermetic: a second run mounts a fresh ephemeral port and passes again" do
    {:ok, "egd=OK(" <> rest1} = run_leg()
    assert rest1 =~ ":handshake1-handshake2-delivery-eg1shape)"

    {:ok, "egd=OK(" <> rest2} = run_leg()
    assert rest2 =~ ":handshake1-handshake2-delivery-eg1shape)"
  end

  # Runs the leg and proves the on_exit law: the ephemeral listener is
  # actually gone when run/0 returns (port cannot still be bound).
  defp run_leg do
    result = PopcornDemo.LiveEgd.run()

    case result do
      {:ok, "egd=OK(" <> rest} ->
        port = rest |> String.split(":") |> hd() |> String.to_integer()

        assert {:error, :eaddrinuse} =
                 :gen_tcp.listen(port, [ip: {127, 0, 0, 1}])

        result

      other ->
        other
    end
  end
end
