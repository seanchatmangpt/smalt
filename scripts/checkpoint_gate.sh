#!/usr/bin/env bash
# checkpoint_gate.sh — refuse a commit whose STAGED files carry SHIM-COURT markers.
#
# Closes BK-B4VW's typed process hazard (incident: coordinator tick checkpoint
# 44cfa665 landed BK-B4VW's M2 shim in queue_store.ex as real code; fix-forward
# restore 767b9b52). Scans the staged diff for the `SHIM-COURT` marker and
# exits 1 naming file + line if found. Wire as:
#   just checkpoint <msgfile>   (durable path — wraps git commit -F)
# or run standalone before any commit: scripts/checkpoint_gate.sh
#
# Exit codes: 0 clean | 1 SHIM-COURT marker in staged content | 2 usage/git error
set -euo pipefail

MARKER="SHIM-COURT"

cd "$(git rev-parse --show-toplevel)"

# Staged file list (added/copied/modified/renamed); nothing staged => dry pass.
mapfile -t files < <(git diff --cached --name-only --diff-filter=ACMR)
if [ "${#files[@]}" -eq 0 ]; then
    echo "checkpoint-gate: nothing staged — nothing to scan (dry pass)" >&2
    exit 0
fi

# Scan STAGED blob content (git show :path), not the worktree — what lands is
# the index, and a lane's in-flight worktree shim must not gate other lanes.
# Markdown is exempt: receipts/courts legitimately cite the marker string in
# prose. The gate script itself is exempt: its header documents the marker.
# Everything else — a SHIM-COURT marker in executable source — is the hazard.
hits=0
for f in "${files[@]}"; do
    case "$f" in *.md) continue ;; scripts/checkpoint_gate.sh) continue ;; esac
    while IFS= read -r lineno; do
        echo "checkpoint-gate: REFUSED $f:$lineno carries ${MARKER} marker"
        hits=$((hits + 1))
    done < <(git show ":$f" 2>/dev/null | grep -n -F -- "$MARKER" | cut -d: -f1)
done

if [ "$hits" -gt 0 ]; then
    echo "checkpoint-gate: ${hits} marker line(s) in staged files — commit REFUSED." >&2
    echo "  Strip the markers or unstage the file(s), then retry." >&2
    echo "  Register: docs/jira/v26.10.22/receipts/bkshimgate-gate.md" >&2
    exit 1
fi

echo "checkpoint-gate: staged files clean (no SHIM-COURT markers) — OK"
exit 0
