#!/usr/bin/env bash
# build_burn_image.sh — WO-1: leased burn-image build at a pinned SHA.
#
# Mechanically enforces both WO-1 root-cause fixes:
#   1. SUBJECT_SHA is always the pinned ring SHA (the Dockerfile no longer
#      carries a default; it validates 40-hex at build time).
#   2. Concurrent docker builds cannot race HEAD: a flock image-build lease
#      (/tmp/smalt-burn-image.lock) is held across pin → build → verify →
#      release. Children spawned with the lock fd closed (9>&-), same
#      discipline as scripts/substrate.sh (fan-out rule 4: no fd inheritance).
#
# Sequence: RING_SHA=$(git rev-parse HEAD) pin → docker build
# --build-arg SUBJECT_SHA=$RING_SHA → post-build HEAD equality check (abort
# typed if HEAD moved) → docker inspect label org.smalt.subject equality
# assertion → release.
#
# Testability: DOCKERCmd env var overrides the docker command (default
# `docker`) so the inspect/assert logic is witnessable without a daemon.
#
# Exit: 0 pass / 1 typed failure / 2 usage.
set -euo pipefail

TAG=""
DRY_RUN=0
DOCKERCmd="${DOCKERCmd:-docker}"

usage() {
  echo "usage: $0 --tag <name> [--dry-run]" >&2
  exit 2
}

while [ $# -gt 0 ]; do
  case "$1" in
    --tag) TAG="${2:?--tag requires a value}"; shift 2 ;;
    --dry-run) DRY_RUN=1; shift ;;
    *) usage ;;
  esac
done
[ -n "$TAG" ] || usage

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO_ROOT"
LOCKFILE=/tmp/smalt-burn-image.lock

RING_SHA="$(git -C "$REPO_ROOT" rev-parse HEAD)"
echo "RING_SHA(pinned)=$RING_SHA"
echo "TAG=$TAG"
echo "LOCKFILE=$LOCKFILE"

if [ "$DRY_RUN" -eq 1 ]; then
  echo "DRY-RUN plan (no lock taken, no build):"
  echo "  exec 9>$LOCKFILE; flock -x 9"
  echo "  $DOCKERCmd build -f docker/Dockerfile -t $TAG --build-arg SUBJECT_SHA=$RING_SHA \\"
  echo "      --build-context ash_r2rml=~/ash_r2rml --build-context ash_graphlaw=~/ash_graphlaw \\"
  echo "      --build-context ggen_igniter=~/ggen_igniter ."
  echo "  git rev-parse HEAD  # must equal $RING_SHA (typed abort: HEAD_MOVED otherwise)"
  echo "  $DOCKERCmd inspect --format {{.Config.Labels}} $TAG  # org.smalt.subject must equal $RING_SHA"
  echo "  flock -u 9; exec 9>&-  # release"
  exit 0
fi

exec 9>"$LOCKFILE"
if ! flock -x 9; then
  echo "BUILD_LEASE_REFUSED: could not acquire $LOCKFILE" >&2
  exit 1
fi

echo "lease: acquired (flock -x 9)"

fail() { echo "TYPED-FAIL[$1]: $2" >&2; exit 1; }

# 1. build at the pinned SHA
"$DOCKERCmd" build -f docker/Dockerfile -t "$TAG" \
  --build-arg SUBJECT_SHA="$RING_SHA" \
  --build-context ash_r2rml="$REPO_ROOT/../ash_r2rml" \
  --build-context ash_graphlaw="$REPO_ROOT/../ash_graphlaw" \
  --build-context ggen_igniter="$REPO_ROOT/../ggen_igniter" \
  . || fail BUILD_FAILED "docker build exited nonzero at SUBJECT_SHA=$RING_SHA"

# 2. post-build HEAD equality (HEAD must not have moved under the build)
HEAD_NOW="$(git -C "$REPO_ROOT" rev-parse HEAD)"
[ "$HEAD_NOW" = "$RING_SHA" ] || fail HEAD_MOVED "HEAD moved during build: pinned=$RING_SHA now=$HEAD_NOW"
echo "head-check: HEAD unchanged ($HEAD_NOW)"

# 3. label equality assertion
LABEL_SUBJECT="$("$DOCKERCmd" inspect --format '{{index .Config.Labels "org.smalt.subject"}}' "$TAG")"
[ "$LABEL_SUBJECT" = "$RING_SHA" ] || fail IMAGE_SUBJECT_MISMATCH \
  "org.smalt.subject=$LABEL_SUBJECT != pinned SUBJECT_SHA=$RING_SHA"
echo "label-check: org.smalt.subject=$LABEL_SUBJECT == pinned"

# 4. release
flock -u 9
exec 9>&-
echo "lease: released"
echo "BUILD_RECEIPT subject=$RING_SHA tag=$TAG lease=PASS label=PASS head=PASS"
