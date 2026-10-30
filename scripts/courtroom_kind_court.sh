#!/usr/bin/env bash
# scripts/courtroom_kind_court.sh — lane KIND-E2E (v26.10.29): kind-cluster
# end-to-end proof that courtroom-platform-az runs on smalt with ZERO cloud
# and ZERO writes to the consumer repo.
#
# Topology (all in kind ns default):
#   courtroom-web (Next.js, public origin) --proxy /api/*,/saml/*-->
#     courtroom-api (express + @node-saml) --redis wire--> courtroom-smalt
#                                           --saml sso--> courtroom-smalt (IdP)
# Flow driver: a node script in a courtroom-driver pod (real in-cluster HTTP,
# manual cookie jar — accommodation note in the embedded flow.mjs header).
#
# Stages (each rc-captured, never a silent skip):
#   s01 tools        s05 smalt image (+load)   s09 secrets
#   s02 docker up    s06 materialize consumer  s10 apply manifests
#   s03 kind-up      s07/s08 api/web images    s11 wait ready
#   s04 compile gate                           s12 store=redis evidence
#   s13 host port-forward web / -> 200 + /api/health proxied
#   s14 in-cluster SSO flow (driver pod)
#   s15 teardown policy (PASS keeps; FAIL deletes lane-owned resources only)
#
# Exit contract: 0 pass / 1 assert fail / 2 infra never up / 3 loud skip.
# Receipt: docs/jira/v26.10.29/receipts/r13-kind-e2e.md
set -uo pipefail

SMALT=/Users/sac/smalt
CONSUMER=/Users/sac/cai/courtroom-platform-az
SCRATCH=/tmp/courtroom-kind-e2e
NS=default
WEB_ORIGIN="http://courtroom-web.$NS.svc.cluster.local:3000"
IDP_BASE="http://courtroom-smalt.$NS.svc.cluster.local:19445"
TLS_DIR="$SMALT/.smalt/tls"
PF_PORT=13000
CLUSTER=""
PF_PID=""
COMPILE_GATE_SECS=${KIND_E2E_COMPILE_GATE_SECS:-1800}   # 30 min
READY_TIMEOUT=${KIND_E2E_READY_TIMEOUT:-420}            # 7 min

mkdir -p "$SCRATCH"
LOG="$SCRATCH/court.log"
: > "$LOG"
RAW="$SCRATCH/stages.raw"
: > "$RAW"

say() { echo "[KIND-E2E] $*" | tee -a "$LOG"; }
stage() { # stage <name> <rc>
  echo "rc_$1=$2" >> "$RAW"
  say "stage $1 rc=$2"
}
poll_step() { sleep "${1:-5}"; } # SLEEP-CLASS: POLL-STEP (bounded poll tick)

finish() { # finish <code> <verdict>
  say "COURT-VERDICT: $2 (exit $1)"
  echo "verdict=$2" >> "$RAW"
  exit "$1"
}

fail_all() { # fail_all <verdict> <code> — typed failure teardown: delete ONLY
             # lane-owned resources (3 manifests + 3 secrets + driver pod);
             # keep the kind cluster and all /tmp logs.
  say "[TEARDOWN-FAIL] deleting lane-owned resources (cluster kept; logs in $SCRATCH)"
  local m
  for m in courtroom-smalt.yaml courtroom-api.yaml courtroom-web.yaml; do
    kubectl delete -f "$SMALT/k8s/$m" --ignore-not-found >/dev/null 2>&1
  done
  kubectl -n "$NS" delete secret courtroom-smalt-tls courtroom-idp-cert courtroom-session-secret --ignore-not-found >/dev/null 2>&1
  kubectl -n "$NS" delete pod courtroom-driver --force --grace-period=0 --ignore-not-found --wait=180s >/dev/null 2>&1
  for wi in $(seq 1 240); do kubectl -n "$NS" get pod courtroom-driver >/dev/null 2>&1 || break; sleep 0.5; done
  finish "$2" "$1"
}

cleanup() {
  [ -n "$PF_PID" ] && kill "$PF_PID" 2>/dev/null
  return 0
}
trap cleanup EXIT

# ============================================================================
# s01 — tools present (fail-closed, typed)
# ============================================================================
missing=""
for t in kind kubectl docker just openssl git; do
  command -v "$t" >/dev/null 2>&1 || missing="$missing $t"
