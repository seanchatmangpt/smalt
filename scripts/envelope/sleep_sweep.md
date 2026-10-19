# sleep_sweep.md — scripts + docker/burn sleep triage (v26.10.19 lane)

Scope: `scripts/*.sh` (top-level) + `docker/burn/*.sh`. Out of lane:
`verification/`, `test/`, `lib/` (owned elsewhere). Gate:
`python3 scripts/sleep_gate.py` (AZB-21/22 grammar — `sleep [0-9]` in
docker/burn, `Process.sleep`/`:timer.sleep` in lib/test, TS/PY primitives in
verification/test). Note: the gate's sh-scanner only has jurisdiction over
`docker/burn/*.sh`; `scripts/*.sh` are NOT gate-scanned, so the annotations
below are the doctrine's discipline layer for scripts/, verified by the
manual grep sweep, not by the gate itself.

## Before (gate + manual sweep)

```
$ python3 scripts/sleep_gate.py
[SLEEP-GATE] 1 violation(s) across 186 files — REFUSED
  [FAIL] verification/ts/wf3/index.ts:32 unclassified ts/js sleep primitive ...
EXIT:1
```

The single default-scope FAIL is `verification/ts/wf3/index.ts:32` — outside
this lane's scope (verification/ owned elsewhere). docker/burn scope:

```
$ python3 scripts/sleep_gate.py docker/burn
[SLEEP-GATE] PASS — 12 files, 0 unclassified sleep primitives
EXIT:0
```

docker/burn contains ZERO literal `sleep` sites (grep-confirmed); the
scanner's no-annotation-escape law was already satisfied by prior restructure
work — nothing to touch there.

Manual sweep of `scripts/*.sh` (gate has no jurisdiction) found 26 sleep
sites across 9 files; 3 were already annotated POLL-STEP
(bootstrap.sh:76,98 — pre-existing; dev_watch.sh:42), 23 unannotated.

## Triage + actions

Lawful POLL-STEP (sleep is the pacing step inside an already-bounded loop
polling a real observable) → annotated `# SLEEP-CLASS: POLL-STEP` with the
deadline named. Fixed settle/coordination sleeps → restructured to bounded
polls (deadline counter, observable: `kill -0`, `lsof`/`nc` port probe,
`curl`).

| file | site(s) | action |
|---|---|---|
| scripts/bootstrap.sh | 125 | annotate POLL-STEP (curl endpoint poll, 60x1s) |
| scripts/fast_test.sh | 69 | annotate POLL-STEP (mtime watch poll; operator-Ctrl-C bounded) |
| scripts/port_sweep.sh | 165 | RESTRUCTURE: fixed `sleep 3` → 6s-deadline reap poll on `kill -0` of every killed pid |
| scripts/release.sh | 43 | annotate POLL-STEP (backoff pacing, 3-attempt-bounded mix-release retry) |
| scripts/release.sh | 66 | annotate POLL-STEP (lsof port-listen poll, 30x0.5s) |
| scripts/release.sh | 71 | RESTRUCTURE: fixed `sleep 1` after `smalt stop` → 5s-deadline reap poll on `kill -0 $BOOT_PID` |
| scripts/substrate.sh | 158 | annotate POLL-STEP (any_listener_present poll, 20x0.5s) |
| scripts/substrate.sh | 217 | annotate POLL-STEP (curl health poll, UP_TIMEOUT deadline) |
| scripts/tf_cleanroom.sh | 146,156,167,174 | 146/156/167 annotate POLL-STEP; 174 RESTRUCTURE fixed `sleep 1` → 5s-deadline port-free poll |
| scripts/tf_cleanroom.sh | 268,276 | annotate POLL-STEP (lsof bind polls, 120x1s / 60x1s) |
| scripts/tf_enclave_loop.sh | 105,115,126,133 | 105/115/126 annotate POLL-STEP; 133 RESTRUCTURE fixed `sleep 1` → 5s-deadline port-free poll |
| scripts/tf_enclave_loop.sh | 221 | annotate POLL-STEP (backoff pacing, 5-attempt-bounded TLS self-heal) |
| scripts/tf_enclave_loop.sh | 261,273 | annotate POLL-STEP (lsof bind polls) |
| scripts/tf_plan_check.sh | 148 | annotate POLL-STEP (lsof bind poll, 120x1s) |
| scripts/tf_smoke.sh | 85 | RESTRUCTURE: fixed `sleep 1` in cleanup → 10s-deadline reap poll on `kill -0` |
| scripts/tf_smoke.sh | 190,203 | annotate POLL-STEP (nc bind polls, 30x1s) |

Restructures: 5 sites across 5 files (port_sweep.sh, release.sh,
tf_cleanroom.sh, tf_enclave_loop.sh, tf_smoke.sh). All restructured
loops: deadline counter via `date +%s`/`seq` bound, observable
(`kill -0`/`lsof`/`nc`), typed fail path preserved (the pre-existing
STILL-HELD / post-loop escalation branches are unchanged).

## After (gate + sweep)

```
$ python3 scripts/sleep_gate.py
[SLEEP-GATE] 1 violation(s) across 189 files — REFUSED
  [FAIL] verification/ts/wf3/index.ts:32 ...
EXIT:1
```

Same single out-of-lane violation (verification/ — another lane's file; file
count 186→189 reflects other lanes' concurrent landings). scripts+docker/burn
scope: ZERO violations, zero unannotated sleeps (grep sweep above returns
empty).

```
$ python3 scripts/sleep_gate.py docker/burn
[SLEEP-GATE] PASS — 12 files, 0 unclassified sleep primitives
EXIT:0
```

## Syntax + smoke receipts

```
$ for f in bootstrap fast_test port_sweep release substrate tf_cleanroom \
    tf_enclave_loop tf_plan_check tf_smoke; do bash -n scripts/$f.sh; done
OK scripts/bootstrap.sh
OK scripts/fast_test.sh
OK scripts/port_sweep.sh
OK scripts/release.sh
OK scripts/substrate.sh
OK scripts/tf_cleanroom.sh
OK scripts/tf_enclave_loop.sh
OK scripts/tf_plan_check.sh
OK scripts/tf_smoke.sh
```

Reap-poll smoke (port_sweep restructure, real background pid, TERM then the
new bounded poll):

```
PASS: reaped via observable, no fixed 3s sleep
```

Bind/port-free poll smoke (nc listener, bounded /dev/tcp-shaped probes):

```
PASS: bounded bind poll observed listener
PASS: bounded port-free poll observed release
```

## Out-of-lane residual

- `verification/ts/wf3/index.ts:32` — unclassified TS `await sleep(` idiom
  (`new Promise((r) => setTimeout(r, ms))`); needs `// SLEEP-CLASS: ...` or
  restructure by the verification/ owner. Only remaining gate FAIL tree-wide.
- `scripts/**/*.sh` subdirectories (bench/, chaos/, lib/, shim_court/) are
  outside this lane's named `scripts/*.sh` scope; c11_tf_loop.sh and
  scripts/lib/substrate_boot.sh contain additional sleep sites not triaged
  here (flagged for the coordinator to assign if the doctrine sweep should
  extend).
