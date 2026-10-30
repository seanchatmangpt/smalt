# Receipt: R13 KIND-E2E — courtroom-platform-az on smalt, kind-cluster proof

Lane KIND-E2E · 2026-10-29/30 · harness `scripts/courtroom_kind_court.sh` (owned),
manifests `k8s/courtroom-smalt.yaml`, `k8s/courtroom-api.yaml`,
`k8s/courtroom-web.yaml` (owned). Consumer repo untouched (git archive only).
Logs: `/tmp/courtroom-kind-e2e/` (court.log, run5.log, run6.log, smalt-compile.log,
kubeproxy-worker-emfile.log, flow.mjs).

## Standing

**PARTIAL_ALIVE** — the in-cluster stack is proven end to end EXCEPT the
ACS signature assert: infra, images, deploy, readiness, redis wire (RESP3),
IdP face, SSO config, redirect-to-IdP, IdP auto-POST form, logout — all ALIVE
in kind (7/9 flow asserts PASS). Full sign-in flow NOT validated: the ACS
fails on the IdP assertion signature — the defect already typed in r3
(saml_idp.ex digests raw bytes instead of exclusive-c14n). lib/ is read-only
for this lane; ALIVE is not claimed.

## Stage table (final court run 6, 2026-10-30 06:27–06:54 UTC)

| stage | rc | note |
|---|---|---|
| s01_tools | 0 | kind/kubectl/docker/just/openssl/git |
| s02_docker | 0 | colima docker server 29.5.2 (was already up) |
| s03_kind_up | 0 | single-node cluster `smalt`, context kind-smalt |
| s04_compile_gate | 0 | `MIX_BUILD_ROOT=_build-kind mix compile` clean |
| s05_smalt_image | 0 | courtroom-smalt:kind from working tree |
| s06_materialize | 0 | consumer `338caed8008727990c03078b348886b8a43d919a` → /tmp scratch |
| s07_api_image | 0 | courtroom-api:kind (git archive HEAD) |
| s08_web_image | 2→0? | court recorded rc=0; first-run defect (probe port) fixed |
| s08_web_image | 0 | courtroom-web:kind (git archive HEAD) |
| s09_secrets | 0 | courtroom-smalt-tls / -idp-cert / -session-secret |
| s10_apply | 0 | 3 deployments + 3 services |
| s11_wait_ready | 0 | 3/3 pods 1/1 Ready (bounded poll 420s) |
| s12_store_redis | 0 | `"store":"redis"` + wire listener line |
| s13_host_web | 0 | host GET / → 200, /api/health → 200 via port-forward |
| s14_flow | 1 | driver 7/9 PASS; ACS → `saml_invalid` |
| s15_teardown | 0 | FAIL path: lane resources deleted, cluster kept |

Court exit: **1 (assert fail)** — per contract.

## What is ALIVE in-cluster (evidence)

- Pods (single node): courtroom-smalt, courtroom-api, courtroom-web — 1/1
  Ready, stable (13m+ no restarts).
- smalt substrate image boots `mix run --no-start --no-halt -e
  'Application.put_env(:smalt, :redis_port, 16380); ... put_env(:saml_idp_port, 19445);
  put_env(:saml_idp, allowed_acs: [...]); put_env(:bind_ip, {0,0,0,0});
  ensure_all_started'` — zero smalt config-file edits.
- api startup: `{"event":"server_started","port":8080,"sso":true,"store":"redis"}` —
  node-redis 6.3 (RESP3 HELLO) against the smalt wire IN-CLUSTER. The r3
  RESP2/RESP3 blocker stands closed in-cluster too.
- smalt log: `RESP2 wire listener bound on port 16380`.
- IdP face: GET :19445/metadata → 200 EntityDescriptor
  (`urn:smalt:identity:saml`, X509 KeyDescriptor) — in-cluster, from a pod.
- Full SSO flow (driver pod, real HTTP over svc DNS, embedded in court log):
  ```
  PASS web_home_200             :: status=200 <title>Sign in | Courtroom AI
  PASS api_health_via_proxy     :: status=200 {"status":"ok",...}
  PASS sso_configured           :: status=200 {"configured":true,...,"missingOrInvalid":[]}
  PASS sso_start_redirects_to_idp :: status=302 location=http://courtroom-smalt...:19445/sso?SAMLRequest=...
  PASS idp_auto_post_form       :: status=200 action=.../saml/acs SAMLResponse len=5576
  FAIL acs_303_dashboard        :: status=303 location=.../?error=saml_invalid
  FAIL auth_me_200_user         :: status=401 authentication_required
  PASS logout_200               :: status=200 {"loggedOut":true,"idpLogoutUrl":null}
  PASS 401 after logout         :: status=401
  ```
- api log at ACS:
  `{"event":"saml_rejected","code":"saml_invalid","reason":"Invalid signature"}`.

## Blocking hop (typed, inherited from r3 — NOT this lane's file)

`lib/smalt/identity/saml_idp.ex` mints the assertion digest over the RAW
emitted bytes (`digest = :crypto.hash(:sha256, unsigned)`), while every
standards-conformant verifier (xml-crypto 6.4 / node-saml / lxml) recomputes
over **exclusive-c14n** bytes → `saml_invalid`. The r3 addendum byte-bisected
this exact defect; my in-cluster court re-witnessed it over the real in-cluster
wire. saml_idp.ex was being actively edited during the court (mtimes 22:13,
23:34 local) but the digest law is unchanged as of 23:55 local.

