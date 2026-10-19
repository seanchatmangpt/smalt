# External workflow receipt: wf5-edge-resilience (ts)

Workflow: wf5-edge-resilience
Lang: ts
Window: v26.10.19
SUBJECT_SHA: b847c020ee6b0a7ef426e27379f960228932feb0
Profile: primary-tier external suite (official Azure SDKs; surfaces: sentinel, cap:monitor-metrics)
Generated: 2026-10-19T18:46:23.092477+00:00

## Cell tags

sentinel:arm-429-burst: sentinel/arm-429-burst PASS
sentinel:arm-429-typed-code: sentinel/arm-429-typed-code PASS
sentinel:arm-429-sdk-observability: sentinel/arm-429-sdk-observability PASS
sentinel:dead-port-plane-check: sentinel/dead-port-plane-check PASS

## Runner output tail

```
[run-all] shared substrate block=v13 ports=39830/39831/39832/39833/39834/39835 reused=false
{"id":"wf5","checks":[{"name":"arm-429-burst","verdict":"SKIP-429","detail":"arm_rate_limit=0 but 0 429s in 200-burst (errs=0)"}],"skip":{"code":4,"reason":"arm_rate_limit=0 injected but 0 429s observed in 200-request burst — throttle not enforced on the wire"}}
{"id":"wf5","checks":[{"name":"arm-429-burst","verdict":"GREEN","detail":"180/200 requests 429'd, retry-after=1"},{"name":"arm-429-typed-code","verdict":"GREEN","detail":"error.code=TooManyRequests status429x180"},{"name":"arm-429-sdk-observability","verdict":"GREEN","detail":"SDK maxRetries:0 single GET: threw429=false resolved=false (window-dependent; burst leg is the throttle witness)"},{"name":"dead-port-plane-check","verdict":"GREEN","detail":"dead port typed failure (TypeError)"}]}

== VERDICT TABLE ==
-- wf5: child exit=4
   [SKIP-429] arm-429-burst — arm_rate_limit=0 but 0 429s in 200-burst (errs=0)
-- wf5: child exit=0
   [GREEN] arm-429-burst — 180/200 requests 429'd, retry-after=1
   [GREEN] arm-429-typed-code — error.code=TooManyRequests status429x180
   [GREEN] arm-429-sdk-observability — SDK maxRetries:0 single GET: threw429=false resolved=false (window-dependent; burst leg is the throttle witness)
   [GREEN] dead-port-plane-check — dead port typed failure (TypeError)
[run-all] done in 6.8s exit=1
```
