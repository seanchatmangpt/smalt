# semantic kernel roadmap

**Five Defect Classes → ggen Projections**

Understanding-oriented. Roadmap of record:
`docs/jira/v26.10.16/NEXT_WINDOW.md` section 11; the modules the
projections target: `lib/smalt/arm_gateway/defaults.ex`,
`provider_matrix` supplement, cascade dispatch in
`lib/smalt/arm_gateway/router.ex`.

## Why projections, why now

Each of the five target surfaces began as a hand-written module
repaired defect-by-defect. The repairs are correct but the class
recurs: every new resource family re-derives the same defaults shape,
the same cascade shape, the same version-admission shape by hand. The
roadmap's bet is that the *shape* is the defect class — and a shape,
once named, is generatable. The unit of work is therefore not "fix the
module" but "name the shape in the ontology and project it."

One authoring surface owns every projection: the **smalt-substrate-pack**
(`ontology.ttl` + `queries/*.rq` + `templates/*.eex` + `gates/*.rq`),
wired one `--query`/`--template`/`--out` pair per projection in the
`mix smalt.gen` alias. No external pack reuse except two named
exceptions (state-transition-pack — vocabulary-only port;
shacl-projection-pack — manual composition, not drop-in). Reuse is
curated because every borrowed generator identity becomes a parity
surface of its own (see [[dfcm-composition]] C20 reasoning).

## The five lanes

| # | Defect class | Pack projection | Replaces |
|---|---|---|---|
| 1 | Cascade dispatch re-derived per handler | Cascade DAG projected from the ontology | hand-written cascade path in `router.ex` (incl. the D127×FR-6 interaction, WRAP_LEDGER item 4) |
| 2 | api-version admission ad hoc per family | Version lattice | hand-pinned version checks |
| 3 | Defaults table drifting from shape | Defaults-in-shape bijection | `Defaults.@table` in `defaults.ex` |
| 4 | Provider matrix hand-supplemented | Provider-matrix-from-ontology | provider_matrix supplement |
| 5 | IRI/id normalization divergences | Canonical IRI normalizer | scattered normalization sites |

The pairing convention applies to all five: `gates/0XX_*.rq` (runtime
gate, graph violation crashes smalt hard) pair with
`verify/*.unbound.rq` (generation-time query that must return zero
rows to pass). A gate landing without its verify pairing is
incomplete — the same non-vacuity law the shim courts encode
mechanically.

## Prototype verdicts

Receipt of record for the roadmap = prototype artifacts + verdicts,
each prototype landing with its falsifier run (NEXT_WINDOW §11). The
verdicts table, as recorded by the roadmap lane:

| Prototype | Verdict criterion | Artifact (verified on disk, docs lane) |
|---|---|---|
| Cascade DAG | projected dispatch reproduces the hand-written sweep on the D127×FR-6 fixture set | LANDED — `<ggen-marketplace-repo>/packs/smalt-substrate-pack/rendered/cascade_sweep.ex` (997 lines, verified `wc -l`), rendered via `ggen_igniter.sync` from `queries/cascade_sweep_rows.rq` + `templates/cascade_sweep.ex.eex` in the same pack |
| Version lattice | monotone admission over the projected lattice admits exactly the versions the pinned tests admit, and no malformed version | durable referent = `verify/api_admission.rq` in the pack (41-row probe; the `/tmp/kd78_scratch/registry.ex` output was scratch and may be swept) |
| Defaults bijection | table ↔ shape bijection: every default validator-acceptable, every shape field defaulted-or-user-required | LANDED — `<repo>/tmp/defaults_projected.ex` + `<repo>/tmp/merged_defaults.ttl` (table equality: true, validator-accepted); gate pairing `verify/defaults-bijection.unbound.rq` |
| Provider matrix | projected matrix byte-identical to the hand-written supplement on the census fixture | LANDED — proof artifacts `<repo>/tmp/{provider_matrix_generated.ex, hand.json, gen.json}`; `diff hand.json gen.json` → IDENTICAL (16 namespaces / 45 rows), re-run by this lane 2026-10-16; template `templates/provider_matrix.ex.eex` |
| Canonical normalizer | normalization of the probe IRI corpus idempotent and convention-stable | LANDED — `lib/smalt/projection/canonical.ex` (`Smalt.Projection.Canonical`), artifacts `docs/capabilities.json` + `docs/THIRD_PARTY.md`, drift-fenced by `test/canonical_projection_test.exs`; residual-drift court receipt `docs/jira/v26.10.18/receipts/i26-canonical-residual.md` (regenerated with `mix run --no-start`, 27-test tier green) |

Honest status note (docs lane, 2026-10-16; updated 2026-10-18): artifact
paths verified to
exist on disk by this lane (`ls` + `wc -l` + re-run diff); the
canonical-normalizer row, previously UNLOCATED, is now LANDED —
`Smalt.Projection.Canonical` is on disk with its drift-fence test and
the i26 residual-drift court receipt. `tmp/` artifacts are
scratch-class per repo convention (not indexed); the durable referents
are the pack files under
`<ggen-marketplace-repo>/packs/smalt-substrate-pack/`. Where a
row's artifact is not on disk, the row reads UNLOCATED, not "landed".
No row claims landed status without its artifact + falsifier receipt.

## Utilization staging

The target is not coexistence but replacement, staged so each swap is
individually receipted:

1. **provider_matrix supplement → projected matrix** first — it has
   the strongest verdict (byte-identical), so the swap is provably
   behavior-preserving;
2. **defaults table → bijection projection** — the bijection gate
   (validator-acceptable defaults, shape-complete) plus the existing
   `Defaults` tests fence the swap;
3. **cascade dispatch → DAG projection** last — largest surface,
   carries the D127×FR-6 scoping, and depends on the lattice +
   bijection projections being stable underneath it.

Why this order: each stage's falsifier is cheapest when the surfaces
it diffs against are still hand-written and green. Swap the
strongest-verdict, weakest-coupling surface first; the cascade, which
reads everything else, goes last. After stage 3, "the hand-written
supplement/defaults/cascade modules" cease to be sources of truth —
the ontology is, and the modules become projections regenerated, not
patched, exactly the discipline already enforced for ERROR_CODES.md
and the registry.

## See Also

- `docs/jira/v26.10.16/NEXT_WINDOW.md` §11 — roadmap of record
- `docs/explanation/zero-drift-model.md` — why defaults-as-data makes
  the bijection a swap
- `docs/explanation/cascade-teardown.md` — the surface projection 1
  replaces
- `~/.claude/rules/dfcm-composition-catalog.md` — C20 generator
  plurality (why the single pack surface is curated)
- `docs/NO_SLEEP_DOCTRINE.md` — the falsifier-first posture the
  projections share: gates and projections refuse typed, they never
  wait-and-hope
