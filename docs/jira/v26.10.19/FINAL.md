# FINAL.md — v26.10.19 window wrap

- **Date**: 2026-10-19 (refreshed 2026-10-20, ERRC docs lane)
- **Subject**: smalt @ HEAD `bab1949` (main; version 26.10.19; capability
  wave-4 promoted)
- **Context**: solo(documentation wrap; counts re-derived on this tree)
- **Standing of this document**: CENSUS — every claim cites a receipt on disk.
  The court-x2 verdict is **ALIVE — four consecutive promotion pairs all
  green: #3 (wave-1 @ `17fcbb6`), #4 (wave-2 @ `61e0543`; COURT-Y1/Y2 rc=0),
  #5 (wave-3 @ `5666ae2`; COURT-Z1/Z2 rc=0), #6 (wave-4 @ `60823ed`;
  COURT-V1/V2 rc=0, latest — G5 receipt §"court-x2 #6" carries the section:
  `COURT-V1 rc=0 — [COURT] Full gate passed.` / `COURT-V2 rc=0 — [COURT]
  Full gate passed.`)** — `receipts/v261019-12-court-x2-close.md`. Promotion
  commit `bab1949` carries the release receipt + BLAKE3 re-mint #6.
  **publish-dry: PASS 4/4 witnessed at an earlier release commit (session
  rc=0); re-run owed at `bab1949` before the next publish** (carried wrap
  obligation, `../v26.10.20/PLANNING.md` WO-5).

## 1. Landing

- **Landing commit**: `cf8b1b8` ("fix(hygiene): naming-sweep zero
  violations…"), 21 local commits ahead of origin/main; the deletion anchor
  is `64f6099` (303 files / 107,644 lines removed), the parity anchor is
  `1aca688` (AZB-25a/b: blobServices synthesis, sync storage DELETE).
- **Push**: NOT executed — merge-only law, no explicit push request; the 21
  commits are local on main.

## 2. Gate verdicts

- **court-x2**: CLOSED — see G5 receipt
  `receipts/v261019-12-court-x2-close.md` (Standing ALIVE): six pairs run
  this window, the latest four are the promotion pairs #3/#4/#5/#6, all
  two-green at a single unchanged SHA each (pair #6 at wave-4 HEAD
  `60823ed`: invariant-gates 6/6 + naming-sweep 0/49 + non-duplication +
  portable-target PASS in both verdict tails).
- **publish-dry**: **PASS 4/4** (hex.build tarball, inner-tar keys grep,
  leak grep, ERROR_CODES identity) — run at the release commit; output
  witnessed in session (rc=0).

## 3. Post-commit gates (7-gate table, surface at HEAD `81a7a29`)

| # | Gate | Command | Verdict | Receipt |
|---|---|---|---|---|
| 1 | court-x2 | `just court-x2` | PASS ×2 (see G5 receipt) | `receipts/v261019-12-court-x2-close.md` |
| 2 | publish-dry | `just publish-dry` | PASS 4/4 | session rc=0 |
| 3 | docs-dod-check | `just docs-dod-check` | PASS | `receipts/v261019-envelope-automation.md` leg |
| 4 | invariant-gates | `python3 scripts/invariant_gates.py` | PASS (6/6) | `receipts/v261019-court-census.md` post-fix |
| 5 | naming-sweep | `bash scripts/naming_sweep.sh` | PASS (0/49) | inline session output |
| 6 | gen-error-codes | `python3 scripts/gen_error_codes.py --check` | PASS ×2 (146 rows, idempotent) | `receipts/08-servicebus-census.md` era |
| 7 | sdk-matrix | `python3 scripts/sdk_coverage.py` | PASS (exit 0, every cell pass-or-registered) | `sdk-results/wf*-*.md` ×10 |

Plus the **5-gate acceptance machine** (`python3
scripts/acceptance_gates.py`): G1 PASS, G3 PASS, G4 PASS; G2 (F1
revert-the-diff) typed-DEFERRED pending TS-suite green (6 honest emulator
divergences standing); G5 CLOSED on the court-x2 receipt (ALIVE).

## 4. Test-volume census (before → after; full receipt
`receipts/v261019-vol-census.md`)

| Metric | Before | After | Reduction | Target ≥80% |
|---|---|---|---|---|
| Tracked test files | 303 | 9 (enumerated fresh set — G1 PASS) | 99.7% | MET |
| ExUnit leaves | 2,763 (budgeted, manifest era) | 31 (executed: 31 tests, 0 failures ×2) | 98.9% | MET |
| node:test leaves | 97 (grep census) | 97 + suites (grep census) | 0% — external surface was never the deletion target | scoped out |
| pytest items | 156 (grep) | 150 collected | 3.8% | scoped out |
| **Leaf-weighted** | 3,016 | 278 | **90.8%** | **MET** |

Honest caveat: the ≥80% clears on the ExUnit reset dominating the leaf
population; the pytest/node:test surfaces were never part of the deleted
tree and are carried, not reduced.

## 5. Counts (re-derived on this tree)

- Receipt files: 39 in `docs/jira/v26.10.19/receipts/` (indexed by
  `scripts/receipt_index.py`, rc 0)
- SUSPECT: 12 named in RECEIPTS.md (skeletons pending their executing runs —
  every one names its pending command)
- KD rows: 112 unique ids (KD-01..KD-113, gaps = split rows), 94 OPEN /
  closed-class remainder; **KD-99 + KD-100 flipped CLOSED-SIMULATED this
  window via `scripts/kd_flip.py --apply`** (official-SDK witness)
- Bench results: `docs/jira/v26.10.19/bench/b2.jsonl` (4 rows, machine
  spec embedded)
- Standing mix: see RECEIPTS.md (ALIVE/PASS dominate the executed lanes;
  SUSPECT = named pending skeletons)

