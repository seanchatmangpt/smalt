# 32 SHACL Runtime Decision: shapes are generation-time-only; validate/2 is a stub

Status: PARTIAL — decision specified from on-disk evidence this session (smalt working
tree, posh pack, BEAM admission path re-read 2026-10-30); no executable court ran.
Decision record only; the chosen option's implementation is not landed.

Subjects (read this session):

- pack: `/Users/sac/smalt/ggen-marketplace/packs/posh/` (shapes/ingress.ttl,
  shapes/egress.ttl, ggen.toml, generated pipeline modules)
- BEAM admission: `/Users/sac/smalt/lib/smalt/posh/ingress/admission.ex`
- turnstile: `/Users/sac/smalt/lib/smalt/posh/turnstile.ex:26`
- generated stub: `/Users/sac/smalt/ggen-marketplace/packs/posh/generated/lib/smalt/
  posh/pipeline/arm.resource_group.ex:46` (identical stub in every generated pipeline
  module, mirrored into
  `/Users/sac/smalt/lib/smalt/posh/pipeline/*.ex`)
- prior art: `/Users/sac/smalt/lib/smalt/graphlaw/validator.ex` (compile-time shapes
  parser + runtime validator) and `lib/smalt/graphlaw/shacl_projection.ex` (projections
  derived from the same parsed shapes so projection and gate cannot drift)
- CTQ: `smalt/docs/jira/posh/v26.10.30/dfcharter/charter-master.md:53` — Intake Ingress
  Jitter < 10 µs; frame drop rate 0.000%.

## 1. Current state (what the code actually does)

- Shapes (`shapes/ingress.ttl`, `shapes/egress.ttl`) are consumed **only at generation
  time**. The ingress.ttl header states the law outright: "TRIZ Principle 10: validated
  by ggen prior to execution, not at runtime."
- The generated Elixir admission step is a stub: `def validate(_frame, _shape_iri),
  do: :ok` (arm.resource_group.ex:46, all pipeline modules). Every frame passes. The
  module docstring's claim "Admission: validate the frame against the route's SHACL
  shape" is **unbacked by the code** — prose overclaiming, fileable as-is.
- The real runtime gate is `Smalt.Posh.Ingress.Admission` (map-compiled policy:
  required_keys + a small type lattice `:string | :integer | :binary | :map | :list |
  {:one_of, _}`, admission.ex:32-58). It enforces key-presence and types, **not** SHACL
  semantics. No dependency on the shapes TTL at all.
- `ggen.toml` merges the A-box (`examples/posh_instance.ttl`) with the T-box and relies
  on ggen's conforming-graph precondition to render; there is no pyshacl invocation
  found in the pack or smalt scripts (grep for `pyshacl` across smalt: zero hits
  outside vendored pip deps). So the "validated at generation time" claim itself is
  only as strong as ggen's internal conformance check — noted, not audited here.

## 2. Options

### Option A — runtime SHACL at admission (full validator in the hot path)

Mechanics: call pyshacl as a subprocess per frame, or adopt a hex SHACL library.

- No mature SHACL validator exists in hex (the only real implementations are
  RDF/XML-graph-heavy ports; smalt deliberately hand-rolled a Turtle subset parser in
  `graphlaw/validator.ex` rather than depend on one — that choice is itself evidence).
- pyshacl per frame: CPython interpreter spawn (~30–80 ms) + rdflib graph parse
  (~50–500 ms for a small shapes+data graph) ≈ **10⁴–10⁵ µs** per frame. The CTQ
  budget is **< 10 µs jitter on the intake path**. Overrun is 4–5 orders of magnitude.
  Even a resident python worker amortizes spawn but still pays serialization + GIL +
  IPC per frame (tens of µs minimum, p99 unbounded) — still disqualifying, plus a
  Python runtime becomes a hard dependency of the hot path.
- Latency math alone disqualifies A for the intake path. Verdict: **rejected**.

### Option B — compile-time-only (register as KD divergence)

Mechanics: ggen refuses nonconforming graphs at sync time (already the de-facto
precondition per ggen.toml); runtime trusts the compiled policy structs and the stub
`validate/2` stays `:ok`, relabeled honestly.

- Enforcement point: the admission-policy compile (`Admission.compile/1` from the
  ggen-projected policy map) plus ggen's generation-time conformance gate.
