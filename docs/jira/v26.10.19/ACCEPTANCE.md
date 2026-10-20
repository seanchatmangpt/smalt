# ACCEPTANCE — v26.10.19 reset

> Commands and paths below were verified against the PRE-deletion checkout
> (4fd2ff2), then RE-GROUNDED against the landed tree on 2026-10-19 (see
> "Verification status 2026-10-19" at the bottom). The reset landed: the
> residual internal tier, the external verification/{ts,py} suites, and the
> acceptance-gate machine (`scripts/acceptance_gates.py`) all exist on HEAD.

Machine-checkable definition of done for the whole reset. Every section is a command + expected outcome; no prose-only criteria. Status tags: `[EXISTS]` = path verified on disk today; `[TO-CREATE]` = artifact the reset lanes must land before this section can pass.

## 1. Deletion complete

Landed final state: `git ls-files test/` returns **exactly 9 entries** — the
5 recreated `test/internal/*` files + `test/internal/poll_helper.exs`, the
recreated `test/adaptive_health_test.exs`, `test/cluster/cluster_test.exs`,
`test/internal/wasm_nif_lifecycle_test.exs`, and `test/test_helper.exs`.
Untracked bulk gone. G1 PASS (`receipts/v261019-11-test-deletion-gate.md`).

```bash
# 1a. Tracked set is exactly the landed 9-file set   [LANDED — G1 PASS]
git ls-files test/
# expect (9 lines, sorted):
# test/adaptive_health_test.exs
# test/cluster/cluster_test.exs
# test/internal/{dets_mirror_recovery,internal_tier_census,plane_blast_radius,poll_helper,vm_zero_growth,wasm_nif_lifecycle}*
# test/test_helper.exs
git ls-files test/ | wc -l        # landed: 9
git ls-files test/ | grep -cv '^test/internal/\|^test/adaptive_health_test.exs$\|^test/cluster/\|^test/test_helper.exs$'   # expect: 0

# 1b. Untracked bulk gone   [checkable now and after]
find test/ -name .venv -o -name node_modules   # expect: empty (exit 0, no output)

# 1c. Working tree clean w.r.t. test/   [checkable now]
git status --porcelain test/     # expect: empty
```

Note: superseded — the deletion landed (`receipts/v261019-11-test-deletion-gate.md`, commit `cf8b1b8` era; clean-room manifest `receipts/reset-delete-manifest.txt`).

## 2. External suites alive — LANDED

`verification/ts` and `verification/py` landed with the five workflows each
(`test_wf1_governance.py`…`test_wf5_throttling.py`; ts: `census.test.cjs` +
`run-all.mjs` + `harness/`). `[EXISTS]` — receipts
`receipts/v261019-08-ts-external-suite.md` and
`receipts/v261019-09-py-external-suite.md` (both Standing: ALIVE).

```bash
# 2a. Structure
test -d verification/ts && test -d verification/py          # expect exit 0
for wf in 1 2 3 4 5; do
  test -d "verification/ts/wf$wf" && test -d "verification/py/wf$wf"   # expect 5x exit 0
done

# 2b. Court recipes with the 0/1/2/3 contract   [LANDED — justfile.d/32-verification.just]
just sdk-ts-court    # exit 0 pass / 1 probe fail / 2 substrate never up / 3 harness/env
just sdk-py-court    # same contract; inherits the 04-sdk-recipes conventions:
                     #   ts-run.mjs            0 pass / 1 fail / 2 substrate / 3 harness / 124 watchdog
                     #   run.sh (py lane)      0 pass / 1 fail / 2 substrate timeout / 3 lock failure
# Court SKIP semantics: exit 3 (harness/env) degrades to loud SKIP in `just court`;
# exits 0/1/2 stay hard verdicts (Justfile census precedent).

# 2c. Receipts land as per-wf sdk-results files   [LANDED]
ls docs/jira/v26.10.19/sdk-results/wf*-*.md    # expect ≥ 1 result per wf, per language (10 files; FINAL.md §3 gate 7)
```

Court recipes landed in `justfile.d/32-verification.just` (`sdk-ts-court` /
`sdk-py-court`, 0/1/2/3 contract).

## 3. Residual tier green

