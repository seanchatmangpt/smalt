# EXPL-11-R2 court — F2/F3 repairs: delivery truth in the CloudEvents witness
# buffer (F2) after a real POST, and dead-pid pruning + terminate-leaves-groups
# (F3). Chicago: real processes, no mocks.
defmodule Smalt.Internal.Expl11R2WpsServiceCourtTest do
  use ExUnit.Case, async: false

  Code.require_file("poll_helper.exs", __DIR__)

  # -- F2: delivery truth (real HTTP, dead handler) ---------------------------------

  test "F2: dead handler — witness carries delivered=false + refused typing" do
    prior = Application.get_env(:smalt, :web_pubsub_event_handler_url)

    on_exit(fn ->
      Application.put_env(:smalt, :web_pubsub_event_handler_url, prior)
    end)

    port = listen_and_close()
    Application.put_env(:smalt, :web_pubsub_event_handler_url, "http://127.0.0.1:#{port}/events")

    hub = "expl11r2-f2-#{System.unique_integer([:positive])}"
    :ok = Smalt.WebPubSub.Events.connect(hub, "c-f2", "u1")

    {:ok, ev} =
      SmaltTest.Internal.Poll.eventually(
        fn ->
          case Enum.find(Smalt.WebPubSub.events(), &(&1["hub"] == hub and &1["delivery_status"] != "pending")) do
            nil -> :pending
            ev -> {:ok, ev}
          end
        end,
        timeout_ms: 10_000
      )

    assert ev["type"] == "azure.webpubsub.sys.connect"
    assert ev["delivered"] == false
    assert ev["delivery_status"] =~ "refused"
  end

  # -- BK-WPSSKEP / WPS-SKEP-1: broker aliveness post-connect (anti-tautology) ------
  # The F2 defect class: a cast the broker doesn't match kills Smalt.WebPubSub on
  # every connect, yet suites passed because no leg asserted aliveness. This leg
  # pins it: connect with handler_url nil (no_handler path) and the broker must
  # still be alive after the delivery_result cast lands.

  test "WPS-SKEP-1: broker survives connect with handler_url nil (no_handler cast)" do
    prior = Application.get_env(:smalt, :web_pubsub_event_handler_url)
    Application.put_env(:smalt, :web_pubsub_event_handler_url, nil)

    on_exit(fn -> Application.put_env(:smalt, :web_pubsub_event_handler_url, prior) end)

    broker = Process.whereis(Smalt.WebPubSub)
    ref = Process.monitor(broker)

    hub = "wps-skep1-#{System.unique_integer([:positive])}"
    :ok = Smalt.WebPubSub.Events.connect(hub, "c-skep1", "u1")

    # The no_handler delivery_result cast is processed (witness flips to no_handler)
    {:ok, _ev} =
      SmaltTest.Internal.Poll.eventually(
        fn ->
          case Enum.find(Smalt.WebPubSub.events(), &(&1["hub"] == hub and &1["delivery_status"] == "no_handler")) do
            nil -> :pending
            ev -> {:ok, ev}
          end
        end,
        timeout_ms: 10_000
      )

    # Broker did not crash-and-restart on the cast (same pid, no DOWN)
    refute_received {:DOWN, ^ref, :process, ^broker, _reason}
    assert Process.alive?(broker)
    assert Process.whereis(Smalt.WebPubSub) == broker
  end

  # -- F3: membership pruning (real processes) --------------------------------------

  test "F3a: kill a member — members/publish prune the dead pid from raw state" do
    hub = "expl11r2-f3a-#{System.unique_integer([:positive])}"
    member = spawn(fn -> loop() end)

    :ok = Smalt.WebPubSub.join(hub, "g1", member)
    assert [^member] = Smalt.WebPubSub.members(hub, "g1")

    Process.exit(member, :kill)
    wait_dead(member)

    # publish is a prune point: the dead pid must leave RAW state, not just
    # the read-time filter.
    assert {:ok, 0} = Smalt.WebPubSub.publish(hub, "g1", "x")
    assert [] = Smalt.WebPubSub.members(hub, "g1")

    state = :sys.get_state(Smalt.WebPubSub)
    assert member not in (get_in(state, [:groups, hub, "g1"]) || [])
  end

  test "F3b: terminate/2 leaves the socket's groups" do
    hub = "expl11r2-f3b-#{System.unique_integer([:positive])}"
    sock = spawn(fn -> loop() end)

    :ok = Smalt.WebPubSub.join(hub, "g1", sock)
    assert [^sock] = Smalt.WebPubSub.members(hub, "g1")

    # Run terminate/2 INSIDE the socket's own process (self() is the leave
    # subject), then the process dies — membership must drop.
    :ok =
      run_in(sock, fn ->
        Smalt.WebPubSub.Socket.terminate(:normal, %Smalt.WebPubSub.Socket{
          hub: hub,
          conn_id: "c-f3b",
          user_id: "u",
          groups: ["g1"]
        })
      end)

    stop(sock)

    {:ok, []} =
      SmaltTest.Internal.Poll.eventually(
        fn ->
          if Smalt.WebPubSub.members(hub, "g1") == [] do
            {:ok, []}
          else
            :pending
          end
        end,
        timeout_ms: 5_000
      )

    state = :sys.get_state(Smalt.WebPubSub)
    assert get_in(state, [:groups, hub, "g1"]) in [nil, []]
  end

  # -- Helpers ----------------------------------------------------------------------

  # Real loopback port with no listener (real TCP reset on the POST).
  defp listen_and_close do
    {:ok, sock} = :gen_tcp.listen(0, [:binary, active: false])
    {:ok, port} = :inet.port(sock)
    :gen_tcp.close(sock)
    port
  end

  defp loop do
    receive do
      :stop -> :ok
      {:run, ref, from, fun} ->
        send(from, {ref, fun.()})
        loop()
    after
      30_000 -> :ok
    end
  end

  defp wait_dead(pid),
    do:
      SmaltTest.Internal.Poll.eventually(
        fn -> if Process.alive?(pid), do: :pending, else: {:ok, :dead} end,
        timeout_ms: 5_000
      )

  defp stop(pid), do: if(Process.alive?(pid), do: send(pid, :stop))

  defp run_in(pid, fun) do
    ref = make_ref()
    send(pid, {:run, ref, self(), fun})

    receive do
      {^ref, _result} -> :ok
    after
      5_000 -> flunk("run_in timed out")
    end
  end
end
