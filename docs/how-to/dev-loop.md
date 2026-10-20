# dev loop

How to iterate on smalt without paying full-suite cost on every save.
Numbers measured 2026-10-14 on this checkout (Elixir 1.19.5 / OTP 28, warm shared `_build`);
full-suite rows refreshed 2026-10-15/16 (the suite has grown since the 10-14 measurement).
**Post-reset (v26.10.19, 64f6099)**: the legacy `test/` corpus (303 files) is
deleted; the residual tier is `test/internal/` and the wire contract moved to
`verification/ts/` + `verification/py/` (`verification/README.md` is the
verification contract of record). Timing rows below are pre-reset history.
`just sdk-ts` / `just sdk-py` are still LOUD no-op placeholders (exit 1,
`justfile.d/04-sdk-recipes.just`) pending V261019-08/09 repoint.
Diátaxis home: `docs/how-to/dev-loop.md` (moved from `docs/DEV_LOOP.md`;
see `docs/jira/v26.10.16/docs-restructure-plan.md`).

## The loop

The default iteration path is just-first; the script-level fallbacks below
are the same gates with their handles exposed.

1. `just doctor` — preflight (deps/ports/certs/toolchain, ~2s). Run first;
   it is also the first stage of every court.
2. Edit `lib/` or `test/internal/`.
3. Focused gate:
   - Enclave work: `just test-native` (native lifecycle: HCL parse →
     engine apply → zero-drift plan → cascade destroy → residue audit,
     on private ports 29445-29450, dedicated beam, shared-checkout safe).
   - Other work: `scripts/fast_test.sh <file[:line]>` or a targeted
     `mix test test/internal/<file>` (timing table below).
4. `mix test` — full offline suite (residual tier `test/internal/` only
   post-reset) before you think you're done.
5. Enclave provisioning loop: `just apply` (fixture → state JSON) →
   `just verify` (read-your-write parity audit; SKIP-LOUD exit 3 without
   applied state) → `just destroy` (cascade + residue, fails on residue).
   Both `apply` and `destroy` default to `tier=native`; `tier=wire` is an
   explicit opt-in to the external terraform cleanroom and is refused with
   `TIER-WIRE-UNAVAILABLE` unless the trusted-machine gate reports PASS.
6. `just court` before push/PR.

## Scripts

- `scripts/fast_test.sh <test_file[:line]> [--watch] [--] [extra mix test args]`
- `scripts/dev_watch.sh [--once]`

## Timing receipts (real runs, 2026-10-14)

Pre-reset history (the legacy 1500+-test suite was deleted at 64f6099;
the residual `test/internal/` tier is 5 suites — count them with
`mix test` on your own run). Kept for measurement method only.

