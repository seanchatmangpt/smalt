# AZB-23/24 Terminal Gate Preflight

- **Date**: 2026-10-18
- **Subject**: /Users/sac/smalt @ `e916d767c34e916a3444d214e5eada82af0abdbd` (branch main)
- **Context**: solo(read-only census; no execution, no git state mutations)
- **Ticket specs**: `docs/jira/v26.10.18/azsim-burn/TICKETS.md` (AZB-23, AZB-24)
- **Standing of this document**: CENSUS — preconditions computed from receipts on disk, not asserted.

## AZB-23 — court-x2 on frozen quiescent tree

### A. Quiet machine

| # | Precondition | Status | Evidence | Note |
|---|---|---|---|---|
| A1 | Quiet machine — colima stop runbook | PENDING | `docs/jira/v26.10.18/receipts/i29-colima-stop-runbook.md` (TYPED_RECOMMENDATION, 2026-10-18) | Full stop sequence computed (12 containers, all restartable, volumes survive stop/start); sequence not yet executed. Order is load-bearing vs AZB-18 container leg. |
| A2 | Quiet machine — port census | PENDING | `docs/jira/v26.10.18/receipts/i29-port-census.md` (PARTIAL_ALIVE: census executed; ports BLOCKED by live colima) | colima ssh mux PID 61023 holds 9443/8443/5672. Re-census required after the stop sequence; current receipt predates quiescence. |
| A3 | `just quiesce` → 0 foreign BEAMs/listeners | PENDING | recipe exists (`justfile.d/24-quiesce.just`); no post-quiescence receipt | Runs only after A1/A2. |

### B. Frozen tree

| # | Precondition | Status | Evidence | Note |
|---|---|--- |---|---|
| B1 | `git status --porcelain` empty | BLOCKED | live `git status --porcelain` 2026-10-18 (this preflight) — 10 dirty files | All 10 are Lane C (test-env hygiene sweep, `SmaltTest.Env.put_restored` refactor per `i29-checkpoint3.md`) — a single in-flight lane; its landing (one `test(env)` commit + gate order per checkpoint3) clears B1. |
| B2 | HEAD == AZB-22 subject SHA | BLOCKED | HEAD `e916d76`; AZB-22 ring init SHA `3688e449` (`azb-22-burn-ring.md` line 7) | Subject has moved 6+ commits past ring init; AZB-22 standing **RED** (ZOMBIE_BEAM, jidoka line-stop) per `azb-22-burn-ring.md`. Zombie repair witnessed (`azb-22b-zombie-fix.md`, `azb-22b-zombie-verify.md` PASS) but the ring itself has NOT been re-run — `just burn-ring` re-run at a pinned SHA is the close condition. |
| B3 | AZB-22 receipt present for this SHA | BLOCKED | `receipts/azb-22-burn-ring.md` (RED at ring SHAs; `azb-22b-zombie-verify.md` PASS post-cycle) | Gate condition is "AZB-22 receipt present for this SHA" — no such receipt exists for `e916d76`. Close by re-running `just burn-ring` (zombie fix landed via azb-22b, machinery witnessed green where run). |

### C. Two-green court

