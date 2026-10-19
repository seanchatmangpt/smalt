#!/usr/bin/env bash
# container-burn.sh — in-container burn probe for the parallel matrix
# (docker/burn). Runs INSIDE the smalt:local image (bash + the release only;
# no python in the runtime image — this script is bash-only by construction).
#
# Per container (AZB-17 stage order):
#   0. Plane chaos stage (optional, BURN_CHAOS_SCENARIO): runs the plane's
#      scenario from docker/burn/chaos-kill.sh BEFORE the daemon boot — the
#      eval VMs bind the plane's ports; the daemon rebinds after the eval VM
#      exits. Evidence: /burn-results/chaos-<service>.jsonl.
#   1. Start the release; deadline-poll for the plane listener.
#   2. Atom-flood the container's own AMQP port 5672: connect -> partial HTTP
#      request line -> mid-request close (the i22 :closed flood class,
#      docs/jira/v26.10.17/receipts/i22-atom-flood-fix.md).
#   3. AZB-17 tenant canary: replica-unique marker written into and read back
#      from the container's own namespace, then a cross-replica reachability
#      assertion — replicas sit on separate compose networks, so every
#      cross-replica TCP attempt MUST fail; a success is CANARY_CROSS_READ.
#   4. Emit stage=chaos + stage=probe rows to
#      /burn-results/burn-<service>.jsonl and exit 0 clean / 1 dirty.
#
# Env: BURN_SERVICE, BURN_FLOOD_SECONDS (default 15), BURN_EXPECT_PORT,
# BURN_REPLICA, BURN_REPLICA_TOTAL, SMALT_BURN_PLANE, BURN_CHAOS_SCENARIO.
#
# AZB-16 HOST mode (`--saturation`): the release image has no mix/test tree,
# so the saturation suite runs in the smalt-burn TEST image (source at
# /smalt, test target stage) under `--cpus 2`: repo test/ + lib/ are mounted
# over the baked copies so the container compiles the CURRENT tree, and
# `mix test test/azsim/amqp_saturation_test.exs --include stress` runs x3.
# An atom-flood generator (connect -> partial HTTP request line ->
# mid-request close) runs against the HOST substrate AMQP port for the
# duration - the i22 :closed class under concurrent saturation. Exit 0 all
# runs green / 1 any run red / 2 preflight refusal.
set -u

SERVICE="${BURN_SERVICE:-smalt-burn-unknown}"
# AZB-17: replica identity + per-plane chaos scenario (set by the matrix
# generator; defaults keep the legacy single-container invocation intact).
REPLICA="${BURN_REPLICA:-1}"
REPLICA_TOTAL="${BURN_REPLICA_TOTAL:-1}"
CHAOS_SCENARIO="${BURN_CHAOS_SCENARIO:-}"
FLOOD_SECONDS="${BURN_FLOOD_SECONDS:-15}"
RESULTS_DIR="${BURN_RESULTS_DIR:-/burn-results}"
# AZB-02: release binary lives at /app/_release/bin/smalt in the pinned image
# (multi-stage release target); the /opt/smalt path was never in this image
# lineage. BURN_EXPECT_PORT is the plane's primary listener (control/all=9443,
# data=8443, integration=5672) — the netns probe asserts it is bound INSIDE
# the container netns via `ss -ltn` (iproute2 baked into the image).
SMALT_BIN="${SMALT_BIN:-/app/_release/bin/smalt}"
EXPECT_PORT="${BURN_EXPECT_PORT:-9443}"
LOG=/tmp/burn-smalt.log
JSONL="$RESULTS_DIR/burn-$SERVICE.jsonl"
START_TS=$SECONDS
DEADLINE=$((START_TS + 300))

mkdir -p "$RESULTS_DIR"

