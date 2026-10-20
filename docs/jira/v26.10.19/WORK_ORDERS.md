# WORK_ORDERS

v26.10.19 work orders — 6 typed-open items carried from the v26.10.18 window
(`docs/jira/v26.10.18/FINAL.md`) plus the clean-room reset ladder WO-7..16
(fresh verification/{ts,py} external suites, residual internal tier, deletion
gate, identity RS256, boot library, gates, wrap). Each item: evidence receipt
+ close condition + priority. Context: solo(...)

Base: pre-deletion HEAD `4fd2ff2`; deletion commit `64f6099` (V261019-11
landed — legacy test/ tree deleted, `test/` = test_helper.exs only).

## Execution order

WO-7 -> WO-8 ∥ WO-9 -> WO-10 -> WO-11-gated -> WO-12/13 -> WO-14/15
-> WO-16. WO-1..6 run on independent lanes and gate WO-12's court legs.
Deletion (WO-11) executed early at `64f6099`; its parity backfill (WO-8/9/10
receipts green at one pinned SHA) is a closing obligation of this window,
not a precondition.

## WO-1 — Burn-ring re-run under flock image-build lease + SUBJECT_SHA build-arg fix

- Status-2026-10-19: **ALIVE** — mechanical fixes landed
  (`receipts/v261019-wo1-subject-sha-lease.md`: SUBJECT_SHA build-arg +
  flock image-build lease); the `just burn-ring` re-run itself remains
  open.
- Standing: **BLOCKED[image-subject-mismatch loop + colima daemon EOF]** — 3rd
  strike on the `just burn-ring` re-judge. Evidence:
  `docs/jira/v26.10.18/receipts/azb-22b-zombie-fix.md`
  (§"Ring boot re-judge retry — BLOCKED again", 6 docker builds / 0 ring runs;
  zombie *repair* is ALIVE via `azb-22b-zombie-verify.md`, the ring itself never
  re-ran). Preflight: `docs/jira/v26.10.18/azsim-burn/AZB23-PREFLIGHT.md` B2/B3.
- Root causes, both mechanical:
  1. `docker/Dockerfile:26` bakes a stale default
     `ARG SUBJECT_SHA=29bb0371…` — label stale on arrival unless overridden.
     Fix: pass `--build-arg SUBJECT_SHA=$(git rev-parse HEAD)` always
     (BUILD_RECEIPT.md command) AND update the default to the pinned ring SHA,
     or remove the default in favor of a required build-arg.
  2. Concurrent docker builds race (witnessed 4 concurrent `docker build` PIDs,
     `azb-22b-zombie-fix.md` lines ~170): two lanes baked different SHAs while
     HEAD moved under them. Fix: image-build lease per
     `docs/jira/v26.10.18/azsim-burn/AZB23-PREFLIGHT.md` line 69 — flock on a
     build lockfile, build at a pinned SHA, verify HEAD unchanged post-build,
     release after boot-stage verification (same discipline as
     `scripts/substrate.sh`).
- Close condition: `just burn-ring` completes at a pinned SHA with
  `org.smalt.subject` == ring subject; burn receipt derived standing ALIVE via
  the fixed `scripts/validate_burn.py` (all plane rows clean);
  `docs/jira/v26.10.18/azsim-burn/AZB23-PREFLIGHT.md` B2/B3 flip BLOCKED→PASS.
  Third-strike rule applies: a further failure retires the ring shape.

## WO-2 — SOVEREIGN_MIDNIGHT G-register: G2 X-ARR mTLS, G3 EG DLQ spillover, G4 split-brain failover

- Status-2026-10-19: **G2 LANDED** (plug + witness receipt);
  **G3 LANDED** (DLQ spillover, typed dead-letter face);
  **G4 still OPEN** (split-brain failover plane unscheduled).
- Standing per `docs/jira/v26.10.18/azsim-burn/SOVEREIGN_MIDNIGHT.md`
  §"Gap register (build order for v26.10.19)":
  - **G2 MISSING** — X-ARR-ClientCert mTLS gateway termination + spoof
    injector (grep: 0 hits; arm_throttle 429 exists).
  - **G3 MISSING** — Event Grid DLQ blob spillover; extends the azb-07 engine
    (`lib/smalt/messaging/event_grid.ex`: no DLQ/blob path).
  - **G4 MISSING** — Split-brain regional failover plane — new architecture
    (grep: 0 hits).
