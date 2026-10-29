# T35LRO — ARM control-plane LRO contract (empirical leg)

**Standing:** **PASS** (0 errors), well inside the 15 s typed-FAIL envelope and the T21 p99 3.6 s cycle envelope.

## Scope

Real provisioning chain via raw REST — `@azure/arm-servicebus` is **not** vendored in `verification/ts` (verified: `node_modules/@azure` carries `service-bus`, `core-lro`, `identity`, but no arm-servicebus), so the lane rides the 9444 TLS twin with an STS bearer (KD-15 shape) exactly like `scripts/bench/scvd_t21_arm_ramp.mjs`. 20 provisions of `Microsoft.ServiceBus/namespaces` (a real smalt `lro_type?`, `lib/smalt/arm_gateway/router.ex:3100`) plus a sync queue PUT leg under each namespace.

## Result rows (`tmp/bench/t35-lro.jsonl`, final run)

```json
{"lane": "t35-lro", "surface": "arm", "op": "lro-namespace-provision-e2e", "n": 20, "ops_per_sec": 10.864, "p50_ms": 89, "p95_ms": 119, "p99_ms": 119, "errors": 0, "fails_over_15s": 0, "transport_retries": 0, "last_transport_err": null, "sync_200_face_count": 0, "provisioning_errors": 0, "machine": {"cpu": "Apple M3 Max", "cores": 16, "ram_gb": 48, "node": "v26.10.0", "elixir": "1.19.5", "otp": "28", "darwin": "26.2", "endpoint": "https://127.0.0.1:9444"}, "standing": "PASS"}
```

```json
{"lane":"t35-lro","transposed_from":"arm-queue-put-sync row","n":20,"ops_per_sec":606.061,"p50_ms":2,"p95_ms":2,"p99_ms":3,"errors":0,"transport_retries":0}
```

(Second row abridged for width; full row on disk in `tmp/bench/t35-lro.jsonl`.)

## Poll-cadence contract (what the wire actually says)

All 20 provisions: `202` + `Azure-AsyncOperation` + `Location` + `Retry-After: 1`.

- **Header content**: `Azure-AsyncOperation` and `Location` are the **same URL** on smalt (`/subscriptions/{sub}/operations/{opid}`). Real ARM differentiates them (Location → resource URI, Azure-AsyncOperation → operation status). A client that polls `Location` per real-ARM semantics would poll the operation URL — it happens to work here because smalt serves the operation body there. Observation only; KD minting is the registrar's call.
- **Cadence**: Retry-After declares 1 s; first poll lands ~90 ms after submission and is **already terminal `Succeeded`** — the smalt LRO sweeper flips the operation before the first declared-cadence poll. All 20 runs: 1 poll per provision, `body_status Succeeded`, `retry_after` absent on the terminal poll. No `InProgress` sighting was possible at this cadence — the operation terminates in <90 ms, faster than the first poll.
- **Terminal-state latency**: p50 89 ms, p95/p99 119 ms (e2e, submission→terminal poll). 0/20 over 15 s. Envelope check vs T21 (`scvd-t21-arm-ramp.md`, cycle p99 3615.5 ms at c=128): this lane is sequential and 30-40x under that envelope.

## Machine

`just bench-machine`: `{"cpu":"Apple M3 Max","cores":16,"ram_gb":48,"elixir":"1.19.5","otp":"28","darwin":"26.2"}` + harness `node v26.10.0`.

## Honest-run ledger

1. First runs 404 (`RouteNotFound`): generic child-resource routes are case-sensitive — `resourceGroups` (capital G), unlike the RG route's `resourcegroups`. Fixed in harness.
2. Next run 400 (`InvalidResourceShape`): smalt GraphLaw requires `skuName (Basic|Standard|Premium)` on ServiceBus namespaces. Harness now sends `sku: {name:"Standard", tier:"Standard"}` (what the real SDK sends). These 400/404s are client harness defects, not substrate defects; the substrate behavior on both was correct typed refusal.
3. Final run: 0 errors, 0 transport retries, 20/20 clean.
4. Result file discipline: the lane's jsonl briefly carried rows from the defect runs; it was trimmed to the final run's 3 rows (lane-owned file only).

## Compliance

- Substrate already live (beam on 9443/9444) — loud-SKIP path implemented (exit 3), never restarted anything.
- Lane writes ONLY `tmp/bench/t35-lro.jsonl`. Harness: `/Users/sac/smalt/scripts/bench/t35_lro_contract.mjs`.
- Typed FAIL exit 1 on >15 s provisioning is implemented and armed (threshold `FAIL_MS = 15000`).
