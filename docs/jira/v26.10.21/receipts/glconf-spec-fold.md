# GL-CONF: GRAPHLAW-SPEC fold into landed GL modules (spec-conformance writer lane)

**Standing:** ALIVE
Context: full
Date: 2026-10-21
Toolchain: Elixir 1.20.4 / Erlang/OTP 29.1.2 (asdf), MIX_BUILD_ROOT=_build-glconf

## Scope

Fold of `docs/jira/v26.10.21/GRAPHLAW-SPEC.md` refinements into the landed GL
files, where they differ from lane-dispatch shapes. Coordinator-directed
reconciliation item folded in.

## Refinement legs

### (1) GL-3 — JSON-LD ANDON receipt (lib/smalt/powl2/andon.ex)

- `Andon.json_ld/1,2`: serializes the receipt per spec §GL-3 —
  `@context` (prov + `andon:` prefix), `@type: andon:RefusalReceipt`,
  refusalId/violatingActivity/failedConstraint/shapeClass/detail/
  suggestedRepairAction, `prov:atTime`, `prov:wasInvalidatedBy`.
  `shapeClass` derived from LawCompiler rule ids
  (`Shape/class/path` → class; unknown → `RuleViolation`); `repair_action:`
  opt pins the repair-action IRI; Jason-encoded.
- `format_andon/4` now returns map + `:json_ld` (string) side-by-side.
- Public `Andon.repair_hint/1` exposed for the wire face.
- Court: `test/internal/powl2_andon_court.exs` GL-3 leg (3 tests): every
  spec field asserted, byte-identical for injected inputs, override +
  shapeClass degradation.

### (2) GL-7 — in-place atomic guard swap (lib/smalt/powl2/law_compiler.ex)

- `guard_table!/1`, `swap_guard/3` (compile new predicate → single atomic
  `:ets.insert` pointer swap → next evaluation uses it; net topology
  untouched), `lookup_guard/2`.
- Court legs in `test/internal/powl2_law_guard_court.exs`:
  - install/swap/topology test (one row before and after, fun identity
    changes, next evaluation honors the amended ceiling).
  - concurrent court: 8 spinner evaluators pulling the predicate via
    `lookup_guard/2` under a live swap, two deadline-checked barriers
    (100 old-predicate :ok verdicts observed pre-swap, 100 new-predicate
    violations post-swap), drained stream asserts zero
    new-fun-returns-:ok events (zero stale-predicate evaluations).
- GL-9 fence leg: paired raw-ETS vs lookup+guard-eval+write rounds,
  min-of-3, assert ≤ 15µs/step. PASSES. Corroborated by the landed
  `gl9-governance-tax.md` receipt: median-diff **+0.25 µs/step**
  (+47.2–47.5 reds/step) — far inside the fence.

### (3) GL-8 — wire face (lib/smalt/powl2/andon_wire.ex)

The GL-8 lane landed its full AndonWire mid-flight (GraphlawRefusal error
envelope + AMQP app-props, 14/14 court). Folded the spec refinements
minimally on top:
- `http_envelope` now carries `headers: [{"x-ms-error-code",
  "BusinessLawViolation"}]` (spec §GL-8 header face).
- Error map gains `json_ld` — the GL-3 JSON-LD receipt as a decode-able
  string riding the envelope (byte-identity to the producer receipt is
  preserved via `Andon.json_ld/1` over the normalized wire facts).
- Court: `test/internal/powl2_andon_wire_court.exs` (GL-8 lane's full
  court, 14 tests, green post-fold).

### (4) GL-9 fence

Covered in (2) above; cited receipt: docs/jira/v26.10.21/receipts/gl9-governance-tax.md.

## Coordinator reconciliation: AR-WIRE-02 guard-form restore (7 files)

`is_integer/3` IS a real guard BIF on this OTP 29.1.2 toolchain (decisive
probe: `erlc` of a module with an `is_integer(X, 0, 10)` guard compiles and
`erlang:is_integer(5, 0, 10)` → true on OTP 29). My first attempt failed
only because the bare `is_integer(x, lo, hi)` form resolves in Elixir as a
local macro lookup; the arbitration form is the fully-qualified
`:erlang.is_integer(x, lo, hi)` delegate. Restored in all 7 files:

    lib/smalt/data_plane/blob_storage.ex
    lib/smalt/data_plane/cosmos.ex
    lib/smalt/data_plane/cosmos_query_metrics.ex
    lib/smalt/data_plane/file_share.ex
    lib/smalt/egress_router.ex
    lib/smalt/messaging/amqp10/frame_decoder.ex

(each line: `defguardp int_in(x, lo, hi) when :erlang.is_integer(x, lo, hi)`;
net diff vs HEAD for these files is zero — HEAD already carries the
arbitration form, the compound downgrades were uncommitted SLA downgrades).

## Verification (real output)

    $ MIX_BUILD_ROOT=_build-glconf mix compile
    Generated smalt app

    $ MIX_BUILD_ROOT=_build-glconf mix test test/internal/powl2_andon_court.exs \
        test/internal/powl2_law_guard_court.exs test/internal/powl2_andon_wire_court.exs
    Finished in 0.2 seconds (0.1s async, 0.1s sync)
    Result: 28 passed
    (re-run at --seed 777: Result: 28 passed)

    $ MIX_BUILD_ROOT=_build-glconf mix test test/data_plane \
        test/integration/amqp10_skeptic_court.exs <GL courts>
    Result: 86/89 passed, Failed: 3

The 3 failures are all Amqp10.SkepticCourt (SK2/SK2b/SK5: disposition
decoding, decoder-raise typing, settled-rows growth) — pre-existing on this
tree, unrelated to this lane: this lane's net diff in the AMQP/data-plane
area is zero vs HEAD, and the GL-8 lane receipt (c6424b1) itself flags
"skeptic-court shape adjudication" as open. Not session-introduced.

## Cross-lane events (disclosure)

- Applied a minimal compile-unblock to lib/smalt/wasm/worker.ex (`port =
  state.port` before the pin-matched receive) under the compile-freeze SLA;
  the owning lane's next write superseded it and landed its own fix.
- Coordinate use of lib/smalt/powl2/andon_wire.ex: GL-8 lane rewrote it
  mid-flight after my first implementation; reconciled by folding the spec
  refinements onto their landed API instead of shipping mine.

## Files owned/edited this session

    lib/smalt/powl2/andon.ex                  (GL-3 leg)
    lib/smalt/powl2/law_compiler.ex           (GL-7 leg)
    lib/smalt/powl2/andon_wire.ex             (GL-8 refinement fold)
    test/internal/powl2_andon_court.exs       (GL-3 leg)
    test/internal/powl2_law_guard_court.exs   (GL-7 + GL-9 legs, uncommitted)
    test/internal/powl2_andon_wire_court.exs  (co-owned with GL-8 lane)
    6x defguardp guard-form files             (net-zero vs HEAD, restore)
