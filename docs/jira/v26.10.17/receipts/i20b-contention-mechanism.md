# I20b: contention mechanism — cosmos-etag-cas gate vs StoreDets churn flake

Standing: PARTIAL_ALIVE — dets churn flake REPRODUCED under artificial load
(2/2 loaded runs) with the timing envelope named; the cosmos-etag-cas gate arm
is NEGATIVE (did not reproduce in 2 loaded attempts). No lib/ or test/ edits,
no git operations.

Lane I20b (mechanism lane, /Users/sac/smalt). Subjects (read-only):
- `gates/cosmos_etag_cas_gate.py` (self-boots its own substrate)
- `test/store_dets_test.exs:145` — restore x insert_new churn, `@max_rounds 120`
- Code paths read: `lib/smalt/store/dets_mirror.ex` (`restore_table`, `sync_all`),
  `lib/smalt/store.ex` (`:cas`, `:insert_new` handle_call), `lib/smalt/data_plane/cosmos.ex`
  `do_put_doc` If-Match CAS, `gates/common.py` `http()` (15s timeout, no retry).

## Result matrix

| subject | quiet | +2 hogs | +16 hogs | verdict |
|---|---|---|---|---|
| cosmos_etag_cas_gate | PASS | PASS | PASS (wall >10 min) | NEGATIVE — no reproduction |
| store_dets_test:145 | PASS 158.6s | n/a | FAIL 2/2 | REPRODUCED |

Attempt log (2026-10-17, 16-core darwin):

1. Gate quiet: PASS, receipt `tmp/invariant-gates/cosmos-etag-cas-receipt.json`
   (path as printed by the gate). Quiet pre-flight printed
   "substrate port stolen pre-bind; re-picked all six" — a concurrent lane was
   binding ports in the same window; the re-pick path handled it.
2. Gate +2 hogs (`yes > /dev/null` x2): PASS.
3. Gate +16 hogs: PASS, race result still exactly [200,412,412,412,412,412]; wall
   time ballooned past 10 min (substrate self-boot under saturation), verdict intact.
4. test:145 quiet: PASS 158.6s (`1 test, 0 failures (5 excluded)`).
5. test:145 +16 hogs, attempt 1: FAIL 16.4s into the run —
   `** (exit) exited in: GenServer.call(#PID<0.3647.0>, :sync, 5000) ** (EXIT) time out`
   at `test/store_dets_test.exs:197` (`Smalt.Store.DetsMirror.sync(pid)` before the racers start).
6. test:145 +16 hogs, attempt 2: FAIL 36.3s into the run — same crash site, same
   `:sync` call, same 5000ms default timeout.

## Mechanism (named, with measurements)

The unsynchronized assumption is the DEFAULT `GenServer.call` 5-second timeout
riding on a per-call latency envelope with no such ceiling under load — timer
slack, not a lost update.

`Smalt.Store.DetsMirror.sync/1` is
`GenServer.call(server, :sync)` with the implicit 5000ms default. Its server-side
work (`sync_all` in `lib/smalt/store/dets_mirror.ex`) does
`:ets.tab2list` + `:dets.match_object` + per-key `:dets.delete` + `:dets.insert` + `:dets.sync`
(an fsync) per table — a per-call latency distribution with a FAT TAIL under CPU
saturation, because the single DetsMirror process must be scheduled (a) while
16 external `yes` hogs saturate all 16 cores, (b) against 100 racer Task
processes spinning `GenServer.call`s into the single `Smalt.Store` process, and
(c) while APFS fsync latency spikes under load.

Measured envelope (probe: bare beam with Smalt.Store + DetsMirror only,
`/tmp/i20b_probe_sync.exs`, 60 fresh-mirror syncs of 100 rows):

```
QUIET  sync_ms x60: 24,15,13,11,14,17,16,12,17,15,17,16,15,14,14,17,13,16,14,12,14,13,10,15,38,15,11,10,12,9,9,10,11,11,11,9,8,14,14,8,11,8,5,4,11,9,12,20,7,8,7,7,8,8,6,12,10,12,8,8   (min 4 / max 38 / typical ~12)
LOADED sync_ms x60: 641,692,237,208,165,324,101,153,244,366,114,170,287,339,163,488,953,498,554,406,428,479,747,183,478,536,458,78,125,279,246,349,133,520,453,272,238,191,189,87,244,450,287,197,191,100,57,213,410,189,304,340,160,614,529,146,170,244,329,220   (min 78 / max 953 / typical ~300)
```

### Racer flood: full race_round replica (/tmp/i20b_probe_round.exs)

Full race_round replica (100 racers hammering Store.insert_new during restore,
30 rounds), quiet: sync ~11ms, restore ~306-362ms, attempts_total ~10^5/round,
no hang. LOADED (16 hogs):

```
round 1 sync=75ms restore=16ms   restored=0 attempts_total=0
round 2 sync=416ms restore=185ms restored=0 attempts_total=38736
...
round 14 sync=4008ms restore=178ms restored=0 attempts_total=71231   <-- 350x tail, 1s from the 5s cliff
round 17 sync=2480ms round 18 restore=1068ms round 27 restore=1090ms round 29 restore=1386ms
```

Round 14 sync hit 4008ms (quiet: ~11ms) — a 350x tail that sits 1 second from
the 5000ms cliff the default timeout draws. Both real-test failures were exactly
this call crossing the cliff. No stale clobber was ever witnessed in any loaded
probe round (restored=0 every round: racers always win insert_new against the
hot ETS; the CAS/insert_new atomicity itself held everywhere it was checked).

## Why the gate arm is NEGATIVE

`gates/cosmos_etag_cas_gate.py` race is 6 threads x ONE request each — total
in-flight work ~6 HTTP requests (~1.4s quiet, several seconds loaded). The dets
test by contrast generates ~10^5+ GenServer.call floods per round across 120
rounds. The gate's race is too short to cross the 5s default timeout budget
(its HTTP client timeout is 15s, also with no retry); under 16-hog saturation
it degraded throughput only. Its 6-thread single-shot race cannot witness the
timer-slack cliff the churn court witnesses. (Its lost-update window is closed
structurally: Store.compare_and_swap is one handle_call in the Store GenServer;
both loaded runs still returned exactly one 200 / five 412s.)

## Close condition (proposed, not applied)

Name the timeout at the call sites that carry the envelope: explicit timeout on
`DetsMirror.sync/restore` GenServer.call sites (or infinity with a caller-side
deadline), and/or an ExUnit tag-level `@tag timeout` computed for loaded-tree
runs. Fix belongs to a repair lane; this lane made no edits.

## Cleanup

- 16 `yes` CPU hogs killed after every loaded run (verified `pgrep -x yes` -> 0).
- No substrate left running by this lane (gate self-booted and reaped its own).
- Probe scripts are scratch: /tmp/i20b_probe_sync.exs, /tmp/i20b_probe_round.exs.
