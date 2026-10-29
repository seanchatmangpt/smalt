#!/usr/bin/env bash
# close_kd122.sh — receipt-gated KD-122 (blob CORS) closure.
# Standing: the flip is decided by evidence, never hand-declared.
#
# Eligibility law:
#   1. witness  = newest popcorn_demo/receipts/*-testbed-witness.md
#      (or a fresh `node scripts/browser_smoke.mjs` run with --fresh)
#   2. eligible IFF witness mtime > lib/smalt/egress_router.ex mtime
#      (the file carrying `# KD-COVERS: KD-122`)
#      AND the witness's SMOKE_RECEIPT line (the in-browser witness, not the
#      HOST-leg line) contains blob=OK AND does NOT contain blob=SKIP.
#      A blob=OK elsewhere in the file (host leg) is NOT sufficient —
#      false-flip hazard: witness embeds host-leg OK while browser leg SKIPs.
#   3. on eligible: scripts/kd_flip.py --apply (register flips only via the tool).
#      If the tool cannot cover the v26.10.20 pointer file, exit 3 typed refusal
#      naming exactly what is missing. Never hand-edit the register here.
#
# Exit codes: 0 flip-done | 1 error | 3 not-eligible-loud
set -euo pipefail

REPO="${REPO:-/Users/sac/smalt}"
SHIM="lib/smalt/egress_router.ex"
RECEIPT_DIR="popcorn_demo/receipts"
KD_ID="KD-122"

FRESH=0
[ "${1:-}" = "--fresh" ] && FRESH=1

cd "$REPO"

for f in "$SHIM" scripts/kd_flip.py; do
  [ -f "$f" ] || { echo "REFUSED(KD-122): missing $f" >&2; exit 1; }
done

SHIM_MT=$(stat -f %m "$SHIM")
echo "shim: $SHIM mtime=$SHIM_MT ($(date -r "$SHIM_MT" '+%F %T %Z'))"
grep -n "KD-COVERS: $KD_ID" "$SHIM" || {
  echo "REFUSED(KD-122): shim token missing in $SHIM" >&2; exit 1; }

if [ "$FRESH" -eq 1 ]; then
  echo "--fresh: running node popcorn_demo/scripts/browser_smoke.mjs"
  node popcorn_demo/scripts/browser_smoke.mjs
fi

# (1) newest testbed witness receipt
WITNESS=$(ls -t "$RECEIPT_DIR"/*-testbed-witness.md 2>/dev/null | head -1 || true)
if [ -z "$WITNESS" ]; then
  echo "REFUSED(KD-122): no *-testbed-witness.md under $RECEIPT_DIR/" >&2
  echo "NOT-ELIGIBLE(KD-122): no witness receipt exists yet (exit 3)" >&2
  exit 3
fi
W_MT=$(stat -f %m "$WITNESS")
echo "witness: $WITNESS mtime=$W_MT ($(date -r "$W_MT" '+%F %T %Z'))"

# (2) gate: receipt postdates shim, and the SMOKE_RECEIPT line (browser leg)
#     carries blob=OK with no blob=SKIP on that same line.
if [ "$W_MT" -le "$SHIM_MT" ]; then
  echo "NOT-ELIGIBLE(KD-122): witness mtime ($W_MT) does not postdate shim mtime ($SHIM_MT); substrate restart with the fix has not been witnessed yet (exit 3)"
  exit 3
fi
SMOKE_LINE=$(grep '^SMOKE_RECEIPT:' "$WITNESS" | tail -1 || true)
if [ -z "$SMOKE_LINE" ]; then
  echo "NOT-ELIGIBLE(KD-122): witness $WITNESS has no SMOKE_RECEIPT line — not an in-browser witness; run node popcorn_demo/scripts/browser_smoke.mjs (exit 3)" >&2
  exit 3
fi
echo "smoke-line: $SMOKE_LINE"
if echo "$SMOKE_LINE" | grep -q "blob=SKIP"; then
  echo "NOT-ELIGIBLE(KD-122): SMOKE_RECEIPT line reports blob=SKIP — browser blob leg still skipping (exit 3)" >&2
  exit 3
fi
if ! echo "$SMOKE_LINE" | grep -q "blob=OK"; then
  echo "NOT-ELIGIBLE(KD-122): SMOKE_RECEIPT line has no blob=OK (browser blob leg not yet OK; host-leg blob=OK does not count) (exit 3)" >&2
  exit 3
fi

echo "ELIGIBLE(KD-122): SMOKE_RECEIPT line postdates shim and carries blob=OK (no blob=SKIP) — invoking kd_flip.py --apply"
# (3) flip only via the tool; typed refusal if it cannot cover this register
if OUT=$(python3 scripts/kd_flip.py --apply 2>&1); then
  echo "$OUT"
  # A no-op apply ("nothing FLIP-ELIGIBLE; register unchanged") is NOT a flip:
  # verify the canonical row actually shows CLOSED, else refuse loudly.
  if echo "$OUT" | grep -q "flipped.*$KD_ID"; then
    if grep -q "| KD-122 |.*CLOSED" docs/jira/v26.10.14/KNOWN_DIVERGENCES.md; then
      echo "FLIP-DONE(KD-122): register updated via kd_flip.py — row CLOSED, witness named"
      exit 0
    fi
    echo "REFUSED(KD-122): kd_flip reported a flip but the canonical row is not CLOSED" >&2
    exit 1
  fi
  echo "REFUSED(KD-122): kd_flip.py ran but flipped nothing (no-op apply is not a flip)" >&2
  exit 3
else
  RC=$?
  echo "REFUSED(KD-122): kd_flip.py --apply exited $RC; output:" >&2
  echo "$OUT" >&2
  echo "MISSING: v26.10.20 pointer-file coverage by scripts/kd_flip.py (or witness not registered as evidence path) — no hand edit performed" >&2
  exit 3
fi
