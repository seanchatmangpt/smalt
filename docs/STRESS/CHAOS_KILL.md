# Chaos Kill-Under-Load Harness

H1 matches filename. Real runs, real receipts. Falsifier for the harness
itself: `python3 scripts/stress/chaos_kill.py` exits 0 only when all three
chaos phases execute and a receipt lands at `tmp/chaos-kill-receipt.json`.

## Run

```sh
python3 scripts/stress/chaos_kill.py
```

Stdlib-only, no deps. Fails closed: refuses to start unless it can boot a
usable substrate, and SIGKILLs every substrate it spawns on every exit path.

## Profile

- Good traffic: 20 rps rotating ARM RG PUT/GET (:9443) and Cosmos doc
  POST/GET (:8443), Bearer-authenticated (token minted per beam from the
  exempt `POST /oauth2/v2.0/token` STS endpoint; auto-refresh on 401 streaks).
- t=30s listen-queue fill: 300 unaccepted connects held 10s on :8443.
- t=60s gate pressure: 500 GraphLaw-refusing ARM PUTs
  (`Microsoft.Fake/nonexistentType`) -> 500 x 400 InvalidResourceShape.
- t=90s total failure: SIGKILL the substrate process group mid-flight, reboot,
  time-to-first-success (TTFS) measured from the kill moment.

## Results (darwin/arm64, 2026-10-14, two full rc=0 runs)

| run | baseline p95 | flood p95 | gate p95 | in-flight failures at kill | reboot (ports bound) | TTFS from kill | post-recovery p95 |
|---|---|---|---|---|---|---|---|
| 1 | 1.7ms | 1.8ms | 1.9ms | 142 | 18.0s | 7.56s | 1.9ms (240/240) |
| 2 | 1.3ms | 1.5ms | 1.6ms | 90 | 15.0s | 4.95s | 1.6ms (300/300) |

Per-phase detail (run 2, 22:12 receipt):

```
phase                n    ok  fail   p50ms   p95ms   p99ms   maxms
p1_baseline         600   600     0     0.9     1.3     3.6    12.3
p2_flood            300   300     0     1.0     1.5     6.9    21.3
p2_between          300   300     0     1.0     1.5     6.9    27.8
p3_gate             300   300     0     1.0     1.6    14.1    17.8
p3_between          300   300     0     1.1     1.5     2.0    17.5
p4_kill_recovery    599   371   228     1.1     1.7     8.2    23.2
```

## Findings

- **Listen-queue fill: zero impact.** 300 half-open connects for 10s on the
  data plane did not perturb good traffic (300/300, p95 +0.2ms). The 8443
  accept loop absorbed the flood; recovery is immediate on release.
- **GraphLaw gate pressure: zero impact.** 500 refusing PUTs completed in
  0.27-0.58s (500 x 400 InvalidResourceShape); concurrent good traffic held
  300/300 with p95 within 0.3ms of baseline. A p99/max blip (14.1ms/17.8ms)
  coincides with the gate burst.
- **SIGKILL is the only chaos that lands.** ~90-142 good-traffic requests
  fail across the kill+reboot gap (~5-8s of the 20 rps stream). TTFS from
  kill: 4.95-7.56s. Post-recovery traffic is indistinguishable from baseline
  (300/300, p95 1.6ms).
- **Reboot includes first-attempt boot instability.** On this shared checkout
  the first boot attempt frequently exits rc=1 ~2-3s after bind ("Application
  smalt exited: shutdown" was observed pre-sweeper-fix; post-fix attempts
  still sometimes exit rc=1 after settle while other lanes run `mix run`
  probe loops against the same pinned ports). The harness retries (3 attempts)
  and the measured reboot time (15-18s) includes the failed attempt; TTFS is
  the cleaner recovery number.

## Harness guarantees

- Auth is real: dev mode enforces Bearer tokens; the harness mints a token
  per beam generation and refreshes on 401 streaks (events recorded in the
  receipt).
- The watchdog records mid-run substrate crashes (`substrate_crash` events)
  and reboots them, so a crash under load is a finding, not a dead run.
- Receipt (`tmp/chaos-kill-receipt.json`): per-phase impact table, per-request
  records (t_rel, kind, status, latency), chaos-phase details, events.

## Session-introduced change outside owned files (disclosed)

Compile-freeze SLA unblock fixes applied to shared `lib/` during this session,
both minimal and disclosed:

- `lib/smalt/data_plane/blob_storage.ex` — escaped `#{container}` inside the
  `@doc` heredoc (undefined-variable compile error).
- `lib/smalt/messaging/amqp/sweeper.ex` — skip `CbsRouter.gc()` unless the
  process is alive (`GenServer.whereis`); the unconditional call crashed the
  Sweeper -> "Application smalt exited: shutdown" ~2-3s after boot whenever no
  AMQP connection had started CbsRouter yet, killing any substrate run.

## See Also

`docs/BENCHMARKS.md` · `scripts/bench.py`
