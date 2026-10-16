#!/usr/bin/env bash
# Naming/leak sweep — pre-publication contamination audit (mechanized).
# Implements docs/NAMING_SWEEP.md's grep as a fail-closed gate:
#   exit 0 = every hit covered by the line-precise allowlist below
#   exit 1 = at least one hit NOT covered by the allowlist
# Sweeps git-tracked files only, excluding machine-receipt and self-quote
# surfaces (deps/, _build/, .git/, tmp/, .elixir_ls/, docs/NAMING_SWEEP.md,
# .ggen_igniter/, cli/.ggen-v2/, Justfile — the recipe doc comments quote the
# scan terms by design, same meta class as docs/PUBLISH_CHECK.md).

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO"

PATTERN='athena|/Users/sac|courtroom|\bcai\b|morluto'

# Line-precise allowlist (path:line). Hit sets were read off the real tree
# 2026-10-15; see docs/NAMING_SWEEP.md v3 REPORTED-TO-LANE table for classes.
# Classes: .env.example legacy defaults (lane 14 owns cleanup);
# SMALT_SDK_ROOT fallbacks; machine lockfiles/manifests; docs quoting the
# scan terms; redteam/e2e captured receipts; jira work orders quoting terms.
ALLOWLIST=(
  # .env.example legacy personal defaults (REPORTED, lane 14 owns cleanup)
  ".env.example:12"
  ".env.example:15"
  ".env.example:19"
  ".env.example:20"
  ".env.example:24"
  # SMALT_SDK_ROOT fallback paths (REPORTED-TO-LANE, scripts/sdk-smoke owners)
  "scripts/sb_census_replay.sh:21"
  "scripts/dev_env.sh:33"
  "scripts/stress/vs_azurite.py:330"
  "scripts/stress/vs_azurite.py:369"
  "test/sdk-smoke/eh-run.mjs:143"
  # Machine-generated lock/config (ggen lane; regenerated, not hand-edited)
  "cli/ggen.lock:4"
  "cli/ggen.lock:8"
  "cli/ggen.lock:12"
  "cli/ggen.lock:16"
  "cli/ggen.lock:20"
  "cli/ggen.lock:24"
  "cli/ggen.toml:14"
  "cli/ggen.toml:15"
  "cli/ggen.toml:16"
  "cli/ggen.toml:17"
  "cli/ggen.toml:18"
  "cli/ggen.toml:19"
  # docker docs + build receipt (docker docs owner, v2/v3 open item)
  "docker/README.md:42"
  "docker/BUILD_RECEIPT.md:5"
  "docker/BUILD_RECEIPT.md:16"
  "docker/BUILD_RECEIPT.md:17"
  "docker/BUILD_RECEIPT.md:28"
  "docker/BUILD_RECEIPT.md:55"
  # docs quoting the scan terms themselves (meta self-reference).
  # Re-pinned 2026-10-15 after lane 14's scrub/gate pass; see
  # docs/jira/v26.10.14/receipts/14-docs-drift.md for the delta list.
  "docs/PUBLISH_CHECK.md:69"
  "docs/PUBLISH_CHECK.md:173"
  "docs/PUBLISH_CHECK.md:178"
  "docs/PUBLISH_CHECK.md:278"
  "docs/PUBLISH_CHECK.md:281"
  "docs/PUBLISH_CHECK.md:282"
  # jira work orders quoting the scan terms
  "docs/jira/v26.10.14/02-store-lifecycle.md:87"
  "docs/jira/v26.10.14/02-store-lifecycle.md:88"
  "docs/jira/v26.10.14/02-store-lifecycle.md:89"
  "docs/jira/v26.10.14/12-gate-closure.md:22"
  "docs/jira/v26.10.14/12-gate-closure.md:83"
  "docs/jira/v26.10.14/12-gate-closure.md:107"
  "docs/jira/v26.10.14/14-docs-drift.md:15"
  "docs/jira/v26.10.14/14-docs-drift.md:41"
  "docs/jira/v26.10.14/14-docs-drift.md:47"
  "docs/jira/v26.10.14/14-docs-drift.md:53"
  "docs/jira/v26.10.14/14-docs-drift.md:81"
  "docs/jira/v26.10.14/_LANES.md:25"
  # stress-script legacy paths (stress-scripts owner)
  "scripts/stress/telemetry_overhead.py:28"
  # e2e s7/s9 + azapi test comments/fallbacks (e2e owners)
  "test/e2e/s7_worm/run.sh:21"
  "test/e2e/s7_worm/worm.test.cjs:11"
  "test/e2e/s9_lro_chain/lro_chain.test.mjs:2"
  "test/azapi_actions_test.exs:3"
  # captured redteam receipts (redteam lane; captured output, not source)
  "test/redteam/r1_input_fuzz/receipt.txt:2"
  "test/redteam/r2_state/findings.md:4"
  # eh-run.mjs new-file regression line 14 (sdk-smoke owner; :143 above)
  "test/sdk-smoke/eh-run.mjs:14"
)

# 1. Sweep tracked files only, excluding machine/self-quote surfaces.
hits="$(git ls-files -z \
  | grep -zvE '^(deps/|_build/|\.git/|tmp/|\.elixir_ls/|[Jj]ustfile$|docs/NAMING_SWEEP\.md$|\.ggen_igniter/|cli/\.ggen-v2/)' \
  | xargs -0 grep -niE "$PATTERN" 2>/dev/null || true)"

allowed=0
violations=()
while IFS= read -r line; do
  [[ -z "$line" ]] && continue
  # extract file:line (grep -n output is file:line:content)
  file="${line%%:*}"
  rest="${line#*:}"
  lineno="${rest%%:*}"
  key="$file:$lineno"
  found=0
  for entry in "${ALLOWLIST[@]}"; do
    if [[ "$entry" == "$key" ]]; then found=1; break; fi
  done
  if [[ $found -eq 1 ]]; then
    allowed=$((allowed + 1))
  else
    violations+=("$line")
  fi
done <<< "$hits"

# 2. Verdict.
if [[ ${#violations[@]} -gt 0 ]]; then
  echo "[NAMING-SWEEP] VIOLATIONS (${#violations[@]}):"
  printf '  %s\n' "${violations[@]}"
  echo "[NAMING-SWEEP] FAIL: ${#violations[@]} violation(s), $allowed allowed"
  exit 1
fi
echo "[NAMING-SWEEP] PASS: 0 violations / $allowed allowed"
exit 0
