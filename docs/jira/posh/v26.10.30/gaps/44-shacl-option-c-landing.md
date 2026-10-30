# 44 SHACL Option C landing: thin runtime validator over the used SHACL subset

Status: **ALIVE** — validator live in the admission path, tests green, bench
recorded (2026-10-30, lane 44 of 16, canonical checkout /Users/sac/smalt).

Closes G32 (`docs/jira/gaps` not used; canonical:
`docs/jira/posh/v26.10.30/gaps/32-shacl-runtime-decision.md` §3 recommendation:
Option C). B's compile-time gate retained as first half; C adds the per-frame
runtime gate.

## 1. What landed

New `lib/smalt/posh/ingress/shape_validator.ex` —
`Smalt.Posh.Ingress.ShapeValidator` (+ `.TTL` parser, `UnsupportedConstraint`,
`ParseError`):

* compile-time parse of `ggen-marketplace/packs/posh/shapes/ingress.ttl`
  (`@external_resource`; shape edits recompile), A-box individuals +
  route→op bindings compiled from `ontology/routes.ttl` +
  `examples/posh_instance.ttl`. Public: `shapes/0`, `individuals/0`,
  `route_ops/0`, `ingress_route_shape/0`, `admission_policy/0`,
  `shape_spec/1`, `validate/2`, `violations/2`.
* `validate/2` enforces the G32 subset {sh:minCount, sh:maxCount,
  sh:closed, sh:class} per frame: minCount-required keys, maxCount-0 ban
  (Law 2), closed extra-key refusals, class membership against compiled
  Turnstile/Sink A-box (empty compiled set refuses every value —
  fail-closed).
* fail-closed shape resolution: unknown shape IRI falls back to every shape
  targeting posh:IngressRoute; G26 lane 39's `ArmRequestShape` (open Delta
  shape) resolves BY NAME and admits raw JSON-object deltas (G26's witnessed
  fence-court 400 fix is preserved — no regression).
* fail-closed ggen-sync guard (deliverable 3, in-repo half; ggen-side check
  out of reach this wave): any constraint keyword outside
  {path,minCount,maxCount,class,closed} + KD tolerances {node,datatype,
  message,ignoredProperties,seeAlso,targetClass} raises
  `UnsupportedConstraint` at BUILD time. Non-falsifiable claim refused:
  ggen-side refusal of unsupported keywords is NOT implemented ggen-side —
  the guard is the Elixir compile-time allowlist raise. Close condition:
  a ggen.toml-level / pack-lint shapes gate refusing sh:pattern & co.
  before render. Non-vacuity court: ShapeValidatorTest
  "unsupported constraint keyword raises at parse time" (sh:pattern →
  raise naming the keyword).
* `Admission.compile/1` extended: optional per-route `:shape` spec
  (projected via `ShapeValidator.shape_spec/1`) enforced as ban/closed/
  class checks inside the compiled policy (`shape_violations/2`).
  `ShapeValidator.admission_policy/0` compiles every admitted route's op
  to a policy carrying required+types+shape (Laws 1+2 merged bans).
* Template `beam_pipeline.ex.tmpl`: stub `validate/2` replaced (template is
  the product — output regenerated, never hand-edited): validate/2 calls
  the real validator; `just posh-generate` rerun end-to-end (invariant gate
  → ggen sync → copy-out → compile gate, exit 0). All 15 generated pipeline
  modules call `ShapeValidator.validate/2` (grep witness: 15/15, pack
  generated/ tree included). Return shape `:ok | {:refused,
  {:shape_violation, %{violations: [...]}}}` flows through the generated
  admit/2 else-clause as a typed refusal.
* `Admission` containment hardening: `run_admission/4` now contains
  task-crash RAISES in the budget, not only :exit — without it a crashing
  validator re-raises through Task.await into the CALLER, defeating
  let-it-crash containment (witnessed: BadMapError escaped to the test
  process; also witnessed the concurrent ArgumentError-inline-fallback edit
  by another lane — disclosed below).

## 2. Tests (Chicago — real collaborators, final-state asserts, no doubles)

`test/smalt/posh/ingress/shape_validator_test.exs` (14 tests):

1. compiles the real ingress.ttl shapes (ArmRequestShape, IngressRouteShape,
   NoBypassShape, closed/targetClass/ignoredProperties asserted)
2. NoBypassShape carries the posh:emits ban (maxCount 0)
3. compiles Turnstile/Sink individuals from the real A-box (>=3 Turnstiles,
   sinkStarboard9443 member)
4. shape-conformant payload ADMITS
5. extra-key payload REFUSED (closed)
6. emits-on-route REFUSED (maxCount ban, Law 2)
7. missing required key REFUSED (minCount)
8. non-Turnstile admittedBy REFUSED (class)
9. hostile frames (non-map, atom-key) → typed refusals, never crash
10. unsupported constraint keyword (sh:pattern) raises at parse time —
    fail-closed guard non-vacuity