## 6. Publication gate

Signing-key rotation: unchanged (fin-21 lineage — coordinator decision
carried, not exercised this window).

## 7. Planning handoff to next window

**Four-wave receipt ledger** (re-derived 2026-10-20 at `bab1949`):

- **Waves 1-4 all promoted.** Integration SHAs: wave-1 `17fcbb6`,
  wave-2 `61e0543`, wave-3 `5666ae2`, wave-4 `60823ed`; promotion commits
  with re-minted release receipts + BLAKE3 re-mints; court-x2 promotion
  pairs **#3/#4/#5/#6 all green** at their pinned SHAs (sections
  "court-x2 #3..#6" with embedded COURT-X/Y/Z/V rc=0 tails,
  `receipts/v261019-12-court-x2-close.md`; wave receipts
  `receipts/v261019-capability-wave{1,2,3}.md` + the wave-4 lane receipts
  `receipts/v261019-w4h-glossary-surface.md` and
  `../v26.10.20/receipts/w4e-sb-rules-arm.md`).
- **Lane census**: 60+ named lanes across waves 1-3
  (`../v26.10.20/PLANNING.md` "Lanes: 60+ … caps w1/w2/w3 lanes
  wNa..wNq") + 7 wave-4 lane leases on disk (`_build-lane-w4{a,d,e,f,g,h,i}`,
  same PLANNING.md) — 67+ lanes across 4 waves. (An "80 lanes" figure is
  NOT receipt-backed on disk; 67+ is the defensible count.)
- **KD flips this window: 11 rows** flipped CLOSED(-SIMULATED) with
  witness receipts under `docs/jira/v26.10.19/` — **KD-99, KD-100,
  KD-104, KD-105, KD-106, KD-108, KD-111, KD-113, KD-117, KD-118,
  KD-119** (canonical register
  `../v26.10.14/KNOWN_DIVERGENCES.md`, table = ground truth; register
  now carries 117 rows, **55 OPEN**). `scripts/kd_flip.py --apply` at
  wrap: FLIP-ELIGIBLE 0 (nothing pending except KD-110, see below).
- **Capabilities 41 → 46 types** — 46 entries on disk in
  `docs/capabilities.json`, `identity.semanticEpoch=26.10.19` (regen via
  `Canonical.write()` riders).
- **publish-dry: owed at `bab1949`** before the next publish (carried
  wrap obligation, `../v26.10.20/PLANNING.md` WO-5).

**Genuinely open, re-derived on this tree:**

1. **KD-114 / KD-115 / KD-116** — TS-suite divergence remainder (blob
   bearer-over-http channel; SB plain-queue receiver zero-delivery; SB
   session settle-shape). Rows OPEN with witnessed FAIL cells
   (`receipts/kd114-blob-bearer-http-tbd.md`,
   `receipts/kd115-sb-receiver-zero-delivery-tbd.md`,
   `receipts/kd116-sb-session-delivery-shape-tbd.md`); = v26.10.20
   WO-1 P0 (status PARTIAL in `../v26.10.20/PLANNING.md`).
2. **KD-110 (throttle default `:infinity`)** — row OPEN; shim landed
   (`SMALT_ARM_RATE_LIMIT` config token) but **FLIP-PENDING-WITNESS**:
   `scripts/kd_flip.py --apply` at wrap reports "no post-shim receipt
   newer than shim mtime (2026-10-20T06:00:20)". Needs a post-shim
   witness receipt (bounded default vs `:infinity` decision + falsifier:
   over-limit 429 + Retry-After, under-limit 2xx).
3. **KD-112 (policy initiatives/exemptions 404s)** — row OPEN
   (`receipts/kd112-arm-policy-initiatives-tbd.md`); the in-window
   exemptionCategory persistence work (wave-3) narrowed it but the
   initiative/exemption SDK surfaces remain open.
4. **Registry-surfacing gaps** — partially closed this window (registry
   46-type sync landed wave-3/4); residual: wf6 dangling cap ids in
   `workflows.json`, wf7 missing from `workflows.json`/sdk_coverage refs
   (probes on disk: `verification/ts/diagnostics.probe.mjs`,
   `verification/py/test_wf6_newcaps.py`, `test_wf7_diagnostics.py`).
   Regen order unchanged: registry.ex → capabilities.json →
   CAP_CELLS/workflows.json → `Canonical.write()`.
5. **Carried from v26.10.19 WOs, still OPEN in
   `../v26.10.20/PLANNING.md`**: WO-2 (F1 falsifier unblock, G2
   DEFERRED), WO-4 (secrets-sweep + envelope courts), WO-6
   (SOVEREIGN_MIDNIGHT G-register: G2 X-ARR mTLS, G3 EG DLQ spillover,
   G4 split-brain failover), WO-7 (isolation runtime5 quiet-window).
6. **publish-dry re-run at `bab1949`** (WO-5 tail; also gates G5
   typed-PENDING → closed receipt-gated).

**Handoff**: v26.10.20 window is OPEN and seeded —
`../v26.10.20/PLANNING.md` (WO table + sub-sketches KD-114..119) already
consumes this window's ledger; its court-x2/publish-dry close conditions
gate the next release receipt.

## 8. Pointers

[RECEIPTS.md](RECEIPTS.md) ·
[v26.10.18 FINAL.md](../v26.10.18/FINAL.md) ·
[KNOWN_DIVERGENCES.md](../v26.10.14/KNOWN_DIVERGENCES.md) ·
[SDK_MATRIX.md](SDK_MATRIX.md) ·
[RISK_REGISTER.md](RISK_REGISTER.md) ·
[ACCEPTANCE.md](ACCEPTANCE.md) ·
[ENVELOPE_RESET.md](ENVELOPE_RESET.md)
