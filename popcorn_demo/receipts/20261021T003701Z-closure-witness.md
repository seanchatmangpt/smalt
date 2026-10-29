# L-b closure witness — pass 2

Standing: ALIVE
Context: solo
Lane: L-b (bench-runner), repo /Users/sac/smalt

## Delta vs pass 1

No skips closed and no regressions: the single SKIP (blob=SKIP(cors-preflight-403:fetch))
persisted in both passes; no sibling closure-lane receipts landed during the 10-minute
bounded poll (tree quiet, timeout path taken per lane contract). All OK legs reproduced
identically; host legs and browser witness exited 0 in both passes.

## Substrate probe

```
$ curl -s -m 3 -o /dev/null -w "%{http_code}" http://127.0.0.1:9443/metadata/endpoints
200
```

## Host legs (bash popcorn_demo/scripts/receipt_testbed.sh, exit 0)

```
17:36:44.717 [info] smalt-on-popcorn smoke: cosmos_sql=OK(where+order+limit correct); sb_rule=OK(sql filter matched); registry=OK(admitted-type + api-version checks pass)
17:36:44.755 [info] popcorn_demo live leg: live=OK(endpoints,tenants,sts,subscriptions=1)
HOST_RECEIPT: live=OK(endpoints,tenants,sts,subscriptions=1); live=OK(matrix=OK(popcorn/smoke:1-matched)); live=OK(blob=OK(popcorn/l3rb1792543004837/receipt.txt:61-roundtrip))
host legs exit: 0
RECEIPT: /Users/sac/smalt/popcorn_demo/receipts/20261021T003644Z-testbed-witness.md standing=ALIVE
```

## Browser smoke (node popcorn_demo/scripts/browser_smoke.mjs, exit 0)

```
SMOKE_RECEIPT: cosmos_sql=OK(where+order+limit correct); sb_rule=OK(sql filter matched); registry=OK(admitted-type + api-version checks pass); live=OK(endpoints,tenants,sts,subscriptions=1); matrix=OK(popcorn/smoke:1-matched); blob=SKIP(cors-preflight-403:fetch)
EXIT:0
```

## Live gate court (bash scripts/live_gate_court.sh, exit 0)

```
BASELINE: three exit arms present in browser_smoke.mjs
BEFORE: sha256 72f199cc46fb97e139b8a9b95afd1083a812d5274794b091a8977c19520188b2
SHIM+AFTER(shim): mutated copy exited 0 under SMOKE_COURT_ONLY=1 — gate CAN flip
AFTER: real gate unchanged — all three arms intact (PROOF-MODE: structural)
RESTORE: sha256 byte-exact match — subject intact
PASS: live gate is non-vacuous (fails under mutation, real gate untouched)
COURT_EXIT:0
```

## Summary

No FAIL. One persistent browser SKIP (CORS preflight 403 on 127.0.0.1:8443/healthz),
unchanged across passes. Standing ALIVE (no FAIL, browser exit 0).
