# L-b closure witness — pass 1

Standing: ALIVE
Context: solo
Lane: L-b (bench-runner), repo /Users/sac/smalt

## Substrate probe

```
$ curl -s -m 3 -o /dev/null -w "%{http_code}" http://127.0.0.1:9443/metadata/endpoints
200
```

## Host legs (bash popcorn_demo/scripts/receipt_testbed.sh, exit 0)

```
17:25:31.795 [info] smalt-on-popcorn smoke: cosmos_sql=OK(where+order+limit correct); sb_rule=OK(sql filter matched); registry=OK(admitted-type + api-version checks pass)
17:25:31.836 [info] popcorn_demo live leg: live=OK(endpoints,tenants,sts,subscriptions=1)
HOST_RECEIPT: live=OK(endpoints,tenants,sts,subscriptions=1); live=OK(matrix=OK(popcorn/smoke:1-matched)); live=OK(blob=OK(popcorn/l3rb1792542331919/receipt.txt:61-roundtrip))
host legs exit: 0
```

Note: compile warnings observed (Smalt.Store.list_prefix/2, Smalt.Amqp.QueueStore.enqueue/3 undefined in popcorn_demo isolation build) — warnings only, app generated and ran.

## Browser smoke (node popcorn_demo/scripts/browser_smoke.mjs, exit 0)

public/out cooked (beam.mjs, beam.wasm, index.mjs, otp/, worker.mjs present).

```
SMOKE_RECEIPT: cosmos_sql=OK(where+order+limit correct); sb_rule=OK(sql filter matched); registry=OK(admitted-type + api-version checks pass); live=OK(endpoints,tenants,sts,subscriptions=1); matrix=OK(popcorn/smoke:1-matched); blob=SKIP(cors-preflight-403:fetch)
browser witness exit: 0
```

One SKIP: blob=SKIP(cors-preflight-403:fetch) — browser fetch to 127.0.0.1:8443/healthz blocked by CORS preflight 403. Console noise: 404 resource, 409 Conflict (expected conflict arm).

## Live gate court (bash scripts/live_gate_court.sh, exit 0)

```
BASELINE: three exit arms present in browser_smoke.mjs
BEFORE: sha256 f6e0ffae85d99fd1d322de4c960bc24045c940b88d7f911b01f2d681163d1661
SMOKE_RECEIPT: shim always-zero
SHIM+AFTER(shim): mutated copy exited 0 under SMOKE_COURT_ONLY=1 — gate CAN flip
AFTER: real gate unchanged — no early-exit guard, all three arms intact (PROOF-MODE: structural)
RESTORE: sha256 byte-exact match — subject intact
PASS: live gate is non-vacuous (fails under mutation, real gate untouched)
EXIT:0
```

## Summary

No FAIL. One browser SKIP (CORS preflight). Standing ALIVE per lane rule (ALIVE iff no FAIL and browser exit 0). Delta pass 2 to follow.
