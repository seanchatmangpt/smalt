# FIX-2 KD-143 Witness — SB rule SQL filter persistence

- **Standing:** ALIVE
- Context: pair
- Date: 2026-10-21 10:46 
- KD row: KD-143 (canonical: docs/jira/v26.10.14/KNOWN_DIVERGENCES.md; mirror: docs/jira/v26.10.20/KNOWN_DIVERGENCES.md)
- Shim: lib/smalt/arm_gateway/router.ex:2192 `# KD-COVERS: KD-143` (sb_rule_filter_props/1 typed-shape fallthrough fix), mtime epoch 1792602656 — this receipt postdates it.

## Command: scripts/fast_test.sh test/integration/kd143_rules_persistence_test.exs

```
Finished in 0.1 seconds (0.00s async, 0.1s sync)
6 tests, 0 failures
```

Full run exit code: 0

## Command: live wire witness via 9444 TLS twin (real HTTP, bearer from emulator STS)

```
== PUT namespace: 200
== PUT topic:    200
== PUT sub:      200
== PUT rule r143 (valid SqlFilter):
{"id":"/subscriptions/sub-kd143w/resourceGroups/rg-kd143w/namespaces/ns-kd143w/topics/t-kd143w/subscriptions/s-kd143w/rules/r143","name":"r143","properties":{"action":null,"filter":{"sqlExpression":"sys.to= 'kd143'"},"filterType":"SqlFilter","sqlFilter":{"sqlExpression":"sys.to= 'kd143'"}},"type":"Microsoft.ServiceBus/namespaces/topics/subscriptions/rules"}
HTTP 201
== GET rule r143 (expect echoed sqlFilter.sqlExpression):
{"id":"/subscriptions/sub-kd143w/resourceGroups/rg-kd143w/namespaces/ns-kd143w/topics/t-kd143w/subscriptions/s-kd143w/rules/r143","name":"r143","properties":{"action":null,"filter":{"sqlExpression":"sys.to= 'kd143'"},"filterType":"SqlFilter","sqlFilter":{"sqlExpression":"sys.to= 'kd143'"}},"type":"Microsoft.ServiceBus/namespaces/topics/subscriptions/rules"}
HTTP 200
== PUT rule r143-bad (invalid SQL, expect 400):
{"error":{"code":"InvalidFilter","innererror":{},"message":"Unsupported SQL filter construct: unsupported filter construct near: NOT"}}
HTTP 400
```

PUT rule 201 echoes `properties.sqlFilter.sqlExpression`; GET 200 returns the identical body (no trueFilter fallthrough); invalid SQL -> 400 InvalidFilter. Close condition of KD-143 is met on the wire.
