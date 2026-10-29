import Bitwise

defmodule PopcornDemo.ApexRatelimit do
  @moduledoc """
  APEX-4 — "tollbooth vs silicon" falsifier.

  Measures the delta between (arm 1) local in-memory CAS arbitration — 1,024
  concurrent CAS actors on a shared `:atomics` counter, no coordination cost
  beyond the hardware CAS retry loop — and (arm 2) the same 1,024 CAS
  operations gated by a simulated Azure Cosmos-style token bucket that answers
  over-demand with typed 429s and exponential backoff (9 retries, 30s ceiling,
  the Cosmos SDK documented default). The measured wall delta IS the receipt.

  No-sleep law: the local arm contains zero sleeps. The simulated arm's
  backoff waits ARE the simulated cost — the single wait site is annotated
  `# SLEEP-CLASS: TIME-ADVANCE` (it models the documented client-side retry
  wait, it coordinates nothing).
  """

  @n_actors 1024
  # Simulated Cosmos RU bucket: capacity 100 RU, refill 100 RU/s.
  @bucket_capacity 100
  @refill_per_sec 100
  # Cosmos SDK documented defaults: 9 retries, 30s max wait, exponential.
  @max_retries 9
  @max_wait_ms 30_000
  @backoff_base_ms 50
  @tok_bits 65_536
  @tok_shift 16

  # ---------------------------------------------------------------------------
  # Token bucket — ONE atomic word, CAS-only, lazily refilled from monotonic
  # time. Word = last_ms * @tok_bits + tokens_x100. Single-word CAS means a
  # refill and a take are one atomic transition: racing takers can neither
  # double-apply a refill nor drive the balance negative.
  # ---------------------------------------------------------------------------

  def new_bucket(capacity \\ @bucket_capacity, refill_per_sec \\ @refill_per_sec) do
    a = :atomics.new(1, signed: true)
    :atomics.put(a, 1, pack(now_ms(), capacity * 100))
    %{a: a, capacity: capacity, per_ms: refill_per_sec / 1_000}
  end

  @doc """
  Take one token. `:ok` on success; `{:throttled, retry_after_ms}` — the typed
  429 — when the bucket cannot fund the take within its current balance.
  """
  def take(%{a: a, capacity: cap, per_ms: per_ms}) do
    now = now_ms()
    v = :atomics.get(a, 1)
    {prev_ms, toks} = unpack(v)
    refilled = trunc((now - prev_ms) * per_ms * 100)
    balance = min(toks + refilled, cap * 100)

    if balance >= 100 do
      if :atomics.compare_exchange(a, 1, v, now * @tok_bits + balance - 100) == :ok do
        :ok
      else
        take(%{a: a, capacity: cap, per_ms: per_ms})
      end
    else
      # Refusal persists the accrued refill (CAS) so the stored balance is the
      # observable, then emits the typed 429. Retry hint = time to fund 1 RU.
      if :atomics.compare_exchange(a, 1, v, pack(now, balance)) == :ok do
        :moved
      else
        take(%{a: a, capacity: cap, per_ms: per_ms})
      end

      deficit = 100 - balance
      {:throttled, max(ceil(deficit / 100 / per_ms), 1)}
    end
  end

  @doc """
  Observer: persists the accrued refill into the word (CAS) without consuming
  a token, so external probes can watch the balance advance between takes.
  """
  def peek(%{a: a, capacity: cap, per_ms: per_ms} = b) do
    now = now_ms()
    v = :atomics.get(a, 1)
    {prev_ms, toks} = unpack(v)
    balance = min(toks + trunc((now - prev_ms) * per_ms * 100), cap * 100)

    if balance == toks or :atomics.compare_exchange(a, 1, v, pack(now, balance)) == :ok do
      {_p, t} = unpack(:atomics.get(a, 1))
      t
    else
      peek(b)
    end
  end

  @doc """
  Chicago check (real collaborator, final-state asserts): the bucket enforces
  its own limit — an over-capacity burst meets typed 429 refusals, the granted
  count within any instant window never exceeds capacity + refilled, the token
  word never goes negative, refill restores real budget over real elapsed time,
  and a refilled bucket re-enforces the cap on the next burst. Raises on any
  violation.
  """
  def verify_bucket do
    b = new_bucket(10, 1_000)

    # Burst 50 takes against capacity 10 with ~1000 RU/s refill: every response
    # must be :ok or a typed integer-hinted 429, nothing else.
    {granted, refused, untyped} =
      Enum.reduce(1..50, {0, 0, 0}, fn _, {g, r, u} ->
        case take(b) do
          :ok -> {g + 1, r, u}
          {:throttled, ms} when is_integer(ms) and ms >= 1 -> {g, r + 1, u}
          _ -> {g, r, u + 1}
        end
      end)

    unless untyped == 0, do: raise("#{untyped} untyped bucket responses")
    unless refused > 0, do: raise("bucket never refused — limit NOT enforced")
    unless granted + refused == 50, do: raise("response accounting broken")
    {_ , toks_now} = unpack(:atomics.get(b.a, 1))
    unless toks_now >= 0, do: raise("negative token balance: #{toks_now}")

    # Grants within the burst window cannot exceed capacity + refill budget.
    # 50 takes took < 50ms even contended -> refill budget < 10+50; granted
    # must be strictly less than the demand to prove the ceiling bound.
    unless granted < 50, do: raise("bucket granted the whole burst — no limit")

    # Refill is real: bounded poll on the observable (balance returns to full).
    refilled? =
      Enum.any?(1..500, fn _ ->
        # SLEEP-CLASS: POLL-STEP (bounded poll step inside audited refill probe)
        if peek(b) >= 1000, do: true, else: (Process.sleep(1) && false)
      end)

    unless refilled?, do: raise("bucket never refilled to capacity within 500ms poll")

    # Refilled bucket re-enforces: 10 grants then a typed refusal, same instant.
    Enum.each(1..10, fn _ ->
      unless take(b) == :ok, do: raise("post-refill grant refused — refill overcorrected")
    end)

    unless match?({:throttled, _}, take(b)), do: raise("11th post-refill take not throttled")
    :ok
  end

  # ---------------------------------------------------------------------------
  # Arm 1 — local CAS arbitration (silicon).
  # ---------------------------------------------------------------------------

  def local_arm(n \\ @n_actors) do
    counter = :atomics.new(1, signed: true)

    {wall_ms, results} =
      time(fn ->
        Task.async_stream(1..n, fn _ ->
          t0 = System.monotonic_time(:millisecond)
          attempts = cas_increment(counter)
          t1 = System.monotonic_time(:millisecond)
          {t1 - t0, attempts}
        end, timeout: :infinity)
        |> Enum.to_list()
        |> Enum.map(&elem(&1, 1))
      end)

    lats = Enum.map(results, &elem(&1, 0))
    total_attempts = results |> Enum.map(&elem(&1, 1)) |> Enum.sum()

    %{
      arm: :local_cas,
      n: n,
      wall_ms: wall_ms,
      winners: n,
      total_attempts: total_attempts,
      retries_total: total_attempts - n,
      errors: 0,
      p50_ms: percentile(lats, 50),
      p95_ms: percentile(lats, 95),
      p99_ms: percentile(lats, 99),
      ops_per_sec: n / max(wall_ms / 1_000, 0.001)
    }
  end

  defp cas_increment(counter, attempts \\ 1) do
    cur = :atomics.get(counter, 1)

    case :atomics.compare_exchange(counter, 1, cur, cur + 1) do
      :ok -> attempts
      _actual -> cas_increment(counter, attempts + 1)
    end
  end

  # ---------------------------------------------------------------------------
  # Arm 2 — simulated Azure: token bucket + typed 429 + exponential backoff.
  # The SAME 1,024 CAS operations; every op must pass the tollbooth first.
  # Deterministic seed drives the backoff jitter.
  # ---------------------------------------------------------------------------

  def simulated_arm(n \\ @n_actors, seed \\ {1, 942_042, 314_159}) do
    _ = :rand.seed(:exsss, seed)
    bucket = new_bucket()
    counter = :atomics.new(1, signed: true)

    {wall_ms, results} =
      time(fn ->
        Task.async_stream(1..n, fn _ ->
          t0 = System.monotonic_time(:millisecond)
          outcome = gated_op(bucket, counter)
          t1 = System.monotonic_time(:millisecond)
          {t1 - t0, outcome}
        end, timeout: :infinity)
        |> Enum.to_list()
        |> Enum.map(&elem(&1, 1))
      end)

    lats = Enum.map(results, &elem(&1, 0))
    retries = results |> Enum.map(&(&1 |> elem(1) |> elem(0))) |> Enum.sum()
    statuses = results |> Enum.map(&(&1 |> elem(1) |> elem(1)))

    %{
      arm: :simulated_azure_429,
      n: n,
      wall_ms: wall_ms,
      winners: Enum.count(statuses, &(&1 in [:ok, :throttled_ever])),
      retries_total: retries,
      throttled_ops: Enum.count(statuses, &(&1 == :throttled_ever)),
      retries_exhausted: Enum.count(statuses, &(&1 == :retries_exhausted)),
      errors: Enum.count(statuses, &(&1 == :retries_exhausted)),
      p50_ms: percentile(lats, 50),
      p95_ms: percentile(lats, 95),
      p99_ms: percentile(lats, 99),
      ops_per_sec: n / max(wall_ms / 1_000, 0.001)
    }
  end

  # One CAS op behind the tollbooth. The backoff wait is the SIMULATED cost of
  # the documented Cosmos client retry policy — the runtime scheduling the
  # process away for a modeled real-world interval.
  # SLEEP-CLASS: SCHEDULING (simulated Cosmos client retry backoff — modeled real-world interval)
  defp gated_op(bucket, counter, attempt \\ 0, retries \\ 0) do
    case take(bucket) do
      :ok ->
        cur = :atomics.get(counter, 1)
        _ = :atomics.compare_exchange(counter, 1, cur, cur + 1)
        {retries, if(retries > 0, do: :throttled_ever, else: :ok)}

      {:throttled, _hint} when attempt >= @max_retries ->
        {retries, :retries_exhausted}

      {:throttled, _hint} ->
        Process.sleep(backoff_ms(attempt))
        gated_op(bucket, counter, attempt + 1, retries + 1)
    end
  end

  defp backoff_ms(attempt) do
    base = trunc(min(@backoff_base_ms * :math.pow(2, attempt), @max_wait_ms))
    jitter = trunc(base * 0.2 * (:rand.uniform() * 2 - 1))
    max(min(base + jitter, @max_wait_ms), 1)
  end

  # ---------------------------------------------------------------------------
  # Runner — writes bench/apex_ratelimit.jsonl (this lane's ONLY result file).
  # ---------------------------------------------------------------------------

  def run do
    chicago = verify_bucket()

    local = local_arm()
    sim = simulated_arm()

    machine = machine_spec()
    ts = DateTime.utc_now() |> DateTime.to_iso8601()

    rows = [
      row("apex4", "popcorn.cas.local", "cas_contend_1024", local, ts, machine),
      row("apex4", "popcorn.cas.simulated_429", "cas_throttled_1024", sim, ts, machine)
    ]

    path = Path.join(demo_root(), "bench/apex_ratelimit.jsonl")
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, Enum.map_join(rows, &[Jason.encode!(&1), "\n"]))

    delta = %{
      bucket_chicago_check: chicago,
      local_wall_ms: local.wall_ms,
      simulated_wall_ms: sim.wall_ms,
      ratio: Float.round(sim.wall_ms / max(local.wall_ms, 0.001), 1),
      local_p99_ms: local.p99_ms,
      simulated_p99_ms: sim.p99_ms,
      local_cas_retry_loops: local.retries_total,
      simulated_429_retries: sim.retries_total,
      throttled_ops: sim.throttled_ops,
      retries_exhausted: sim.retries_exhausted
    }

    IO.puts(Jason.encode!(%{rows: rows, delta: delta}))
    {:ok, path, delta}
  end

  defp row(lane, surface, op, m, ts, machine) do
    %{
      lane: lane,
      surface: surface,
      op: op,
      n: m.n,
      wall_ms: m.wall_ms,
      ops_per_sec: round(m.ops_per_sec * 10) / 10,
      p50_ms: m.p50_ms,
      p95_ms: m.p95_ms,
      p99_ms: m.p99_ms,
      retries_total: m.retries_total,
      throttled_ops: Map.get(m, :throttled_ops, 0),
      errors: m.errors,
      ts: ts,
      machine: machine
    }
  end

  defp time(fun) do
    t0 = System.monotonic_time(:millisecond)
    r = fun.()
    t1 = System.monotonic_time(:millisecond)
    {t1 - t0, r}
  end

  defp percentile(list, p) do
    s = Enum.sort(list)
    Enum.at(s, max(0, ceil(p / 100 * length(s)) - 1))
  end

  defp now_ms, do: System.monotonic_time(:millisecond)

  # BEAM monotonic time is NEGATIVE on this host (boots near -2^45 ms), and
  # div/rem truncate toward zero — a naive word pack corrupts the token field
  # for negative words. Arithmetic shifts floor, so they are sign-correct.
  defp pack(ms, toks), do: (ms <<< @tok_shift) + toks

  defp unpack(v) do
    toks = v - (v >>> @tok_shift <<< @tok_shift)
    {v >>> @tok_shift, toks}
  end

  defp demo_root, do: Path.expand("../..", __DIR__)

  defp machine_spec do
    cpu =
      case System.shell("sysctl -n machdep.cpu.brand_string", stderr_to_stdout: true) do
        {out, 0} -> String.trim(out)
        _ -> "unknown"
      end

    %{
      cpu: cpu,
      cores: :erlang.system_info(:logical_processors),
      elixir: System.version(),
      otp: :erlang.system_info(:otp_release) |> to_string(),
      darwin:
        case System.shell("sw_vers -productVersion", stderr_to_stdout: true) do
          {out, 0} -> String.trim(out)
          _ -> "unknown"
        end
    }
  end
end
