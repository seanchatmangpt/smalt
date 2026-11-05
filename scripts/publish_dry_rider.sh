#!/usr/bin/env bash
# publish_dry_rider.sh — WO-10 promotion rider (lane 9, v26.11.6).
# Gate: mix.exs must NOT carry `only:`/`optional:` on the ash_graphlaw dep
# (regression = the dev/test-only posture that WO-10 closed).
# rg fail-loud guard: refuses to fake-pass without ripgrep.
command -v rg >/dev/null 2>&1 || { echo "refusing to fake-pass (no rg)"; exit 2; }

set -u
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

LINE="$(rg -n 'ash_graphlaw' "$REPO/mix.exs" | rg -v '^\s*[0-9]+:\s*#' | head -1)"

if [ -z "$LINE" ]; then
  echo "FAIL: no ash_graphlaw dep line found in mix.exs"
  exit 1
fi

if printf '%s' "$LINE" | rg -q 'only:'; then
  echo "FAIL: ash_graphlaw dep carries only: (WO-10 regression): $LINE"
  exit 1
fi

if printf '%s' "$LINE" | rg -q 'optional:'; then
  echo "FAIL: ash_graphlaw dep carries optional: (WO-10 regression): $LINE"
  exit 1
fi

echo "PASS: ash_graphlaw dep is unconditional (ASH_GRAPHLAW_PATH-relocatable, no only:/optional:)"
exit 0
