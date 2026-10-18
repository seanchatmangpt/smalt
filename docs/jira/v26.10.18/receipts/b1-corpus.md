# B1 — corpus + compliance scaffolding consolidation (corpus-compliance.md)

Standing: ALIVE
Window: docs/jira/v26.10.18 · Batch B1 · MIX_BUILD_ROOT=_build-ft-b1
Draft: docs/jira/v26.10.18/rewrite-drafts/corpus-compliance.md
Master plan: docs/jira/v26.10.18/rewrite-drafts/00-MASTER-PLAN.md
Poll: B0 receipt (b0-foundations.md) present before any edit — confirmed.

## Context

Slice: corpus + compliance test-scaffolding consolidation. Pair: stress-tier
lane (disjoint-region merge on test/corpus/shacl_fuzz.exs — its `@tag :stress`
on the 1000-PUT sweep landed mid-window inside my rewrite; clean merge, no
collision; its exclusion changes the default corpus run to 25/0 (1 excluded),
so the receipted gate is executed with `--include stress`), plus a sleeps lane
whose additive `# SLEEP-CLASS: TIME-ADVANCE` comments landed in c1's
rate-limit test inside the same window.

## What landed

Per the draft (assertion bodies verbatim, scaffolding replaced):

1. `test/corpus/helper.exs` — full rewrite: canonical
   `resilient_clear/1` with in-window `post_seed`, `assert_eventually!/4`,
   `quiescent_read/2` (constants unchanged: 50x10ms clear retry, 20x25ms
   quiesce + 5000ms call-cliff rescue), `arm/egress/json/code` byte-identical.
2. `test/corpus/shacl_fuzz.exs` — alias + private quiesce machinery deleted;
   snapshot rides `Helper.quiescent_read/2` (scope filter
   `String.contains?(String.downcase(k), @snapshot_scope)` preserved
   verbatim).
3. `test/corpus/tags_normalization.exs` — setup comment + `:ok =` pin; the
   smallest consumer / helper smoke test.
4. `test/compliance/c1_arm.exs` — setup → `Helper.resilient_clear(fn -> ... end)`
   (subscription seed now INSIDE the retry window), `start_supervised!`
   Bandit (no on_exit Process.exit), private `poll_until_terminal/3` grid →
   `Helper.assert_eventually!/4` with `@lro_poll_deadline_ms 10_000`,
   private i22 tail deleted.
5. `test/compliance/c3_cosmos.exs` — setup → helper + `start_supervised!`;
   `stop_server/1` and the private tail deleted. Defect fix carried by the
   consolidation: c3's private `ensure_store/0` returned :ok on
   already-started with no table check (no monitor-wait — the divergence the
   draft named); no receipted assertion depended on the weaker behavior.
6. `test/compliance/c4_blob.exs` — setup → helper + `start_supervised!`;
   `stop_server/1` and the private tail deleted; unused `alias Smalt.Store`
   removed (alias Smalt.Corpus.Helper added). c3 likewise dropped its now
   unused Store alias.

Seam fix beyond the draft: `test/compliance_test.exs` loader now requires
`test/corpus/helper.exs` before the c-files (c1/c3/c4 alias
`Smalt.Corpus.Helper`; without the loader line the whole compliance suite
UndefinedFunctionErrors in setup — witnessed 103 failures, run 1).

## Commands + output (real, this window)

Baseline (pre-rewrite, HEAD versions of the six files swapped in via
`git show HEAD:path`, restored after — no stash):

```
$ MIX_BUILD_ROOT=_build-ft-b1 mix test test/corpus_test.exs        # on HEAD files
26 tests, 0 failures
[shacl-fuzz] verdicts: %{admitted: 668, typed_refusal: 214, parse_typed: 118}
```

Corpus 3x post-rewrite (`--include stress`: the sweep is now :stress-tagged
by the stress lane, excluded by default per test_helper.exs):

```
$ MIX_BUILD_ROOT=_build-ft-b1 mix test test/corpus_test.exs --include stress   # x3
run1 EXIT=0 26 tests, 0 failures   verdicts: %{admitted: 668, typed_refusal: 214, parse_typed: 118}
run2 EXIT=0 26 tests, 0 failures   verdicts: %{admitted: 668, typed_refusal: 214, parse_typed: 118}
run3 EXIT=0 26 tests, 0 failures   verdicts: %{admitted: 668, typed_refusal: 214, parse_typed: 118}
```

Compliance 2x (after the loader seam fix):

```
$ MIX_BUILD_ROOT=_build-ft-b1 mix test test/compliance_test.exs    # x2
run1 EXIT=0 157 tests, 0 failures (16 excluded)
run2 EXIT=0 157 tests, 0 failures (16 excluded)
```

Paired:

```
$ MIX_BUILD_ROOT=_build-ft-b1 mix test test/corpus_test.exs test/compliance_test.exs --include stress
183 tests, 0 failures (16 excluded)
$ MIX_BUILD_ROOT=_build-ft-b1 mix test test/corpus_test.exs test/compliance_test.exs
182 tests, 0 failures (17 excluded)
```

Final paired rerun after a `_every` unused-variable warning fix in
`do_poll/7`'s deadline clause (no behavior change; zero warnings remain in
any B1-owned file):

```
$ MIX_BUILD_ROOT=_build-ft-b1 mix test test/corpus_test.exs test/compliance_test.exs --include stress
183 tests, 0 failures (16 excluded)
verdicts: %{admitted: 668, typed_refusal: 214, parse_typed: 118}
```

Sleep-drift sweep (draft verification step 4): only helper-owned bounded
rescues + c1 F1/F2 (SLEEP-CLASS annotated by the sleeps lane) remain;
c2's `wait_twin` retry is out of B1 scope, pre-existing.

```
test/corpus/helper.exs:58/88/125/131/138  (bounded retry/quiesce constants)
test/compliance/c1_arm.exs:403  Process.sleep(1000 - rem(ms, 1000) + 5)   # F1
test/compliance/c1_arm.exs:427  Process.sleep(1100)                        # F2
test/compliance/c2_keyvault.exs:115 wait_twin  (pre-existing, out of scope)
```

## Verification vs gate

- corpus_test 3x 26/0 — PASS, verdict counts byte-equal to the pre-rewrite
  baseline run (668 admitted / 214 typed_refusal / 118 parse_typed,
  deterministic under the recorded seed).
- compliance_test 2x 157/0 — PASS.
- paired 183/0 — PASS (with --include stress; default run 182/0, 17 excluded).
- No git actions taken, per dispatch.

## Notes for the wrap lanes

- `test/compliance_test.exs` gained a `Code.require_file` of the corpus
  helper — a loader change the stress/census lanes' inventories do not touch.
- Default (no --include stress) corpus run is now 25/0 with 1 excluded
  (stress-tagged sweep) — census lanes fencing a plain `mix test
  test/corpus_test.exs` count should expect 25, not 26.
