# r-p08-kind-gate — one-command milestone gate run

- date: 2026-10-30T15:33:28Z · wall: 842s · verdict: **PARTIAL_ALIVE (2/9 legs rc=0)**

| leg | rc |
|---|---|
| kind_court_9x9 | 1 |
| readiness | 0 |
| p01_browser_saml | 1 |
| p02_slo_roundtrip | 1 |
| p03_browser_oidc | 1 |
| p04_concurrency | 1 |
| p05_tenant_fence | 1 |
| p06_ingress_parity | 1 |
| cleanup_driver | 0 |

## Embedded evidence (leg log tails)
### cleanup_driver.log
```
```
### kind_court_9x9.log
```
[KIND-E2E] COURT-VERDICT: FAIL(DRIVER-POD) (exit 1)
```
### p01_browser_saml.log
```
{"verdict":"P01-FAIL","error":"Error: page.goto: net::ERR_EMPTY_RESPONSE at http://localhost:3000/\nCall log:\n  - navigating to \"http://localhost:3000/\"","landed":"about:blank"}
```
### p02_slo_roundtrip.log
```
{"verdict":"P02-FAIL","error":"Error: page.goto: net::ERR_EMPTY_RESPONSE at http://localhost:3000/\nCall log:\n  - navigating to \"http://localhost:3000/\", waiting until \"domcontentloaded\"\n"}
{"verdict":"P02-FAIL","error":"Error: page.goto: net::ERR_EMPTY_RESPONSE at http://localhost:3000/\nCall log:\n  - navigating to \"http://localhost:3000/\", waiting until \"domcontentloaded\"\n"}
```
### p03_browser_oidc.log
```
```
### p04_concurrency.log
```
{"verdict":"P04-FAIL","passed":0,"of":10,"failures":[{"i":0,"ok":false,"error":"Error: page.goto: net::ERR_EMPTY_RESPONSE at http://localhost:3000/\nCall log:\n  - navigating to \"htt"},{"i":1,"ok":false,"error":"Error: page.goto: net::ERR_CONNECTION_RESET at http://localhost:3000/\nCall log:\n  - navigating to \"h"},{"i":2,"ok":false,"error":"Error: page.goto: net::ERR_EMPTY_RESPONSE at http://localhost:3000/\nCall log:\n  - navigating to \"htt"},{"i":3,"ok":false,"error":"Error: page.goto: net::ERR_EMPTY_RESPONSE at http://localhost:3000/\nCall log:\n  - navigating to \"htt"},{"i":4,"ok":false,"error":"Error: page.goto: net::ERR_EMPTY_RESPONSE at http://localhost:3000/\nCall log:\n  - navigating to \"htt"},{"i":5,"ok":false,"error":"Error: page.goto: net::ERR_EMPTY_RESPONSE at http://localhost:3000/\nCall log:\n  - navigating to \"htt"},{"i":6,"ok":false,"error":"Error: page.goto: net::ERR_CONNECTION_RESET at http://localhost:3000/\nCall log:\n  - navigating to \"h"},{"i":7,"ok":false,"error":"Error: page.goto: net::ERR_EMPTY_RESPONSE at http://localhost:3000/\nCall log:\n  - navigating to \"htt"},{"i":8,"ok":false,"error":"Error: page.goto: net::ERR_EMPTY_RESPONSE at http://localhost:3000/\nCall log:\n  - navigating to \"htt"},{"i":9,"ok":false,"error":"Error: page.goto: net::ERR_EMPTY_RESPONSE at http://localhost:3000/\nCall log:\n  - navigating to \"htt"}]}
```
### p05_tenant_fence.log
```
[P05] PASS error-payload-data-free
"verdict":"P01-FAIL"
[P05] verdict: 2 passed, 1 failed
```
### p06_ingress_parity.log
```
[P06] verdict: 0 passed, 6 failed
```
### readiness.log
```
```
