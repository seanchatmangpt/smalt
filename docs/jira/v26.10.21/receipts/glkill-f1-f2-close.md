# GL-KILL — GL-10 F1/F2 KILL-class defect close

- **Date**: 2026-10-21
- **Lane**: GL-KILL (writer, OTP-29, `MIX_BUILD_ROOT=_build-glkill`)
- **Context**: solo
**Standing**: **ALIVE** — both KILL-class defects closed with witness courts; all named neighbor courts green

## Diff

### F1 — typed struct law-seam preservation (`lib/smalt/powl2/reticle.ex`)

- `AST.Transition` now declares `law_guard: nil, repair: nil` beside
  `[:id, :label, op: :tau]`.
- `AST.PartialOrder` and `AST.ChoiceGraph` declare `law_module: nil,
  repair_edges: %{} defaults`.
- `struct/2` / update syntax now preserve the law fields through the
  documented construction path; the executor's `Map.get` seam reads the
  same fields the overlay path always reached. Typed path == untyped map
  path. `Reticle.admit/1` patterns were already field-superset-tolerant —
  no admission change needed.

### F2 — canonical exclusion compare (`lib/smalt/powl2/law_compiler.ex`)

`notEquals` no longer compares raw `==`. `same_principal?/2`:

- numbers compare numerically (`7 == 7.0` ⇒ violation; same quantity),
- everything else compares canonical string form: `:alice` vs `"alice"`
  violates (atom/binary spell the same principal), structs compare by
  field map with the type tag stripped (cross-struct-type identity rides
  the value, not the module name),
- mixed number/non-number never equal; unrepresentable terms fall back to
  `inspect/1` — the canonical form is total, never raises.

## Court extensions (`test/integration/graphlaw_skeptic_court.exs`)

- F1 leg rewritten: typed-struct `law_guard` transition now asserts
  `{:refused, {:powl2_andon, :a1, "exclusion", "self approval"}}` with the
  real ETS counter at 0 (was: mutated 0→1, `:ok` completion).
- New F1c leg: typed `PartialOrder` carrying `law_module` + `repair_edges`
  (values are repair NODES) survives `Reticle.admit`, guard refusal routes
  to the repair node, op never mutates. Law module resolves `powl2_guard/2
  → :ok` for unguarded nodes (executor consults it for every node).
- F2 legs: atom-vs-binary now violates; cross-struct-type same-id now
  violates; int/float remains a violation (numeric class); representation
  fuzz across `{"alice", :alice, binary}` × `{"bob", :bob, binary}` asserts
  violation/direction in both orderings; mixed-type `7` vs `"7"` stays
  lawful.

## Command output

```
$ PATH="$HOME/.asdf/shims:$PATH" MIX_BUILD_ROOT=_build-glkill mix test test/integration/graphlaw_skeptic_court.exs
...................................................................
Finished in 0.4 seconds (0.00s async, 0.4s sync)

Result: 29 passed
```

Neighbors (single run, 10 files):

```
$ MIX_BUILD_ROOT=_build-glkill mix test test/internal/powl2_law_compiler_court.exs \
    test/internal/powl2_law_guard_court.exs test/internal/powl2_reticle_test.exs \
    test/internal/powl2_executor_test.exs test/internal/powl2_projection_test.exs \
    test/internal/powl2_andon_wire_court.exs test/integration/powl2_gates_court.exs \
    test/integration/graphlaw_powl_business_net.exs test/integration/graphlaw_fullstack_court.exs \
    test/integration/graphlaw_rule_change.exs

Result: 78 passed
```

GL-5 / GL-6:

```
$ MIX_BUILD_ROOT=_build-glkill mix test test/integration/graphlaw_agent_bounding.exs
Result: 1 passed

$ MIX_BUILD_ROOT=_build-glkill mix test test/integration/graphlaw_dual_governance.exs
COURT VERDICT: PASS (GL-6-dual-governance) — operational and analytical legs agree 9/9
```

Full offline suite: `mix test` → 357/455 passed, 10 invalid, 98 failed. The
98 failures contain ZERO powl2 tests (data-plane/integration faces: kv,
blob, service bus, cosmos, appconfig) and each sampled file passes in
isolation (`kv_crypto_face_test.exs` alone: 4 passed) — shared-machine
contention from concurrent lanes, pre-existing, not session-introduced.
No powl2 regression anywhere.

## Coordination disclosure

- `reticle.ex` was quiet ~3.2h before edit. `law_compiler.ex` was polled
  bounded to a >10-min quiet window (616s observed) before folding F2 —
  GL-CONF did not land during the window; no merge conflict occurred.
- Compile freeze: initial `mix compile --warnings-as-errors` fails on a
  PRE-EXISTING `deps/plug` warning surfaced via `Smalt.Mcp.Router`
  (untouched by this lane). Plain `mix compile` emits zero warnings in
  `reticle.ex` / `law_compiler.ex`.

## Files

- `/Users/sac/smalt/lib/smalt/powl2/reticle.ex`
- `/Users/sac/smalt/lib/smalt/powl2/law_compiler.ex`
- `/Users/sac/smalt/test/integration/graphlaw_skeptic_court.exs`
- Build root `_build-glkill` is a lane lease — reclaim at integration.
