#!/usr/bin/env bash
# Naming/leak sweep — pre-publication contamination audit (mechanized).
# Implements docs/NAMING_SWEEP.md's grep as a fail-closed gate:
#   exit 0 = every hit covered by the line-precise allowlist below
#   exit 1 = at least one hit NOT covered by the allowlist
# Sweeps git-tracked files only, excluding machine-receipt and self-quote
# surfaces (deps/, _build/, .git/, tmp/, .elixir_ls/, docs/archive/ (archived
# evidence docs), docs/NAMING_SWEEP.md's successor classes,
# .ggen_igniter/, cli/.ggen-v2/, Justfile — the recipe doc comments quote the
# scan terms by design, same meta class as docs/archive/PUBLISH_CHECK.md).
#
# Extended (2026-10-16, lane 11 docs-dod): docs/jira/v26.10.16/ (window
# wrap/planning docs — WRAP_LEDGER, PUBLISH_RECORD, release-flip-spec,
# next-window-errc, doctor-receipt*.json machine receipts — same
# evidence/planning-record class as the v26.10.15 exclusion below).
# Also excluded (2026-10-15, lane X-4): docs/jira/*/receipts/ and
# docs/jira/*/sdk-results/ — 163 hits across 80 files. These are evidence
# Extended (2026-10-17, coordinator): docs/jira/*/verify-ledger/ (machine
# verdict ledgers from the 20-wide verify pool quoting captured command
# Extended (2026-10-16, coordinator): docs/jira/*/bench/ (machine JSONL quoting
# absolute stack/series paths — 22-hit class from the C/A bench waves) and
# docs/jira/v26.10.15/ (planning docs citing the checkout root). Same
# evidence/planning-record class: they document the environment they ran in.
# records quoting their own environment (command output, captured paths,
# work-order text), the same tolerated class as .ggen_igniter/ machine
# receipts. Scrubbing would rewrite historical evidence, and the volume
# (163) makes per-line allowlisting impractical; directory-level exclusion
# chosen over normalization. workspace/ was NOT excluded: its 4 hits were
# normalized in place to repo-relative phrasing instead.
# Also excluded as self-quote surfaces (scripts defining/running the scan
# pattern itself, same meta class as docs/archive/NAMING_SWEEP.md / Justfile):
# scripts/naming_sweep.sh (2 hits: PATTERN line + header), scripts/publish_dry.sh
# (2 hits: LEAK_PAT + header comment).

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO"

PATTERN='athena|/Users/sac|courtroom|\bcai\b|morluto'

# Line-precise allowlist (path:line). Hit sets were read off the real tree
# 2026-10-15; see docs/archive/NAMING_SWEEP.md v3 REPORTED-TO-LANE table.
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
  "docker/BUILD_RECEIPT.md:5"
  "docker/BUILD_RECEIPT.md:16"
  "docker/BUILD_RECEIPT.md:17"
  "docker/BUILD_RECEIPT.md:28"
  "docker/BUILD_RECEIPT.md:55"
  # docs quoting the scan terms themselves (meta self-reference).
  # The docs/PUBLISH_CHECK.md:* entries were retired 2026-10-16 when the file
  # moved to docs/archive/ (excluded above as an evidence-record surface);
  # see docs/jira/v26.10.14/receipts/14-docs-drift.md for the original pins.
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
  # KD register rows quoting their own evidence environment (lane 11
  # docs-dod, 2026-10-16): KD-90-era B-leg note + KD-94 row (athena B-leg
  # receipt text). Same evidence-record class as the 12-gate-closure pins.
  "docs/jira/v26.10.14/KNOWN_DIVERGENCES.md:157"
  "docs/jira/v26.10.14/KNOWN_DIVERGENCES.md:252"
    # v26.10.17 window affidavit quotes its run environment (absolute paths)
  # in its evidence-record tables (2026-10-17 relocation into docs/jira/).
  "docs/jira/v26.10.17/AFFIDAVIT-CHANGES-UPGRADES.md:3"
  "docs/jira/v26.10.17/AFFIDAVIT-CHANGES-UPGRADES.md:24"
  "docs/jira/v26.10.17/AFFIDAVIT-CHANGES-UPGRADES.md:25"
  "docs/jira/v26.10.17/AFFIDAVIT-CHANGES-UPGRADES.md:26"
  # stress-script legacy paths (stress-scripts owner)
  "scripts/stress/telemetry_overhead.py:28"
  # e2e s7/s9 + azapi test comments/fallbacks (e2e owners)
  "test/e2e/s7_worm/run.sh:21"
  "test/e2e/s7_worm/worm.test.cjs:11"
  # captured redteam receipts (redteam lane; captured output, not source)
  "test/redteam/r1_input_fuzz/receipt.txt:2"
  "test/redteam/r2_state/findings.md:4"
  # docs/verification/ocel/** are chain-hashed evidence receipts (same
  # exempted class as publish_dry gate 3's OCEL policy) — captured output,
  # not source
  "docs/verification/ocel/anti_llm_cheat_lsp_ocel.json:195"
  # eh-run.mjs :14 entry retired 2026-10-15 (fin-14): REPO is now derived
  # repo-relative via HERE, absolute literal removed.
)

# 1. Sweep tracked files only, excluding machine/self-quote surfaces.
hits="$(git ls-files -z \
  | grep -zvE '^(deps/|_build/|\.git/|tmp/|\.elixir_ls/|[Jj]ustfile$|docs/archive/|docs/NAMING_SWEEP\.md$|\.ggen_igniter/|cli/\.ggen-v2/|docs/jira/[^/]+/receipts/|docs/jira/[^/]+/sdk-results/|docs/jira/[^/]+/bench/|docs/jira/[^/]+/verify-ledger/|docs/jira/v26\.10\.15/|docs/jira/v26\.10\.16/|scripts/naming_sweep\.sh$|scripts/publish_dry\.sh$)' \
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
