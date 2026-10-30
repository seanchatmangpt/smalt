#!/usr/bin/env bash
# posh_sla.sh — run_with_sla gate runner + SLA registry (GAP09 G1 close leg).
# Spec: docs/jira/posh/v26.10.30/gaps/31-sla-clocks.md §1/§2/§3/§5/§6.
# Sourced by posh-court and posh-court-sla-test (justfile.d/58-posh.just).
#
# Exit contract: child exit verbatim, EXCEPT 124 (SLA expiry) -> 1 RED;
# empty/unregistered SLA -> typed refusal exit 2, child never spawned
# (fail-closed: a gate without a clock cannot run). rc-3 SKIP passes through
# untouched — the runner only rewrites 124.

# sla_for <gate-name> — the §2.1 registry (case table). Empty = unregistered.
sla_for() {
  case "$1" in
    infra)      echo 600 ;;  # pre kind ladder: kind-up/images/deploy (container ops)
    build)      echo 60 ;;   # posh-build (charter Build; cold Go cache = measurement debt)
    vet)        echo 10 ;;   # stage 1 golangci-lint x2 trees (charter Lint)
    alloc-test) echo 40 ;;   # stage 2 go test -race posh/ (charter Test)
    static)     echo 10 ;;   # stage 3 go vet provider (charter Lint, warm cache)
    fence)      echo 40 ;;   # stage 4 egress+config -race (charter Test)
    wire)       echo 30 ;;   # stage 5 STS mint + asserts (new row; 4x curl max-time 5)
    e2e)        echo 300 ;;  # stages 6+7 tf lifecycle (new row)
    mutation)   echo 40 ;;   # stage 8 tamper legs (charter Test, NOT Invariant 5s)
    *)          echo "" ;;   # unregistered gate -> default-refuse exit 2
  esac
}

# run_with_sla <gate-name> [sla_seconds] <cmd...>
#   Explicit numeric sla_seconds overrides the registry (fixture legs).
#   Empty/omitted -> registry lookup; still empty -> SLA-REFUSE exit 2.
run_with_sla() {
  local gate="$1"; shift
  local sla=""
  case "${1:-}" in
    ''|*[!0-9]*) ;;                       # not a number -> registry lookup path
    *) sla="$1"; shift ;;
  esac
  if [ -z "$sla" ]; then
    sla=$(sla_for "$gate")
  fi
  if [ -z "$sla" ]; then
    echo "[SLA-REFUSE] gate '$gate' has no registered SLA clock — runner refuses (exit 2)" >&2
    return 2
  fi
  local TO
  TO=$(command -v timeout || command -v gtimeout) || {
    echo "[SLA-REFUSE] gate '$gate': neither timeout nor gtimeout on PATH — a clock that cannot be set is an SLA-less gate (exit 2)" >&2
    return 2
  }
  local t0 rc ms outcome
  t0=$(python3 -c 'import time; print(int(time.time()*1000))')
  "$TO" -k 2 "$sla" "$@"; rc=$?
  ms=$(( $(python3 -c 'import time; print(int(time.time()*1000))') - t0 ))
  outcome=pass
  [ "$rc" -eq 124 ] && outcome=timeout
  [ "$rc" -ne 0 ] && [ "$rc" -ne 124 ] && outcome=fail
  mkdir -p tmp/posh
  printf '{"gate":"%s","outcome":"%s","exit":%d,"elapsed_ms":%d,"sla_ms":%d,"ts":"%s"}\n' \
    "$gate" "$outcome" "$rc" "$ms" $((sla * 1000)) "$(date -u +%FT%TZ)" \
    >> tmp/posh/andon.jsonl
  if [ "$rc" -eq 124 ]; then
    echo "[SLA-RED] $gate exceeded ${sla}s — killed, RED (timeout counts as fail)" >&2
    return 1
  fi
  return "$rc"
}