done
if [ -n "$missing" ]; then
  say "[S01-PREREQ-FAIL] missing tools:$missing — install via brew"
  finish 3 "SKIP(TOOLS)"
fi
stage s01_tools 0

# ============================================================================
# s02 — docker/colima up (bounded poll 5 min; else colima start + 5 min)
# ============================================================================
docker_ok=0
deadline=$(( SECONDS + 300 ))
while [ "$SECONDS" -lt "$deadline" ]; do
  if docker info >/dev/null 2>&1; then docker_ok=1; break; fi
  poll_step 5
done
if [ "$docker_ok" -ne 1 ]; then
  say "[S02] docker not ready in 300s — attempting colima start"
  colima start 2>&1 | tail -3 | sed 's/^/[S02-colima] /' | tee -a "$LOG"
  deadline=$(( SECONDS + 300 ))
  while [ "$SECONDS" -lt "$deadline" ]; do
    if docker info >/dev/null 2>&1; then docker_ok=1; break; fi
    poll_step 5
  done
fi
if [ "$docker_ok" -ne 1 ]; then
  say "[S02-FAIL] docker/colima never came up (deadline 10 min total)"
  fail_all "INFRA-DOWN" 2
fi
docker version --format '{{.Server.Version}}' 2>/dev/null | sed 's/^/[S02] docker server: /' | tee -a "$LOG"
stage s02_docker 0

# ============================================================================
# s04-launch — compile quiet-window gate, BACKGROUND (overlaps s03-s08).
# The substrate image must carry the v26.10.29 faces (redis wire + saml idp),
# which live in the smalt WORKING TREE of concurrent lanes. If the tree does
# not compile clean, bounded-poll for a quiet window (deadline 30 min) else
# the court is a typed SKIP (3).
# ============================================================================
COMPILE_LOG="$SCRATCH/smalt-compile.log"
: > "$COMPILE_LOG"
(
  cd "$SMALT" || exit 97
  export PATH="$HOME/.asdf/shims:$PATH"
  attempt=0
  deadline=$(( SECONDS + COMPILE_GATE_SECS ))
  while [ "$SECONDS" -lt "$deadline" ]; do
    attempt=$(( attempt + 1 ))
    echo "=== attempt $attempt $(date '+%H:%M:%S') ===" >> "$COMPILE_LOG"
    if MIX_BUILD_ROOT=_build-kind mix compile >>"$COMPILE_LOG" 2>&1; then
      echo "=== COMPILE-OK attempt $attempt ===" >> "$COMPILE_LOG"
      exit 0
    fi
    echo "=== COMPILE-FAIL attempt $attempt ===" >> "$COMPILE_LOG"
    poll_step 60
  done
  exit 1
) &
COMPILE_PID=$!

# ============================================================================
# s03 — kind-up via the canonical recipe (idempotent) + context derivation
# ============================================================================
KIND_UP_OUT=$(just --justfile "$SMALT/Justfile" kind-up 2>&1)
KIND_UP_RC=$?
printf '%s\n' "$KIND_UP_OUT" | tail -8 | sed 's/^/[S03] /' | tee -a "$LOG"
stage s03_kind_up $KIND_UP_RC
if [ "$KIND_UP_RC" -ne 0 ]; then
  say "[S03-FAIL] just kind-up exited $KIND_UP_RC"
  fail_all "INFRA-DOWN" 2
fi

CTX=$(kubectl config current-context 2>/dev/null)
case "$CTX" in
  kind-*)
    CLUSTER="${CTX#kind-}"
    ;;
  *)
    say "[S03-FAIL] current-context '$CTX' is not a kind context after kind-up"
    fail_all "INFRA-DOWN" 2
    ;;
esac
say "[S03] cluster=$CLUSTER context=$CTX"

# ============================================================================
# s06 — materialize the consumer repo at HEAD into /tmp scratch (read-only)
# ============================================================================
CONSUMER_SHA=$(git -C "$CONSUMER" rev-parse HEAD 2>/dev/null)
if [ -z "$CONSUMER_SHA" ]; then
  say "[S06-FAIL] cannot rev-parse consumer HEAD"
  finish 3 "SKIP(MATERIALIZE)"
