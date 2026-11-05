# L53 — substrate.sh cold-boot readiness: budget not clock

Standing: PASS

## Defect (filed by L16)

`scripts/substrate.sh` defaulted `SMALT_UP_TIMEOUT=90`; a cold boot with full
compile exceeds 90s, so the beam was SIGTERMed mid-boot (witnessed twice, L16
needed `SMALT_UP_TIMEOUT=300`). Additionally the old wait loop counted
iterations (1s sleep per iteration), coupling the deadline to the poll step
rather than to elapsed time.

## Diff (scripts/substrate.sh)

1. Default `UP_TIMEOUT=${SMALT_UP_TIMEOUT:-300}` — the timeout is the BUDGET
   for cold boot (compile included); env override preserved.
2. New `await_ready <spawn_pid> <budget>`: deadline-based bounded poll
   (`SECONDS` vs budget, 0.5s poll step, `# SLEEP-CLASS: POLL-STEP`) on the
   real observables — all PORTS LISTENing via `lsof` + HEALTH URL serving via
   `curl -fsS`. Typed outcomes:
   - rc 0 = ready within budget (boot success)
   - rc 1 = budget exhausted, not serving (slow/failed boot)
   - rc 2 = spawn pid died mid-boot (boot refusal) — detected by the pid
     observable, NOT the clock, so a refused boot fails fast instead of
     burning the whole cold-boot budget.
   `cmd_up` now calls `await_ready` and maps rc 1/2 to distinct messages,
   both returning 2 with the log tail. PORTS/HEALTH are read at call time so
   a court can point them at temp listeners.
3. Source-guard (`BASH_SOURCE[0] = "$0"`) so the script can be sourced for
   court purposes without dispatching up/down/status.

## Non-vacuity court (scripts/courts/court_substrate_readiness.sh)

Real processes, real sockets — no mocks of the socket layer:

- Arm A: `python3 -m http.server` on a temp port → `await_ready` rc 0
  (boot success admitted within budget).
- Arm B: live `sleep 30` that never listens, 3s budget → rc 1
  (slow/failed boot REFUSED, not accepted as success).
- Arm C: process that dies mid-boot, generous 20s budget → rc 2 in <1s
  (refusal detected by pid observable before the clock expires).

A gate that accepted both boot-success and boot-refusal would be vacuous;
the three arms yield distinct verdicts 0/1/2.

## Command output (this session)

```
$ bash scripts/courts/court_substrate_readiness.sh
[COURT] A success-listener: rc=0 (budget 15s, took 1s)
[COURT] B never-listening: rc=1 (budget 3s)
[COURT] C died-mid-boot: rc=2 in 0s (budget 20s)
[COURT] PASS: readiness poll distinguishes boot-success (0) / slow-boot refusal (1) / dead-boot refusal (2); non-vacuous
rc=0

$ bash -n scripts/substrate.sh && echo OK
OK

$ bash scripts/substrate.sh bogus   # executed dispatch unchanged (source-guard)
usage: scripts/substrate.sh {up|down|status}
usage-rc=64
```

The running substrate was NOT touched (tested in isolation against temp
listeners; `substrate.sh status` run read-only).

## Standing

PASS — court green on real sockets with distinct typed refusals; syntax
check green; executed-dispatch behavior unchanged (usage rc 64, status
read-only).
