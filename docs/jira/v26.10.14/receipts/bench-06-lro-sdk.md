# Receipt: bench-06-lro-sdk (B-6)

- **Lane**: B-6 — LRO storm through the real Python mgmt SDK (azure-mgmt-resource, track2)
  at the smalt ARM gateway. BEAM-tier sibling: `scripts/stress/lro_storm.py` (not modified).
- **Subject**: harness `/Users/sac/smalt/scripts/bench/b6_lro_sdk.py`
  (self-contained; boots an anonymous private-port substrate on 39840-39843 via
  `scripts/stress/_substrate.py` helpers).
- **Authority**: B-6 lane order; v26.10.14 20-lane fan-out. No commits, no lib/ edits.
- **Data**: `docs/jira/v26.10.14/bench/b6-lro-sdk.jsonl` — 9 rows; the last row
  (stamp `20261015T191126`) is the final clean full-pass run superseding earlier
  debug rows (2 boot-fail rows, 1 pre-fix run with the phase-c thread-local bug, 2
  probe-path bug rows, 1 read-coupled sweeper run, 1 double-count bug run).

## Measurements (final run, api-version 2021-04-01, smalt dev substrate, TLS :39841)

| phase | subject | result |
|---|---|---|
| a | 100 concurrent generic NSG PUTs via `begin_create_or_update_by_id` | 482.9 submissions/s; submit p50 32.9 ms / p95 68.3 ms; poll-to-terminal p50 0.1 ms (100/100 ok, 0 errors) |
| a2 | 100 concurrent generic storageAccount PUTs (real smalt LRO type) | 117.5 submissions/s; poll-to-terminal p50 267.8 ms / p95 375.6 ms / max 400.3 ms; 100/100 ok |
| b | 300 sequential RG create+delete (SDK) | 255.4 ops/s at default `lro_delay_ms=0` (op p50 3.7 ms); **3.42 ops/s at `lro_delay_ms=250`** (op p50 284.6 ms) — RG delete is itself an LRO whose poller wait absorbs the configured delay |
| c | sweeper convergence, 50 LROs, canary-then-wave protocol | 49/49 non-canary ops **terminal at first read after a 35 s silent window** (`swept_at_rest_fraction` 1.0); at-rest convergence ≤ 35.16 s from first submission (sweep tick 30 s); canary also Succeeded; 0 unconverged |

## Poll-terminated vs sweeper-terminated split

- **Phase a2 (`lro_delay_ms=250`)**: 100/100 **poll-terminated** (first op-record read
  showed `InProgress` for all 100; SDK pollers at 50 ms interval drove terminality).
  Sweeper count 0 — no op lived long enough idle to be swept while the SDK was polling.
- **Phase c (no SDK polling, 35 s silent window)**: 49/49 **sweeper-terminated at rest**
  (canary-then-wave: no non-canary op was ever read before it was found terminal, so the
  background sweeper, not any reader, flipped them). Read-coupled run at `lro_delay_ms=0`
  (earlier row) had shown 50/50 flipped on the first probe wave — lazy-on-read, not sweeper.

## Divergences found (not KD-30/31/32 — new, measurement-altering)

1. **NSG is not an LRO type in smalt.** `router.ex lro_type?` admits only
   `Microsoft.Storage/storageAccounts` + `Microsoft.Compute/virtualMachines`; NSG PUTs are
   synchronous (201, no `Azure-AsyncOperation`), so the SDK poller terminates on the
   initial response (phase a poll-to-terminal ≈ 0.1 ms). KD-northy: sync-vs-LRO
   classification of `Microsoft.Network/networkSecurityGroups` vs real ARM (NSG PUT is
   LRO in real ARM). Measurement note: phase a measures sync PUT throughput + no-op
   poller latency, not LRO polling.
2. **Resource records are stored `provisioningState=Succeeded` at PUT time** (router.ex
   `handle_resource_put` stores the record before `LRO.start_op`), so resource GETs cannot
   observe InProgress — LRO state is observable ONLY on the op record
   (`/subscriptions/{sub}/operations/{op_id}`). This forced the canary-then-wave protocol.
3. **Phase-b sensitivity to `:lro_delay_ms`**: RG delete is an LRO, so its ops/sec scale
   with the configured delay (255 ops/s @ 0 ms vs 3.42 ops/s @ 250 ms).

## Verification

- Final run: `B6 PASSED`, exit 0 — a 100/100, a2 100/100, b 300/300, c 0 unconverged.
- Earlier exits: 137 (teardown port-sweep SIGKILLed the harness itself; fixed by
  excluding self pids from the sweep), probe-path bugs (name appended after query
  string; port mangled into op-URL path), phase-c thread-local bug — all fixed in the
  harness, none in lib/.
- Substrate boot retries: 2 failed attempts on a concurrent lane's broken
  `lib/smalt/hw/frame.ex` compile (shared-tree compile-freeze SLA); attempt 3 booted clean
  after the owning lane healed it.

## Residue

- Substrate down: 0 listeners on 39840-39843 (verified).
- `/Users/sac/smalt/_build-b6` lane build root still on disk — `rm -rf` denied by the
  sandbox this session; coordinator should delete it at integration (cleanup law).
- No commits made.