# AZB-03 row emitter (smalt-burn/v2). One row per (container, plane, stage);
# the AZB-17 matrix emits stage=chaos (when a plane scenario is configured)
# then stage=probe. The legacy "clean":true/false field is kept so the matrix
# driver's verdict parse is unchanged.
# rc: 0 -> CLEAN, else UNHANDLED_EXIT (broken_term mu_unlawful).
SUBJ_SHA=${SMALT_BURN_SUBJECT_SHA:-unrecorded}
IMG_DIGEST=${BURN_IMAGE_DIGEST:-unrecorded}
BURN_PLANE=${SMALT_BURN_PLANE:-all}
emit() { # emit <stage> <clean 0/1> <detail>
  _stage=$1; shift
  if [ "$1" = 0 ]; then _v=CLEAN; _b=null; _clean=true; else _v=UNHANDLED_EXIT; _b='"mu_unlawful"'; _clean=false; fi
  printf '{"schema":"smalt-burn/v2","subject_sha":"%s","image_digest":"%s","container":"%s","plane":"%s","cycle":0,"stage":"%s","verdict":"%s","t_start":"%s","t_end":"%s","exit_code":%s,"orphans":[],"crash_reports":0,"evidence_path":"%s","broken_term":%s,"lane":"container-burn","clean":%s,"detail":"%s"}\n' \
    "$SUBJ_SHA" "$IMG_DIGEST" "$SERVICE" "$BURN_PLANE" "$_stage" "$_v" \
    "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$1" \
    "$JSONL" "$_b" "$_clean" \
    "$(printf '%s' "$2" | tr -d '"' | cut -c1-200)" >> "$JSONL"
}

# ---------------------------------------------------------------------------
# AZB-16 host mode: saturation suite x3 in the test image under cpus: 2
# ---------------------------------------------------------------------------
if [ "${1:-}" = "--saturation" ]; then
  ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
  TEST_IMG=${SMALT_BURN_TEST_IMAGE:-smalt-burn:latest}
  ROUNDS=${SMALT_SATURATION_ROUNDS:-3}
  FLOOD_PORT=${SMALT_BURN_AMQP_PORT:-5672}

  docker image inspect "$TEST_IMG" >/dev/null 2>&1 || {
    echo "[BURN] test image $TEST_IMG missing - build per docker/BUILD_RECEIPT.md" >&2
    exit 2
  }

  SUBJ_SHA=$(git -C "$ROOT" rev-parse HEAD 2>/dev/null || echo unrecorded)
  RUN_TAG=$(date -u +%Y%m%dT%H%M%SZ)
  OUT="$ROOT/docker/burn/results/saturation-$RUN_TAG"
  mkdir -p "$OUT"

  # atom-flood generator against the host substrate for the burn duration
  # (i22 class: partial HTTP request line, mid-request close on :5672)
  (
    end=$((SECONDS + 600))
    n=0
    while [ "$SECONDS" -lt "$end" ]; do
      if exec 3<>/dev/tcp/127.0.0.1/"$FLOOD_PORT" 2>/dev/null; then
        printf 'PUT /flood HTTP/1.1\r\n' >&3 2>/dev/null || true
        exec 3>&- 3<&- 2>/dev/null || true
        n=$((n + 1))
      fi
      echo "$n" > "$OUT/flood-count"
    done
  ) &
  FLOOD_PID=$!

  RC=0
  for i in $(seq 1 "$ROUNDS"); do
    echo "[BURN] saturation round $i/$ROUNDS (cpus: 2)"
    if ! docker run --rm --cpus 2 \
        -e SMALT_SB_SHARED_KEY="$(head -c 24 /dev/urandom | base64)" \
        -v "$ROOT/test:/smalt/test" -v "$ROOT/lib:/smalt/lib" \
        "$TEST_IMG" mix test test/azsim/amqp_saturation_test.exs --include stress; then
      RC=1
    fi
  done

  kill "$FLOOD_PID" 2>/dev/null || true
  wait "$FLOOD_PID" 2>/dev/null || true
  echo "[BURN] saturation: rounds=$ROUNDS rc=$RC flood_conns=$(cat "$OUT/flood-count" 2>/dev/null || echo 0)"
  exit "$RC"
fi

port_open() { exec 3<>/dev/tcp/127.0.0.1/"$1" 2>/dev/null || return 1; exec 3>&- 3<&-; return 0; }

