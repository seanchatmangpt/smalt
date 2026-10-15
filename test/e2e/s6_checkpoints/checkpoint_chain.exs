# S6 exactly-once checkpoint chain driver (substrate-local EventHubs semantics).
#
# Invoked as `mix run test/e2e/s6_checkpoints/checkpoint_chain.exs -- <wins-dir>`.
# Single BEAM by necessity: Smalt.Store / EventHubs backing tables are
# memory-resident ETS, so producer, the 4-consumer CAS race, and verification
# must share one VM. Receipt: test/e2e/s6_checkpoints/receipt.json
# plus a final stdout line RECEIPT:<json>.
#
# Started with `mix run --no-start` and boots :smalt on alternate ports so the
# scenario never collides with another lane's running instance (9443/8443).

wins_dir =
  System.argv() |> Enum.reject(&(&1 == "--")) |> Enum.at(0) ||
    raise "usage: mix run checkpoint_chain.exs -- <wins-dir>"

Application.put_env(:smalt, :arm_port, 19443)
Application.put_env(:smalt, :arm_tls_port, 19444)
Application.put_env(:smalt, :egress_port, 18443)
Application.put_env(:smalt, :amqp_port, 15672)
Application.put_env(:smalt, :event_hubs_port, 15673)
{:ok, _} = Application.ensure_all_started(:smalt)

group = "cg-s6"
partition_names = ["0", "1"]
partitions = Enum.map(partition_names, &("ns/hub/part-" <> &1))
total_events = 200
per_partition = div(total_events, length(partitions))

# -- Producer: 200 events, round-robin over 2 partitions (100 each) -----------
{producer_us, _} =
  :timer.tc(fn ->
    Enum.each(1..total_events, fn i ->
      p = "ns/hub/part-" <> Integer.to_string(rem(i - 1, length(partition_names)))
      {:ok, _seq, _event} = Smalt.Messaging.EventHubs.send_event(p, {:s6, i}, [])
    end)
  end)

producer_counts =
  Enum.into(partitions, %{}, fn p ->
    {p, length(Smalt.Messaging.EventHubs.receive_events(p, 0, 10_000))}
  end)

# -- 4 concurrent consumers racing on compare_and_swap per (group, partition) --
# Each consumer repeatedly reads the authoritative checkpoint via reconcile/2,
# then attempts CAS cur -> cur+1. Exactly one of the 4 wins each step (:ok);
# the other three get {:error, :conflict}. A seq can therefore be won once.
consumer_task = fn consumer_id ->
  Task.async(fn ->
    Enum.flat_map(partitions, fn partition ->
      Enum.reduce_while(1..per_partition, [], fn _step, acc ->
        {:ok, view} = Smalt.Messaging.EventHubs.reconcile(group, partition)
        cp = view["checkpoint"] || %{"seq" => 0, "offset" => 0, "etag" => 0}
        cur = Map.get(cp, "seq", 0)

        if cur >= per_partition do
          {:cont, acc}
        else
          expect = Map.take(cp, ["seq", "offset", "etag"])
          new = %{"seq" => cur + 1, "offset" => cur + 1, "etag" => Map.get(cp, "etag", 0) + 1}

          case Smalt.Messaging.EventHubs.compare_and_swap(group, partition, expect, new) do
            :ok -> {:cont, acc ++ [{partition, cur + 1}]}
            {:error, :conflict} -> {:cont, acc}
          end
        end
      end)
    end)
  end)
end

results = Task.await_many(Enum.map(1..4, consumer_task), 120_000)

# -- Verification ---------------------------------------------------------------
wins_by_partition =
  results
  |> Enum.flat_map(fn wins -> wins end)
  |> Enum.group_by(fn {p, _s} -> p end)
  |> Enum.into(%{}, fn {p, pairs} -> {p, Enum.map(pairs, fn {_p, s} -> s end) |> Enum.sort()} end)

per_partition_report =
  Enum.map(partitions, fn p ->
    {:ok, view} = Smalt.Messaging.EventHubs.reconcile(group, p)
    cp_seq = view["checkpoint"] && view["checkpoint"]["seq"]
    wins = Map.get(wins_by_partition, p, [])
    expected = Enum.to_list(1..per_partition)

    %{
      "partition" => p,
      "produced" => producer_counts[p],
      "checkpoint_seq" => cp_seq,
      "broker_seq" => view["seq"],
      "cas_wins" => length(wins),
      "win_sequence" => if(wins == expected, do: "1..#{per_partition} complete+ordered", else: inspect(wins)),
      "exactly_once" => wins == expected
    }
  end)

cas_successes = results |> Enum.flat_map(fn wins -> wins end) |> length

exactly_once =
  cas_successes == total_events and
    Enum.all?(per_partition_report, & &1["exactly_once"]) and
    Enum.all?(per_partition_report, &(&1["checkpoint_seq"] == per_partition)) and
    Enum.all?(per_partition_report, &(&1["broker_seq"] == per_partition))

receipt = %{
  "scenario" => "s6_checkpoints",
  "mode" => "substrate-local (no EH wire endpoint; Store CAS contract)",
  "group" => "cg-s6",
  "events_sent" => total_events,
  "partitions" => 2,
  "consumers" => 4,
  "cas_successes_total" => cas_successes,
  "zero_double_processing" => exactly_once,
  "partitions_report" => per_partition_report,
  "producer_us" => producer_us,
  "verdict" => if(exactly_once, do: "EXACTLY_ONCE_OK", else: "CAS_CHAIN_BROKEN")
}

File.write!(Path.join(wins_dir, "receipt.json"), Jason.encode!(receipt, pretty: true))

IO.puts("RECEIPT:" <> Jason.encode!(receipt))
System.halt(if(exactly_once, do: 0, else: 1))
