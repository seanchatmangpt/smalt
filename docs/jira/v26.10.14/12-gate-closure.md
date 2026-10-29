# V261014-12 — Gate Closure: make `just court` the complete release gate

- **Release:** v26.10.14 · **Effort:** M (half day) · **Risk:** low (additive gating; no product code)
- **Files owned:** `justfile` · `scripts/naming_sweep.sh` (new) · `scripts/sb_census_replay.sh` (allowlist note only) · `test/invariant_gates_test.py` (wiring only)
- **Coordinates:** lane 14 owns the `gen-error-codes` justfile target — different recipe, same file

## 1. Problem

`court` (alias of `gate`; recipe body justfile:152) currently runs only:

```
doctor test-offline test-wire test-sdk-smoke tf-plan-smoke bench-check
```

Five gate-class checks exist but sit outside the gate:

| # | Gap | Evidence |
|---|---|---|
| 1 | `mutation-court` (graphlaw validator non-vacuity) not a court member | recipe exists at justfile:113; `scripts/mutation_court.py` |
| 2 | Census + EH smokes not court members; aggregator `run-all.mjs` unused | standalone `census`/`eh-smoke` recipes exist; `test/sdk-smoke/run-all.mjs:29-31` chains run→census→eventhubs; `test-sdk-smoke` (justfile:89) runs only `run.mjs` |
| 3 | Five `gates/*.py` invariant gates never run at gate time — `test/invariant_gates_test.py` not collected by `mix test`, no justfile target | GATES_UNDER_TEST at invariant_gates_test.py:19-25; fail-closed non-vacuity contract at `gates/common.py:9-13` |
| 4 | Naming/leak grep is prose-only | `docs/PUBLISH_CHECK.md:69`, `docs/NAMING_SWEEP.md:3` (`grep -rniE 'legacy-client|/Users/sac|courtroom|\bcai\b|morluto'`) |
| 5 | Bench not upstream of bench-check | `bench-check` reads `tmp/bench-receipt.json`, may be stale |

## 2. Goal state

```just
court: doctor test-offline test-wire test-sdk-smoke tf-plan-smoke bench-check \
        mutation-court census invariant-gates naming-sweep
```

`just court` exits 0 on a clean tree with SDK env present, and exits 0 with a loud `census SKIP` line when `SMALT_SDK_ROOT` is absent. All other members remain hard gates.

## 3. Work items

### 3.1 Extend `court` (justfile:152)

Replace the recipe with the 9-member chain. Keep the alias block. Update the header comment to list all members and the SKIP rule.

### 3.2 Census SKIP semantics

```just
# Service Bus census replay (real @azure/service-bus SDK).
# sb_census_replay.sh exits: 0 all pass / 1 probe failure /
# 2 substrate never up / 3 harness-or-env failure.
# In court, exit 3 caused SOLELY by missing env = SKIP; the rest are hard verdicts.
@census:
    #!/usr/bin/env bash
    set -uo pipefail   # NOT -e: we inspect $?
    if [[ -z "${SMALT_SDK_ROOT:-}" ]]; then
        echo "[COURT] census SKIP: SMALT_SDK_ROOT not set"
        exit 0
    fi
    bash scripts/sb_census_replay.sh
    rc=$?
    if [[ $rc -eq 3 ]]; then
        echo "[COURT] census SKIP: census env missing (exit 3)"
        exit 0
    fi
    exit $rc
```

Verified contract (`scripts/sb_census_replay.sh:8-31`): 0 = 8/8 PASS; 1 = probe failure; 2 = substrate never up (5672/9443 in 60s); 3 = harness failure (ports, spawn, **missing SDK root**). `SMALT_SB_SHARED_KEY` is minted internally (line 33) — only `SMALT_SDK_ROOT` is a true prerequisite. Exits 0/1/2 stay hard in court. Add one comment line to `sb_census_replay.sh` noting the court SKIP-on-3 semantics.

### 3.3 New recipe `invariant-gates`

```just
# Five fail-closed invariant gates (cosmos ETag CAS, blob WORM, ledger chain,
# queue capacity, lock clamp), each booting its own substrate on private ports.
# Non-vacuity: a gate exits 0 only if the positive capture passes AND every
# negative fixture is refused (gates/common.py:9-13).
@invariant-gates:
    python3 test/invariant_gates_test.py
```

No change to the runner's semantics; timeout/profile tweaks allowed, weakening is not.

### 3.4 New script `scripts/naming_sweep.sh` + recipe `naming-sweep`

Executable, stdlib bash, exit 0 clean / 1 leak found:

1. Sweep tracked files only (`git ls-files`), excluding `deps/`, `_build/`, `.git/`, `tmp/`, `.elixir_ls/`, `docs/NAMING_SWEEP.md` (self-quotes), `.ggen_igniter/` (machine receipts).
2. Pattern: `grep -rniE 'legacy-client|/Users/sac|courtroom|\bcai\b|morluto'`.
3. Allowlist (per `docs/NAMING_SWEEP.md` re-verification addendum 2026-10-15): line-precise `path:line` entries in an inline array — `.env.example` legacy defaults; `SMALT_SDK_ROOT` fallbacks at `scripts/sb_census_replay.sh:21`, `scripts/dev_env.sh:33`, `scripts/stress/vs_azurite.py:330,369`, `test/sdk-smoke/eh-run.mjs:143`. Any hit NOT covered → print and exit 1. Summary line: `N allowed / N violations`.
4. Recipe `@naming-sweep: bash scripts/naming_sweep.sh`.

### 3.5 `mutation-court` — no change; include in court

Recipe justfile:113 already correct (0 non-vacuous / 1 vacuous / 2 BLOCKED). Court header note: exit 2 (shared compile broken after 3 retries) is a **hard fail** — do not soften.

### 3.6 Bench refresh note (docs-only)

Add to the court header comment and `docs/PUBLISH_CHECK.md` gate section: run `just bench` before `just court` on a perf-relevant change; a stale-receipt `bench-check` failure is remediated by `just bench`, not by touching the gate.

## 4. Non-goals

- No changes to any `gates/*.py`, `gates/common.py`, `scripts/mutation_court.py`, `scripts/bench*.py`, or `lib/`.
- No move of census/EH into `test-sdk-smoke` via `run-all.mjs` (avoids double-running census); `run-all.mjs` stays for manual full-tier runs.
- `.env.example` cleanup owned by lane 14; this order only allowlists it.
- No CI wiring; `just court` remains the single entrypoint.

## 5. Acceptance criteria

1. `just court` exits 0 end-to-end on a clean tree with valid `SMALT_SDK_ROOT`.
2. `env -u SMALT_SDK_ROOT just court` exits 0; stdout contains `census SKIP`.
3. **Non-vacuity proof:** corrupt one negative fixture in one `gates/*.py` → `just invariant-gates` fails naming the gate; revert → passes.
4. **Naming-sweep proof:** append `/Users/sac/tmp` to any file under `lib/` → `just naming-sweep` exits 1 naming file:line; revert → exits 0.
5. `just -l` shows `court`, `census`, `invariant-gates`, `naming-sweep` with doc comments.
6. Receipts written fresh after a court run: `tmp/invariant-gates/<gate>-receipt.json` (5) + census receipt.

## 6. Rollout

1. `invariant-gates` → 2. census SKIP → 3. `naming_sweep.sh` + recipe → 4. extend `court` → 5. full acceptance → 6. allowlist touch-ups from real output → 7. docs comment updates.