wait_port() { # wait_port <port> <what> — deadline poll, no fixed sleep
  while [ "$SECONDS" -lt "$DEADLINE" ]; do
    if port_open "$1"; then echo "[BURN] $2 up on :$1 (${SECONDS}s)"; return 0; fi
    read -t 2 -u 0 _ </dev/null 2>/dev/null || true
  done
  echo "[BURN] deadline waiting for $2 on :$1" >&2
  return 1
}

echo "[BURN] container burn: service=$SERVICE expect_port=$EXPECT_PORT flood=${FLOOD_SECONDS}s"

# ---------------------------------------------------------------------------
# AZB-17 stage 0: plane chaos court BEFORE the daemon boot (the eval VMs bind
# the plane's ports; the daemon rebinds after the eval VM exits).
# ---------------------------------------------------------------------------
CHAOS_RC=0
if [ -n "$CHAOS_SCENARIO" ] && [ -f /burn/chaos-kill.sh ]; then
  echo "[BURN] chaos stage: scenario=$CHAOS_SCENARIO"
  if SMALT_BURN_DIR="$RESULTS_DIR" SMALT_BURN_JSONL="chaos-$SERVICE.jsonl" \
     SMALT_CHAOS_SCENARIO="$CHAOS_SCENARIO" SMALT_STORM_CYCLES=0 \
     BURN_CONTAINER="$SERVICE" SMALT_BURN_PLANE="$BURN_PLANE" \
     bash /burn/chaos-kill.sh; then
    emit chaos 0 "scenario=$CHAOS_SCENARIO evidence=chaos-$SERVICE.jsonl"
    echo "[BURN] chaos CLEAN scenario=$CHAOS_SCENARIO"
  else
    CHAOS_RC=$?
    emit chaos 1 "scenario=$CHAOS_SCENARIO rc=$CHAOS_RC evidence=chaos-$SERVICE.jsonl"
    echo "[BURN] chaos DIRTY scenario=$CHAOS_SCENARIO rc=$CHAOS_RC" >&2
  fi
fi

# ---------------------------------------------------------------------------
# Boot the release; deadline-poll the plane listener.
# ---------------------------------------------------------------------------
echo "[BURN] boot: service=$SERVICE expect_port=$EXPECT_PORT"
: > "$LOG"
"$SMALT_BIN" start >"$LOG" 2>&1 &
SMALT_PID=$!

if ! wait_port "$EXPECT_PORT" "plane listener"; then
  emit probe 1 "release never opened :$EXPECT_PORT within deadline"
  kill "$SMALT_PID" 2>/dev/null || true
  exit 1
fi

# AZB-02 netns probe: the expected plane port must show LISTEN inside this
# container's own network namespace. `ss -ltn` is the ticket-named tool.
SS_LINE=$(ss -ltn 2>/dev/null | grep -E "[:.]$EXPECT_PORT " || true)
if [ -z "$SS_LINE" ]; then
  emit probe 1 "ss -ltn shows no LISTEN on :$EXPECT_PORT inside netns"
  kill "$SMALT_PID" 2>/dev/null || true
  exit 1
fi
echo "[BURN] netns ss: $SS_LINE"

# Atom flood: bash-only. Each iteration: connect, send a partial HTTP request
# line, close mid-request.
(
  end=$((SECONDS + FLOOD_SECONDS))
  n=0
  while [ "$SECONDS" -lt "$end" ]; do
    if exec 3<>/dev/tcp/127.0.0.1/5672 2>/dev/null; then
      printf 'PUT /flood HTTP/1.1\r\n' >&3 2>/dev/null || true
      exec 3>&- 3<&- 2>/dev/null || true
      n=$((n + 1))
    fi
  done
  echo "$n" > "$RESULTS_DIR/flood-count-$SERVICE"
) &
FLOOD_PID=$!

# Deadline-poll the flood subshell to completion (no fixed sleep).
while kill -0 "$FLOOD_PID" 2>/dev/null && [ "$SECONDS" -lt "$DEADLINE" ]; do
  wait "$FLOOD_PID" 2>/dev/null && break
  read -t 2 -u 0 _ </dev/null 2>/dev/null || true
