#!/usr/bin/env bash
# close_kd.sh <KD-nn> [--fragment "label=OK"] — receipt-gated KD closure.
# Generalization of close_kd122.sh (the KD-122 precedent stays as reference).
# Standing: the flip is decided by evidence, never hand-declared.
#
# Eligibility law (parameterized from the KD-122 precedent):
#   1. register row for <KD-nn> in docs/jira/v26.10.14/KNOWN_DIVERGENCES.md
#      must exist and be OPEN (already-CLOSED = loud refusal, exit 1).
#   2. shim token check: some file under lib/ carries `# KD-COVERS: <KD-nn>`.
#      Absent -> exit 3 (PINION/OBSOLETE rows have no shim, never flip-eligible).
#   3. witness gate: newest docs/jira/v26.10.20/receipts/*witness*.md naming
#      <KD-nn>, mtime > newest shim mtime, AND its SMOKE_RECEIPT line (or the
#      whole file when no SMOKE_RECEIPT line exists) carries <fragment>=OK and
#      not <fragment>=SKIP. Fragment default: blob=OK for blob-family rows
#      (per the KD-122 precedent — host-leg OK does not count), live=OK
#      otherwise; overridable with --fragment.
#   4. flip ONLY via `python3 scripts/kd_flip.py --apply`; verify the canonical
#      row actually went CLOSED. A no-op apply is NOT a flip (close_kd122
#      false-DONE lesson) — loud refusal.
#
# Exit codes: 0 flip-done | 1 error (refused) | 3 not-eligible-loud
set -euo pipefail

REPO="${REPO:-/Users/sac/smalt}"
REGISTER="docs/jira/v26.10.14/KNOWN_DIVERGENCES.md"
RECEIPT_GLOB="docs/jira/v26.10.20/receipts"

KD_ID="${1:-}"
FRAGMENT=""
BLOB_FAMILY=0

if [ -z "$KD_ID" ]; then
  echo "usage: close_kd.sh <KD-nn> [--fragment \"label=OK\"]" >&2
  exit 1
fi
shift || true
while [ $# -gt 0 ]; do
  case "$1" in
    --fragment) FRAGMENT="${2:-}"; shift 2 ;;
    *) echo "REFUSED($KD_ID): unknown argument '$1'" >&2; exit 1 ;;
  esac
done

cd "$REPO"

# ---- (1) canonical register row, status OPEN -------------------------------
ROW=$(grep -m1 "^| $KD_ID |" "$REGISTER" || true)
if [ -z "$ROW" ]; then
  echo "REFUSED($KD_ID): no canonical row in $REGISTER — register and KD-COVERS tokens are out of sync; run scripts/kd_flip.py (read-only) to list unknown tokens, register the row first. No flip performed." >&2
  exit 1
fi
STATUS_CELL=$(printf '%s' "$ROW" | awk -F'|' '{c=$(NF-1); gsub(/ /,"",c); print c}')
case "$STATUS_CELL" in
  OPEN*) : ;;  # includes "OPEN — ..." prose tails
  CLOSED*)
    echo "REFUSED($KD_ID): register row is already $STATUS_CELL — nothing to close (no-op is not a flip)" >&2
    exit 1 ;;
  *)
    echo "REFUSED($KD_ID): unrecognized register status '$STATUS_CELL' — refusing to act" >&2
    exit 1 ;;
esac
echo "register: $KD_ID status=OPEN"

# ---- (2) shim token under lib/ ---------------------------------------------
SHIM_FILE=$(grep -rl "KD-COVERS: $KD_ID" lib/ 2>/dev/null | head -1 || true)
if [ -z "$SHIM_FILE" ]; then
  echo "NOT-ELIGIBLE($KD_ID): no '# KD-COVERS: $KD_ID' token anywhere under lib/ — PINION/OBSOLETE rows carry no shim and are never flip-eligible (exit 3)" >&2
  exit 3
