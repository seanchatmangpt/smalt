# Semantic Projection

Lane: semantic projection (owned files: `mix.exs` deps section,
`lib/smalt/semantic/*`, `test/semantic_projection_test.exs`, this doc).

## Architecture

    Smalt.Store (ETS, canonical substrate state)
        |
        v  manual read (Smalt.Semantic.StoreRead)
    Ash resources (Smalt.Semantic.Resource / LedgerEntry / Evidence)
        |            \
        v             v
  AshR2RML mapping   AshEx4pm evidence pattern
  (virtual RDF       (admission standing: observed
   projection)       != authorized; read-only)

- `Smalt.Semantic.Domain` (lib/smalt/semantic/domain.ex) is a minimal Ash
  domain over three read-only resources.
- `Smalt.Semantic.StoreRead` (lib/smalt/semantic/store_read.ex) is a manual
  read path (`Ash.Resource.ManualRead`) over the substrate's own state: real
  `Smalt.Store.list/1` scans of `:smalt_resources` and
  `:smalt_ledger_transactions`, plus a real
  `Smalt.Ocel.DeviationAdmission.read_all/1` ledger read. No new postgres, no
  shadow ETS, no second store: the projection IS the Store read path, lifted
  into Ash records (built with the `__metadata__` every Ash record carries).
- The substrate has no SQL surface, so the R2RML logical tables
  (`smalt_resources`, `smalt_ledger_transactions`, `ocel_deviations`) are
  VIRTUAL: they name the Store table / ledger file the read path projects,
  which is exactly what an R2RML logical table names in the Ontop-style
  deployment (swap the manual read for a real SQL source and the emitted
  mapping is unchanged in shape).

## Resources and vocabulary

All semantic terms are namespaced under smalt's existing vocabulary,
`https://ggen.io/ontology/smalt#` (the same namespace as the
smalt-substrate-pack ontology). Subjects live under
`https://ggen.io/data/smalt/...` (data space, distinct from the ontology
space).

| Resource | Store source | Class | Predicates |
|---|---|---|---|
| `Smalt.Semantic.Resource` | `:smalt_resources` | `smalt#ArmResource` | `name`, `resourceType`, `location`, `provisioningState` |
| `Smalt.Semantic.LedgerEntry` | `:smalt_ledger_transactions` | `smalt#LedgerEntry` | `subLedgerId`, `merkleRoot`, `prevHash`, `dataHash` |
| `Smalt.Semantic.Evidence` | `tmp/ocel/deviations.jsonl` via `Smalt.Ocel.DeviationAdmission` | `smalt#OcelDeviationEvidence` | `referenceTraceId`, `candidateTraceId`, `deviatingMove`, `fitness`, `evidenceStanding` |

## R2RML emission

`AshR2RML.Compiler.compile/1` over the three resources yields a normalized
`AshR2RML.Mapping.Bundle`; `AshR2RML.R2RML.render/1` emits deterministic
W3C R2RML TTL (byte-identical across renders — asserted in the test). The
same mapping drives `AshR2RML.OBDA.InMemory.materialize/3`, which executes a
real `Ash.read!` over the manual Store read path and materializes a real
`RDF.Graph` of substrate state.

## Evidence standing (known != authorized)

Per ex4pm's admission pattern (a capability being known or projected does not
mean it is ALIVE, authorized, or allowed to perform DO):

- Every semantic resource exposes ONLY a `:read` action. Projection cannot
  manufacture write authority; there is no create/update/destroy surface.
- `Smalt.Semantic.Evidence.status` carries the ledger's own vocabulary
  ("observed"), never "authorized". A deviation record projected here is
  evidence that a nonconforming trace was OBSERVED and durably admitted —
  not a repair, not a resolution.
- Ledger receipts are projected as evidence of appends (merkle chain fields),
  again read-only.

## What the packs generated vs hand-written

Pack path EVALUATED, not used — disclosed per house law:

- `ash-r2rml-paas-pack` / `ash-r2rml-reactor-paas-pack`: their ggen pipeline
  (`ontology.ttl -> admission gate -> ggen -> Ash resources/domain -> Reactor
  -> BRCE`) manufactures a STANDALONE provider-neutral PaaS kernel app (the
  pack ships `mix.exs.tmpl`, its own `lib/` tree). Smalt needs in-app
  projections whose read path is `Smalt.Store` — a shape the packs do not
  emit (no template parameterizes an existing app's manual read path).
  Driving ggen_igniter sync from the pack ontology would have generated a
  second app tree that smalt does not consume, so it was not used.
- `ash-ex4pm-evidence-pack`: emits consumer-namespaced evidence bridges
  (`Ex4pm.OCEL.validate_envelope/1` / `Ex4pm.Stream.Ingest.ingest_envelope/2`
  wired through `AshEx4pm.Notifier` post-commit envelopes). That path requires
  the full Ex4pm runtime stream; smalt already owns a real, receipted OCEL
  deviation admission (`Smalt.Ocel.DeviationAdmission`), so the evidence
  resources instead project THAT ledger and follow ash_ex4pm's standing
  discipline (known != authorized) rather than duplicating the envelope
  machinery.
- Therefore: the Ash modules under `lib/smalt/semantic/` are HAND-WRITTEN
  minimal Ash resources using the canonical DSLs of the two referenced repos
  (`AshR2RML.Resource` extension for the r2rml sections; ash_ex4pm followed
  as a PATTERN, its dep present and compiled). The semantic machinery itself
  (mapping compile, R2RML render, OBDA materialization) is the repos' real
  code, not a reimplementation.

## Publish-deps note

- `{:ash_r2rml, path: "../ash_r2rml", only: [:dev, :test], optional: true}` and
  `{:ash_ex4pm, path: "../ash_ex4pm", only: [:dev, :test], optional: true}`:
  path deps, dev/test only, optional — smalt's Hex package does not depend on
  them; they are local development capital per the house path-dep pattern
  (same as `ash_graphlaw`).
- DELIBERATE DEVIATION, disclosed: the lane spec said `only: :dev` exactly;
  widened to `[:dev, :test]` because the gate (`mix test
  test/semantic_projection_test.exs`) runs under MIX_ENV=test, where an
  `only: :dev` dep is not available. With `only: :dev` the test file could not
  compile.
- Heavy transitive tree disclosed: `ash_ex4pm` pulls `ex4pm` (which pulls
  explorer + wasmex Rust NIFs, phoenix, broadway, postgrex). These compile
  locally (cargo) and are dev/test-only.
- Ash requires `config :ash, :default_string_length_count` at resource
  compile time. `config/config.exs` is outside this lane's owned files, so
  each semantic resource sets it via module-level
  `Application.put_env(:ash, :default_string_length_count, :codepoints,
  persistent: true)` before `use Ash.Resource`. Idempotent, compile-VM-local;
  no string-length validation is used at runtime. If a future lane adopts Ash
  broadly, move this to `config/config.exs`.

## Gate receipt

- `mix compile` exit 0 (no errors; all warnings pre-existing, none from
  `lib/smalt/semantic`).
- `mix test test/semantic_projection_test.exs`: 7 tests, 0 failures (at the
  gate run; **21 tests, 0 failures** as of 2026-10-15, docs-corpus-lens7
  cycle 5 re-run — suite grew with the epoch + projection work).
- Canary `mix test test/smalt_arm_gateway_test.exs`: 24 tests, 0 failures (at
  the gate run; **26/0** as of 2026-10-15 lens-6 re-run, unchanged lens-7).
- Existing suites untouched: the only shared-file edit is the mix.exs deps
  section (additions only).
