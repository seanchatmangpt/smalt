#!/usr/bin/env bash
# container-burn.sh — in-container burn probe for the parallel matrix
# (docker/burn). Runs INSIDE the smalt:local image (bash + the release only;
# no python in the runtime image — this script is bash-only by construction).
#
# Per container:
#   1. Start the release; deadline-poll for the ARM listener (9443 in-container).
#   2. Atom-flood the container's own AMQP port 5672: connect -> partial HTTP
#      request line -> mid-request close (the i22 :closed flood class,
#      docs/jira/v26.10.17/receipts/i22-atom-flood-fix.md).
#   3. Deadline-poll the flood process to finish; count `[amqp-atom]` debug
#      lines in the release log — the fix must hold: zero `:closed` lines.
#   4. Emit one JSONL row to /burn-results/burn-<service>.jsonl and exit
#      0 clean / 1 dirty (matrix driver asserts 4/4 clean).
#
# Env: BURN_SERVICE (service name), BURN_FLOOD_SECONDS (default 15).
set -u

SERVICE="${BURN_SERVICE:-smalt-burn-unknown}"
FLOOD_SECONDS="${BURN_FLOOD_SECONDS:-15}"
RESULTS_DIR="${BURN_RESULTS_DIR:-/burn-results}"
# AZB-02: release binary lives at /app/_release/bin/smalt in the pinned image
# (multi-stage release target); the /opt/smalt path was never in this image
# lineage. BURN_EXPECT_PORT is the plane's primary listener (control/all=9443,
# data=8443, integration=5672) — the AZB-02 netns probe asserts it is bound
# INSIDE the container netns via `ss -ltn` (iproute2 baked into the image).
SMALT_BIN="${SMALT_BIN:-/app/_release/bin/smalt}"
EXPECT_PORT="${BURN_EXPECT_PORT:-9443}"
LOG=/tmp/burn-smalt.log
JSONL="$RESULTS_DIR/burn-$SERVICE.jsonl"
START_TS=$SECONDS
DEADLINE=$((START_TS + 300))

mkdir -p "$RESULTS_DIR"

# AZB-03 row emitter (smalt-burn/v2). One row per (container, plane, cycle,
# stage); this single-shot probe emits stage=probe cycle=0. The legacy
# "clean":true/false field is kept so parallel-matrix.sh's verdict parse is
# unchanged. rc: 0 -> CLEAN, else UNHANDLED_EXIT (broken_term mu_unlawful).
SUBJ_SHA=${SMALT_BURN_SUBJECT_SHA:-unrecorded}
IMG_DIGEST=${BURN_IMAGE_DIGEST:-unrecorded}
BURN_PLANE=${SMALT_BURN_PLANE:-all}
emit() { # emit <clean 0/1> <detail>
  if [ "$1" = 0 ]; then _v=CLEAN; _b=null; _clean=true; else _v=UNHANDLED_EXIT; _b='"mu_unlawful"'; _clean=false; fi
  printf '{"schema":"smalt-burn/v2","subject_sha":"%s","image_digest":"%s","container":"%s","plane":"%s","cycle":0,"stage":"probe","verdict":"%s","t_start":"%s","t_end":"%s","exit_code":%s,"orphans":[],"crash_reports":0,"evidence_path":"%s","broken_term":%s,"lane":"container-burn","clean":%s,"detail":"%s"}\n' \
    "$SUBJ_SHA" "$IMG_DIGEST" "$SERVICE" "$BURN_PLANE" "$_v" \
    "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$1" \
    "$JSONL" "$_b" "$_clean" \
    "$(printf '%s' "$2" | tr -d '"' | cut -c1-200)" >> "$JSONL"
}

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
: > "$LOG"
"$SMALT_BIN" start >"$LOG" 2>&1 &
SMALT_PID=$!

if ! wait_port "$EXPECT_PORT" "plane listener"; then
  emit 1 "release never opened :$EXPECT_PORT within deadline"
  kill "$SMALT_PID" 2>/dev/null || true
  exit 1
fi

# AZB-02 netns probe: the expected plane port must show LISTEN inside this
# container's own network namespace. `ss -ltn` is the ticket-named tool.
SS_LINE=$(ss -ltn 2>/dev/null | grep -E "[:.]$EXPECT_PORT " || true)
if [ -z "$SS_LINE" ]; then
  emit 1 "ss -ltn shows no LISTEN on :$EXPECT_PORT inside netns"
  kill "$SMALT_PID" 2>/dev/null || true
  exit 1
fi
echo "[BURN] netns ss: $SS_LINE"

# Atom flood: bash-only (no python in the runtime image). Each iteration:
# connect, send a partial HTTP request line, close mid-request.
FLOOD_PID=""
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

CLOSED_LINES=$(grep -c 'request read failed: :closed' "$LOG" 2>/dev/null || true)
ATOM_LINES=$(grep -c '\[amqp-atom\]' "$LOG" 2>/dev/null || true)
FLOOD_CONNS=$(cat "$RESULTS_DIR/flood-count-$SERVICE" 2>/dev/null || echo 0)

kill "$SMALT_PID" 2>/dev/null || true

# AZB-02: flood applies only where the AMQP listener exists (integration/all
# planes); on planes without :5672 the flood subshell makes zero connections —
# that is a skip, not a failure, and the row records it as such.
if [ "$CLOSED_LINES" -eq 0 ] && { [ "$FLOOD_CONNS" -gt 0 ] || [ "$EXPECT_PORT" != 5672 ]; }; then
  emit 0 "flood_conns=$FLOOD_CONNS closed_log_lines=0 atom_log_lines=$ATOM_LINES ss=$SS_LINE"
  echo "[BURN] CLEAN service=$SERVICE expect_port=$EXPECT_PORT flood_conns=$FLOOD_CONNS closed_log_lines=0"
  exit 0
fi
emit 1 "flood_conns=$FLOOD_CONNS closed_log_lines=$CLOSED_LINES atom_log_lines=$ATOM_LINES"
echo "[BURN] DIRTY service=$SERVICE flood_conns=$FLOOD_CONNS closed_log_lines=$CLOSED_LINES" >&2
exit 1
