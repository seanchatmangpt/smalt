#!/usr/bin/env bash
# scripts/bench/scvd_airgap.sh — SCVD-T19 zero-egress enforcement court.
#
# Legs:
#   1. Static census: grep lib/ for outbound-dial primitives
#      (gen_tcp:connect / ssl:connect / httpc:request / HTTP clients).
#      Expected: empty (server-side only).
#   2. Dead-proxy + observational: run a real cosmos put/get workload against
#      a bench_boot private-port substrate with http_proxy/https_proxy pointed
#      at a dead local port, while a monitor samples the beam's TCP table via
#      lsof — any non-loopback remote address in ESTABLISHED/SYN_SENT is a
#      breach.
#   3. Emit tmp/bench/scvd-airgap.jsonl (census row + workload rows + verdict).
#
# No firewall modification; no sudo. pf leg: SKIPPED typed if unavailable.
set -euo pipefail
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$REPO"
source "$REPO/scripts/bench/lib.sh"
export BENCH_LANE="${BENCH_LANE:-scvd-airgap}"
OUT="$REPO/tmp/bench/scvd-airgap.jsonl"
mkdir -p "$(dirname "$OUT")"; : >"$OUT"

echo "== leg 1: outbound-dial census (lib/) =="
CENSUS_HITS=$(grep -rnE 'gen_tcp\s*:\s*connect|ssl\s*:\s*connect|httpc\s*:\s*request|:httpc\b|HTTPoison|Finch\{|Finch\.|Tesla|Mint\.|:hackney|http_uri' lib --include='*.ex' | wc -l | tr -d ' ' || true)
CENSUS_OUT=$(grep -rnE 'gen_tcp\s*:\s*connect|ssl\s*:\s*connect|httpc\s*:\s*request|:httpc\b|HTTPoison|Finch\{|Finch\.|Tesla|Mint\.|:hackney|http_uri' lib --include='*.ex' || true)
echo "census hits: $CENSUS_HITS"
if [ -n "$CENSUS_OUT" ]; then printf '%s\n' "$CENSUS_OUT"; fi

echo "== leg 1b: workspace ESLint no-egress gate present =="
grep -n "no-restricted" workspace/eslint.config.mjs | head -6 || echo "ESLINT-GATE-MISSING"

echo "== leg 2: boot private-port substrate (lane b11 block: 39110-39115) =="
trap ':' EXIT   # hold an EXIT trap so bench_boot's subshell doesn't self-reap (command-substitution subshell sees trap -p EXIT empty)
PID="$(bench_boot b11)"
trap 'bench_down "$PID"' EXIT INT TERM
ARM=39110; DATA=39111

echo "== leg 2b: dead-proxy + non-loopback monitor =="
export http_proxy=http://127.0.0.1:1 https_proxy=http://127.0.0.1:1 \
       HTTP_PROXY=http://127.0.0.1:1 HTTPS_PROXY=http://127.0.0.1:1
export no_proxy=localhost,127.0.0.1 NO_PROXY=localhost,127.0.0.1
MON="$REPO/tmp/bench/scvd-airgap-monitor.txt"; : >"$MON"
(
  end=$((SECONDS + 120))
  while [ $SECONDS -lt $end ]; do
    # -a = AND the selections (without it lsof ORs: whole-machine TCP table).
    # $PID is the mix wrapper; the beam is a child — resolve it per iteration
    # by its unique private-port eval string.
    BEAM=$(pgrep -f "beam.smp.*arm_port, $ARM" | head -1 || true)
    if [ -n "$BEAM" ]; then
      lsof -nP -w -a -p "$BEAM" -iTCP 2>/dev/null \
        | awk '$NF ~ /ESTABLISHED|SYN_SENT/ {print}' >>"$MON"
    fi
    sleep 0.05 # SLEEP-CLASS: POLL-STEP (bounded observational poll, 50ms cadence)
  done
) &
MONPID=$!

echo "== leg 2c: cosmos put/get workload (T1 shape) =="
i=0; until lsof -nP -iTCP:$DATA -sTCP:LISTEN >/dev/null 2>&1; do
  i=$((i+1)); [ $i -gt 60 ] && { echo "TYPED-TIMEOUT(124): data plane never listened on $DATA" >&2; exit 124; }
  sleep 0.5 # SLEEP-CLASS: POLL-STEP (bounded readiness poll)
