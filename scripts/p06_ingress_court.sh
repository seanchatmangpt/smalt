#!/usr/bin/env bash
# p06_ingress_court.sh — P06: ACA ingress parity — canonical-origin 308
# law, X-Forwarded-Proto trust, zero redirect loops. Scenario-scoped env
# flip (CANONICAL_ORIGIN/REDIRECT_HOSTS), asserts, restore.
set -uo pipefail
export PATH="$HOME/.asdf/shims:$PATH"
NS=default
CTX=kind-smalt
WEB_DEPLOY=courtroom-web
PASS=0; FAIL=0
say() { echo "[P06] $*"; }
ok() { PASS=$((PASS+1)); say "PASS $1"; }
bad() { FAIL=$((FAIL+1)); say "FAIL $1"; }

pf() {
  kubectl --context $CTX -n $NS port-forward svc/$WEB_DEPLOY 3000:3000 >/dev/null 2>&1 &
  PFPID=$!
  for i in $(seq 1 40); do curl -s -o /dev/null http://127.0.0.1:3000/ && break; sleep 0.25; done
}
unpf() { kill $PFPID 2>/dev/null; }

say "flipping CANONICAL_ORIGIN/REDIRECT_HOSTS"
kubectl --context $CTX -n $NS set env deploy/$WEB_DEPLOY \
  CANONICAL_ORIGIN=http://courtroom-web.default.svc.cluster.local:3000 \
  REDIRECT_HOSTS=localhost:3000 >/dev/null
kubectl --context $CTX -n $NS rollout status deploy/$WEB_DEPLOY --timeout=120s >/dev/null 2>&1
pf

# 1. Listed host (localhost:3000) -> 308 to canonical.
st=$(curl -s -o /dev/null -w '%{http_code}' -H 'Host: localhost:3000' http://127.0.0.1:3000/)
[ "$st" = "308" ] && ok "listed-host-308 (got $st)" || bad "listed-host-308 (got $st)"
loc=$(curl -s -o /dev/null -w '%{redirect_url}' -H 'Host: localhost:3000' http://127.0.0.1:3000/)
echo "$loc" | grep -q 'courtroom-web.default.svc.cluster.local:3000' && ok "308-target-canonical" || bad "308-target-canonical ($loc)"

# 2. Follow the 308 (canonical host) -> 200, no loop (bounded).
st2=$(curl -s -o /dev/null -w '%{http_code}' --max-redirs 3 -L -H 'Host: courtroom-web.default.svc.cluster.local' http://127.0.0.1:3000/)
[ "$st2" = "200" ] && ok "canonical-200-no-loop" || bad "canonical-200-no-loop (got $st2)"

# 3. Unlisted host -> 200 (no redirect).
st3=$(curl -s -o /dev/null -w '%{http_code}' -H 'Host: unlisted.example.test' http://127.0.0.1:3000/)
[ "$st3" = "200" ] && ok "unlisted-host-200" || bad "unlisted-host-200 (got $st3)"

# 4. X-Forwarded-Proto https through a proxy front honors trust (the ACA
#    100.64.0.0/10 contract): the app must NOT drop the proto.
hdr=$(curl -s -D - -o /dev/null -H 'Host: courtroom-web.default.svc.cluster.local' -H 'X-Forwarded-Proto: https' http://127.0.0.1:3000/api/health | head -1)
echo "$hdr" | grep -q 200 && ok "forwarded-proto-health-200" || bad "forwarded-proto-health-200 ($hdr)"

unpf
say "restoring env"
kubectl --context $CTX -n $NS set env deploy/$WEB_DEPLOY CANONICAL_ORIGIN- REDIRECT_HOSTS- >/dev/null
kubectl --context $CTX -n $NS rollout status deploy/$WEB_DEPLOY --timeout=120s >/dev/null 2>&1
pf
st=$(curl -s -o /dev/null -w '%{http_code}' -H 'Host: localhost:3000' http://127.0.0.1:3000/)
[ "$st" = "200" ] && ok "restore-200" || bad "restore-200 (got $st)"
unpf

echo "[P06] verdict: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
