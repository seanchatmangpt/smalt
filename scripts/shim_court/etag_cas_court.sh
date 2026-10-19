#!/usr/bin/env bash
# etag_cas_court.sh — shim court for the cosmos-etag-cas invariant gate (M1, v26.10.16).
#
# Subject: lib/smalt/data_plane/cosmos.ex — the optimistic-concurrency CAS on
# the conditional replace path (Store.compare_and_swap, the S8 guarantee:
# exactly one 200 and N-1 412s under a same-etag race).
#
# Protocol (scripts/shim_court/lib.sh):
#   BASELINE  sha256(cosmos.ex)
#   BEFORE    gates/cosmos_etag_cas_gate.py exits 0 against the PRISTINE CAS
#             (boot its own MIX_ENV=test private-port substrate; receipt PASS).
#   SHIM      apply_shim swaps the atomic CAS for a plain Store.put — every
#             conditional writer wins, the race becomes six 200s (lost update),
#             marked `SHIM-COURT`.
#   AFTER     the gate must REFUSE: exit 1 AND the receipt's positive phase a
#             RUNTIME FAIL naming the race check ("exactly one 200") — NOT an
#             ERROR/compile failure, which would fake the flip.
#   RESTORE   sha256 byte-exact, fail-closed.
#
# Exit 0 pass / 1 fail / 3 loud skip.
set -euo pipefail
cd "$(git rev-parse --show-toplevel 2>/dev/null || pwd)"

source "$(dirname "$0")/lib.sh"

COSMOS=lib/smalt/data_plane/cosmos.ex
export GATE=gates/cosmos_etag_cas_gate.py
export RECEIPT=tmp/invariant-gates/cosmos-etag-cas-receipt.json
export MIX_BUILD_ROOT=_build-lane9   # lane-local build root, never the shared one

# Loud skip when the environment cannot run the court for real.
command -v mix >/dev/null 2>&1 || shim_court_skip "mix not on PATH"
command -v python3 >/dev/null 2>&1 || shim_court_skip "python3 not on PATH"
[ -f "$COSMOS" ] || shim_court_skip "subject missing: $COSMOS"
[ -f "$GATE" ] || shim_court_skip "gate missing: $GATE"
grep -q 'Store.compare_and_swap(@docs_table, key, existing, updated)' "$COSMOS" \
    || shim_court_skip "subject degraded: cosmos.ex lacks the replace-path CAS (already mutated?)"

shim_court_self_check

apply_shim() {
    python3 - "$SHIM_FILE" <<'PYEOF'
import sys, time
path = sys.argv[1]
src = open(path).read()
old = ("            ConditionalHeaders.evaluate(headers, existing[\"_etag\"]) == :proceed ->\n"
       "              # Atomic check+write: CAS keyed on the CURRENT STORED RECORD.\n"
       "              case Store.compare_and_swap(@docs_table, key, existing, updated) do")
# Widen: neutralize the ConditionalHeaders GUARD too, not just the CAS. A
# narrower shim (CAS -> put, guard kept) cannot flip: each loser re-reads the
# already-updated record, evaluates its stale If-Match against it, and falls
# into the `true ->` 412 catch-all — the pristine 1x200+5x412 shape reproduces
# WITHOUT atomicity (witnessed 2026-10-19). The class under test is the
# non-atomic check-then-write, so the shim admits EVERY conditional writer
# through a plain Store.put: six 200s, lost update, gate must refuse.
new = ("            # SHIM-COURT etag-cas: atomic CAS -> unconditional put\n"
       "            # (every conditional writer wins; the race becomes six 200s)\n"
       "            if_match != nil ->\n"
       "              case (Store.put(@docs_table, key, updated) && :ok) do")
assert src.count(old) == 1, f"expected exactly one replace-path CAS, got {src.count(old)}"
open(path, "w").write(src.replace(old, new))
import os
# Force mix to see the edit: an in-place rewrite inside the same mtime second
# is invisible to the compiler's change detection (witnessed: AFTER ran the
# stale pristine beam and the flip looked vacuous).
os.utime(path, (time.time() + 2, time.time() + 2))
PYEOF
}

# BEFORE: pristine CAS -> gate passes (receipt verdict PASS).
before_witness() {
    python3 "$GATE"
    local rc=$?
    [ "$rc" -eq 0 ] || { echo "[etag-cas-court] BEFORE: gate exited $rc"; return 1; }
    python3 -c 'import json,sys; r=json.load(open(sys.argv[1])); sys.exit(0 if r["verdict"]=="PASS" and r["positive"]=="PASS" else 1)' "$RECEIPT"
}

# AFTER: shimmed runtime loses updates -> gate must REFUSE via a RUNTIME
# positive FAIL on the race check (not an ERROR/compile failure).
after_witness() {
    python3 "$GATE"
    local rc=$?
    [ "$rc" -eq 1 ] || { echo "[etag-cas-court] AFTER: gate exited $rc (wanted 1)"; return 1; }
    python3 - "$RECEIPT" <<'PYEOF'
import json, sys
r = json.load(open(sys.argv[1]))
ok = (r["verdict"] == "FAIL" and r["positive"] == "FAIL"
      and any("exactly one 200" in d and d.startswith("FAIL") for d in r["positive_details"]))
sys.exit(0 if ok else 1)
PYEOF
}

with_shim "$COSMOS" "$(declare -f before_witness); before_witness" \
                    "$(declare -f after_witness); after_witness"
