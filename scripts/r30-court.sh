#!/usr/bin/env bash
# P09 lane (v26.10.30) — one-command identity-topology court (r30 surfaces).
#
# Applies the r30 identity topology to the kind cluster `smalt`, runs the
# in-cluster multi-redirect identity-resolution probe, witnesses TLS trust
# with curl --cacert from the host, fences TLS-trust bypass strings, and
# prints the r30 resource inventory. Fail-closed: any failed stage exits 1.
#
# Coordination: never touches the KIND-E2E lane's surfaces (courtroom-*,
# smalt-backend — namespace default) or any secret it does not own. The kind
# cluster itself is left up.
#
# No Process.sleep: readiness is bounded-polled via kubectl wait / curl
# --retry on real observables only.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
NS="smalt"
LOGDIR="/tmp/r30-court"
PORT_IDP=19445
PORT_OIDC=19446
mkdir -p "$LOGDIR"

NAMES=()
RCS=()

stage() {
  local name="$1"; shift
  NAMES+=("$name")
  echo "--- s:${name}"
  "$@" >>"$LOGDIR/court.log" 2>&1
  local rc=$?
  RCS+=("$rc")
  echo "STAGE ${name} :: rc=${rc}"
  return 0
}

kill_pfs() { local p; for p in $PFPIDS; do kill "$p" 2>/dev/null || true; done; }

echo "r30 court — P09 identity topology & trust wiring"
echo "repo: $ROOT"
echo "log:  $LOGDIR"
date -u +"court start (UTC): %Y-%m-%dT%H:%M:%SZ"
echo

: >"$LOGDIR/court.log"

# s00 context guard — never mutate anything but the kind cluster `smalt`.
CTX="$(kubectl config current-context 2>/dev/null || true)"
if [ "$CTX" != "kind-smalt" ]; then
  echo "STAGE s00 context-guard :: rc=1 REFUSED (kubectl context '$CTX' is not kind-smalt)" | tee -a "$LOGDIR/court.log"
  exit 1
fi
NAMES+=("s00-context-guard"); RCS+=("0")
echo "STAGE s00-context-guard :: rc=0 (kind-smalt)"

# s01 contention check (read-only): report, never touch, other lanes' surfaces.
CONTEND="$(kubectl get deploy,svc -A 2>/dev/null | grep -E 'courtroom-|smalt-backend' || true)"
if [ -n "$CONTEND" ]; then
  echo "INFO other-lane surfaces present (read-only, untouched):"
  echo "$CONTEND"
else
  echo "INFO no courtroom-*/smalt-backend surfaces present (KIND-E2E r13 s15 teardown state)"
fi
NAMES+=("s01-contention-check"); RCS+=("0")

stage s02-namespace kubectl apply -f "$ROOT/k8s/r30-00-namespace.yaml"
stage s03-ca-secret "$ROOT/scripts/r30-mint_leaf.sh"
stage s04-identity kubectl apply -f "$ROOT/k8s/r30-10-identity.yaml"

stage s05-wait-deploy kubectl -n "$NS" wait --for=condition=available deployment/r30-identity --timeout=300s
stage s06-wait-pods kubectl -n "$NS" wait --for=condition=ready pods -l app=r30-identity --timeout=120s

# Idempotent probe rerun: replace the job, apply the ConfigMap+Job.
stage s07-probe-apply bash -c "kubectl -n $NS delete job r30-probe --ignore-not-found >/dev/null 2>&1; kubectl apply -f $ROOT/k8s/r30-20-probe.yaml"
stage s08-wait-probe kubectl -n "$NS" wait --for=condition=complete job/r30-probe --timeout=240s

# s09 probe transcript (of record, always captured even on failure).
kubectl -n "$NS" logs job/r30-probe >"$LOGDIR/probe.log" 2>&1
if ! grep -q "R30-PROBE VERDICT" "$LOGDIR/probe.log"; then
  kubectl -n "$NS" describe job/r30-probe >>"$LOGDIR/probe.log" 2>&1
  kubectl -n "$NS" get pods -l job-name=r30-probe -o wide >>"$LOGDIR/probe.log" 2>&1
fi
NAMES+=("s09-probe-transcript")
if grep -q "R30-PROBE VERDICT :: PASS" "$LOGDIR/probe.log"; then
  RCS+=("0")
else
  RCS+=("1")
fi
echo "--- s09 probe transcript (in-cluster, node:22-alpine, NODE_EXTRA_CA_CERTS)"
cat "$LOGDIR/probe.log"

# s10 host-side curl --cacert witness: the CA is the ONLY trust material and
# the name is validated through --resolve (bounded poll via curl --retry;
# never a shell sleep). Port-forwards are killed by exact PID, never by
# process-name pattern.
echo "--- s10 host curl --cacert witness"
PFPIDS=""
trap kill_pfs EXIT