- Evidence receipts:
  `docs/jira/v26.10.18/receipts/i29-sovereign-gap-triage.md` +
  `docs/jira/v26.10.18/receipts/i29-midnight-map-refresh.md` (all 18 test
  bodies untagged, 18/0 on HEAD); G5 narrowed to injectors-only in the same
  register; G6 closed via `docs/jira/v26.10.18/receipts/i29-azb20-lib-land.md`
  family (ResourceGraph route family at egress_router.ex:1311).
- Close conditions:
  - G2: X-ARR-ClientCert termination on the ARM surface + spoof-injector test
    refuses a spoofed cert; `grep -ri "X-ARR-ClientCert" lib/` > 0 hits; row
    flips MISSING→COVERED with a receipt.
  - G3: DLQ blob spillover path in the Event Grid engine with a typed
    dead-letter face; wire test exercises delivery-failure → DLQ blob write;
    row flips with receipt.
  - G4: split-brain failover plane (new architecture, largest item — schedule
    behind G2/G3); row flips only with a real failover witness receipt.
  - Register is hand-maintained prose in SOVEREIGN_MIDNIGHT.md — flips cite
    receipts; no GAP tokens minted from this register unilaterally.

## WO-3 — GAP-AZB20-1/4 plane-mounting implementation (Option A)

- Status-2026-10-19: **LANDED** — control-plane Store mount witness +
  regression green (20/0) per the Option A plan; GAP-AZB20 rows flip
  receipt-gated.
- Standing: **OPEN — all 4 cells FAIL on HEAD `502c4ed`**. Evidence:
  `docs/jira/v26.10.18/receipts/i29-azb20-postfix.md` (postfix re-test, all
  four cells still open; root cause re-confirmed in code on HEAD).
- Plan: `docs/jira/v26.10.18/azsim-burn/GAP-AZB20-1-PLAN.md` Option A —
  "mount, don't declare out of scope", ~50 lines, 3 edits, zero StoreTable
  additions (Store.init idempotent, store.ex:29-43):
  1. `lib/smalt/plane/control_supervisor.ex` — start `Smalt.Store` in the
     control subtree when `:data` not selected (closes ARM 500s cell 2 + KV
     503 RouteNotReady cell 5).
  2. `lib/smalt/arm_gateway/router.ex` — `use Plug.ErrorHandler` +
     crash-path header plug stashing `arm_request_id` in `conn.private`
     (closes cell 1: 34 header-audit violations).
  3. `lib/smalt/arm_gateway/router.ex` — `post
     "/providers/Microsoft.ResourceGraph/resources"` delegating to
     `Smalt.DataPlane.ResourceGraph.query/3` (closes cell 3: probe expects
     400 shape, currently catch-all 404).
- Do NOT declare control-plane 500s out of scope — the plan's alternative was
  explicitly not recommended (weakens the parity claim; the mount is
  idempotent and cheap).
- Close condition: `MIX_BUILD_ROOT=_build-ft-az20 just azsim-sdk` — cell 2 →
  404→pass, cell 3 → 400-shape pass, keyvault+secrets cell 5 → pass, header
  audit → 0 violations; regression `mix test test/data_plane/ test/arm/
  test/wire/ test/azsim/` green; GAP-AZB20 rows flip receipt-gated.

## WO-4 — azb-18 cgroup soak: mount gaps + memory ceiling + defaults

- Status-2026-10-19: **fixes LANDED** — read-only `../ggen_igniter` mount +
  `SMALT_SOAK_MEM_LIMIT=4g` + persisted env-overridable defaults; the soak
  run itself (gate exit 0, derived ALIVE) remains open.
- Standing: **PARTIAL_ALIVE / BLOCKED[unledgered-failure-faces +
  harness-mount-gap]**. Evidence:
  `docs/jira/v26.10.18/receipts/azb-18-cgroup-soak.md` — both soak cycles
  refused by the gate (`STANDING_REFUSED`, 4x UNHANDLED_EXIT rows); dominant
  face is a harness mount-surface gap (`.ggen_igniter/receipts` absent in the
  container); memory diagnosis: `SMALT_SOAK_MEM_LIMIT=2g` insufficient for
  2.0-CPU planes.