```bash
# 3a. Exactly the landed internal tier + census guard run   [LANDED]
mix test          # landed: 9 test files, 31 tests / 0 failures (×2, receipts v261019-10 + v261019-12)
# stronger form [LANDED: test/internal/internal_tier_census_test.exs]:
mix test test/internal/internal_tier_census_test.exs   # expect: green

# 3b. Count assertion — the census guard itself asserts the file set   [LANDED]
grep -c "test/internal" test/test_helper.exs >/dev/null    # expect: guard logic present
mix test test/internal/ | grep -E "^[0-9]+ tests"   # expect: all pass, 0 failures
```

The guard (a test that `git ls-files test/` == the landed 9-line set) landed as
`test/internal/internal_tier_census_test.exs` — Section 1 is self-enforcing
(receipt `receipts/v261019-10-residual-elixir-tier.md`).

## 4. Gates armed

Three fail-closed gates with shim non-vacuity courts, same shape as the existing `sleep-gate` / `scripts/shim_court/` pattern `[LANDED]` — `scripts/acceptance_gates.py` (driver, G1–G5), `scripts/non_duplication_gate.py` + `non_duplication_classes.json`, `scripts/portable_target_gate.py`, sleep-gate-sdk in `justfile.d/33-sleep-gate-ext.just`. Receipt: `receipts/v261019-15-verification-gates.md` (Standing: ALIVE).

```bash
# For gate in non-duplication, portable-target, sleep-gate-sdk:
just non-duplication    # exit 0 on clean tree
just portable-target    # exit 0 on clean tree
just sleep-gate-sdk     # exit 0 on clean tree

# Non-vacuity: each gate's shim court refuses the injected fixture
just non-duplication-court    # exit 0 = clean passed AND shim fixture refused
just portable-target-court    # same
just sleep-gate-sdk-court     # same  (verified precedent: scripts/shim_court/sleep_gate_court.sh)

# Negative control — each gate exits 1 on its shim fixture:
bash scripts/shim_court/<gate>_court.sh --inject   # expect exit 1 (fixture survives = vacuous gate)
```

Contract per `gates/common.py:9-13` (verified in the Justfile comment): a gate exits 0 only if the positive capture passes AND every negative fixture is refused.

`gates/` retains the invariant-gate drivers; the three new acceptance gates
landed in `scripts/` (`acceptance_gates.py`, `non_duplication_gate.py`,
`portable_target_gate.py`) — all three `[EXISTS]`, verified on HEAD.

## 5. Court green

`just court` = doctor + test-offline + test-wire post-reset = the residual tier (Section 3) + tf-plan-smoke + bench-check + mutation-court + census + invariant-gates + naming-sweep (verified recipe chain at `Justfile:201-202`). `court-x2` = two consecutive fresh greens (`scripts/court_x2.sh`, `justfile.d/07-court-x2.just`) `[EXISTS]`.

```bash
just court       # LANDED: exit 0 (receipt v261019-12, run 1 rc=0)
just court-x2    # LANDED: exit 0 — two consecutive fresh greens at 81a7a29, no shifted failures
```

## 6. Coverage matrix

```bash
just sdk-matrix     # python3 scripts/sdk_coverage.py   [EXISTS]
# expect exit 0 and the line:
#   GATE: OK — every cell pass / registered / sim-pass / missing-registered
```

Verified exit contract (`scripts/sdk_coverage.py:596`): `sys.exit(1 if all_findings else 0)`; windows with no `sdk-results/` and empty divergence register render but are excluded from the exit. Every cell pass-or-registered; no MISSING, no UNREGISTERED-GAP. Re-run this window: `GATE: OK` line printed, rc=0 (see Verification status below).

## 7. Volume — ≥80% reduction

```bash
before=$(git ls-tree -r --name-only v26.10.19~1 -- test/ | wc -l)   # pre-reset count from the last pre-reset commit
after=$(git ls-files test/ | wc -l)                                  # expect 6
python3 -c "print(1 - $after/$before >= 0.80)"                       # expect: True
```

Arithmetic pinned in `receipts/v261019-vol-census.md`: 303 → 9 tracked files
(99.7%), leaf-weighted 3,016 → 278 (90.8%) — target ≥80% MET.

## 8. Docs regenerate clean

