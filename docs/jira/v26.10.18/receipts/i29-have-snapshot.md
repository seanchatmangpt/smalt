# i29 HAVE snapshot (guard + watchdog + telemetry + status)

Standing: PARTIAL_ALIVE — all have components executed with real output; 1 critical telemetry row (dangling listeners) and 1 SEV4 guard deficit are open findings, not passes.

Context: solo(just have-guard / have-watchdog / have-telemetry / have-status + have-rp01..rp04 probes; no mix test invocation)

## Scope note

`just have-cycle` does not exist — the have justfile (`justfile.d/31-have.just`) exposes `have-guard`, `have-watchdog`, `have-telemetry`, `have-status`, `have-rp01..rp04`, `have-install-crontab`. The cycle was executed as its constituent components. No edits, no git.

## just have-guard

```
{"deficit": 4, "severity": "SEV4", "status": "DEFICIT", "target_pool": 20, "ts": "2026-10-19T04:50:12Z", "workers": 16}
```

## just have-watchdog (dry-run; exit 1 — alerts fired)

```
[HAVE-WATCHDOG] dry-run (HAVE_ENFORCE=1 to arm RP-01 automation)
=== meta_watchdog (DRY-RUN) ===
ALERT [SEV2] ALRT-DANGLING-LISTENER: port 9443 held by non-runtime pid 61023 cmd='ssh' (no live owner class)
ALERT [SEV2] ALRT-DANGLING-LISTENER: port 8443 held by non-runtime pid 61023 cmd='ssh' (no live owner class)
ALERT [SEV2] ALRT-DANGLING-LISTENER: port 5672 held by non-runtime pid 61023 cmd='ssh' (no live owner class)
ALERT [SEV2] ALRT-CRON-MISSING: crontab has 1 lines but none match AZB/HAVE/smalt loop markers ('azb', 'have', 'smalt')
no actions
exit=1
```

## python3 scripts/have/telemetry.py --emit-all --out tmp/have/telemetry-snapshot.jsonl (exit 0, 8 rows)

```
{"metric": "have_control_heartbeat_age_seconds", "severity": "nominal", "ts": "2026-10-19T04:50:24Z", "value": 41.519, "window": "since-last-heartbeat-touch"}
{"metric": "have_worker_fleet_active_count", "severity": "nominal", "ts": "2026-10-19T04:50:24Z", "value": 23.0, "window": "pgrep -f 'mix test|docker' distinct pids"}
{"metric": "have_orphan_beam_processes_count", "severity": "nominal", "ts": "2026-10-19T04:50:24Z", "value": 0.0, "window": "beam.smp pids with no LISTEN socket in tree"}
{"metric": "have_dangling_socket_listeners", "severity": "critical", "ts": "2026-10-19T04:50:24Z", "value": 3.0, "window": "court ports held with no beam owner [9443, 8443, 5672]"}
{"metric": "have_mailbox_message_queue_depth_max", "severity": "ABSENT", "ts": "2026-10-19T04:50:24Z", "value": null, "window": "ABSENT: substrate not distributed (epmd names no node); mailboxes not observable"}
{"metric": "have_dets_unrepaired_dirty_tables", "severity": "nominal", "ts": "2026-10-19T04:50:24Z", "value": 0.0, "window": "open-probe over 15 *.dets files (repair disabled)"}
{"metric": "have_ocel_referential_integrity_violations", "severity": "nominal", "ts": "2026-10-19T04:50:24Z", "value": 0.0, "window": "dangling relationship objectIds in docs/jira/v26.10.18/burn/chaos-kill.ocel.json"}
{"metric": "have_petri_net_token_drift", "severity": "nominal", "ts": "2026-10-19T04:50:24Z", "value": 0.0, "window": "burn-cycle objects deviating from modal event count 5 in docs/jira/v26.10.18/burn/chaos-kill.ocel.json"}
```

## just have-status (2026-10-19T04:51:21Z)

```
-- heartbeat --
1792385382.744604
heartbeat age=0.001s
-- alert summary --
state_ledger.jsonl: 12 rows; kinds={'alert': 12}; severities={'SEV3': 2, 'SEV2': 8, 'SEV4': 2}
dispatch_requests.jsonl: 12 rows; kinds={'dispatch_request': 12}; severities={'SEV3': 2, 'SEV2': 8, 'SEV4': 2}
```

(Second telemetry pass in have-status showed `have_control_heartbeat_age_seconds` at 98.895s severity=warning; all other metrics unchanged.)

## Findings (honest)

1. **CRITICAL — have_dangling_socket_listeners=3**: ports 9443/8443/5672 held by pid 61023 `ssh` (non-runtime, tunnel forwarder class). Not owned by any beam. Lane did not evict (no-evict law).
2. **SEV4 — pool deficit**: guard reports 16/20 workers, deficit 4.
3. **SEV2 — crontab missing loop markers**: RP-01 automation not armed (`HAVE_ENFORCE=1` would arm live mode).
4. **ABSENT — mailbox depth**: substrate not distributed; epmd names no node; typed ABSENT row, not a faked zero.
5. `just have-cycle` is not a registered recipe — either the caller's dispatch named the wrong recipe or the cycle recipe is unlanded.
