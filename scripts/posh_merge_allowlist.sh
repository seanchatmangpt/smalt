#!/usr/bin/env bash
# posh_merge_allowlist.sh — GAP-29 lane 42 (2026-10-30). HAND-WRITTEN RESIDUE,
# disclosed: this is the one non-generated script in the allowlist projection
# path; the merge LAW it enforces is graph-is-ceiling: every operator posh.yaml
# egress_allowlist entry must be a member of the graph-projected fragment set
# (generated/posh/config/egress_allowlist.generated.yaml). Operator may narrow,
# never widen. Exit 1 naming any widening entry.
#
# Usage: posh_merge_allowlist.sh --fragment <generated.yaml> --config <posh.yaml>
# Hand-written residue disclosed per G29 §1/§3; also validates fragment entries
# are bare hostnames (no / : @ space) — a residual separator means the REPLACE
# pipeline leaked and generation must fail loudly.
set -euo pipefail

fragment="" config=""
while [ $# -gt 0 ]; do
  case "$1" in
    --fragment) fragment="$2"; shift 2 ;;
    --config)   config="$2"; shift 2 ;;
    *) echo "[POSH-MERGE-FAIL] unknown arg $1 — usage: posh_merge_allowlist.sh --fragment <graph-projected fragment> --config <posh.yaml>" >&2; exit 1 ;;
  esac
done
[ -n "$fragment" ] && [ -n "$config" ] || { echo "[POSH-MERGE-FAIL] --fragment and --config required" >&2; exit 1; }
[ -f "$fragment" ] || { echo "[POSH-MERGE-FAIL] fragment missing: $fragment" >&2; exit 1; }
[ -f "$config" ] || { echo "[POSH-MERGE-FAIL] config missing: $config" >&2; exit 1; }

# --- Extract fragment hosts (lines of the form "- host") ---------------------
frag_hosts=$(grep -E '^- ' "$fragment" | sed -E 's/^- //' | tr -d '[:space:]')
frag_count=$(printf '%s\n' "$frag_hosts" | grep -c . || true)

# --- Loud guard: fragment entries must be bare hostnames ---------------------
while IFS= read -r h; do
  [ -n "$h" ] || continue
  case "$h" in
    *[/:@' ']*)
      echo "[POSH-MERGE-FAIL] fragment entry '$h' still contains / : @ or space — REPLACE normalization leaked (graph defect, fail loud)" >&2
      exit 1 ;;
  esac
done <<< "$frag_hosts"

# --- Extract operator posh.yaml egress_allowlist entries --------------------
cfg_hosts=$(awk '
  /^[[:space:]]*egress_allowlist:/ {
    sub(/^[[:space:]]*egress_allowlist:[[:space:]]*/, "")
    # inline forms: [] or [a, b]
    if ($0 ~ /^\[/) {
      gsub(/[\[\]]/, "")
      if (length($0) > 0) {
        n = split($0, parts, /,[[:space:]]*/)
        for (i = 1; i <= n; i++) print parts[i]
      }
      exit
    }
    inlist = 1; next
  }
  inlist && /^[[:space:]]*-[[:space:]]/ {
    sub(/^[[:space:]]*-[[:space:]]*/, ""); gsub(/[[:space:]]/, ""); print; next
  }
  inlist { exit }
' "$config")
cfg_count=$(printf '%s\n' "$cfg_hosts" | grep -c . || true)

# --- Merge law: config ⊆ fragment (narrow-only) -----------------------------
rc=0
while IFS=-r read -r h; do
  [ -n "$h" ] || continue
  if ! printf '%s\n' "$frag_hosts" | grep -Fxq -- "$h"; then
    echo "[POSH-MERGE-FAIL] operator posh.yaml egress_allowlist entry '$h' is NOT in the graph-projected set — widening (graph is the ceiling; narrow only)" >&2
    rc=1
  fi
done <<< "$cfg_hosts"

if [ "$rc" -ne 0 ]; then
  echo "[POSH-MERGE-FAIL] ceiling violation: $cfg_count operator entries checked against $frag_count graph-projected hosts" >&2
  exit 1
fi
echo "[POSH-MERGE] PASS: $cfg_count operator entries ⊆ $frag_count graph-projected hosts (ceiling law holds)"
