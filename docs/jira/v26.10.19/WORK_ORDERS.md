# WORK_ORDERS

v26.10.19 open work orders — typed-open items carried from the v26.10.18 window
(`docs/jira/v26.10.18/FINAL.md`). Each item: evidence receipt + close condition.
Context: solo(...)

## WO-1 — Burn-ring re-run under flock image-build lease + SUBJECT_SHA build-arg fix

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
