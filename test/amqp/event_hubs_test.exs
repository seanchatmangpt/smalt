unless Code.ensure_loaded?(Smalt.Amqp.Connection) do
  ExUnit.configure(exclude: [:amqp_wire])
end

defmodule Smalt.Messaging.EventHubsTest do
  use ExUnit.Case, async: false

  alias Smalt.Messaging.EventHubs

  setup do
    EventHubs.ensure_tables()
    :ok
  end

  defp part(suffix), do: "ns/testhub/#{suffix}-#{System.unique_integer([:positive])}"

  describe "per-partition monotonic sequence" do
    test "sequential sends are strictly monotonic from 1" do
      p = part("seq")

      seqs = for _ <- 1..10, {:ok, s, _} = EventHubs.send_event(p, "body"), do: s
      assert seqs == Enum.to_list(1..10)
      assert {:ok, 11} = EventHubs.next_sequence(p)
    end

    test "parallel senders never observe duplicate or regressing sequences" do
      p = part("parallel")
      tasks = 16
      per_task = 25

      results =
        1..tasks
        |> Enum.map(fn _ ->
          Task.async(fn ->
            for _ <- 1..per_task do
              {:ok, s, _} = EventHubs.send_event(p, "m")
              s
            end
          end)
        end)
        |> Task.await_many(15_000)

      all = List.flatten(results)
      assert length(all) == tasks * per_task
      assert length(Enum.uniq(all)) == tasks * per_task
      assert Enum.max(all) == tasks * per_task
      assert Enum.min(all) == 1
    end

    test "receiver gets events back in sequence order across parallel senders" do
      p = part("order")

      1..8
      |> Enum.map(fn _ ->
        Task.async(fn ->
          for i <- 1..20, do: EventHubs.send_event(p, "payload-#{i}")
        end)
      end)
      |> Task.await_many(15_000)

      events = EventHubs.receive_events(p, 0, 200)
      seqs = Enum.map(events, & &1["seq"])
      assert seqs == Enum.sort(seqs)
      assert length(seqs) == 160
    end
  end

  describe "checkpoint compare_and_swap" do
    test "exactly one of two concurrent CAS callers with the same expect wins" do
      g = "group-#{System.unique_integer([:positive])}"
      p = part("cas")

      {:ok, _seq, _} = EventHubs.send_event(p, "seed")
      {:ok, %{"seq" => seq}} = EventHubs.reconcile(g, p)

      expect = %{"seq" => 0, "offset" => 0, "etag" => 0}
      new = %{"seq" => seq, "offset" => seq, "etag" => 1}

      [r1, r2] =
        [1, 2]
        |> Enum.map(fn _ ->
          Task.async(fn -> EventHubs.compare_and_swap(g, p, expect, new) end)
        end)
        |> Task.await_many(10_000)

      results = Enum.sort([r1, r2])
      assert results == [:ok, {:error, :conflict}]
      assert {:ok, %{"checkpoint" => %{"seq" => ^seq}}} = EventHubs.reconcile(g, p)
    end

    test "second CAS against updated checkpoint conflicts" do
      g = "group2-#{System.unique_integer([:positive])}"
      p = part("cas2")

      expect = %{"seq" => 0, "offset" => 0, "etag" => 0}
      v1 = %{"seq" => 1, "offset" => 1, "etag" => 1}

      assert :ok = EventHubs.compare_and_swap(g, p, expect, v1)
      assert {:error, :conflict} = EventHubs.compare_and_swap(g, p, expect, %{"seq" => 9})
      assert {:ok, %{"checkpoint" => %{"seq" => 1}}} = EventHubs.reconcile(g, p)
    end

    # The Store.compare_and_swap/4 path is the one normally taken; the
    # serialized-server fallback is dead in ordinary runs (Store always
    # loads). Fence the fallback semantics directly through EHServer.
    test "serialized-server CAS fallback: exactly-one-winner semantics" do
      alias Smalt.Messaging.EventHubs.Server, as: EHServer
      g = "srv-cas-#{System.unique_integer([:positive])}"
      p = part("srv-cas")
      key = {g, p}

      {:ok, _seq, _} = EventHubs.send_event(p, "seed")
      expect = %{"seq" => 0, "offset" => 0, "etag" => 0}
      new = %{"seq" => 1, "offset" => 1, "etag" => 1}

      # Seed the zero checkpoint, as compare_and_swap/4 does before CAS.
      EventHubs.ensure_tables()
      :ets.insert(:smalt_eh_checkpoints, {key, expect})

      results =
        [1, 2, 3, 4]
        |> Enum.map(fn _ -> Task.async(fn -> EHServer.transaction({:cas_claim_blind, key, expect, new}) end) end)
        |> Task.await_many(10_000)

      assert Enum.sort(results) == [:ok, {:error, :conflict}, {:error, :conflict}, {:error, :conflict}]
      assert {:ok, %{"checkpoint" => %{"seq" => 1}}} = EventHubs.reconcile(g, p)
    end
  end

  describe "reserve_processing lease" do
    test "one live owner excludes others; expired lease is reclaimable after sweep" do
      g = "lease-#{System.unique_integer([:positive])}"
      p = part("lease")

      assert :ok = EventHubs.reserve_processing(g, p, :a, 10)
      assert {:error, :conflict} = EventHubs.reserve_processing(g, p, :b, 5_000)
      # same owner re-reserves freely (renewal)
      assert :ok = EventHubs.reserve_processing(g, p, :a, 10)

      Process.sleep(30)
      assert EventHubs.sweep() >= 0
      assert :ok = EventHubs.reserve_processing(g, p, :b, 5_000)
      assert {:error, :conflict} = EventHubs.reserve_processing(g, p, :a, 5_000)
    end
  end

  describe "reconcile" do
    test "reports broker-truth partition seq alongside stored checkpoint" do
      g = "rec-#{System.unique_integer([:positive])}"
      p = part("rec")

      for i <- 1..3, do: EventHubs.send_event(p, "e#{i}")

      {:ok, view} = EventHubs.reconcile(g, p)
      assert view["seq"] == 3
      assert view["checkpoint"] == nil

      assert :ok =
               EventHubs.compare_and_swap(g, p, %{"seq" => 0, "offset" => 0, "etag" => 0}, %{
                 "seq" => 2,
                 "offset" => 2,
                 "etag" => 1
               })

      {:ok, view} = EventHubs.reconcile(g, p)
      assert view["checkpoint"]["seq"] == 2
      refute Map.has_key?(view["checkpoint"], "claim")
    end

    # Lens-2 cycle 2: durability across sender-process churn — sender tasks
    # exit after sending; a fresh reader process must still see every event,
    # in strictly monotonic seq order, with broker truth intact.
    test "events survive sender-process churn: fresh reader sees all events in seq order" do
      p = part("churn")

      tasks =
        for t <- 1..8 do
          Task.async(fn ->
            for _i <- 1..10 do
              {:ok, _seq, _ev} = EventHubs.send_event(p, {:t, t})
            end

            :ok
          end)
        end

      for task <- tasks, do: assert :ok = Task.await(task, 10_000)

      parent = self()

      {:ok, reader} =
        Task.start(fn ->
          send(parent, {:seen, EventHubs.receive_events(p, 0, 100)})
        end)

      assert_receive {:seen, events}, 5_000
      ref = Process.monitor(reader)
      assert_receive {:DOWN, ^ref, :process, _, _}
      assert length(events) == 80

      seqs = Enum.map(events, & &1["seq"])
      assert seqs == Enum.sort(Enum.uniq(seqs))

      # Broker truth survives the churn.
      {:ok, view} = EventHubs.reconcile("any-group", p)
      assert view["seq"] == 80
    end

    test "live lease survives sweep; checkpoint CAS never moves broker-truth seq" do
      p = part("lease")
      g = "grp-#{System.unique_integer([:positive])}"

      for _ <- 1..3, do: {:ok, _, _} = EventHubs.send_event(p, "b")

      assert :ok = EventHubs.reserve_processing(g, p, self(), 60_000)

      # A live claim is untouched by sweep, and excludes other owners while
      # it holds (reconcile strips the claim field by contract; exclusivity is
      # the observable).
      EventHubs.sweep()
      assert {:error, :conflict} = EventHubs.reserve_processing(g, p, :other_owner, 60_000)

      # CAS the zero checkpoint to seq 3; broker truth was already 3 and must
      # not move.
      assert :ok =
               EventHubs.compare_and_swap(
                 g,
                 p,
                 %{"seq" => 0, "offset" => 0, "etag" => 0},
                 %{"seq" => 3, "offset" => 3, "etag" => 3}
               )

      {:ok, view2} = EventHubs.reconcile(g, p)
      assert view2["seq"] == 3
      assert view2["checkpoint"]["seq"] == 3

      # Advancing the broker seq does not move the checkpoint.
      {:ok, 4, _} = EventHubs.send_event(p, "b2")
      {:ok, view3} = EventHubs.reconcile(g, p)
      assert view3["seq"] == 4
      assert view3["checkpoint"]["seq"] == 3
    end
  end
end
