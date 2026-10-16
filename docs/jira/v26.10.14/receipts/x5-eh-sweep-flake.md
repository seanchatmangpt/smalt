# X-5 Receipt: Event Hubs sweep() flake — deterministic expiry fix

Lane: X-5, v26.10.14. Subject: `test/amqp/broker_facade_test.exs:151`
"GCs expired Event Hubs processing claims" returned `sweep() >= 1` → 0 under
concurrent-lane load.

## Root cause (two stacked racers)

1. **Wall-clock wait**: the test reserved a claim with a 10 ms TTL and
   `Process.sleep(30)` before asserting `EventHubs.sweep() >= 1`. Expiry
   depended on real elapsed time vs. `System.system_time/1` inside
   `EventHubs.Server` (`lib/smalt/messaging/event_hubs.ex:258,372`).
2. **Background sweeper steals the count**: the describe's `setup` sets
   `amqp_sweeper_tick_ms = 20`, so the supervised `Smalt.Amqp.Sweeper` runs
   `EventHubs.sweep()` every 20 ms. Under load, the background tick can GC the
   expired claim between the test's `sleep` and the test's explicit `sweep/0`,
   which then returns 0 — exactly the observed flake. Stopping the sweeper is
   not enough (supervised restart re-arms a 20 ms tick; first tick immediate).

## Fix (deterministic, no sleep lengthening)

`test/amqp/broker_facade_test.exs` — the "GCs expired Event Hubs
processing claims" test now:

1. Reserves with a 60 s TTL (no expiry race against wall clock), confirms the
   conflict arm (`owner_b` reserve → `{:error, :conflict}`) against a LIVE
   claim, then **authors the expired state directly**: overwrites the claim's
   `until` to `now - 60_000` via a direct `:ets.insert` on the public named
   `:smalt_eh_checkpoints` table. The state IS the contract; no wait.
2. Parks the background sweeper: sets `amqp_sweeper_tick_ms = 3_600_000` and
   stops the supervised sweeper so the restart re-reads the env at `init`.
   `wait_until` confirms restart. The background sweep can no longer fire
   inside the assertion window.
3. Asserts `EventHubs.sweep() >= 1`, asserts the stored claim is GC'd
   (`"claim" => nil`), then `owner_b` reserve succeeds (reclaim arm intact).

## Verification

- `mix test test/amqp/broker_facade_test.exs` — 5 runs, all green; run 5
  executed concurrently with a heavy unrelated file
  (`test/egress_dispatch_test.exs`, 98 tests running in a parallel mix VM)
  to simulate load.
- Load simulation also exposed a shared-tree compile freeze from lane X-1's
  in-flight block-list work in `lib/smalt/data_plane/blob_storage.ex` (see
  Compile-freeze disclosure below).

## Compile-freeze disclosures (sibling lane X-1, blob_storage.ex)

During run-5 verification the shared compile broke on X-1's in-flight
`blob_storage.ex` edits. Two typo-class unblock fixes applied per the
compile-freeze SLA (minimal, disclosed):
- Removed stray `end garbage; # fix` after `commit_block_list/6`'s final `end`.
- Removed a stray `by` line after `Enum.sort_by(& &1["staged_at"])`.

X-1's remaining breakage (missing helpers `resolve_refs/4`, `existing_blob?/1`,
`existing_etag/1`, `mismatched_if_match?/2`, `if_none_match_star?/1`,
`worm_blocked?/3`, `worm_message/3`, `defp precondition_message/0`,
`xml_escape/1`, and the garbage clause
`{:error, :precondition_failed, :precondition_failed |> then(& &1) |> invalid}`)
was NOT repaired by X-5 — authoring another lane's helpers oversteps the
minimal-unblock line. X-5 waited (polling `mix compile`) for X-1 to complete.

## Files touched by X-5

- `test/amqp/broker_facade_test.exs` — the flaky test rewritten (deterministic
  expiry authoring + background-sweeper parking).
- `lib/smalt/data_plane/blob_storage.ex` — two typo-class unblock fixes
  (disclosed above; X-1's file, X-1's work otherwise untouched).

## Final — 5 run tails

Runs 1–4 sequential, run 5 concurrent with `mix test test/egress_dispatch_test.exs`:

```
== run 1 ==
Finished in 0.1 seconds (0.00s async, 0.1s sync)
4 tests, 0 failures (1 excluded)
== run 2 ==
Finished in 0.3 seconds (0.00s async, 0.3s sync)
4 tests, 0 failures (1 excluded)
== run 3 ==
Finished in 0.1 seconds (0.00s async, 0.1s sync)
4 tests, 0 failures (1 excluded)
== run 4 ==
Finished in 0.1 seconds (0.00s async, 0.1s sync)
4 tests, 0 failures (1 excluded)
== run 5 (under parallel load) ==
....
Finished in 0.3 seconds (0.00s async, 0.3s sync)
4 tests, 0 failures (1 excluded)
```

Sibling-lane status (not X-5's): `test/egress_dispatch_test.exs` concurrently
reported `98 tests, 5 failures`; `test/compliance/c3_cosmos.exs` could not
start under concurrency (TLS cert contention on shared tmp certs). Both files
carry other lanes' in-flight edits; X-5 touched neither.

## Standing

ALIVE — flake class eliminated at the cause (authored state, no wall-clock
dependency, background racer parked for the assertion window).
