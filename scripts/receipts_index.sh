#!/usr/bin/env bash
# receipts_index.sh — one table over every receipt surface in this repo.
# Surfaces (each optional; absent = reported, never silently skipped):
#   1. receipts/                                    (docs/jira/posh/v26.10.30/receipts/** here)
#   2. gaps/*-*.md                                  (verdict from status line)
#   3. tmp/posh/                                    (andon.jsonl tail, r-receipt.json, court receipts)
#   4. posh/var/andon.jsonl
#   5. .ggen-v2/receipt-log.jsonl (tail)
#   6. scripts/receipts/                            (adapter receipts)
# Usage: scripts/receipts_index.sh [--emit-index]
#   --emit-index : also regenerate receipts/INDEX.md (GENERATED file)

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

EMIT_INDEX=0
[ "${1:-}" = "--emit-index" ] && EMIT_INDEX=1

TMP_OUT="$(mktemp)"
trap 'rm -f "$TMP_OUT"' EXIT

HEX='[0-9a-fA-F]{40}'

# row: date<TAB>subject/SHA<TAB>verdict<TAB>path
add_row() { printf '%s\t%s\t%s\t%s\n' "$1" "$2" "$3" "$4" >> "$TMP_OUT"; }

# --- surface 1: receipts/ tree -------------------------------------------
if [ -d receipts ]; then
  while IFS= read -r -d '' f; do
    d=$(stat -f '%Sm' -t '%Y-%m-%d %H:%M' "$f")
    sha=$(grep -oE "$HEX" "$f" 2>/dev/null | head -1 || true)
    subj=$(basename "$f")
    verdict=$(grep -oE '\b(GREEN|RED|PLANNED|ALIVE|BLOCKED|PARTIAL|CONFORMANT|FAIL|PASS)\b' "$f" 2>/dev/null | head -1 || true)
    [ -z "$verdict" ] && verdict=-
    add_row "$d" "${sha:-$subj}" "$verdict" "$f"
  done < <(find receipts -type f -print0 2>/dev/null)
fi

