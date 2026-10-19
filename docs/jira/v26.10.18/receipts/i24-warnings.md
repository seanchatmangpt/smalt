# i24-warnings — compile warnings blocking `--warnings-as-errors`

Standing: PASS (gate exit 0, 0 warnings; zero behavior change evidenced)
Lane: i24-warnings
Date: 2026-10-18
Window: docs/jira/v26.10.18

## Scope

Fix the 12 pre-existing compiler warnings blocking
`MIX_ENV=test mix compile --warnings-as-errors` named by the burn-image lane's
receipt (blob_storage.ex:1183, arm_gateway/router.ex:1934, budget_formatter,
isolation_formatter + rest). Fixes are semantic only: no suppressions, no
`--warnings-as-errors false`, no `# dubious` disables.

## Touched files (this lane)

- `lib/smalt/application.ex` — removed 4 dead private zero-arity helpers
  (`arm_port/0`, `arm_tls_port/0`, `arm_tls_opts/0`, `egress_port/0`), orphaned
  by the AZB-09 plane refactor (the TLS twin now boots from
  `lib/smalt/plane/control_supervisor.ex:32` via
  `Smalt.Application.TlsTwinDispatch`, which stays). Pure dead-code removal:
  a `defp` with no callers has no behavior.
- `test/support/budget_formatter.ex` — `_config`, `@impl true` on `init/1` and
  both `handle_cast/2` clauses, `defp write_line/2` moved below the
  `handle_cast` clauses (clause-grouping). Catch-all `handle_cast(_event, st)`
  preserved — no event coverage change.
- `test/support/isolation_formatter.ex` — renamed guard-used `_times` →
  `times`; removed the DEAD second `:suite_finished` clause (unreachable
  duplicate of the first — zero behavior); removed `@behaviour
  ExUnit.Formatter` (not a behaviour) and the bogus `@impl true` on
  `handle_event/2`; added `@impl true` to `init/1`, both `handle_cast/2`, and
  `handle_info/2`; grouped all `handle_event/2` clauses.
- `test/support/lifecycle.ex` (NEW) — `SmaltTest.Lifecycle` extracted verbatim
  from `test_helper.exs` into test/support so the 3 "module not yet defined"
  remote-call warnings in `test/support/wire_helpers.ex:37,109` and
  `test/support/store_resilient.ex:19` become real compile-checked calls.
  test_helper.exs keeps a pointer comment. 50 test files consume Lifecycle.
- `test/test_helper.exs` — `defmodule SmaltTest.Lifecycle` block removed
  (moved to test/support/lifecycle.ex).

## Fixes NOT in the receipted 12 (disclosed, same-gate residues)

- `test/support/lifecycle.ex:223` `Process.erase(token)` →
  `Process.delete(token)` — a concurrent lane's addition to the extracted
  module called a nonexistent function; minimal unblock, disclosed here
  (compile-freeze SLA).
- `test/azsim/topology_test.exs:153` — concurrent azsim lane's in-flight file
  called `http_request/5` (bare header list + `body:` kw) against
  `http_request/4`. Normalized to the `headers:`/`body:` opts form; headers
  byte-identical. Disclosed per compile-freeze SLA; the subsequent failure of
  that test (401 IssuerMismatch) is the azsim lane's runtime auth flow, not
  this call shape.

## Gate (the fix target), real output

```
$ MIX_ENV=test MIX_BUILD_ROOT=_build-ft-warn mix compile --warnings-as-errors --force
exit=0
warning count: 0
$ MIX_ENV=test MIX_BUILD_ROOT=_build-ft-warn mix compile --warnings-as-errors   # incremental
exit=0
(no output)
```

Before state (first enumeration, 12+ warnings, exit 1): Lifecycle-undefined x3
(wire_helpers/store_resilient), budget_formatter unused-var + clause-grouping,
isolation_formatter underscored-var-used x2 + clause-grouping +
`ExUnit.Formatter is not a behaviour` + `@impl` mismatch x2,
blob_storage `cas_replace/6`/router warnings present under `--force` only
(stale-beam artifacts; not reproducible after forced recompile — the live
lib tree compiles clean).

## Zero-behavior-change evidence

1. Full offline suite WITH all of this lane's changes, run 1:
   `MIX_BUILD_ROOT=_build-ft-warn mix test` → `exit=0` (green).
2. Isolation court (IsolationFormatter consumer gate):
   ```
   $ just isolation-court
   verdict=PASS static=GREEN fixtures=REFUSED-OK elapsed=0.76s   (exit 0)
   ```
3. Budget formatter exercised: `just test-budget-seed` mix leg wrote the
   export (`== budget export written: tmp/test-budget-export.tsv`); recipe
   exit 2 came from 2 test failures of the concurrent churn class (below),
   not the formatter.
4. Targeted Lifecycle-consuming suites x2 (auth_enforce, lro,
   eventgrid_conformance):
   ```
   run1 exit=0   177 tests, 0 failures
   run2 exit=0   177 tests, 0 failures
   ```
5. Later full-suite runs under the hot tree (runs 4/6/7: 18/13/29 failures)
   contain ZERO failures in this lane's touched files; the failure set varies
   run-to-run across burn-lane surfaces (azsim topology/dets_recovery,
   Enclave lifecycle, McpWire cluster, doctor, pplan) — concurrent-lane churn
   evidenced by per-run mtime changes in `test/azsim/` (adversarial_joe
   `SmaltTest.Support.Assertions` import fixed by its lane at 18:59;
   dets_recovery `bxor` fixed by `import Bitwise` at 19:37) and by HEAD moving
   to 8d6b4cb mid-session. This lane introduced no failure.

## Notes

- The receipt's named line numbers (blob_storage.ex:1183, router.ex:1934)
  did not reproduce against the live tree; the live forced compile surfaced
  the application.ex dead helpers instead. Fixed what the compiler names
  today.
- Build root `_build-ft-warn` is lane-private; deletion left to coordinator
  cleanup (`just lane-clean`).
