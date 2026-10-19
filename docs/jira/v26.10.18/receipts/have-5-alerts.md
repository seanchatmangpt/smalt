# HAVE-5: alert_policy.py — SEV matrix + jidoka engine

**Standing: PASS** (22/22 self-test checks, end-to-end CLI runs exit-contract verified)
Context: solo(alert_policy.py self-test 22/22 + CLI exit-contract runs; no mix test invocation)

## Subject

- `scripts/have/alert_policy.py` — pure-stdlib Python 3, no repo deps.
- Implements the HAVE alert classification exactly:
  - SEV1 `HEARTBEAT-DEADLOCK` — duration > 600s (strictly greater; 600.0 boundary is clean)
  - SEV1 `STORAGE-CORRUPTION-UNREPAIRED` — `verdict: "DETS_UNREPAIRED"` (burn-row AZB-03 vocab) or `dets_unrepaired >= 1`
  - SEV1 `PETRI-TOKEN-IMBALANCE` — `petri_tokens != 0` (fires only when the field is present)
  - SEV2 `FLEET-STARVATION` — `available < 15` sustained >= 600s across ordered rows (or direct `starved_s >= 600`)
  - SEV2 `PROCESS-LEAK-ZOMBIE` — `orphans >= 3` (int count or list length)
- SEV1 = jidoka line-stop: alert row `{action: halt_dag, freeze_state: true, drain_leases: true}` plus a `<alert>.json.hold` dispatch-hold file under the alerts dir (default `.smalt/alerts`, env `HAVE_ALERTS_DIR`) that the cron loop treats as a dispatch hold.
- SEV2 = alert row `{action: recycle_refill}`, no hold file.
- Exit contract: 0 clean / 1 alerts fired / 2 input error.
- Input: telemetry JSONL rows (HAVE-4 contract documented in the module docstring; compatible with AZB-03 burn-row fields `verdict`, `orphans`, `t_start`/`t_end`, `container`).

## Verification (real output)

### Self-test fixture suite (per-rule firing + boundary + clean + hold-file jidoka)

```
$ python3 scripts/have/alert_policy.py --self-test; echo "EXIT=$?"
PASS heartbeat-601s-fires-SEV1
PASS heartbeat-fires-jidoka-action
PASS heartbeat-600s-boundary-clean
PASS heartbeat-t-start-t-end-601s-fires
PASS dets-unrepaired-verdict-fires
PASS dets-unrepaired-count-fires
PASS storage-clean-no-alert
PASS petri-1-fires
PASS petri-negative-fires
PASS petri-0-clean
PASS starvation-10min-fires-SEV2
PASS starvation-9min-clean
PASS starvation-direct-600s-fires
PASS starvation-direct-599s-clean
PASS starvation-recovered-clean
PASS zombies-3-fires-SEV2
PASS zombies-list-of-3-fires
PASS zombies-2-clean
PASS clean-rows-no-alerts
PASS sev1-writes-dispatch-hold
PASS hold-kind-dispatch-hold
PASS sev2-writes-no-hold

22 check(s), 0 failed
EXIT=0
```

### End-to-end: dirty fixture (3 SEV1 + 1 SEV2 rows)

```
$ python3 scripts/have/alert_policy.py bad.jsonl --alerts-dir alerts-bad; echo "EXIT_BAD=$?"
HAVE-5: 4 alert(s): 3 SEV1 (jidoka halt_dag; dispatch holds in alerts-bad), 1 SEV2
{"action": "halt_dag", "container": "c1", "drain_leases": true, "freeze_state": true, "row_ts": null, "rule": "HEARTBEAT-DEADLOCK", "schema": "smalt-have-alert/v1", "severity": "SEV1", "ts": "2026-10-19T04:33:41Z"}
{"action": "halt_dag", "container": "c1", "drain_leases": true, "freeze_state": true, "row_ts": null, "rule": "PETRI-TOKEN-IMBALANCE", "schema": "smalt-have-alert/v1", "severity": "SEV1", "ts": "2026-10-19T04:33:41Z"}
{"action": "halt_dag", "container": "c2", "drain_leases": true, "freeze_state": true, "row_ts": null, "rule": "STORAGE-CORRUPTION-UNREPAIRED", "schema": "smalt-have-alert/v1", "severity": "SEV1", "ts": "2026-10-19T04:33:41Z"}
{"action": "recycle_refill", "container": "c3", "row_ts": "2026-10-18T00:00:00Z", "rule": "PROCESS-LEAK-ZOMBIE", "schema": "smalt-have-alert/v1", "severity": "SEV2", "ts": "2026-10-19T04:33:41Z"}
EXIT_BAD=1
```

Dispatch holds written for SEV1 only (dir listing shows 3 `.json.hold` files alongside
4 `.json` alerts; the SEV2 `PROCESS-LEAK-ZOMBIE` alert has no `.hold`):

```
$ cat alerts-bad/*.hold
{
  "alert": "ALERT-HEARTBEAT-DEADLOCK-2026-10-19T043341Z-00.json",
  "kind": "dispatch-hold",
  "rule": "HEARTBEAT-DEADLOCK",
  "schema": "smalt-have-alert/v1",
  "severity": "SEV1"
}
... (PETRI-TOKEN-IMBALANCE, STORAGE-CORRUPTION-UNREPAIRED identical shape)
```

### End-to-end: clean fixture

```
$ python3 scripts/have/alert_policy.py clean.jsonl --alerts-dir alerts-clean; echo "EXIT_CLEAN=$?"
HAVE-5: clean, 0 alerts
EXIT_CLEAN=0
```

(no alerts dir created; zero side effects on clean input)

Stdin path: `cat bad.jsonl | ... --no-write` → 4 alerts, exit 1, no files written.

## Falsifier

`python3 scripts/have/alert_policy.py --self-test` exits 1 if any rule fires at the
wrong severity/action, misses its boundary, or a SEV1 fails to write a dispatch hold.
Re-run at any time; embedded fixtures are the court.

## Notes / scoping

- HAVE components 1-4 were not present in `scripts/have/` at implementation time
  (dir was empty); the input contract for HAVE-4 telemetry rows is defined in the
  module docstring and maps onto the existing AZB-03 burn-row vocabulary so burn
  JSONL rows validate against the same rules without translation.
- Window rule (FLEET-STARVATION) is evaluated in `finalize()` over the full row
  stream; per-row rules fire in `feed()`. Recovery resets the starvation run
  (covered by `starvation-recovered-clean`).
- No git operations performed, per task.
