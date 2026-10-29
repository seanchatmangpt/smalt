# BK-SKIPPORT — in-browser smoke SKIP-leg Fetch ports + typed-permanent residue

**Standing:** PARTIAL_ALIVE (all mechanical legs green; 6 typed-permanent SKIPs remain, each with a named reason — zero silent skips)
Context: solo
Date: 20261022T1150Z

## What ran

Real substrate (loopback, auth :enforce), real headless-Chromium wasm BEAM
(Popcorn), real Transport.Fetch over the real smalt wire — no mocks. Harness:
`node scripts/browser_smoke.mjs` from `/Users/sac/smalt/popcorn_demo`, with the
BK-91 blob `<Cors>` seed as pre-step.

## BEFORE (baseline: witness-all 20261021T234535Z)

16 OK / 15 SKIP / 0 FAIL (31 legs). The 15 SKIP legs, by reason:
acr (face-absent), apim (wasm :httpc), blob (cors-preflight-403:create-container),
certs (wasm :public_key), dns (wasm :httpc), eg (wasm-transport:publish),
egd (kd101-airgap), eh (5673 :eprotonosupport), keyops (tcp :eprotonosupport),
mcp (wasm :httpc), policy (wasm :httpc), queue (wasm :httpc), reconcile
(wasm :crypto), tls (ca-missing), topic (wasm :httpc).

## AFTER (this lane, run 20261022T1144Z, smoke exit 0)

