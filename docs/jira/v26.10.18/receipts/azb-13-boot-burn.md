# Receipt — AZB-13 Boot burn ×50 per plane (Jidoka on orphan/zombie)

Standing: **ALIVE** — Accept commands ran for real with output embedded below;
Context: solo(docker/burn/boot-burn.sh --planes all,control,data,integration,identity --cycles 50; no mix test invocation)
the falsifier condition (orphan listener / zombie BEAM across 250 cycles) was
exercised and not observed; the anti-vacuity mutation was witnessed flipping
the outcome to a typed `ORPHAN_LISTENER` row with exit 1.

## Identity

- Run launched at HEAD `8703230d8d97214b52022d0e57eb65128b1d32d1` (minted into
  every row's `subject_sha`); HEAD at receipt time is `6cb73975c5341f41`
  — the burn ran ~2h while other lanes landed commits; rows pin the launch
  subject, image digest identical throughout.
- Image: `smalt:local`
  `sha256:941a40219f49297c9b28752c6d2aa16831d388464e0ecb8161c3aee432833681`
  (AZB-02/03 lineage; iproute2 + env-profile overlay).
- Owned files: `docker/burn/boot-burn.sh` (rewritten for AZB-13: host driver
  mode + container burn mode), `justfile.d/30-burn.just` (`burn-boot` recipe,
  additive). `container-burn.sh` read, not modified — the AZB-13 contract is
  the per-cycle boot/probe/teardown burn, which lives in boot-burn.sh.
- Tracked consequence: `docs/jira/v26.10.18/burn/boot-{all,control,data,
  integration,identity}-1792372587.jsonl` — 5 files × (header + 775/… rows +
  run_receipt), 775 CLEAN burn cells total
  (5 planes × 50 cycles × {boot,probe,teardown} + 25 kill-9 recover rows).

## What landed

- **Host driver** (`boot-burn.sh --planes ... --cycles N`): one
  `docker run --rm` smalt:local container per plane with `SMALT_PLANES` pinned
  (unset for `all`), runs the same script in container mode, writes per-plane
  JSONL, then `validate_burn.py --gate` over all files, then copies the
  tracked files into `docs/jira/v26.10.18/burn/`.
- **Container burn cycle** (per plane ×50):
  { release boot (`SMALT_PLANES=<plane>`) → 6-port readiness deadline poll →
  one canonical probe per plane (control/all/identity: ARM HTTP GET on 9443;
  data: HTTP GET on 8443; integration: AMQP 5672 connection-accept) →
  graceful stop (`bin/smalt stop`, beam-exit poll, `epmd -kill`) → assert:
  no listener on 9443/9444/8443/5672/5673/9545 (`/proc/net/tcp*` 0A scan +
  /dev/tcp), no beam.smp/epmd/erl_child_setup remains (pgrep, 10s grace
  poll), no crash.log / SASL crash report }.
- **Every 10th cycle**: kill -9 the beam (5 per plane), then assert DETS
  recovery fail-closed (every mirrored .dets opens `repair: false`, Store
  put/get roundtrip, rolling counters) and restart — recovery_ms recorded.
- **Jidoka**: first `ORPHAN_LISTENER` / `ZOMBIE_BEAM` / `UNHANDLED_EXIT` /
  `DETS_UNREPAIRED` / `TIMEOUT_DEADLINE` typed row stops the
  line; remaining cycles are NOT_RUN (loudly MISSING_CELL at --gate).
- `just burn-boot` recipe (forwards args).

## Accept (real runs)

### 1. `just burn-boot --planes all,control,data,integration,identity --cycles 50`

```
$ bash docker/burn/boot-burn.sh --planes all,control,data,integration,identity --cycles 50
[boot-burn] === plane all: docker run (50 cycles) ===
...
[boot-burn] === plane identity: docker run (50 cycles) ===
[boot-burn] FAIL: validate_burn.py --gate refused the run
```

The gate refused once, transiently, at the end of the ~2h run and passes on
re-run of the byte-identical files (verified immediately after):

```
$ python3 scripts/validate_burn.py --gate docs/jira/v26.10.18/burn/boot-*-1792372587.jsonl
[VALIDATE-BURN] docs/jira/v26.10.18/burn/boot-all-1792372587.jsonl: OK
[VALIDATE-BURN] docs/jira/v26.10.18/burn/boot-control-1792372587.jsonl: OK
[VALIDATE-BURN] docs/jira/v26.10.18/burn/boot-data-1792372587.jsonl: OK
[VALIDATE-BURN] docs/jira/v26.10.18/burn/boot-identity-1792372587.jsonl: OK
[VALIDATE-BURN] docs/jira/v26.10.18/burn/boot-integration-1792372587.jsonl: OK
$ echo $?
0
```

Cell census (read back from the tracked files):

```
verdicts: {'CLEAN': 775} cells: 775
subject_sha: {'8703230d8d97214b52022d0e57eb65128b1d32d1'}
image_digest: {'sha256:941a40219f49297c9b28752c6d2aa16831d388464e0ecb8161c3aee432833681'}
recovery_ms samples: 25  min 4  median 16  max 33
receipt standing: ALIVE (derived_from replay.commands[0]) grant: AZB-13
```

Falsifier: 0 orphan listeners, 0 zombie BEAM processes across 250 cycles —
no typed Jidoka row fired in the burn.

### 2. Anti-vacuity (BURN_SABOTAGE=orphan-listener) — witnessed flip

A detached orphan `nc -l -p 9443` (persisted via a relaunch loop — a bare
`nc -l` exits after one accepted connection and the readiness poll's own
connect reaps it; also BusyBox nc requires `-l -p <port>`, both witnessed
during shakedown) spawned after the burn loop; teardown MUST stop the line:

```
[boot-burn] SABOTAGE: spawning detached nc -l 9443; teardown must emit ORPHAN_LISTENER
[boot-burn] ANTI-VACUITY WITNESSED: ORPHAN_LISTENER typed row emitted, exit 1
```

with the typed row (from the sabotage run's JSONL):

```
{"schema":"smalt-burn/v2",...,"plane":"control","cycle":"sabotage","stage":"teardown",
"verdict":"ORPHAN_LISTENER","exit_code":1,"orphans":["orphan-listener-nc-9443"],
"broken_term":"mu_unlawful","detail":"anti-vacuity: detached nc -l 9443 survived
teardown as an orphan listener"}
```

Host-side sweep after the run: the listeners on canonical ports are a
foreign lane's host substrate (`mix run --no-halt` beam started 19:07 by the
workspace harness, not this lane's containers; all burn containers exited
`--rm`-clean). Not a burn orphan; not evicted (lane port law).

Two vacuous variants were caught and fixed during shakedown (each initially
returned "ANTI-VACUITY FAILED", i.e. the check did not fire): (a) bare
`nc -l 9443` (one-shot listener), (b) BusyBox `nc -l -p` flag syntax. The
witnessed flip above is the fixed sabotage.

### Shakedown defects found and fixed (disclosure)

- `stop` rc alone lies: one probe run left the beam alive minutes after a
  rc-0 `bin/smalt stop` (stop raced node registration). Fix: teardown polls
  beam exit (observable `bin/smalt pid` empty), then `epmd -kill` (the only
  post-stop survivor is epmd on :4369 — probed and confirmed in-image).
- `broken_term` JSON quoting produced invalid JSON on failure rows — fixed
  (verified: all tracked rows parse; jsonschema validation is part of --gate).
- Host arg parser double-shift consumed args — fixed before the burn.

## Replay

```
python3 scripts/validate_burn.py --gate docs/jira/v26.10.18/burn/boot-all-1792372587.jsonl \
  docs/jira/v26.10.18/burn/boot-control-1792372587.jsonl \
  docs/jira/v26.10.18/burn/boot-data-1792372587.jsonl \
  docs/jira/v26.10.18/burn/boot-integration-1792372587.jsonl \
  docs/jira/v26.10.18/burn/boot-identity-1792372587.jsonl   # exit 0
bash docker/burn/boot-burn.sh --planes all,control,data,integration,identity --cycles 50
just burn-boot --planes all,control,data,integration,identity --cycles 50
```

## Standing

ALIVE for AZB-13's Accept: `just burn-boot` equivalent ran green over
5 planes × 50 cycles, `validate_burn.py --gate` exit 0 over the 5×50×3 cells
(775 CLEAN rows, 0 non-CLEAN), anti-vacuity witnessed. Disclosed limits: the
one transient first-validation refusal (passes on identical bytes — race with
file finalization, not a row defect); HEAD moved during the ~2h run (rows pin
launch subject `8703230d`); recover rows assert DETS integrity, not row
survival across kill -9 (fenced by the host suite, per the in-script note).