- Fixes:
  1. Mount `../ggen_igniter` into the soak harness **read-only** (close the
     harness-mount gap that produced the UNHANDLED_EXIT rows).
  2. Raise `SMALT_SOAK_MEM_LIMIT` to **4g** for the 2.0-CPU planes or stagger
     the compile phase (receipt's own remediation line).
  3. Persist the `SMALT_SOAK_MEM_LIMIT` / `SMALT_SOAK_PIDS_LIMIT`
     env-overridable defaults in the soak harness (currently session-set).
- Close condition: cgroup soak gate exits 0 with derived standing ALIVE (all
  plane rows clean) per the fixed
  `scripts/validate_burn.py` (per `docs/jira/v26.10.18/receipts/i29-validator-standing-fix.md`
  — validator derives standing from plane rows, caps non-clean at
  PARTIAL_ALIVE, exits non-zero).

## WO-5 — Isolation runtime5 quiet-window rerun

- Status-2026-10-19: **still OPEN** — quiet-window rerun
  (`just quiet-check` precondition) pending; falsifier not yet landed.
- Standing: **PARTIAL_ALIVE — quiet-run falsifier OPEN**. Evidence:
  `docs/jira/v26.10.18/receipts/i29-isolation-runtime5.md` — machine load
  22–28 during the run; residual is load-shaped, not behavior-shaped.
- Fix: re-run `python3 scripts/isolation_court.py --runtime-only` under
  `just quiesce` discipline (quiet window; `just quiet-check` precondition per
  the receipt-context law).
- Close condition: quiet-window run counts 0 (falsifier lands), then flip the
  register row. Deadline-path typed-expiry note in the same receipt
  (§"settle_snapshot/2 deadline path silent") is flagged for the owning lane —
  carry it as a secondary item if the owning lane does not close it.

## WO-6 — Queue Storage: peek/clear comps out-of-G1-face

- Status-2026-10-19: **LANDED** — peek-messages + clear-messages comps
  implemented with red-before/green-after witness (engine + wire green).
- Standing: **OPEN (deliberately deferred, not a defect)**. Evidence:
  `docs/jira/v26.10.18/receipts/i29-g1-land.md` — "Peek/clear-message comps
  are NOT in the G1 face (scoping doc section 2 lists put/get/update/delete +
  lifecycle only). No GAP token minted." Scoping:
  `docs/jira/v26.10.18/azsim-burn/G1-QUEUE-STORAGE-SCOPING.md`.
- Work: implement peek-messages + clear-messages REST comps against the
  existing `lib/smalt/data_plane/queue_storage.ex` engine + egress_router
  `queue_storage_plane` arm; percent-encoded queue names stay out of face per
  the R154 decode-aware precedent noted in the land receipt.
- Close condition: engine + wire tests for both comps green (follow the
  i29-g1-land.md engine 11/0 + wire 26/0 pattern); no GAP token until/unless a
  parity defect vs real Azure semantics is witnessed.

---

## WO-7 — Reset inventory + census (pre-deletion ground truth) — `07-clean-room-reset.md`

- Status-2026-10-19: **LANDED** — `receipts/v261019-07-reset-inventory.md`
  on disk; manifest 303 rows; lifts precede `64f6099`. B8 classification
  folded into WO-15's classes file.
- Standing: **DONE (lifts + manifest)** at the deletion window. Lifts landed
  in `docs/jira/v26.10.19/lifts/` (`ts-run.mjs`, `conftest.py`,
  `assert_eventually-reference.exs`) BEFORE deletion, per the blocking-first
  law; the 303-path manifest is
  `docs/jira/v26.10.19/receipts/reset-delete-manifest.txt` (303 lines).
- Evidence: `receipts/reset-delete-manifest.txt`; lift provenance in
  `07-clean-room-reset.md` §0 (ts-run.mjs boot/poll/teardown/exit-contract
  machinery + conftest session protocol, R177b marker guard, loud-skip).
- Close condition: MET — manifest exists at 303 rows; lifts precede the
  deletion commit `64f6099`. Residual: the B8 sleep-census classification of
  the deleted sites folds into WO-15's classes file.
- Priority: **P0** — DONE; downstream denominator.

## WO-8 — verification/ts: external official-SDK suite (5 workflows), TypeScript — `08-verification-ts.md`

- Status-2026-10-19: **LANDED (PY-GREEN/TS-PARTIAL family per FINAL.md
  §7)** — suite landed with per-workflow receipts
  (`receipts/v261019-08-ts-external-suite.md`); 6 honest emulator
  FAILs carried as KD candidates (FINAL.md §7 item 1).
- Standing: **NEW — landing now** (sibling suites lane; `verification/` not
  yet on disk at materialization).
- Evidence: lifts (`lifts/ts-run.mjs`); design in `08-verification-ts.md`
  (harness/{substrate,credential,poll,assert,enum}.ts, wf1–wf5, exit contract
  0/1/2/3/124, no @azure/eventgrid — KD-101).
- Close conditions (exact commands):
  - `cd verification/ts && npm ci && node run.mjs` — exit contract 0/1/2/3/124
    honored; green x2 at the same SHA;
  - every WO-7 MOVES-TO-TS census row witnesses green in the new suite;
  - non-duplication / portable-target / sleep-gate (TS scan root) all exit 0
    (WO-15 gates);
  - per-workflow receipts land in `docs/jira/v26.10.19/receipts/` with real
    output tails.
- Priority: **P0** — half of the WO-11 parity evidence.

## WO-9 — verification/py: external official-SDK suite (5 workflows), Python mirror — `09-verification-py.md`

- Status-2026-10-19: **LANDED — PY-GREEN** —
  `receipts/v261019-09-py-external-suite.md`; exit contract honored.
- Standing: **NEW — landing now** (sibling suites lane).
- Evidence: lifts (`lifts/conftest.py`); design in `09-verification-py.md`
  (lifted conftest: lazy session fixtures, reuse-else-boot, R177b identity
  guard; azure deps as pyproject optional-extra; native-exception table).
- Close conditions (exact commands):
  - `cd verification/py && ./run.sh` — exit contract 0/1/2/3 honored; green
    x2 at the same SHA as the TS leg;
  - every WO-7 MOVES-TO-PY census row witnesses green;
  - non-duplication / portable-target / sleep-gate (PY scan root) all exit 0;
  - per-workflow receipts with real output tails.
- Priority: **P0** — other half of the WO-11 parity evidence.

## WO-10 — Residual internal Elixir tier: fresh `test/internal/` (5 files + census guard) — `10-residual-internal-tier.md`

- Status-2026-10-19: **LANDED — residual tier ALIVE** —
  `receipts/v261019-10-residual-elixir-tier.md`; 5-file tier + census
  guard green x2 (31 tests, 0 failures ×2 per FINAL.md §4).
- Standing: **IN FLIGHT** — `test/internal/` exists at materialization with
  `plane_blast_radius_test.exs`, `vm_zero_growth_test.exs`,
  `poll_helper.exs`; `wasm_nif_lifecycle_test.exs`,
  `dets_mirror_recovery_test.exs`, `internal_tier_census_test.exs` pending.
- Evidence: full design in `10-residual-internal-tier.md` (5 files
  re-derived from lib ground truth with provenance comments, zero copied
  text; census guard = the Non-Duplication ratchet).
- Close conditions (exact commands):
  - `mix test test/internal/` green x2, distinct seeds, same SHA;
  - census guard gate exit 0 (exactly the 5 registered files, forbidden-token
    scan clean, observables allowlist enforced);
  - `python3 scripts/sleep_gate.py` exit 0 including `test/internal`.
- Priority: **P1** — sequenced after WO-8/WO-9, before the WO-11 backfill.

## WO-11 — Test-deletion gate (clean-room reset) — `11-test-deletion-gate.md`

- Status-2026-10-19: **LANDED** — deletion commit `64f6099`
  (`receipts/v261019-11-test-deletion-gate.md`); parity backfill
  (WO-8/9/10 receipts at one pinned SHA) remains the closing obligation.
- Standing: **LANDED — commit `64f6099`** (V261019-11: 303 tracked files,
  107k lines deleted; `git ls-files test/` == 1: `test/test_helper.exs`).
  Executed ahead of the TS/PY parity preconditions — the parity backfill
  (WO-8/9/10 receipts green at one pinned SHA) is a closing obligation of
  this window. Revertible by design: `git revert 64f6099`.
- Evidence: commit `64f6099`; manifest
  `receipts/reset-delete-manifest.txt`; receipt
  `receipts/v261019-11-test-deletion-gate.md` (skeleton — Standing UNKNOWN
  until the parity backfill receipts land).
- Close conditions (exact commands):
  - `git ls-files test/` == exactly the residual set (test_helper + 5
    internal files);
  - WO-8 AND WO-9 AND WO-10 receipts green at the SAME `git rev-parse HEAD`,
    echoed in `receipts/v261019-11-test-deletion-gate.md`;
  - `find test -name .venv -o -name node_modules` empty;
  - no live recipe references a deleted `test/` path (`just verify-all`
    resolves no missing path).
- Priority: **P0 (gated)** — keystone; backfill owes the evidence.

## WO-12 — Court-x2 close: 11-stage court, two greens at a pinned SHA — `12-court-x2-close.md`

- Status-2026-10-19: **court-x2 IN FLIGHT** —
  `receipts/v261019-12-court-x2-close.md` records the court; census-court
  blockers cleared (77a4041 watchdog, c9b0bf1 monitor scope, 81a7a29
  binary removal per FINAL.md §7 item 4); landing pair pending.
- Standing: **TYPED-RED carried** from v26.10.18
  (`docs/jira/v26.10.18/receipts/azb-23-court-x2.md` +
  `i29-court-x2-final.md`); BLOCKED until the reset ladder integrates.
- Evidence: 11-stage table in `12-court-x2-close.md` (doctor → residual mix
  test → sdk-ts-court → sdk-py-court → tf-smoke → bench-check →
  mutation-court → census → invariant-gates → naming-sweep → sleep-gate-sdk);
  exit contracts preserved per stage.
- Close conditions (exact commands):
  - `just quiet-check` exit 0, then `just court-x2` exit 0 on BOTH legs at
    the pinned SHA;
  - `python3 scripts/isolation_court.py --runtime-only` counts 0;
  - release receipt minted per `azsim-burn/TICKETS.md`.
- Priority: **P1** — release gate; runs the post-reset tree.

## WO-13 — Identity plane: RS256 signing key + real-AAD discovery surface — `13-identity-rs256.md`

- Status-2026-10-19: **LANDED — identity ALIVE** —
  `receipts/v261019-13-identity-rs256.md`; official-SDK witness landed;
  KD-99 + KD-100 flipped CLOSED-SIMULATED via `scripts/kd_flip.py
  --apply` (FINAL.md §5).
- Standing: **IN FLIGHT** — `lib/smalt/auth/sts_key.ex` on disk (untracked),
  `lib/smalt/arm_gateway/router.ex` + `lib/smalt/auth/bearer.ex` modified.
  Technical annex: wave-3 draft (verified anchors, StsKey API,
  env-PEM-first, hs256_dev escape, cross-mode refuse, JWKS route,
  `/common/discovery/instance` metadata-aliases form, workspace
  SmaltTokenCredential deletion, C6 rows 7/14/17, KD-15/94 re-runs).
- Evidence: `13-identity-rs256.md`; C6_OAUTH_OIDC.md rows 7/14/17 flips;
  KD-99/KD-100 close via `scripts/kd_flip.py --apply` (receipt-gated).
- Close conditions (exact commands):
  - whole-WO acceptance: `ClientSecretCredential` + `@azure/arm-resources`
    → 200 with ZERO custom code, both TS and PY suites;
  - `Node crypto.verify('sha256', digest, pub, sig) == true` on the probe
    flow; JWKS fetch → verify roundtrip green both languages, same SHA;
  - KD-15/KD-94 fences re-run green (alg-agnostic);
  - KD-99/KD-100 flipped CLOSED-SIMULATED, receipt mtime > shim mtime.
- Priority: **P1** — unblocks the official-identity legs of WO-8/WO-9.

## WO-14 — Substrate boot library: substrate_boot.sh + substrate-ctl — `14-substrate-boot-library.md`

- Status-2026-10-19: **LANDED — boot library ALIVE** —
  `receipts/v261019-14-boot-library.md`; fd-9 law + wrappers +
  starvation shim court consumed by the WO-8/WO-9 harnesses.
- Standing: **IN FLIGHT** — `scripts/lib/substrate_boot.sh` on disk
  (untracked, sibling lane).
- Evidence: `14-substrate-boot-library.md` (fd-9 law + `9>&-` spawn assert,
  boot markers, formula blocks `vN = 39700+10N..+5`, tree-aware orphans,
  250ms bounded poll; mjs/py wrappers; starvation shim court).
- Close conditions (exact commands):
  - `substrate-ctl up && substrate-ctl verify` → exit 0;
  - `substrate-ctl down` leaves zero listeners and zero lock holders;
  - starvation falsifier: 8-lane collision storm, `lsof` fd-9 leak proof,
    >=1 held-port refusal witnessed;
  - shim court `scripts/shim_court/boot_library_court.sh` AFTER-leg flips
    (non-vacuity).
- Priority: **P1** — consumed by WO-8/WO-9 harnesses.

## WO-15 — Verification gates: non-duplication R1/R2/R3, portable-target whitelist, sleep-gate TS/PY — `15-verification-gates.md`

- Status-2026-10-19: **LANDED — gates ALIVE** —
  `receipts/v261019-15-verification-gates.md`; non-duplication +
  portable-target + sleep-gate TS/PY scopes green; acceptance machine
  G1/G3/G4 PASS (FINAL.md §3).
- Standing: **IN FLIGHT** — `scripts/non_duplication_gate.py` +
  `scripts/non_duplication_classes.json` + `scripts/portable_target_gate.py`
  on disk (untracked, sibling gates lane); sleep_gate TS/PY extension and
  the shim courts pending.
- Evidence: `15-verification-gates.md` (R1 wrapper purity / R2 delegated-
  primitive census / R3 receipt-evidence law; portable-target whitelist:
  SMALT_AZURE_*/AZURE_* env only; sleep TS/PY scopes + 4 new shim-court
  legs; `justfile.d/30-verification.just` — note: the wave-3 slot correction
  puts the verification module at `32-verification.just` if slot 30 is taken
  by burn).
- Close conditions (exact commands):
  - all three gates exit 0 clean and exit 1 on their shim fixtures;
  - `just shim-court non_duplication` / `portable_target` AFTER-legs flip;
  - sleep-gate-sdk leg green in the 11-stage court (WO-12 stage 11).
- Priority: **P1** — the measuring stick; lands before court rewiring (WO-12).

## WO-16 — Milestone wrap: generated docs, FINAL.md, wrap sequence — `16-milestone-wrap.md`

- Status-2026-10-19: **wrap IN FLIGHT** — FINAL.md on disk with census
  arithmetic (leaf-weighted 90.8% ≥ 80%, `receipts/v261019-rc-rewrite-census.md`);
  remaining: court-x2 landing pair + publish-dry (G5 blockers).
- Standing: **NEW — terminal WO** (runs last; nothing lands after it).
- Evidence: `16-milestone-wrap.md` (generated-docs regeneration law —
  RECEIPTS/SDK_MATRIX/BENCH regenerated never hand-edited; KD/GAP settle;
  post-commit re-witness discipline; publish-dry; FINAL.md with handoff
  pointer).
- Close conditions (exact commands):
  - `just receipt-index && python3 scripts/sdk_coverage.py && just bench-report`
    all exit 0, idempotent on second run;
  - `just court-x2` two greens at the pinned SHA post-commit;
  - `just publish-dry` pre+post-commit exit 0;
  - `just docs-dod-check` exit 0 with FINAL.md on disk;
  - FINAL.md census section: `(before-after)/before >= 0.80` from the
    rewrite-census receipt arithmetic.
- Priority: **P0 (terminal)**.

---

## Cross-cutting standing constraints (WO-7..16)

- **Non-duplication**: every assertion surface is owned exactly once across
  TS / PY / internal-elixir, per the WO-7 disposition; the
  `scripts/non_duplication_gate.py` gate is fail-closed and runs in every
  close condition that names it.
- **Portable Azure Target**: official SDKs only; endpoints resolve from
  `SMALT_AZURE_*`/`AZURE_*` env with repo-relative defaults;
  `scripts/portable_target_gate.py` fails on absolute-home literals.
- **Zero-sleep**: SDK pollers/bounded polls only; `scripts/sleep_gate.py`
  scan roots cover `lib/`, `verification/{ts,py}`, and `test/internal`
  (TS/PY extension = WO-15); honest red is the deliverable, silence is not.
- **Volume ratchet**: >=80% test-volume reduction measured per tier against
  the pre-reset SHA `4fd2ff2` (`receipts/v261019-rc-rewrite-census.md`).
