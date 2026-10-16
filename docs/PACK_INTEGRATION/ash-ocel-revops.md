# Pack Integration Receipt — ash-ocel-revops-surface-factory-pack → smalt

- **Date**: 2026-10-14
- **Pack**: `ggen-marketplace/packs/ash-ocel-revops-surface-factory-pack` v26.9.11
  (semantic: ontology + SPARQL candidate-surface corpus, SELECT/CONSTRUCT-only authority)
- **Composed executable manufacturer**:
  `ggen-marketplace/packs/ash-revops-structural-factory-pack` v26.8.26 (templates/gates/tests)
- **Subject**: `~/smalt` @ uncommitted working tree (no git, shared checkout, lane-scoped
  files only). Replay: rerun the two gate commands below.
- **Consumer-local projection graph**: `lib/smalt/ocel/revops/gen/revops_surface.ttl` — composes
  the surface-factory pack's candidate structures (r75:AshResource/OcelTimeline/
  ProcessConformance/ValueEvidence, plus the `r75:factory r75:generates r75:AshResource`
  SELECT/CONSTRUCT factory statement) with the structural pack's `ar:` vocabulary.

## What was built

Read-only Ash RevOps surface over smalt's real OCEL feed:

| Module | Pack structure | Reads |
|---|---|---|
| `Smalt.Ocel.RevOps` (domain) | composition root | `Smalt.Telemetry.OcelNdjson` assembled document; trace grouping by first relationship objectId |
| `Smalt.Ocel.RevOps.OcelTrace` (r75:OcelTimeline) | trace surface | NDJSON sink (`tmp/ocel/events.ndjson`, argument `:events_path`) |
| `Smalt.Ocel.RevOps.FitnessVerdict` (r75:ProcessConformance) | verdict surface | same doc, each trace replayed through the real `Smalt.Ocel.Conformance.happy_path_net/0`; only net-vocabulary traces get a row |
| `Smalt.Ocel.RevOps.OcelDeviation` (r75:ValueEvidence) | evidence surface | deviation ledger via `Smalt.Ocel.DeviationAdmission.read_all` (argument `:path`) |

All resources: `Ash.DataLayer.Simple`, read-only (no CUD actions, `defaults []`), records derived
from the real files at read time via `prepare` + `Ash.DataLayer.Simple.set_data/2`.

## Generated vs hand-adapted (disclosed)

- **Factory-generated skeleton** (real `mix ggen_igniter.sync` run, sparql engine, 3 rows →
  3 files via `--for-each`): module name, kind, and attribute-spec list for the three resources
  (see the regenerate header in each resource file).
- **Hand-adapted residue** (disclosed per pack authority boundary — the surface-factory pack is
  SELECT/CONSTRUCT-only and ships no templates; the structural pack's tera templates don't
  project smalt's OCEL vocabulary): atom attribute names, real Ash types (`{:array, :string}`,
  `:utc_datetime_usec`), primary keys, the read actions with `Ash.DataLayer.Simple` prepare
  bodies, code interfaces, and the `Smalt.Ocel.RevOps` domain + trace-grouping helper.
- Regenerate command (canonical form; the executed run rendered into a scratch root inside the
  ggen_igniter project because the smalt tree was compile-frozen by concurrent lanes — output
  copied 1:1 into the owned dir, disclosed here):

```sh
mix ggen_igniter.sync \
  --ontology lib/smalt/ocel/revops/gen/revops_surface.ttl \
  --query resources=lib/smalt/ocel/revops/gen/revops_resources.rq \
  --template lib/smalt/ocel/revops/gen/ash_resource.ex.eex \
  --for-each resources \
  --out 'lib/smalt/ocel/revops/<name>.ex' \
  --engine sparql
```

## Gates (executed 2026-10-14, MIX_ENV=test)

```
mix test test/ocel_revops_test.exs      → 3 tests, 0 failures
mix test test/ocel_conformance_test.exs → 6 tests, 0 failures
```

Test subject: a real seeded `events.ndjson` (res-1 = full happy path, res-2 = broken
2-event trace `[arm.resource.transition, blob.custody.transition]` — blob.put absent) and a
real `deviations.jsonl` written by the real `DeviationAdmission.admit/2` over the real
`Conformance.check_trace/2` verdict on that fixture. res-2's fitness is exactly
`0.5833333333333334` with 2 deviations; the first (asserted) deviation is
`blob.custody.transition/missing_tokens`, status `observed`. The conformance-false deviation
reads back through the Ash surface as an evidence record with the real record id, real trace,
and real fitness.

## Falsifier

Inject a nonconforming trace into the seeded NDJSON (e.g. skip a step): its FitnessVerdict row
must flip to `conforms: false` with `deviation_count > 0`, and (after a real
`DeviationAdmission.admit/2`) a new evidence record must appear on the Ash surface. If a
conformance-false trace still reads `conforms: true` through Ash, this receipt is refuted.

Re-verified v26.10.14 (V261014-16): gate re-run green; test-subject paragraph corrected to
the actual fixture (2-event trace, fitness 0.5833333333333334).

## Standing

PARTIAL_ALIVE: surface reads the real sink + ledger through Ash on the seeded subject; no
admission/court layer gates the surface itself yet; generation of the resource skeleton is
receipted, the read-action bodies are hand-adapted residue.

## Out-of-lane compile-unblock fixes (disclosed, compile-freeze SLA)

Applied minimal syntax repairs to three files being actively edited by other lanes (each was
freezing the shared compile; none are owned by this lane):

1. `lib/smalt/telemetry/semconv/registry.ex` — removed a `@event_names ~w(...)` nested inside
   another `~w` sigil; later removed a `@type` fragment pasted mid-map-literal (the owner
   subsequently landed their own fix for the second).
2. `lib/smalt/projection/semantic_epoch.ex` — `defp parse_ts(ts), do: case ...` multi-expression
   `do:` clause (owner fixed it concurrently; my edit was a no-op duplicate).
3. `lib/smalt/runtime_contracts/support.ex` — duplicate `@doc` blocks (reserve twice) before
   `contract/2`.

No git operations performed.
