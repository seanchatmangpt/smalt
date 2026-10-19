# Receipt: HAVE-11 end-to-end fault drill

Standing: ALIVE (all six drill steps executed; two typed storage verdicts witnessed across two live runs)
Context: solo(scripts/have/have_11_drill.sh end-to-end fault drill, 2 live runs; no mix test invocation)
Date: 2026-10-19
Lane: have-11 (solo)
Subject: `/Users/sac/smalt/scripts/have/have_11_drill.sh` + `/Users/sac/smalt/scripts/have/{storage_probe,meta_watchdog,telemetry,alert_policy}.py`
Result file: `/Users/sac/smalt/docs/jira/v26.10.18/bench/have-11-drill.jsonl` (7 rows, run 4)
Artifacts: `/Users/sac/smalt/tmp/have/drill/20261019T044615Z/` (run 4, TYPED_OK) and `/Users/sac/smalt/tmp/have/drill/20261019T044529Z/` (run 3, TYPED_NEEDS_REPAIR)

## Machine

```
$ just bench-machine
{"cpu":"Apple M3 Max","cores":16,"ram_gb":48,"elixir":"1.19.5","otp":"28","darwin":"26.2"}
```

## Contract

End-to-end fault drill proving the HAVE engine catches what it claims:
boot a private substrate, SIGKILL the beam with its DETS mirror open, then
walk the detection chain: storage_probe → meta_watchdog → telemetry →
alert_policy. A lane writes only its own result file; no git.

## Verification

### (1) Private substrate boot — PASS

`MIX_ENV=test mix run --no-start --no-halt` writer beam: `Smalt.Store` +
`Smalt.Store.DetsMirror` on a private dir (`tmp/have/drill/<ts>/dets`,
tables `[:smalt_blobs]`, interval 3_600_000, `blob_storage` profile
`persistence: :dets_mirrored, sync_interval_ms: 0`). 50 000 × 2 KB writes
with per-write fsync via `sync_write/1`.

```
[04:46:16] drill 20261019T044615Z start
[04:46:18] (1) substrate up pid=77687 dir=/Users/sac/smalt/tmp/have/drill/20261019T044615Z/dets
```

### (2) SIGKILL → typed storage verdict — both branches witnessed

Run 4 (04:46): `kill -9` on the writer beam →
`storage_probe --verify-clean-open --data-dir <private dets>`:

```
(2) storage_probe exit=0: smalt_blobs.dets  OK
```

→ **TYPED_OK** (dets had synced to a consistent point at kill).

Run 3 (04:45, same script, `tmp/have/drill/20261019T044529Z/stages.log`):

```
(2) storage_probe exit=1: smalt_blobs.dets  NEEDS_REPAIR
```

→ **TYPED_NEEDS_REPAIR**. Both members of the typed disjunction
(clean-or-needs-repair) were observed live in this session; run 4's rows
are the ones in the result JSONL, run 3's evidence is its stages.log.

### (2b) Non-vacuity mutation — PASS

Truncating 25% of the first mirror file MUST flip the probe. It did:

```
[04:46:20] (2b) mutation exit=1 typed=NEEDS_REPAIR   (run 4, after TYPED_OK)
[04:45:32] (2b) mutation exit=1 typed=NEEDS_REPAIR   (run 3)
```

A probe that cannot fire is FAIL; the probe fired on both a clean-then-cut
and an already-torn store.

### (3) meta_watchdog --dry-run — PASS (typed alerts, no action)

```
=== meta_watchdog (DRY-RUN) ===
ALERT [SEV2] ALRT-DANGLING-LISTENER: port 9443 held by non-runtime pid 61023 cmd='ssh' (no live owner class)
ALERT [SEV2] ALRT-DANGLING-LISTENER: port 8443 held by non-runtime pid 61023 cmd='ssh' (no live owner class)
ALERT [SEV2] ALRT-DANGLING-LISTENER: port 5672 held by non-runtime pid 61023 cmd='ssh' (no live owner class)
ALERT [SEV2] ALRT-CRON-MISSING: crontab has 1 lines but none match AZB/HAVE/smalt loop markers ('azb', 'have', 'smalt')
no actions
exit=1
```