done
kill "$FLOOD_PID" 2>/dev/null || true
wait "$FLOOD_PID" 2>/dev/null || true

# i22 law: every flood-closed read must carry the [amqp-atom] tag (atom-guard
# path). A `:closed` line WITHOUT the tag is an unguarded path — that is the
# failure signal. Tagged lines are the fix working, not a defect.
CLOSED_LINES=$(grep 'request read failed: :closed' "$LOG" 2>/dev/null | grep -vc '\[amqp-atom\]' || true)
ATOM_LINES=$(grep -c '\[amqp-atom\]' "$LOG" 2>/dev/null || true)
FLOOD_CONNS=$(cat "$RESULTS_DIR/flood-count-$SERVICE" 2>/dev/null || echo 0)

# ---------------------------------------------------------------------------
# AZB-17 tenant canary: replica-unique marker in own tmpfs + cross-replica
# reachability assertion (separate compose networks per replica -> every
# cross-replica TCP attempt MUST fail; a success is CANARY_CROSS_READ).
# ---------------------------------------------------------------------------
CANARY_RC=0
CANARY_DIR=/tmp/canary
mkdir -p "$CANARY_DIR"
CANARY_NONCE="$(date +%s)-$$-$(head -c 4 /dev/urandom | od -An -tx1 | tr -d ' \n')"
MARKER="$SERVICE|$REPLICA|$CANARY_NONCE"
if printf '%s\n' "$MARKER" > "$CANARY_DIR/marker" && [ "$(cat "$CANARY_DIR/marker")" = "$MARKER" ]; then
  echo "[BURN] canary marker roundtrip OK: $MARKER"
else
  CANARY_RC=1
  echo "[BURN] canary marker roundtrip FAILED" >&2
fi
CROSS_TRIES=0
CROSS_HITS=0
j=1
while [ "$j" -le "$REPLICA_TOTAL" ]; do
  if [ "$j" -ne "$REPLICA" ]; then
    peer="smalt-burn-${BURN_PLANE}-$j"
    CROSS_TRIES=$((CROSS_TRIES + 1))
    if timeout 5 bash -c "exec 3<>/dev/tcp/$peer/$EXPECT_PORT" 2>/dev/null; then
      CROSS_HITS=$((CROSS_HITS + 1))
      echo "[BURN] CANARY CROSS-REACH: $peer:$EXPECT_PORT reachable" >&2
    fi
  fi
  j=$((j + 1))
done
[ "$CROSS_HITS" -eq 0 ] || CANARY_RC=1

kill "$SMALT_PID" 2>/dev/null || true

# AZB-02: flood applies only where the AMQP listener exists (integration/all
# planes); on planes without :5672 the flood subshell makes zero connections —
# that is a skip, not a failure, and the row records it as such. AZB-17: the
# verdict folds in the chaos stage rc and the tenant canary.
if [ "$CLOSED_LINES" -eq 0 ] && [ "$CHAOS_RC" -eq 0 ] && [ "$CANARY_RC" -eq 0 ] && { [ "$FLOOD_CONNS" -gt 0 ] || [ "$EXPECT_PORT" != 5672 ]; }; then
  emit probe 0 "flood_conns=$FLOOD_CONNS closed_log_lines=0 atom_log_lines=$ATOM_LINES canary=ok cross_tries=$CROSS_TRIES cross_reads=$CROSS_HITS"
  echo "[BURN] CLEAN service=$SERVICE chaos_rc=$CHAOS_RC canary cross_reads=0 cross_tries=$CROSS_TRIES"
  exit 0
fi
emit probe 1 "flood_conns=$FLOOD_CONNS closed_log_lines=$CLOSED_LINES atom_log_lines=$ATOM_LINES canary_rc=$CANARY_RC cross_tries=$CROSS_TRIES cross_reads=$CROSS_HITS chaos_rc=$CHAOS_RC"
echo "[BURN] DIRTY service=$SERVICE canary_rc=$CANARY_RC chaos_rc=$CHAOS_RC closed=$CLOSED_LINES" >&2
exit 1
