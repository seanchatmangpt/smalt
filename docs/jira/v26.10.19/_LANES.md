# v26.10.19 Work Orders — Lane Partition

Release: v26.10.19 · Base: HEAD `64f6099` (post-deletion; the clean-room
deletion commit V261019-11 removed all 303 tracked `test/` files). The design
lanes worked from the pre-deletion base `4fd2ff2`; every path claim below is
re-grounded to the post-deletion tree at materialization (2026-10-19).
Generated 2026-10-19 by the 60-lane reset fan-out; 16 lanes = 6 work orders
carried from the v26.10.18 window + 10 reset-plan lanes. Materialized by the
docs-materialization lane; per-WO detail lives in the `NN-*.md` files.

## Work orders

| # | Doc | Lane | Headline | Priority |
|---|---|---|---|---|
| WO-1 | [01-burn-ring-image-lease.md](01-burn-ring-image-lease.md) | burn-ring | Carried: `just burn-ring` re-run under flock image-build lease + SUBJECT_SHA build-arg fix (3rd strike; retire ring shape on further failure) | **P0** |
| WO-2 | [02-sovereign-g-register.md](02-sovereign-g-register.md) | sovereign-gaps | Carried: SOVEREIGN_MIDNIGHT G-register — G2 X-ARR mTLS, G3 EG DLQ spillover, G4 split-brain failover (G4 behind G2/G3) | P1 |
| WO-3 | [03-gap-azb20-plane-mounting.md](03-gap-azb20-plane-mounting.md) | azb20-mount | Carried: GAP-AZB20-1/4 plane-mounting Option A — Store in control subtree, ErrorHandler + arm_request_id plug, ResourceGraph route (~50 lines, 3 edits) | **P0** |
| WO-4 | [04-cgroup-soak.md](04-cgroup-soak.md) | cgroup-soak | Carried: azb-18 cgroup soak — read-only `../ggen_igniter` mount, SMALT_SOAK_MEM_LIMIT 4g / staggered compile, persist env-overridable defaults | P1 |
| WO-5 | [05-isolation-quiet-window.md](05-isolation-quiet-window.md) | isolation-quiet | Carried: isolation runtime5 quiet-window rerun under `just quiesce`; carry typed-expiry note as secondary item | P1 |
| WO-6 | [06-queue-storage-peek-clear.md](06-queue-storage-peek-clear.md) | queue-comps | Carried: Queue Storage peek/clear comps on the existing engine + `queue_storage_plane` arm; percent-encoded names stay out of face | P1 |
| WO-7 | [07-clean-room-reset.md](07-clean-room-reset.md) | reset-inventory | Reset: pre-deletion lifts (ts-run.mjs / conftest.py) + 303-path all-delete manifest — **DONE** (lifts/ + receipts/reset-delete-manifest.txt) | **P0** |
| WO-8 | [08-verification-ts.md](08-verification-ts.md) | ts-suite | Reset: `verification/ts` external official-SDK suite (5 workflows, node --test, exit 0/1/2/3/124, no @azure/eventgrid per KD-101) | **P0** |
| WO-9 | [09-verification-py.md](09-verification-py.md) | py-suite | Reset: `verification/py` external suite (lifted conftest, pytest mirror of wf1–wf5, azure deps as optional-extra) | **P0** |
| WO-10 | [10-residual-internal-tier.md](10-residual-internal-tier.md) | residual-tier | Reset: fresh `test/internal/` 5 files re-derived from lib ground truth + the Non-Duplication census guard | P1 |
| WO-11 | [11-test-deletion-gate.md](11-test-deletion-gate.md) | deletion-gate | Reset: clean-room deletion — **LANDED at `64f6099`**; TS+PY+residual parity receipts at one pinned SHA are the closing backfill | **P0** (backfill owed) |
| WO-12 | [12-court-x2-close.md](12-court-x2-close.md) | court-x2 | Reset: 11-stage court, two consecutive greens at one pinned SHA; TYPED-RED carried from v26.10.18 | **P0** (final gate) |
| WO-13 | [13-identity-rs256.md](13-identity-rs256.md) | identity-rs256 | Identity: RS256 signing + JWKS + `/common/discovery/instance` metadata aliases; closes KD-99/KD-100; official-SDK acceptance = ClientSecretCredential 200, zero custom code | P1 |
| WO-14 | [14-substrate-boot-library.md](14-substrate-boot-library.md) | boot-library | Substrate: `scripts/lib/substrate_boot.sh` + `substrate-ctl` (fd-9 law, boot markers, v-law formula blocks, tree-aware orphans, bounded poll) | P1 |
| WO-15 | [15-verification-gates.md](15-verification-gates.md) | verification-gates | Gates: non-duplication R1/R2/R3, portable-target whitelist, sleep-gate TS/PY scopes + shim courts; `justfile.d/32-verification.just` wired into court | P1 |
| WO-16 | [16-milestone-wrap.md](16-milestone-wrap.md) | final-wrap | Wrap: regenerate RECEIPTS/SDK_MATRIX/BENCH (never hand-edit), KD/GAP settle, court-x2 post-commit re-witness, publish-dry, FINAL.md | P2 (terminal) |

## Shared-file ownership (disjoint seams)

