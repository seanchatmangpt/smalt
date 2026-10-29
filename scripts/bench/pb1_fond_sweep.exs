# PB-1 lane, native leg — FOND contingency-loop latency through the native
# POWL2 path (Smalt.POWL2.Executor + Smalt.POWL2.ChangeFeed).
#
# Sweep: forced stale-etag CAS contention 0..10 retries per settlement. Each
# transition op settles one document via ChangeFeed CAS: R forced stale-etag
# attempts (412 carrying the current etag) then one CAS match (200). Wall per
# orchestration = one PartialOrder of 4 concurrent transitions.
#
# Self-contained: starts ONLY the ChangeFeed gen_statem (private named ETS
# tables per rate), never the full smalt app (no port binds, safe beside a
# live substrate). Run with --no-start.
#
#   MIX_ENV=test mix run --no-start scripts/bench/pb1_fond_sweep.exs

alias Smalt.POWL2.ChangeFeed
alias Smalt.POWL2.Executor
alias Smalt.POWL2.Reticle.AST.{PartialOrder, Transition}

rates = 0..10
waves = 150
warmup = 20
fanout = 4

System.put_env("SMALT_PB1", "1")

# Emitted as JSON rows; the bash driver validates and appends to
# tmp/bench/pb1-fond-sweep.jsonl.
stats = fn ->
  Enum.map(rates, fn r ->
    base = :"pb1_cf_#{r}"
    # isolate per rate: stop any prior server, fresh ETS tables
    Process.whereis(base) && Process.exit(Process.whereis(base), :kill)
    Process.sleep(5) # SLEEP-CLASS: POLL-STEP (bounded teardown reaping)
    {:ok, _} = ChangeFeed.start_link(base: base)

    pk = "pb1"
    ids = Enum.map(1..fanout, &"doc#{r}-#{&1}")

    # seed: create the settlement docs once (no If-Match)
    Enum.each(ids, fn id ->
      {:ok, 201, _} = ChangeFeed.put_item(base, pk, id, %{"v" => 0})
    end)

    settle = fn id ->
      fn _ctx ->
        # One CAS settlement: R forced stale etags (412 -> recover the current
        # etag via etag read, the real CAS-loser recovery shape), then one
        # match (200). Each transition settles its OWN doc (no cross-task CAS
        # race); contention = the injected stale-etag loop, deterministic.
        cur =
          if r > 0 do
            {:error, 412, _} =
              ChangeFeed.put_item(base, pk, id, %{"v" => 1}, if_match: "pb1-stale-seed")

            ChangeFeed.etag(base, pk, id)
          else
            ChangeFeed.etag(base, pk, id)
          end

        cur =
          if r > 1 do
            Enum.reduce(2..r, cur, fn i, cur ->
              {:error, 412, cur2} =
                ChangeFeed.put_item(base, pk, id, %{"v" => 1}, if_match: "pb1-stale-#{i}")

              cur2
            end)
          else
            cur
          end

        {:ok, 200, _} = ChangeFeed.put_item(base, pk, id, %{"v" => 2}, if_match: cur)
        {:ok, %{}}
      end
    end

    # Each of the 4 concurrent frontier transitions settles its OWN doc —
    # contention is the injected stale-etag loop inside each settlement
    # (deterministic, race-free), mirroring the SDK leg's 4-doc fanout.
    model = %PartialOrder{
      children:
        Map.new(ids, fn id ->
          {String.to_atom(id), %Transition{id: String.to_atom(id), label: "settle", op: settle.(id)}}
        end),
      order: []
    }

    ctx0 = %{orchestration: r, last_outcome: nil}

    # warmup (untimed)
    Enum.each(1..warmup, fn w ->
      :ok = Executor.execute_admitted({:pb1, r, w}, {:ok, model}, ctx0, nil, self())
      receive do
        {:orchestration_completed, {:pb1, r, w}, _, _} -> :ok
        {:orchestration_failed, {:pb1, r, w}, o} -> exit({:warmup_failed, o})
      after
        5_000 -> exit(:warmup_timeout)
      end
    end)

    # timed waves
    walls =
      for w <- 1..waves do
        t0 = System.monotonic_time(:microsecond)

        :ok =
          Executor.execute_admitted({:pb1, r, w}, {:ok, model}, ctx0, nil, self())

        receive do
          {:orchestration_completed, {:pb1, r, w}, _, receipt} ->
            wall_us = System.monotonic_time(:microsecond) - t0
            if receipt.status == :completed, do: wall_us / 1000, else: exit({:bad_receipt, receipt})

          {:orchestration_failed, {:pb1, r, w}, o} ->
            exit({:orchestration_failed, o})
        after
          10_000 -> exit(:orchestration_timeout)
        end
      end

    sorted = Enum.sort(walls)
    p = fn q -> Enum.at(sorted, round(q / 100 * (waves - 1))) end
    total = Enum.sum(walls)
    ops = waves / (total / 1000)

    %{
      "contention_pct" => r * 10,
      "retries_forced" => r,
      "n" => waves,
      "ops_per_sec" => Float.round(ops, 2),
      "p50_ms" => Float.round(p.(50), 3),
      "p95_ms" => Float.round(p.(95), 3),
      "p99_ms" => Float.round(p.(99), 3),
      "errors" => 0
    }
  end)
end

native_rows = stats.()

otp_s = to_string(:erlang.system_info(:otp_release))
cores = :erlang.system_info(:logical_processors) |> to_string()

machine_json =
  Jason.encode!(%{
    "cpu" => "apple-silicon-host",
    "cores" => cores,
    "ram_gb" => "see-driver",
    "elixir" => System.version(),
    "otp" => otp_s,
    "darwin" => "see-driver"
  })

for row <- native_rows do
  row =
    row
    |> Map.put("lane", "pb1")
    |> Map.put("surface", "fond-powl2-native")
    |> Map.put("op", "settle_r#{row["retries_forced"]}")
    |> Map.put("machine", Jason.decode!(machine_json))

  IO.puts("PB1ROW " <> Jason.encode!(row))
end

IO.puts("PB1NATIVE-DONE")
