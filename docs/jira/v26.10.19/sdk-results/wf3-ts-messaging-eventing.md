# External workflow receipt: wf3-messaging-eventing (ts)

Workflow: wf3-messaging-eventing
Lang: ts
Window: v26.10.19
SUBJECT_SHA: b847c020ee6b0a7ef426e27379f960228932feb0
Profile: primary-tier external suite (official Azure SDKs; surfaces: eventgrid, eventhubs, servicebus, cap:eh-consumergroups, cap:sb-eh-2024-children)
Generated: 2026-10-19T18:45:12.193569+00:00

## Cell tags

servicebus:send20-receive-complete: servicebus/send20-receive-complete FAIL
eventgrid:dead-port-plane-check: eventgrid/dead-port-plane-check PASS
eventhubs:dead-port-plane-check: eventhubs/dead-port-plane-check PASS
servicebus:dead-port-plane-check: servicebus/dead-port-plane-check PASS
servicebus:message-lock-lost: servicebus/message-lock-lost FAIL
servicebus:dlq-maxdelivery: servicebus/dlq-maxdelivery FAIL
servicebus:session-fifo: servicebus/session-fifo PASS
eventhubs:hub-up: eventhubs/hub-up PASS
eventhubs:send-200: eventhubs/send-200 PASS
eventhubs:exactly-once: eventhubs/exactly-once PASS

## Runner output tail

```
EN","detail":"hub properties via $management link"},{"name":"eh-send-200","verdict":"GREEN","detail":"100 events to partition 0, 100 to partition 1"},{"name":"eh-exactly-once","verdict":"GREEN","detail":"unique=200/200 duplicates=0"}]}
{"id":"wf5","checks":[{"name":"arm-429-burst","verdict":"GREEN","detail":"180/200 requests 429'd, retry-after=1"},{"name":"arm-429-typed-code","verdict":"GREEN","detail":"error.code=TooManyRequests status429x180"},{"name":"arm-429-sdk-observability","verdict":"GREEN","detail":"SDK maxRetries:0 single GET: threw429=false resolved=false (window-dependent; burst leg is the throttle witness)"},{"name":"dead-port-plane-check","verdict":"GREEN","detail":"dead port typed failure (TypeError)"}]}

== VERDICT TABLE ==
-- wf3: child exit=0
   [FAIL] sb-send20-receive-complete — received=0/20 fifo=true — receiver-delivery gap: attach+flow+CBS succeed and send resolves, but no delivery is produced on receiver-link flow credit (send-side only on the wire)
   [GREEN] dead-port-plane-check — dead AMQP typed failure (MessagingError: ECONNREFUSED: connect ECONNREFUSED 127.0.0.1:1)
   [FAIL] sb-message-lock-lost — no delivery — receiver-delivery gap leaves the lock-expiry leg unexercisable over the SDK
   [FAIL] sb-dlq-maxdelivery — DLQ size=0 reason=null
   [GREEN] sb-session-fifo — received=[0,1,2,3,4] (deliveries lack settle methods — delivery-shape divergence)
   [GREEN] eh-hub-up — hub properties via $management link
   [GREEN] eh-send-200 — 100 events to partition 0, 100 to partition 1
   [GREEN] eh-exactly-once — unique=200/200 duplicates=0
-- wf5: child exit=0
   [GREEN] arm-429-burst — 180/200 requests 429'd, retry-after=1
   [GREEN] arm-429-typed-code — error.code=TooManyRequests status429x180
   [GREEN] arm-429-sdk-observability — SDK maxRetries:0 single GET: threw429=false resolved=false (window-dependent; burst leg is the throttle witness)
   [GREEN] dead-port-plane-check — dead port typed failure (TypeError)
[run-all] done in 55.8s exit=1
```
