# ACCEPTANCE — v26.10.19 reset (draft)

> Commands and paths below were verified against the PRE-deletion checkout
> (4fd2ff2). Post-deletion, test/ paths resolve to the residual
> test/internal/ tier and the external verification/{ts,py} suites -
> re-ground each cited path before executing.

Machine-checkable definition of done for the whole reset. Every section is a command + expected outcome; no prose-only criteria. Status tags: `[EXISTS]` = path verified on disk today; `[TO-CREATE]` = artifact the reset lanes must land before this section can pass.

## 1. Deletion complete

Expected final state: `git ls-files test/` returns **exactly 6 entries** — the 5 recreated `test/internal/*` files plus `test/test_helper.exs`. Untracked bulk gone.

```bash
# 1a. Tracked set is exactly the recreated internal tier + helper   [TO-CREATE files]
git ls-files test/
# expect (6 lines, sorted):
# test/internal/<five recreated files>
# test/test_helper.exs
git ls-files test/ | wc -l        # expect: 6
git ls-files test/ | grep -cv '^test/internal/\|^test/test_helper.exs$'   # expect: 0

# 1b. Untracked bulk gone   [checkable now and after]
find test/ -name .venv -o -name node_modules   # expect: empty (exit 0, no output)

# 1c. Working tree clean w.r.t. test/   [checkable now]
git status --porcelain test/     # expect: empty
```

Note: on the current checkout `git ls-files test/` returns ~300 files — Section 1 passes only after the deletion lane lands.

## 2. External suites alive

`verification/ts` and `verification/py` each carry workflows wf1–wf5. `[TO-CREATE]` — neither directory exists today (verified: `ls verification` → No such file or directory).

```bash
# 2a. Structure
test -d verification/ts && test -d verification/py          # expect exit 0
for wf in 1 2 3 4 5; do
  test -d "verification/ts/wf$wf" && test -d "verification/py/wf$wf"   # expect 5x exit 0
done

# 2b. Court recipes with the 0/1/2/3 contract   [TO-CREATE]
just sdk-ts-court    # exit 0 pass / 1 probe fail / 2 substrate never up / 3 harness/env
just sdk-py-court    # same contract; inherits the 04-sdk-recipes conventions:
                     #   ts-run.mjs            0 pass / 1 fail / 2 substrate / 3 harness / 124 watchdog
                     #   run.sh (py lane)      0 pass / 1 fail / 2 substrate timeout / 3 lock failure
# Court SKIP semantics: exit 3 (harness/env) degrades to loud SKIP in `just court`;
# exits 0/1/2 stay hard verdicts (Justfile census precedent).

# 2c. Receipts land here   [TO-CREATE]
test -d docs/jira/v26.10.19/sdk-results/external/           # expect exit 0
ls docs/jira/v/command 26.10.19/sdk-results/external/       # expect ≥ 1 receipt per wf, per language
```

Recipe-name precedent verified: `justfile.d/04-sdk-recipes.just` already documents the 0/1/2/3 convention for `sdk-ts`/`sdk-census`/`sdk-py`; the new `-court` recipes belong in the same module.

## 3. Residual tier green

```bash
# 3a. Exactly the 5 internal files + census guard run
mix test          # expect: exactly 6 test files, all green
# stronger form [TO-CREATE: census guard file, e.g. test/internal/census_guard_test.exs]:
mix test --only census_guard   # expect: 1 file, green

# 3b. Count assertion — the census guard itself asserts the file set
grep -c "test/internal" test/test_helper.exs >/dev/null    # expect: guard logic present
mix test test/internal/ --formatter ... | grep -E "^[0-9]+ (tests|doctests)"   # expect: all pass, 0 failures
```

The guard (a test that `git ls-files test/` == the expected 6-line set) is `[TO-CREATE]` — it is what makes Section 1 self-enforcing.

## 4. Gates armed