fi
MATERIAL="$SCRATCH/$CONSUMER_SHA"
rm -rf "$MATERIAL"
mkdir -p "$MATERIAL"
if ! git -C "$CONSUMER" archive HEAD | tar -x -C "$MATERIAL"; then
  say "[S06-FAIL] git archive|tar failed"
  finish 3 "SKIP(MATERIALIZE)"
fi
say "[S06] consumer HEAD $CONSUMER_SHA materialized at $MATERIAL"
stage s06_materialize 0

# ============================================================================
# s07/s08 — courtroom api + web images from the scratch materialization
# ============================================================================
build_and_load() { # build_and_load <df-abs> <tag>
  local df="$1" tag="$2"
  local out rc
  say "[BUILD] docker build -f $df -> $tag"
  out=$(docker build -f "$df" -t "$tag" "$MATERIAL" 2>&1)
  rc=$?
  printf '%s\n' "$out" | tail -4 | sed 's/^/[BUILD] /' | tee -a "$LOG"
  if [ "$rc" -ne 0 ]; then return "$rc"; fi
  out=$(kind load docker-image "$tag" --name "$CLUSTER" 2>&1)
  rc=$?
  printf '%s\n' "$out" | tail -2 | sed 's/^/[LOAD] /' | tee -a "$LOG"
  return "$rc"
}

build_and_load "$MATERIAL/apps/api/Dockerfile" "courtroom-api:kind"
API_RC=$?
stage s07_api_image $API_RC
build_and_load "$MATERIAL/apps/web/Dockerfile" "courtroom-web:kind"
WEB_RC=$?
stage s08_web_image $WEB_RC
if [ "$API_RC" -ne 0 ] || [ "$WEB_RC" -ne 0 ]; then
  say "[S07/S08-FAIL] courtroom image build/load failed (api=$API_RC web=$WEB_RC)"
  fail_all "FAIL(IMAGE-BUILD)" 1
fi

# node:22-alpine rides the daemon after the builds — load it for the driver
# pod so the cluster needs no registry access.
if kind load docker-image node:22-alpine --name "$CLUSTER" >/dev/null 2>&1; then
  say "[LOAD] node:22-alpine loaded for the driver pod"
else
  say "[LOAD-WARN] node:22-alpine load failed — driver pod may ImagePullBackOff"
fi

# ============================================================================
# s05 — join the compile gate; smalt image from the working tree (+load)
# ============================================================================
say "[S05] waiting on compile quiet-window gate (pid $COMPILE_PID, deadline ${COMPILE_GATE_SECS}s)"
wait "$COMPILE_PID"
COMPILE_RC=$?
stage s04_compile_gate $COMPILE_RC
if [ "$COMPILE_RC" -ne 0 ]; then
  say "[S05-SKIP] smalt working tree did not compile clean within ${COMPILE_GATE_SECS}s"
  tail -12 "$COMPILE_LOG" | sed 's/^/[S05-compile] /' | tee -a "$LOG"
  finish 3 "SKIP(COMPILE-WINDOW)"
fi
say "[S05] compile clean; building courtroom-smalt:kind from the working tree"
SMALT_SHA=$(git -C "$SMALT" rev-parse HEAD)
SMALT_IMG_OUT=$(docker build \
  -f "$SMALT/Dockerfile.smalt" \
  -t courtroom-smalt:kind \
  --build-arg SUBJECT_SHA="$SMALT_SHA" \
  --build-context ash_r2rml=/Users/sac/ash_r2rml \
  --build-context ash_graphlaw=/Users/sac/ash_graphlaw \
  --build-context ggen_igniter=/Users/sac/ggen_igniter \
  "$SMALT" 2>&1)
SMALT_RC=$?
printf '%s\n' "$SMALT_IMG_OUT" | tail -4 | sed 's/^/[S05-BUILD] /' | tee -a "$LOG"
if [ "$SMALT_RC" -ne 0 ]; then
  say "[S05-FAIL] courtroom-smalt:kind build exited $SMALT_RC"
  fail_all "FAIL(SMALT-IMAGE)" 1
fi
SMALT_LOAD_OUT=$(kind load docker-image courtroom-smalt:kind --name "$CLUSTER" 2>&1)
if [ $? -ne 0 ]; then
  say "[S05-FAIL] kind load courtroom-smalt:kind failed: $SMALT_LOAD_OUT"
  fail_all "FAIL(SMALT-IMAGE)" 1
