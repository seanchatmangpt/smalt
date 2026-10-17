# Receipt — V261016-08 (lane333, Service Bus SDK census + private-port SDK sweep)

- **Subject**: `/Users/sac/smalt` working tree @ `main` `fd9cfea` (uncommitted in-flight lane diffs in `lib/` owned by other lanes; no lib/ edits by this lane)
- **Date**: 2026-10-16
- **Status**: census ALIVE (11/11, exit 0); sweep executed on private ports; loud skips recorded below

## Census (11 probes, fail-closed, zero skips)

```bash
MIX_BUILD_ROOT=_build-lane333 \
SMALT_TEST_ARM_PORT=39796 SMALT_TEST_EGRESS_PORT=39797 \
SMALT_TEST_AMQP_PORT=39798 SMALT_TEST_EVENT_HUBS_PORT=39799 \
SMALT_SDK_ROOT=test/sdk-smoke/node_modules bash scripts/sb_census_replay.sh
# exit 0
```

`test/sdk-smoke/census.test.cjs` registers 11 probes (authentication, bytes,
exclusive-session, renewal-peek, abandon-complete, stale-handle, dead-letter,
dlq-properties, ordered-session, lock-duration, deferred-receive). All 11
executed and passed against the self-booted private substrate
(amqp 39798 / arm 39796), 17963 ms wall, `ℹ pass 12 / fail 0 / skipped 0`.
Supplementary file `test/sdk-smoke/sb-extra.probe.cjs` adds 3 distinct record
registrations (scheduleMessage, receiveAndDelete-delivery,
acceptNextSession-no-session) → 14 total probe/record registrations across the
census family; the 3 supplementary ran against the lane333 persistent
substrate, 2 passed, scheduleMessage hit the registered OPEN KD-47
(`$management` schedule → `NotImplementedError: UNSUPPORTED_OPERATION`).

Boot note: first invocation exited 2 (cold `_build-lane333` compile overran
the 60 s poll window — KD-48's harness class, re-witnessed); after
pre-compiling the lane build root the run passed clean. The front door
exports `SMALT_TEST_*_PORT`, so the private-port invocation is supported.

## Private-port SDK sweep (same lock discipline, substrate arm=39796 egress=39797 amqp=39798 eh=39799 arm_tls=39800)

| leg | result | receipt |
|---|---|---|
| census (self-boot) | 11/11 exit 0 | sdk-results/ts-servicebus-census.md |
| sb-extra (TS-4) | 2/3, KD-47 OPEN | sdk-results/ts-servicebus-census.md |
| ts-arm-resources | 8/11, KD-30/31/32 OPEN | sdk-results/ts-arm-resources.md |
| ts-storage-blob | 15/15 exit 0 | sdk-results/ts-storage-blob.md |
| ts-event-hubs (self-boot 39690-4) | 6/6 exit 0 | sdk-results/ts-event-hubs.md |
| ts-auth (self-boot 39681-5) | 9/9 exit 0 (after CA retry) | sdk-results/ts-auth.md |
| py-arm-resources | 12/12 exit 0 | sdk-results/py-arm-resources.md |
| py-servicebus | 2/7, KD-77-class residual | sdk-results/py-servicebus.md |
| py-auth-keyvault | 9/13, KD-16 re-witnessed + 3 env-qualified rows | sdk-results/py-auth-keyvault.md |
| py-eventhub-eventgrid (run.sh block) | 2/4, pyamqp decode residual | sdk-results/py-eventhub-eventgrid.md |

## Loud skips (harness cannot boot privately — no faked passes)

- **ts-cosmos**: `test/sdk-full/cosmos.probe.mjs` hardcodes
  `http://127.0.0.1:8443` (no port env); canonical 8443 is held by the user's
  live enforce-mode substrate (pid 882). Port law: no eviction. SKIP.
- **ts-keyvault**: `test/sdk-full/keyvault.probe.mjs` hardcodes
  `http://127.0.0.1:9443` / `:8443` (no port env); same holder. SKIP.
- **py-cosmos**: `test/sdk-python/py_cosmos.py` hardcodes
  `http://127.0.0.1:8443`. SKIP.
- **py-storage-blob**: `test/sdk-python/py_storage_blob.py` hardcodes
  `http://127.0.0.1:8443`. SKIP.
- **py-resourcegraph-monitor**: `py_resourcegraph_monitor.py` hardcodes
  `http://127.0.0.1:9443` / `:8443`. SKIP.
- **`just sdk-ts` full recipe**: phase-2 attach block hardwires canonical
  5672/5673/9443/8443/9444 and an `lsof tcp:9443` ownership gate; held ports
  → not privately runnable as-is. Its phase-1 self-booting legs (ts-auth,
  ts-eventhubs) and the env-portable attach legs were executed individually
  instead (receipts above). SKIP (recipe-level), legs covered.

## Teardown / hygiene

- Substrate killed (process-group TERM→KILL), all lane ports verified released
  after the sweep, `/tmp/smalt-substrate.lock` released, no orphan beams.
- `MIX_BUILD_ROOT=_build-lane333` retained (lane lease; coordinator cleanup at
  integration).
