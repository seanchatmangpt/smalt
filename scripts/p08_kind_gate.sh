#!/usr/bin/env bash
# p08_kind_gate.sh — the v26.10.30 milestone gate, one command.
# Boots/verifies the in-cluster topology (the kind court, 9/9 flow),
# then runs every P-wave scenario court, then emits the manufacturing
# receipt. Exit 0 only when every leg is green.
set -uo pipefail
export PATH="$HOME/.asdf/shims:$PATH"
export KUBECONFIG="${KUBECONFIG:-$HOME/.kube/config}"
cd /Users/sac/smalt
LOGDIR=/tmp/p08-gate
mkdir -p "$LOGDIR"
SUMMARY="$LOGDIR/summary.tsv"
: > "$SUMMARY"
START=$(date +%s)

stage() {
  local name="$1"; shift; shift
  echo "== [P08-GATE] $name $(date +%H:%M:%S)"
  "$@" >"$LOGDIR/$name.log" 2>&1
  local rc=$?
  printf '%s\t%s\n' "$name" "$rc" >>"$SUMMARY"
  echo "== [P08-GATE] $name rc=$rc"
}

stage kind_court_9x9 -- bash scripts/courtroom_kind_court.sh

# The driver pod carries the browser scenarios.
run_driver_retry() {
  run_driver "$@" && return 0
  echo "== [P08-GATE] retry $*"
  run_driver "$@"
}

run_driver() {
  kubectl --context kind-smalt -n smalt delete pod r30-driver --force --grace-period=0 >/dev/null 2>&1
  kubectl --context kind-smalt apply -f k8s/r30-driver.yaml >/dev/null
  kubectl --context kind-smalt -n smalt wait --for=condition=Ready pod/r30-driver --timeout=180s >/dev/null 2>&1
  timeout 20 kubectl --context kind-smalt -n smalt exec r30-driver -- sh -c "cd /court && timeout $1 node $2 2>&1"
}

stage readiness -- timeout 600 bash -c '
  for i in $(seq 1 90); do
    timeout 20 kubectl --context kind-smalt -n smalt exec r30-driver -- node -e "
const http = require("http");
const get = (u) => new Promise(r => { const q = http.get(u, x => { x.resume(); x.on("end", () => r(x.statusCode)); }); q.on("error", () => r(0)); q.setTimeout(4000, () => { q.destroy(); r(0); }); });
(async () => { const a = await get("http://localhost:3000/api/health"); const b = await get("http://localhost:9446/organizations/.well-known/openid-configuration"); console.log(a, b); process.exit(a === 200 && b === 200 ? 0 : 1); })();
" >/dev/null 2>&1 && break
    sleep 5
  done'

stage p01_browser_saml -- run_driver 300 p01.mjs
stage p02_slo_roundtrip -- run_driver_retry 300 p02.mjs
stage p03_browser_oidc -- run_driver_retry 300 p03.mjs
stage p04_concurrency -- run_driver 330 p04.mjs
stage p05_tenant_fence -- bash scripts/p05_fence_browser.sh
stage p06_ingress_parity -- bash scripts/p06_ingress_court.sh

# Stale driver pods from earlier legs must not leak.
stage cleanup_driver -- kubectl --context kind-smalt -n smalt delete pod r30-driver --force --grace-period=0

END=$(date +%s)
PASS=$(awk -F'\t' '$2==0' "$SUMMARY" | wc -l | tr -d ' ')
TOTAL=$(wc -l <"$SUMMARY" | tr -d ' ')
VERDICT=ALIVE
[ "$PASS" -eq "$TOTAL" ] || VERDICT=PARTIAL_ALIVE

{
  echo "# r-p08-kind-gate — one-command milestone gate run"
  echo
  echo "- date: $(date -u +%FT%TZ) · wall: $((END - START))s · verdict: **$VERDICT ($PASS/$TOTAL legs rc=0)**"
  echo
  echo "| leg | rc |"
  echo "|---|---|"
  while IFS=$'\t' read -r n rc; do echo "| $n | $rc |"; done <"$SUMMARY"
  echo
  echo "## Embedded evidence (leg log tails)"
  for f in "$LOGDIR"/*.log; do
    echo "### $(basename "$f")"
    echo '```'
    grep -E 'COURT-VERDICT|FLOW-VERDICT|verdict|P0[1-6]-PASS|PASS \w|verdict: [0-9]' "$f" 2>/dev/null | tail -3
    echo '```'
  done
} > docs/jira/v26.10.30/receipts/r-p08-kind-gate-run.md
echo "== [P08-GATE] verdict: $VERDICT ($PASS/$TOTAL) — receipt r-p08-kind-gate-run.md"
[ "$VERDICT" = "ALIVE" ]
