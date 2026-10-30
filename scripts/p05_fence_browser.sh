#!/usr/bin/env bash
# p05_fence_browser.sh — P05: cross-tenant breach prevention witnessed
# from the browser: with the api's ENTRA_TENANT_ID flipped to a foreign
# tenant, the substrate's assertion (tenant A) fails the fence law and
# the consumer answers a typed, data-free denial through the full
# browser → ingress → api path. Restores config after.
set -uo pipefail
export PATH="$HOME/.asdf/shims:$PATH"
CTX=kind-smalt
PASS=0; FAIL=0
say() { echo "[P05] $*"; }
ok() { PASS=$((PASS+1)); say "PASS $1"; }
bad() { FAIL=$((FAIL+1)); say "FAIL $1"; }

say "flipping api tenant to a foreign GUID (fence scenario)"
kubectl --context $CTX -n default set env deploy/courtroom-api \
  ENTRA_TENANT_ID=99999999-9999-4999-8999-999999999999 >/dev/null
kubectl --context $CTX -n default rollout status deploy/courtroom-api --timeout=120s >/dev/null 2>&1

kubectl --context $CTX -n smalt exec r30-driver -- node -e "
const http = require('http');
const poll = (n) => http.get('http://localhost:3000/api/health', r => { let b=''; r.on('data', d=>b+=d); r.on('end', () => { if (b.includes('"configured":true')) { console.log('api-ready'); process.exit(0); } if (n <= 0) { console.log('api-not-ready'); process.exit(1); } setTimeout(() => poll(n-1), 1000); }); }).on('error', () => { if (n <= 0) process.exit(1); setTimeout(() => poll(n-1), 1000); });
poll(60);" 2>&1 | tail -1
kubectl --context $CTX -n smalt exec r30-driver -- sh -c 'cd /court && timeout 120 node p01.mjs 2>&1' | tail -1 > /tmp/p05-run.json
cat /tmp/p05-run.json | head -c 300; echo
grep -q 'access_denied' /tmp/p05-run.json && ok "foreign-tenant-typed-denial" || bad "foreign-tenant-typed-denial"
grep -q 'P01-FAIL' /tmp/p05-run.json && ok "no-session-issued" || bad "no-session-issued (a session leaked through the fence)"
grep -qv 'smalt-user\|"authorized":true' /tmp/p05-run.json && ok "error-payload-data-free" || bad "error-payload-data-free"

say "restoring tenant"
kubectl --context $CTX -n default set env deploy/courtroom-api \
  ENTRA_TENANT_ID=11111111-1111-4111-8111-111111111111 >/dev/null
kubectl --context $CTX -n default rollout status deploy/courtroom-api --timeout=120s >/dev/null 2>&1
kubectl --context $CTX -n smalt exec r30-driver -- sh -c 'cd /court && timeout 120 node p01.mjs 2>&1' | grep -o '"verdict":"[^"]*"' | tail -1 | head -c 60
echo " <- post-restore sign-in"
grep -q 'P01-PASS' /tmp/p05-run.json 2>/dev/null || true

echo "[P05] verdict: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
