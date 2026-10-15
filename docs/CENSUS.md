# CENSUS

# Service Bus SDK Census

One-command replay: `scripts/sb_census_replay.sh`. Boots the smalt substrate
(`mix run --no-halt`, MIX_ENV=test) and runs the 8-probe census
(`test/sdk-smoke/census.test.cjs`) against it with the real
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

## Exit codes (census-run.mjs codes, passed through)

| Code | Meaning |
|---|---|
| 0 | All 8 probes PASS |
| 1 | Census failure — at least one probe failed |
| 2 | Substrate never opened 5672/9443 within 60s |
| 3 | Harness failure — ports occupied, spawn error, or missing/invalid `SMALT_SDK_ROOT` |

## Acceptance rule

All 8 probes PASS, or the broker is not a Service Bus-compatible court.
Zero skips is part of the contract: any probe that cannot run fails the run
(fail-closed), it is never silently skipped.
