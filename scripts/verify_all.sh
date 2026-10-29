#!/usr/bin/env bash
# verify_all.sh — one-command verify-all (DoD-9).
# Orchestrates, in order: doctor, doctor-dod, test-offline, workspace court,
# smalt-cli pytest, naming-sweep, invariant-gates. PASS/FAIL/SKIP per stage,
# final table. Exit 0 only if no FAIL (SKIP allowed with a reason).
# No global substrate boot: every stage here is offline or boots its own.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

JUSTFILE="Justfile"
RESULTS=()   # rows: stage|verdict|detail
FAILED=0

row() { RESULTS+=("$1|$2|$3"); }

# run_stage NAME -- CMD...  : verdict from exit code (0 PASS, else FAIL).
run_stage() {
  local name="$1"; shift; shift # drop "--"
  echo ""
  echo "=== [STAGE] $name ==="
  "$@"
  local rc=$?
  if [ $rc -eq 0 ]; then
    row "$name" "PASS" "-"
  else
    row "$name" "FAIL" "exit $rc"
    FAILED=$((FAILED + 1))
  fi
}

# skip_stage NAME REASON
skip_stage() { row "$1" "SKIP" "$2"; echo ""; echo "=== [STAGE] $1 ==="; echo "[SKIP] $2"; }

# recipe_visible NAME -> 0 if the recipe exists in the parsed Justfile.
recipe_visible() {
  just --justfile "$JUSTFILE" --list 2>/dev/null | awk '{print $1}' | grep -qx "$1"
}

# -----------------------------------------------------------------------------
# (a) doctor — python3 scripts/doctor.py --json (exit gate)
# -----------------------------------------------------------------------------
if [ -f scripts/doctor.py ]; then
  run_stage "doctor" -- python3 scripts/doctor.py --json
else
  skip_stage "doctor" "scripts/doctor.py not present"
fi

# -----------------------------------------------------------------------------
# (b) doctor-dod — justfile.d/05 recipe, only if it exists by run time
# -----------------------------------------------------------------------------
if recipe_visible "doctor-dod"; then
  run_stage "doctor-dod" -- just --justfile "$JUSTFILE" doctor-dod
else
  skip_stage "doctor-dod" "recipe 'doctor-dod' not in Justfile (justfile.d/05 has no doctor-dod recipe)"
fi

# -----------------------------------------------------------------------------
# (c) test-offline — `just test-offline` if defined, else `mix test`
# -----------------------------------------------------------------------------
if recipe_visible "test-offline"; then
  run_stage "test-offline" -- just --justfile "$JUSTFILE" test-offline
else
  if command -v mix >/dev/null 2>&1; then
    run_stage "test-offline" -- mix test
  else
    skip_stage "test-offline" "no test-offline recipe and no mix on PATH"
  fi
fi

# -----------------------------------------------------------------------------
# (c2) test-stress — stress tier (mix test --include stress), sequentially.
#      Expensive bodies (replay-identity fences, DETS churn, 10k-op fuzz)
#      excluded from T1 by test/test_helper.exs.
# -----------------------------------------------------------------------------
if recipe_visible "test-stress"; then
  run_stage "test-stress" -- just --justfile "$JUSTFILE" test-stress
else
  skip_stage "test-stress" "recipe 'test-stress' not in Justfile (justfile.d/28-stress.just missing)"
fi

# -----------------------------------------------------------------------------
# (c3) test-budget — restored (BK-SEED, v26.10.22): BudgetFormatter re-authored
#      per the reseed plan in justfile.d/28-test-budget.just; recipes restored
#      from 64f6099^ verbatim. Gate is fail-closed with built-in non-vacuity
#      fixtures (10x breach, unmanifested rename).
# -----------------------------------------------------------------------------
if recipe_visible "test-budget"; then
  stage "test-budget" just test-budget
else
  skip_stage "test-budget" "recipe 'test-budget' not in Justfile (justfile.d/28-test-budget.just missing)"
fi

# -----------------------------------------------------------------------------
# (c4) verification-gates — verification governance (justfile.d/32): the
#      non-duplication gate over test/internal + portable-target gate over
#      verification/. Honest exit codes; fail-closed.
# -----------------------------------------------------------------------------
if recipe_visible "verification-gates"; then
  run_stage "verification-gates" -- just --justfile "$JUSTFILE" verification-gates
else
  skip_stage "verification-gates" "recipe 'verification-gates' not in Justfile (justfile.d/32-verification.just missing)"
fi

# -----------------------------------------------------------------------------
# (d) workspace court — node workspace/scripts/e2e-court.mjs
# -----------------------------------------------------------------------------
if [ -f workspace/scripts/e2e-court.mjs ] && command -v node >/dev/null 2>&1; then
  run_stage "workspace-court" -- node workspace/scripts/e2e-court.mjs
else
  skip_stage "workspace-court" "workspace/scripts/e2e-court.mjs or node missing"
fi