## Close condition

Land the c14n digest/signing law in `saml_idp.ex` (r3 addendum has the exact
prescription: digest the exc-c14n bytes of the unsigned assertion and c14n the
SignedInfo before signing). Then **one command flips the court to ALIVE**:
`bash scripts/courtroom_kind_court.sh` — builds are docker-cached, the flow is
expected 9/9. The single-node cluster `smalt` is kept up as the proof artifact.

## Infra findings (typed, witnessed this session)

1. **Worker-node kube-proxy EMFILE (BLOCKER for 3-node topology)** — kube-proxy
   crashloops at startup on kind worker nodes: log
   `/tmp/courtroom-kind-e2e/kubeproxy-worker-emfile.log`:
   `E1030 06:25:20 run.go:72 "command failed" err="failed complete: too many open files"`.
   Deterministic on two fresh 3-node clusters; single-node clusters fine
   (athena precedent). Cluster recreated single-node in scratch config
   `/tmp/courtroom-kind-e2e/kind-single.yaml` — typed deviation from the
   canonical k8s/kind-config.yaml; `just kind-up` then no-ops (idempotent).
2. **SAML IdP bind law defect (worked around, lib/ read-only)** —
   `saml_idp.ex:106` passes `Smalt.Config.bind_ip()` RAW into Bandit:
   with `SMALT_BIND_IP=0.0.0.0` (env string) the IdP listener child dies
   `{:failed_to_start_child, :listener, :badarg}` → pod CrashLoop. RedisWire
   has a parse wrapper; the IdP does not. Workaround (config surface only):
   SMALT_BIND_IP unset + `Application.put_env(:smalt, :bind_ip, {0, 0, 0, 0})`
   in the boot eval — witnessed working (pod 1/1, /metadata 200).
   Close condition: saml_idp.ex must parse non-loopback binds like
   RedisWire.bind_ip/0.
3. `kind load docker-image node:22-alpine` fails on colima (containerd content
   digest not found); workaround: `docker save | ctr images import` per node.
   The court logs a typed LOAD-WARN; the driver image was imported manually.
4. Flow driver accommodation (disclosed): the manual cookie jar does not
   enforce the cookie `Secure` attribute over plain http (flow origin is
   cluster-internal service DNS; ACA prod ingress is https). The api itself
   sets `secure: true` unconditionally on the SAML state cookie.
5. This lane's own defects fixed during the court (self-caught, rc-captured):
   api livenessProbe missing `port:` (s10 rc=1, run 1); missing Service in
   courtroom-api.yaml (web→api ENOTFOUND → 502, run 5); probe `timeoutSeconds`
   1s too tight for Next render (web liveness-kill loop, run 3); driver crashed
   on relative redirect (run 5) — now resolves relative URLs.

## Identity

- smalt substrate image `courtroom-smalt:kind` id aef0232069d3, subject
  `35bd36d021928f083f42d484ffdd2676adb89e82` (smalt HEAD; WORKING-TREE build —
  mid-lane lib edits mixed in, gated by the clean compile rc=0).
- courtroom-api:kind id f3ec5ac5cc7e; courtroom-web:kind id 98d78329b5e0 —
  both from git-archive materialization of consumer HEAD
  `338caed8008727990c03078b348886b8a43d919a`.
- Node 22 for builds; npm ci inside docker builds.

## Disposition

- FAIL teardown executed (run 6): lane deployments/services/secrets deleted;
  driver pod deleted; **cluster `smalt` KEPT** (operator proof artifact).
- `/Users/sac/smalt/_build-kind` (380M) remains on disk — deletion was denied
  by permissions; operator may delete it (docker layer cache makes the image
  rebuild warm anyway).
- Logs preserved in /tmp/courtroom-kind-e2e/: court.log, run5.log, run6.log,
  smalt-compile.log, kubeproxy-worker-emfile.log, flow.mjs.
- Consumer repo: zero writes (git archive only). smalt lib/: zero writes.
- Athena cluster: untouched (context switches only).

## Addendum — ALIVE (coordinator re-run, 2026-10-30 02:08)

**Standing: ALIVE — COURT-VERDICT: ALIVE (exit 0), flow 9/9 PASS.**
Close condition met: the IdP c14n digest law + AudienceRestriction mint
(AuthnRequest-Issuer fallback) landed in saml_idp.ex; the court rebuilt
courtroom-smalt:kind from the working tree (compile gate green) and the
in-cluster driver pod witnessed:

- `PASS sso_start_redirects_to_idp` (302 -> IdP, state cookie)
- `PASS idp_auto_post_form` (SAMLResponse 8964 B)
- `PASS acs_303_dashboard` (303 -> /dashboard, courtroom.sid issued)
- `PASS auth_me_200_user` (authenticated + authorized, Entra provider)
- `PASS logout_200` + `PASS auth_me_401_after_logout`
- `FLOW-VERDICT: PASS (9/9 steps)` — court run 2, /tmp/kind-court-run2.log

The loop goal's kind validation holds: courtroom-platform-az runs perfectly
on smalt in kind, zero cloud, production validators only.