- Leaves unprotected: **every runtime frame**. Conformance is a property of the
  ontology/pack at build time; nothing binds a producer's emitted frame to the shape.
  A producer bug (extra key, wrong arity on an optional, posh:emits-class bypass
  pattern from ingress.ttl Law 2) sails through admission and into the membrane.
  The closed-shape laws (Law 1 no-bypass, Law 2 emits-ban) are exactly the ones whose
  runtime violations are cheap to check and expensive to debug downstream.

### Option C — thin runtime validator over the used SHACL subset (recommended)

Mechanics: project the small constraint set actually used in the pack shapes —
`sh:minCount`, `sh:maxCount`, `sh:closed` + ignoredProperties, `sh:class` — into a
compiled shape struct at build time (from the same TTL ggen reads), and enforce it in
`validate/2` before admission.

- **Prior art already in-tree**: `Smalt.GraphLaw.Validator` parses shapes at compile
  time and enforces exactly minCount/maxCount/closed/datatype (validator.ex:120-266,
  including the KD-156 absent-minCount-is-optional semantics note). `SHACLProjection`
  derives projections from the *same* parsed shapes so projection and gate cannot
  drift (shacl_projection.ex moduledoc). Option C is that pattern applied to the posh
  pack; it is not a new mechanism.
- `Admission.compile/1` audit vs the shapes: it enforces required-key presence
  (≈ minCount≥1 for fixed keys) and a type lattice. It does **not** enforce maxCount
  (maps can't carry duplicate keys in JSON/Elixir maps — maxCount>1 is vacuous on map
  payloads, maxCount 0 as a *ban* (`posh:emits maxCount 0`, ingress.ttl Law 2) is NOT
  enforced), does not enforce `sh:closed` (extra keys admitted silently), and has no
  `sh:class` notion (the `posh:admittedBy` class constraint is unchecked). That is
  the audit gap: closed + ban + class are the three unprotected laws, and they include
  the no-bypass law — the pack's Law 1.
- Cost: the subset check is map-key membership + count + IRI-string comparison —
  single-digit µs on a small frame, compatible with the <10 µs CTQ (receipt pending;
  this is a design-bound estimate, not a measurement — the bench court is a close
  condition).

## 3. Recommendation

**Option C.** B's compile-time gate is retained as the first half (it is already
de-facto); C adds the thin runtime validator so the closed/ban/class laws hold on
frames, not just on the ontology. A is rejected on the latency math above.

- Unprotected by C (must be registered or fenced): any constraint outside
  {minCount, maxCount, closed, class} — `sh:pattern`, `sh:in`, `sh:node`, `sh:and/or/
  not`, datatype refinements beyond Admission's lattice. Guard: a ggen-time check that
  refuses any shape introducing an unsupported constraint keyword (loud missing-cell,
  not silent passthrough) — same fail-closed posture as Validator's
  `parse_datatype` unsupported-datatype raise (validator.ex:270).
- Close conditions: (1) bench receipt: p99 per-frame validate cost on the intake path,
  budget <10 µs; (2) stub replacement: `validate/2` no longer returns unconditional
  `:ok`; (3) mutation court: a frame violating Law 2 (route carrying `posh:emits`) is
  refused by the runtime validator.

## 4. KD-row text (for the SDK-parity register)

If C lands (preferred):

    | KD-nn | posh frame admission | Generated `validate/2` enforces only the
    SHACL subset {sh:minCount, sh:maxCount, sh:closed, sh:class} projected into the
    compiled policy; full SHACL validation happens at generation time only (ggen
    refuses nonconforming graphs). Constraints outside the subset are refused at
    ggen-sync, never silently skipped. Evidence: shapes/ingress.ttl,
    lib/smalt/posh/pipeline/*.ex validate/2. Close: unsupported-constraint gate at
    sync + per-frame p99 bench <10 µs receipt. |

If B only (fallback, honest label):

    | KD-nn | posh frame admission | SHACL shapes are enforced at generation time
    only; runtime `validate/2` is a no-op (`:ok`) and frames are trusted against the
    compiled policy map (required-keys + type lattice), not the SHACL shape. Closed/
    maxCount-0-ban/class constraints are unprotected at runtime. Evidence:
    arm.resource_group.ex:46; shapes/ingress.ttl. Close: thin projected validator
    (Option C) or explicit acceptance of unprotected-frame risk. |

## 5. Status vocabulary

- Decision: **specified** (this file).
- Implementation: **not landed** — `validate/2` remains `:ok` in every generated
  module as of this session's read.
- CTQ latency claim: design-bound estimate; the <10 µs figure is from
  charter-master.md:53; no bench receipt exists yet — **UNVERIFIED** until the bench
  court in §3 runs.
