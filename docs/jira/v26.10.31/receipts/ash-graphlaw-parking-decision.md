# Decision Receipt — ash_graphlaw Dependency Parking (P4 Unit 6)
Standing: UNVERIFIED

- **Subject**: smalt's optional `:ash_graphlaw` dependency (mix.exs) and the skip-gated
  `graphlaw_shacl_admission_test.exs`.
- **Standing**: DECIDED-PARKED.
- **Context correction**: P4's Unit 6 was parked pending "lane 8's ontology fix" — no such
  lane exists in this wave. This receipt supersedes that parking reference and records the
  ruling on the merits.

## RULING

The optional dependency **stays**: `only: [:dev, :test], optional: true` — cost near zero
(no runtime surface, no prod footprint).

`graphlaw_shacl_admission_test.exs` **keeps its skip-gate**.

## Close condition

The canonical-ontology meta-shape fix landing **upstream in ash_graphlaw**. At that point the
dependency can be removed in one commit:

- the `mix.exs` dep line,
- the `mix.lock` entry,
- the `docs/THIRD_PARTY.md` row.

Gate: the `validator.ex` guard stays (it is load-bearing for the non-graphlaw path and must
survive the dependency removal).

## Disposition of smalt mix.lock

`git status` at receipt time shows `mix.lock` clean — C6's lane already landed without
leaving it dirty. No mix.lock action required; no P4 U1 verify-then-commit needed.
