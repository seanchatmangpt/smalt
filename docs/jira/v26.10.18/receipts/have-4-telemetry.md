# HAVE-4 — telemetry.py metric catalog emitter

**Standing: ALIVE**

## Subject

`scripts/have/telemetry.py` — HAVE component 4. Emits typed JSONL rows
`{metric, value, window, ts, severity}` for the 8-metric have_* catalog,
with severity banding (nominal/warning/critical) and honest ABSENT rows
(value null, reason in `window`) for unobservable metrics. Zero sleeps.

Threshold table (as implemented; no thresholds table arrived in the dispatch
context, so bands follow the sibling HAVE components' vocabulary and are
documented in the script docstring — coordinator may re-pin):

| metric | nominal | warning | critical |
|---|---|---|---|
| have_control_heartbeat_age_seconds | <=90s | (90,600] | >600s |
| have_worker_fleet_active_count | >=15 | [5,15) | <5 |
| have_orphan_beam_processes_count | 0 | 1-3 | >=4 |
| have_dangling_socket_listeners | 0 | 1 | >=2 |
| have_mailbox_message_queue_depth_max | <1000 | [1000,100000) | >=100000 |
| have_dets_unrepaired_dirty_tables | 0 | 1-2 | >=3 |
| have_ocel_referential_integrity_violations | 0 | 1-9 | >=10 |
| have_petri_net_token_drift | 0 | 1-2 | >=3 |

Metric mechanics:
- heartbeat age reuses `state_ledger.heartbeat_age/1` (HAVE L1 file).
- workers = distinct `pgrep -f 'mix test|docker'` PIDs (component-2 definition).
- orphan beams = tree-aware: a beam.smp with no LISTEN socket in its
  ancestor chain (beam -> mix/elixir -> sh/flock, depth cap 6) — same-checkout-fanout rule 4.
- dangling listeners = court ports (9443/9444/8443/5672/5673/9545) held by a
  non-beam process with no beam owner.
- mailbox depth = eval injection riding Erlang distribution; requires a
  DISTRIBUTED substrate (epmd must name a node) — else typed ABSENT.
  HONEST BOUNDARY, witnessed: `mix run --no-start` spawns its own node and
  cannot read another BEAM's mailboxes; only distribution reaches them.
- DETS dirty = `:dets.open_file(..., repair: false)` probe over tmp/**.dets
  via `mix run --no-start --eval`.
- OCEL integrity + petri drift = newest `*.ocel.json` (docs/jira before tmp);
  integrity = dangling relationship objectIds (agrees with
  `scripts/validate_ocel2.py`); drift = burn-cycle objects deviating from the
  modal event-reference count.

## Verification (real output, exit codes)

1. Self-check (fixture-driven, 21 assertions): `python3 scripts/have/telemetry.py --self-check` →
   21/21 PASS, `self-check: 0 failure(s)`, exit 0.
2. Live snapshot: `python3 scripts/have/telemetry.py --emit-all --out tmp/have/telemetry.jsonl`
   → rc=0, 8 rows, 2.994s wall:

```
{"metric": "have_control_heartbeat_age_seconds", "severity": "warning", "value": 96.165, ...}
{"metric": "have_worker_fleet_active_count", "severity": "warning", "value": 6.0, ...}
{"metric": "have_orphan_beam_processes_count", "severity": "nominal", "value": 0.0, ...}
{"metric": "have_dangling_socket_listeners", "severity": "nominal", "value": 0.0, ...}
{"metric": "have_mailbox_message_queue_depth_max", "severity": "ABSENT", "value": null,
 "window": "ABSENT: substrate not distributed (epmd names no node); mailboxes not observable"}
{"metric": "have_dets_unrepaired_dirty_tables", "severity": "nominal", "value": 0.0,
 "window": "open-probe over 11 *.dets files (repair disabled)"}
{"metric": "have_ocel_referential_integrity_violations", "severity": "nominal", "value": 0.0,
 "window": "... docs/jira/v26.10.18/burn/chaos-kill.ocel.json"}
{"metric": "have_petri_net_token_drift", "severity": "nominal", "value": 0.0,
 "window": "burn-cycle objects deviating from modal event count 5 in .../chaos-kill.ocel.json"}
```

3. Honest ABSENT witnessed live: substrate is UP (beam.smp LISTEN on 9443)
   but not distributed (`epmd -names` → no names, rc 1), so the mailbox
   metric is ABSENT with reason — not faked as zero. DETS probe ran the real
   mix eval over 11 dets files; OCEL metrics read the real chaos-kill
   projection.
4. Cross-check: `python3 scripts/validate_ocel2.py docs/jira/v26.10.18/burn/chaos-kill.ocel.json`
   → `[OCEL2-VAL] PASS ... 5 events, 4 objects, referential integrity OK`, rc=0 —
   agrees with have_ocel_referential_integrity_violations=0.
5. `--metric have_orphan_beam_processes_count` single-metric mode → rc=0,
   one well-formed row.

## Falsifiers (all survived)

- A collector crash must degrade to ABSENT, never skip the row (wrapped).
- ABSENT rows must carry value=null + severity=ABSENT (self-check asserts).
- Petri drift must detect a deviant cycle in a synthetic doc (self-check: drift==1).

## Notes

- `tmp/have/telemetry.jsonl` snapshot appended (gitignored under tmp/).
- No git operations performed, per dispatch.