done
echo "data plane LISTEN on $DATA confirmed"
run_ops() { # <op> <n> — one persistent keep-alive connection, one JSON stats line
  python3 - "$1" "$2" "$DATA" <<'PY'
import sys, time, json, http.client
op, n, port = sys.argv[1], int(sys.argv[2]), int(sys.argv[3])
db = "scvd-airgap"
conn = http.client.HTTPConnection("127.0.0.1", port, timeout=10)
lat, ok, err = [], 0, 0
def req(method, path, body=None):
    headers = {'content-type': 'application/json'} if body else {}
    conn.request(method, path, body=body, headers=headers)
    resp = conn.getresponse()
    resp.read()
    return resp.status
t0 = time.perf_counter()
for i in range(n):
    s0 = time.perf_counter()
    try:
        if op == "put":
            code = req("POST", f"/dbs/{db}/colls/c/docs", json.dumps({"id": f"t19-{i}", "v": i}).encode())
        else:
            code = req("GET", f"/dbs/{db}/colls/c/docs/t19-{i}")
    except Exception as e:
        print(f"TRANSPORT {op} #{i}: {e}", file=sys.stderr); err += 1; continue
    lat.append((time.perf_counter()-s0)*1000)
    if code in (200, 201): ok += 1
    else:
        err += 1
        print(f"HTTP {op} #{i}: {code}", file=sys.stderr)
wall = time.perf_counter()-t0
sl = sorted(lat)
p = lambda q: round(sl[min(len(sl)-1, int(q*len(sl)))], 2)
print(json.dumps({"n": n, "ops_per_sec": round(n/wall, 1),
                  "p50_ms": p(.5), "p95_ms": p(.95), "p99_ms": p(.99), "errors": err}))
sys.exit(0 if err == 0 else 1)
PY
}

# hold-open generator: one persistent keep-alive connection issuing continuous
# loopback gets for the whole observation window — gives the monitor a stable
# ESTABLISHED fixture to sample (without it the ~0.2s workload is easy to miss).
python3 - "$DATA" <<'PYHOLD' &
import sys, time, http.client
port = int(sys.argv[1])
end = time.time() + 12
conn = http.client.HTTPConnection("127.0.0.1", port, timeout=10)
while time.time() < end:
    try:
        conn.request("GET", "/dbs/scvd-airgap/colls/c/docs/t19-0")
        r = conn.getresponse(); r.read()
    except Exception:
        conn.close(); conn = http.client.HTTPConnection("127.0.0.1", port, timeout=10)
PYHOLD
HOLDPID=$!

for op in put get; do
  # warm-up: ensure db/container exist (first put creates them)
  STATS="$(run_ops "$op" 200)" || true
  eval "$(python3 -c "import json,sys; d=json.loads(sys.argv[1]); print(' '.join(f'{k}={v}' for k,v in d.items()))" "$STATS")"
  bench_emit "$OUT" "cosmos-http" "$op" "$n" "$ops_per_sec" "$p50_ms" "$p95_ms" "$p99_ms" "$errors"
done

kill "$MONPID" "$HOLDPID" 2>/dev/null || true; wait "$MONPID" "$HOLDPID" 2>/dev/null || true

echo "== leg 3: verdict =="
NONLB=$(grep -vE '127\.0\.0\.1|::1|localhost|\*:\*|\* ' "$MON" 2>/dev/null | grep -E 'ESTABLISHED|SYN_SENT' | wc -l | tr -d ' ' || true)
ESTLOOP=$(grep -E '127\.0\.0\.1.*ESTABLISHED|::1.*ESTABLISHED' "$MON" 2>/dev/null | wc -l | tr -d ' ' || true)
if [ "$NONLB" -eq 0 ] && [ "$CENSUS_HITS" -eq 0 ] && [ "$ESTLOOP" -gt 0 ]; then
  VERDICT="PASS (non-vacuous: $ESTLOOP loopback ESTABLISHED samples observed)"
else
  VERDICT="FAIL"
  echo "NON-LOOPBACK SAMPLES: $NONLB" >&2
  grep -vE '127\.0\.0\.1|::1|localhost' "$MON" | grep -E 'ESTABLISHED|SYN_SENT' >&2 || true
fi
printf '{"lane":"%s","surface":"airgap-court","op":"%s","n":1,"ops_per_sec":0,"p50_ms":0,"p95_ms":0,"p99_ms":0,"errors":%s,"machine":%s,"census_hits":%s,"non_loopback_samples":%s,"established_loopback_samples":%s}\n' \
  "$BENCH_LANE" "$VERDICT" "$((NONLB > 0 ? 1 : 0))" "$(bench_machine_spec)" "$CENSUS_HITS" "$NONLB" "$ESTLOOP" >>"$OUT"
echo "VERDICT=$VERDICT census_hits=$CENSUS_HITS non_loopback_samples=$NONLB established_loopback_samples=$ESTLOOP monitor_samples=$(wc -l <"$MON" | tr -d ' ')"
cat "$OUT"
