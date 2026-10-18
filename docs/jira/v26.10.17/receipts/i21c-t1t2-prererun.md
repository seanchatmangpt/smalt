# i21c — T1+T2 court pre-run #5 (decisive, load-context)

Standing: PARTIAL_ALIVE — T2 wire tier green; T1 2655 tests / 7 failures under heavy concurrent load; failure set is drift+load class, zero repaired-face recurrences identified.

Date: 2026-10-17 ~20:53–21:12. Repo: /Users/sac/smalt. Build root: `_build-ft-t12`.
Expectation going in: 2655 tests, 0 failures. Observed: 2655 tests, **7 failures** (61 excluded, 1 doctest, 7 properties). T2: **29 tests, 0 failures, exit 0**.

## Load context (just quiet-check, captured verbatim)

```
QUIET-CHECK REFUSE (typed violations):
  - stray beam pid 45956 cwd='/Users/sac/smalt/deps/postgrex' (not this checkout)
  - stray beam pid 32927 cwd='/Users/sac/ex4pm ~/ex4pm' (not this checkout)
  - court port 9443 occupied
  - court port 8443 occupied
  - port 5672 occupied
  - court port 9445 occupied
  - concurrent suite/court processes: (concurrent mix test --include amqp_wire full-suite lane)
  - load 14.2/18.2 > threshold (16 cpus)
```

Also observed: `uptime` load averages 17.01 27.86 24.19 at 20:53. A concurrent lane ran
`MIX_BUILD_ROOT=_build-ft-comb mix test --include amqp_wire` (full suite) simultaneously.

## Command + real output

```
$ MIX_BUILD_ROOT=_build-ft-t12 mix test
Finished in 628.1 seconds (15.9s async, 612.1s sync)
1 doctest, 7 properties, 2655 tests, 7 failures (61 excluded)
```

(T1 completed despite a trailing `** (Mix) Can't continue due to errors on dependencies`
after the summary — see "Tree churn during run" below. Full log: `/tmp/t1_run5.log`.)

```
$ MIX_BUILD_ROOT=_build-ft-t12 mix test test/wire --include amqp_wire
Finished in 1.3 seconds (0.00s async, 1.3s sync)
29 tests, 0 failures
```
(exit 0; two earlier T2 attempts at 20:56–21:05 exited 1 with a deps-resolution refusal —
see below. First T1 attempt also surfaced the same refusal before any tests ran.)

## The 7 T1 failures, verbatim identity + classification

1. `test verify gate is quiet on the live ontology and FIRES on a mutated copy (Smalt.SemconvReplayIdentityTest)` — `test/semconv_replay_identity_test.exs:67` — "replay subprocess failed (exit 1)" while recompiling deps (stream_data, gen_stage, ymlr, mime) inside the subprocess. Class: **load/transient (dep-recompile subprocess under concurrent compile churn)** — suspect, not repaired-face.

2. `test docs/ERROR_CODES.md is the byte-identical projection of the sources (Smalt.ErrorCodesDocTest)` — `test/error_codes_doc_test.exs:46` — "docs/ERROR_CODES.md is stale relative to the sources. Regenerate: python3 scripts/gen_error_codes.py". Class: **projection drift from concurrent in-flight lib/ edits** (router.ex et al. modified mid-window by other lanes).

3. `test generated artifact drift fence docs/capabilities.json equals rendered json/0 (Smalt.CanonicalProjectionTest)` — `test/canonical_projection_test.exs:125` — "docs/capabilities.json is stale vs Registry truth". Class: same **projection drift** as (2).

4. `test THIRD_PARTY rider (E4 #6/#5b) docs/THIRD_PARTY is stale vs mix.lock truth — run Canonical.write/0 (Smalt.CanonicalProjectionTest)` — `test/canonical_projection_test.exs:145` — THIRD_PARTY.md is derived from mix.lock; mix.lock mtime churned at 20:55 mid-run. Class: **projection drift (mix.lock churn)**.

5. `test cite-drift fence: every router.ex:LINE citation resolves to the expected construct (ApiVersionMatrixTest)` — `test/apiversion_matrix_test.exs:421` — "stale citation lib/smalt/arm_gateway/router.ex:2725: expected line content matching \"Microsoft.Network/virtualNetworks/:parent/subnets/:name\" but got \"          [{\\\"__unmatched__\\\", \\\"\\\"}]\"". Class: **projection drift — concurrent in-flight edit to router.ex moved line 2725**.

6. `test concurrency (ST4 court) sweep/0 does NOT reclaim a renewed message lock (renew mirrors into message row) (Smalt.Amqp.QueueStoreTest)` — `test/amqp/queue_store_test.exs:590` — row came back `state: :available` (lock_token nil) where `:locked` expected. Class: **SUSPECT — possible real defect or load-timing flake**; only failure whose mechanism is not explained by drift or load. Needs a clean-machine replay to classify. Not a repaired-face (i21) recurrence.

7. `test wire mixed load: normal calls interleaved with oversized payloads (Smalt.McpWireTest)` — `test/mcp_wire_test.exs:452` — `** (EXIT ...) unparseable HTTP response: ""` at :488. Class: **load flake suspect** — empty response under 14+ load; needs clean-machine replay.

## Tree churn during run (explains the deps refusals)

- `mix.lock` mtime churned at 20:55 mid-run; `deps/ex4pm/mix.exs` at 20:56 showed version "26.10.8" checked out vs lock 26.10.1 → `mix` refused: "the dependency ex4pm 26.10.8 ... does not match the requirement ... {:ex4pm, "26.10.1"} from deps/ash_ex4pm/mix.exs". By 21:07 both lock and deps/ex4pm read 26.10.1 (another lane repaired/reverted). T2 then passed on the first consistent attempt.
- This lane made no edits and ran no git commands.

## Verdict

- T2 wire tier: green (29/0) on a consistent tree.
- T1: 7 failures, all but #6 classified as drift/load-context; #6 (ST4 renew/sweep court) is the one item needing a clean-machine replay before attempt-4 prediction. Load context (14.2/18.2, full-suite lane concurrent, ports held by substrate) makes a load-context green of the full 2655 unattainable this window; this is the strongest load-context evidence attempt 4 will get.