```bash
just receipt-index        # python3 scripts/receipt_index.py            [EXISTS]
just receipt-index-check  # expect: "receipt-index: clean (committed index matches regeneration)"  [EXISTS]
just sdk-matrix-md        # expect exit 0 AND docs/jira/v26.10.14/SDK_MATRIX.md + v26.10.16/SDK_MATRIX.md present  [EXISTS]
just bench-report         # python3 scripts/bench/report.py             [EXISTS]
just docs-dod-check       # expect exit 0, zero MISS lines              [EXISTS]
```

---

### Verification notes (path checks performed)

| Path | Status |
|---|---|
| `Justfile` census/invariant-gates/naming-sweep/court | EXISTS |
| `justfile.d/04-sdk-recipes.just` (0/1/2/3 contract doc) | EXISTS |
| `justfile.d/07-court-x2.just` → `scripts/court_x2.sh` | EXISTS |
| `justfile.d/12-docs-dod.just` (`docs-dod-check`) | EXISTS (rc 0 this window) |
| `justfile.d/13-receipt-index.just` | EXISTS |
| `justfile.d/14-sdk-matrix.just` → `scripts/sdk_coverage.py` | EXISTS (rc 0 this window, GATE: OK) |
| `justfile.d/15-bench.just` (`bench-report`) | EXISTS |
| `justfile.d/29-sleep.just` + `scripts/shim_court/sleep_gate_court.sh` | EXISTS |
| `justfile.d/32-verification.just` (`sdk-ts-court`/`sdk-py-court`) | LANDED |
| `justfile.d/33-sleep-gate-ext.just` (`sleep-gate-sdk`) | LANDED |
| `scripts/acceptance_gates.py` (G1–G5 driver) | LANDED |
| `scripts/non_duplication_gate.py` + `portable_target_gate.py` | LANDED |
| `test/` (9 files incl. `internal/internal_tier_census_test.exs` guard) | LANDED |
| `verification/ts`, `verification/py` (wf1–5) | LANDED |
| `docs/jira/v26.10.19/sdk-results/wf*-*.md` | LANDED (10 files) |
| `docs/jira/v26.10.19/sdk-results/external/` | NOT CREATED — receipts consolidated into per-wf `sdk-results/wf*-*.md` instead |

---

### Verification status 2026-10-19 (post-landing re-ground, lane: docs-status)

| Gate | Verdict | Evidence |
|---|---|---|
| G1 (deletion complete / 9-file set) | **PASS** | `receipts/v261019-11-test-deletion-gate.md` (Standing: LANDED); `git ls-files test/ | wc -l` = 9 re-run this window |
| G2 (F1 revert-the-diff court) | **typed-DEFERRED** | F1 court landed and fail-closed (`scripts/acceptance_gates.py`); BEFORE gate typed-SKIPs until the TS suite is green (6 honest emulator divergences standing) — FINAL.md §3, §7 item 3 |
| G3 (external suites alive) | **PASS** | `receipts/v261019-08-ts-external-suite.md` + `receipts/v261019-09-py-external-suite.md` (ALIVE) |
| G4 (residual tier green) | **PASS** (re-verified post-fence-fix) | `receipts/v261019-10-residual-elixir-tier.md`; vm census monitor scope fenced to the long-lived population (commit `c9b0bf1`), 10x green |
| G5 (court green) | **CLOSED** | `receipts/v261019-12-court-x2-close.md` — Standing: **ALIVE**; two consecutive `just court` greens at `81a7a29cd3b15ab6fede2f000d4220aa1eadf235`, invariant-gates 6/6, naming-sweep 0/49. Remaining G5-adjacent item: `just publish-dry` (FINAL.md §7 item 4) |
| Coverage matrix (§6) | **PASS** | `python3 scripts/sdk_coverage.py` re-run this window → `GATE: OK — every cell pass / registered / sim-pass / missing-registered`, rc=0 |
| Docs regen (§8) | **PASS** | `just docs-dod-check` re-run this window → rc 0, zero MISS lines |

Note on §2c: the originally-specified `sdk-results/external/` directory was
never minted — external wf receipts consolidated into `sdk-results/wf*-*.md`
(10 files, one per wf per language). The §2c command above reflects the landed
layout.
