#!/usr/bin/env bash
# soak.sh — v26.10.18 burn lane (docker/burn)
#
# Saturation burn under the i22 atom-flood class:
#   1. N x `yes` CPU hogs (degraded-host law; FLAKE_LEDGER F9/F12 hammer class).
#   2. AMQP atom-flood generator: connect -> partial HTTP request line ->
#      mid-request close on the AMQP port. Reproduces the 390-lines/ms
#      `[amqp-atom] request read failed: :closed` logger-flood class fixed in
#      docs/jira/v26.10.17/receipts/i22-atom-flood-fix.md
#      (lib/smalt/messaging/amqp/atom_bridge.ex :closed silent exit). The burn
#      proves the fix holds under saturation.
#   3. Full offline suite + wire tier (`--include amqp_wire`) x rounds.
#      :stress stays excluded per the v26.10.18 tier split (test/test_helper.exs).
#   4. Failures classified against docs/jira/v26.10.17/FLAKE_LEDGER.md — only
#      UNLEDGERED failures (or hard leg failures with no ledger match) fail the
#      burn; ledgered faces are recorded, not fatal.
#   5. JSONL rows in tmp/burn-soak-<ts>.jsonl (writes ONLY its own files).
#
# Deadline polls everywhere — no fixed sleeps (NO-SLEEP-DOCTRINE). Exit
# 0 clean / 1 burn failure / 3 usage or preflight.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT"

DRY_RUN=0
ROUNDS=3
HOGS=4
FLOOD_SECONDS=20
AMQP_PORT="${SMALT_BURN_AMQP_PORT:-5672}"
JSONL=""
DEADLINE_SECS=3600

usage() {
  cat <<EOF
usage: soak.sh [--dry-run] [--rounds N] [--hogs N] [--flood-seconds S]
               [--amqp-port P] [--jsonl PATH] [--deadline S]
  --dry-run          print the resolved plan and exit 0
  --rounds N         offline + wire legs per round, default 3
  --hogs N           yes(1) CPU hogs, default 4
  --flood-seconds S  atom-flood generator budget per leg, default 20
  --amqp-port P      substrate AMQP port to flood, default 5672 (or \$SMALT_BURN_AMQP_PORT)
  --jsonl PATH       JSONL sink (default tmp/burn-soak-<ts>.jsonl)
  --deadline S       overall wall budget in seconds, default 3600
EOF
  exit 3
}

while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run) DRY_RUN=1 ;;
    --rounds) ROUNDS="$2"; shift ;;
    --hogs) HOGS="$2"; shift ;;
    --flood-seconds) FLOOD_SECONDS="$2"; shift ;;
    --amqp-port) AMQP_PORT="$2"; shift ;;
    --jsonl) JSONL="$2" ;;
    --deadline) DEADLINE_SECS="$2"; shift ;;
    *) usage ;;
  esac
  shift
done

TS="$(date -u +%Y%m%dT%H%M%SZ)"
JSONL="${JSONL:-$ROOT/tmp/burn-soak-$TS.jsonl}"
LEDGER="$ROOT/docs/jira/v26.10.17/FLAKE_LEDGER.md"
FLOOD_STATUS="$ROOT/tmp/burn-flood-status-$TS"
LEG_LOG="$ROOT/tmp/burn-leg-$TS.log"
START_TS="$SECONDS"

if [ "$DRY_RUN" = 1 ]; then
  echo "[BURN-SOAK][DRY-RUN] root=$ROOT rounds=$ROUNDS hogs=$HOGS flood_seconds=$FLOOD_SECONDS amqp_port=$AMQP_PORT"
  echo "[BURN-SOAK][DRY-RUN] jsonl=$JSONL ledger=$LEDGER"
  echo "[BURN-SOAK][DRY-RUN] plan: start $HOGS yes-hogs -> atom-flood 127.0.0.1:$AMQP_PORT (partial HTTP + mid-request close) -> $ROUNDS x (mix test + mix test --include amqp_wire) -> classify vs FLAKE_LEDGER -> jsonl rows"
  exit 0
fi

mkdir -p "$ROOT/tmp"
: > "$JSONL"

