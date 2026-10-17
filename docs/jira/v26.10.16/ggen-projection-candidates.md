# ggen Projection Candidates — v26.10.16 → next window

Generated from the run-ggen skill lane (2026-10-16, dry-run, freeze-safe).
Ground truth: `mix.exs:33-52` wires two projections from `smalt-substrate-pack`
(registry.ex, ocel/event_registry.ex); pack lock `a4774b15…` @ 26.10.14.

## Ready-to-wire (pack artifacts exist, NOT wired into mix.exs)

| # | Projection | Pack artifacts | Replaces | Verdict |
|---|---|---|---|---|
| 1 | Defaults table | `queries/defaults.rq`, `templates/defaults.ex.eex` | `arm_gateway/defaults.ex` `@table`/`enrich_defaults` | **Wire first** — smallest blast radius; residue caveats: `enrich/4` name-interpolation closures + KD-T5-F1 loopback-authority are behavior (`cnv:CustomBehavior` seam), not data |
| 2 | Cascade sweep dispatch | `queries/cascade_sweep_rows.rq` + CONSTRUCT twin, `templates/cascade_sweep.ex.eex`, `rendered/cascade_sweep.ex` | hand-rolled `cascade_sweep/2` + D127/FR-6 branches (router.ex ~668-717, 1365, 3918-4064) | **Wire last** — D127×FR-6 semantics + behavior-seam decision (store-table sweep is behavior; contains-graph is data); depth-4 guard must fail the gate, never silently under-sweep |
| 3 | Provider matrix | `queries/provider_listing.rq`, `templates/provider_matrix.ex.eex` | hand-written provider_matrix supplement | Wire second — pure data projection |

Convention: every wiring ships its `verify/*.unbound.rq` zero-rows pairing +
`gates/shapes-coverage.rq`; a projection without its verify pairing is
incomplete. SPARQL engine caveat (verified in-pack): the `sparql` hex engine
ignores ORDER BY and returns zero rows for property paths — in-template
re-sorting + unrolled recursion are the standing workarounds.

## Not candidates without ontology authoring

- **planning-policy-pack**: planner-policy vocabulary, not ARM policyRule — no
  fit for `lib/smalt/policy.ex` without a smalt ARM-policy ontology.
- **self-monitoring-pack**: kh:Hook CONSTRUCT mechanism proven, but
  telemetry.ex/metrics.ex are runtime scaffolding; park until PROV modeling.
- **EG1 gap**: not tooling-blocked — blocked on ontology authoring (EG1/
  GRIDEVENT individuals + shapes). Prerequisite lane before any projection.

## Ordering

1. Wire defaults → 2. provider matrix → 3. cascade (with behavior-seam
decision) → 4. EG1 ontology authoring as Event Grid prerequisite.

Each swap is receipt-gated: real `mix smalt.gen` output, replay-identity test,
verify-query zero-rows, falsifier run — no receipt, no swap.