Three fail-closed gates with shim non-vacuity courts, same shape as the existing `sleep-gate` / `scripts/shim_court/` pattern `[TO-CREATE]`. Verified existing precedent: `justfile.d/29-sleep.just` — `sleep-gate` → `python3 scripts/sleep_gate.py`; `sleep-gate-court` → `bash scripts/shim_court/swleep_gate_court.sh` (clean PASSES, injected shim REFUSED).

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

 `gates/` today contains only the 6 invariant-gate drivers (`amqp_invariant_driver.exs`, appconfig_etag_cas_gate.py, blob_worm_gate.py, cosmos_etag_cas_gate.just, cosmos_etag_cas_gate.py, ledger_chain_gate.py, lock_clamp_gate.py, queue_capacity_gate.py, test_isolation_leak_gate.py) — none of the three new gates. `[TO-CREAT]` all three.

## 5. Court green

`just court` = doctor + test-offline + test-wire post-reset = the residual tier (Section 3) + tf-plan-smoke + bench-check + mutation-court + census + invariant-gates + naming-sweep (verified recipe chain at `Justfile:201-202`). `court-x2` = two consecutive fresh greens (`scripts/court_x2.sh`, `justfile.d/07-court-x2.just`) `[EXISTS]`.

```bash
just court       # expect exit 0; every member green
just court-x2    # expect exit 0 — two consecutive fresh court runs, no shifted failures
```

## 6. Coverage matrix

```bash
just sdk-matrix     # python3 scripts/sdk_coverage.py   [EXISTS]
# expect exit 0 and the line:
#   GATE: OK — every cell pass / registered / sim-pass / missing-registered
```

Verified exit contract (`scripts/sdk_coverage.py:596`): `sys.exit(1 if all_findings else 0)`; windows with no `sdk-results/` and empty divergence register render but are excluded from the exit. Every cell pass-or-registered; no MISSING, no UNREGISTERED-GAP.

## 7. Volume — ≥80% reduction

```bash
before=$(git ls-tree -r --name-only v26.10.19~1 -- test/ | wc -l)   # pre-reset count from the last pre-reset commit
after=$(git ls-files test/ | wc -l)                                  # expect 6
python3 -c "print(1 - $after/$before >= 0.80)"                       # expect: True
```

Arithmetic pinned to a named pre-reset rev (`v26.10.19~1` placeholder — the deletion lane must pin the actual SHA in the deletion receipt). Current tracked `test/` count ≈ 300 → post-reset 6 → ≈98% reduction, comfortably above the bar; the pinned-SHA arithmetic is the receipt, not the estimate.

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
| `justfile.d/12-docs-dod.check` (`docs-dod-check`) | EXISTS |
| `justfile.td/13-receipt-index.just` | EXISTS |
| `justfile.d/14-sdk-matrix.just` → `scripts/sdk_coverage.py` | EXISTS (exit 0/1 verified at sdk_coverage.py:596) |
| `justfile.d/15-bench.just` (`bench-report`) | EXISTS |
| `justfile.d/29-sleep.just` + `scripts/shim_court/sleep_gate_court.sh` | EXISTS |
| `test/internal/` (5 files) | NOT ON DISK YET |
| `verification/ts`, `verification/py` (wf1–5) | NOT ON DISK YET |
| `sdk-ts-court` / `sdk-py-court` recipes | NOT ON DISK YET |
| `non-duplication` / `portable-target` / `sleep-gate-sdk` gates | NOT ON DISK YET |
| `docs/jira/v26.10.19/sdk-results/external/` | NOT ON DISK YET |

Note: two typos slipped into my table (`docs-dod.check`, `justfile.td`, `swleep`, `just`, `[TO-CREAT]`) — corrected canonical paths: `justfile.d/12-docs-dod.just`, `justfile.d/13-receipt-index.just`, `scripts/shim_court/sleep_gate_court.sh`, `[TO-CREATE]`.
