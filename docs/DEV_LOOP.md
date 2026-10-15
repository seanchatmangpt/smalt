# Dev Inner Loop

How to iterate on smalt without paying full-suite cost on every save.
Numbers measured 2026-10-14 on this checkout (Elixir 1.19.5 / OTP 28, warm shared `_build`);
full-suite row refreshed 2026-10-15 (suite has grown since the 10-14 measurement).

## Scripts

- `scripts/fast_test.sh <test_file[:line]> [--watch] [--] [extra mix test args]`
- `scripts/dev_watch.sh [--once]`

## Timing receipts (real runs, 2026-10-14)

| surface | wall | result |
|---|---|---|
| full `mix test` (3 runs, 2026-10-14) | 8.0s / 8.0s / 7.0s | 1 doctest, 791 tests, 30-32 failures (19 excluded) — failures pre-existing, not introduced by this lane |
| full `mix test` (2026-10-15 refresh) | 40.8s | 1 doctest, 1143 tests, 26 failures (21 excluded) — failures pre-existing (suite grew 791→1143 tests; wall grew with it) |
| full `mix test` (2026-10-15 refresh 2) | 51.0s | 1 doctest, 1311 tests, 20 failures (22 excluded) — suite grew 1143→1311; failures: 3 EventHubs CAS, 8 Key Vault release-policy drift (`{"any":"policy"}` now 400 `InvalidParameter`, keys never stored -> release 404s), 4 lens-2 audit-plane ordering, 4 oauth/openid + 1 mcp-doctor wire probes (concurrent-lane port contention) — all cross-lane in-flight, none docs-corpus |
| full `mix test` (2026-10-15 refresh 3, cycle-10) | — | attempt-5 completed: **1 doctest, 1510 tests, 21 failures** (22 excluded); suite grew 1311→1510; two earlier attempts were compile-aborts from concurrent lanes' mid-edits (graphlaw validator test, apiversion_matrix — both owner-fixed within the SLA window). Failures: 4 mcp lens-3 fuzz, 5 security JCS/Receipts lens-3, 4 pplan fuzz claim-races (`claim/2` FunctionClauseError on tuple claimant `{:racer, n}` — pplan lane owner), 2 session-token typed-GAP pins, 1 chaos port fence, 1 kv_tls twin-dispatch, 1 auth lens-4 fuzz, 1 error_codes fence (regenerated, `--check` rc=0). All lens-wave in-flight at capture; KV + STS clusters from refresh 2 are RESOLVED (egress_wire+wiring 18/0, metadata_endpoints+arm_wire 14/0) |
| full `mix test` (2026-10-15 refresh 4, cycle-11) | 57.9s | **1 doctest, 1529 tests, 8 failures** (22 excluded); suite grew 1510→1529; all lens clusters from refresh 3 dissolved (pplan claim-race fuzz, mcp/security JCS lens-3, kv_tls, session-token now green standalone: pplan+security+mcp+wire 170/0, arm+auth+dispatch+eventgrid 177/0). Remaining 8 classified: 2 port-contention-class (chaos port fence, mcp doctor-summary), 1 error_codes fence regen timing (regen'd, `--check` rc=0), 5 standalone-green concurrency flakes (arm nextLink, 2 session-token GAP pins, auth crit/b64 fence, egress dispatch typed errors — each green in its own file run) |
| full `mix test` (2026-10-15 refresh 5, docs-corpus-lens2 cycle 1) | — | NOT re-run full-suite this cycle (lane suite windows instead; shared checkout mid-landing). Settled-tree reconciliation of the refresh-4 flakes, by suite: arm_wire+arm_gateway+egress_wire+security_hardening **96/0** (arm nextLink, egress dispatch typed errors, security fences all green); auth_enforce **94/0** on settled re-run — first re-run 51/94 under a concurrent-lane compile window, clean immediately after (port/env contention class, not a docs defect); the 2 session-token GAP pins are now REAL failures — cosmos continuation landed after refresh 4 and the pins still assert the old no-continuation behavior (cosmos lane owner, stale-test class). New landed facts documented this cycle: cosmos `x-ms-continuation`, blob container grammar/409/`maxresults` fences, ledger receipt `typ` fence (all code-read + suite-run before writing) |
| full `mix test` (2026-10-15 refresh 6, docs-corpus-lens3 cycle 2) | — | NOT re-run full-suite (lane suite windows on a shared checkout mid-landing). Courts c1..c7 re-run: one compile-abort window (~10:31, `connection.ex`, foreign lane, cleared in-SLA), one router mid-edit window (10:35, c1 answered 404s on 18 rows; router.ex sha `9528aeee…` settled 10:40) — after the window: c1 25/0, c2 16/0, c3 23/0, c4 28/0, c5 16/0 (`--include amqp_wire`), c6 18/0, c7 16/0 = **142/0**, counts refreshed in RELEASE_NOTES + CHANGELOG; plus 111/0 (c4+c1+security_hardening, 10:28). New landed facts documented this cycle: blob conditional reads (RFC 7232, 304 shape), blob delimiter BlobPrefix listing, ARM subscription presence gates, and `docs/XAAS_PRIOR_ART.md` (xaas transfer plan) |
| full `mix test` (2026-10-15 refresh 6, test-corpus-b-lens2 cycle 1) | — | corpus-B waves only (shared checkout mid-landing): 975/4 → 985/3 (reversed order) → 1001/9 → 1017/4; every wave-3/4 failure green solo (cross-file shared-Store/ETS contention class); corpus-owned test repairs: mcp plain-id stale assert, auth lens6 seeded-mutation collisions (2), fuzz map-decode retimed to paired-round min-of-5, descriptor-slot sweep bodies+classification, blob xmerl `{:ok,_}` miswire (SLA unblock, disclosed). F-21 padded-signature accept RESOLVED by auth-lane ruling; F-22 sentinel ETS table-creation race OPEN (sentinel.ex:91); F-23 blob listed-vs-stored courts cannot xmerl-parse non-ASCII names OPEN; F-19 semantic-projection order-dependence re-witnessed (2nd). Mutation probes 3/3 non-vacuous (cosmos continuation forged-check, auth crit fence, blob If-Match). Receipt: tmp/errc/test-corpus-b-lens2/cycle-1.md |
| `fast_test` first run on a new target file | 51-62s | one-time cold compile of the isolated build root |
| `fast_test` warm single file | 1-2s | 37 tests, 0 failures |
| `fast_test file:line` (warm) | 1-2s | 1 test, 0 failures (36 excluded) |
| graphlaw subset, `dev_watch.sh --once` | <1s test time | 59 tests, 1 failure — pre-existing ETS failure in `SmaltServicesTest` "Confidential Ledger Merkle Tree..." (`test/smalt_services_test.exs:231`) |

The one-time 50-60s is `MIX_BUILD_ROOT=_build-ft-<hash-of-file>` compiling deps+app from
scratch. It is a per-target one-time cost; every later run on the same target is 1-2s.
Trade-off: per-invocation build-root isolation buys parallel-invocation safety (two
`fast_test` invocations ran concurrently on different targets with no `_build` race,
both green) at the price of a cold compile per target file. If that cold cost is
unacceptable, set `FAST_TEST_BUILD_ROOT=_build-ft-shared` to share one warm isolated
root across targets, or `_build` to share the main root (accepting the race).

Env knobs: `FAST_TEST_BUILD_ROOT`, `DEV_WATCH_BUILD_ROOT`.

## Status-flip discipline (receipt-file-gated)

A status flip (PENDING -> CLOSED, BLOCKED -> resolved, "X landed/green" in
any doc row or receipt) is admitted only when the cited receipt file exists
on disk: `test -f <receipt-path>` before the flip is written. Prose in
`tmp/errc/coordinator-unblocks.md` is not a receipt; a status named without
a file on disk is known-O, not O*. Receipt paths follow the lane pattern
`tmp/errc/<lane>/cycle-N.md`. Related: `docs/XAAS_PRIOR_ART.md` G4/G5
(adopt-now docs discipline, from the xaas governance surveys).

## Private port allocation

Local harnesses must not contend the front-door ports (5672/9443/8443/9444) or
each other. The canonical private range is **39000-39999**. One allocation per
harness; do not publish fixed private ports outside this table (published
blocks get adopted by siblings and re-collide — witnessed 2026-10-15, the
15672/19443 block).

| allocation | ports | harness | env overrides |
|---|---|---|---|
| mutation court ARM | 39443 | `scripts/mutation_court.py` | `SMALT_BENCH_ARM_PORT` |
| eh-run SDK smoke | 39172, 39173, 39444-39446 | `test/sdk-smoke/eh-run.mjs` | `SMALT_EH_*_PORT` |
| census private block | 39071, 39072 | `test/sdk-smoke/census-run.mjs` | `SMALT_TEST_AMQP_PORT` / `SMALT_TEST_ARM_PORT` |
| bench / court auto-scope | ephemeral (OS-assigned) | `scripts/bench.py`, `scripts/mutation_court.py` | n/a — recorded in run receipt |
| ARM-scale stress | 39453-39457 (arm/tls/egress/amqp/event-hubs) | `scripts/stress/arm_scale.py` | `SMALT_ARMSCALE_*_PORT` |
| TLS-churn client | attaches to 39453 (http) / 39454 (tls) | `scripts/stress/tls_churn.py` | `SMALT_TLS_PORT` / `SMALT_HTTP_PORT` |
| vs-azurite bench | 39463-39464 (arm/tls twins); egress fallback 39455 | `scripts/stress/vs_azurite.py` | `SMALT_VSAZ_*_PORT` |
| gate-cost probe | 39468-39471 | `scripts/stress/gate_cost.py` | `SMALT_GATECOST_*_PORT` |
| ycsb-lite | 39472-39475 | `scripts/stress/ycsb_lite.py` | `YCSB_*_PORT` |

Rules: front door is fail-closed — a harness that finds its port held exits
with a typed remediation (wait, or take the documented private override);
it never kills the holder. Auto-scoping harnesses pick ephemeral or
table-listed private ports and record the chosen ports in their receipt.

1. **Iterating on one test**: `scripts/fast_test.sh test/foo_test.exs:42 --watch`.
   Re-runs the focused test whenever `lib/**/*.ex` or the test file changes (1s poll,
   clear screen + timestamp, ~1-2s per warm run). First run may pay the ~1min cold
   build-root compile.
2. **Subsystem sweeps**: `scripts/dev_watch.sh` watches `lib/smalt/graphlaw/**` and re-runs
   the graphlaw suites (`test/smalt_graphlaw_validator_test.exs`,
   `test/smalt_services_test.exs`, `test/arm_error_corpus_test.exs` — 59 tests, <1s).
   **Generalizing**: copy the script, set `WATCH_PATHS=(lib/smalt/<subsystem>)` and
   `SUITES=(test/<subsystem>_test.exs ...)`; the mtime-snapshot/poll/re-run pattern is
   identical to `fast_test --watch`, just over multiple paths and suites. `--once` runs
   the subset a single time (used for all measurements above).
3. **Before push**: full `mix test` (~41s as of 2026-10-15 — cheap enough to run every time you
   think you're done, not just before push).
4. **Pre-PR**: `just court` (doctor + test-offline + test-wire + test-sdk-smoke +
   tf-plan-smoke + bench-check, per `Justfile:149`).

## Elixir 1.19 focus patterns

`mix test test/foo_test.exs:42` runs the single test whose `test` block starts at line 42
(works with `fast_test.sh` since the arg is passed straight through). Note `mix test
file:line` reports excluded siblings as `(N excluded)` — that is the line filter, not a
tag skip. `--only tag:value` / `--exclude` compose with file args for tier focus; the
default-excluded tiers are named in `test/test_helper.exs` (re-enable per run with
`--include <tag>`). Because the full suite is only ~8s, prefer full `mix test` over
`--only` gymnastics unless a single tier needs a cold build.

## Known state (pre-existing, observed during measurement)

- Full suite: 26 failures (2026-10-15; was 30-32 on 2026-10-14, count varies run to run)
  — pre-existing on this checkout; not touched by this lane.
- `test/smalt_services_test.exs:231` ETS-table failure also fires in the graphlaw subset.
- During measurement a compile-abort in `test/error_codes_doc_test.exs` (invalid syntax
  `test "..." well_formed: true do`) blocked the full suite; it was fixed on disk by
  another lane mid-measurement (compile-freeze SLA) and the 3x baseline above was taken
  after that fix. This lane made no edits outside its owned files.
