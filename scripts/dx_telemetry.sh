#!/usr/bin/env bash
# dx_telemetry.sh — append-only DX telemetry (lane 13, gaps/66)
# Usage (source this file, then call):
#   dx_event <gate> <outcome(pass|fail|skip)> <elapsed_ms> [subject_sha]
# Appends one JSONL row to posh/var/dx-events.jsonl. Never fails the caller:
# telemetry errors go to stderr and return 0 so a gate is not flipped by its logger.
set -u

DX_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DX_LOG="$DX_ROOT/posh/var/dx-events.jsonl"

dx_event() {
  local gate="$1" outcome="$2" elapsed_ms="$3"
  local subject_sha="${4:-}"
  [ -z "$subject_sha" ] && subject_sha="$(git -C "$DX_ROOT" rev-parse HEAD 2>/dev/null || echo unknown)"
  local ts
  ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  if ! printf '{"ts":"%s","gate":"%s","outcome":"%s","elapsed_ms":%s,"subject_sha":"%s","backfilled":false}\n' \
      "$ts" "$gate" "$outcome" "$elapsed_ms" "$subject_sha" \
      >> "$DX_LOG" 2>/dev/null; then
    mkdir -p "$(dirname "$DX_LOG")" 2>/dev/null
    printf '{"ts":"%s","gate":"%s","outcome":"%s","elapsed_ms":%s,"subject_sha":"%s","backfilled":false}\n' \
      "$ts" "$gate" "$outcome" "$elapsed_ms" "$subject_sha" >> "$DX_LOG" 2>/dev/null \
      || echo "dx_event: failed to append to $DX_LOG" >&2
  fi
  return 0
}
