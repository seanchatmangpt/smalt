# BK-91 — blob `<Cors>` seed: repeatable browser blob leg (BK-89 retry)

**Standing**: ALIVE
**Context**: solo

## What landed

1. `popcorn_demo/scripts/seed_blob_cors.mjs` — idempotent account `<Cors>`
   seeding via `PUT /{account}?restype=service&comp=properties` (STS token
   minted over the wire, bearer + x-ms-version 2021-12-02, 202 expected).
   Two rules: exact loopback origins (`http://127.0.0.1`, `http://localhost`)
   and a wildcard rule — the wildcard is REQUIRED because the browser smoke
   serves on a RANDOM 127.0.0.1 port and `Smalt.DataPlane.BlobCors` origin
   matching is exact-string, so no exact entry can ever match
   `http://127.0.0.1:<random-port>`. Methods/headers cover the demo walk
   (GET,PUT,HEAD,OPTIONS,DELETE; `*` headers/exposed; max-age 3600).
2. `popcorn_demo/scripts/browser_smoke.mjs` — seed wired as a best-effort
   pre-step (try/rescue): a seeding failure prints
   `[bk91-cors-seed] best-effort seed failed ...` and the walk's own
   classifier still answers `blob=SKIP(cors-preflight-403:...)` loudly —
   seeding failure can never fake a pass.

## Wire probes (real, all on the live loopback substrate)

```
$ node scripts/seed_blob_cors.mjs        # in popcorn_demo/
SEED_BLOB_CORS: OK — popcorn <Cors> rules seeded (202, PUT http://127.0.0.1:8443/popcorn?restype=service&comp=properties)
exit=0          # re-run: exit=0 again (idempotent — PUT replaces the rule set)

$ OPTIONS /popcorn/l3rb/r.txt  (Origin: http://127.0.0.1:54609, ACRM: PUT)
-> 200 (before bounce)

$ just substrate-down && substrate-up    # fresh beam (pid 89501 -> 81744)
$ OPTIONS (same probe) -> 403            # rules GONE after bounce
$ node scripts/seed_blob_cors.mjs -> 202 (reseed)
$ OPTIONS (same probe) -> 200
```

## Smoke run (with seed pre-step)

`node scripts/browser_smoke.mjs` → exit **0**. Blob verdict flipped
SKIP→OK as expected:

```
SMOKE_RECEIPT: ... blob=OK(popcorn/l3rb1792645623148-110/receipt.txt:61-roundtrip) ...
SCVD_GATE: SCVD-OK:t16:5.115ms <= 3x rolling-best 5.214ms
SMOKE_EXIT=0
```

Full receipt line: `blob=OK(popcorn/l3rb1792645623148-110/receipt.txt:61-roundtrip)`
— real PUT/GET byte-equality round-trip through the in-browser wasm BEAM.
(The CORS preflight block visible in the console log was the Event Hubs
`/topics/...` plane, an unrelated surface; the blob leg passed preflight.)

## Answer: do rules survive a substrate bounce?

**No — ETS-only, confirmed by probe, not by reading.** Rules live in
`:smalt_blob_cors` (public ETS, `Smalt.DataPlane.BlobCors`); after a real
down/up the same preflight that answered 200 answered 403 on the fresh beam.
The seed script is the documented answer: run it (it now runs automatically
as the smoke's best-effort pre-step) after every substrate boot. The prior
KD-122 "close witness" stood only while the seeding beam stayed up.

## Exit-code ledger

| command | exit |
|---|---|
| `node scripts/seed_blob_cors.mjs` (run 1) | 0 |
| `node scripts/seed_blob_cors.mjs` (run 2, idempotence) | 0 |
| `node scripts/browser_smoke.mjs` | 0 |
| preflight OPTIONS before bounce / after / after reseed | 200 / 403 / 200 |

Not committed (per task order).