Killed-beam remnants: none survived as orphan beams (run 3/4 kills hit the
beam directly; no zombie cohort >= 3 formed) — the zombie rule correctly
did NOT fire; the dangling-listener and cron rules DID fire on real state
(an ssh tunnel from another session holds 9443/8443/5672; no machine
crontab markers). Dry-run executed nothing.

### (4) telemetry --emit-all — PASS (8/8 rows, severity classified)

```
have_control_heartbeat_age_seconds      4.46     nominal
have_worker_fleet_active_count          15.0     nominal
have_orphan_beam_processes_count        0.0      nominal
have_dangling_socket_listeners          3.0      critical
have_mailbox_message_queue_depth_max    null     ABSENT (substrate not distributed — honest absent, not zero)
have_dets_unrepaired_dirty_tables       0.0      nominal
have_ocel_referential_integrity_violations 0.0   nominal
have_petri_net_token_drift              0.0      nominal
```

### (5) alert_policy on the emitted rows — clean bill, with a typed gap

```
$ python3 scripts/have/alert_policy.py tmp/have/drill/20261019T044615Z/telemetry.jsonl --no-write
HAVE-5: clean, 0 alerts   (exit 0)
```

**Drill finding F-1 (detection gap, honest)**: the SEV matrix enforced by
alert_policy (HEARTBEAT-DEADLOCK, STORAGE-CORRUPTION-UNREPAIRED,
PETRI-TOKEN-IMBALANCE, FLEET-STARVATION, PROCESS-LEAK-ZOMBIE) has no rule
for `have_dangling_socket_listeners`, so a telemetry row at severity
`critical` still yields a clean bill. The watchdog typed the alert in step
(3); the policy layer does not consume it. Close condition: an
ALRT-DANGLING-LISTENER SEV-matrix row (SEV2 per meta_watchdog's own
classification) in alert_policy, or an explicit register row.

### (6) Drill JSONL — written

`docs/jira/v26.10.18/bench/have-11-drill.jsonl` — 7 rows
(lane have-11, surface have, ops: boot_private_substrate, sigkill_midwrite,
storage_verify_clean_open, storage_probe_mutation_witness, meta_watchdog_dry_run,
telemetry_emit_all, alert_policy_eval; verdicts above; errors=0; machine block
embedded per row).

## Honest boundaries / failures

- The SIGKILL in both runs landed after the 50k-write burst drained
  (byte counter at kill not mid-burst) — `midwrite: false` in the JSONL.
  The fault class exercised is kill -9 with the dets file OPEN (no close),
  which is the un-clean-shutdown class AZB-14 pins; a true in-fsync torn
  write was produced synthetically by the 25% truncation mutation (2b).
- `have_dets_unrepaired_dirty_tables` reads `tmp/**/*.dets`, not the
  private drill dir, so it reads nominal (0) during the drill window even
  while run 3's mirror sat NEEDS_REPAIR — scan window is a documented
  boundary of component 4, and step (2)'s probe is the authoritative
  verdict for the faulted store.
- Run 1 of the drill failed boot (`interval: :infinity` is not a valid
  `Process.send_after` interval — ArgumentError, fixed to 3_600_000) and an
  interim run hung on an unbounded write loop (O(n²) sync_table growth);
  scratch dirs under `tmp/have/drill/` remain (rm of repo tmp denied to
  this lane). Their rows are not in the result file.
- alert_policy ran with `--no-write`: no `*.hold` dispatch-hold files were
  minted by this lane (none were warranted; bill was clean).

## Falsifiers

- Re-run `bash scripts/have/have_11_drill.sh`: boot step FAILs if the
  writer never prints WRITER_READY; the mutation step FAILs if truncation
  does not flip the probe to NEEDS_REPAIR/CORRUPT_HEADER + exit 1.
- `storage_probe --verify-clean-open` exits 0 iff every table opens with
  `repair: false`.
