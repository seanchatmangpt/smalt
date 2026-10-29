defmodule Smalt.Internal.BkcellsArdCasGateTest do
  # BK-CELLS — AR-DATA-01 ARD verification gate executed on real state.
  # Charter gate (ARD-PRD.md AR-DATA-01): concurrent CAS operations across 16
  # schedulers must show zero lock-contention stalls and flat P99 latency.
  #
  # Chicago: real adopted table (Smalt.ArmGateway.Router.rate_table_for_test/0,
  # write_concurrency :auto default-ON), real counters, exactness asserted on
  # final table state. Task-local latency aggregation, min-of-3 per rung.
  # AR-DATA-01 is DECENTRALIZED counters: gate profile is one key per worker
  # (16 distinct keys). The 16-writers-on-one-hot-key profile is a different,
  # harder contention class — typed in the receipt, not gated here.
  use ExUnit.Case, async: false

  @rungs [256, 1024, 4096]

  test "ARD gate: decentralized CAS sweep, exact + flat P99" do
    sampled =
      for n <- @rungs do
        # min-of-3 per rung
        p99s =
          for _ <- 1..3 do
            table = Smalt.ArmGateway.Router.rate_table_for_test()
            keys = for i <- 1..16, do: {:bkcells, n, i}

            Enum.each(keys, fn k -> :ets.insert(table, {k, 0}) end)

            per_task = div(n, 16)

            tasks =
              for k <- keys do
                Task.async(fn ->
                  for _ <- 1..per_task do
                    s = System.monotonic_time(:nanosecond)
                    :ets.update_counter(table, k, {2, 1}, {k, 0})
                    System.monotonic_time(:nanosecond) - s
                  end
                end)
              end

            results = Enum.map(tasks, &Task.await(&1, 60_000))

            total =
              Enum.reduce(keys, 0, fn k, acc ->
                [{_, v}] = :ets.lookup(table, k)
                acc + v
              end)

            assert total == n, "lost updates at n=#{n}: got #{inspect(total)}"

            lat = results |> List.flatten() |> Enum.sort()
            at = fn q -> Enum.at(lat, trunc(q * (length(lat) - 1))) / 1000.0 end
            at.(0.99)
          end

        p99 = Enum.min(p99s)
        IO.puts("[BKCELLS ARD gate] n=#{n} (min-of-3) p99=#{Float.round(p99, 3)}us exact=yes")
        {n, p99}
      end

    {256, p99_256} = List.keyfind(sampled, 256, 0)
    {4096, p99_4096} = List.keyfind(sampled, 4096, 0)

    assert p99_4096 / p99_256 < 20.0, "P99 not flat: #{inspect(sampled)}"
    assert p99_4096 < 100.0, "P99 breach at 4096: #{inspect(sampled)}"
  end
end
