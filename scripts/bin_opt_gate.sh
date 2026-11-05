#!/usr/bin/env bash
# bin_opt_gate.sh — AoQ match-context reuse gate (aq-architecture-spec §4, 25dd40df).
#
# Compiles the scope surface with ERL_COMPILER_OPTIONS=bin_opt_info, captures
# stderr, and FAILS CLOSED on any warning emitted for a module under the scope
# (default lib/smalt/aoq) that matches a pinned FAIL class. Zero scoped
# warnings = exit 0. Warnings for NON-scope modules (deps, stdlib, rest of
# lib/) are scoped out by path attribution — the gate is scoped to the AoQ
# surface, like the naming sweep is scoped to its surface.
#
# ============================================================================
# PINNED WARNING-CLASS VOCABULARY (premise-rot diff surface — the spec says
# warning text premise rot must be a diff, not a silent pass)
# ============================================================================
# Spec §4 classes (authored against legacy OTP ≤27 bin_opt_info texts):
#   R1: no match .* could be optimized
#   R2: optimization .* is not possible
#   R3: not a binary directive
#   R4: deferred
# OTP 29 (erts-17.1.1, Elixir 1.20.4-otp-29) re-emits the same underlying
# diagnostics as (measured on this toolchain, see
# docs/jira/v26.11.5/receipts/l12-bin-opt-gate.md):
#   F1: NOT OPTIMIZED: ...                     (match cannot optimize)
#   F2: BINARY CREATED: ... doesn't support context reuse
# F-classes FAIL; R-classes stay pinned for forward compat (a toolchain
# rollback resurrects them). A class going extinct OR a new class appearing is
# a diff to THIS header, never a silent pass.
#
# BENIGN vocabulary (explicitly NOT failing — the spec-required parse shape
# "returns {parsed, rest}" emits B1/B2 on OTP 29; measured):
#   B1: BINARY CREATED: binary is returned from the function
#   B2: BINARY CREATED: binary is used in a term that is returned from the function
# Any scoped warning matching NEITHER the FAIL nor the BENIGN vocabulary
# FAILS CLOSED (unclassified = fail; silence is not a pass).
# ============================================================================
#
# Environment:
#   BINOPT_SCOPE       default lib/smalt/aoq — files under it are compiled
#                      with bin_opt_info via elixirc against warmed build beams
#   BINOPT_BUILD_ROOT  default tmp/bin-opt/build (dedicated scratch build
#                      root — never the shared _build; lane-safe by design)
#   BINOPT_RECEIPT_DIR default tmp/bin-opt (gate result receipt lands here,
#                      scratch, not indexed)
#
# Exit codes: 0 = zero scoped FAIL-class warnings.
#             1 = scoped FAIL-class (or unclassified scoped) warnings.
#             2 = environment/compile failure (fail loud, never fake-pass).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

# rg fail-loud guard NOT needed: this gate uses grep/awk only (no rg).
command -v mix >/dev/null 2>&1 || { echo "[FAIL:MIX] no mix on PATH" >&2; exit 2; }
command -v elixirc >/dev/null 2>&1 || { echo "[FAIL:ELIXIRC] no elixirc on PATH" >&2; exit 2; }

BINOPT_SCOPE="${BINOPT_SCOPE:-$ROOT/lib/smalt/aoq}"
BINOPT_BUILD_ROOT="${BINOPT_BUILD_ROOT:-$ROOT/tmp/bin-opt/build}"
BINOPT_RECEIPT_DIR="${BINOPT_RECEIPT_DIR:-$ROOT/tmp/bin-opt}"
mkdir -p "$BINOPT_BUILD_ROOT" "$BINOPT_RECEIPT_DIR"
BEAMS="$BINOPT_RECEIPT_DIR/beams"
rm -rf "$BEAMS"
mkdir -p "$BEAMS"

# --- Pinned toolchain (repo .tool-versions: elixir 1.20.4-otp-29 / OTP 29.1.2)
for _c in "$HOME/.asdf/installs/elixir/1.20.4-otp-29/bin" \
          "$HOME/.asdf/installs/erlang/29.1.2/bin"; do
    [ -d "$_c" ] && PATH="$_c:$PATH"
done
export PATH

# --- Phase 1: warm the build root (deps + project beams for -pa code path) --
# Incremental mix compile into the DEDICATED build root. Blocks until done
# (blocking subprocess is lawful; no sleeps). Non-fatal on failure: another
# lane's in-flight edit may have the shared tree mid-compile (compile-freeze
# SLA owns that); the Phase 2 scope compile still fails loud on real errors.
if ! MIX_BUILD_ROOT="$BINOPT_BUILD_ROOT" mix compile >/dev/null 2>&1; then
    echo "[WARN:WARM] mix compile failed in $BINOPT_BUILD_ROOT (tree mid-compile?); proceeding with elixirc scope compile" >&2