fi
say "[S05] courtroom-smalt:kind built (subject $SMALT_SHA) and loaded"
stage s05_smalt_image 0

# ============================================================================
# s09 — Secrets: IdP TLS material (same PEM for smalt signing + api pinning)
#        and a random dev session secret. Never baked into images.
# ============================================================================
for f in dev-cert.pem dev-key.pem ca-cert.pem; do
  if [ ! -f "$TLS_DIR/$f" ]; then
    say "[S09-FAIL] $TLS_DIR/$f missing — run scripts/gen_dev_cert.sh"
    finish 3 "SKIP(TLS-MATERIAL)"
  fi
done
if ! kubectl -n "$NS" create secret generic courtroom-smalt-tls \
    --from-file=dev-cert.pem="$TLS_DIR/dev-cert.pem" \
    --from-file=dev-key.pem="$TLS_DIR/dev-key.pem" \
    --from-file=ca-cert.pem="$TLS_DIR/ca-cert.pem" \
    --dry-run=client -o yaml | kubectl apply -f - >/dev/null 2>&1; then
  say "[S09-FAIL] courtroom-smalt-tls secret apply failed"
  fail_all "FAIL(SECRET)" 1
fi
if ! kubectl -n "$NS" create secret generic courtroom-idp-cert \
    --from-file=dev-cert.pem="$TLS_DIR/dev-cert.pem" \
    --dry-run=client -o yaml | kubectl apply -f - >/dev/null 2>&1; then
  say "[S09-FAIL] courtroom-idp-cert secret apply failed"
  fail_all "FAIL(SECRET)" 1
fi
if ! kubectl -n "$NS" create secret generic courtroom-session-secret \
    --from-literal=secret="$(openssl rand -hex 32)" \
    --dry-run=client -o yaml | kubectl apply -f - >/dev/null 2>&1; then
  say "[S09-FAIL] courtroom-session-secret apply failed"
  fail_all "FAIL(SECRET)" 1
fi
say "[S09] secrets applied (courtroom-smalt-tls, courtroom-idp-cert, courtroom-session-secret)"
stage s09_secrets 0

# ============================================================================
# s10 — apply the lane-owned manifests (courtroom-smalt/api/web)
# ============================================================================
APPLY_RC=0
for m in courtroom-smalt.yaml courtroom-api.yaml courtroom-web.yaml; do
  out=$(kubectl apply -f "$SMALT/k8s/$m" 2>&1) || APPLY_RC=1
  printf '%s\n' "$out" | sed 's/^/[S10] /' | tee -a "$LOG"
done
stage s10_apply $APPLY_RC
if [ "$APPLY_RC" -ne 0 ]; then
  say "[S10-FAIL] manifest apply failed"
  fail_all "FAIL(APPLY)" 1
fi

# ============================================================================
# s11 — wait ready (bounded poll on real observables: pod Ready 1/1 x3)
# ============================================================================
say "[S11] waiting (deadline ${READY_TIMEOUT}s) for 3/3 courtroom pods Ready"
deadline=$(( SECONDS + READY_TIMEOUT ))
ready=0
while [ "$SECONDS" -lt "$deadline" ]; do
  ready_n=$(kubectl -n "$NS" get pods -l 'app in (courtroom-smalt,courtroom-api,courtroom-web)' --no-headers 2>/dev/null | awk '$2=="1/1"{n++} END{print n+0}')
  if [ "$ready_n" -ge 3 ]; then ready=1; break; fi
  poll_step 5
done
if [ "$ready" -ne 1 ]; then
  say "[S11-FAIL] pods not Ready within ${READY_TIMEOUT}s — witness:"
  kubectl -n "$NS" get pods -o wide 2>&1 | sed 's/^/[S11] /' | tee -a "$LOG"
  for d in courtroom-smalt courtroom-api courtroom-web; do
    kubectl -n "$NS" logs "deploy/$d" --tail=25 2>&1 | tail -12 | sed "s/^/[S11-$d] /" | tee -a "$LOG"
  done
  fail_all "FAIL(PODS-READY)" 1
fi
kubectl -n "$NS" get pods -o wide 2>&1 | grep -E 'NAME|courtroom' | sed 's/^/[S11] /' | tee -a "$LOG"
stage s11_wait_ready 0

