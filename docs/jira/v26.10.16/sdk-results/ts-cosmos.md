# TS-3: Real TypeScript @azure/cosmos SDK vs smalt Cosmos NoSQL plane (v26.10.16 re-run)

- Date: 2026-10-16
- Repo: /Users/sac/smalt @ main, v26.10.16 window
- Probe: `test/sdk-full/cosmos.probe.mjs`
- Port env: probe now reads `SMALT_TS_EGRESS` (lane-351); run against a
  lane-private substrate on ports 39360-39364 (amqp/eh/arm/egress/tls),
  MIX_ENV=test anonymous auth, attestation n/a here, booted under
  `flock -x -o /tmp/smalt-substrate.lock` with the lock fd closed (`-o`).
- SDK: @azure/cosmos 4.10.1 (test/sdk-full/node_modules)

## Verdict: 18/20 PASS, 2 FAIL (exit 1, fail-closed; both FAIL = KD-44)

Embedded probe output (lane run, substrate 39363 egress):

```
[PASS] db.createIfNotExists — database ts3db-1792169258282 created (statusCode ok)
[PASS] container.createIfNotExists — container c1 with /pk partition key
[PASS] item.create — status 201, etag "b4650cde4f07fb48eecb2f658aa8594f2e969313678391ce2e6c1679f4fada22"
[PASS] item.read — status 200, value="héllo 🌊 multibyte", etag="b4650cde4f07fb48eecb2f658aa8594f2e969313678391ce2e6c1679f4fada22"
[PASS] item.replace(unconditional) — status 200, new etag "373648d9cb6d6fe1bc3b7eb9d770603a1becd31edb4030327274e7e869fda912"
[PASS] item.replace(IfMatch current) — status 200
[PASS] item.replace(stale etag -> 412) — code=412 body={"code":"PreconditionFailed","message":"The condition specified using HTTP conditional header(s) is not met."}
[PASS] item.delete(stale etag -> 412) — code=412 body={"code":"PreconditionFailed","message":"The condition specified using HTTP conditional header(s) is not met."}
[PASS] item.upsert(existing) — status 200 (200 = replaced)
[PASS] item.upsert(new) — status 201 (201 = created)
[PASS] item.delete(bare -> 204) — status 204
[PASS] query('SELECT * FROM c') admitted — returned 1 docs, requestCharge=1
[PASS] query(WHERE-clause) refused 400 — code=400 body={"code":"SyntaxError","message":"The query syntax is invalid."}
[PASS] partition-scoped query — returned 1 docs, all pk=p1: true
[PASS] seed 120 docs (sequential create) — 120/120 created in 93ms
[FAIL] bulk upsert 3 ops (single partition) — code=undefined body="" msg=Bulk request errored with: Partition key provided in the header doesn't match the partition key of the document.
[FAIL] bulk upsert cross-partition (3 pks) — code=undefined body="" msg=Bulk request errored with: Partition key provided in the header doesn't match the partition key of the document.
[PASS] pagination continuation (maxItemCount=25) — pages=2 totalDocs=121 firstContinuation=1#126:dHMzZGItMTc5MjE2OTI1ODI4Mi9jMQ:seq…
[PASS] databases.list (readAll) — 9 databases listed
[PASS] containers.list — containers=c1
SUMMARY: 18/20 PASS, 2 FAIL
```

## Delta vs v26.10.14 receipt (ts-cosmos.md there)

- KD-36 (upsert-of-existing 409) is FIXED on this substrate: probe 9
  `item.upsert(existing)` returns 200 (replaced), 3/3 lane runs.
- KD-44 (bulk 400 pk-mismatch) still OPEN and reproduced: probes 16-17,
  same 400 "Partition key provided in the header doesn't match the partition
  key of the document", 2/2 lane runs (single- and cross-partition).
- KD-36/KD-44 rows live in the v26.10.14 register and cite this receipt
  filename; the coverage gate merges registers across windows.

## Falsifier replay

```bash
# boot a lane substrate (any free ports), then:
SMALT_TS_EGRESS=http://127.0.0.1:<egress> node test/sdk-full/cosmos.probe.mjs
# expect: 18/20 PASS, bulk probes 16-17 FAIL per KD-44 until the bulk
# wire shape is accepted.
```