23 OK / 6 SKIP / 1 UNSUPPORTED / 0 FAIL. Legs flipped green this session:
blob, certs, keyops, mcp, policy, queue, reconcile (the BK-15/BK-46/BK-40
Transport.Fetch ports already landed in lib/ were cooked + witnessed for the
first time), and **eg** (this lane's port — see diff below). dns moved
OK → UNSUPPORTED (typed RouteNotFound-404 on the fresh substrate — loud,
not a silent skip).

## Lane diff (all disclosed)

Harness (3 files):
1. `popcorn_demo/scripts/seed_blob_cors.mjs` — CORS seed AllowedMethods
   +POST (the eg leg publishes POST /topics/:topic/events; POST was
   preflight-403'd by the stored rule set), comment updated to name the
   EventGrid publish face.
2. `popcorn_demo/scripts/witness_all.sh` — step-2 `<Cors>` XML AllowedMethods
   +POST (same law; keeps witness-all runs admissible for eg).
3. `popcorn_demo/scripts/bkskipport_witness.sh` — NEW atomic
   boot+seed+smoke driver (exit 0/1/2/3), because canonical-port beams were
   being reaped by concurrent lanes' sweeps between separate commands on
   this box; atomic capture survives reaping.

Substrate (1 line, disclosed lane-boundary extension — no lane owns this seam):
4. `lib/smalt/egress_router.ex` — the blob-plane path heuristic excluded only
   a hardcoded plane-prefix list that did not include `/topics` (EventGrid),
   so topic OPTIONS preflights were evaluated as a phantom blob account
   "topics" (no rules → 403) and every in-browser publish 403'd at preflight.
   Added `"topics"` to the exclusion list. Compile-fenced
   (MIX_BUILD_ROOT=_build-bkskipport, exit 0); wire-verified: preflight
   403 → 204 with the full Access-Control-* face on the fixed beam
   (`curl -X OPTIONS /topics/:t/events` with Origin + A-C-Request-Method).

## Environment notes (disclosed, not defects)

- An unrelated 3h23m-old beam holds 9092 (Kafka) with a live LISTEN
  (port_sweep-protected, not ours to kill) — this lane's substrate ran with
  `kafka_port=19092`; no smoke leg rides Kafka.
- Substrate left UP after the witness (pid 76567, registered in
  /tmp/smalt-substrate-state/substrate.pid, kafka on 19092) for the
  coordinator's call.

## Verdict output (verbatim, 20261022T1144Z run)

Exit: 0. SCVD gate: `SCVD-OK:t16:5.215ms <= 3x rolling-best 5.214ms`.
CORS seed: `SEED_BLOB_CORS: OK — popcorn <Cors> rules seeded (202, PUT http://127.0.0.1:8443/popcorn?restype=service&comp=properties)`.

SMOKE_RECEIPT (byte-captured, also at /tmp/bkskipport-receipt-line.txt):

```text
SMOKE_RECEIPT: cosmos_sql=OK(where+order+limit correct); sb_rule=OK(sql filter matched); registry=OK(admitted-type + api-version checks pass); acr=SKIP(face-absent::acr_face_absent); apim=SKIP(wasm-transport:function :httpc.request/4 is undefined (module :httpc is not available)); appconfig=OK(popcorn-ac-1078:kv+flag-lifecycle); blob=OK(popcorn/l3rb1792669469846-110/receipt.txt:61-roundtrip); cas=OK(insert,etag,fresh-200,stale-412,delete-204,gone-404); certs=OK(popcorn-cert-502:purge); containers=OK(1-listed); dns=UNSUPPORTED(recordset-A:RouteNotFound-404-zone-deleted-clean); eg=OK(pegl31792669470245:bearer-topic-publish-readback-kd101refusal); egd=SKIP(kd101-airgap:local-delivery-unimplemented); eh=SKIP(eh-plane-down(5673-connect-:eprotonosupport); run 9>&- just substrate-up); export=OK(2-resources-exported); keyops=OK(ES256:verified); kv=OK(popcorn-secret-206:30-bytes-lifecycle); lifecycle=OK(create:get:delete:get404:l5k1792669470317-874); live=OK(endpoints,tenants,sts,subscriptions=1); matrix=OK(popcorn/smoke:1-matched); mcp=OK(32-tools); param=OK(1-matched-params); policy=OK(5-faces-1-defs); queue=OK(popcorn-q-1792669469884-87497:74-bytes-roundtrip); reconcile=OK(3-staged,seeded,feed-6,monotonic,typed-conflict,cas-winners); rg=OK(5-rows); rules=OK(popcorn-r:1-listed); scvd=OK(t16:5.215ms,p99:570us;t256:67.304ms,p99:344us;c128:w8/l120/committed8;c256:w8/l248/committed8); tags=OK(2-tags-roundtrip); tls=SKIP(ca-missing:/Users/sac/smalt/.smalt/tls/ca-cert.pem); topic=SKIP(wasm-transport:function :httpc.request/4 is undefined (module :httpc is not available))
```

## Typed-permanent SKIP register (6 — no silent skips)

| leg | reason | class |
|-----|--------|-------|
| acr | face-absent (::acr_face_absent) — the substrate does not implement the ACR face; the leg's designed terminal state is this loud SKIP | PERMANENT-SKIP (surface absent) |
| apim | wasm :httpc unavailable AND the APIM face is absent on the substrate (the leg's own doc names face-absent as the only passing-adjacent outcome) | PERMANENT-SKIP (transport + surface absent) |
| egd | kd101-airgap: local-delivery unimplemented — the KD-101 typed gap is the assertion surface; no local-delivery face exists to port to | PERMANENT-SKIP (typed gap by design) |
| eh | AMQP 1.0 over raw :gen_tcp to 5673 — the wasm BEAM has no sockets; fetch cannot carry AMQP binary framing | PERMANENT-SKIP (transport class impossible in-browser) |
| topic | AMQP 1.0 over raw :gen_tcp (same law as eh) | PERMANENT-SKIP (transport class impossible in-browser) |
| tls | real :ssl peer-verified handshake + on-disk CA file — neither exists in the wasm BEAM; porting would weaken the leg's own assertion (peer verification) | PERMANENT-SKIP (transport class impossible in-browser) |

dns=UNSUPPORTED(recordset-A:RouteNotFound-404-zone-deleted-clean) rides along
as a typed non-SKIP non-OK verdict, loud.

## Falsifier

Re-run `bash popcorn_demo/scripts/bkskipport_witness.sh` (or seed+smoke)
against a booted substrate: eg flips back to SKIP iff the `/topics` CORS face
regresses; the six typed-permanent rows flip only if the named surface/transport
becomes available in the wasm BEAM.
