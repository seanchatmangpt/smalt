#!/usr/bin/env bash
# t45 BOOTPROF lane — NFR-FOOTPRINT boot-phase profiler.
#
# Boots N fresh private-port substrates sequentially (39940..39945, lock fd
# closed, never touches the shared substrate), each instrumented by
# tmp/bench/t45_boot_eval.exs which stamps phases inside the VM:
#   phase A  mix/beam pre-eval overhead (wall t0 -> eval entered)
#   phase B  per-dep-app Application.ensure_all_started, individually timed
#   phase C  ETS table creations (dbg trace on :ets.new) + Logger events,
#            both stamped with ms-since-VM-start
#   phase D  first listener accepting (in-VM gen_tcp connect poll)
#
# Emits ONLY tmp/bench/t45-boot-phases.jsonl (lane result-file law).
# Run: bash scripts/bench/t45_boot_phases.sh [N_boots]
set -euo pipefail
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$REPO"
OUT="$REPO/tmp/bench/t45-boot-phases.jsonl"
LOG="$REPO/tmp/t45-boot-substrate.log"
PORTS="39940 39941 39942 39943 39944 39945"
NBOOTS="${1:-3}"

for p in $PORTS; do
  if lsof -nP -iTCP:"$p" -sTCP:LISTEN >/dev/null 2>&1; then
    echo "t45: TYPED-BLOCKED: port $p held — refusing to boot (collision)" >&2
    exit 1
  fi
done

mkdir -p tmp/bench
MACHINE=$(python3 - <<'PY'
import json, os, sys
def g(cmd):
    return os.popen(cmd).read().strip()
print(json.dumps({
  "cpu": g("sysctl -n machdep.cpu.brand_string"),
  "cores": g("sysctl -n hw.ncpu"),
  "ram_gb": int(int(g("sysctl -n hw.memsize"))/2**30),
  "elixir": g("elixir -e 'IO.puts System.version()' | tail -1"),
  "otp": g("elixir -e 'IO.puts :erlang.system_info(:otp_release)' | tail -1"),
  "darwin": g("sw_vers -productVersion"),
}))
PY
)

for n in $(seq 1 "$NBOOTS"); do
  # Bounded pre-flight that the block is free (repeat each boot: prior boot exited).
  t0_ms=$(python3 -c 'import time; print(int(time.time()*1000))')
  set +e
  T45_T0_MS="$t0_ms" MIX_ENV=test MIX_BUILD_ROOT="_build-t45" \
  SMALT_TEST_ARM_PORT=39940 SMALT_TEST_EGRESS_PORT=39941 \
  SMALT_TEST_AMQP_PORT=39942 SMALT_TEST_EVENT_HUBS_PORT=39943 \
  SMALT_TEST_ARM_TLS_PORT=39944 SMALT_TEST_MCP_PORT=39945 \
    mix run --no-start "tmp/bench/t45_boot_eval.exs" \
    >"$LOG-$n" 2>&1 </dev/null 9>&-
  rc=$?
  set -e
  t1_ms=$(python3 -c 'import time; print(int(time.time()*1000))')

  if [ "$rc" -ne 0 ] || ! grep -q T45DONE "$LOG-$n"; then
    echo "t45: boot $n FAILED rc=$rc — log: $LOG-$n" >&2
    tail -20 "$LOG-$n" >&2
    exit 1
  fi

  python3 - "$n" "$rc" "$t0_ms" "$t1_ms" "$MACHINE" "$OUT" <<'PY'
import json, sys, os
n, rc, t0, t1, machine, out = sys.argv[1], int(sys.argv[2]), int(sys.argv[3]), int(sys.argv[4]), json.loads(sys.argv[5]), sys.argv[6]
vm = json.load(open("tmp/bench/t45-vm-stamps.json"))
bootlog = []
p = "tmp/bench/t45-bootlog.stream"
if os.path.exists(p):
    for line in open(p):
        f = line.split(None, 3)
        if len(f) == 4 and f[0] == "BOOTLOG":
            bootlog.append({"ms": int(f[1]), "level": f[2], "msg": f[3].strip()[:300]})
ets = []
p = "tmp/bench/t45-ets.stream"
if os.path.exists(p):
    for line in open(p):
        f = line.split(None, 2)
        if len(f) == 3 and f[0] == "ETS":
            ets.append({"ms": int(f[1]), "table": f[2].strip()[:120]})
apps = {a["app"]: a["ms"] for a in vm["apps"]}
top_apps = sorted(vm["apps"], key=lambda a: -a["ms"])[:5]
row = {
  "lane": "t45", "surface": "boot-phases", "op": f"cold-boot-{n}", "n": 1,
  "ops_per_sec": None,
  "p50_ms": vm["first_listener_ms_since_eval"],
  "p95_ms": vm["first_listener_ms_since_eval"],
  "p99_ms": vm["first_listener_ms_since_eval"],
  "errors": 0, "machine": machine,
  "detail": {
    "wall_total_ms": t1 - t0,
    "wall_to_eval_enter_ms": t0,
    "vm_uptime_ms_at_eval_enter": vm["vm_uptime_ms_at_eval_enter"],
    "wall_to_eval_enter_ms": vm["os_ms_at_eval_enter"] - t0,
    "post_listener_teardown_ms": (t1 - t0) - (vm["os_ms_at_eval_enter"] - t0) - vm["total_ms_since_eval_enter"],
    "apps_ms": apps,
    "top_apps": top_apps,
    "listeners": vm["listeners"],
    "first_listener_port": vm["first_listener_port"],
    "first_listener_ms_since_eval": vm["first_listener_ms_since_eval"],
    "total_ms_since_eval_enter": vm["total_ms_since_eval_enter"],
    "ets_tables": len(ets),
    "ets_first5": ets[:5],
    "bootlog_first10": bootlog[:10],
    "bootlog_n": len(bootlog),
  },
}
os.makedirs(os.path.dirname(out), exist_ok=True)
open(out, "a").write(json.dumps(row) + "\n")
print(f"boot {n}: wall={t1-t0}ms vm_uptime_at_eval={vm['vm_uptime_ms_at_eval_enter']}ms "
      f"total_in_vm={vm['total_ms_since_eval_enter']}ms "
      f"first_listener={vm['first_listener_ms_since_eval']}ms "
      f"wall_to_eval={vm['os_ms_at_eval_enter']-t0}ms teardown={ (t1-t0)-(vm['os_ms_at_eval_enter']-t0)-vm['total_ms_since_eval_enter'] }ms "
      f"top_apps={[(a['app'], a['ms']) for a in top_apps]}")
PY

  # reap bootlog/ets streams for the next boot
  rm -f tmp/bench/t45-bootlog.stream tmp/bench/t45-ets.stream tmp/bench/t45-vm-stamps.json
done
echo "t45: done — $OUT"
