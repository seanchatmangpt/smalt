# i23 — standalone corpus invocation + atom_bridge teardown-noise typing

Standing: PASS (both repairs verified green x2, real output embedded)
Date: 2026-10-18
Lane: i23 (single-lane repair, no git)

## Repair 1 — standalone corpus invocation

Defect: test/corpus/*.exs family files import/alias `Smalt.Corpus.Helper`
but helper.exs was `Code.require_file`'d only by the loader
(test/corpus_test.exs:62), so standalone invocation
(`mix test test/corpus/<name>.exs`) failed with "Smalt.Corpus.Helper is
not available". Witnessed by w9/w10/w12 receipts.

Fix: `Code.require_file("helper.exs", __DIR__)` inserted immediately
before `defmodule` in all 9 family files
(api_version_admission, blob_container_reput, cosmos_arm_container,
eh_created_at, head_database_account_names, secret_cross_plane_seed,
shacl_fuzz, tags_normalization, vault_enrichment). Idempotent:
require_file is a no-op when the file is already loaded, so the
corpus_test.exs loader path is unchanged.

Verification (MIX_BUILD_ROOT=_build-ft-sc, both invocations):

```
$ MIX_BUILD_ROOT=_build-ft-sc mix test test/corpus/shacl_fuzz.exs
2 tests, 0 failures (1 excluded)          # standalone run 1, exit 0

$ MIX_BUILD_ROOT=_build-ft-sc mix test test/corpus/<8 remaining>.exs (each standalone)
2 tests, 0 failures  <- eh_created_at
2 tests, 0 failures  <- cosmos_arm_container
3 tests, 0 failures  <- both invocations green; exit 0 for all 8
4 tests, 0 failures  <- api_version_admission
2 tests, 0 failures  <- blob_container_reput
2 tests, 0 failures  <- tags_normalization
2 tests, 0 failures  <- vault_enrichment
2 tests, 0 failures  <- secret_cross_plane_seed

$ MIX_BUILD_ROOT=_build-ft-sc mix test test/corpus_test.exs
run 1: 25 tests, 0 failures (1 excluded)  exit 0
run 2: 25 tests, 0 failures (1 excluded)  exit 0
```

Standalone round 2 batch (shacl_fuzz + 3 more in one mix invocation):
exit 0, `9 tests, 0 failures (1 excluded)`.

## Repair 2 — atom_bridge unlinked-task teardown noise

Defect (w15-review, pre-existing noted not fixed there): the test-owned
accept-loop serve tasks log `CaseClauseError {:error, :einval}` /
`WithClauseError {:error, :bad_content_length}` when the harness closes
sockets mid-loop — expected teardown vocabulary surfacing as crash-class
log noise from unlinked Tasks.

Fix: typed teardown arm in `Smalt.Amqp.AtomBridge.serve/2`
(lib/smalt/messaging/amqp/atom_bridge.ex): `:einval`, `:enotconn`,
`:notconn` join `:closed` as silent terminal-socket outcomes (`:ok`, no
log); `:too_large` / `:bad_content_length` / recv faults stay on the
typed `Logger.debug` diagnostic arm (debug level, off by default).

Verification:

```
$ MIX_BUILD_ROOT=_build-ft-sc mix test test/amqp/   # run 1
331 tests, 0 failures (45 excluded)   exit 0

$ MIX_BUILD_ROOT=_build-ft-sc mix test test/amqp/   # run 2
331 tests, 0 failures (45 excluded)   exit 0
```

No debug/CaseClause noise arms changed for genuine faults; the flip is
exactly the new typed arm treating peer-reset teardown as expected.

## Disclosure

Round-2 attempts hit two transient shared-tree compile breaks owned by
other concurrent lanes (lib/smalt/planes.ex, then
test/support/isolation_formatter.ex — compile-freeze class, not this
lane's files). Both settled within the SLA window; the recorded runs
above are the settled re-runs. No cross-lane fix applied by this lane.