# ============================================================================
# s12 — store=redis + wire face evidence from real logs
# ============================================================================
API_LOG=$(kubectl -n "$NS" logs deploy/courtroom-api --tail=200 2>/dev/null)
STORE_LINE=$(printf '%s' "$API_LOG" | grep -o '"store":"[a-z]*"' | head -1)
START_LINE=$(printf '%s' "$API_LOG" | grep -o '"event":"server_started"[^}]*}' | head -1)
say "[S12] api server_started: ${START_LINE:-NONE}"
if [ "$STORE_LINE" != '"store":"redis"' ]; then
  say "[S12-FAIL] api did not report redis store (got: ${STORE_LINE:-NONE})"
  printf '%s\n' "$API_LOG" | tail -30 | sed 's/^/[S12-api] /' | tee -a "$LOG"
  fail_all "FAIL(STORE-REDIS)" 1
fi
say "[S12] store line: $STORE_LINE"
SMALT_WIRE=$(kubectl -n "$NS" logs deploy/courtroom-smalt --tail=500 2>/dev/null | grep -o 'RESP2 wire listener bound on port [0-9]*' | tail -1)
say "[S12] smalt wire line: ${SMALT_WIRE:-NONE}"
stage s12_store_redis 0

# ============================================================================
# s13 — host evidence through port-forward: GET web / -> 200, /api/health
# ============================================================================
kubectl -n "$NS" port-forward svc/courtroom-web "$PF_PORT:3000" >/dev/null 2>&1 &
PF_PID=$!
pf_ok=0
code="none"
deadline=$(( SECONDS + 60 ))
while [ "$SECONDS" -lt "$deadline" ]; do
  code=$(curl -s -o "$SCRATCH/host-web-index.html" -w '%{http_code}' "http://127.0.0.1:$PF_PORT/" 2>/dev/null)
  if [ "$code" = "200" ]; then pf_ok=1; break; fi
  poll_step 3
done
if [ "$pf_ok" -ne 1 ]; then
  say "[S13-FAIL] host GET web / via port-forward failed (last code=$code)"
  fail_all "FAIL(HOST-WEB)" 1
fi
say "[S13] host curl http://127.0.0.1:$PF_PORT/ -> 200 ($(wc -c < "$SCRATCH/host-web-index.html" | tr -d ' ') bytes; $(grep -o '<title>[^<]*' "$SCRATCH/host-web-index.html" | head -1))"
PROX_CODE=$(curl -s -o "$SCRATCH/host-api-health.json" -w '%{http_code}' "http://127.0.0.1:$PF_PORT/api/health" 2>/dev/null)
say "[S13] host curl http://127.0.0.1:$PF_PORT/api/health -> $PROX_CODE $(cat "$SCRATCH/host-api-health.json" 2>/dev/null)"
if [ "$PROX_CODE" != "200" ]; then
  say "[S13-FAIL] /api/health via web proxy not 200 (got $PROX_CODE)"
  fail_all "FAIL(HOST-PROXY)" 1
fi
stage s13_host_web 0

# ============================================================================
# s14 — in-cluster SSO flow via the driver pod (real HTTP over svc DNS)
# ============================================================================
FLOW="$SCRATCH/flow.mjs"
cat > "$FLOW" <<'FLOW_EOF'
// courtroom kind E2E flow driver — runs IN-CLUSTER (courtroom-driver pod).
// Real HTTP against the real web/api/IdP; the only accommodation is a manual
// cookie jar that does not enforce the Secure attribute over plain http
// (the flow origin is cluster-internal service DNS; a real browser on the
// https ACA ingress enforces it — disclosed in receipt r13-kind-e2e.md).
const WEB = process.env.WEB_ORIGIN;
const IDP = process.env.IDP_BASE;
if (!WEB || !IDP) { console.error("FLOW-VERDICT: FAIL (WEB_ORIGIN/IDP_BASE unset)"); process.exit(2); }

