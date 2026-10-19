#!/usr/bin/env bash
# court_x2.sh — two-green-court receipt runner (release receipt gate).
# Runs `just court` TWICE consecutively (fresh runs, no reuse). Exit 0 only on
# two green runs (both exit 0 AND both summary lines showing 0 failures).
# On failure: prints failing tests from both runs and a diff of the failure
# sets — run1 vs run2 failing on DIFFERENT tests is the flake signature.
set -uo pipefail
cd "$(dirname "$0")/.."

# Exit contract: 0 two green runs | 1 court failure | 2 precondition missing.
command -v just >/dev/null 2>&1 || { echo "[COURT-X2] ERROR: 'just' not on PATH (precondition)" >&2; exit 2; }
[ -f Justfile ] || { echo "[COURT-X2] ERROR: no Justfile at repo root (precondition)" >&2; exit 2; }

LOGDIR="$(mktemp -d /tmp/smalt-court-x2.XXXXXX)"
trap 'rm -rf "$LOGDIR"' EXIT

extract_failures() {
    # Failing test names from a full court log (mix-style failure output).
    awk '
        /^[[:space:]]*[0-9]+[)] / {
            name=$0; sub(/^[[:space:]]*[0-9]+\) /, "", name)
            if ((getline nxt) > 0 && nxt ~ /^[[:space:]]+[A-Za-z0-9_\/.]+\.exs:[0-9]+/) {
                loc=nxt; sub(/^[[:space:]]+/, "", loc)
                print name " (" loc ")"
            } else {
                print name
            }
            next
        }
    ' "$1" | sort -u
}

# Green predicate: "0 failures" with no nonzero-failure count AND no
# compile-abort marker — a mix run that died with a CompileError and zero
# test-failure blocks must judge NOT-GREEN, not pass vacuously.
judge_log() {
    local log="$1"
    grep -Eq '0 failures' "$log" \
        && ! grep -Eq '[1-9][0-9]* failures?' "$log" \
        && ! grep -q '== Compilation error' "$log" \
        && ! grep -q ' compilation failed' "$log"
}

overall=0

for run in 1 2; do
    log="$LOGDIR/run$run.log"
    echo "==================================================================="
    echo "[COURT-X2] Run $run of 2 — fresh 'just court', no reuse"
    echo "==================================================================="
    just court >"$log" 2>&1
    rc=$?
    echo "[COURT-X2] Run $run exit: $rc"
    echo "--- Run $run tail summary ---"
    tail -25 "$log"
    echo "-----------------------------"
    if [ "$rc" -ne 0 ]; then
        overall=1
    fi
done

f1="$(extract_failures "$LOGDIR/run1.log")"
f2="$(extract_failures "$LOGDIR/run2.log")"

# Summary-line check: each run's tail must show zero failures.
for run in 1 2; do
    log="$LOGDIR/run$run.log"
    if judge_log "$log"; then
        echo "[COURT-X2] Run $run summary line: 0 failures — GREEN"
        verdict=green
    else
        echo "[COURT-X2] Run $run summary line: FAILURES PRESENT (or unparsable) — NOT GREEN"
        verdict=not-green
        overall=1
    fi
    # OCEL emission (fail-safe): one court.run event per run; telemetry
    # never breaks the gate.
    MIX_BUILD_ROOT="${MIX_BUILD_ROOT:-_build}" mix smalt.court_emit \
        --receipt "$log" --run "$run" --verdict "$verdict" >/dev/null 2>&1 || true
done

if [ -n "$f1" ] || [ -n "$f2" ]; then
    echo "==================================================================="
    echo "[COURT-X2] Failing tests — run 1:"
    echo "${f1:-(none)}"
    echo "[COURT-X2] Failing tests — run 2:"
    echo "${f2:-(none)}"
    echo "[COURT-X2] Failure-set diff (run1 vs run2):"
    diff <(echo "$f1") <(echo "$f2") || true
    if [ -n "$f1" ] && [ -n "$f2" ] && [ "$f1" != "$f2" ]; then
        echo "!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!"
        echo "[COURT-X2] *** SHIFTING-FAILURE / FLAKE SIGNATURE DETECTED ***"
        echo "[COURT-X2] Run 1 and run 2 failed on DIFFERENT tests. This is the"
        echo "[COURT-X2] flake class this session spent a wave killing. Investigate."
        echo "!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!"
    fi
    echo "==================================================================="
fi

if [ "$overall" -eq 0 ]; then
    echo "[COURT-X2] RECEIPT: TWO GREEN RUNS — release receipt gate PASSED."
else
    echo "[COURT-X2] RECEIPT: gate FAILED (see above)."
fi
exit "$overall"
