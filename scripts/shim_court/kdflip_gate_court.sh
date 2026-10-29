#!/usr/bin/env bash
# kdflip_gate_court.sh -- non-vacuity court for scripts/kd_flip.py --apply
# semantics (KD-FLIPFIX lane, 2026-10-22; KD-166F incident: a bare --apply
# re-flipped environment-gated KD-168, and the standing regex rejected
# bold-markdown ALIVE receipts on formatting alone).
#
# Runs the REAL tool (python3 scripts/kd_flip.py) against a KD_FLIP_ROOT
# fixture tree -- no mocks; the fixture register is the court surface.
#
# Phases:
#   FIXTURE   temp tree: OPEN KD-901/KD-902/KD-903 rows, shim file, three
#             post-shim witness receipts (KD-903's is bold-ALIVE with no
#             literal PASS token anywhere).
#   BASELINE  sha256 the fixture register.
#   BEFORE    bare --apply with 3 eligible rows -> exit 2 + would-flip list,
#             register byte-unchanged (fail-closed vs side-effect flips).
#   AFTER     --apply --only KD-901 -> exit 0, EXACTLY KD-901 flipped;
#             --apply --only KD-903 -> exit 0, flips from the bold-ALIVE
#             receipt (old regex rejected it on formatting alone).
#             KD-902 stays OPEN throughout.
#   RESTORE   restore the fixture register from its baseline snapshot;
#             sha256 must equal BASELINE byte-exact (fail-closed).
#
# Exit 0 = non-vacuous pass. Typed [FAIL:PHASE] lines. The fixture is a
# temp tree -- the canonical register is never touched.
set -euo pipefail
REPO="$(cd "$(dirname "$0")/../.." && pwd)"
TOOL="$REPO/scripts/kd_flip.py"

fail() { printf '[FAIL:%s] %s\n' "$1" "$2" >&2; exit 1; }
log()  { printf '[%s] %s\n' "$1" "$2"; }

command -v python3 >/dev/null 2>&1 || fail INIT "python3 not on PATH"

TMP="$(mktemp -d "${TMPDIR:-/tmp}/kdflip-court.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/lib" "$TMP/docs/jira/v1/receipts" "$TMP/docs/jira/v26.10.14"
REG="$TMP/docs/jira/v26.10.14/KNOWN_DIVERGENCES.md"

cat > "$REG" <<'REGEOF'
| KD-901 | d | e1.md | OPEN | cond | OPEN |
| KD-902 | d | e2.md | OPEN | cond | OPEN |
| KD-903 | d | e3.md | OPEN | cond | OPEN |
REGEOF

cat > "$TMP/lib/shim.ex" <<'SHIMEOF'
# KD-COVERS: KD-901,KD-902,KD-903
SHIMEOF

if date -v-1H >/dev/null 2>&1; then
  TS="$(date -v-1H '+%Y%m%d%H%M.%S')"
else
  TS="$(date -d '1 hour ago' '+%Y%m%d%H%M.%S')"
fi
touch -t "$TS" "$TMP/lib/shim.ex"

cat > "$TMP/docs/jira/v1/receipts/k901.md" <<'R1EOF'
KD-901 fixed on the real route.
Disposition: CLOSED-WITH-EVIDENCE
Standing: ALIVE
R1EOF
cat > "$TMP/docs/jira/v1/receipts/k902.md" <<'R2EOF'
KD-902 fixed on the real route.
Disposition: CLOSED-WITH-EVIDENCE
Standing: ALIVE
R2EOF
# KD-903's witness: bold-markdown standing, and NO literal "PASS" token
# anywhere -- only the standing line can qualify it (old regex rejected it).
cat > "$TMP/docs/jira/v1/receipts/k903.md" <<'R3EOF'
KD-903 fix landed on the real route, evidenced below.
Disposition: CLOSED-WITH-EVIDENCE
Standing: **ALIVE**
R3EOF

BASE="$(shasum -a 256 "$REG" | awk '{print $1}')"
log FIXTURE "register fixture built (baseline sha ${BASE:0:12}...)"

run_tool() { # args... -> sets rc/out (errexit-safe: capture the tool rc)
  rc=0; out="$(KD_FLIP_ROOT="$TMP" python3 "$TOOL" "$@" 2>&1)" || rc=$?
}

# BEFORE: bare --apply, 3 eligible rows -> exit 2, register untouched
run_tool --apply
if [ "$rc" -eq 2 ] && grep -q "would-flip: KD-901, KD-902, KD-903" <<<"$out" \
   && [ "$(shasum -a 256 "$REG" | awk '{print $1}')" = "$BASE" ]; then
  log BEFORE "bare --apply exit 2 with would-flip list; register byte-unchanged"
else
  fail BEFORE "expected exit 2 + would-flip list + untouched register; got rc=$rc out=<<$out>>"
fi

cp "$REG" "$TMP/reg.baseline"

# AFTER leg 1: --only flips exactly the named row
run_tool --apply --only KD-901
if [ "$rc" -eq 0 ] \
   && [ "$(shasum -a 256 "$REG" | awk '{print $1}')" != "$BASE" ] \
   && grep -qE '^\| KD-901 .*CLOSED-SIMULATED' "$REG" \
   && [ "$(grep -c CLOSED-SIMULATED "$REG")" -eq 1 ] \
   && grep -E '^\| KD-902 ' "$REG" | grep -q '| OPEN |$' \
   && grep -E '^\| KD-903 ' "$REG" | grep -q '| OPEN |$'; then
  log AFTER "--only KD-901: rc=0, exactly KD-901 flipped; KD-902/KD-903 still OPEN"
else
  fail AFTER "KD-901-only leg: rc=$rc out=<<$out>> reg=<<$(cat "$REG")>>"
fi

# AFTER leg 2: bold-ALIVE receipt qualifies (old-regex defect closed)
run_tool --apply --only KD-903
if [ "$rc" -eq 0 ] && grep -qE '^\| KD-903 .*CLOSED-SIMULATED' "$REG" \
   && grep -E '^\| KD-902 ' "$REG" | grep -q '| OPEN |$'; then
  log AFTER "--only KD-903: bold-ALIVE receipt flipped the row (no PASS token in receipt); KD-902 still OPEN"
else
  fail AFTER "KD-903 bold-ALIVE leg: rc=$rc out=<<$out>> reg=<<$(cat "$REG")>>"
fi

# RESTORE: restore from baseline snapshot; sha byte-exact
cp "$TMP/reg.baseline" "$REG"
if [ "$(shasum -a 256 "$REG" | awk '{print $1}')" = "$BASE" ]; then
  log RESTORE "fixture register restored sha256-exact"
else
  fail RESTORE "restore mismatch: $(shasum -a 256 "$REG" | awk '{print $1}') != $BASE"
fi

log PASS "kdflip gate court non-vacuous (exit-2 fence, exact --only flip, bold-ALIVE acceptance, restore sha-exact)"
