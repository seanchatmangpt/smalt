# SUITE_STABILITY — 4x back-to-back `mix test` benchmark

- Subject: `~/smalt` canonical checkout, `MIX_ENV=test`, nothing excluded.
- Date: 2026-10-14. Command: `MIX_ENV=test mix test --trace` (per-test timings parsed from trace).
- Raw logs: `tmp/stability/run{1..4}.log`, per-run failure sets `tmp/stability/fset{1..4}.txt`,
  wall receipts `tmp/stability/run{2..4}.time`, slow-test extracts `tmp/stability/slow1.txt`, `slow4.txt`.

## Stability table

| run | tests | failures | ExUnit reported | wall (instrumented) |
|---|---|---|---|---|
| 1 | 749 (+1 doctest, 19 excluded) | 12 | 8.7s (1.9 async / 6.8 sync) | not instrumented (paid cold compile) |
| 2 | 749 | 16 | 6.4s (1.9 / 4.5) | 8s |
| 3 | 749 | 10 | 6.7s (2.0 / 4.7) | 8s |
| 4 | 749 | 11 | 6.9s (2.1 / 4.7) | 9s |

Mean full-suite wall (instrumented runs 2-4): **8.3s**; mean ExUnit reported 7.2s.
Run 1 additionally paid cold `mix test` compile. All 4 runs exited non-zero —
failures in every run, no clean baseline exists today.

## Flake register

**DETERMINISTIC — failed 4/4 runs (10 tests, classified EXPECTED-IN-FLIGHT):**

- `Smalt.Amqp.SasVerifierTest` (6 tests): valid token round-trips with matching endpoint
  config; back-compat 2-arity verify; verify/1 honors the configured `:sb_endpoint`;
  `se` exactly 86400s out accepted; valid token with bare `sb://` audience; valid token
  when audience config is a string endpoint. All with `{:error, {401, "INVALID_LOCAL_SAS"}}`.
- `Smalt.Amqp.CbsRouterTest` (4 tests): valid put-token returns 200 and caches the claim;
  gc removes only expired claims; claim cap of 128 returns 429 CLAIM_CAPACITY; refreshing
  an existing claim does not hit the cap. Same `INVALID_LOCAL_SAS` root error.
- Classification basis: identical failure signature in every run, zero pass variance.
  This matches the in-flight AMQP/SAS lane (lane 93). Caveat: "lane 93 in flight" is a
  dispatch claim, not verified from lane state; the falsifier for this classification is
  these same 10 tests still failing after the AMQP lane lands (then they are true bugs).

**FLAKY — failed some runs, passed others:**

