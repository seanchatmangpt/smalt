# W17 — residual review lane, group 16 (solo)

Standing: PASS (green x2, embedded output below)
Window: v26.10.18 · Repo: /Users/sac/smalt · Build root: `MIX_BUILD_ROOT=_build-ft-w17`
Contract: WORKQUEUE.md / /tmp/rewrite-workqueue.json group 16 · review vs
`docs/jira/v26.10.18/rewrite-drafts/NO-SLEEP-DOCTRINE.md` · no git

## Group 16 files (5)

| File | Verdict | Action |
|---|---|---|
| `test/api_version_admission_test.exs` | DEFECTIVE setup → repaired | hand-rolled `ensure_store/0` (private monitor + `after 500` bounded-recursion retry) replaced with canonical `SmaltTest.Store.resilient_setup/0`; unused `alias Smalt.Store` removed. All 20 assertion bodies preserved verbatim. |
| `test/data_plane/blob_service_test.exs` | DEFECTIVE setup → repaired | bare `ensure_store_up(); Store.clear()` (FLAKE_LEDGER F2-F5/F10 pattern) → `SmaltTest.Store.resilient_setup/0`; unused `alias Smalt.Store` removed. All 18 assertion bodies preserved verbatim. |
| `test/enclave_lifecycle_test.exs` | DEFECTIVE setup → repaired | bare `ensure_store_up(); Store.clear()` → `resilient_setup/0`. OCEL sink isolation + on_exit restore untouched; `alias Smalt.Store` retained (still used at lines 102-103). Assertions verbatim. |
| `test/r77_snippet_test.exs` | DEFECTIVE setup → repaired | bare pattern → `resilient_setup/0`; unused `alias Smalt.Store` removed. Assertion verbatim. |
| `test/smalt_test.exs` | ALREADY-COMPLIANT | 8-line doctest suite; zero sleeps, zero timing fences, nothing to canonicalize. |

## Doctrine compliance notes

- Zero `Process.sleep` / `:timer.sleep` in any of the 5 files (grep over
  the group returned no matches before and after edits).
- `api_version_admission_test.exs` `ensure_store/0` was the one residual
  per-suite reimplementation of the store bootstrap: its `receive do {:DOWN,...}
  after 500 -> ensure_store()` was event-driven (lawful mechanism) but
  unbounded in recursion depth and duplicated the audited primitive the
  doctrine requires to be singular. Folded onto
  `test/support/store_resilient.ex` (`resilient_setup/0`, built on
  `AssertEventually`).
- No duration claims / leak fences in the group, so the ratio-fence sub-law
  has no surface here. No `lib/` touches.

## Verification (green x2, real output)

Pass 1 (`MIX_BUILD_ROOT=_build-ft-w17 mix test <file>`):

```
=== RUN1 test/api_version_admission_test.exs ===
21 tests, 0 failures
=== RUN1 test/data_plane/blob_service_test.exs ===
18 tests, 0 failures
=== RUN1 test/enclave_lifecycle_test.exs ===
2 tests, 0 failures
=== RUN1 test/r77_snippet_test.exs ===
1 test, 0 failures
=== RUN1 test/smalt_test.exs ===
1 doctest, 1 test, 0 failures
```

Pass 2:

```
=== RUN2 test/api_version_admission_test.exs ===
21 tests, 0 failures
=== RUN2 test/data_plane/blob_service_test.exs ===
18 tests, 0 failures
=== RUN2 test/enclave_lifecycle_test.exs ===
2 tests, 0 failures
=== RUN2 test/r77_snippet_test.exs ===
1 test, 0 failures
=== RUN2 test/smalt_test.exs ===
1 doctest, 1 test, 0 failures
```

Totals: 43 tests + 1 doctest, 0 failures, both passes, on the edited
subjects.

## Disclosures

- Build root `_build-ft-w17` left on disk for coordinator lane-clean at
  integration (lane lease, not an asset).
- No git operations performed (per contract).
