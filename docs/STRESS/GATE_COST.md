# GraphLaw Gate Cost

## Harness

`scripts/stress/gate_cost.py` (stdlib-only, fail-closed) measures the cost of
the GraphLaw admission gate. Receipt: `tmp/gate-cost-receipt.json`
(schema `smalt-gate-cost/v1`). Exit 0 only when all budgets hold. Run:

```bash
python3 scripts/stress/gate_cost.py
```

Two phases:

1. **In-process** (`scripts/stress/gate_cost_inner.exs`, via
   `mix run --no-start`): per-type `validate_resource` latency — all admitted
   types (41 as of 2026-10-16)
   x 500 valid + 500 malformed payloads, p50/p95 microseconds, pure
   calls, no HTTP; plus registry lookups (100k each of `shape_for` /
   `latest_version` / `admitted?`), ns/op.
2. **Wire**: boots the substrate on isolated ports (default ARM 39443;
   `SMALT_GATECOST_*` env overrides) and PUTs against one
   `Microsoft.Network/virtualNetworks` resource (VNetShape: location +
   addressPrefixes) with a minted Bearer token: 500 valid PUTs (200) vs 500
   deliberately-invalid PUTs missing the required `addressPrefixes` (400
   GraphLaw refusal), p50/p95 and the p50 delta.

Budget: gate adds < 1ms p95 per request. Asserted as (a) every per-type pure
validate p95 < 1000 us and (b) wire valid-path p95 minus same-shape pure p95
< 1ms.

## Result (run 2026-10-14, verdict PASS)

In-process, per-type (500+500 samples per class, Elixir 1.19.5 / OTP 28):

| Shape | Types bound | max valid p95 (us) |
|---|---|---|
| DefaultShape | 28 | 0.92 |
| NsgShape | 1 | 0.46 |
| ResourceGroupShape | 1 | 0.75 |
| CosmosAccountShape | 1 | 0.54 |
| SubnetShape | 1 | 1.29 |
| VirtualMachineShape | 1 | 1.29 |
| KeyVaultShape | 1 | 1.29 |
| ManagedHsmShape | 1 | 1.29 |
| StorageAccountShape | 1 | 1.54 |
| VNetShape | 1 | 1.58 |
| ServiceBusNamespaceShape | 1 | 1.63 |

Worst-case pure gate cost is **1.6 us p95** — DefaultShape (single required
`location`) is cheapest; multi-prop shapes cost ~2x. Malformed payloads cost
the same as valid (max invalid p95 1.6 us) — the evaluator always walks all
constraints; there is no early-exit asymmetry to exploit.

Registry lookups (100k ops each): `shape_for` 84 ns/op,
`latest_version` 84 ns/op, `admitted?` 182 ns/op (`admitted?` does a linear
scan of the 38-type list; still 3 orders of magnitude under budget).

Wire (500 sequential PUTs per class, one keep-alive connection):

| Class | p50 | p95 |
|---|---|---|
| valid PUT (200) | 0.231 ms | 0.288 ms |
| invalid PUT (400 refusal) | 0.215 ms | 0.253 ms |
| p50 delta (invalid - valid) | -0.017 ms | |

The refusal path is marginally **cheaper** than the admitted path (it skips
the store write). The gate is not measurable over the wire: total PUT
round-trip p95 is 0.29 ms and the pure gate is ~1.6 us of it.

## Verdict

Both checks PASS: pure validate p95 1.6 us < 1ms, wire overhead p95
0.287 ms < 1ms. The GraphLaw gate adds far under the PRD budget of 1ms p95
per request — about 0.6% of the wire round-trip.

## See Also

`scripts/stress/spike.py`, `scripts/bench.py` (harness conventions;
substrate spawn / token mint / percentile helpers).