# --- surface 2: gaps/*-*.md ----------------------------------------------
if [ -d gaps ]; then
  for f in gaps/*-*.md; do
    [ -e "$f" ] || continue
    d=$(stat -f '%Sm' -t '%Y-%m-%d %H:%M' "$f")
    sha=$(grep -oE "$HEX" "$f" 2>/dev/null | head -1 || true)
    verdict=$(grep -m1 -oE '\b(ALIVE|PARTIAL|BLOCKED|REFUSED|UNVERIFIED|GREEN|RED|PLANNED)\b' "$f" 2>/dev/null || true)
    [ -z "$verdict" ] && verdict=-
    add_row "$d" "${sha:-$(basename "$f")}" "$verdict" "$f"
  done
fi

# --- surfaces 3+4: andon.jsonl (tmp/posh and posh/var), r-receipt, courts --
for ad in tmp/posh/andon.jsonl posh/var/andon.jsonl; do
  [ -f "$ad" ] || continue
  d=$(stat -f '%Sm' -t '%Y-%m-%d %H:%M' "$ad")
  tail -5 "$ad" | while IFS= read -r line; do
    ts=$(printf '%s' "$line" | grep -oE '"(ts|timestamp|time)"[[:space:]]*:[[:space:]]*"[^"]+"' | head -1 | sed 's/.*: *"//;s/"$//')
    sha=$(printf '%s' "$line" | grep -oE "\"[0-9a-fA-F]{40}\"" | head -1 | tr -d '"')
    verdict=$(printf '%s' "$line" | grep -oE '"(status|verdict|level)"[[:space:]]*:[[:space:]]*"[^"]+"' | head -1 | sed 's/.*: *"//;s/"$//')
    [ -z "$verdict" ] && verdict=-
    add_row "${ts:-$d}" "${sha:-$(basename "$ad")}" "$verdict" "$ad (tail)"
  done
done

for f in tmp/posh/r-receipt.json tmp/posh/*court*.json tmp/posh/*receipt*; do
  [ -e "$f" ] || continue
  case "$f" in *.jsonl) continue;; esac
  d=$(stat -f '%Sm' -t '%Y-%m-%d %H:%M' "$f")
  sha=$(grep -oE "$HEX" "$f" 2>/dev/null | head -1 || true)
  verdict=$(grep -oE '"(verdict|status)"[[:space:]]*:[[:space:]]*"[^"]+"' "$f" 2>/dev/null | head -1 | sed 's/.*: *"//;s/"$//')
  [ -z "$verdict" ] && verdict=-
  add_row "$d" "${sha:-$(basename "$f")}" "$verdict" "$f"
done 2>/dev/null

# --- surface 5: .ggen-v2/receipt-log.jsonl tail ---------------------------
if [ -f .ggen-v2/receipt-log.jsonl ]; then
  d=$(stat -f '%Sm' -t '%Y-%m-%d %H:%M' .ggen-v2/receipt-log.jsonl)
  tail -5 .ggen-v2/receipt-log.jsonl | while IFS= read -r line; do
    ts=$(printf '%s' "$line" | grep -oE '"(ts|timestamp)"[[:space:]]*:[[:space:]]*"[^"]+"' | head -1 | sed 's/.*: *"//;s/"$//')
    sha=$(printf '%s' "$line" | grep -oE '"[0-9a-fA-F]{40}"' | head -1 | tr -d '"')
    verdict=$(printf '%s' "$line" | grep -oE '"(status|verdict)"[[:space:]]*:[[:space:]]*"[^"]+"' | head -1 | sed 's/.*: *"//;s/"$//')
    [ -z "$verdict" ] && verdict=-
    add_row "${ts:-$d}" "${sha:-receipt-log}" "$verdict" ".ggen-v2/receipt-log.jsonl (tail)"
  done
fi

# --- surface 6: scripts/receipts/ -----------------------------------------
if [ -d scripts/receipts ]; then
  while IFS= read -r -d '' f; do
    d=$(stat -f '%Sm' -t '%Y-%m-%d %H:%M' "$f")
    sha=$(grep -oE "$HEX" "$f" 2>/dev/null | head -1 || true)
    verdict=$(grep -m1 -oE '\b(ALIVE|PARTIAL|BLOCKED|REFUSED|UNVERIFIED|GREEN|RED|PLANNED)\b' "$f" 2>/dev/null || true)
    [ -z "$verdict" ] && verdict=-
    add_row "$d" "${sha:-$(basename "$f")}" "$verdict" "$f"
  done < <(find scripts/receipts -type f -print0 2>/dev/null)
fi

# --- render ---------------------------------------------------------------
echo "receipts index — $(date -u '+%Y-%m-%dT%H:%M:%SZ') — repo $(git rev-parse --short HEAD 2>/dev/null || echo unknown)"
echo
echo "surfaces:"
surf() { if [ -e "$1" ]; then n=$(find "$1" -type f 2>/dev/null | wc -l | tr -d ' '); echo "  PRESENT ($n files)  $1"; else echo "  MISSING            $1"; fi; }
surf receipts
surf gaps
surf tmp/posh
surf posh/var/andon.jsonl
surf .ggen-v2/receipt-log.jsonl
surf scripts/receipts
echo
printf '%-17s | %-42s | %-12s | %s\n' "DATE" "SUBJECT/SHA" "VERDICT" "PATH"
printf '%s\n' "$(printf '%.0s-' {1..130})"
sort -t$'\t' -k1,1r "$TMP_OUT" | awk -F'\t' '{ printf "%-17s | %-42.42s | %-12.12s | %s\n", $1, substr($2,1,42), substr($3,1,12), $4 }'

if [ "$EMIT_INDEX" = 1 ]; then
  mkdir -p receipts
  {
    echo "<!-- GENERATED by scripts/receipts_index.sh --emit-index — do not hand-edit. Regenerate: scripts/receipts_index.sh --emit-index -->"
    echo
    echo "# Receipts Index"
    echo
    printf '%-17s | %-42s | %-12s | %s\n' "DATE" "SUBJECT/SHA" "VERDICT" "PATH"
    printf '%s\n' "$(printf '%.0s-' {1..130})"
    sort -t$'\t' -k1,1r "$TMP_OUT" | awk -F'\t' '{ printf "%-17s | %-42.42s | %-12.12s | %s\n", $1, substr($2,1,42), substr($3,1,12), $4 }'
  } > receipts/INDEX.md
  echo
  echo "wrote receipts/INDEX.md"
fi
