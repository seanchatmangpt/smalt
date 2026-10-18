# W12 residual review — group 11 (5 files)

Standing: PASS. Date: 2026-10-18. Context: solo lane.
Contract: docs/jira/v26.10.18/rewrite-drafts/WORKQUEUE.md (lane contract).
Doctrine: docs/jira/v26.10.18/rewrite-drafts/NO-SLEEP-DOCTRINE.md.

Group 11 in /tmp/rewrite-workqueue.json carries 5 files (the dispatch note
said 6; the JSON is the partition of record).

## Per-file verdicts

### test/amqp/management_rpc_test.exs — ALREADY-COMPLIANT
- Zero `Process.sleep` / `:timer` sites; all interactions are synchronous
  `ManagementRpc.handle/2` calls returning typed maps — structural sync
  (doctrine Law 1 form 2).
- Both modules `async: false` with receipts cited in-file (lines 2-8 and
  585-590: receipts/i21d-store-clear-async.md round-1 + round-2 audits of
  the shared `:smalt_sb_*` table wipes) — the F8 401-cluster fix itself;
  not to be re-asynced.
- `defmodule EmptyStore` (line ~598) is a hand-written real-interface
  minimal implementation (`tables_ready?/0 -> false`) exercising the
  fail-closed branch — Chicago-legal, not a mock.
- No env mutations, no absolute-ms timing bounds.

### test/corpus/eh_created_at.exs — ALREADY-COMPLIANT
- Zero sleeps. Corpus family asserting the EH namespace dual-key
  (`createdAt` + `created_at`) emission fence; assertions are pure wire-shape
  asserts over real router dispatch via `Smalt.Corpus.Helper`
  (`ensure_store/0` → `SmaltTest.Lifecycle.ensure_store_up/0`, real Store).
- Note (pre-existing, not introduced): a corpus `.exs` cannot compile
  standalone — `Smalt.Corpus.Helper` is `Code.require_file`d by
  test/corpus_test.exs:62 before the family modules compile. The lawful
  isolated gate for this file is therefore `mix test test/corpus_test.exs`
  (which includes `Smalt.Corpus.EhCreatedAt`); solo-file invocation fails
  compile with "module Smalt.Corpus.Helper is not loaded" (witnessed this
  session, exit 1, before any edit — no edits were made to any file).

### test/egress_wiring_test.exs — ALREADY-COMPLIANT
- Zero sleeps; real Plug.Test dispatch through the real `EgressRouter`,
  real `Store` (`setup` = `ensure_store()` + `Store.clear()`,
  `async: false` serializes the shared-table wipe) — moduledoc states the
  Chicago discipline explicitly.
- No env mutations, no timing bounds.

### test/ocel_test.exs — ALREADY-COMPLIANT
- Zero sleeps. Setup is structural: `SmaltTest.Env.put_restored/1`
  (foundations helper) for the `ocel_dir` env + real tmp dir with
  `on_exit` cleanup; all assertions on real module returns/ETS.
- No timing bounds, no mocks.

## test/smalt_graphlaw_matrix_test.exs — ALREADY-COMPLIANT
- Zero sleeps; `async: true` is safe and documented in-file (line 145:
  "this suite touches no shared process state").
- One observation, deliberately NOT changed: the registry-projection test
  (line 21) guards its body behind
  `if Code.ensure_loaded?(SPARQL) and Code.ensure_loaded?(RDF.Turtle)` —
  a conditional that can silently no-op the test when the deps are absent.
  Out of W-lane scope (skip semantics, not sleep doctrine) — flagged for
  the coordinator as a candidate hardening item, not acted on.

## Validation evidence (real output, both runs)

```
$ MIX_BUILD_ROOT=_build-ft-w12 mix test test/amqp/management_rpc_test.exs \
    test/egress_wiring_test.exs test/ocel_test.exs \
    test/smalt_graphlaw_matrix_test.exs test/corpus_test.exs
# run 1: Finished in 3.3 seconds (1.0s async, 2.3s sync)
#        98 tests, 0 failures (4 excluded)
# run 2: Finished in 2.8 seconds (0.7s async, 2.0s sync)
#        98 tests, 0 failures (4 excluded)
```

Both runs exit 0. Corpus family runs under corpus_test.exs (see note above).
MIX_BUILD_ROOT=_build-ft-w12 left on disk for coordinator cleanup.

## Preserved contracts

No assertions altered; zero file edits in this lane (all five verdicts
ALREADY-COMPLIANT). Receipted pins kept: i21d async:false pins in
management_rpc_test.exs; corpus fix-site fences in eh_created_at.exs.
