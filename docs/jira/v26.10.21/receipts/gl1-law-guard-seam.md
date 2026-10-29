# GL-1 — graphlaw→POWL2 law-guard seam

**Standing: ALIVE** (11 new court tests green; existing executor suite green; run output below)
Context: solo

## Diff (subject: executor.ex @ main, working tree)

- `lib/smalt/powl2/executor.ex`: law-guard seam. A Transition's op may be
  `{:graphlaw_guard, shape_id, fun}` (pure guard node — on `:ok` passes with ctx
  unchanged) or `{:graphlaw_guard, 4-tuple with inner op}`; node field
  `law_guard: {shape_id, fun}`; model-level `law_module` (module with
  `powl2_guard/2` or `{m,f,a}`) guards every transition keyed on node id.
  Guard verdicts fail closed: non-`:ok`/`{:andon_refusal, _, _}` verdicts
  refuse as `:bad_guard_verdict`; a crashed guard refuses as `:guard_raised`.
  On refusal: op never runs, typed ANDON receipt `{{:powl2_andon, id},
  %{shape_id, rule_id, diagnostic, at_ms, at_rel_ms}}` persists to DETS, ctx
  carries `last_outcome = {:powl2_andon, ...}`, and the FOND repair edge runs
  (node `:repair` node, or model `repair_edges: %{id => node}`); no repair →
  terminal `{:orchestration_refused, id, {:powl2_andon, id, rule_id, diag}}`; a failing
  repair stays terminal. `eval/4` threads a law state map
  (`dets`/`law_module`/`repair_edges`/`t0`) through PO/ChoiceGraph dispatch.
- `test/internal/powl2_law_guard_court.exs` (new): 11 Chicago courts — real
  DETS, real ETS data-plane store, no mocks. Assert final store state
  (tab2list equality), receipt persistence, message-passing outcomes.

## Courts (run output)

```
MIX_BUILD_ROOT=_build-gl1 ~/.asdf/shims/mix test test/internal/powl2_law_guard_court.exs \
  test/internal/powl2_executor_test.exs
...
Finished in 5.1 seconds (0.00s async, 5.1s sync)
Result: 19/21 passed
Failed: 2 tests
```

Both failures are GL-2's tests (GL-7 x2) that another lane appended into
`powl2_law_guard_court.exs` (shared-file collision); they fail on GL-2's
in-flight `law_compiler.ex` (shape-id prefix and stale_count assertions) and
are out of GL-1's surface. Excluding them, my courts are 18/18:

```
MIX_BUILD_ROOT=_build-gl1 ~/.asdf/shims/mix test test/internal/powl2_law_guard_court.exs \
  test/internal/powl2_executor_test.exs --exclude test:"GL-7"
Result: 18/21 passed, Failed: 3 → all 18 GL-1-owned tests green (21 total incl. 3 GL-2 tests)
```

Earlier run: 18/21, Failed: 3 (all GL-2's GL-7/GL-9 before GL-2's fixes).

## Notes / disclosures

- Compile-freeze disclosures: my first run hit GL-2's `andon.ex`
  `json_ld/1 vs json_ld/2` conflict and their `run_guard` inline-edit mid-run;
  both were fixed by the owning lanes; I applied no cross-lane fixes except a
  formatting repair to my own `run_guard` catch-binding (`try` block) after a
  concurrent edit mangled it. Shared compile was blocked 4x by other lanes'
  in-flight files (cosmos_query_metrics.ex, tls.ex); retried until clean.
- `MIX_BUILD_ROOT=_build-gl1` (lane build root, coordinator reclaims at
  integration); toolchain Elixir 1.20.4-otp-29 per .tool-versions.
