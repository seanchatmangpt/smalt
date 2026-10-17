#!/usr/bin/env bash
# post-commit-checklist.sh — smalt v26.10.16 terminal-window post-commit executor (lane T17).
#
# Prepared, NOT executed, by lane T17 (docs-only). The coordinator runs this
# AFTER the wrap commits land (step 1's arithmetic needs the family commits in
# history) and after `just court-x2` (run-8) has a real verdict.
#
# Usage: bash docs/jira/v26.10.16/post-commit-checklist.sh <run8-verdict>
#   <run8-verdict> = PASS        -> spec Variant A flips (ALIVE standing)
#                     any other  -> spec Variant B flips (BUILD_BROKEN + verdict line)
#
# This script NEVER runs `git commit` or `git tag`. Step 5 only PRINTS the tag
# command; the coordinator runs it. Every step is idempotent — re-running on an
# already-flipped tree is a per-step no-op.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
cd "$ROOT"

WIN="docs/jira/v26.10.16"
FINAL="$WIN/FINAL.md"
CHANGELOG="CHANGELOG.md"
RELNOTES="docs/RELEASE_NOTES_v26.10.16.md"

VERDICT="${1:-}"
if [[ -z "$VERDICT" ]]; then
  echo "usage: $0 <run8-court-x2-verdict>  (PASS | <non-PASS verdict string>)" >&2
  exit 64
fi

for f in "$FINAL" "$CHANGELOG" "$RELNOTES"; do
  if [[ ! -f "$f" ]]; then
    echo "ABORT: required file missing: $ROOT/$f" >&2
    exit 66
  fi
done

echo "== [step 0] environment =="
echo "repo:     $ROOT"
echo "HEAD:     $(git rev-parse HEAD)"
echo "verdict:  $VERDICT"

# ---------------------------------------------------------------------------
echo "== [step 1] resolve FINAL.md PENDING-POST-COMMIT sites =="
LANDING_HASH="$(git log --format='%H' -1)"
LANDING_SUBJ="$(git log --format='%s' -1)"
FILE_COUNT="$(git diff --stat HEAD~10..HEAD | tail -1)"
PUSH_RANGE="$(git log --format='%H' -10 | tail -1)..$(git rev-parse HEAD)"
echo "landing hash:  $LANDING_HASH ($LANDING_SUBJ)"
echo "file count:    $FILE_COUNT"
echo "push range:    $PUSH_RANGE"
if grep -q 'PENDING-POST-COMMIT' "$FINAL"; then
  TMP="$(mktemp)"
  sed "s|PENDING-POST-COMMIT\*\* — landing commit hash, file count, and push range cannot exist until the wrap commits land; the fin sweep fills this line after them. No commit SHA is minted here.|${LANDING_HASH}** — landing commit ${LANDING_HASH:0:7} (${LANDING_SUBJ}); ${FILE_COUNT}; push range ${PUSH_RANGE}.|" \
    "$FINAL" > "$TMP"
  mv "$TMP" "$FINAL"
  echo "-- FINAL.md Commit SHAs line after fill:"
  grep -n 'Commit SHAs' "$FINAL" | head -2
else
  echo "(no PENDING-POST-COMMIT remains — step 1 idempotent no-op)"
fi

# ---------------------------------------------------------------------------
echo "== [step 2] release-flip-spec edits (verdict=$VERDICT) =="

# 2a. CHANGELOG heading: drop " — UNRELEASED" (spec §1)
if grep -q '## \[26\.10\.16\] - 2026-10-16 — UNRELEASED' "$CHANGELOG"; then
  TMP="$(mktemp)"
  sed 's|## \[26\.10\.16\] - 2026-10-16 — UNRELEASED|## [26.10.16] - 2026-10-16|' "$CHANGELOG" > "$TMP"
  mv "$TMP" "$CHANGELOG"
  echo "CHANGELOG heading flipped (UNRELEASED dropped)."
else
  echo "CHANGELOG heading already flipped or absent (no-op)."
fi

# 2b. CHANGELOG Status sentence per spec §1 (Variant A on PASS, B otherwise)
if grep -q 'Status: pre-court-x2' "$CHANGELOG"; then
  TMP="$(mktemp)"
  if [[ "$VERDICT" == "PASS" ]]; then
    sed 's|Status: pre-court-x2 — standing flips only.*|Status: released 2026-10-16; two-green court-x2 receipt in `docs/jira/v26.10.16/FINAL.md`.|' "$CHANGELOG" > "$TMP"
  else
    sed "s|Status: pre-court-x2 — standing flips only.*|Status: court-x2 run-8 verdict: ${VERDICT}|" "$CHANGELOG" > "$TMP"
  fi
  mv "$TMP" "$CHANGELOG"
  echo "CHANGELOG Status sentence rewritten per verdict."
else
  echo "CHANGELOG Status sentence already flipped or absent (no-op)."
fi

# 2c. RELEASE_NOTES standing line (spec §2). Variant B quotes the real verdict
# verbatim — the applier passes it as $1; nothing is substituted for output.
if grep -q 'PARTIAL_ALIVE pre-court-x2' "$RELNOTES"; then
  TMP="$(mktemp)"
  if [[ "$VERDICT" == "PASS" ]]; then
    sed 's|Standing for this document: \*\*PARTIAL_ALIVE pre-court-x2\*\* — the|Standing for this document: **ALIVE** — two-green court-x2 receipt landed|' "$RELNOTES" > "$TMP"
    TMP2="$(mktemp)"
    sed 's|^standing line flips only on the two-green receipt\.$|2026-10-16; see `docs/jira/v26.10.16/FINAL.md` court-x2 line.|' "$TMP" > "$TMP2"
    mv "$TMP2" "$TMP"
  else
    sed "s|Standing for this document: \*\*PARTIAL_ALIVE pre-court-x2\*\* — the|Standing for this document: **BUILD_BROKEN** — court-x2 run-8 verdict \"${VERDICT}\"|" "$RELNOTES" > "$TMP"
    TMP2="$(mktemp)"
    sed 's|^standing line flips only on the two-green receipt\.$|2026-10-16; see `docs/jira/v26.10.16/FINAL.md` court-x2 line.|' "$TMP" > "$TMP2"
    mv "$TMP2" "$TMP"
  fi
  mv "$TMP" "$RELNOTES"
  echo "RELEASE_NOTES standing line flipped (verdict=$VERDICT)."
else
  echo "RELEASE_NOTES standing line already flipped or absent (no-op)."
fi

# ---------------------------------------------------------------------------
echo "== [step 3] receipt-index final regen =="
python3 scripts/receipt_index.py
echo "receipt_index.py regen complete (SUSPECT flags above are expected-informational, not step failures)."

# ---------------------------------------------------------------------------
echo "== [step 4] just docs-dod-check =="
just docs-dod-check
echo "docs-dod-check exit: $?"

# ---------------------------------------------------------------------------
echo "== [step 5] tag command for the coordinator (printed, NOT run) =="
echo "Coordinator-run command:"
echo "  git tag -a v26.10.16 -m 'smalt v26.10.16 — court-x2 run-8 verdict: ${VERDICT}; landing $(git rev-parse --short HEAD)'"
echo "done."
