# W9 residual review — group 8 (review lane, Context: solo)

Window: v26.10.18. Contract: WORKQUEUE.md residual lane W9. Doctrine:
`docs/NO_SLEEP_DOCTRINE.md` (LANDED). Canonical helpers:
`test/support/assert_eventually.ex`, `test/support/wire_helpers.ex`
(`SmaltTest.Wire.stop_existing_tree/0`), `test/support/env.ex`. Standing:
PASS (review lane; 1 file REWRITTEN, 4 ALREADY-COMPLIANT).

## Verdicts

| file | verdict | citation |
|---|---|---|
| test/amqp/delivery_encoder_test.exs | ALREADY-COMPLIANT | pure synchronous unit suite: zero sleeps, zero timing bounds, zero env mutation, zero process starts. All assertions on real `DeliveryEncoder.build_sections/1` / `filetime_from_ms/1` return state (Chicago). |
| test/corpus/api_version_admission.exs | ALREADY-COMPLIANT | zero sleeps/timing/env mutation. Uses the canonical corpus contract (`INCIDENT → FIX → FENCE` moduledoc triad, `:corpus` tag, `Smalt.Corpus.Helper.ensure_store/0`, real Plug dispatch). Note: family files are not directly runnable (`mix test test/corpus/api_version_admission.exs` fails — `Smalt.Corpus.Helper` not loaded); the lawful invocation is the loader `mix test test/corpus_test.exs` (per `test/corpus/README.md`). |
| test/dspy_test.exs | ALREADY-COMPLIANT | zero sleeps/env mutation. Real collaborators: real `docs/ERROR_CODES.md`, real `scripts/gen_error_codes.py esc/1` via python subprocess (:131-161); end-to-end run writes a unique-per-run tmp dir deleted in the same test's `on_exit` (:225-230 — lane-lease cleanup law). |
| test/metadata_endpoints_test.exs | REWRITTEN | two defects. (1) Dead helper `wait_until_gone/2` (:368-379 pre-edit): a local poll loop with three `Process.sleep(10)` steps, zero call sites — an unclassified sleep that would fail the sleep gate; DELETED. (2) Local `defp stop_existing_tree/0` duplicated the two-branch whereis shape already canonicalized as `SmaltTest.Wire.stop_existing_tree/0` (`test/support/wire_helpers.ex:101`, same convention the two eventgrid suites and egress_dispatch adopted); local copy deleted, setup (:19) now calls the canonical helper — its Store+AmqpBroker superset stop is documented-safe (each arm tolerates a missing name). Receipted assertions preserved verbatim: all wire assertions, the JWT-claims pins, the no-rescue loud TLS-boot-failure fence, and the http-primary probe order are untouched. |
| test/shacl_projection_test.exs | ALREADY-COMPLIANT | zero sleeps/timing/env mutation/process starts. Real collaborators: real `priv/shacl/smalt-shapes.ttl` parsed via `setup_all`, a stdlib JSON-Schema checker asserting rejection paths (:158-204, no vacuous admits), byte-identical determinism fences, and pack-law cross-validation. |

## Diff summary (one file)

`test/metadata_endpoints_test.exs`: -31 lines (dead `wait_until_gone/2`
with 3 sleeps; local `stop_existing_tree/0` copy), +2 lines (canonical
`SmaltTest.Wire.stop_existing_tree()` call with citation comment). No
assertion changed.

## Evidence — green x2 (MIX_BUILD_ROOT=_build-ft-w9)

Command (corpus family runs via its loader per test/corpus/README.md):

```
MIX_BUILD_ROOT=_build-ft-w9 mix test test/amqp/delivery_encoder_test.exs \
  test/corpus_test.exs test/dspy_test.exs test/metadata_endpoints_test.exs \
  test/shacl_projection_test.exs
```

Round 1:

```
Finished in 4.2 seconds (0.8s async, 3.4s sync)
82 tests, 0 failures (1 excluded)
```

Round 2 (identical command):

```
Finished in 4.8 seconds (1.0s async, 3.8s sync)
82 tests, 0 failures (1 excluded)
exit=0
```

Sleep gate on the touched file:

```
[SLEEP-GATE] PASS — 1 files, 0 unclassified Process.sleep
```

Remaining 4 files: zero `Process.sleep` (grep -c = 0 each).