emit() { # emit <round> <tier> <rc> <tests> <failures> <faces-json> <note>
  python3 - "$JSONL" "$1" "$2" "$3" "$4" "$5" "$6" "${7:-}" "$FLOOD_STATUS" "$HOGS" <<'PY'
import json, os, sys, time
(path, rnd, tier, rc, tests, fails, faces, note, flood_status, hogs) = sys.argv[1:11]
row = {
    "schema": "smalt.burn-soak/1",
    "ts": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
    "lane": "burn-soak",
    "round": int(rnd),
    "tier": tier,
    "exit": int(rc),
    "tests": int(tests),
    "failures": int(fails),
    "faces": json.loads(faces) if faces else [],
    "flood_conns": -1,
    "hogs": int(hogs),
    "note": note,
}
try:
    row["flood_conns"] = int(open(flood_status).read().strip())
except Exception:
    pass
with open(path, "a") as f:
    f.write(json.dumps(row) + "\n")
PY
}

# classify <leg log path> — extract ExUnit failure faces (file:line) and look
# each up in the FLAKE_LEDGER table rows (| Fn | <face> ... | standing |).
classify() {
  python3 - "$1" "$LEDGER" <<'PY'
import json, os, re, sys
log, ledger_path = sys.argv[1], sys.argv[2]
txt = open(log, errors="replace").read()
blocks = re.split(r"(?m)^\s*\d+\) test ", txt)[1:]
seen, faces = set(), []
ledger = open(ledger_path).read() if os.path.exists(ledger_path) else ""
rows = []
for line in ledger.splitlines():
    if line.lstrip().startswith("| F"):
        cells = [c.strip() for c in line.strip().strip("|").split("|")]
        if len(cells) >= 8:
            rows.append((cells[1], cells[7]))
for b in blocks:
    m = re.search(r"(test/[A-Za-z0-9_/.]+\.exs):(\d+)", b)
    if not m:
        continue
    face, fname = f"{m.group(1)}:{m.group(2)}", m.group(1)
    if face in seen:
        continue
    seen.add(face)
    standing = "UNLEDGERED"
    for row_face, row_standing in rows:
        if face in row_face:
            standing = row_standing.split()[0]
            break
        if fname in row_face:
            standing = row_standing.split()[0] + "-FILE"
            break
    faces.append({"face": face, "standing": standing})
print(json.dumps(faces))
PY
}

has_unledgered() { case "$1" in *'"UNLEDGERED"'*|*'"UNLEDGERED-FILE"'*) return 0 ;; *) return 1 ;; esac; }

# ---- substrate: use it as found; boot via substrate.sh if we must ------------
amqp_listening() { lsof -nP -iTCP:"$AMQP_PORT" -sTCP:LISTEN >/dev/null 2>&1; }

SUBSTRATE_BOOTED=0
if ! amqp_listening; then
  echo "[BURN-SOAK] AMQP :$AMQP_PORT not listening — booting substrate via scripts/substrate.sh"
  bash "$ROOT/scripts/substrate.sh" up
  SUBSTRATE_BOOTED=1
fi
if ! amqp_listening; then
  echo "[BURN-SOAK] substrate never came up on :$AMQP_PORT" >&2
  exit 1
fi

DEADLINE_OK() { [ "$((START_TS + DEADLINE_SECS))" -gt "$SECONDS" ]; }

# ---- CPU hogs ----------------------------------------------------------------
HOG_PIDS=()
start_hogs() {
  for _ in $(seq 1 "$HOGS"); do
    yes > /dev/null 2>&1 &
    HOG_PIDS+=($!)
  done
  echo "[BURN-SOAK] $HOGS yes-hogs started: ${HOG_PIDS[*]}"
}
stop_hogs() {
  [ "${#HOG_PIDS[@]}" -gt 0 ] || return 0
  for p in "${HOG_PIDS[@]}"; do kill "$p" 2>/dev/null || true; done
}

# ---- atom-flood generator ----------------------------------------------------
FLOOD_PID=""
start_flood() { # $1 = seconds budget; writes the connection count to $FLOOD_STATUS
  python3 - "$AMQP_PORT" "$1" "$FLOOD_STATUS" <<'PY' &
import socket, sys, time
port, budget, status = int(sys.argv[1]), float(sys.argv[2]), sys.argv[3]
deadline = time.time() + budget
n = 0
while time.time() < deadline:
    try:
        s = socket.create_connection(("127.0.0.1", port), 0.5)
        try:
            s.sendall(b"PUT /flood HTTP/1.1\r\n")  # partial request line
        except OSError:
            pass
        s.close()  # mid-request close -> AtomBridge read path -> {:error, :closed}
        n += 1
    except OSError:
        pass
open(status, "w").write(str(n))
PY
  FLOOD_PID=$!
  echo "[BURN-SOAK] atom-flood generator pid=$FLOOD_PID -> 127.0.0.1:$AMQP_PORT for ${1}s"
}
stop_flood() { [ -n "$FLOOD_PID" ] && kill "$FLOOD_PID" 2>/dev/null || true; }

