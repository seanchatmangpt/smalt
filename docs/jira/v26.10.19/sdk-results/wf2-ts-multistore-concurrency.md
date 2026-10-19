# External workflow receipt: wf2-multistore-concurrency (ts)

Workflow: wf2-multistore-concurrency
Lang: ts
Window: v26.10.19
SUBJECT_SHA: b847c020ee6b0a7ef426e27379f960228932feb0
Profile: primary-tier external suite (official Azure SDKs; surfaces: blob, cosmos, ledger, cap:blob-snapshot-metadata, cap:cosmos-throughput)
Generated: 2026-10-19T18:38:38.527302+00:00

## Cell tags

cosmos:cosmos-8way-etag-race: cosmos/cosmos-8way-etag-race PASS
blob:dead-port-plane-check: blob/dead-port-plane-check PASS
cosmos:dead-port-plane-check: cosmos/dead-port-plane-check PASS
ledger:dead-port-plane-check: ledger/dead-port-plane-check PASS
blob:blob-auth-channel: blob/blob-auth-channel FAIL

## Runner output tail

```
pconfig-ifmatch-race","verdict":"GREEN","detail":"fulfilled=1 412=1 finalValue=A"},{"name":"appconfig-unconditional-409","verdict":"GREEN","detail":"typed 409 WriteConflict"},{"name":"appconfig-missing-404","verdict":"GREEN","detail":"delete missing key typed 404"},{"name":"blob-auth-channel","verdict":"FAIL","detail":"SharedKey refused by enforce-mode Bearer plug; bearer-over-http refused by the SDK itself; blob not routed on the TLS twin — no usable official-SDK blob channel under enforce auth"}]}
{"id":"wf5","checks":[{"name":"arm-429-burst","verdict":"GREEN","detail":"182/200 requests 429'd, retry-after=1"},{"name":"arm-429-typed-code","verdict":"GREEN","detail":"error.code=TooManyRequests status429x182"},{"name":"arm-429-sdk-observability","verdict":"GREEN","detail":"SDK maxRetries:0 single GET: threw429=false resolved=false (window-dependent; burst leg is the throttle witness)"},{"name":"dead-port-plane-check","verdict":"GREEN","detail":"dead port typed failure (TypeError)"}]}

== VERDICT TABLE ==
-- wf2: child exit=0
   [GREEN] cosmos-8way-etag-race — 1x200=true 7x412=true winnerV=1
   [GREEN] dead-port-plane-check — dead endpoint typed failure (TypeError)
   [GREEN] appconfig-ifmatch-race — fulfilled=1 412=1 finalValue=A
   [GREEN] appconfig-unconditional-409 — typed 409 WriteConflict
   [GREEN] appconfig-missing-404 — delete missing key typed 404
   [FAIL] blob-auth-channel — SharedKey refused by enforce-mode Bearer plug; bearer-over-http refused by the SDK itself; blob not routed on the TLS twin — no usable official-SDK blob channel under enforce auth
-- wf5: child exit=0
   [GREEN] arm-429-burst — 182/200 requests 429'd, retry-after=1
   [GREEN] arm-429-typed-code — error.code=TooManyRequests status429x182
   [GREEN] arm-429-sdk-observability — SDK maxRetries:0 single GET: threw429=false resolved=false (window-dependent; burst leg is the throttle witness)
   [GREEN] dead-port-plane-check — dead port typed failure (TypeError)
[run-all] done in 7.6s exit=1
```
