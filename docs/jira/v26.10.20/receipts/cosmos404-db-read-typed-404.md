# COSMOS404 — missing-database GET answers typed 404, never 500

**Standing:** **ALIVE** (defect class closed at HEAD; regression fenced by test)

- Lane: COSMOS404 (writer), 2026-10-21, repo /Users/sac/smalt
- Witnessed defect (T1/T14, 2026-10-21; disclosure
  `tmp/bench/scvd_tier1.mjs:46-48`): GET
  /dbs/<nonexistent> answered 500 on the live substrate, crashing
  @azure/cosmos `databases.createIfNotExists` read-first (the SDK throws on
  anything non-404 during the read probe).
- **Root cause (class):** the missing-database arm
  (`lib/smalt/egress/CosmosRoutes.ex:83-109`) renders through
  `EgressRouter.blob_error/3`; the KV404 lane traced the 500 to a
  BadBooleanError in blob_error/3's face guard, fixed in ad3136b with the
  `&&` short-circuit. The Cosmos arm was consumed by the same defect: the
  witness substrate predates the ad3136b/934d21a builds.
- **State at HEAD 934d21a:** the arm already answers the Azure-correct face.
  No lib/ change was needed; the lane's deliverable is the Chicago wire
  regression fence so the arm cannot rot back.

## Wire evidence (live substrate, pid 56472)

BEFORE (witnessed, pre-ad3136b substrate — T1 lane, quoted from
tmp/bench/scvd_tier1.mjs:46-48 disclosure): `500` on GET /dbs/<absent>.

AFTER (this lane, 2026-10-21):

```
=== AFTER (HEAD 934d21a + live substrate pid 56472, TLS twin 9444) ===
{"code":"NotFound","message":"Entity with id does-not-exist-c404 not found"}
HTTP 404
=== real SDK client.database().read() ===
code: 404 | script: tmp/c404_repro.mjs (real @azure/cosmos over 9444 TLS,
NODE_EXTRA_CA_CERTS=.smalt/tls/ca-cert.pem, STS bearer via 9443 STS)
```

Plain-http 8443 arm identical: 404 same envelope. Unauthenticated GET answers
401 InvalidAuthenticationToken (enforce mode) — no auth bypass on the arm.

## Test

`test/integration/cosmos404_typed_error_test.exs` — real HTTPS over the test
boot's ephemeral twin listener (Bandit + Smalt.Application.TlsTwinDispatch),
real curl subprocess, KD-15 bearer dance. Seeds a real database (201 leg),
reads it (200 leg), then proves the absent-database read answers 404 with the
"NotFound" envelope twice (idempotent, no 500).

```
$ MIX_BUILD_ROOT=_build-c404 mix test test/integration/cosmos404_typed_error_test.exs
11:03:09.342 [info] Sent 201 in 30ms
11:03:09.360 [info] Sent 200 in 185µs
11:03:09.376 [info] Sent 404 in 331µs
11:03:09.391 [info] Sent 404 in 284µs
.
Finished in 0.4 seconds (0.00s async, 0.4s sync)
1 test, 0 failures
```

## Cosmos test tier

```
$ MIX_BUILD_ROOT=_build-c404 mix test <6-file cosmos tier>
21 tests, 4 failures
```

The 4 failures are ALL in `test/internal/cosmos_analytical_ttl_test.exs`
(analyticalStorageTtl echo) and are PRE-EXISTING: they fail identically with
the file run alone on a fresh _build-c404 build of HEAD, and the lane's only
diff is the new test file (no lib/ change; `lib/smalt/data_plane/cosmos.ex`
untouched). Disclosed honestly per lane law; NOT session-introduced.

## Machine

```json
{"cpu":"Apple M3 Max","cores":16,"ram_gb":48,"elixir":"1.19.5","otp":"28","darwin":"26.2"}
```

## Falsifier

Re-introduce a 500 on GET /dbs/<absent> (e.g. revert the blob_error/3 `&&`
short-circuit) — cosmos404_typed_error_test.exs must fail with status != 404.
Not mutation-run in this lane (lib/ is other lanes' ownership); the fence is
the test, and the KV404 lane already court-proved the same class non-vacuous.

## Files

- Added: /Users/sac/smalt/test/integration/cosmos404_typed_error_test.exs
- Receipt: /Users/sac/smalt/docs/jira/v26.10.20/receipts/cosmos404-db-read-typed-404.md
- lib/ untouched: fix already at HEAD 934d21a; registry.ex untouched.