fi

# --- Phase 2: compile scope files with bin_opt_info -------------------------
SCOPE_FILES="$(find "$BINOPT_SCOPE" -name '*.ex' -type f | sort)"
if [ -z "$SCOPE_FILES" ]; then
    echo "[FAIL:SCOPE] no .ex files under $BINOPT_SCOPE" >&2
    exit 2
fi

PA_ARGS=()
while IFS= read -r ebin; do
    PA_ARGS+=(-pa "$ebin")
done < <(find "$BINOPT_BUILD_ROOT" -path '*/lib/*/ebin' -type d | sort)

STDERR_LOG="$BINOPT_RECEIPT_DIR/stderr.log"
: > "$STDERR_LOG"
while IFS= read -r f; do
    if ! ERL_COMPILER_OPTIONS=bin_opt_info elixirc "${PA_ARGS[@]}" -o "$BEAMS" "$f" \
        2>>"$STDERR_LOG"; then
        echo "[FAIL:COMPILE] bin_opt_info compile failed for $f" >&2
        exit 2
    fi
done <<<"$SCOPE_FILES"

# --- Phase 3: scoped warning-class gate (fail closed) -----------------------
# Attribution: an Elixir-format diagnostic block starts at '    warning: ' and
# its location line is '    └─ <path>:<line>'. An Erlang-format diagnostic is
# '<path>:<line>[.<col>]: Warning: <text>'. A warning belongs to the scope if
# its attributed path is under $BINOPT_SCOPE.
RESULT="$(BINOPT_SCOPE="$BINOPT_SCOPE" python3 - "$STDERR_LOG" <<'PYEOF'
import re, sys, os

log = open(sys.argv[1], encoding="utf-8", errors="replace").read()
scope = os.path.realpath(sys.argv[2] if len(sys.argv) > 2 else os.environ["BINOPT_SCOPE"])

FAIL = [r"NOT OPTIMIZED", r"doesn't support context reuse",
        r"no match .* could be optimized", r"optimization .* is not possible",
        r"not a binary directive", r"deferred"]
BENIGN = [r"OPTIMIZED: match context reused",
          r"BINARY CREATED: binary is returned from the function",
          r"BINARY CREATED: binary is used in a term that is returned from the function"]
# bin_opt_info diagnostics begin with one of these prefixes; any other scoped
# warning is a plain compiler warning owned by other gates, not this one.
BIN_OPT_PREFIX = re.compile(r"^(OPTIMIZED|NOT OPTIMIZED|BINARY CREATED)\b")

def classify(text):
    if not BIN_OPT_PREFIX.match(text) and \
       not any(re.search(p, text) for p in FAIL):
        return "SKIP"  # not a bin_opt diagnostic (other gates' surface)
    if any(re.search(p, text) for p in BENIGN):
        return "BENIGN"
    if any(re.search(p, text) for p in FAIL):
        return "FAIL"
    return "UNCLASSIFIED"

blocks = re.split(r"(?=^\s*warning: )", log, flags=re.M)
scoped_fail, scoped_benign, scoped_skip = [], 0, 0
for b in blocks:
    m = re.search(r"└─\s+(\S+?):\d+", b)
    if not m:
        m = re.search(r"^(\S+?):\d+(?:\.\d+)?:\s*Warning:", b, re.M)
    if not m:
        continue
    path = os.path.realpath(m.group(1))
    if not (path == scope or path.startswith(scope + os.sep)):
        continue
    w = re.search(r"warning:\s*(.+)", b)
    text = w.group(1) if w else b.strip().splitlines()[0]
    c = classify(text)
    if c == "BENIGN":
        scoped_benign += 1
    elif c == "SKIP":
        scoped_skip += 1
    else:
        scoped_fail.append(("UNCLASSIFIED: " if c == "UNCLASSIFIED" else "") + text)

for s in scoped_fail:
    print("WARN-FAIL:", s)
print(f"SUMMARY scoped_fail={len(scoped_fail)} scoped_benign={scoped_benign} scoped_other={scoped_skip}")
PYEOF
)"
echo "$RESULT" | tail -n 1
echo "$RESULT" | grep '^WARN-FAIL:' >&2 || true
echo "$RESULT" > "$BINOPT_RECEIPT_DIR/gate-result.txt"

FAILS="$(echo "$RESULT" | grep -c '^WARN-FAIL:' || true)"
if [ "$FAILS" -gt 0 ] 2>/dev/null; then
    echo "[FAIL:GATE] $FAILS scoped bin_opt warning(s) under $BINOPT_SCOPE" >&2
    exit 1
fi
echo "bin_opt gate: PASS (zero scoped FAIL-class warnings)"
exit 0