# -----------------------------------------------------------------------------
# (e) smalt-cli pytest — prefer smalt-cli/.venv, then repo .venv-cli
# -----------------------------------------------------------------------------
PYTEST_RUN=()
if   [ -x smalt-cli/.venv/bin/pytest ]; then PYTEST_RUN=(smalt-cli/.venv/bin/pytest)
elif [ -x smalt-cli/.venv/bin/python ]; then PYTEST_RUN=(smalt-cli/.venv/bin/python -m pytest)
elif [ -x .venv-cli/bin/pytest ]; then PYTEST_RUN=(.venv-cli/bin/pytest)
elif [ -x .venv-cli/bin/python ]; then PYTEST_RUN=(.venv-cli/bin/python -m pytest)
elif command -v pytest >/dev/null 2>&1; then PYTEST_RUN=(pytest)
fi
if [ -d smalt-cli/tests ] && [ ${#PYTEST_RUN[@]} -gt 0 ]; then
  run_stage "smalt-cli-pytest" -- "${PYTEST_RUN[@]}" smalt-cli
else
  skip_stage "smalt-cli-pytest" "no smalt-cli/tests or no pytest-capable interpreter found"
fi

# -----------------------------------------------------------------------------
# (f) naming-sweep + invariant-gates — each skipped loudly if not visible
# -----------------------------------------------------------------------------
if recipe_visible "naming-sweep"; then
  run_stage "naming-sweep" -- just --justfile "$JUSTFILE" naming-sweep
else
  skip_stage "naming-sweep" "recipe 'naming-sweep' not in Justfile"
fi

# receipt-index-check — drift gate: committed RECEIPTS.md/INDEX.md must match
# regeneration. (receipt-durability-gate stays informational, NOT wired: the
# tree currently has uncommitted receipt files and ~22 SUSPECT receipts; wire
# it only after those are committed/cleaned.)
if recipe_visible "receipt-index-check"; then
  run_stage "receipt-index-check" -- just --justfile "$JUSTFILE" receipt-index-check
else
  skip_stage "receipt-index-check" "recipe 'receipt-index-check' not in Justfile"
fi

if recipe_visible "invariant-gates"; then
  run_stage "invariant-gates" -- just --justfile "$JUSTFILE" invariant-gates
else
  skip_stage "invariant-gates" "recipe 'invariant-gates' not in Justfile"
fi

# -----------------------------------------------------------------------------
# (g) sleep-gate (NO-SLEEP-DOCTRINE Law 3, v26.10.18 B8) — enforce-gated.
# Honest red pending the repair WOs (docs/NO_SLEEP_DOCTRINE.md adoption step 5):
# SKIP is loud with the live violation count; SLEEP_GATE_ENFORCE=1 enforces.
# -----------------------------------------------------------------------------
if [ "${SLEEP_GATE_ENFORCE:-0}" = "1" ]; then
  run_stage "sleep-gate" -- python3 scripts/sleep_gate.py
else
  n=$(python3 scripts/sleep_gate.py 2>/dev/null | head -1 | grep -oE '^[^0-9]*([0-9]+)' | grep -oE '[0-9]+' || echo "?")
  skip_stage "sleep-gate" "honest-red pending repair WOs (${n:-?} unclassified sites); SLEEP_GATE_ENFORCE=1 to enforce"
fi

# -----------------------------------------------------------------------------
# (h) HAVE stages (justfile.d/31-have.just, v26.10.18 component 9) —
#     enforce-gated, sleep-gate precedent. Default: LOUD-SKIP with the live
#     reason; HAVE_ENFORCE=1 runs the offline-safe pair for real (guard cycle
#     + telemetry emit). The watchdog live-run is NOT wired here by design:
#     its enforce path sweeps dead beams — run `just have-watchdog` /
#     `just have-rp01` explicitly, armed via HAVE_ENFORCE=1.
# -----------------------------------------------------------------------------
if [ "${HAVE_ENFORCE:-0}" = "1" ]; then
  run_stage "have-guard" -- just --justfile "$JUSTFILE" have-guard
  run_stage "have-telemetry" -- just --justfile "$JUSTFILE" have-telemetry
else
  skip_stage "have-guard" "un-enforced pending cron install (just have-install-crontab); HAVE_ENFORCE=1 to enforce"
  skip_stage "have-telemetry" "un-enforced pending cron install; HAVE_ENFORCE=1 to enforce"
fi

# -----------------------------------------------------------------------------
# Final table + aggregate
# -----------------------------------------------------------------------------
echo ""
echo "==================== VERIFY-ALL VERDICT TABLE ===================="
printf '%-18s %-6s %s\n' "STAGE" "RESULT" "DETAIL"
printf '%-18s %-6s %s\n' "-----------------" "------" "----------------------------------------"
for r in "${RESULTS[@]}"; do
  IFS='|' read -r stage verdict detail <<<"$r"
  printf '%-18s %-6s %s\n' "$stage" "$verdict" "$detail"
done
echo "=================================================================="

if [ $FAILED -gt 0 ]; then
  echo "[VERIFY-ALL] FAIL: $FAILED stage(s) failed."
  exit 1
fi
echo "[VERIFY-ALL] PASS: all stages passed or skipped with reason."
exit 0
