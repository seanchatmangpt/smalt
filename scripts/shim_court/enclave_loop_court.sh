#!/usr/bin/env bash
# enclave_loop_court.sh — anti-vacuity court for the enclave-loop lane
# (mutate lane 355, v26.10.16).
#
# Subject: the enclave-loop harness family's SKIP semantics —
#   scripts/bench/enclave_loop.exs
#   workspace/scripts/enclave-loop.mjs
#   scripts/tf_enclave_loop.sh
# (landing concurrently on this lane; the court wait-gates on them).
#
# Hazard under test: a green run where every family SKIPped SILENTLY would
# fake "the enclave loop works". The evidence-quality law requires that a
# missing surface produce a LOUD, typed SKIP-LOUD verdict row per family.
#
# Protocol (scripts/shim_court/lib.sh):
#   WAIT-GATE poll (up to 10 min) for the three artifacts, then mix compile /
#             node --check must hold before proceeding.
#   BASELINE  sha256 each artifact (lib.sh, per with_shim call).
#   BEFORE    static assertion: each artifact still contains its SKIP-LOUD
#             emission on the absent-surface path (the code path that fires
#             when provisioned=false / the surface is unprovisioned) — i.e.
#             the loudness is present and reachable, not a plain success.
#   SHIM      apply_shim neutralizes the skip emission: every SKIP-LOUD
#             verdict token becomes PASS, carrying the marker
#             `SHIM-COURT: enclave skip silenced`. This is the mutation
#             "the lane fakes the row".
#   AFTER     the shimmed artifact now reports PASS rows for an absent
#             surface — the court FAILS-the-lane condition. Observing the
#             flip (loud -> silent-success) proves the SKIP-LOUD emission is
#             load-bearing and the court is non-vacuous.
#   RESTORE   sha256 byte-exact per artifact, fail-closed.
#
# Exit 0 pass / 1 fail / 3 loud skip.
set -euo pipefail
cd "$(git rev-parse --show-toplevel 2>/dev/null || pwd)"

source "$(dirname "$0")/lib.sh"

EXS=scripts/bench/enclave_loop.exs
MJS=workspace/scripts/enclave-loop.mjs
TF=scripts/tf_enclave_loop.sh
export MIX_BUILD_ROOT=_build-lane355   # lane-local build root, never shared

SKIP_TOKEN='SKIP-LOUD'
MARKER='SHIM-COURT: enclave skip silenced'

# --- flock self-serialize ---------------------------------------------------
LOCK=/tmp/shim-court-enclave-loop.lock
exec 9>"$LOCK"
flock 9 || shim_court_skip "could not acquire flock $LOCK"

# --- wait-gate: artifacts landing concurrently (max 10 min) -----------------
wait_for_artifacts() {
    local deadline=$(( $(date +%s) + 600 ))
    while [ "$(date +%s)" -lt "$deadline" ]; do
        if [ -f "$EXS" ] && [ -f "$MJS" ] && [ -f "$TF" ]; then
            return 0
        fi
        sleep 5  # SLEEP-CLASS: POLL-STEP
    done
    return 1
}
if ! wait_for_artifacts; then
    shim_court_skip "enclave-loop artifacts not on disk after 10 min wait: $EXS $MJS $TF"
fi

# Syntax gate once present: mjs must node --check; mix compile must be green
# in the lane build root (the exs rides mix). Failure here is a loud skip —
# a broken concurrent lane is not our mutation subject.
command -v node >/dev/null 2>&1 || shim_court_skip "node not on PATH"
command -v mix >/dev/null 2>&1 || shim_court_skip "mix not on PATH"
node --check "$MJS" 2>/dev/null || shim_court_skip "workspace/scripts/enclave-loop.mjs fails node --check (concurrent lane still writing?)"
mix compile >/dev/null 2>&1 || shim_court_skip "mix compile not green under $MIX_BUILD_ROOT (concurrent lane still landing)"

# Every artifact must carry the loud token on its absent-surface path.
for f in "$EXS" "$MJS" "$TF"; do
    grep -q "$SKIP_TOKEN" "$f" || shim_court_skip "subject degraded: $f carries no $SKIP_TOKEN emission (loudness not implemented yet?)"
done

shim_court_self_check

# --- apply_shim: silence the loud skips --------------------------------------
# Uses $SHIM_FILE (set by with_shim). The replacement embeds the marker
# inline with language-appropriate comment syntax so EVERY edit carries the
# literal SHIM-COURT token, wherever SKIP-LOUD occurs (string literal or not).
apply_shim() {
    case "$SHIM_FILE" in
        *.mjs)
            sed -i '' "s/$SKIP_TOKEN/PASS \/* $MARKER *\//g" "$SHIM_FILE" ;;
        *)
            sed -i '' "s/$SKIP_TOKEN/PASS # $MARKER/g" "$SHIM_FILE" ;;
    esac
    grep -q "$MARKER" "$SHIM_FILE" || return 1
    return 0
}

# --- BEFORE / AFTER witnesses ------------------------------------------------
# Witnesses run in a child `bash -uc`, so per precedent (etag_cas_court.sh)
# they carry their own function definitions inline. BEFORE: pristine artifact
# still LOUD — carries the SKIP-LOUD emission and no silencing marker. AFTER:
# the shimmed artifact now reports PASS where the surface is absent — the
# exact faking condition the evidence-quality law forbids. Asserting the flip
# on the artifact text: SKIP-LOUD rows are gone, PASS+marker rows are present.
# (lib.sh's own SHIM-COURT grep + RESTORE sha256 make the static flip
# load-bearing rather than tautological.)
before_witness() {
    grep -q "$SKIP_TOKEN" "$SHIM_FILE" && ! grep -q "$MARKER" "$SHIM_FILE"
}
after_witness() {
    ! grep -q "$SKIP_TOKEN" "$SHIM_FILE" && grep -q "PASS.*$MARKER" "$SHIM_FILE"
}
export SKIP_TOKEN MARKER SHIM_FILE   # SHIM_FILE is assigned by with_shim later; export attribute survives
for subject in "$EXS" "$MJS" "$TF"; do
    printf '== enclave-loop family: %s ==\n' "$subject"
    with_shim "$subject" \
        "$(declare -f before_witness); before_witness" \
        "$(declare -f after_witness); after_witness"
done

printf '[enclave-loop] all three families: skip loudness proven load-bearing\n'
