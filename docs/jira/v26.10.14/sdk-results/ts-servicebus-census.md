# TS-4 Service Bus SDK Census Receipt — @azure/service-bus 7.10.0

- Lane: TS-4, 2026-10-15, repo `/Users/sac/smalt` (v26.10.14, branch `main`)
- SDK: `@azure/service-bus@7.10.0` (installed `--no-save` under
  `test/sdk-smoke/node_modules`; no package.json/lock committed)
- Harness: `test/sdk-smoke/census.test.cjs` (11 registered probes) via
  `scripts/sb_census_replay.sh` + `test/sdk-smoke/census-run.mjs`
- Run: `flock -x /tmp/smalt-substrate.lock` + private ports 39790-39795
  (`SMALT_TEST_*_PORT`; config/test.exs binds random ephemeral ports unless
  these are exported — the front door does not export them, so the two
  front-door runs failed exit 2 with cold compile missing the 60s poll window;
  private-port run is the documented fallback in census-run.mjs itself)
- Substrate: real smalt AMQP broker, MIX_ENV=test, minted `sb_shared_key`,
  CBS `put-token` status=200 `LOCAL_SIGNATURE_VERIFIED_NOT_AZURE_AUTHORITY`
  on every link (witnessed in `.logs/census-substrate.log`)
- Raw log preserved at `/tmp/sb-census-run2.log`; substrate log at
  `test/sdk-smoke/.logs/census-substrate.log`

## Verdict

**CENSUS: 8 / 11 PASS, 3 FAIL — sb_census_replay exit 1 (census failure, not
harness failure; exit code witnessed).**

## Per-probe results (real node --test output)

| probe | result | time |
|---|---|---|
| authentication | PASS | 26.8ms |
| bytes | PASS | 416.8ms |
| exclusive-session | PASS | 73.7ms |
| renewal-peek | PASS | 45.6ms |
| abandon-complete | PASS | 10.2ms |
| stale-handle | FAIL | 17.3ms |
| dead-letter | PASS | 8.9ms |
| dlq-properties | PASS | 8.1ms |
| ordered-session | PASS | 7.0ms |
| lock-duration | FAIL | 1.5ms |
| deferred-receive | FAIL | 6.99ms |

node --test summary line: `tests 12, pass 8, fail 4` (4th "fail" is the suite
itself failing because 3 probes failed).

## Failures with wire evidence

### stale-handle — RestError HPE_INVALID_CONSTANT
- Probe creates queue with `lockDuration PT15S` via
  `ServiceBusAdministrationClient.createQueue` → SDK issues
  `PUT http://127.0.0.1:39790/census-stale-95a3b9c8-...?api-version=2024-05`
  with `content-type: application/atom+xml;type=entry;charset=utf-8`,
  `user-agent: azsdk-js-azureservicebus/7.10.0 core-rest-pipeline/1.25.0 Node/26.10.0`,
  `x-ms-client-request-id 7f3752a0-f9ec-4c74-ad2d-4fc54372e78f`.
- Error: `RestError: Parse Error: Expected HTTP/, RTSP/ or ICE/ (HPE_INVALID_CONSTANT)`
  — the substrate's HTTP management surface on the AMQP port answered the
  ATOM+XML queue-create PUT with a response Node's HTTP parser rejects
  (non-HTTP/1.x status line / malformed framing). Fails before any lock-loss
  scenario is reached.

### lock-duration — same class
- `PUT http://127.0.0.1:39790/census-lockdur-95a3b9c8-...?api-version=2024-05`
  (content-length 389, request-id `c6a4a5a1-838c-44b8-bb31-f0fed2726279`),
  identical `HPE_INVALID_CONSTANT` parse error. Probe never reached the 2s
  lockDuration assertion; blocked at queue-create.

### deferred-receive — missing deliveryCount on deferred delivery
- Probe deferred a message then received it by sequence number; the deferred
  redelivery arrived but `message.deliveryCount` was `undefined` where the
  probe asserts `2` (census.test.cjs:259, `DEFERRED_DELIVERY_COUNT`,
  `undefined !== 2`). The receive-by-sequence-number wire path itself worked
  (delivery arrived with the right body); the deferred-redelivery count
  annotation is missing on the wire.

## Supplementary probes (test/sdk-smoke/sb-extra.probe.cjs, TS-4-written)

Run against a dedicated substrate (AMQP 39810, same minted-key CBS flow,
full log `/tmp/ts4-extra-substrate.log`):

| probe | result | evidence |
|---|---|---|
| scheduleMessage | FAIL — `NotImplementedError: UNSUPPORTED_OPERATION` | thrown during scheduleMessages; substrate log shows CBS auth + `$management` put-token for `sb://127.0.0.1:39810/ts4-extra/$management` all status=200, then the management operation itself is refused. Message scheduling over the `$management` link is not implemented in the substrate. |
| receiveAndDelete-delivery | PASS | message sent (`ts4-fire-1`), delivered exactly-once in receiveAndDelete mode with matching messageId |
| acceptNextSession-no-session | PASS | acceptNextSession on a sessionless queue threw after `maxWaitTimeInMs: 2000` per SDK contract (no unexpected session accepted, no hang) |

Extra run: `pass=2 fail=1`, exit 1.

## Harness finding (pre-existing, not lane-introduced)

`config/test.exs` binds random ephemeral ports unless `SMALT_TEST_*_PORT` is
exported, but `scripts/sb_census_replay.sh` front door never exports them — the
front-door defaults (5672/9443) can never match what the substrate binds, so
the unmodified front-door invocation structurally cannot pass; it only works
with `SMALT_TEST_*_PORT` exported (private range) or with the substrate port
env injection some lanes' census-run.mjs variants add. Witnessed twice (both
front-door runs failed exit 2 while the substrate was actually up on random
ports). Flagged for the coordinator; not fixed (no lib/test edits allowed).

## Cleanup

Substrate killed (port 39810 closed, witnessed `SIGTERM received - shutting
down` in substrate log); flock released; no lib/ or test/ edits; only new file
is `test/sdk-smoke/sb-extra.probe.cjs` (coordinator-sanctioned).

Supplementary note (fin-08): `test/sdk-smoke/sb-extra.probe.cjs` is now CRC-covered — `scripts/sdk_coverage.py` counts its 3 registered probes into `registered_total` (11 + 3 = 14).