kubectl -n "$NS" port-forward "svc/idp" "$PORT_IDP:9445" >/dev/null 2>&1 &
PFPIDS="$PFPIDS $!"
kubectl -n "$NS" port-forward "svc/oidc" "$PORT_OIDC:9446" >/dev/null 2>&1 &
PFPIDS="$PFPIDS $!"

S10_RC=0
CURL_IDP="$(curl -sS --cacert "$ROOT/.smalt/tls/ca-cert.pem" \
  --resolve "idp.smalt.svc.cluster.local:$PORT_IDP:127.0.0.1" \
  --retry 20 --retry-delay 1 --retry-connrefused --connect-timeout 2 --max-time 40 \
  -o "$LOGDIR/idp-metadata.xml" -w "%{http_code}" \
  "https://idp.smalt.svc.cluster.local:$PORT_IDP/metadata" 2>"$LOGDIR/curl-idp.err")" || S10_RC=1
CURL_OIDC="$(curl -sS --cacert "$ROOT/.smalt/tls/ca-cert.pem" \
  --resolve "oidc.smalt.svc.cluster.local:$PORT_OIDC:127.0.0.1" \
  --retry 20 --retry-delay 1 --retry-connrefused --connect-timeout 2 --max-time 40 \
  -o "$LOGDIR/oidc-discovery.json" -w "%{http_code}" \
  "https://oidc.smalt.svc.cluster.local:$PORT_OIDC/organizations/.well-known/openid-configuration" 2>"$LOGDIR/curl-oidc.err")" || S10_RC=1

IDP_OK=0; OIDC_OK=0
[ "$CURL_IDP" = "200" ] && grep -q 'entityID="urn:smalt:identity:saml"' "$LOGDIR/idp-metadata.xml" && IDP_OK=1
[ "$CURL_OIDC" = "200" ] && grep -q '"issuer":"https://oidc.smalt.svc.cluster.local:9446/organizations/v2.0"' "$LOGDIR/oidc-discovery.json" && OIDC_OK=1
if [ "$S10_RC" = "0" ] && [ "$IDP_OK" = "1" ] && [ "$OIDC_OK" = "1" ]; then
  NAMES+=("s10-curl-cacert"); RCS+=("0")
  echo "STAGE s10-curl-cacert :: rc=0 (metadata 200 + discovery 200 over CA-validated names, zero bypass flags)"
  echo "discovery head: $(head -c 300 "$LOGDIR/oidc-discovery.json")"
else
  NAMES+=("s10-curl-cacert"); RCS+=("1")
  echo "STAGE s10-curl-cacert :: rc=1 (idp_http=$CURL_IDP oidc_http=$CURL_OIDC) see $LOGDIR/curl-*.err"
fi
kill_pfs
trap - EXIT

# s11 self-fence: zero TLS-trust bypass strings in this lane's artifacts.
# The pattern is assembled from split literals so this fence line cannot
# self-match.
FENCE_PAT='ignoreHTTPS''Errors|rejectUnauthor''ized'
FENCE_HITS="$(grep -rnE "$FENCE_PAT" "$ROOT/k8s"/r30-*.yaml "$ROOT/scripts"/r30-* 2>/dev/null || true)"
NAMES+=("s11-bypass-fence")
if [ -n "$FENCE_HITS" ]; then
  RCS+=("1")
  echo "STAGE s11-bypass-fence :: rc=1 — HITS:"
  echo "$FENCE_HITS"
else
  RCS+=("0")
  echo "STAGE s11-bypass-fence :: rc=0 (zero hits across k8s/r30-*.yaml + scripts/r30-*)"
fi
echo "fence command: grep -rnE '<ignoreHTTPSErrors|rejectUnauthorized>' k8s/r30-*.yaml scripts/r30-*  (pattern split-literal above)"

stage s12-inventory kubectl -n "$NS" get deploy,pod,svc,secret,configmap,job -o wide
echo "--- s12 r30 resource inventory (namespace smalt)"
kubectl -n "$NS" get deploy,pod,svc,secret,configmap,job -o wide
kubectl -n "$NS" get events --sort-by=.lastTimestamp | tail -15 >>"$LOGDIR/court.log" 2>&1

# Verdict (fail-closed).
FAILS=0
echo
echo "=== r30 court stage table ==="
i=0
while [ $i -lt ${#NAMES[@]} ]; do
  rc="${RCS[$i]}"
  printf '%-26s rc=%s\n' "${NAMES[$i]}" "$rc"
  [ "$rc" != "0" ] && FAILS=$((FAILS + 1))
  i=$((i + 1))
done
echo "transcripts: $LOGDIR/court.log $LOGDIR/probe.log $LOGDIR/idp-metadata.xml $LOGDIR/oidc-discovery.json"
if [ "$FAILS" != "0" ]; then
  echo "--- court.log tail (failure detail)"
  tail -40 "$LOGDIR/court.log"
  echo "R30 COURT VERDICT :: FAIL ($FAILS failed stage(s))"
  exit 1
fi
echo "R30 COURT VERDICT :: PASS"
exit 0