11. Admission policy compiled from the pack shapes enforces closed+ban+class
12. admission crash budget bounded under a crashing shape spec
    (BadMapError contained → {:refused, {:admission_crash,
    :restart_budget_exhausted}}; starts the real TaskSupervisor when the
    bare ExUnit boot lacks it)
13. generated pipeline module validate/2 is no longer an unconditional
    :ok stub (Arm_resource_group: conformant :ok, extra-key refused)
14. bench (tagged :bench, runs by default, correctness-only assert <1ms
    sanity): prints the honest numbers.

## 3. Bench receipt (honest numbers, 2026-10-30, Apple Silicon, BEAM dev)

    [L44-BENCH] validate/2 hot path p50=2us p99=4us (CTQ <10us, n=20000)
    [L44-BENCH] Admission.validate_task p50=2us p99=4us (n=500)

validate/2 p99 = 4 µs — UNDER the 10 µs Intake Ingress Jitter CTQ
(charter-master.md:53). G32 §2's design-bound estimate is now measured.
The validate_task number is the supervised Task path; treat it as
order-of-magnitude corroboration, not a p99 court (n=500, warm loop).

## 4. Gates (real output this session)

    MIX_BUILD_ROOT=_build-l44 mix compile          → exit 0 (no warnings in lane files)
    just posh-generate                             → exit 0 ([POSH-GENERATE] synthesis complete)
    MIX_BUILD_ROOT=_build-l44 mix test test/smalt/posh → Result: 41 passed, exit 0

## 5. KD-POSH row (SDK-parity register text, G32 §4 verbatim — C landed)

    | KD-POSH-44 | posh frame admission | Generated `validate/2` enforces only the
    SHACL subset {sh:minCount, sh:maxCount, sh:closed, sh:class} projected into
    the compiled policy; full SHACL validation happens at generation time only
    (ggen refuses nonconforming graphs). Constraints outside the subset are
    refused at ggen-sync, never silently skipped. Evidence: shapes/ingress.ttl,
    lib/smalt/posh/pipeline/*.ex validate/2. Close: unsupported-constraint gate
    at sync + per-frame p99 bench <10 µs receipt. |

Amendment (honest delta from G32's text): "refused at ggen-sync" is currently
the Elixir compile-time allowlist raise (`UnsupportedConstraint`), not a
ggen-side gate; sh:node / sh:datatype are KD-registered tolerances (parsed,
recorded, NOT runtime-enforced). Unprotected surface (registered, not closed):
sh:pattern, sh:in, sh:node-lookups, sh:and/or/not, datatype refinements
beyond the Admission lattice.

## 6. Findings for other lanes (not repaired here — lane lease)

* `test/smalt/posh/turnstile_fence_court_test.exs` is FLAKY on the in-flight
  G26 surface: witnessed failing on two different tests across runs
  ("admitted mutating delta…" got 400 AdmissionRefused; "unreceipted… REFUSED"
  got 404) and passing on the final run (41/41). Shim-court style baseline:
  with my validator stubbed back to :ok the file still failed → NOT
  session-introduced by lane 44. Full-dir run order dependence suspected
  (per-test named EventLog servers + shared :smalt application env).
* Concurrent in-flight edit witnessed in
  `lib/smalt/posh/ingress/admission.ex` `run_admission/4` (ArgumentError →
  inline-validate fallback, comment "TaskSupervisor is not running … validate
  inline"): lane 44's additive change keeps that fallback first and adds a
  broadened `_other_exception -> retry` clause. Disclosed per the
  compile-freeze disclosure law; both lanes' laws hold together.

## 7. Manufacturing receipt (law-7)

* Subject: /Users/sac/smalt @ working tree (no commits made — coordinator
  owns transitions)
* Diff (lane 44 owned files):
  - NEW lib/smalt/posh/ingress/shape_validator.ex (~600 lines: TTL parser +
    validator + exceptions)
  - MOD lib/smalt/posh/ingress/admission.ex (shape spec type + compile + checks
    + raise containment)
  - MOD ggen-marketplace/packs/posh/templates/beam_pipeline.ex.tmpl (stub →
    real validate/2)
  - REGEN ggen-marketplace/packs/posh/generated/lib/smalt/posh/pipeline/*.ex +
    lib/smalt/posh/pipeline/*.ex (15 modules, via just posh-generate)
  - NEW test/smalt/posh/ingress/shape_validator_test.exs (14 tests incl. bench)
  - NEW docs/jira/posh/v26.10.30/gaps/44-shacl-option-c-landing.md (this file)
* Commands/exits: mix compile exit 0; just posh-generate exit 0;
  mix test test/smalt/posh → 41 passed, exit 0 (final run, this session)
* Verification ladder: compile → unit (14 lane tests) → dir gate (41 tests,
  includes real in-process Router→Admission→Settlement fence court) → bench
  (p50/p99 recorded). E2E/chaos/stress: not run this lane.
* Standing: ALIVE per §4 gates + bench; falsifier for future waves: a frame
  violating Laws 1/2 admitted by validate/2, or p99 > 10 µs.
* Replay: MIX_BUILD_ROOT=_build-l44 mix test test/smalt/posh
