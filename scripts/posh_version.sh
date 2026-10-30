#!/usr/bin/env bash
# posh_version.sh — version coherence table (lane 14, gaps/67)
# Prints component | version | source file | owning-tree git SHA, plus the
# subject-SHA line (smalt HEAD) for receipt discipline. Skew (charter vs mix
# version, unstamped binaries) is WARN, never FAIL — they legitimately differ.
set -u

SALT_ROOT="${SALT_ROOT:-$HOME/smalt}"
CONSUMER_ROOT="$(cd "$(dirname "$0")/.." && pwd)"

smalt_sha() { git -C "$SALT_ROOT" rev-parse HEAD 2>/dev/null || echo "UNKNOWN"; }
az_sha()    { git -C "$CONSUMER_ROOT" rev-parse HEAD 2>/dev/null || echo "UNKNOWN"; }

smalt_ver() {
  grep -E '@version' "$SALT_ROOT/mix.exs" 2>/dev/null | head -1 | sed 's/.*"\(.*\)".*/\1/'
}
posh_ver() {
  # posh has no static version: Makefile stamps `git describe` at build time.
  ( cd "$SALT_ROOT/posh" && git describe --tags --always --dirty 2>/dev/null ) || echo "UNKNOWN"
}
provider_ver() {
  sed -n 's/^var version = "\(.*\)"/\1/p' \
    "$SALT_ROOT/adapters/terraform-provider-smalt/main.go" 2>/dev/null | head -1
}
charter_ver() {
  head -1 "$SALT_ROOT/docs/jira/posh/v26.10.30/00-charter.md" 2>/dev/null \
    | sed 's/.*(\(v[0-9.]*\)).*/\1/'
}

MIXV="$(smalt_ver)";   [ -n "$MIXV" ]    || MIXV="UNKNOWN"
POSHV="$(posh_ver)";   [ -n "$POSHV" ]   || POSHV="UNKNOWN"
PROVV="$(provider_ver)"; [ -n "$PROVV" ] || PROVV="UNKNOWN"
CHV="$(charter_ver)";  [ -n "$CHV" ]     || CHV="UNKNOWN"

SSHA="$(smalt_sha)"; ASHA="$(az_sha)"

echo "component                     | version              | source file                                | tree SHA"
echo "------------------------------+----------------------+--------------------------------------------+------------------"
printf '%-30s| %-20s| %-42s| %s\n' "smalt"            "$MIXV"  "mix.exs @version"                              "${SSHA:0:12}"
printf '%-30s| %-20s| %-42s| %s\n' "posh"             "$POSHV" "posh/Makefile VERSION (git describe stamp)"    "${SSHA:0:12}"
printf '%-30s| %-20s| %-42s| %s\n' "tf-provider-smalt" "$PROVV" "adapters/terraform-provider-smalt/main.go:28"  "${SSHA:0:12}"
printf '%-30s| %-20s| %-42s| %s\n' "posh-charter"     "$CHV"   "docs/jira/posh/v26.10.30/00-charter.md:1"      "${SSHA:0:12}"
printf '%-30s| %-20s| %-42s| %s\n' "courtroom-az"     "(none)" "(consumer tree; no version declared)"          "${ASHA:0:12}"

echo ""
echo "SUBJECT-SHA (smalt HEAD): $SSHA"

# --- skew notes (WARN, not FAIL) ---
echo ""
if [ -n "$MIXV" ] && [ -n "$CHV" ] && [ "$CHV" != "v$MIXV" ]; then
  echo "WARN skew: charter $CHV vs smalt mix.exs $MIXV — legitimate (charter is the posh v26.10.30 milestone label, not a release version)."
fi
if [ "$PROVV" = "dev" ]; then
  echo "WARN skew: terraform-provider-smalt version is the hardcoded 'dev' (main.go:28); stamp via -ldflags \"-X main.version=\$(git describe --tags --always)\" at build. Disclosed one-liner, not landed this lane."
fi
if [ "$POSHV" = "UNKNOWN" ]; then
  echo "WARN skew: posh version unresolvable — Makefile git describe failed outside a git tree."
fi
echo "NOTE: posh carries no static version anywhere in-tree (go.mod declares only the module path; go1.26.0 toolchain). The 'posh 0.1.0' in the lane brief is not present in the tree — build-time git-describe stamp is the only version identity."
echo "NOTE (consumed-by): final-wave receipts should cite this table via 'just version' output verbatim, keyed on the SUBJECT-SHA line."
