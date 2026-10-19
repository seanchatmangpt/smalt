#!/usr/bin/env bash
# court23.sh — one-shot AZB-23 gate executor (pre-positioned; NOT auto-run).
# 1) just quiet-check must exit 0 (quiet window open — colima down)
# 2) just court-x2 with the full log captured to tmp/court-x2-<epoch>.log
# 3) summary line (two run verdicts + failure-set diff when they differ)
#    appended to docs/jira/v26.10.18/receipts/i29-court-x2-final.md
# DRY_RUN=1 echoes the commands instead of executing them.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
RECEIPT="docs/jira/v26.10.18/receipts/i29-court-x2-final.md"
DRY_RUN="${DRY_RUN:-0}"

ts="$(date +%s)"
LOG="tmp/court-x2-${ts}.log"

echo "== AZB-23 gate @ ${ts} =="

# --- 1) quiet window precondition ---
if [ "$DRY_RUN" = "1" ]; then
  echo "[DRY_RUN] just quiet-check"
else
  if ! just quiet-check; then
    echo "REFUSED: quiet-check failed — quiet window not open (colima up?)" >&2
    exit 1
  fi
fi

# --- 2) court-x2 (runs `just court` twice internally) ---
if [ "$DRY_RUN" = "1" ]; then
  echo "[DRY_RUN] just court-x2 >${LOG} 2>&1"
  V1="DRY-RUN"; V2="DRY-RUN"; DIFFNOTE="(dry run — no log parsed)"
else
  just court-x2 >"$LOG" 2>&1
  rc=$?
  echo "[court23] court-x2 exit=${rc} log=${LOG}"

  # --- 3) parse two run verdicts from court_x2.sh's own markers ---
  V1="$(sed -n 's/.*Run 1 summary line: .* — \(GREEN\|NOT GREEN\).*/\1/p' "$LOG" | head -1)"
  V2="$(sed -n 's/.*Run 2 summary line: .* — \(GREEN\|NOT GREEN\).*/\1/p' "$LOG" | head -1)"
  V1="${V1:-UNPARSED}"; V2="${V2:-UNPARSED}"

  # failure sets: court_x2.sh prints "Failing tests — run N:" sections
  F1="$(awk '/Failing tests — run 1:/{f=1;next} /Failing tests — run 2:/{f=0} f' "$LOG" | grep -v '^(none)$' | sed '/^====/,$d' | sort -u)"
  F2="$(awk '/Failing tests — run 2:/{f=1;next} f' "$LOG" | sed '/^====/,$d' | sort -u)"

  if [ "$F1" = "$F2" ]; then
    DIFFNOTE="(failure sets identical)"
  else
    DIFF="$(diff <(printf '%s\n' "$F1") <(printf '%s\n' "$F2") || true)"
    DIFFNOTE="run1!=run2 flake signature: ${DIFF//$'\n'/; }"
  fi
fi

# --- append summary to the final receipt ---
{
  echo ""
  echo "## AZB-23 court-x2 final — ${ts}"
  echo ""
  echo "- run1: ${V1} / run2: ${V2}"
  echo "- ${DIFFNOTE}"
  echo "- log: ${LOG}"
  echo ""
  echo '```'
  echo "${ts} court-x2: run1=${V1} run2=${V2} ${DIFFNOTE}"
  echo '```'
} >>"$RECEIPT"

echo "[court23] summary appended to ${RECEIPT}"
exit 0
