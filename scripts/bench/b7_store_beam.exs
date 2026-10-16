# B-7: BEAM-level Store microbenchmarks — raw ETS/GenServer through Smalt.Store.
# Run: MIX_ENV=test mix run --no-start scripts/bench/b7_store_beam.exs
# No SDK, no HTTP: the BEAM floor the SDK benches sit on.

{:ok, _} = Smalt.Store.start_link([])

t0 = :erlang.monotonic_time(:millisecond)
:rand.seed(:exsss, {t0, t0 * 7919 + 13, t0 * 104729 + 7})

n = 120_000
batch = System.unique_integer([:positive])

# 100-key warmup per bench (JIT). Keys unique per batch to avoid dead-Vnode effects.
warm = fn f -> Enum.each(1..100, fn i -> f.(i) end) end

times_ms = fn f, ops ->
  # returns {total_ms, per_op_us_list_sampled}
  start = :erlang.monotonic_time(:microsecond)

  vals =
    Enum.map(1..ops, fn i ->
      s = :erlang.monotonic_time(:microsecond)
      f.(i)
      # sample latency every 50th op to keep the timer overhead < 1%
      if rem(i, 50) == 0,
        do: :erlang.monotonic_time(:microsecond) - s,
        else: nil
    end)

  total_us = :erlang.monotonic_time(:microsecond) - start
  {total_us / 1000, Enum.reject(vals, &is_nil/1)}
end

pcts = fn lats ->
  v = Enum.sort(lats)

  if v == [] do
    {0.0, 0.0, 0.0}
  else
    at = fn p -> Enum.at(v, round(p / 100 * (length(v) - 1))) / 1000 end
    {at.(50), at.(95), at.(99)}
  end
end

