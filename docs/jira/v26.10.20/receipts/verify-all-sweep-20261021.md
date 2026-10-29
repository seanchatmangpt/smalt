# verify-all post-checkpoint regression sweep — 2026-10-21

- **Subject**: smalt @ /Users/sac/smalt, HEAD `4e1efe35adb03b3c31c5dfaaedf7b75fedc663eb` (branch main), dirty tree
- **Command**: `just verify-all` (recipe `justfile.d/09-verify-all.just` → `scripts/verify_all.sh`); full log `/tmp/verify_all_sweep.log`
- **Aggregate**: `[VERIFY-ALL] FAIL: 8 stage(s) failed.` — script exit **1**. Wall ~4.5 min; no stage exceeded 10 min (no TIMEOUT).
- **Tree state at run**: 10 in-flight `lib/smalt/` edits (application.ex, cosmos_sql.ex, data_plane/{blob_storage,cosmos,queue_storage}.ex, egress_router.ex, graphlaw/validator.ex, messaging/amqp/{atom_bridge,connection,sas_verifier}.ex), in-flight test edits (`test/internal/{internal_tier_census_test.exs,scvd_concurrency_courts.exs}`), ~7 untracked `test/integration/` + `test/internal/` files, dirty docs/receipts. Per lane law, these are **in-flight (other lanes)**, not pre-existing-at-HEAD.

## Per-stage table

| Stage | Result | Exit | Detail / failure signature |
|---|---|---|---|
| doctor | PASS | 0 | - |
| doctor-dod | PASS | 0 | - |
| test-offline | FAIL | 2 | 265 tests, **6 failures**, 21.6s. (1) census allowlist violation (`event_grid_backpressure_test.exs`, `scvd_concurrency_courts.exs` module refs); (2) internal-tier population fence (on-disk vs @owned_files drift); (3) HTTP-status-literal census (4 hits in `scvd_concurrency_courts.exs`); (4,5) `Smalt.ClusterTest` — `:net_kernel.start` → `{:error, {:shutdown, …}}` (2 tests); (6) KD-115 credit-first wire falsifier. |
| test-stress | FAIL | 2 | Same 3 InternalTier census failures under `--include stress` (allowlist, population fence, status-literal census). |
| verification-gates | FAIL | 1 | non-duplication gate: 5 violations — R1 `:gen_tcp.send` in `test/internal/kd134_requester_delivery_test.exs:194`; R2 status-literal asserts ×4 in `test/internal/scvd_concurrency_courts.exs:44/46/193/195`. |
| workspace-court | FAIL | 1 | lib typecheck: ~40 `Cannot find module …/ws12-court-*/lib-js/lib/...js` — compiled lib-js scratch tree absent/stale (`/Users/sac/.cache/tmp/ws12-court-27Auom/`); live leg loud-skipped (no :3100 server). |
| smalt-cli-pytest | FAIL | 2 | collection errors: 167 collected / **8 errors**, `ModuleNotFoundError` (`hypothesis` in `test_hw_property.py`; `azure` in tests/test_blob/cosmos/eventhub…). Venv missing deps. |
| naming-sweep | FAIL | 1 | 39 violations, 62 allowed — overwhelmingly absolute-path strings `/Users/sac/smalt/...` in docs/jira markdown (doc-drift class, many in in-flight v26.10.20 docs). |
| receipt-index-check | FAIL | 1 | `receipt-index: DRIFT — committed index does not match regeneration (restored committed bytes)` — uncommitted receipt files in tree. |
| invariant-gates | FAIL | 1 | 5/6 PASS; **cosmos-etag-cas FAIL** (positive: "create etag is quoted 64-hex" — unquoted/non-64-hex create etag observed; all 7 negative fixtures correctly refused). blob-worm, ledger-chain, lock-clamp, appconfig-etag-cas, queue-capacity PASS. |
| sleep-gate | SKIP | - | honest-red pending repair WOs (5 unclassified sites); SLEEP_GATE_ENFORCE=1 to enforce. |
| have-guard | SKIP | - | un-enforced pending cron install. |
| have-telemetry | SKIP | - | un-enforced pending cron install. |