cleanup() {
  stop_flood
  stop_hogs
  if [ "$SUBSTRATE_BOOTED" = 1 ]; then
    bash "$ROOT/scripts/substrate.sh" down >/dev/null 2>&1 || true
  fi
}
trap cleanup EXIT INT TERM

start_hogs

ANY_UNLEDGERED=0
ANY_LEG_FAIL=0

for r in $(seq 1 "$ROUNDS"); do
  if ! DEADLINE_OK; then
    echo "[BURN-SOAK] overall deadline hit at round $r — stopping early" >&2
    ANY_LEG_FAIL=1
    break
  fi
  : > "$LEG_LOG"
  start_flood "$FLOOD_SECONDS"

  echo "[BURN-SOAK] round $r/$ROUNDS — offline tier (stress excluded per test_helper.exs)"
  set +e
  MIX_BUILD_ROOT=_build-burn mix test >"$LEG_LOG" 2>&1
  OFF_RC=$?
  set -e
  OFF_TESTS=$(grep -oE '[0-9]+ tests' "$LEG_LOG" | tail -1 | tr -dc '0-9'); OFF_TESTS=${OFF_TESTS:-0}
  OFF_FAILS=$(grep -oE '[0-9]+ failures?($|,)' "$LEG_LOG" | tail -1 | tr -dc '0-9'); OFF_FAILS=${OFF_FAILS:-0}
  OFF_FACES="$(classify "$LEG_LOG")"
  emit "$r" offline "$OFF_RC" "$OFF_TESTS" "$OFF_FAILS" "$OFF_FACES" "hogs=$HOGS flood=${FLOOD_SECONDS}s"
  echo "[BURN-SOAK] round $r offline: exit=$OFF_RC tests=$OFF_TESTS failures=$OFF_FAILS faces=$OFF_FACES"
  has_unledgered "$OFF_FACES" && ANY_UNLEDGERED=1
  [ "$OFF_RC" -ne 0 ] && ANY_LEG_FAIL=1

  : > "$LEG_LOG"
  start_flood "$FLOOD_SECONDS"
  echo "[BURN-SOAK] round $r — wire tier (--include amqp_wire)"
  set +e
  MIX_BUILD_ROOT=_build-burn mix test --include amqp_wire >"$LEG_LOG" 2>&1
  WIRE_RC=$?
  set -e
  WIRE_TESTS=$(grep -oE '[0-9]+ tests' "$LEG_LOG" | tail -1 | tr -dc '0-9'); WIRE_TESTS=${WIRE_TESTS:-0}
  WIRE_FAILS=$(grep -oE '[0-9]+ failures?($|,)' "$LEG_LOG" | tail -1 | tr -dc '0-9'); WIRE_FAILS=${WIRE_FAILS:-0}
  WIRE_FACES="$(classify "$LEG_LOG")"
  emit "$r" wire "$WIRE_RC" "$WIRE_TESTS" "$WIRE_FAILS" "$WIRE_FACES" "hogs=$HOGS flood=${FLOOD_SECONDS}s"
  echo "[BURN-SOAK] round $r wire: exit=$WIRE_RC tests=$WIRE_TESTS failures=$WIRE_FAILS faces=$WIRE_FACES"
  has_unledgered "$WIRE_FACES" && ANY_UNLEDGERED=1
  [ "$WIRE_RC" -ne 0 ] && ANY_LEG_FAIL=1
done

echo "[BURN-SOAK] flood connections (last leg): $(cat "$FLOOD_STATUS" 2>/dev/null || echo 'n/a')"

if [ "$ANY_UNLEDGERED" = 1 ]; then
  echo "[BURN-SOAK] VERDICT: FAIL — unledgered failure face(s); fix or ledger before re-burn"
  exit 1
fi
if [ "$ANY_LEG_FAIL" = 1 ]; then
  echo "[BURN-SOAK] VERDICT: CLASSIFIED-FAIL — failures present, all ledgered (see $JSONL)"
  exit 1
fi
echo "[BURN-SOAK] VERDICT: CLEAN — $ROUNDS rounds x (offline + wire) green under $HOGS hogs + atom flood ($JSONL)"
exit 0