emit = fn op, n, ops_sec, {p50, p95, p99}, errors ->
  IO.puts(
    ~s({"lane":"b7","surface":"store-beam","op":"#{op}","n":#{n},"ops_per_sec":#{:erlang.float_to_binary(ops_sec * 1.0, decimals: 0)},"p50_ms":#{:erlang.float_to_binary(p50, decimals: 3)},"p95_ms":#{:erlang.float_to_binary(p95, decimals: 3)},"p99_ms":#{:erlang.float_to_binary(p99, decimals: 3)},"errors":#{errors}})
  )
end

sched = :erlang.system_info(:schedulers_online)

IO.puts(
  ~s({"lane":"b7","surface":"store-beam","op":"beam_meta","schedulers":#{sched},"logical":#{:erlang.system_info(:logical_processors_available)},"otp":#{:erlang.system_info(:otp_release) |> List.to_string() |> inspect()}})
)

# ---- (a) put: 120k unique keys into :smalt_resources ----
tbl = :smalt_resources
warm.(fn i -> Smalt.Store.put(tbl, "b7-warm-#{batch}-#{i}", %{"v" => i}) end)
{ms, lats} = times_ms.(fn i -> Smalt.Store.put(tbl, "b7-put-#{batch}-#{i}", %{"v" => i, "pad" => String.duplicate("x", 64)}) end, n)
{p50, p95, p99} = pcts.(lats)
emit.("put", n, n / (ms / 1000), {p50, p95, p99}, 0)

# ---- (b) get: 120k reads over the just-written keys ----
warm.(fn i -> Smalt.Store.get(tbl, "b7-put-#{batch}-#{i}") end)
{ms, lats} = times_ms.(fn i -> Smalt.Store.get(tbl, "b7-put-#{batch}-#{i}") end, n)
{p50, p95, p99} = pcts.(lats)
emit.("get", n, n / (ms / 1000), {p50, p95, p99}, 0)

# ---- (c) compare_and_swap single-writer: 120k CAS on rotating keys ----
cas_keys = Enum.map(1..100, fn i -> "b7-cas-#{batch}-#{i}" end)
Enum.each(cas_keys, fn k -> Smalt.Store.put(tbl, k, 0) end)
warm.(fn i ->
  k = Enum.at(cas_keys, rem(i, 100))
  {:ok, cur} = Smalt.Store.get(tbl, k)
  Smalt.Store.compare_and_swap(tbl, k, cur, cur + 1)
end)

cas_counter = :counters.new(1, [:atomics])

cas_f = fn i ->
  k = Enum.at(cas_keys, rem(i, 100))
  {:ok, cur} = Smalt.Store.get(tbl, k)

  case Smalt.Store.compare_and_swap(tbl, k, cur, cur + 1) do
    :ok -> :ok
    {:error, _} -> :counters.add(cas_counter, 1, 1) && :ok
  end
end

{ms, lats} = times_ms.(cas_f, n)
{p50, p95, p99} = pcts.(lats)
cas_errors = :counters.get(cas_counter, 1)
emit.("compare_and_swap", n, n / (ms / 1000), {p50, p95, p99}, cas_errors)

# ---- (d) 32-process concurrent put+get mixed ----
procs = 32
per = 8_000
parent = self()

t_start = :erlang.monotonic_time(:microsecond)

 Enum.each(1..procs, fn p ->
  spawn(fn ->
    Enum.each(1..per, fn i ->
      k = "b7-conc-#{batch}-#{p}-#{i}"
      :ok = Smalt.Store.put(tbl, k, %{"p" => p, "i" => i})
      {:ok, _} = Smalt.Store.get(tbl, k)
    end)

    send(parent, :done)
  end)
end)

Enum.each(1..procs, fn _ ->
  receive do
    :done -> :ok
  after
    60_000 -> exit(:timeout)
  end
end)

conc_ms = (:erlang.monotonic_time(:microsecond) - t_start) / 1000
conc_ops = procs * per * 2
emit.("concurrent_put_get_32p", conc_ops, conc_ops / (conc_ms / 1000), {0.0, 0.0, 0.0}, 0)

# ---- (e) list_prefix over 10k keys: full-scan ms ----
Enum.each(1..10_000, fn i -> Smalt.Store.put(:smalt_eh_checkpoints, "b7-scan-#{batch}/#{i}", i) end)
# warm the scan
Smalt.Store.list_prefix(:smalt_eh_checkpoints, "b7-scan-#{batch}/")

scan_start = :erlang.monotonic_time(:microsecond)
scanned = Smalt.Store.list_prefix(:smalt_eh_checkpoints, "b7-scan-#{batch}/")
scan_ms = (:erlang.monotonic_time(:microsecond) - scan_start) / 1000
scan_n = length(scanned)

emit_scan =
  ~s({"lane":"b7","surface":"store-beam","op":"list_prefix_10k","n":#{scan_n},"full_scan_ms":#{:erlang.float_to_binary(scan_ms, decimals: 3)},"keys_per_sec":#{:erlang.float_to_binary(scan_n / (scan_ms / 1000), decimals: 0)}})

IO.puts(emit_scan)

# ---- (f) insert_new 64 racers, exactly-one-winner ----
Enum.each(1..20, fn round ->
  key = "b7-race-#{batch}-#{round}"
  parent = self()

  t = :erlang.monotonic_time(:microsecond)

  Enum.each(1..64, fn _ ->
    spawn(fn ->
      r =
        try do
          Smalt.Store.insert_new(:smalt_resource_groups, key, %{"w" => self()})
        rescue
          _ -> {:error, :raised}
        end

      send(parent, {:r, r})
    end)
  end)

  outs =
    for _ <- 1..64 do
      receive do
        {:r, r} -> r
      after
        30_000 -> :timeout
      end
    end

  dt = :erlang.monotonic_time(:microsecond) - t
  winners = Enum.count(outs, &(&1 == :ok))
  losers = Enum.count(outs, &(&1 == {:error, :exists}))
  ok? = winners == 1 and losers == 63

  IO.puts(
    ~s({"lane":"b7","surface":"store-beam","op":"insert_new_race_64","round":#{round},"n":64,"winners":#{winners},"losers":#{losers},"ok":#{ok?},"total_ms":#{:erlang.float_to_binary(dt / 1000, decimals: 3)}})
  )
end)

# cleanup
Smalt.Store.clear()
IO.puts(~s({"lane":"b7","surface":"store-beam","op":"done"}))
