# Receipt: HAVE-9 justfile.d/31-have.just — `just have-*` operator surface

Standing: ALIVE
Context: solo(just have-* recipes + verify_all.sh stage-h wiring checks; no mix test invocation)
Date: 2026-10-19
Subject: `/Users/sac/smalt/justfile.d/31-have.just` (HAVE component 9) and the verify_all.sh stage wiring in `/Users/sac/smalt/scripts/verify_all.sh` (section h)
Wired: import already present in `/Users/sac/smalt/justfile` (`import 'justfile.d/31-have.just'`)

## Contract

Nine recipes over `scripts/have/`, honest exits throughout:

| recipe | body | exit contract (witnessed) |
|---|---|---|
| `have-guard` | one L1 pool-guard cycle (typed alert + dispatch request on deficit, heartbeat touch) | 0; the JSON IS the verdict |
| `have-watchdog` | L2 meta watchdog; default dry-run, `HAVE_ENFORCE=1` arms the live run | 0 quiet / 1 alerts / 2 config |
| `have-telemetry` | `telemetry.py --emit-all` (ABSENT is typed, never a faked zero) | 0 rows emitted / 2 usage |
| `have-rp01` | enforced watchdog pass; RP-01 automation fires only on heartbeat deadlock, never touches live lanes | 0 quiet / 1 alerts / 2 config |
| `have-rp02` | `storage_probe.py --inspect-headers --verify-clean-open --ledger-pointer` (read-only, never repairs) | 0 / 1 |
| `have-rp03` | `validate_ocel2.py` over the newest `*.ocel.json` burn projection; loud typed SKIP (exit 0 with `[SKIP]` line) when the audit surface is empty | 0 valid / 1 invalid |
| `have-rp04` | `petri_conformance.py` over the newest OCEL projection against the canonical settlement net; REGRESSION quarantines | 0 conformant / 1 imbalance / 2 usage |
| `have-install-crontab` | PRINTS the two cron lines (*/5 guard + */30 watchdog) with this checkout's absolute path; never installs | 0 |
| `have-status` | telemetry snapshot + heartbeat + alert/dispatch ledger summary; report-only | 0 |

Design pinions: the watchdog live-run is dry-run by default (beam/port sweeping
is armed only by `HAVE_ENFORCE=1`); `have-install-crontab` is print-only by
construction; RP-03/RP-04 loud-skip when no OCEL projection exists — a reason,
not a pass.

## Verification (real output)

### `just --list` shows all nine

```
$ just --list | grep have
    have-guard                                   # deficit, heartbeat touch). Exit 0 always — the JSON IS the verdict.
    have-install-crontab                         # docs/reference/have-runbook.md templates with this checkout's absolute path.
    have-rp01                                    # a stale heartbeat (>600s) and never touches live lanes (cwd-prefix rule).
    have-rp02                                    # header inspect + strict fail-closed clean-open verify + ledger pointer.
    have-rp03                                    # which is a reason, not a pass.
    have-rp04                                    # (REGRESSION quarantines to tmp/have/QUARANTINE) / 2 usage/IO.
    have-status                                  # from tmp/have ledgers. Report-only, exit 0.
    have-telemetry                               # typed, never a faked zero). Exit 0 rows emitted / 2 usage.
    have-watchdog                                # / reclaim verified-dead ports). Exit 0 quiet / 1 alerts fired / 2 config.
```

### Per-recipe exits (2026-10-19 04:38Z tree)

```
$ for r in ...; do just $r; echo exit=$?; done
have-guard            exit=0   {"deficit": 16, "severity": "SEV2", "status": "DEFICIT", "target_pool": 20, "ts": "2026-10-19T04:38:28Z", "workers": 4}
have-telemetry        exit=0   8 typed rows (one ABSENT: substrate not distributed — honest, not zero)
have-watchdog         exit=1   ALERT [SEV2] ALRT-CRON-MISSING: crontab has 1 lines but none match AZB/HAVE/smalt loop markers
have-rp01             exit=1   same typed ALRT-CRON-MISSING (honest red: no cron installed yet)
have-rp02             exit=0   RP-02 replay-from-ledger pointer: verified hash-chained ledger .../smalt-cli/audit_manifest.jsonl
                               latest entry_hash: 500cd11e71fb74853489e0316a022f007e3ff95720c68ede0ef5a071f617035b
have-rp03             exit=0   [OCEL2-VAL] PASS docs/jira/v26.10.18/burn/chaos-kill.ocel.json: 5 events, 4 objects, referential integrity OK
have-rp04             exit=1   [PETRI] class=PROTOCOL-UPDATE conformant=FALSE reason=OCEL log carries event type(s)
                               burn.chaos-kill.chaos, burn.chaos-kill.probe not declared in net — net must be re-pinned (honest red)
have-status           exit=0   heartbeat age=0.001s; state_ledger.jsonl: 7 rows severities={'SEV3': 1, 'SEV2': 6};
                               dispatch_requests.jsonl: 7 rows
have-install-crontab  exit=0   printed exactly:
                               */5  * * * * cd /Users/sac/smalt && python3 scripts/have/pool_saturation_guard.py >> .../cron.log 2>&1
                               */30 * * * * cd /Users/sac/smalt && python3 scripts/have/meta_watchdog.py        >> .../cron.log 2>&1
```

`have-watchdog`/`have-rp01`/`have-rp04` exiting 1 is the deliverable, not a
defect: each is a typed honest red on a real open condition (cron not yet
installed; Petri net not yet re-pinned to the chaos-kill event types).

### verify_all.sh wiring (section h, sleep-gate precedent)

Default mode — both stages LOUD-SKIP with reason:

```
have-guard         SKIP   un-enforced pending cron install (just have-install-crontab); HAVE_ENFORCE=1 to enforce
have-telemetry     SKIP   un-enforced pending cron install; HAVE_ENFORCE=1 to enforce
```

`HAVE_ENFORCE=1 bash scripts/verify_all.sh` — both stages run for real:

```
=== [STAGE] have-guard ===
{"deficit": 13, "severity": "SEV2", "status": "DEFICIT", "target_pool": 20, "ts": "2026-10-19T04:39:37Z", "workers": 7}
=== [STAGE] have-telemetry ===
{"metric": "have_control_heartbeat_age_seconds", ... "value": 54.083, ...}
{"metric": "have_worker_fleet_active_count", ... "value": 7.0, "severity": "warning", ...}
{"metric": "have_dangling_socket_listeners", ... "value": 3.0, "severity": "critical", "window": "court ports held with no beam owner [9443, 8443, 5672]"}
... 8 typed rows total
```

The watchdog live-run is deliberately NOT a verify-all stage (its enforce path
sweeps dead beams); it is reachable as `just have-watchdog` / `just have-rp01`.

### Scope note (pre-existing, not session-introduced)

Default-mode `verify_all.sh` exits 1 on this tree via 8 PRE-EXISTING/concurrent
stages (doctor-dod gap-register drift, receipt-index DRIFT from other lanes'
uncommitted receipts, test tiers under concurrent lane churn). None touch this
component: the two HAVE stages PASS in enforce mode and SKIP loudly in default
mode; `bash -n scripts/verify_all.sh` clean; `just --list` parses rc=0.

## Falsifier

`just --list | grep -c have` < 9, or any recipe faking a pass (e.g. RP-03/RP-04
skipping silently, watchdog killing without `HAVE_ENFORCE=1`), or verify-all
default mode running the HAVE stages un-gated.
