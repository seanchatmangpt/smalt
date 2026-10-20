# CENSUS

# Service Bus SDK Census

> **RETIRED@64f6099** — the pre-reset census machinery (`scripts/sb_census_replay.sh`,
> `test/sdk-smoke/census.test.cjs`) was deleted in the clean-room reset. The run below
> is a preserved witness record; the live census successor is `verification/ts/census.test.cjs`
> (run via `verification/ts/run-all.mjs`), probe table moved with it.

One-command replay (retired): `scripts/sb_census_replay.sh`. Boots the smalt substrate
(`mix run --no-halt`, MIX_ENV=test) and runs the census probes
(`test/sdk-smoke/census.test.cjs` — retired; live probe table now in `verification/ts/census.test.cjs`)
against it with the real
`@azure/service-bus` SDK over loopback AMQP (`127.0.0.1:5672`).

## Run

```bash
export SMALT_SDK_ROOT=<legacy-sdk-root>/playground/node_modules  # node_modules with @azure packages
scripts/sb_census_replay.sh
```

The script generates a dev shared key (`openssl rand -base64 32`) and exports
`SMALT_SB_SHARED_KEY`; `census-run.mjs` mints the broker key and injects it
into both the substrate (`Application.put_env(:smalt, :sb_shared_key, ...)`)
and the census process env, so the SAS the SDK computes matches the broker
verifier.

## Last replay (2026-10-16)

`SMALT_SDK_ROOT=test/sdk-smoke/node_modules scripts/sb_census_replay.sh` — exit 0:

```text
✔ service bus census: 11 probes, fail-closed, zero skips (17972.374833ms)
ℹ tests 12
ℹ pass 12
ℹ fail 0
ℹ skipped 0
ℹ duration_ms 18139.067625
```

11 probes / 12 tests, all PASS, zero skips. Substrate up on 39792/39790 in
2.5s; slowest probe `stale-handle` (15.2s, waits out the 30s-clamped lock
window via the 2s `lockDuration` path).

## Probes

| Probe | Dialect invariant pinned | Implemented in |
|---|---|---|
| authentication | Wrong SAS key is rejected with an auth-failure error, never a silent accept | `census.test.cjs` `authenticationCase` — bad-key `ServiceBusClient` send must reject `/Unauthorized\|Authentication/i` |
| bytes | Binary (non-UTF8) message bodies survive a round-trip byte-exact with messageId preserved | `census.test.cjs` `bytesCase` — `Buffer.from([0,255,1,128])` round-trip + `deepEqual` |
| exclusive-session | A second `acceptSession` on a locked session is rejected `SessionCannotBeLocked`; `renewSessionLock` extends the lock | `census.test.cjs` `exclusiveSessionCase` |
| renewal-peek | `peekMessages` returns body-exact messages without locking; `renewMessageLock` extends the delivery lock; peek is empty after complete | `census.test.cjs` `renewalPeekCase` |
| abandon-complete | `abandonMessage` redelivers with `deliveryCount` incremented; complete removes the message | `census.test.cjs` `abandonCompleteCase` |
| stale-handle | Complete on an expired lock is rejected `LockLost`; redelivery carries a new lock token | `census.test.cjs` `staleHandleCase` (35s probe budget: broker clamps locks to 30s) |
| dead-letter | `deadLetterMessage` routes to the DLQ subqueue with reason/description and body intact | `census.test.cjs` `deadLetterCase` |
| ordered-session | Messages in a session are delivered in send order | `census.test.cjs` `orderedSessionCase` |
| lock-duration | Complete after the queue's configured (short) lock duration expires is rejected `LockLost`; the message redelivers | `census.test.cjs` `lockDurationCase` (2s lockDuration probe) |
| deferred-receive | `deferMessage` then `receiveDeferredMessages` by sequence number returns body-exact message with incremented `deliveryCount`; gone after complete | `census.test.cjs` `deferredReceiveCase` |
| dlq-properties | DLQ receive exposes `deadLetterReason`, `deadLetterErrorDescription`, and custom application properties | `census.test.cjs` `dlqPropertiesCase` |

## Exit codes (census-run.mjs codes, passed through)

| Code | Meaning |
|---|---|
| 0 | All probes PASS |
| 1 | Census failure — at least one probe failed |
| 2 | Substrate never opened 5672/9443 within 60s |
| 3 | Harness failure — ports occupied, spawn error, or missing/invalid `SMALT_SDK_ROOT` |

## Acceptance rule

All probes PASS, or the broker is not a Service Bus-compatible court.
Zero skips is part of the contract: any probe that cannot run fails the run
(fail-closed), it is never silently skipped.
