# B6 — cite-system swap (apiversion-refusal draft, files 1+2)

Window: v26.10.18. Batch: B6 (master plan §2). Context: solo.
Spec: `docs/jira/v26.10.18/rewrite-drafts/apiversion-refusal.md` (files 1 and 2
only — file 3 `arm_error_corpus_test.exs` cite tags defer to B4's landing per
§1.3; files 4/5 out of this lane).

## Landed

- NEW `test/support/route_cites.ex` — `SmaltTest.RouteCites`:
  - `@route_cites` registry: route_key -> `{Router, handler, arity}` (17 keys:
    generic_provider_put, rg_put, 5 child, vault_secrets + 2 cosmos + 6
    parented). Draft registry corrected against the live router:
    `handle_rg_put` arity is **3**, not the draft's 4.
  - `route_key_for_type/1` / `route_key_for_type!/1` type classification
    (child / parented / generic-by-segment-shape).
  - `assert_path_coverage!/2` — compile-time coverage fence (raises naming
    gaps; consumed as a module attribute).
  - `handler_defs/1` via `:beam_lib.chunks(..., [:abstract_code])` and
    `assert_cites_resolve!/0`.
- `test/apiversion_matrix_test.exs` — cite-by-symbol swap:
  - Row cites are route_key atoms (`:subnet_put`, ...); `@generic_put_line`
    dead; describe renders `"{type} (#{route_key})"`.
  - `@cite_drift` line-content fence + grep test DELETED; replaced by two
    structural rows: "every matrix row cites a registered route_key" and
    "cite fence: every route cite resolves to a live Router symbol" (via
    `assert_cites_resolve!/0`).
  - Registry-completeness exclusions moved from inline comments to
    `@excluded_literals` (8 named rows with close-condition prose); new
    non-vacuity row asserts every excluded literal still appears in
    router.ex (stale exclusion turns red).
  - Preserved verbatim: the three-PUT fence per row, KD-78 monotonic
    admission row, matrix sweep precedence rows, route-gap rows, helpers.
- `test/wire_tier_refusal_sweep_test.exs`:
  - `resource_path/2` rewritten onto `SmaltTest.RouteCites.route_key_for_type!/1`;
    the `raise "no ARM path builder"` fallthrough is DEAD; replaced by the
    compile-time `@path_coverage` module attribute
    (`SmaltTest.RouteCites.assert_path_coverage!(@resolver_keys)`).
  - Behavior preserved: `Microsoft.Network/subnets` (2-segment registry type
    with a dedicated child route) keeps its old resolver behavior — rides the
    generic provider path (explicit `:subnet_put` case, prior segment-count
    outcome unchanged).
  - Preserved verbatim: shapeless-set derivation, Defaults-hydration clause,
    V261014-18-D2 clause, law comments, `>= 30` floor.

## Verification (real output)

Build root `MIX_BUILD_ROOT=_build-ft-b6` throughout.

### File gate, green x2 each (post-restore final runs)

```
apiversion_matrix: 243 tests, 0 failures   (exit 0)   # run 1: 243/0 @13:39
apiversion_matrix: 243 tests, 0 failures   (exit 0)   # run 2
wire_tier_refusal_sweep: 3 tests, 0 failures (exit 0)  # run 1: 3/0 @13:39
wire_tier_refusal_sweep: 3 tests, 0 failures (exit 0)  # run 2
```

(One interim matrix run mid-batch read 243/1 — my own `Code.ensure_loaded/1`
match bug, fixed; superseded by the two green runs above.)

### Cite-fence non-vacuity probe (scratch test, deleted after run)

```
NV-PROBE defs count: 140
NV-PROBE live handle_parented_child/7: true
NV-PROBE bogus handle_resource_put/9: false
NV-PROBE bogus handle_nope/5: false
```

The introspection discriminates a live `defp` from bogus fun/arity — the
fence can fail, and only on a real handler rename/removal.

### Drift-proof probe (the point of the whole rewrite)

Blank line inserted after router.ex line 1 (snapshot swap, no stash), router
actually recompiled, fence re-run:

```
BEFORE 122bc974484e45b963fc6f02012840d62d7500e345e3ee7718a713d67827ba94
Finished in 7.8 seconds ... 243 tests, 0 failures
DRIFT-PROBE-EXIT: 0
AFTER  122bc974484e45b963fc6f02012840d62d7500e345e3ee7718a713d67827ba94
RESTORE-EXACT: yes (== pre-probe sha)
```

A line insertion that previously required a hand re-anchor of 12 line cites
now leaves the fence GREEN. (An interim "RESTORE-EXACT: NO" line in the
session log was a shell artifact — `before_sha` did not survive the bash-call
boundary; the byte-exact comparison above was re-run in a single call.)

### Fence mutation status

Not run in this batch: `just shim-courts` untouched; no `lib/` changes; no KD
flips; no GAP tokens minted; no registry flips.

## Compile-freeze disclosures

- Lane b-await-migration applied a minimal unblock to MY in-flight
  `test/support/route_cites.ex` while it was non-compiling: guard-illegal
  `String.contains?/2` moved from the cond guard to the body
  (`route_key_for_type/1`) — identical classification, compiles clean.
  Named here per the disclosure law; mirrored in that lane's receipt.
- Two transient shared-tree states interrupted runs (not my surface, not
  counted against this batch): a `lib/smalt/affidavit/wasm_engine.ex`
  CompileError window and a `WasmEngine.Supervisor.start_link/1 undefined`
  boot-failure window — both healed by the owning lane; final greens above
  are post-heal.

## Standing

PASS for the B6 cite-system scope. Outstanding per master plan: full-suite
x3 gate and corpus/compliance stage are batch-gate items for the coordinator;
B6's remaining scope (arm_error_corpus second pass, mcp-ash-misc §1/§2,
trust_profile async flip) belongs to the sequential second pass after B4.