| File | Owner(s) | Split |
|---|---|---|
| `docs/jira/v26.10.19/WORK_ORDERS.md` | carried lanes WO-1..6 | each lane appends receipts/closes only to its own WO section; no lane edits another's section |
| `docker/Dockerfile` | WO-1 (burn-ring) | SUBJECT_SHA default / required build-arg; no other lane touches |
| `scripts/validate_burn.py` | WO-1 (fixed) / WO-4 (consumes) | 1 owns changes; 4 runs it read-only |
| `docs/jira/v26.10.18/azsim-burn/SOVEREIGN_MIDNIGHT.md` | WO-2 | G-register flips receipt-gated; no unilateral GAP tokens |
| `lib/smalt/plane/control_supervisor.ex` | WO-3 | additive Store child start; the boot library (WO-14) references, never edits |
| `lib/smalt/arm_gateway/router.ex` | WO-3 / WO-13 | 3: ErrorHandler plug + ResourceGraph route; 13: JWKS + discovery-instance routes, disjoint route arms |
| `lib/smalt/auth/{sts_key,bearer}.ex` | WO-13 | RS256/JWKS + alg-agnostic KD-15/94 fences; WO-8/9 consume via wire only |
| `lib/smalt/messaging/event_grid.ex` | WO-2 (G3) | DLQ blob spillover path only |
| soak harness (`SMALT_SOAK_*` defaults) | WO-4 | env defaults + read-only ggen_igniter mount only |
| `scripts/isolation_court.py` invocation surface | WO-5 | quiet-window rerun only; no validator edits |
| `lib/smalt/data_plane/queue_storage.ex` + `queue_storage_plane` arm | WO-6 | peek/clear comps only |
| `verification/ts/**` | WO-8 | the external TS suite; docs lane owns only `verification/README.md` + `verification/workflows.json` |
| `verification/py/**` | WO-9 | the external PY suite |
| `test/internal/**` | WO-10 | residual tier; the deletion gate (WO-11) owns the rest of `test/` |
| `scripts/lib/substrate_boot.sh` + `substrate-ctl` | WO-14 | boot library; WO-8/9 harnesses are thin wrappers, never private boots |
| `scripts/non_duplication_gate.py` / `scripts/portable_target_gate.py` / sleep-gate scopes | WO-15 | gates; suites lanes consume, never edit |
| `scripts/sdk_coverage.py` + `justfile.d/32-verification.just` | WO-15 (gates wiring) / WO-16 (matrix regen) | 15 lands the workflows.json ingestion + court wiring; 16 regenerates the matrix at wrap |
| generated docs (RECEIPTS/SDK_MATRIX/BENCH/ERROR_CODES) | WO-16 exclusive | other lanes cite, never hand-edit |
| `docs/jira/v26.10.19/FINAL.md` + `RECEIPTS.md` | WO-16 exclusive | reconciles all lane receipts last; docs lane materialized the FINAL skeleton |
| KD rows KD-99..KD-113 | kd-registrar lane | mint + flip via `scripts/kd_flip.py` only, receipt-gated |

## Dependency order

```
WO-7 (inventory) ──→ WO-8 ∥ WO-9 (suites; consume WO-14 boot library)
                     WO-10 (residual tier) runs alongside
WO-8 + WO-9 + WO-10 green at ONE pinned SHA ──→ WO-11 backfill closes
WO-13 (identity RS256) unblocks the official-credential legs of WO-8/WO-9
WO-15 (gates) lands BEFORE court rewiring — the gates are the measuring stick
WO-15 ──→ WO-12 (11-stage court incl. sleep-gate-sdk leg) ──→ WO-16 (wrap)
WO-1..WO-6 independent (shared seams per table)
WO-3 ──→ WO-12 (court sees the mounted plane)
WO-16 LAST; nothing lands after the wrap
```

Laws: the WO-11 deletion landed early at `64f6099`; its TS+PY+residual parity
receipts at one pinned SHA are a closing obligation, not a precondition.
No court rewiring before WO-15's gates exist. Court-x2 is the last
verification step; the wrap (WO-16) is the last step, period.

## Session state at materialization time (2026-10-19, HEAD `64f6099`)

- `test/` = `test_helper.exs` tracked + fresh `test/internal/` landing
  (plane_blast_radius, vm_zero_growth, poll_helper present; wasm/dets/census
  guard pending — WO-10).
- `verification/` hosts this README + `workflows.json` (20 inventory ids, 0
  orphans); `verification/ts/` + `verification/py/` land from the suites
  lanes (WO-8/WO-9).
- On disk untracked: `lib/smalt/auth/sts_key.ex` + router/bearer edits
  (WO-13 in flight); `scripts/lib/substrate_boot.sh` (WO-14);
  `scripts/non_duplication_gate.py` + `scripts/non_duplication_classes.json`
  + `scripts/portable_target_gate.py` (WO-15).
- Burn-ring lanes (WO-1) must build at a pinned SHA with
  `--build-arg SUBJECT_SHA=$(git rev-parse HEAD)` — never bake stale defaults.
- Zombie repair standing is ALIVE via `azb-22b-zombie-verify.md` — the ring
  re-run must not regress the zombie-fix receipt.
- GAP-AZB20 all 4 cells FAIL on the `502c4ed` lineage — do not declare
  control-plane 500s out of scope; Option A mount is the chosen fix.
- `validate_burn.py` derives standing from plane rows (non-clean caps at
  PARTIAL_ALIVE, non-zero exit) — soak/burn lanes must not weaken this.
- G5 stays narrowed to injectors-only; G6 remains closed via the azb20 lib
  land family — G-register flips cite receipts only.
- Isolation residual is load-shaped: runtime5 reruns happen only under
  `just quiesce` / `just quiet-check` discipline.
- Queue percent-encoded names stay out of the G1 face per the R154
  decode-aware precedent — no GAP token for them without a witnessed parity
  defect.
