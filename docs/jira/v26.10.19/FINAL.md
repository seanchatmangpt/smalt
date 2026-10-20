# FINAL.md — v26.10.19 window wrap

- **Date**: 2026-10-19
- **Subject**: smalt @ HEAD `28ceff9` (main; version 26.10.19; capability
  wave-3 promoted)
- **Context**: solo(documentation wrap; counts re-derived on this tree)
- **Standing of this document**: CENSUS — every claim cites a receipt on disk.
  The court-x2 verdict is **ALIVE — three consecutive promotion pairs all
  green: #3 (wave-1 @ `17fcbb6`), #4 (wave-2 @ `61e0543`), #5 (wave-3 @
  `5666ae2`, latest, at the wave-3 HEAD; G5 receipt §"court-x2 #5" carries
  all sections: COURT-Z1/Z2 rc=0)** — `receipts/v261019-12-court-x2-close.md`.
  **Published: pushed `4fd2ff2..dc40e84 main` 2026-10-19; publish-dry 4/4
  PASS (post-wrap; re-run owed at the wave-3 HEAD before the next publish).**

## 1. Landing

- **Landing commit**: `cf8b1b8` ("fix(hygiene): naming-sweep zero
  violations…"), 21 local commits ahead of origin/main; the deletion anchor
  is `64f6099` (303 files / 107,644 lines removed), the parity anchor is
  `1aca688` (AZB-25a/b: blobServices synthesis, sync storage DELETE).
- **Push**: NOT executed — merge-only law, no explicit push request; the 21
  commits are local on main.

## 2. Gate verdicts

- **court-x2**: CLOSED — see G5 receipt
  `receipts/v261019-12-court-x2-close.md` (Standing ALIVE): two consecutive
  `just court` runs, both exit 0, HEAD `81a7a29` unchanged across both run
  windows; invariant-gates 6/6 + naming-sweep 0/49 + non-duplication +
  portable-target all PASS in both verdict tails.
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

v26.10.20 NOT yet planned. Open items carried, re-derived at the wave-3
promotion HEAD `28ceff9` (2026-10-20):

**Three-wave receipt ledger**: 60 lanes across 3 capability waves; court-x2
promotion pairs #3/#4/#5 all green (wave-1 `17fcbb6`, wave-2 `61e0543`,
wave-3 `5666ae2` — G5 receipt sections "court-x2 #3/#4/#5",
`receipts/v261019-12-court-x2-close.md`); 9 KD flips via
`scripts/kd_flip.py --apply` (KD-99/KD-100 window flips; KD-104/105/108
flipped at `8e7c3b9`; KD-117 flip landed `e6430a9`; remainder per wave
receipts `receipts/v261019-capability-wave{1,2,3}.md`); capabilities 41 →
46 types (46 verified on disk in `docs/capabilities.json` at `28ceff9`,
`identity.semanticEpoch=26.10.19`).

1. **KD-119 (vault RS256 double-hash) — single-hash fix; w4 lane in
   flight.** Row OPEN (witnessed, no fix:
   `receipts/kd119-kv-rs256-double-hash-tbd.md`, wf4-py falsifier: hazmat
   verify digest=true message=false). Close = sign consumes the pre-hashed
   digest as-is; witness must postdate the fix's KD-COVERS token.
2. **KD-110 (throttle default `:infinity`) — profile-default decision
   pending.** Limiter defect (boot-eval never bridging
   `SMALT_ARM_RATE_LIMIT`) found + fixed this window
   (`receipts/kd110-throttling-infinity-tbd.md`: burst witness 0/60
   throttled on the broken path, green with lifted eval); the row itself
   stays OPEN — next window decides the default profile vs `:infinity`.
3. **Registry-surfacing gaps** (`/tmp/w3-registry/GAPS.md`, wave-1/2
   audit): (a) 5 ARM-served types with zero `registry.ex` entries —
   `Microsoft.Authorization/locks` (router 7 hits), `policyExemptions`
   (9), `policySetDefinitions` (4), `policyRemediations` (13), SB
   `topics/subscriptions/rules` (16) — a `Canonical.write()` regen adds
   nothing until `registry.ex` gains them; (b) new `lib/` modules with no
   inventory grounding: `data_plane/certificates.ex` (KD-104),
   `appconfig_snapshots.ex`, `kv_pss.ex` (KD-105), `policy.ex`;
   (c) `sdk_coverage.py` CAP_CELLS stale (7, actual 13) and wf6 has 6
   dangling cap ids in `workflows.json`; wf7 has no workflows.json entry
   and no sdk_coverage refs (probes on disk:
   `verification/ts/diagnostics.probe.mjs`,
   `verification/py/test_wf6_newcaps.py`, `test_wf7_diagnostics.py`);
   (d) regen order is registry.ex → capabilities.json →
   CAP_CELLS/workflows.json → `Canonical.write()`.
4. **Wave-2 wire defects — verification status**
   (`receipts/v261019-capability-wave2.md`, "Registrar-input summary",
   re-read at `e6430a9`): (a) **KD-118 TS framing** — TS SDK
   `scheduleMessages` still 400 QUEUE_REQUIRED (management_rpc.ex resolves
   neither body `queue` nor associated-link-name); the wave-3 integration
   commit claims "KD-118 TS framing verified" — contradicted by the probe;
   PY leg passes only because the PY harness sends body `queue`.
   (b) **blob RFC-1123** — NOT flipped: nil-`snapshots` clause crash,
   List Blobs still 500 (`blob_storage.ex:1627` via `render_blob/4:1548`);
   snapshot CREATE and PY/TS decoration legs pass around the crash.
   (c) **KD-112 exemptionCategory** — REGRESSED in-window: cased RG-scope
   PUT 201 (run 1, pre-wave-3) → 400 (runs 2-3 at wave-3 landed HEAD);
   PY wf6 chain passes on the lower-case path only. (d) FLIPPED this
   window: KD-117 recover leg; PY wf6 remediation cell. **wf7
   table-stats**: honest skip — no route for `GET
   workspaces/:id/tables` in `egress_router.ex` or
   `arm_gateway/router.ex` (grep, no matches).
5. **table-stats ARM family** — Sentinel/Log Analytics workspace-tables
   GET family unrouted (`receipts/v261019-capability-wave2.md` wf7 leg,
   SKIPPED [1] with owning-surface reason); open as surface growth for
   the next window (registrar-gated mint if witnessed as a divergence).

## 8. Pointers

[RECEIPTS.md](RECEIPTS.md) ·
[v26.10.18 FINAL.md](../v26.10.18/FINAL.md) ·
[KNOWN_DIVERGENCES.md](../v26.10.14/KNOWN_DIVERGENCES.md) ·
[SDK_MATRIX.md](SDK_MATRIX.md) ·
[RISK_REGISTER.md](RISK_REGISTER.md) ·
[ACCEPTANCE.md](ACCEPTANCE.md) ·
[ENVELOPE_RESET.md](ENVELOPE_RESET.md)
