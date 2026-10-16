# DoD-4 — SDK validation recipes: runnable, executed, witnessed

Lane: DoD-4 · date: 2026-10-15 · owner file: `justfile.d/04-sdk-recipes.just`
(also touched, env-only: `test/sdk-full/package.json` + `npm install` to add
`@azure/service-bus` — ts-reality.test.mjs required it but it was absent from
node_modules, MODULE_NOT_FOUND on first run)

## What was built

`justfile.d/04-sdk-recipes.just` — four recipes, all shebang recipes under the
shared substrate lock `/tmp/smalt-substrate.lock` (flock, 1800s wait; mkdir
spin-lock fallback on macOS without flock):

- `sdk-ts` — test/sdk-full: `node ts-run.mjs` (self-booting reality court),
  `auth.probe.mjs` + `eventhubs.probe.mjs` (self-booting on private port
  blocks 39681-39685 / 39690-39694), then a recipe-owned substrate boot on the
  canonical ports (5672/5673/9443/8443/9444, TLS certs, random shared key,
  attestation-baseline seed per ts-run.mjs's bootstrap) for the attach-mode
  probes `arm-resources`, `blob`, `cosmos`, `keyvault`. Per-probe exit
  reporting, continue-on-failure, aggregated summary, honest exit (1 if any
  harness FAIL). Includes: ownership gate (anonymous ARM must answer 200;
  a foreign enforce-mode substrate answers 401 → attach phase SKIP-loud) and
  boot-retry loop (4 attempts) after a measured teardown/boot port-release
  race (:eaddrinuse on first attempt).
- `sdk-census` — `SMALT_SDK_ROOT=$PWD/test/sdk-smoke/node_modules bash
  scripts/sb_census_replay.sh`, exit-code contract preserved (0/1/2/3 =
  pass/fail/substrate-down/harness-SKIP), verdict line printed.
- `sdk-py` — `bash test/sdk-python/run.sh` (self-booting under the same lock,
  private ports 39272-39456), exit contract preserved.
- `sdk-all` — aggregates the three with per-lane PASS/FAIL/SKIP verdict lines;
  exits 1 only when a lane FAILs (exit 1); exit 3 lanes map to SKIP.

justfile.d/01 was still a stub at run time, so the recipes boot their own
substrate per docs/DEV_LOOP.md under the lock; sdk-ts can be retargeted to
`substrate-up/down` when 01 lands.

## Execution witness — `just sdk-ts` (exit 1; 7 harnesses, 5 FAIL files)

Ran 3 attempt generations against a contended tree; the final run got all 7
harnesses against owned substrates. Log: `/tmp/dod4-ts-final2.log` (attach
phase) + `/tmp/dod4-ts-final.log` (full ts-reality suite detail).

- ts-run.mjs — FAIL: **10 pass / 6 fail** (16 tests):
  1. oauth azidentity ClientSecretCredential end-to-end (msal tenant-discovery
     envelope routes to login.smalt.local NXDOMAIN — documented FAIL class)
  2. kv createKey over https TLS twin (route placement)
  3. kv getKey against http egress (azidentity enforces https)
  4. sb sessions: sessionId not preserved on receive (`undefined !== 'S1'`)
  5. eventhubs producer/consumer round-trip ($management link never answered
     on the 5673 lane — UNSUPPORTED_OPERATION; WIRE_PARITY PARTIAL)
  6. blob listBlobsFlat (substrate list XML omits `<Segment>` wrapper)
- auth.probe.mjs — PASS **9/9** (enforce-mode: STS mint, sdk-credential 200,
  tokenless/tampered/expired/nbf/duplicate-auth 401s, api-version 400s).
- eventhubs.probe.mjs — FAIL **4/5** (`wire-delivery-ordered-sequence`
  ORDER_VIOLATION: sent 0..5, received [null×6]).
- arm-resources.probe.mjs — FAIL **8/11** (fails: `locations list` 404
  RouteNotFound; `resources listByResourceGroup` 404 pagination; `resourcegroup
  update` PATCH 404 route missing — raw STS/LRO CRUD path passes).
- blob.probe.mjs — **15/15 PASS**.
- cosmos.probe.mjs — FAIL **17/20** (fails: `item.upsert(existing)` 409
  Conflict; `bulk upsert` single-partition + cross-partition — "Partition key
  provided in the header doesn't match the partition key of the document").
- keyvault.probe.mjs — **11 FAIL / 4 PASS/DIVERGENCE** (SDK-path failures on
  PUT/PATCH/rotationpolicy/deletedkeys routes: MissingXMsVersion routed to
  blob-storage error path, PATCH /keys/:name/ route absent, crypto verify
  RS256 valid=false; substrate-native create/release/crypto-encrypt/decrypt/
  wrap/unwrap/sign all PASS).

`just sdk-ts` summary line: `7 harnesses, 5 FAIL`.

## Execution witness — `just sdk-census` (exit 1) — FIRST census execution

`scripts/sb_census_replay.sh` with `SMALT_SDK_ROOT=test/sdk-smoke/node_modules`
(real @azure/service-bus from the in-repo SDK root). Substrate up on private
ports 39792/39790 after ~2s. **8/11 PASS, 3 FAIL** — first-ever execution of
the written-but-unexecuted census probes:

- PASS: authentication, bytes, exclusive-session, renewal-peek,
  abandon-complete, dead-letter, dlq-properties, ordered-session
- FAIL: `stale-handle`, `lock-duration`, `deferred-receive`
  (fail-closed per census contract; details in the run log)

## Execution witness — `just sdk-py` (exit 2 — substrate boot BLOCKED)

`test/sdk-python/run.sh` acquired the substrate lock and attempted boot; mix
compile of the shared tree failed in `lib/smalt/data_plane/blob_storage.ex`
(`resolve_refs/4` undefined; also `mismatched_if_match?/2` at :343/:479) — an
in-flight edit by another lane on the shared checkout (Compile-freeze SLA
violation, not this lane's file). Re-verified after the run: `mix compile`
still fails at blob_storage.ex:479. Per lane rules (no lib/ fixes in this
lane), the py lane witnesses the blocker honestly: **FAIL (substrate
timeout) — shared-tree compile break, pre-existing to this lane's arrival**.

## Contention notes (witnessed, not fixed)

- Cross-lane contention was the dominant failure mode: flocks queued 15-30
  min behind other lanes; two 30-min background windows were reaped by the
  harness while queued on the lock; a foreign enforce-mode substrate
  (auth_mode :enforce, boot eval identical to the ws-08 class) squatted the
  canonical ports across several attempts — one leaked instance (lock free,
  ~1h old, holding all five canonical ports) was killed per the harness's own
  remediation line (`lsof -ti tcp:5672 | xargs kill -9`) after verifying it
  was a leaked mix-run smalt substrate, not an active lane's.
- The ownership gate converts the foreign-substrate collision into a loud
  SKIP instead of a false 401 sweep (that failure mode was witnessed live:
  first attach attempt reported 0/15 blob "FAIL MalformedBearerHeader" purely
  from hitting the foreign substrate).

## Honest exit semantics

- `sdk-ts` exit 1 = real probe FAILs on filed divergence classes (witnessed),
  not harness failure.
- `sdk-census` exit 1 = real census probe failures, first execution witness.
- `sdk-py` exit 2 = substrate boot blocked by shared-tree compile break
  (other lane's in-flight lib/ edit, re-verified failing after the run).

## Final verdict lines

    sdk-ts      FAIL — 7 harnesses run: auth 9/9 PASS, blob 15/15 PASS,
                ts-reality 10/16, arm-resources 8/11, cosmos 17/20,
                eventhubs 4/5, keyvault 11F/4P (exit 1)
    sdk-census  FAIL — 8/11 probes PASS (first census execution); fails:
                stale-handle, lock-duration, deferred-receive (exit 1)
    sdk-py      FAIL — substrate boot blocked by shared-tree compile break in
                lib/smalt/data_plane/blob_storage.ex (other lane's in-flight
                edit; exit 2)