const jar = []; // {name, value, domain, path}
function storeCookies(url, res) {
  const u = new URL(url);
  for (const c of res.headers.getSetCookie()) {
    const parts = c.split(";");
    const pair = parts[0] || "";
    const i = pair.indexOf("=");
    if (i <= 0) continue;
    const name = pair.slice(0, i).trim();
    const value = pair.slice(i + 1).trim();
    let domain = u.hostname;
    let path = "/";
    let expired = false;
    for (const a of parts.slice(1)) {
      const t = a.trim();
      const eq = t.indexOf("=");
      const k = (eq === -1 ? t : t.slice(0, eq)).toLowerCase();
      const v = eq === -1 ? "" : t.slice(eq + 1);
      if (k === "domain" && v) domain = v.replace(/^\./, "");
      if (k === "path" && v) path = v;
      if (k === "expires" && /01 jan 1970/i.test(v)) expired = true;
      if (k === "max-age" && v.trim() === "0") expired = true;
    }
    const idx = jar.findIndex((x) => x.name === name && x.domain === domain);
    if (expired) { if (idx >= 0) jar.splice(idx, 1); continue; }
    const rec = { name, value, domain, path };
    if (idx >= 0) jar[idx] = rec; else jar.push(rec);
  }
}
function cookieHeader(url) {
  const u = new URL(url);
  return jar
    .filter((c) => (u.hostname === c.domain || u.hostname.endsWith("." + c.domain)) && u.pathname.startsWith(c.path))
    .map((c) => `${c.name}=${c.value}`)
    .join("; ");
}
function snap() { return jar.map((c) => c.name).join(",") || "(empty)"; }

async function req(method, url, opts = {}) {
  const headers = { ...(opts.headers || {}) };
  const ck = cookieHeader(url);
  if (ck) headers.cookie = ck;
  const res = await fetch(url, {
    method, headers, redirect: "manual",
    body: opts.body, signal: AbortSignal.timeout(20000),
  });
  storeCookies(url, res);
  return res;
}

const results = [];
function assert(name, cond, evidence) {
  results.push({ name, ok: !!cond });
  console.log(`[flow] ${cond ? "PASS" : "FAIL"} ${name} :: ${evidence}`);
  return !!cond;
}

(async () => {
  let res = await req("GET", `${WEB}/`);
  const pageText = (await res.text()).slice(0, 120).replace(/\s+/g, " ");
  assert("web_home_200", res.status === 200, `status=${res.status} body[:120]=${pageText}`);

  res = await req("GET", `${WEB}/api/health`);
  const healthBody = await res.text();
  assert("api_health_via_proxy", res.status === 200 && healthBody.includes('"status":"ok"'), `status=${res.status} body=${healthBody.slice(0, 200)}`);

  res = await req("GET", `${WEB}/api/sso/status`);
  const ssoBody = await res.text();
  assert("sso_configured", res.status === 200 && ssoBody.includes('"configured":true'), `status=${res.status} body=${ssoBody.slice(0, 200)}`);

  res = await req("GET", `${WEB}/api/sso/start`);
  const loc = res.headers.get("location") || "";
  assert("sso_start_redirects_to_idp", res.status === 302 && loc.startsWith(`${IDP}/sso?`) && loc.includes("SAMLRequest="),
    `status=${res.status} location=${loc.slice(0, 110)} cookies=[${snap()}]`);

  res = await req("GET", new URL(loc, WEB).href);
  const html = await res.text();
  const actionRaw = (html.match(/action="([^"]+)"/) || [])[1] || "";
  // The baked APP_ORIGIN is the browser dev shape (http://localhost:3000);
  // the in-pod driver translates it to the web Service (curl-level flow,
  // cookie jar is host-agnostic in this driver).
  const action = actionRaw.replace("//localhost:3000", "//courtroom-web.default.svc.cluster.local:3000");
  const samlResponse = (html.match(/name="SAMLResponse" value="([^"]+)"/) || [])[1] || "";
  const relayState = (html.match(/name="RelayState" value="([^"]+)"/) || [])[1] || "";
  assert("idp_auto_post_form", res.status === 200 && samlResponse.length > 500, `status=${res.status} action=${action} SAMLResponse len=${samlResponse.length}`);

  const form = new URLSearchParams();
  form.set("SAMLResponse", samlResponse);
  if (relayState) form.set("RelayState", relayState);
  res = await req("POST", new URL(action, WEB).href, {
    headers: { "content-type": "application/x-www-form-urlencoded", "origin": WEB },
    body: form.toString(),
  });
  const acsLoc = res.headers.get("location") || "";
  await res.text();
  assert("acs_303_dashboard", res.status === 303 && acsLoc.includes("/dashboard"), `status=${res.status} location=${acsLoc} cookies=[${snap()}]`);

  res = await req("GET", `${WEB}/api/auth/me`);
  const meBody = await res.text();
  assert("auth_me_200_user", res.status === 200 && meBody.includes('"authenticated":true'), `status=${res.status} body=${meBody.slice(0, 240)}`);

  // The api's same-origin law compares Origin against APP_ORIGIN (the
  // baked browser dev shape http://localhost:3000), not the svc host.
  res = await req("POST", `${WEB}/api/auth/logout`, { headers: { "origin": "http://localhost:3000" } });
  const outBody = await res.text();
  assert("logout_200", res.status === 200 && outBody.includes('"loggedOut":true'), `status=${res.status} body=${outBody.slice(0, 160)}`);

  res = await req("GET", `${WEB}/api/auth/me`);
  assert("auth_me_401_after_logout", res.status === 401, `status=${res.status}`);

  const failed = results.filter((r) => !r.ok);
  console.log(`FLOW-VERDICT: ${failed.length ? "FAIL" : "PASS"} (${results.length - failed.length}/${results.length} steps)`);
  process.exit(failed.length ? 1 : 0);
})().catch((e) => { console.error(`FLOW-VERDICT: FAIL (driver error: ${e && e.message})`); process.exit(1); });
FLOW_EOF

