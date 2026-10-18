#!/usr/bin/env bash
# parallel-matrix.sh — 4-service parallel burn matrix driver (docker/burn).
#
# `docker compose -f docker/burn/compose.burn.yml up -d`, deadline-poll each
# container's JSONL row in docker/burn/results/, assert 4/4 clean, compose down.
#
# Per-container probe: docker/burn/container-burn.sh (release boot, AMQP
# atom-flood, zero `:closed` log-line assertion; i22 class,
# docs/jira/v26.10.17/receipts/i22-atom-flood-fix.md).
#
# Deadline polls everywhere — no fixed sleeps. Exit 0 clean / 1 not 4/4 clean /
# 2 docker/preflight failure / 3 usage.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
cd "$ROOT"

DRY_RUN=0
DEADLINE_SECS=900
COMPOSE_FILE="$HERE/compose.burn.yml"
PROJECT="smalt-burn"
RESULTS_DIR="$HERE/results"
SERVICES=(smalt-burn-1 smalt-burn-2 smalt-burn-3 smalt-burn-4)

usage() {
  cat <<EOF
usage: parallel-matrix.sh [--dry-run] [--deadline S]
  --dry-run     print the resolved plan and exit 0
  --deadline S  wall budget in seconds for all 4 JSONL rows, default 900
EOF
  exit 3
}

while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run) DRY_RUN=1 ;;
    --deadline) DEADLINE_SECS="$2"; shift ;;
    *) usage ;;
  esac
  shift
done

if [ "$DRY_RUN" = 1 ]; then
  echo "[BURN-MATRIX][DRY-RUN] compose_file=$COMPOSE_FILE project=$PROJECT"
  echo "[BURN-MATRIX][DRY-RUN] services=${SERVICES[*]}"
  echo "[BURN-MATRIX][DRY-RUN] results_dir=$RESULTS_DIR deadline=${DEADLINE_SECS}s"
  echo "[BURN-MATRIX][DRY-RUN] plan: compose up -d -> deadline-poll burn-<svc>.jsonl x4 -> assert 4/4 clean -> compose down"
  exit 0
fi

command -v docker >/dev/null 2>&1 || { echo "[BURN-MATRIX] docker not on PATH" >&2; exit 2; }
docker info >/dev/null 2>&1 || { echo "[BURN-MATRIX] docker daemon not reachable" >&2; exit 2; }
docker image inspect smalt:local >/dev/null 2>&1 || {
  echo "[BURN-MATRIX] image smalt:local missing — build per docker/README.md first" >&2
  exit 2
}

mkdir -p "$RESULTS_DIR"
rm -f "$RESULTS_DIR"/burn-smalt-burn-*.jsonl "$RESULTS_DIR"/flood-count-* 2>/dev/null || true

DC=(docker compose -f "$COMPOSE_FILE" -p "$PROJECT")

echo "[BURN-MATRIX] compose up -d (${SERVICES[*]})"
"${DC[@]}" up -d

START_TS=$SECONDS
DEADLINE=$((START_TS + DEADLINE_SECS))
collect() { # poll until every service has a JSONL row or the deadline hits
  have=0
  while [ "$SECONDS" -lt "$DEADLINE" ]; do
    have=0
    for s in "${SERVICES[@]}"; do
      [ -s "$RESULTS_DIR/burn-$s.jsonl" ] && have=$((have + 1))
    done
    if [ "$have" -eq "${#SERVICES[@]}" ]; then
      echo "[BURN-MATRIX] all ${#SERVICES[@]} JSONL rows present after $((SECONDS - START_TS))s"
      return 0
    fi
    read -t 2 -u 0 _ </dev/null 2>/dev/null || true
  done
  echo "[BURN-MATRIX] deadline (${DEADLINE_SECS}s) before all rows landed (have=$have/4)" >&2
  return 1
}

COLLECT_RC=0
collect || COLLECT_RC=$?

echo "[BURN-MATRIX] container states at collection:"
"${DC[@]}" ps -a --format '{{.Name}} {{.State}} {{.ExitCode}}' || true

# Down + volume teardown BEFORE verdict so cleanup happens on every path.
"${DC[@]}" down -v --remove-orphans >/dev/null 2>&1 || true

if [ "$COLLECT_RC" -ne 0 ]; then
  echo "[BURN-MATRIX] VERDICT: FAIL — not all containers emitted rows" >&2
  exit 1
fi

CLEAN=0
for s in "${SERVICES[@]}"; do
  row="$(tail -1 "$RESULTS_DIR/burn-$s.jsonl")"
  echo "[BURN-MATRIX] $s -> $row"
  case "$row" in
    *'"clean":true'*) CLEAN=$((CLEAN + 1)) ;;
  esac
done

echo "[BURN-MATRIX] clean services: $CLEAN/4"
[ "$CLEAN" -eq 4 ] || { echo "[BURN-MATRIX] VERDICT: FAIL — not 4/4 clean" >&2; exit 1; }
echo "[BURN-MATRIX] VERDICT: CLEAN — 4/4 containers green under atom flood"