fi
SHIM_MT=$(stat -f %m "$SHIM_FILE")
echo "shim: $SHIM_FILE mtime=$SHIM_MT ($(date -r "$SHIM_MT" '+%F %T %Z'))"

# ---- (3) witness gate -------------------------------------------------------
# fragment default: blob-family -> blob=OK, else live=OK
if [ -z "$FRAGMENT" ]; then
  case "$ROW" in
    *[Bb]lob*) BLOB_FAMILY=1 ;;
    *)
      case "$SHIM_FILE" in
        *blob*) BLOB_FAMILY=1 ;;
      esac ;;
  esac
  if [ "$BLOB_FAMILY" -eq 1 ]; then FRAGMENT="blob=OK"; else FRAGMENT="live=OK"; fi
fi
echo "fragment: $FRAGMENT"

[ -f scripts/kd_flip.py ] || { echo "REFUSED($KD_ID): missing scripts/kd_flip.py" >&2; exit 1; }

WITNESS=$(ls -t "$RECEIPT_GLOB"/*witness*.md 2>/dev/null | xargs grep -l "$KD_ID" 2>/dev/null | head -1 || true)
if [ -z "$WITNESS" ]; then
  echo "NOT-ELIGIBLE($KD_ID): no $RECEIPT_GLOB/*witness*.md names $KD_ID — no witness receipt exists yet (exit 3)" >&2
  exit 3
fi
W_MT=$(stat -f %m "$WITNESS")
echo "witness: $WITNESS mtime=$W_MT ($(date -r "$W_MT" '+%F %T %Z'))"

if [ "$W_MT" -le "$SHIM_MT" ]; then
  echo "NOT-ELIGIBLE($KD_ID): witness mtime ($W_MT) does not postdate shim mtime ($SHIM_MT); substrate restart with the fix has not been witnessed yet (exit 3)" >&2
  exit 3
fi

SMOKE_LINE=$(grep '^SMOKE_RECEIPT:' "$WITNESS" | tail -1 || true)
if [ -n "$SMOKE_LINE" ]; then
  echo "smoke-line: $SMOKE_LINE"
  GATE_TEXT="$SMOKE_LINE"
else
  GATE_TEXT=$(cat "$WITNESS")
fi
if echo "$GATE_TEXT" | grep -q "${FRAGMENT%%=*}=SKIP"; then
  echo "NOT-ELIGIBLE($KD_ID): witness gate text reports ${FRAGMENT%%=*}=SKIP — leg still skipping (exit 3)" >&2
  exit 3
fi
if ! echo "$GATE_TEXT" | grep -q "$FRAGMENT"; then
  echo "NOT-ELIGIBLE($KD_ID): witness gate text has no $FRAGMENT (host-leg OK does not count) (exit 3)" >&2
  exit 3
fi

echo "ELIGIBLE($KD_ID): witness postdates shim and gate text carries $FRAGMENT (no SKIP) — invoking kd_flip.py --apply"

# ---- (4) flip only via the tool, verify, refuse no-op ----------------------
if OUT=$(python3 scripts/kd_flip.py --apply 2>&1); then
  echo "$OUT"
  if echo "$OUT" | grep -q "flipped.*$KD_ID"; then
    if grep -q "^| $KD_ID |.*CLOSED" "$REGISTER"; then
      echo "FLIP-DONE($KD_ID): register updated via kd_flip.py — row CLOSED, witness named"
      exit 0
    fi
    echo "REFUSED($KD_ID): kd_flip reported a flip but the canonical row is not CLOSED" >&2
    exit 1
  fi
  echo "REFUSED($KD_ID): kd_flip.py ran but flipped nothing for $KD_ID (no-op apply is not a flip)" >&2
  exit 3
else
  RC=$?
  echo "REFUSED($KD_ID): kd_flip.py --apply exited $RC; output:" >&2
  echo "$OUT" >&2
  echo "MISSING: tool coverage/refusal detail above — no hand edit performed" >&2
  exit 3
fi
