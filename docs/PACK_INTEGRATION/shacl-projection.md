# SHACL Projection — Pack Integration

Source pack: `ggen-marketplace/packs/shacl-projection-pack` v0.2.0
(shared, target-agnostic SHACL-shape-driven projection law; zero domain
individuals).

Integration surface (new files only; the admission gate
`lib/smalt/graphlaw/validator.ex` is untouched):

* `lib/smalt/graphlaw/shacl_projection.ex` — `Smalt.GraphLaw.SHACLProjection`
* `test/shacl_projection_test.exs`
* this document

## What the pack's law says

Every projected artifact is bound to its source `sh:NodeShape`
(`sp:derivedFromShape`); fields come only from real `sh:PropertyShape`s
(never fabricated); a field carries exactly one value kind (primitive
`sh:datatype` or nested `sh:node`); primitive datatypes are bounded to
`xsd:string`, `xsd:boolean`, `xsd:integer|xsd:long`, and
`xsd:decimal|xsd:float|xsd:double`. Names are admitted source facts and are
echoed, never synthesized.

## Consumer adaptation (disclosed)

Smalt's shapes file (`priv/shacl/smalt-shapes.ttl`) exercises a narrower
subset of the pack vocabulary, so the smalt projection carries these
differences:

* **No `sh:datatype` is declared anywhere in the TTL.** Pack law maps
  primitive datatypes to JSON types; here no field schema emits a `type`
  keyword — projection is presence-only (`required` + the shape's
  `sh:message` as the field `description`). The datatype mapping
  (`string -> "string"`, `integer -> "integer"`, `boolean -> "boolean"`)
  is implemented and tested via the checker contract, so a future
  `sh:datatype` in the TTL flows through unchanged.
* **No `sp:collection`/`sp:nullable` metadata** occurs in smalt's TTL and
  is not emitted.
* **`className` is the shape's `sh:targetClass` local name** (e.g.
  `smalt:VNet` -> `"VNet"`), which is exactly the pack's
  "supplied by the consumer graph" rule — smalt's TTL supplies it via
  `sh:targetClass`.
* **Nested `sh:node`** does not occur in smalt's shapes; not projected.
* **No ggen sync target runs for smalt** (targets.toml declares
  `["ts", "json-schema"]`; only the JSON-Schema target is consumed here,
  projected in Elixir from the same parsed shapes the validator uses, not
  via a template). The two `ggen_igniter`-style determinism properties are
  preserved: sorted defs/properties/required, byte-identical output across
  runs (asserted in tests).

The binding law is honored: projections are re-derived at COMPILE time from
the same `Smalt.GraphLaw.Validator.ShapeFile.parse!` output the admission
gate uses (`@external_resource` on the TTL in both modules), so the
projection and the gate cannot drift — a shapes-file edit recompiles both.

## Projection surface

`Smalt.GraphLaw.SHACLProjection`

* `shapes/0` — parsed shapes (identity with `Validator.shapes/0`).
* `json_schema/0` — `%{"$schema" => draft 2020-12, "$defs" => %{class =>
  schema}}`. Each def: `type: "object"`, `properties` (one entry per
  declared property, `description` = `sh:message`), `required` (paths with
  `minCount >= 1`, sorted).
* `json_schema_json/0` — byte-stable pretty encoding (sorted keys, sorted
  lists). Two runs are byte-identical; decodes to exactly `json_schema/0`.
* `docs_markdown/0` — human-readable documentation: one `## <ShapeName>`
  section per shape with target class, `closed` flag, and every declared
  property (path, min/max count, datatype, message). Covers all 11 shapes
  in the TTL, including `NsgShape` (no properties).

The JSON-Schema form is intended for SDK courts' client-side validation
(the smalt-side admission gate remains `Smalt.GraphLaw.Validator`).

## Verification

`mix test test/shacl_projection_test.exs` (13 tests) plus the canary
`mix test test/smalt_graphlaw_validator_test.exs` — validator untouched,
both green. Real-collaborator courts, no mocks:

* shapes identity between projection, gate, and a fresh parse of the TTL.
* coverage: every shape and every property appears in the Markdown doc and
  in `$defs`.
* semantics: a tiny stdlib JSON-Schema checker (object/required/properties/
  type/description subset) accepts a conforming VNet payload, rejects a
  payload missing `addressPrefixes` / `location`, admits extra keys
  (shapes are `sh:closed false`), admits anything against the
  property-less `Nsg` def, rejects a non-map payload against an object
  schema, and admits any value against a description-only field schema
  (the disclosed no-datatype adaptation).
* determinism: `json_schema_json/0` and `docs_markdown/0` byte-identical
  across runs; `json_schema_json/0` round-trips through `Jason`.

## Receipt

* Date: 2026-10-14
* Subject: smalt working tree, files
  `lib/smalt/graphlaw/shacl_projection.ex`,
  `test/shacl_projection_test.exs`,
  `docs/PACK_INTEGRATION/shacl-projection.md` (no git commit per lane
  contract).
* Commands: `mix test test/shacl_projection_test.exs` — `13 tests, 0
  failures`; `mix test test/shacl_projection_test.exs
  test/smalt_graphlaw_validator_test.exs` — `49 tests, 0 failures`.
* Hand-adapted vs generated: all three files hand-written in Elixir/Markdown
  from the pack law (no ggen target for `.ex` consumers); disclosed above.
* Known limits: projection covers only the SHACL subset smalt's TTL uses;
  typed-value rejection paths are implemented but not exercised by real
  TTL data (no `sh:datatype` present).
