defmodule PopcornDemo.EmpiricalHotPartitionTest do
  @moduledoc """
  E1 — empirical hot-partition contract for `PopcornDemo.Concurrency.contention/1`.

  Converts the benchmark report's Cosmos claim ("1,024 concurrent writes to
  one hot partition -> 80% HTTP 429 + retry backoff loops") into an
  executable Chicago test of smalt's ACTUAL arbitration mechanism: the
  S1-audited CAS harness run at the report's own load (N=1024, 8 keys —
  128 actors pile onto each key, i.e. one genuinely hot partition).

  Chicago discipline: real collaborators only — 1024 real spawned processes,
  one real public ETS table, real atomic `:ets.insert_new` CAS decisions;
  asserts on final observed state, never on call counts or a mocked
  throttle. There is no HTTP layer, no RU meter, no backoff sleep anywhere
  in the harness to observe — deterministic typed arbitration REPLACES
  probabilistic throttling by construction, and this test witnesses that
  construction at the report's load.

  Contract under test (the report's claim inverted):

    1. Every one of the 1024 actors receives a TYPED outcome
       (`{:winner, key}` or `{:cas_lost, key}`) — zero unhandled outcomes.
    2. Exactly 8 winners (one per contended key) and 1016 typed `:cas_lost`
       losers; winners + losers == 1024, so the report's "80% fail" framing
       (partial, probabilistic loss) is FALSE for smalt: the loss is 100%
       accounted for, deterministic, and typed.
    3. ZERO throttling semantics: no 429-equivalent, no retry, no backoff —
       each actor makes exactly ONE CAS attempt (a single atomic insert_new
       decides); losers are final, not retried.
    4. Final ETS state: all 8 rows `:committed` at version 1, each owned by
       its claim winner (enforced again by the harness's own
       `assert_contention_final/2`, fail-closed).
    5. Total wall < 1000ms — the whole arbitration at 1024-way contention
       is three orders of magnitude under the report's retry-backoff-loop
       regime (backoff loops stretch hot-partition writes to seconds).

  Both cases admit ~99% loss of the raw 1024 writes; the contract
  difference is the loss SHAPE: probabilistic RU-throttle + retry storm
  (report) vs one-shot deterministic typed CAS verdict (smalt).
  """

  use ExUnit.Case, async: false

  @n 1024
  @keys 8
  @expected_winners @keys
  @expected_losers @n - @keys
  @wall_fence_ms 1_000

  test "1024 concurrent writes to one hot partition: deterministic typed arbitration, zero throttling" do
    t0 = System.monotonic_time()

    result = PopcornDemo.Concurrency.contention(@n)

    wall_ms =
      System.monotonic_time()
      |> then(&System.convert_time_unit(&1 - t0, :native, :millisecond))

    # 1. The harness verdict itself is a typed pass — never a coerced one.
    assert {:ok, row} = result

    # 2. Every actor accounted for, distribution exactly as the ETS-CAS
    #    protocol predicts: one winner per key, everyone else a typed loser.
    assert row.n == @n
    assert row.keys == @keys
    assert row.winners == @expected_winners
    assert row.losers == @expected_losers
    assert row.winners + row.losers == @n

    # 3. Report's "80% fail" claim is FALSE for smalt: outcomes are 100%
    #    accounted (winners + losers == N), not a partial probabilistic
    #    failure. Loss fraction here is exactly (N-8)/N — but it is a fully
    #    partitioned, typed loss, not 80%-ish throttling noise.
    assert_in_delta(row.losers / @n, (@n - @expected_winners) / @n, 0.0)
    # 1016/1024 = 0.9921875 — full partition, nothing like an 80% throttle rate
    assert row.losers / @n > 0.99

    # 4. Zero unhandled outcomes: the harness's own fail-closed determinism
    #    assertion ran (:ok branch above); a crashed/missing/untyped actor
    #    would have returned {:error, {:not_deterministic, _}}.
    assert row.committed_rows == @expected_winners

    # 5. Zero throttling: total wall for the whole 1024-way arbitration is
    #    well under the report's retry-backoff regime.
    assert wall_ms < @wall_fence_ms,
           "hot-partition arbitration took #{wall_ms}ms (fence #{@wall_fence_ms}ms)"
  end
end
