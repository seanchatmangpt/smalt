#!/usr/bin/env bash
# cgroup_suite_runner.sh — AZB-18 in-container offline-suite leg (bash-only;
# the runtime/test images have no python). Runs INSIDE the smalt-burn test
# image with the CURRENT tree mounted over /smalt (test/ + lib/), under the
# compose service's cgroup limits (cpus / mem_limit / pids_limit).
#
# Per cycle: `mix test` (offline tier; :stress excluded per test_helper.exs;
# the suite self-boots on EPHEMERAL ports, so 4 parallel containers in their
# own netns never collide). Parses the ExUnit summary, emits one smalt-burn/v2
# row (stage=soak) per (container, cycle) to
# /burn-results/cgroup-<service>.jsonl, plus the raw leg log for host-side
# FLAKE_LEDGER classification.
#
# Env: BURN_SERVICE, BURN_PLANE, BURN_CYCLES, BURN_CPUS, BURN_MEM,
#      SMALT_BURN_SUBJECT_SHA, BURN_IMAGE_DIGEST.
set -u

SERVICE="${BURN_SERVICE:-smalt-soak-unknown}"
PLANE="${BURN_PLANE:-all}"
CYCLES="${BURN_CYCLES:-1}"
CPUS="${BURN_CPUS:-unrecorded}"
MEM="${BURN_MEM:-unrecorded}"
SUBJ_SHA="${SMALT_BURN_SUBJECT_SHA:-unrecorded}"
IMG_DIGEST="${BURN_IMAGE_DIGEST:-unrecorded}"
RESULTS="${BURN_RESULTS_DIR:-/burn-results}"
JSONL="$RESULTS/cgroup-$SERVICE.jsonl"
mkdir -p "$RESULTS"
: > "$JSONL"

# AZB-03 row emitter (smalt-burn/v2). rc 0 -> CLEAN / else UNHANDLED_EXIT
# (broken_term mu_unlawful). Faces are classified HOST-side against
# docs/jira/v26.10.17/FLAKE_LEDGER.md from the leg logs this script leaves
# beside the rows.
emit() { # emit <cycle> <rc> <tests> <failures> <note>
  _c=$1; _rc=$2
  if [ "$_rc" = 0 ]; then _v=CLEAN; _b=null; _clean=true; else _v=UNHANDLED_EXIT; _b='"mu_unlawful"'; _clean=false; fi
  _now="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  printf '{"schema":"smalt-burn/v2","subject_sha":"%s","image_digest":"%s","container":"%s","plane":"%s","cycle":%s,"stage":"soak","verdict":"%s","t_start":"%s","t_end":"%s","exit_code":%s,"orphans":[],"crash_reports":0,"evidence_path":"%s","broken_term":%s,"lane":"cgroup-soak","clean":%s,"tier":"offline","tests":%s,"failures":%s,"faces":[],"flood_conns":-1,"hogs":0,"note":"%s"}\n' \
    "$SUBJ_SHA" "$IMG_DIGEST" "$SERVICE" "$PLANE" "$_c" "$_v" "$_now" "$_now" "$_rc" \
    "$JSONL" "$_b" "$_clean" "${3:-0}" "${4:-0}" \
    "$(printf '%s' "${5:-}" | tr -d '"' | cut -c1-160)" >> "$JSONL"
}

echo "[CGROUP-SOAK] runner: service=$SERVICE plane=$PLANE cycles=$CYCLES cpus=$CPUS mem=$MEM"

cd /smalt || exit 2
for c in $(seq 1 "$CYCLES"); do
  LOG="$RESULTS/leg-$SERVICE-c$c.log"
  echo "[CGROUP-SOAK] cycle $c/$CYCLES offline tier (stress excluded per test_helper.exs)"
  MIX_BUILD_ROOT=_build-cgroup-soak mix test >"$LOG" 2>&1
  RC=$?
  TESTS=$(grep -oE '[0-9]+ tests' "$LOG" | tail -1 | tr -dc '0-9'); TESTS=${TESTS:-0}
  FAILS=$(grep -oE '[0-9]+ failures' "$LOG" | tail -1 | tr -dc '0-9'); FAILS=${FAILS:-0}
  NOTE="cpus=$CPUS mem=$MEM plane=$PLANE cycle=$c"
  emit "$c" "$RC" "${TESTS:-0}" "${FAILS:-0}" "$NOTE"
  echo "[CGROUP-SOAK] cycle $c: exit=$RC tests=$TESTS failures=$FAILS"
  [ "$RC" -eq 0 ] || exit "$RC"
done
exit 0
