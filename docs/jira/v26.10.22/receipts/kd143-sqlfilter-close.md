# KD-143 Close — SB rule SQL filter persistence (solo wire witness)

- **Standing:** ALIVE
- Context: solo
- Date: 2026-10-22 04:20
- KD row: KD-143 (canonical: docs/jira/v26.10.14/KNOWN_DIVERGENCES.md)
- Shim: lib/smalt/arm_gateway/router.ex `# KD-COVERS: KD-143` (sb_rule_props/sb_rule_wire_props typed-shape filter normalization + echo), mtime epoch 1792602656 — this receipt postdates it.
- Court test: test/integration/kd143_rules_persistence_test.exs (6 legs, real Store + real ARM dispatch, no mocks).

## Command: MIX_BUILD_ROOT=_build-kd143 scripts/fast_test.sh test/integration/kd143_rules_persistence_test.exs

```
03:56:52.847 info[] Sent 200 in 65µs
.
Finished in 0.06 seconds (0.00s async, 0.06s sync)

Result: 6 passed
```

Full run exit code: 0

## Command: live wire witness via 9444 TLS twin (solo, real HTTP, bearer from emulator STS, curl)

```
rg PUT 201
ns PUT 202
topic PUT 201
sub PUT 201
== PUT rule r143s:
{"id":"/subscriptions/sub-kd143s/resourceGroups/rg-kd143s/namespaces/ns-kd143s/topics/t-kd143s/subscriptions/s-kd143s/rules/r143s","name":"r143s","properties":{"action":null,"filter":{"sqlExpression":"sys.to = 'kd143s'"},"filterType":"SqlFilter","sqlFilter":{"sqlExpression":"sys.to = 'kd143s'"}},"type":"Microsoft.ServiceBus/namespaces/topics/subscriptions/rules"}
HTTP 201
== GET rule r143s:
{"id":"/subscriptions/sub-kd143s/resourceGroups/rg-kd143s/namespaces/ns-kd143s/topics/t-kd143s/subscriptions/s-kd143s/rules/r143s","name":"r143s","properties":{"action":null,"filter":{"sqlExpression":"sys.to = 'kd143s'"},"filterType":"SqlFilter","sqlFilter":{"sqlExpression":"sys.to = 'kd143s'"}},"type":"Microsoft.ServiceBus/namespaces/topics/subscriptions/rules"}
HTTP 200
== PUT rule r143s-bad (invalid SQL):
{"error":{"code":"InvalidFilter","innererror":{},"message":"Unsupported SQL filter construct: unsupported filter construct near: priority"}}
HTTP 400
GET r143s-bad (expect 404) 404
```

PUT rule 201 echoes `properties.sqlFilter.sqlExpression`; GET 200 returns the identical body (no `trueFilter` fallthrough — the exact KD-143 defect shape); invalid SQL refuses 400 `InvalidFilter` fail-closed and the rule is not persisted (GET 404). The close condition of KD-143 is met on the live wire post-shim, witness postdates the shim mtime.

## Environment note

First two `substrate.sh up` attempts during this lane failed for reasons OUTSIDE
the KD-143 surface: (1) a compile error in another lane's in-flight
`lib/smalt/data_plane/kql.ex`, then (2) port 9092 `:eaddrinuse` from a
concurrent private-port lane beam. The lane then witnessed against the already-up
substrate (pid 5739) — that beam was booted from source containing the KD-143
shim, and the wire behavior confirms the shim is loaded. No KD-143-surface code
was edited in this lane; the fix was already landed (`# KD-COVERS: KD-143`,
lib/smalt/arm_gateway/router.ex).

## Disposition

KD-143: CLOSED-SIMULATED -> CLOSED-WITH-EVIDENCE (solo live-wire witness,
docs/jira/v26.10.22/receipts/kd143-sqlfilter-close.md, postdating shim mtime
1792602656). Register edit made manually per the BK-36/KD-154 convention
(kd_flip.py flips only OPEN -> CLOSED-SIMULATED; the SIMULATED -> WITH-EVIDENCE
promotion is a manual, receipt-gated edit).