| # | Precondition | Status | Positive evidence | Negative evidence |
|---|---|---|---|---|
| C1 | court-x2 run1 GREEN, run2 GREEN, same SHA | PENDING | rehearsal-only: `i29-court-dry1/2/3.md`; dry3 leg at `1eb89df` — run1 GREEN (2733 tests / 0 failures, 218.4s) | runs 2 and 3 of dry3 had 3 / 2 LOAD-class failures (F61 Topology `:econnrefused` class, `test/azsim/topology_test.exs:82/:141`); full two-green at HEAD `e916d76` not yet witnessed; no `rNNN-court-x2-azsim-two-green.md` receipt exists (spec'd name in TICKETS.md). |

### D. Gates latest verdicts

| Gate | Status | Receipt | Verdict as-of |
|---|---|---|--- |---|
| naming-sweep | READY | `i29-naming-fix.md` (PASS) + commit `1339f3f8` "naming pin 262->269 + injectors allowlist entry — sweep PASS 0/47" | 0/47 at HEAD-adjacent SHA |
| sleep-gate | READY | `i28-sleep-gate-full.md` (PASS, gate+shim court) | 2026-10-18 |
| leak-court | READY | `i29-leak-remediation.md` (PASS: 17 files/39 mutations → 0; positive fixtures still refuse) | 0 offenders |
| invariant-gates | PENDING | `i29-gates-postfix.md` (invariant PASS, but naming FAIL 76 then; naming since fixed) | stale — re-run at HEAD after Lane C lands |
| publish-dry | PENDING | `i29-publish-dry-fresh.md` (PARTIAL_ALIVE @ `0009df3`, publish gates green, artifact-freshness half-verified) | stale — pre-HEAD, re-run at release SHA |
| docs-dod-check | PENDING | recipe `justfile.d/11-docs-dod.just` exists; no fresh receipt | run at release SHA |

## AZB-24 — release receipt, standing, retirement

| # | Step | Status | Evidence/Tool | Note |
|---|---|---|---|---|
| V1 | Release receipt mint | READY | `scripts/mint_release_receipt.py` (exists on disk) | — |
| V2 | Version bump (mix.exs `@version` → 26.10.18, workspace/package.json, CHANGELOG.md) | PENDING | spec'd in TICKETS.md AZB-24 | strictly post-AZB-23; semanticEpoch regenerated via projection, not hand-edited |
| V3 | FINAL.md | PENDING | no `FINAL.md` in `docs/jira/v26.10.18/` (window listing, this preflight) | written at wrap |
| V4 | Push / NEXT_WINDOW.md | PENDING | `i29-push-readiness2.md` (read-only readiness audit) | — |
| V5 | receipt_index 24/24 + project.py --check | PENDING | `scripts/receipt_index.py` + `~/.zcode/dfcm/project.py --check` | anti-vacuity: delete-one-receipt court spec'd in TICKETS.md |

## Amendment 2026-10-19 — B2/B3 carried to v26.10.19 as TYPED-OPEN

Context: solo(...). Basis: `docs/jira/v26.10.18/receipts/azb-22b-zombie-fix.md`
section "Ring boot re-judge retry — BLOCKED again" (third infrastructure
strike: colima disk 100% / 0B reclaimable without sabotaging concurrent
lanes, sustained concurrent build contention). Per the v26.10.17
typed-RED honest-close precedent:

- **B2/B3 (AZB-22 ring subject binding) carry to v26.10.19 as TYPED-OPEN.**
  Evidence: zombie FACE is closed (boot-burn 12/12 CLEAN,
  `azb-22b-zombie-verify.md` ALIVE) — the full ring re-judge was deferred on
  un-leased concurrent image builds (3 strikes, embedded in
  azb-22b-zombie-fix.md).
- **AZB-23 proceeds without B2/B3**, per the honest-close precedent.
- **Ring re-run is the first v26.10.19 work order**, alongside G1–G4.
- **Recommended fix (also carried)**: an image-build lease (flock, same
  pattern as `scripts/substrate.sh`) so concurrent docker builds cannot
  strike a ring re-judge again.

## Blocking chain (shortest path to gate)

1. Lane C lands its `test(env)` commit (10 files) → B1 clears; gate order per `i29-checkpoint3.md`: mix test → test-budget (reseed owns the 4th dirty file) → sleep-gate → docs-dod-check.
2. Pin a SHA, re-run `just burn-ring` → clears B2/B3 and un-REDs AZB-22.
3. Execute the colima stop sequence (i29-colima-stop-runbook.md) → re-census → `just quiesce` → A1–A3.
4. court-x2 at the pinned SHA → `rNNN-court-x2-azself-two-green.md` (spec name from TICKETS.md: `rNNN-court-x2-azsim-two-green.md`) → C1.
5. Re-run invariant-gates + publish-dry + docs-dod-check at release SHA → table D.
6. AZB-24 V1–V5 in spec order.
