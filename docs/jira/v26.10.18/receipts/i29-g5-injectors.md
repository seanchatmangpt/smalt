# i29 — Sovereign Midnight G5-narrow residual injectors landed (test-side, no lib/ changes)

Standing: ALIVE — 6 tests, 0 failures, green x2 (plus 4 intermediate red-to-green cycles).
Subject: /Users/sac/smalt @ main acb820a (working tree; new test file only).

Scope: G5 row
(`docs/jira/v26.10.18/azsim-burn/SOVEREIGN_MIDNIGHT.md` line 41, NARROWED) —
injector-only residuals per `i29-sovereign-gap-triage.md`:

- 1.3 JWT expiry-race injector
- 2.3 policy cancel-race injector
- 3.2 EH mid-stream detach/resume injector
- 3.1 lock-lost ordering stress (410 typed face; 410 closed by queue_store.ex
  token-scoped settle per the G5 row — this receipt witnesses it under stress)

## Artifact

`test/azsim/sovereign_midnight/sovereign_midnight_injectors_test.exs`
(module `Smalt.Azsim.SovereignMidnightInjectorsTest`, `@moduletag :stress`,
excluded from plain `mix test`; zero `Process.sleep` — bounded polls only via
`SmaltTest.AssertEventually.eventually/2`). No `lib/` changes. No bench lane,
no ports held (machine report: n/a).

## Injector designs (deterministic forcing, typed outcomes)

- **1.3 JWT expiry-race** — authored `:smalt, :sts_clock` (the AZB-08 injected
  verify clock) steps a short-TTL HS256 bearer token across its `exp` boundary
  under a 16-wide concurrent verifier pool: all `:ok` before, all
  `{:refuse, "InvalidAuthenticationToken", "TokenExpired"}` at/past exp
  (`expired?/2`: `exp <= now`). Second test steps the boundary INSIDE a live
  32-task pool's lifetime; every outcome stays on the two typed faces, and a
  post-step floor verify refuses. No wall-clock guessing.
- **2.3 policy cancel-race** — `Policy.enforce/3` (24-wide) races one
  `delete_policy_assignment` cancel. Deterministic faces bracket the race:
  pre-cancel `{:deny, json}` with code `PolicyViolation`; in-race outcomes all
  typed (`:ok | {:deny, _}` — the cancel-vs-evaluate order decides which);
  post-cancel `:error` from `get_policy_assignment` + `:ok` enforce. Live
  receipt face witnessed via `non_compliant_resources` (full assignment id).
- **3.2 EH mid-stream detach/resume** — consumer A reserves the partition,
  checkpoints seq 3 of a 5-event stream; detach = A's 40 ms processing lease
  expiring, reclaimed lazily inside the serialized reserve (B bounded-polls
  `reserve_processing` → `:ok`; no sleeps). Mid-detach production continues
  (events 6..10). B resumes: `reconcile` shows broker seq 10 / checkpoint 3;
  replay of 4..10 includes A's uncheckpointed pre-detach events AND mid-detach
  production; B CAS-checkpoints to 10; zombie A's stale CAS refuses
  `{:error, :conflict}` with the live checkpoint untouched; full 10-event
  stream continuous.
- **3.1 lock-lost ordering stress** — x20 ordered reclaim cycles: stale-token
  settle after authored-clock reclaim refuses `{:error, :lock_lost}` (the
  token-scoped compare-and-settle in `queue_store.ex`), live owner settles
  `:ok`; then a 16+1 burst. Two typed faces witnessed:
  - pre-burst stale settle (row still exists under the live lock): typed
    `{:error, :lock_lost}`;
  - in-race stale settles: `{:error, :lock_lost}` or idempotent `:ok`
    (`do_complete` on an already-settled missing row is `:ok` —
    queue_store.ex:715-728; exactly-once effect holds either way: queue empty
    post-settle, post-settlement settle is an idempotent `:ok` no-op).

## Product semantics pinned (witnessed, not changed)

- `Policy.enforce/3` deny returns a JSON-encoded STRING body (decode to
  inspect) — matches the wire shape the router serves.
- `EventHubs.receive_events(partition, after_seq, limit)` replays strictly
  after `after_seq` (resume replays 4..10 from checkpoint 3).
- `EventHubs.compare_and_swap` zero-checkpoint expect shape is
  `%{"seq" => 0, "offset" => 0, "etag" => 0}`.
- `QueueStore.complete` on a missing row returns idempotent `:ok`
  (queue_store.ex:725-726) — a settle after an already-settled seq is a no-op,
  not a resurrection.

## Verification (verbatim)

    $ MIX_BUILD_ROOT=_build-ft-inj mix test test/azsim/sovereign_midnight/sovereign_midnight_injectors_test.exs --include stress
    ......
    Finished in 0.2 seconds (0.00s async, 0.2s sync)
    6 tests, 0 failures

    (run 2)
    ......
    Finished in 0.3 seconds (0.00s async, 0.3s sync)
    6 tests, 0 failures

    $ MIX_BUILD_ROOT=_build-ft-inj mix test test/azsim/sovereign_midnight/sovereign_midnight_injectors_test.exs
    Finished in 0.1 seconds (0.00s async, 0.1s sync)
    0 tests, 0 failures (6 excluded)   # :stress excluded by default — correct

Sleep gate: `grep -c "Process.sleep"` on the new file = 0.

Context: pair(G5 injector lane × serialized store collaborators — QueueStore
GenServer, EventHubs.Server, Policy ETS, Auth.Bearer persistent_term; no other
lanes touched, no shared-file edits). Machine report: n/a — no bench lane, no
ports held.
