# W18 residual review — FINAL residual group (review lane, Context: solo)

Window: v26.10.18. Contract: WORKQUEUE.md residual lane W18 (group 17 of
`/tmp/rewrite-workqueue.json` — 5 files; the WORKQUEUE prose says "6 files
each" for W6–W18 but the JSON group holds 5 — JSON is the dispatch source).
Doctrine: `docs/jira/v26.10.18/rewrite-drafts/NO-SLEEP-DOCTRINE.md`.
Canonical helpers considered: `test/support/assert_eventually.ex`,
`test/support/env.ex`, `SmaltTest.Lifecycle.ensure_store_up/0`. Standing:
PASS (review lane; 1 file REWRITTEN, 4 ALREADY-COMPLIANT).

## Verdicts

| file | verdict | citation |
|---|---|---|
| test/arm_cascade_teardown_test.exs | REWRITTEN | one defect: a dead no-op "residue audit" loop (:277-281 pre-edit) — `for t <- @tables do if :ets.info(t) == :undefined do else end end` with EMPTY if/else bodies, zero bits, no assertion, no observation; plus the `@tables` attribute (:11-19 pre-edit) that existed only to feed it. Both DELETED (ERRC: delete outranks generate; a no-op loop is unclassified noise for the sleep-leak gate's lint surface). Everything else compliant: `poll_until_terminal/2` is a 50-attempt bounded poll on the real LRO location header (no sleeps; terminality is observed, not slept-for — `lro_delay_ms` is set to 0 via env, so each attempt is synchronous); env mutation (`:lro_delay_ms`) carries correct save/restore in `on_exit`; Store start uses the already_started-tolerant case. All FR-6 receipted assertions (cascade 404s, D127 data-plane sweep, vault-secret capture-then-sweep across RG/account/vault teardown) preserved verbatim. |
| test/data_plane/conditional_headers_test.exs | ALREADY-COMPLIANT | zero sleeps, zero timing bounds, zero env mutation. Pure synchronous unit suite over real `ConditionalHeaders.evaluate/2`/`header/2` return state (Chicago); RFC 7232 precedence pins, lens-5 candidate-dialect pins, and the lens-8 nil-guard degenerate-input fence (:81-88) all assert on real return state. Store via `SmaltTest.Lifecycle.ensure_store_up/0` (canonical helper). |
| test/enclave_ocel_test.exs | ALREADY-COMPLIANT | zero sleeps, zero timing bounds. Real collaborators end to end: real `Lifecycle.run/2` over the real terraform fixture, real NDJSON sink, real POWL discover/conform at fitness 1.0 with a mutated-trace anti-vacuity flip (:117-121). Structural sync (`Process.whereis` guard + `ensure_all_started`) instead of a start-order sleep. Collision-proof scratch sink (ms + unique_integer, cross-pollution fix documented in-source), env `:ocel_dir` save/restore correct, tmp dir deleted in `on_exit` (lane-lease cleanup law). Setup-captured sink asserted, not a node-global env re-read — the shared-env race is handled by structure, not time. |
| test/route_negative_test.exs | ALREADY-COMPLIANT | zero sleeps, zero timing bounds, zero env mutation. Real Plug dispatch over the real Router; every negative path asserts on the decoded envelope + store residue (`list_prefix` zero-write fences). Receipted lens fences (lens-2 400-before-404 precedence, lens-4 F1a/F1b/F2 pagination composition, lens-5 F3a/F3b/F6 providers-anchor kill witnesses, F5/F9 clamp gates) preserved verbatim. `ensure_store/0` delegates to the canonical `SmaltTest.Lifecycle.ensure_store_up/0`; async: false + Store.clear is the established shared-store pattern. |
| test/smalt/hw_test.exs | ALREADY-COMPLIANT | zero sleeps, zero timing bounds, zero env mutation. Real collaborators: real CRC witness vectors, real Ed25519 `:crypto.verify`, real `VirtualSerial` GenServer started under unique names (`:hw_test_dev1/2/3`), byte-pattern destructuring asserts on real binary return state; doctest fence on `Smalt.Hw.Frame`. Python/TS wire-parity vectors preserved verbatim. |

## Diff summary (one file)

`test/arm_cascade_teardown_test.exs`: -18 lines (dead `@tables` attribute +
no-op residue-audit loop with empty if/else bodies), +0. No assertion
changed; all FR-6 fences untouched.

## Evidence — green x2 (MIX_BUILD_ROOT=_build-ft-w18)

Command:

```
MIX_BUILD_ROOT=_build-ft-w18 mix test test/arm_cascade_teardown_test.exs \
  test/data_plane/conditional_headers_test.exs test/enclave_ocel_test.exs \
  test/route_negative_test.exs test/smalt/hw_test.exs
```

Round 1:

```
Finished in 0.7 seconds (0.00s async, 0.7s sync)
41 tests, 0 failures
exit=0
```

Round 2 (identical command):

```
Finished in 1.3 seconds (0.00s async, 1.3s sync)
41 tests, 0 failures
exit=0
```

Sleep gate on all 5 files:

```
[SLEEP-GATE] PASS — 5 files, 0 unclassified Process.sleep
```
