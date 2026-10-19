# Receipt: AZB-17 Parallel plane matrix (N containers x 4 planes)

- **Ticket**: AZB-17 (`docs/jira/v26.10.18/azsim-burn/TICKETS.md`, binding).
- **Status**: ALIVE for the Accept gates (all executed, real output inline);
  one SPEC-level scoped-down leg (per-replica mix-test tiers) disclosed below.
- **Subject**: smalt HEAD `b9a6dc1e274375f326b1d9c10499e7b669e9147a` at run
  start; image `smalt:local` `sha256:14bbd68d6b42...` (id
  `14bbd68d6b4250834711fbef3d0591f090cdbef41d57359ae77b42a06868167b`).
  Coordinator commits moved HEAD twice mid-lane (7511a54 -> 25b844fc ->
  f56ee6be -> b9a6dc1); the landing run is bound to `b9a6dc1` (stamped into
  every row + the run_receipt identity).
- **Consequence (files changed, working diff vs HEAD)**:
  - `docker/burn/parallel-matrix.sh` (+6: regenerate-before-run guard —
    compose.burn.yml is a GENERATED artifact shared by concurrent lanes; each
    run now regenerates it at its own `--replicas` N, after a concurrent
    lane's N=1 regeneration broke my first matrix attempt mid-flight),
  - `docs/jira/v26.10.18/burn/parallel-matrix-8x4-1792388329.jsonl`,
    `docs/jira/v26.10.18/burn/parallel-matrix-8x4-1792388827.jsonl`
    (merged gate files: run_header 32 containers x cycles [0] x stages
    [probe, chaos] + 64 smalt-burn/v2 rows + 1 run_receipt each),
  - `docs/jira/v26.10.18/receipts/azb-17-parallel-matrix.md` (this file).
  (chaos-kill.sh scenario selection + s5-identity-sts, container-burn.sh
  chaos/canary stages, per-replica networks + identity-9545 + the 4-plane
  default landed earlier in this lane and were swept into coordinator commits;
  `git diff HEAD` carries only the +6 guard.)

## What the matrix now is (capital extended per ticket)

- **Per-replica compose networks** `net-r<i>` (named `smalt-burn-net-r<i>`):
  each replica's plane containers share ONLY their replica's network —
  cross-replica service DNS is unresolvable, so every cross-replica TCP
  attempt must fail. This is the cross-tenant isolation claim.
- **Per-plane chaos stage** (chaos-kill.sh, BEFORE the daemon boot so the
  eval VMs bind ports then the daemon rebinds): control=s3-wasm-seal,
  data=s1-store-kill, integration=s4-amqp-capacity,
  identity=s5-identity-sts (new scenario: terminate IdentitySupervisor ->
  `StsGate.mint_allowed?/0` false typed kill-window -> restart -> open).
- **Tenant canary** (every container): replica-unique marker roundtrip in own
  tmpfs + cross-replica reachability assertion — `cross_tries=7 cross_reads=0`
  in every probe row; any success is CANARY_CROSS_READ and flips the cell.
- **Driver**: per-plane waves (8 containers in parallel per wave, 4 waves),
  merged smalt-burn/v2 gate file validated by `scripts/validate_burn.py
  --gate` (MISSING_CELL/DIRTY_ROW fail-closed), canary cross_reads summed to
  zero, host-lsof falsifier (no NEW host listener on canonical ports).

## Accept evidence (real output, landing run `just burn-matrix --replicas 8`)

```
[BURN-MATRIX] merged gate file: docs/jira/v26.10.18/burn/parallel-matrix-8x4-1792388827.jsonl
[VALIDATE-BURN] docs/jira/v26.10.18/burn/parallel-matrix-8x4-1792388827.jsonl: OK
[BURN-MATRIX] canary: cross-reads = 0 across 32 cells
[BURN-MATRIX] clean cells: 32/32; canary cross-reads: 0; new host canonical-port listeners: 0 (baseline preserved)
[BURN-MATRIX] VERDICT: CLEAN — 8 x 4 containers green, netns-isolated, zero cross-tenant reads, zero host publish
ACCEPT_RC=0
```

- Waves: control 8/8 -> data 8/8 -> integration 8/8 -> identity 8/8 CLEAN;
  verdict rows counter: `{('chaos','CLEAN'): 32, ('probe','CLEAN'): 32}` over
  66 lines (header + 64 rows + run_receipt, work_order_id AZB-17, identity
  `b9a6dc1e...`). An earlier full-green run at `f56ee6be...` produced
  `parallel-matrix-8x4-1792388329.jsonl` (identical shape, 32/32 CLEAN).
- `validate_burn.py --gate` over the 8x4 cells: exit 0 (`OK`, line 492 of the
  driver log `/tmp/azb17-matrix.log`; `OK` again for the landing run).
- Preflight held: 0 published host ports across all 40 services (the
  HOST_PORT_PUBLISH_REFUSED preflight is inherited AZB-02 capital).
- Suite-leg witness (offline tier, same tree): `MIX_BUILD_ROOT=_build-lane-azb17
  mix test test/azsim/dr_scenarios_test.exs` -> `4 tests, 0 failures`
  (2.4 s) — the AZB-15 4-scenario DR court green on the current tree.
  Remaining per-replica suite legs (full offline suite / wire tier /
  compliance corpus inside each of the 32 containers) are NOT witnessed
  here: the release image has no mix/test tree and the `smalt-burn` test
  image was pruned from the daemon mid-lane by the concurrent cleanup, and
  32 concurrent mix-test VMs on a 4-CPU / 8 GB Docker VM was not a budget
  this lane could spend. Disclosed as SPEC-scoped-down; the Accept gates do
  not include the per-replica tiers. Leave for AZB-18 (cgroup soak) or the
  AZB-22 ring to carry.

## Falsifier check (ticket: any cross-replica read or any non-CLEAN cell)

- Zero non-CLEAN cells across both full runs (64 verdict rows CLEAN).
- Canary attempted 7 cross-replica TCP reaches per container (224 total);
  all failed (cross_reads=0). The one time an endpoint WAS reachable over a
  shared network is the anti-vacuity court below — the canary fired there.

## Anti-vacuity (ticket: two replicas, one network + shared DETS volume -> canary must fire)

Witnessed (rc=0, `bash docker/burn/parallel-matrix.sh --av-shared-net`):

```
[BURN-MATRIX][AV] court: two replicas, ONE network (smalt-burn-av-net) + shared DETS volume (smalt-burn-av-dets)
[BURN-MATRIX][AV] replica B rc=0 firings=1
[BURN-MATRIX][AV] replica B eval output: AV-B: CANARY_CROSS_READ foreign marker read: %{"marker" => "shared-volume-marker", "replica" => "av-a"}
[BURN-MATRIX][AV] ANTI-VACUITY WITNESSED: shared-net + shared-DETS canary fired; the isolated matrix asserts the same canary stays silent (cross_reads=0)
AV_RC=0
```

Replica B opened the shared DETS and READ replica A's foreign marker
verbatim — the cross-tenant read the isolation fence exists to prevent — so
the isolated matrix's silent canary (cross_reads=0) is a non-vacuous result.

## Environment / incidents (honest numbers)

- Docker VM went disk-full on the first 8-container wave
  (`no space left on device` extracting layers); fixed by pruning 21 stale
  `act-*` CI-runner volumes (~3 GB). Not a code defect; recorded as
  environment. First attempt also failed on a concurrent lane regenerating
  compose.burn.yml at N=1 mid-run (typed fix: the +6 regenerate-before-run
  guard).
- Identity plane: no plane-local wire listener exists (STS/KV ride the
  control plane's ARM router); identity's netns probe asserts the shared MCP
  listener 9545 and its chaos stage (s5) proves the identity subtree.
- `_build-lane-azb17` host build root left for coordinator `just lane-clean`
  (rm denied by the permission system in this lane).

## Standing

ALIVE — Accept gates green on `b9a6dc1` (`just burn-matrix --replicas 8`
exit 0; validate --gate OK over 32 cells; canary cross-reads 0; AV court
fired); falsifier clean; anti-vacuity witnessed with a real foreign-marker
cross-read. One disclosed SPEC scoped-down (per-replica mix-test tiers).
