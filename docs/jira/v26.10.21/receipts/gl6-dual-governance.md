# GL-6 — dual governance court (same SHACL law, operational + analytical legs)

**Standing:** **ALIVE** (court green 11/11, exit 0, real execution on the pinned
OTP-29/Elixir 1.20.4-otp-29 toolchain)

Context: solo

Lane: GL-6 (writer, OTP-29). Subject:
`test/integration/graphlaw_dual_governance.exs`

## What landed

One SHACL law set compiled ONCE — a single predicate closure over
`Smalt.GraphLaw.Validator.validate_shape/2` with one shape map in the
Validator's parsed-shape format — governs both legs:

- **Operational leg**: the closure guards a WF-net transition (`:deploy`
  in a `Smalt.PetriNet` p0→submit→p1→deploy→p2→archive→p3 net) over live
  context. Every corpus event is attempted as a live binding; conforming
  context admits the firing, violating context refuses with the typed
  violations the law emitted.
- **Analytical leg**: the SAME closure instance (same anonymous-function
  object) filters the corpus re-read as a historical OCEL ledger; aggregate
  counts over conforming-only events are taken.
- **Divergence assert**: per-event verdict equality across legs on a mixed
  corpus (4 conforming / 5 violating spanning all 4 violation classes:
  minCount×location, minCount×name, datatype×replicas, datatype×window),
  plus per-event typed-violation (path, constraint) equality. The legs
  cannot diverge unless the shared closure is bypassed — proven by
  construction, and the construction is proven non-vacuous (both verdict
  classes fire on both legs).

## GL-2 note

GL-2 compiler ABSENT at dispatch (no `lib/smalt/graphlaw/compiler.ex`, no
GL-2 receipt) after the mandated 15-minute bounded poll. Per dispatch, the
predicate shape is written locally: `compile_law/0` in the court file is
the single compilation site and the ONLY seam to re-point when GL-2 lands —
the shape map is already in Validator's parsed format, so a GL-2
`compile/1` drops in unchanged.

## Commands + output

```
MIX_BUILD_ROOT=_build-gl6 mix compile
# (one transient compile-freeze window on another lane's in-flight
#  lib/smalt/powl2/executor.ex:186 run_guard/4; cured by its owner between
#  attempts — no edit from this lane)

MIX_BUILD_ROOT=_build-gl6 mix run --no-start test/integration/graphlaw_dual_governance.exs

== GL-6 dual governance court ==

law closure        : {:type, :local} {:arity, 1}
corpus             : 9 events (4 conforming / 5 violating, 4 violation classes)
operational ledger : 4 admitted / 5 refused
analytical ledger  : 4 conforming / 5 refused

  [PASS] law is a 1-arity function
  [PASS] corpus mixed (>=4 conforming, >=4 violating)
  [PASS] operational: all 9 verdicts present
  [PASS] operational: deploy transition structurally enabled
  [PASS] operational: admitted set == conforming set
  [PASS] operational: refused set == analytics refused set
  [PASS] no divergence on mixed corpus (9/9 events agree)
  [PASS] typed violations identical across legs (every event)
  [PASS] all 4 violation classes fired (minCount x2, datatype x2)
  [PASS] aggregate: 4 conforming, 5 refused, partition exact
  [PASS] law fails closed on a fresh unknown-shape event
COURT VERDICT: PASS (GL-6-dual-governance) — operational and analytical legs agree 9/9
EXIT=0
```

(One real defect was caught and fixed during the court's own run:
`violation_classes/1` initially built a set of constraint *lists* instead of
a set of constraint atoms — the court itself flagged it as a FAIL before the
fix. The divergence checks were green on the first run.)

## Falsifiers

- Introduce any divergence channel (e.g. re-point one leg at a freshly
  compiled law instead of the shared closure) and re-run: the
  "no divergence on mixed corpus" check must flip to FAIL.
- Any new violating-event class added to the corpus without a matching
  refusal in the operational ledger fails "aggregate: partition exact".

## Falsified / honest notes

- None remaining on the landed surface. The court file is a `.exs` runner
  (dispatch-named), not collected by plain `mix test`; it runs via the
  `mix run --no-start` command above.
