# 08 — ggen posh pack coverage vs ambition

Status: **PARTIAL** — graph + generation exist and outputs compile, but generated artifacts
are orphaned (zero hand-written imports), runtime SHACL validation is a stub, one generated
module resolves to a nonexistent turnstile module, and the handwritten-code-is-irresidue rule
is not enforced by any byte-identical regen check.

Subject: smalt @ main, packs/posh (ggen-marketplace, F12 lane, v26.10.30).
Evidence date: 2026-10-30, this session.

## Coverage matrix: route class → graph → generated → imported

Graph individuals (`packs/posh/examples/posh_instance.ttl`): 3 `posh:IngressRoute` individuals
(routeArmRequest, routeArmGet, routeTelemetry), 3 Turnstiles, 3 Receipts, 1 EgressRoute, 2 Sinks,
1 ReceiptRule. Op registry in `posh/cmd/posh/main.go:28-31` (`var ops`): exactly 1 op, `"echo"`.

| route class (graph individual) | membraneOp | graph | Elixir generated | compiled | imported by hand-written | Go generated | compiled | imported |
|---|---|---|---|---|---|---|---|---|
| routeArmRequest | `arm.request` | YES | `lib/smalt/posh/pipeline/arm.request.ex` | YES (beam) | **NO** | `generated_ops_arm_request.go` | YES (`go build ./...` clean) | **NO** |
| routeArmGet | `arm-get` | YES | `arm-get.ex` | YES | **NO** | `generated_ops_arm_get.go` | YES | **NO** |
| routeTelemetry | `echo` | YES | `echo.ex` | YES | **NO** | `generated_ops_echo.go` | YES | **NO** |
| (hand-wired, not in graph) | `echo` | — | — | — | — | — | — | YES — `main.go` `ops` registry |

The only route the running system actually serves (`echo` via `main.go` `ops` map) IS in the
graph, but it is served through the hand-wired registry, not the generated dispatcher. The
generated `adapter.generatedOps` table + `Dispatch` are never referenced outside
`posh/internal/adapter/` (grep: zero references). Generated Elixir pipelines are never
referenced by `ingress/`, `supervisor.ex`, or `client.ex` (grep: zero references). Orphaned
on both sides.

## Findings

1. **Generated artifacts are orphans (both runtimes).** All 7 generated files exist and compile
   (`mix compile` produces beams for all three `Smalt.Posh.Pipeline.*`; `cd posh && go build ./...`
   exits 0), but no hand-written code imports them. The live path is `client.ex → UDS → main.go
   hand-wired `ops` map (1 op). C25-style "repo consumes its own pack" is not happening.
2. **Graph→code skew: 3 routes in graph, 1 op in code.** `arm.request`/`arm-get` exist as
   individuals + generated adapters but the hand-written registry admits only `echo`. The
   generated `adapter.generatedOps` table was designed to BE the allowlist ("an op absent from
   it is refused") but since nothing dispatches through it, the real allowlist is the hand-wired
   map — the graph is not the source of the live allowlist.
3. **SHACL is generation-time only.** `shapes/ingress.ttl`/`egress.ttl` gate the merged graph at
   generation; runtime `validate/2` in every generated pipeline is a stub (`def validate(_frame,
   _shape_iri), do: :ok`), explicitly deferring to "hand-written runtime" which contains no SHACL
   engine for posh (grep of lib/ finds shacl_gate only in `sql_ingest/mapping.ex` and fences in
   `arm_gateway`, nothing in `lib/smalt/posh/`). A nonconforming frame is admitted.
4. **Generated pipeline has a dangling atom reference.** `Smalt.Posh.Pipeline.Echo.admit/2` calls
   `turnstile()` = `String.to_atom("Smalt.Posh.Turnstile.TurnstileTelemetry")` — no such module
   exists (only `Smalt.Posh.Turnstile` with a different `admit/5` arity). First call would crash.
   Even the orphaned code is not self-consistent.
5. **Invariant queries exist, no court runs them.** `queries/invariant_orphan_route.rq` and
   `invariant_turnstile_receipt.rq` name exactly this drift, but grep finds no script, justfile
   recipe, test, or CI step executing them.
6. **No byte-identical regen check.** No `ggen sync`-diff gate in justfile, either Makefile, or
   scripts. Today the 7 checked-in generated copies (3 in `lib/smalt/posh/pipeline/`, 4 in
   `posh/internal/adapter/`) are byte-identical to `packs/posh/generated/` (verified by diff),
   but nothing prevents silent hand-edit of the deployed copies — the "hand-written code is
   irreducible residue" rule is prose, not mechanism.
7. **Compile gate is environment-gated.** `mix compile --warnings-as-errors` fails on a
   pre-existing unrelated warning in `Smalt.EgressRouter` (plug router line 1300) under Elixir
   1.20.4 (mix.exs pins ~> 1.20; default asdf elixir is 1.19.5). The three pipeline beams compile
   clean; the failure is session-preexisting, not posh-introduced.

## Close conditions

- **G-08a (orphan dispatch)**: `main.go` deletes its hand-wired `ops` map and dispatches through
  `adapter.generatedOps` (or the dispatcher is wired into `server.Handler` routing). Receipt: a
  membrane request for an op absent from the graph is refused by the projected table, and
  `grep -r "ops = map" posh/cmd` is empty.
- **G-08b (graph = allowlist)**: adding a route individual + regen makes the new op servable
  without touching `cmd/`; deleting one makes it refused. Receipt: end-to-end echo over real UDS.
- **G-08c (runtime SHACL)**: generated `validate/2` delegates to a real validator (shex/shacl.ex
  or the shape compiled to a match) or the shape is compiled into generated validation code; a
  nonconforming frame raises (Andon RED) in a test.
- **G-08d (dangling turnstile)**: either per-turnstile modules are generated or the pipeline
  calls `Smalt.Posh.Turnstile.admit/5` with the graph-projected receipt IRI; `admit/2` succeeds
  in a test with a real turnstile.
- **G-08e (invariant courts)**: justfile recipe runs the two invariant .rq files against the
  merged graph and exits 1 on violation; shim-court: injecting an undeclared route must flip
  the court to FAIL (non-vacuity).
- **G-08f (regen check)**: `just posh-regen-check` runs ggen sync and `diff -r` (or sha256)
  against checked-in outputs, fail-closed, with a shim-court proving hand-edit detection.
- **G-08g (compile gate)**: fix or allowlist the `EgressRouter` warning so
  `mix compile --warnings-as-errors` exits 0 under the pinned Elixir.

## Verification ladder (executed this session)

- `ls` pack tree: ontology/shapes/queries/templates/examples/generated all present; 655 lines total.
- `grep` individuals: 3 IngressRoute, 3 Turnstile, 3 Receipt individuals.
- `go build ./...` in posh/: exit 0 (adapter package compiles, unimported).
- `mix compile` (Elixir 1.20.4): 3 pipeline beams present in `_build/dev/lib/smalt/ebin`;
  `--warnings-as-errors` fails on pre-existing EgressRouter warning.
- `diff` deployed vs pack `generated/`: all 7 files byte-identical (as-of 2026-10-30; unenforced).
- Greps: 0 references to generated dispatcher/ops outside `internal/adapter`; 0 references to
  `Smalt.Posh.Pipeline` outside the generated files; 0 SHACL-runtime hits in `lib/smalt/posh/`;
  0 regen/drift gates in justfile/Makefiles.