## Attribution (census only — nothing fixed)

| Failure | Attribution |
|---|---|
| census failures (test-offline 1-3, test-stress) | **in-flight** — dirty `test/internal/scvd_concurrency_courts.exs` + untracked `test/internal/event_grid_backpressure_test.exs`-adjacent files; census tests scan on-disk tier |
| verification-gates violations | **in-flight** — both cited files (`kd134_requester_delivery_test.exs`, `scvd_concurrency_courts.exs`) are dirty/untracked-tier files in the shared tree |
| Smalt.ClusterTest (2) | **environment-suspect** — `:net_kernel.start` refused at distribution setup; loopback EPMD/distribution env, unrelated to dirty diff; not re-derived at HEAD |
| KD-115 credit-first (test-offline #6) | **in-flight-suspect** — rides the dirty AMQP `lib/smalt/messaging/amqp/*` edits |
| workspace-court missing lib-js | **environment/stale scratch** (`~/.cache/tmp/ws12-court-*` built tree absent); needs a ws-build before blaming any diff |
| smalt-cli-pytest venv | **environment (pre-existing)** — `.venv` missing `hypothesis`/`azure` deps; not diff-related |
| naming-sweep 39 | **in-flight** — absolute-path strings largely in dirty v26.10.20 docs |
| receipt-index-check DRIFT | **in-flight** — direct consequence of uncommitted receipt files |
| cosmos-etag-cas gate | **in-flight-suspect** — rides dirty `lib/smalt/{cosmos_sql.ex,data_plane/cosmos.ex}`; etag shape regression signature matches those files' surface |

**Standing:** **SUSPECT** — no stage timed out; 8/13 stages red, but every red attributable to in-flight shared-tree edits or environment (venv, ws scratch, distribution), none proven a regression at HEAD `4e1efe3`. Census only: nothing fixed, nothing reverted. Full log preserved at `/tmp/verify_all_sweep.log`.

## Addendum: publish-dry census (PUBDRY lane, 2026-10-21)

Command: `just publish-dry` (recipe `justfile.d/08-publish-dry.just` → `bash scripts/publish_dry.sh`), repo /Users/sac/smalt.

| Gate | Verdict | Evidence |
|---|---|---|
| 1. mix hex.build tarball | PASS | 1,055,744 bytes; log /tmp/hex-publish-dry/smalt.tar.build.log |
| 2. inner-tar key grep (signing.key\|verifying.key\|.ggen\|keys/) | PASS | 0 matches in contents.tar.gz listing |
| 3. packaged-set leak grep (legacy-client\|/Users/sac) | PASS | 0 hits in unpacked set |
| 4. gen_error_codes.py --check | FAIL | docs/ERROR_CODES.md stale vs regenerated |

Gate-4 diff classification: every hunk is (a) source line-number drift in `lib/smalt/arm_gateway/router.ex` citations (e.g. 1864→2148, 6132→6812) and (b) one added row `arm-gateway | 200 | TagNotFound | router.ex:1071`. Both match the in-flight dirty edit to `lib/smalt/arm_gateway/router.ex` in the shared tree; no unrelated surfaces drift.

**Attribution: in-flight** — dirty `lib/smalt/arm_gateway/router.ex`; not proven a regression at HEAD 4e1efe3. Remedy when the router edit lands: `just gen-error-codes` then re-run `just publish-dry`. Census only, nothing fixed, nothing regenerated.

**Standing:** **PARTIAL_ALIVE** — 3/4 gates PASS on the packaged artifact itself (no key/leak escapes); the sole red is generated-doc drift tracking a dirty lib/ file, not a packaging defect.
