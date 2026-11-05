#!/usr/bin/env bash
# aoq_fence_court.sh — non-vacuity court for the AoQ egress fence (L29).
#
# Law: scripts/aoq_egress_fence.sh must FAIL on an un-allowlisted `<>`
# binary-append at an AoQ egress site. A fence that stays green under an
# injected violation is a VACUOUS GATE — that is a FAIL, not a pass.
#
# SCRATCH-scope rule: the fence is LANE-13-labeled and must never be edited,
# and no lib/ file may be touched. The court therefore materializes a SCRATCH
# copy of the fence at tmp/aoq-court/shim/scripts/aoq_egress_fence.sh with a
# scratch fixture scope at tmp/aoq-court/shim/lib/smalt/aoq/fixture.ex.
# The fence resolves its scan root as dirname($0)/.., so the copy scans only
# the scratch tree — lib/ is never read, written, or restored here.
#
# Protocol (scripts/shim_court/lib.sh):
#   BASELINE  sha256 the scratch fixture.
#   BEFORE    fence exits 0 (CLEAN) against the unmodified scratch scope.
#   SHIM      append an un-allowlisted `<>` egress line marked SHIM-COURT.
#   AFTER     fence must exit 1 (VIOLATION) — the flip IS the proof.
#   RESTORE   sha256 byte-exact, fail-closed.
set -euo pipefail
cd "$(dirname "$0")/../.."
source "scripts/shim_court/lib.sh"

shim_court_self_check

ROOT="$(pwd -P)"
SCRATCH="$ROOT/tmp/aoq-court/shim"
FIXTURE="$SCRATCH/lib/smalt/aoq/fixture.ex"
FENCE_SRC="$ROOT/scripts/aoq_egress_fence.sh"
FENCE_COPY="$SCRATCH/scripts/aoq_egress_fence.sh"

# Materialize the scratch scope: fence copy + a clean fixture file.
rm -rf "$SCRATCH"
mkdir -p "$SCRATCH/scripts" "$SCRATCH/lib/smalt/aoq"
cp "$FENCE_SRC" "$FENCE_COPY"
chmod +x "$FENCE_COPY"
printf '# SCRATCH fixture scope for aoq_fence_court (never a lib/ file)\n' > "$FIXTURE"

cleanup() { rm -rf "$SCRATCH"; }
trap cleanup EXIT

FENCE_OUT="$ROOT/tmp/aoq-court"

apply_shim() {
    # Un-allowlisted `<>` binary append at a (scratch) egress site: no
    # `# AOQ-FENCE-OK:` comment, not a comment line, not an exempt file.
    printf 'def egress_violation do\n  header <> payload # SHIM-COURT aoq-fence un-allowlisted <> egress\nend\n' >> "$SHIM_FILE"
}

before_witness() {
    # Fence must be CLEAN on the unmodified scratch scope (exit 0).
    "$FENCE_COPY" >/dev/null 2>&1
}

after_witness() {
    # Fence must now FAIL loudly with a VIOLATION on the injected line.
    local out rc
    out="$("$FENCE_COPY" 2>&1)" && rc=0 || rc=$?
    if [ "$rc" -eq 1 ] && printf '%s' "$out" | grep -q 'VIOLATION.*fixture.ex'; then
        return 0
    fi
    echo "AFTER witness: fence did not flip on injected <> (rc=$rc) — VACUOUS GATE" >&2
    printf '%s\n' "$out" | tail -10 >&2
    return 1
}

mkdir -p "$FENCE_OUT"
# Witnesses run via `bash -uc` in a fresh shell: embed the constants and the
# function bodies (unbound-variable hardening, R190 class).
BEFORE_CMD="$(declare -f before_witness); FENCE_COPY='$FENCE_COPY'; before_witness"
AFTER_CMD="$(declare -f after_witness); FENCE_COPY='$FENCE_COPY'; after_witness"
with_shim "$FIXTURE" "$BEFORE_CMD" "$AFTER_CMD"

# Court receipt under tmp/aoq-court/.
RECEIPT="$FENCE_OUT/aoq_fence_court_$(date +%Y%m%dT%H%M%S).md"
{
  echo "# L29 aoq fence shim court"
  echo "Standing: PASS"
  echo ""
  echo "Verdict: FLIPPED — fence exited 0 (CLEAN) on the unmodified scratch"
  echo "scope and 1 (VIOLATION fixture.ex) under the SHIM-COURT <> injection."
  echo "Fence subject: scripts/aoq_egress_fence.sh (copy; original untouched)."
  echo "Scope: tmp/aoq-court/shim/lib/smalt/aoq/fixture.ex — lib/ never touched."
} > "$RECEIPT"
printf '[aoq_fence_court] PASS — non-vacuous (flip witnessed), receipt: %s\n' "$RECEIPT"