- `KvTlsTest` (`test/kv_tls_test.exs`) — 7 distinct tests, clustered in run 2 (plus
  "list keys over verified https" also in run 1 with an HTTP 500 from the TLS twin;
  run 1's 2.3s outlier on that test is its failure mode). Errors: HTTP 500 vs 200, and
  `MatchError` with `nil` right-hand side in handshake tests. All passed runs 3-4.
- `Smalt.TelemetryTest` "RollingCounters counters increment and dump/0" — failed runs 1
  and 4 (`dump[{[:smalt, :admit], %{event: :ok}}]` expected 2, got 3), passed 2-3.
  Counter state leaked between tests / async pollution.

Per-run split: R1 = 10 in-flight + 2 flaky; R2 = 10 + 6; R3 = 10 + 0; R4 = 10 + 1.

## Top 10 slowest tests (--trace timings, run 4 unless noted)

| test | suite file | run1 ms | run4 ms |
|---|---|---|---|
| store crash is contained: store restarts, listeners never go down | test/chaos/crash_isolation_test.exs | 1025 | 1025 |
| frame-split invariance: incremental feed at every offset matches unsplit | test/amqp/fuzz_test.exs | 801 | 850 |
| list keys over verified https (failed R1 — 2.3s is its failure mode; <200ms when passing) | test/kv_tls_test.exs | 2308 | <200 |
| enqueue/3 rejects the 4097th message with :capacity | test/amqp/queue_store_test.exs | ~499 | 518 |
| round-trip: encode -> decode_all reproduces the term (100 seeds x 200 terms) | test/amqp/fuzz_test.exs | 453 | 164 |
| transfer-payload round-trip: encode_message -> decode_message (100 seeds) | test/amqp/fuzz_test.exs | 230 | 247 |
| decode-never-crash: mutated binaries return tagged tuples, never raise (10k) | test/amqp/fuzz_test.exs | 57 | 242 |
| mirror captures writes within interval + epsilon | test/store_dets_test.exs | 165 | 154 |
| Bandit https boot + :ssl connect + :httpc round-trip | test/tls_test.exs | 98 | 164 |
| wrapKey/unwrapKey RSA wrap/unwrap round-trip | test/data_plane/key_vault_actions_test.exs | 89 | 74 |

Hot spots: `test/amqp/fuzz_test.exs` dominates (5 of the top 10 slots, ~1.5s combined),
then crash-isolation chaos and the DETS store mirror tests. The whole suite is fast;
per-suite wall is bounded by the 1.9-2.1s async batch, so no single suite gates the run.

## ST17 verdict (2026-10-14, later same day): both ST16 flaky classes fixed

Subject: same checkout. Owned files: `test/telemetry_test.exs`, `test/kv_tls_test.exs`,
`lib/smalt/telemetry.ex`.

**Root causes and fixes**

- `Smalt.TelemetryTest` "counters increment and dump/0" (`expected 2 got 3`): NOT a
  counter leak across suites or a double-attach — the shared RollingCounters ETS table is
  cumulative over the app lifetime, and a sibling test in the same module
  (`per_minute/0 keys counters by {minute, key}`) emits a bare `Telemetry.admit(:ok)`
  that lands on the same `{[:smalt, :admit], %{event: :ok}}` key under ExUnit's random
  in-module ordering. Fixed test-side only: both counter tests now assert deltas over a
  pre-test `Telemetry.dump()` baseline instead of absolute counts. `Smalt.Telemetry.attach/0`
  was already de-duplicated by `:telemetry.attach_many`'s all-or-nothing `:already_exists`
  behavior; it now matches on the return explicitly (`lib/smalt/telemetry.ex`) so a
  duplicate boot-path attach can never double-count.
- `KvTlsTest` (run-2 cluster: HTTP 500 + `MatchError` nil): the module reused ONE long-lived
  private twin listener across all tests (setup_all), racing concurrent suites that
  stop/restore the shared app tree; an empty twin response then hit a bare match in
  `parse_response/1` (`MatchError` nil). Fixed test-side only: per-test dedicated Bandit
  listener on a freshly probed port (`boot_twin/1` retries up to 10 fresh-port probes on
  bind collision, never reuses the failed listener's port on heal), wait-for-ready loop,
  `restart_twin/1` re-probes a fresh port on heal, `parse_response/1` raises a typed
  "twin returned no HTTP response" error on empty bodies, and every status assertion now
  pins the twin's response body in the message so a future 500 shows its root body.
  Release/list/subscriptions requests retry 5xx with both first/final bodies on flunk.

**Gate receipt**

- 5 consecutive `MIX_ENV=test mix test test/telemetry_test.exs test/kv_tls_test.exs`:
  `17 tests, 0 failures` x5 (run1-5, all green, back-to-back).
- Full `MIX_ENV=test mix test` (3 runs): 756 tests; failures 19 / 17 / 16 across the three
  runs; `TelemetryTest` and `KvTlsTest` appear in ZERO of them (grep receipt: 0 matches in
  failure lists). Both ST16 flaky classes absent.
- Remaining failures are OTHER lanes' surfaces, NOT in this lane's register; honest census
  from the last full run (16): the 10 EXPECTED-IN-FLIGHT AMQP rows (6 SasVerifierTest +
  4 CbsRouterTest, `INVALID_LOCAL_SAS`) PLUS in-flight churn from concurrently-landing
  lanes — `Smalt.Amqp.FuzzTest` (2), `Smalt.Amqp.FrameCodecTest` (1, intermittent: absent
  in one full run, present in others), `Smalt.DataPlane.BlobHardeningTest` (3). These vary
  between full runs (19/17/16) and belong to the AMQP/data-plane lanes landing on the same
  tree; not classified here.

## ST16 v2 — 3× back-to-back `MIX_ENV=test mix test` (2026-10-14)

Subject: ~/smalt, shared canonical checkout with lanes landing mid-batch
(test count moved 948 → 958 between run 2 and run 3 — a concurrent lane added ~10 tests;
`docs/ERROR_CODES.md`-family breakage confirms auth-lane churn in flight). Logs:
`tmp/stability2/run{1,2,3}.full.log` + `run4.trace.log` + `run{1,2}.fails.txt`.

### Per-run counts

| run | tests | failures | passes | ExUnit wall | cmd wall |
|---|---|---|---|---|---|
| 1 | 948 | 16 | 932 | 8.0s | 10s |
| 2 | 948 | 18 | 930 | 8.4s | 10s |
| 3 | 958 | 39 | 919 | 39.9s | 41s |
| 4 (--trace, timing pass) | 958 | 32 | 926 | 8.5s | 10s |
| 3a (discarded, contaminated) | 958 | 77 | 881 | 100.2s | 103s |

Run 3a is retained as drift evidence, not counted: the tree changed under it
(recompile at start, CosmosTest 22F / KeyVaultActionsTest 9F / PPlanTest 7F /
EventGridConformanceTest 5F — churn families from lanes landing mid-run).
Mean wall over counted runs: (10+10+41)/3 = 20.3s (run 3's 41s is concurrent-lane
compile contention; ExUnit-internal mean is ~8.3s when the tree is quiet).

### Stable core failure set (16 — present in ALL 3 counted runs, 16/16 in run 3)

**EXPECTED-IN-FLIGHT (10, unchanged from v1):** 6× `Smalt.Amqp.SasVerifierTest` +
4× `Smalt.Amqp.CbsRouterTest`, root error `INVALID_LOCAL_SAS` — identical set and
signatures to the v1 register.

**REAL-BUG / stale-projection (6, NEW since v1, deterministic — same failure every run):**

- `Smalt.ErrorCodesDocTest` (2) — `docs/ERROR_CODES.md` is stale vs the generators;
  fix is `python3 scripts/gen_error_codes.py`, then the egress-rows coverage test.
- `Smalt.MetadataEndpointsTest` (2) — advertised token_endpoint
  `/organizations/oauth2/v2.0/token` returns 400 over the wire (metadata advertises an
  endpoint the substrate refuses).
- `Smalt.SemanticEpochTest` "timeline/0 ... digest drift" — `pack_name` nil vs
  "smalt-substrate-pack" (receipt-timeline vs locked pack digest drift).
- `Smalt.Wire.ArmWireTest` "POST /oauth2/v2.0/token issues a bearer token over the wire"
  — 400 vs 200. Same token-endpoint family as MetadataEndpointsTest.

### Flake register (diff of failure sets across runs)

- `Smalt.AdmissionProjectionTest` "verdict counter-aggregation matches Telemetry.dump()
  where overlapping" — run 2 only (left 2, right 3). Telemetry RollingCounters cross-suite
  pollution, same family as the ST16/ST17 TelemetryTest flake; not seen in runs 1/3/4.
- `Smalt.Amqp.FuzzTest` "5000 unique long symbol ... mint no new atoms" — run 2 only
  (atom-table cross-run accounting), passed runs 1/3/4.

### Classification receipt

- Core 16: zero pass variance, same signature each run → deterministic, not flakes.
- The v1 12-16-failure band is now: a stable 16-failure floor (10 in-flight + 6 real),
  plus a churn band above it (16 → 39 → 77) that tracks concurrent lanes landing on the
  shared checkout — the churn is environmental, not suite instability.
- vs v1/ST17 (756 tests, 19/17/16 failures, 10 in-flight): test count +202
  (~30 new suites: compliance, integration I-family, ocel, mcp, pplan, trust-profile),
  in-flight floor unchanged at 10; +6 new deterministic failures, both ST16 flaky classes
  (TelemetryTest, KvTlsTest) still fixed (0 matches in any run).
- All top-10 slowest tests pass; timings from run 4 (--trace).

### Slowest 10 tests (--trace, run 4)

| ms | test | suite |
|---|---|---|
| 1034 | store crash is contained: store restarts, listeners never go down | test/chaos/crash_isolation_test.exs |
| 805 | frame-split invariance: incremental feed at every offset matches unsplit | test/amqp/fuzz_test.exs |
| 606 | transfer-payload round-trip: encode_message -> decode_message (100 seeds) | test/amqp/fuzz_test.exs |
| 488 | enqueue/3 rejects the 4097th message with :capacity | test/amqp/queue_store_test.exs |
| 290 | concurrency (ST4 court) 200-racer dequeue: 1000 messages | test/amqp/queue_store_test.exs |
| 223 | a conformance-false deviation appears as an evidence record through Ash | test/ocel_revops_test.exs |
| 154 | mirror captures writes within interval + epsilon | test/store_dets_test.exs |
| 150 | round-trip: encode -> decode_all reproduces the term (100 seeds x 200 terms) | test/amqp/fuzz_test.exs |
| 121 | verifier refuses a resource with a non-read action | test/ash_extension_test.exs |
| 121 | Key Vault: release with valid CVM attestation returns released key material | test/wire/egress_wire_test.exs |

Hot spots: AMQP fuzz + queue-store dominate (5 of top 6, ~3.2s combined);
chaos crash-isolation is the single slowest test at ~1.03s (unchanged from v1).