| surface | wall | result |
|---|---|---|
| full `mix test` (3 runs, 2026-10-14) | 8.0s / 8.0s / 7.0s | 1 doctest, 791 tests, 30-32 failures (19 excluded) — failures pre-existing, not introduced by this lane |
| full `mix test` (2026-10-15 refresh) | 40.8s | 1 doctest, 1143 tests, 26 failures (21 excluded) — failures pre-existing (suite grew 791→1143 tests; wall grew with it) |
| full `mix test` (2026-10-15 refresh 2) | 51.0s | 1 doctest, 1311 tests, 20 failures (22 excluded) — suite grew 1143→1311; failures: 3 EventHubs CAS, 8 Key Vault release-policy drift (`{"any":"policy"}` now 400 `InvalidParameter`, keys never stored -> release 404s), 4 lens-2 audit-plane ordering, 4 oauth/openid + 1 mcp-doctor wire probes (concurrent-lane port contention) — all cross-lane in-flight, none docs-corpus |
| full `mix test` (2026-10-15 refresh 3, cycle-10) | — | attempt-5 completed: **1 doctest, 1510 tests, 21 failures** (22 excluded); suite grew 1311→1510; two earlier attempts were compile-aborts from concurrent lanes' mid-edits (graphlaw validator test, apiversion_matrix — both owner-fixed within the SLA window). Failures: 4 mcp lens-3 fuzz, 5 security JCS/Receipts lens-3, 4 pplan fuzz claim-races (`claim/2` FunctionClauseError on tuple claimant `{:racer, n}` — pplan lane owner), 2 session-token typed-GAP pins, 1 chaos port fence, 1 kv_tls twin-dispatch, 1 auth lens-4 fuzz, 1 error_codes fence (regenerated, `--check` rc=0). All lens-wave in-flight at capture; KV + STS clusters from refresh 2 are RESOLVED (egress_wire+wiring 18/0, metadata_endpoints+arm_wire 14/0) |
| full `mix test` (2026-10-15 refresh 4, cycle-11) | 57.9s | **1 doctest, 1529 tests, 8 failures** (22 excluded); suite grew 1510→1529; all lens clusters from refresh 3 dissolved (pplan claim-race fuzz, mcp/security JCS lens-3, kv_tls, session-token now green standalone: pplan+security+mcp+wire 170/0, arm+auth+dispatch+eventgrid 177/0). Remaining 8 classified: 2 port-contention-class (chaos port fence, mcp doctor-summary), 1 error_codes fence regen timing (regen'd, `--check` rc=0), 5 standalone-green concurrency flakes (arm nextLink, 2 session-token GAP pins, auth crit/b64 fence, egress dispatch typed errors — each green in its own file run) |
| full `mix test` (2026-10-15 refresh 5, docs-corpus-lens2 cycle 1) | — | NOT re-run full-suite this cycle (lane suite windows instead; shared checkout mid-landing). Settled-tree reconciliation of the refresh-4 flakes, by suite: arm_wire+arm_gateway+egress_wire+security_hardening **96/0** (arm nextLink, egress dispatch typed errors, security fences all green); auth_enforce **94/0** on settled re-run — first re-run 51/94 under a concurrent-lane compile window, clean immediately after (port/env contention class, not a docs defect); the 2 session-token GAP pins are now REAL failures — cosmos continuation landed after refresh 4 and the pins still assert the old no-continuation behavior (cosmos lane owner, stale-test class). New landed facts documented this cycle: cosmos `x-ms-continuation`, blob container grammar/409/`maxresults` fences, ledger receipt `typ` fence (all code-read + suite-run before writing) |
| full `mix test` (2026-10-15 refresh 6, docs-corpus-lens3 cycle 2) | — | NOT re-run full-suite (lane suite windows on a shared checkout mid-landing). Courts c1..c7 re-run: one compile-abort window (~10:31, `connection.ex`, foreign lane, cleared in-SLA), one router mid-edit window (10:35, c1 answered 404s on 18 rows; router.ex sha `9528aeee…` settled 10:40) — after the window: c1 25/0, c2 16/0, c3 23/0, c4 28/0, c5 16/0 (`--include amqp_wire`), c6 18/0, c7 16/0 = **142/0**, counts refreshed in RELEASE_NOTES + CHANGELOG; plus 111/0 (c4+c1+security_hardening, 10:28). New landed facts documented this cycle: blob conditional reads (RFC 7232, 304 shape), blob delimiter BlobPrefix listing, ARM subscription presence gates, and `docs/XAAS_PRIOR_ART.md` (xaas transfer plan) |
| full `mix test` (2026-10-15 refresh 7, docs-corpus-lens4 cycle 5) | — | NOT re-run full-suite (courts + targeted suites on a shared checkout mid-landing). Courts c1..c7 re-run settled: c1 25/0, c2 16/0, c3 **26**/0 (+3 cosmos), c4 **29**/0 (+1 slash-named blob round-trip), c5 16/0 (`--include amqp_wire`), c6 18/0, c7 16/0 = **146/0** — counts refreshed in RELEASE_NOTES + CHANGELOG (was 142/0). Targeted: c4+lens5 33/0; store_churn+audit_planes 83/0; tls+metadata_endpoints 16/0 settled (16/2 -> 16/0 same hour); cosmos+semantic_projection 110/2 mid-window (cosmos.ex mtime 4s old — foreign; both failures green in c3's own 26/0 run minutes later). Docs landed this cycle-pair: include=metadata + Container PUT 201 header shape (stale "container PUT lacks ETag/Last-Modified" gap claim DELETED), ledger crash-class totality, GAP(name) tokens in TEST_ISOLATION, DEV_LOOP status-flip discipline, ARCHITECTURE/README false-CAS repair, NAMING_SWEEP re-verification addendum, 7 line-pin drift repairs |
| full `mix test` (2026-10-15 refresh 6, test-corpus-b-lens2 cycle 1) | — | corpus-B waves only (shared checkout mid-landing): 975/4 → 985/3 (reversed order) → 1001/9 → 1017/4; every wave-3/4 failure green solo (cross-file shared-Store/ETS contention class); corpus-owned test repairs: mcp plain-id stale assert, auth lens6 seeded-mutation collisions (2), fuzz map-decode retimed to paired-round min-of-5, descriptor-slot sweep bodies+classification, blob xmerl `{:ok,_}` miswire (SLA unblock, disclosed). F-21 padded-signature accept RESOLVED by auth-lane ruling; F-22 sentinel ETS table-creation race OPEN (sentinel.ex:91); F-23 blob listed-vs-stored courts cannot xmerl-parse non-ASCII names OPEN; F-19 semantic-projection order-dependence re-witnessed (2nd). Mutation probes 3/3 non-vacuous (cosmos continuation forged-check, auth crit fence, blob If-Match). Receipt: tmp/errc/test-corpus-b-lens2/cycle-1.md |
| full `mix test` (2026-10-15 refresh 8, docs-corpus-lens6 cycle 5) | — | NOT re-run full-suite (courts + targeted suites on a shared checkout mid-landing). Courts c1..c7 re-run settled: c1 26/0, c2 16/0, c3 28/0 (+2), c4 36/0 (+7), c5 16/0 (`--include amqp_wire`), c6 18/0, c7 16/0 = **156/0** — counts refreshed in RELEASE_NOTES + CHANGELOG (was 147/0). Targeted: blob_hardening+egress_wire 91/0; codec gate 34/0 (lens-7 decode-mirror failure window REPORTED + resolved by codec lane); semantic_projection 18/0 + arm_gateway canary 26/0 (SEMANTIC_PROJECTION receipt refreshed). Docs landed this lens: WIRE_PARITY codec encode-guard + blob splat + ledger/cosmos GAP flips, PUBLISH_CHECK blockers 2+3 CLEARED, TEST_ISOLATION 25-file inventory, NAMING_SWEEP 2 CONFIRMED-FIXED flips, ERROR_SWEEP chaos_kill re-pins, SEMANTIC_PROJECTION counts |
| full `mix test` (2026-10-15 refresh 9, docs-corpus-lens7 cycle 3) | — | NOT re-run full-suite (courts + targeted suites on a shared checkout mid-landing). Courts c1..c7 re-run settled: c1 26/0, c2 16/0, c3 28/0, c4 **42**/0 (+6), c5 16/0 (`--include amqp_wire`), c6 18/0, c7 **17**/0 (+1) = **163/0** — counts refreshed in RELEASE_NOTES + CHANGELOG (was 156/0). Targeted: lens6_fuzz + lro_test 27/0 (tee-admit + LRO Failed-terminal adoption evidence); semantic_projection 21/0 (+3) + arm_gateway canary 26/0 (SEMANTIC_PROJECTION receipt refreshed); hex build court: `mix hex.build` rc=0, checksum `284efbdf…`, still carries the 5 key paths (PUBLISH_CHECK blocker 1 STANDS, corroborated). Docs landed this lens: WIRE_PARITY SKR tee-admit/claim_value + ARM Failed-terminal rows, blob splat into CHANGELOG, c4/egress pin re-derivation, ERROR_SWEEP chaos_kill/soak/gates re-pins, XAAS_PRIOR_ART G1 witness, SEMANTIC_PROJECTION counts |
| full `mix test` (2026-10-15 refresh 10, docs-corpus-lens8 cycle 2) | — | NOT re-run full-suite (courts on a shared checkout mid-landing). Courts c1..c7 re-run settled (MIX_BUILD_ROOT=_build-docs8): c1 26/0, c2 16/0, c3 28/0, c4 **46**/0 (+4 blob-lane fences), c5 16/0 (`--include amqp_wire`), c6 18/0, c7 17/0 = **167/0** — counts refreshed in RELEASE_NOTES + CHANGELOG (was 163/0). error_codes fence: stale on arrival (foreign c4_blob.exs drift 1219->1223), regenerated, `--check` rc=0. Hex build court re-derived: `mix hex.build` rc=0, checksum `71461bd6…`, 5 leak paths still in the inner contents.tar.gz (PUBLISH_CHECK blocker 1 STANDS; outer-tar grep reads 0 — grep the INNER contents listing, not the outer). Docs landed this lens: 7 WIRE_PARITY pin re-derivations, 17 ERROR_SWEEP pin re-derivations, NAMING_SWEEP 7-row CONFIRMED-FIXED flips + eh-run:143/stress re-pins + count refresh, DEV_LOOP lane build-root lease note (37 orphaned `_build-*` dirs), PUBLISH_CHECK lens-8 corroboration |
| native lifecycle ladder (2026-10-16, lane 409) | **73ms-class** | parse 3 / apply 52 / plan 2 / synthesize 1 / destroy 15 / residue 0 ms (`TIMINGS_MS`, receipt `docs/jira/v26.10.16/sdk-results/native-lifecycle.md`); `just test-native` gate 1 test 0 failures on the same run |
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

## Substrate boot budget (typed, 2026-10-15)

`bench.py` CTQ 2 (spawn -> TCP accept) measures a quantity with TWO regimes,
and the budget names one of them:

- **Quiet-tree regime** — no sibling holds the mix build lock. Measured
  distributions (n=5 each, `scripts/bench.py` receipts):
  12:25 receipt `[0.774, 1.831, 1.844, 2.14, 2.553]` (p95 2.553s), and
  lens-5 14:1x probe `[1.539, 1.549, 1.66, 1.688, 1.858]` — p95 1.858s
  (receipt
  `tmp/errc/dx-scripts-lens5/cycle-3.md`). Quiet-tree p95 is stable at
  **<= 2.6s across both windows** — the 5.0s budget holds with ~2x headroom.
- **Contention regime** — a sibling lane holds the build lock; the boot
  eats lock wait, not substrate work. Witnessed same-day: `[3.379, 4.545,
  5.693, 9.573, 10.822]`, p95 10.822s (receipt
  `tmp/errc/dx-scripts-lens5/bench-receipt-run1-contented.json`). Ceiling
  witnessed ~11s under multi-lane churn; record, don't budget.

**Contract**: the 5.0s boot budget is a quiet-tree budget. A boot FAIL is
admitted only if a quiet re-run (no sibling build activity) also exceeds
5.0s; a FAIL that clears on a quiet re-run is the contention regime, typed
as such in the receipt/log, not a subject regression. Never raise the budget
to absorb lock wait — that trades a real quiet-tree signal for silence.

## Lane build-root leases (integration-cleanup items, 2026-10-15 docs-corpus-lens-8)

Per the same-checkout fan-out cleanup law, `MIX_BUILD_ROOT=_build-lane*`
directories are leases, not assets: the coordinator deletes every lane build
root at integration, BEFORE the final commit. As of lens-8 the tree carries
**272 `_build-lane*` dirs / 281 `_build-*` dirs total** in the tree root at
last count (2026-10-16); retired families `_build-l4..l8`/misc are gone —
current families are `_build-ft-*` (per-hash fast_test roots), `_build-r133-fresh`,
`_build-w6docs`. These are coordinator-owned integration
cleanup (a docs lane does not delete build roots); each surviving root should
be either deleted or re-leased by its owner at the next integration. A fan-out
whose integration commit leaves new `_build-*` dirs behind is an incomplete
integration.

## Status-flip discipline (receipt-file-gated)

A status flip (PENDING -> CLOSED, BLOCKED -> resolved, "X landed/green" in
any doc row or receipt) is admitted only when the cited receipt file exists
on disk: `test -f <receipt-path>` before the flip is written. Prose in
`tmp/errc/coordinator-unblocks.md` is not a receipt; a status named without
a file on disk is known-O, not O*. Receipt paths follow the lane pattern
`tmp/errc/<lane>/cycle-N.md`. Related: `docs/XAAS_PRIOR_ART.md` G4/G5
(adopt-now docs discipline, from the xaas governance surveys).

## Private port allocation (v-law, post-reset)

Local harnesses must not contend the front-door ports (5672/9443/8443/9444)
or each other. Post-reset port law (`scripts/bench/REGISTRY.md` v-law,
v26.10.19): verification-surface lanes take **vN blocks: `39700 + 10N .. +5`**
(v1 39710..39715, v2 39720..39725, ...); spare block `39826..39839` is
reserved for ad hoc probes. Lane blocks are leased through
`scripts/substrate-ctl` (`up --block v<N>`) — `scripts/lib/substrate_boot_registry.md`
documents the fd-9 lock law, marker/identity guard, and the exit contract
(0 up / 1 refused / 2 died-or-timeout / 3 lock-or-occupied / 64 usage).
The a/n bench lane families and b42 are RETIRED (v26.10.19); b2-b6 lanes
are DORMANT pending V261019-08/09. Do not publish fixed private ports
outside the formula blocks (published blocks get adopted by siblings and
re-collide — witnessed 2026-10-15, the 15672/19443 block).

Residual table (harnesses still on disk; each verified `ls`-present
2026-10-19):

| allocation | ports | harness | env overrides |
|---|---|---|---|
| mutation court ARM | 39443 | `scripts/mutation_court.py` | `SMALT_BENCH_ARM_PORT` |
| bench / court auto-scope | ephemeral (OS-assigned) | `scripts/bench.py`, `scripts/mutation_court.py` | n/a — recorded in run receipt |
| ARM-scale stress | 39453-39458 (six-listener block) | `scripts/stress/arm_scale.py` | `SMALT_ARMSCALE_*_PORT` |
| TLS-churn client | attaches to 39453 (http) / 39454 (tls) | `scripts/stress/tls_churn.py` | `SMALT_TLS_PORT` / `SMALT_HTTP_PORT` |
| soak | 39430-39435 (six-listener block) | `scripts/stress/soak.py` | edit PORTS dict (documented) |
| gate-cost probe | 39460-39465 (six-listener block) | `scripts/stress/gate_cost.py` | `SMALT_GATECOST_*_PORT` |
| ycsb-lite | 39472-39477 (six-listener block) | `scripts/stress/ycsb_lite.py` | `YCSB_*_PORT` |
| vs-azurite bench | 39500-39505 (six-listener block; main egress default 8443, private fallback 39502) | `scripts/stress/vs_azurite.py` | `SMALT_VSAZ_*_PORT` |
| connection spike | 39510-39515 (six-listener block) | `scripts/stress/spike.py` | `SMALT_SPIKE_*_PORT` |
| chaos kill | 39520-39525 (six-listener block) | `scripts/stress/chaos_kill.py` | `SMALT_CHAOS_*_PORT` |
| blob scale | 39530-39535 (six-listener block) | `scripts/stress/blob_scale.py` | `SMALT_BLOBSCALE_*_PORT` |
| bench-concurrent private overrides | 39540-39542 (tls/eh/mcp of the scoped branch; arm/egress/amqp via `SMALT_BENCH_{ARM,DATA,AMQP}_PORT`) | `scripts/bench_concurrent.py` | `SMALT_BENCH_*_PORT` |
| lro storm | ephemeral (six-port `free_port()` re-pick per boot) | `scripts/stress/lro_storm.py` | n/a |
| cosmos bulk | ephemeral (six-port re-pick per boot) | `scripts/stress/cosmos_bulk.py` | n/a |
| bounds probe | ephemeral (`gates/common.py`) | `scripts/stress/bounds.py` | n/a |

Rules: front door is fail-closed — a harness that finds its port held exits
with a typed remediation (wait, or take the documented private override);
it never kills the holder. Auto-scoping harnesses pick ephemeral or
table-listed private ports and record the chosen ports in their receipt.

1. **Iterating on one test**: `scripts/fast_test.sh
   test/internal/vm_zero_growth_test.exs:42 --watch`.
   Re-runs the focused test whenever `lib/**/*.ex` or the test file changes (1s poll,
   clear screen + timestamp, ~1-2s per warm run). First run may pay the ~1min cold
   build-root compile.
2. **Subsystem sweeps**: `scripts/dev_watch.sh` still exists, but its default
   watch targets are pre-reset suites — set `WATCH_PATHS`/`SUITES` explicitly
   (e.g. `SUITES=(test/internal/<subsystem>_test.exs ...)`); the
   mtime-snapshot/poll/re-run pattern is unchanged. `--once` runs the subset
   a single time.
3. **Before push**: full `mix test` (residual tier only post-reset; the
   58s-class pre-reset figures above are history, not the current wall).
4. **Pre-PR**: `just court` (doctor + test-offline + tf-plan-smoke + bench-check +
   mutation-court + census + invariant-gates + naming-sweep + verification-gates,
   per the root Justfile `court` recipe — note `census` is a RETIRED exit-1
   placeholder until the verification/ts census lands).

## Workspace / SDK / release tooling recipes

One-command entry points for the non-Elixir surfaces (recipes live in
`justfile.d/`; not part of `just court` — run them when working on their
surface):

| Command | Surface | Notes |
|---|---|---|
| `just ws-install` / `ws-build` / `ws-lint` | `workspace/` Next.js console | scaffold + build + lint (`npm`) |
| `just ws-court` / `ws-converge` | `workspace/scripts/e2e-court.mjs` | e2e court; `ws-converge` surfaces failing checks on FAIL |
| `just test-sdk-smoke` / `eh-smoke` / `census` | — | RETIRED (v26.10.19 reset, 64f6099): loud exit-1 placeholders; successors = `verification/ts` + `verification/py` (V261019-08/09) |
| `bash test/enclave-testbed/run.sh` | enclave stress testbed | exclusive substrate lock; exit 0 = all phases PASS; just recipe pending |
| `cd smalt-cli && .venv/bin/python run_gates.py` | smalt-cli 4-gate runner | LANDED: `just cli-gates` (`justfile.d/03-cli-wiring.just:34`) |
| `just publish-dry` | hex publish dry-run gate | inner-tar leak grep + ERROR_CODES regen identity |
| `just court-x2` | release receipt gate | full court twice; two consecutive greens required |
| `just docs-dod-check` | docs truth-sync | receipt/doc paths named in README/DEV_LOOP/CHANGELOG exist on disk |

## Elixir 1.19 focus patterns

`mix test test/internal/vm_zero_growth_test.exs:42` runs the single test whose
`test` block starts at line 42
(works with `fast_test.sh` since the arg is passed straight through). Note `mix test
file:line` reports excluded siblings as `(N excluded)` — that is the line filter, not a
tag skip. The post-reset `test/test_helper.exs` configures no default excludes
(legacy tag tiers went with the corpus); tier focus is by path now. The full suite is 40-60s-class and growing with the suite
(see the refresh rows above — the ~8s figure was the 2026-10-14 three-file-era
suite), so prefer full `mix test` over `--only` gymnastics unless a single tier
needs a cold build.

## Known state (pre-existing, observed during measurement)

- Full suite: pre-reset figures only (refresh-4 row above, 8/1529,
  2026-10-15). Post-reset the suite is the 5-suite `test/internal/` tier —
  measure it on your own run; the counted rows above do not describe it.
- The remaining pre-reset flakes (graphlaw ETS failure,
  `error_codes_doc_test` compile-abort) named files deleted at 64f6099 —
  history in git, no current referent.

## See Also

- `docs/JUST_REFERENCE.md` (full recipe surface + exit contracts)
- `docs/explanation/architecture.md` (substrate containers, enclave tiers)
- `docs/XAAS_PRIOR_ART.md` (status-flip discipline, G4/G5)
- `docs/how-to/how-to-run-burn.md` (saturation burn lanes)
- `docs/how-to/how-to-write-tests.md` (canonical test foundations)
- `docs/how-to/how-to-add-config-key.md` (ontology -> smalt.gen -> census)
