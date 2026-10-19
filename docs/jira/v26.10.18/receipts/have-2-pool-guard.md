# Receipt: HAVE-2 pool saturation guard

Standing: ALIVE
Context: solo(scripts/have/pool_saturation_guard.py live runs; no mix test invocation)
Date: 2026-10-19
Subject: `/Users/sac/smalt/scripts/have/pool_saturation_guard.py` (HAVE component 2, Level-1 5m guard)
State dir: `/Users/sac/smalt/tmp/have/` (`state_ledger.jsonl`, `dispatch_requests.jsonl`, `heartbeat.json`)

## Contract

1. Worker count = distinct lines of `pgrep -f 'mix test|docker'` (smalt worker
   definition). Counter failure returns -1 and is typed SEV1
   COUNTER_FAIL — count is UNKNOWN, never silently read as zero workers.
2. Target N=20 from `--target-pool`.
3. N < target emits a typed `have_worker_fleet_active_count` alert row to
   `state_ledger.jsonl`. Severity: SEV2 iff deficit < 15 sustained — the
   previous heartbeat sample also reported < 15 (last-2-heartbeat window).
   First observation is SEV3 (unproven duration). Above 15 but below target
   is SEV4 band. AND appends `{kind: dispatch_request, deficit: N}` to
   `dispatch_requests.jsonl`. Honest boundary: the guard cannot spawn Claude
   agents — it requests; the 5m cron loop is the actuator.
4. Heartbeat touched every cycle (ts + epoch + workers + status).
5. `--self-check` runs fixture-driven, no real pgrep dependency, zero sleeps.

Zero sleeps; deadlines via timestamp arithmetic (epoch stored in heartbeat).

## Verification

### Self-check (fixtures), exit 0

```
$ python3 scripts/have/pool_saturation_guard.py --self-check; echo "exit=$?"
PASS saturated-pool-ok
PASS no-alert-at-target
PASS no-dispatch-at-target
PASS heartbeat-touched
PASS first-deficit-sev3
PASS alert-row-typed
PASS alert-row-deficit
PASS dispatch-request-deficit
PASS sustained-deficit-sev2
PASS sev2-sustained-flag
PASS midband-sev4
PASS counter-fail-typed
PASS counter-fail-sev1
PASS recovery-ok
PASS no-dispatch-on-recovery

self-check: 0 failure(s)
exit=0
```

### Live run 1 — quiet tree, SEV3 first observation

```
$ python3 scripts/have/pool_saturation_guard.py; echo "exit=$?"
{"deficit": 14, "severity": "SEV3", "status": "DEFICIT", "target_pool": 20, "ts": "2026-10-19T04:30:09Z", "workers": 6}
exit=0
$ pgrep -f 'mix test|docker' | wc -l
       6
```

Alert row + dispatch-request row landed; matches pgrep ground truth (6).

### Live run 2 — sustained SEV2 flip on real state

```
$ python3 scripts/have/pool_saturation_guard.py; echo "exit=$?"
{"deficit": 14, "severity": "SEV2", "status": "DEFICIT", "target_pool": 20, "ts": "2026-10-19T04:30:15Z", "workers": 6}
exit=0
$ tail -1 tmp/have/state_ledger.jsonl
{"deficit": 14, "kind": "alert", "severity": "SEV2", "sustained": true, "target_pool": 20, "ts": "2026-10-19T04:30:15Z", "type": "have_worker_fleet_active_count", "workers": 6}
$ tail -1 tmp/have/dispatch_requests.jsonl
{"deficit": 14, "kind": "dispatch_request", "requested_by": "pool_saturation_guard", "severity": "SEV2", "target_pool": 20, "ts": "2026-10-19T04:30:15Z", "workers": 6}
```

Note: the SEV3→SEV2 flip came from the real previous heartbeat
(6 < 15 both samples), not a fixture — the sustained path is witnessed live.

## Honest boundaries

- The guard does not spawn agents. `dispatch_requests.jsonl` is a request
  stream; the cron loop consuming it is a separate component.
- The tree was genuinely quiet at run time — the SEV2-class rows are honest
  observations, not simulated.

## Falsifiers

- `--self-check` exits nonzero on any fixture failure.
- If a later cycle observes >= target after a deficit, status flips OK with
  no new dispatch row (fixture 6).