say "[S14] deploying driver Deployment (node:22-alpine; rollout absorbs stale pods)"
# Declarative on purpose: a Deployment replaces any stale/Completed state
# (the `kubectl run` shape raced its own zombie pods — witnessed 4x on
# 2026-10-30, receipt r-p08-kind-gate-run.md).
cat <<'DRIVER_YAML' | kubectl -n "$NS" apply -f - >/dev/null 2>&1
apiVersion: apps/v1
kind: Deployment
metadata:
  name: courtroom-driver
spec:
  replicas: 1
  strategy: { type: Recreate }
  selector:
    matchLabels: { app: courtroom-driver }
  template:
    metadata:
      labels: { app: courtroom-driver }
    spec:
      containers:
        - name: d
          image: node:22-alpine
          imagePullPolicy: IfNotPresent
          command: ["sleep", "900"]
DRIVER_YAML
kubectl -n "$NS" delete pod -l app=courtroom-driver --force --grace-period=0 --wait=120s >/dev/null 2>&1 || true
drv_ok=0
st="none"
deadline=$(( SECONDS + 120 ))
while [ "$SECONDS" -lt "$deadline" ]; do
  st=$(kubectl -n "$NS" get pod courtroom-driver -o jsonpath='{.status.phase}' 2>/dev/null)
  if [ "$st" = "Running" ]; then drv_ok=1; break; fi
  poll_step 3
done
if [ "$drv_ok" -ne 1 ]; then
  say "[S14-FAIL] driver pod never Running (phase=$st)"
  kubectl -n "$NS" describe pod courtroom-driver 2>&1 | tail -12 | sed 's/^/[S14] /' | tee -a "$LOG"
  fail_all "FAIL(DRIVER-POD)" 1
fi
kubectl -n "$NS" cp "$FLOW" courtroom-driver:/tmp/flow.mjs >/dev/null 2>&1
FLOW_OUT=$(kubectl -n "$NS" exec courtroom-driver -- env WEB_ORIGIN="$WEB_ORIGIN" IDP_BASE="$IDP_BASE" node /tmp/flow.mjs 2>&1)
FLOW_RC=$?
printf '%s\n' "$FLOW_OUT" | sed 's/^/[S14-flow] /' | tee -a "$LOG"
if [ "$FLOW_RC" -ne 0 ]; then
  say "[S14-FAIL] flow driver exited $FLOW_RC"
  kubectl -n "$NS" logs deploy/courtroom-api --tail=60 2>/dev/null | tail -20 | sed 's/^/[S14-api] /' | tee -a "$LOG"
  fail_all "FAIL(FLOW)" 1
fi
say "[S14] in-cluster SSO flow PASS"
stage s14_flow 0

# ============================================================================
# s15 — teardown policy: PASS keeps everything (the operator's proof artifact)
# ============================================================================
stage s15_teardown 0
finish 0 "ALIVE"
