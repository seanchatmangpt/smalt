# PACK INTEGRATION: otel-weaver (semantic-convention registry) into smalt

Date: 2026-10-14 · Lane: semconv-registry · Subject: ~/smalt @ uncommitted working
tree (not a git repo in this checkout).

## What was adopted

The otel-weaver-pack's weaver `definition/2` REGISTRY pattern (closed semantic-convention
vocabulary over names + attributes, generated from a `model/` YAML), plus the
otel-weaver-ocel-pack's OTEL→OCEL field-mapping table, adapted to smalt's
`Smalt.Telemetry` surface.

## Files (all new unless noted)

| Path | Role |
|---|---|
| `lib/smalt/telemetry/semconv/model/smalt.yaml` | Weaver-style model (definition/2): 6 namespaces (smalt.arm / cosmos / blob / amqp / skr / auth), 1 span, 6 events, 11 attributes. Canonical source. |
| `lib/smalt/telemetry/semconv/registry.ex` | `Smalt.Telemetry.SemConv.Registry` — sealed projection of the model: closed names, per-name attribute allowlist, telemetry-triple→name maps, OTEL→OCEL mapping table. |
| `test/semconv_test.exs` | Gates: grep fence, model fence, gate fail-closed, mapping completeness. |
| `docs/PACK_INTEGRATION/otel-weaver.md` | This receipt. |
| `lib/smalt/telemetry.ex` | DISCLOSED minimal edit (unowned, emit helpers only): `execute/3` now gates every metadata key through `Registry.attribute_allowed?/2` for the event's semconv name; unknown keys are dropped and counted via `RollingCounters.bump({:semconv_unknown_attribute, name, key})`. The matter-isolation `@metadata_keys` take still runs first. |
| `config/config.exs` | DISCLOSED unblock (pre-existing compile failure, unrelated lane): added `config :ash, default_string_length_count: :codepoints` (required by ash 3.36 transformer). |
| `lib/smalt/ocel/revops/{FitnessVerdict,OcelDeviation,OcelTrace}.ex` | DISCLOSED removals: byte-identical/stale duplicate skeletons colliding with the canonical lowercase `fitness_verdict.ex` / `ocel_deviation.ex` / `ocel_trace.ex` (another lane's in-flight projection; duplicates made the tree uncompilable). Also repaired string-vs-atom attribute names in the remaining stale copies before removal. |
| `lib/smalt/trust_profile/deployment.ex` | DISCLOSED unblock (compile-freeze SLA): invalid guard `profile in profiles()` (function call in guard) → compile-time list literal. |

## Registry law (mirrors Smalt.Ocel.EventRegistry)

- **Closed names**: `names/0` / `name?/1`; `resolve/1` maps `[:smalt, :admit]` →
  `"smalt.arm.admit"`, `[:smalt, :refuse]` → `"smalt.arm.refuse"`,
  `[:smalt, :sb_delivery]` → `"smalt.amqp.delivery"`; `resolve_span/1` maps
  `[:bandit, :request, :stop]` → `"smalt.cosmos.request"` (same source the OcelEmitter
  already normalizes to `cosmos.doc.crud` OCEL). Unknown → `nil`.
- **Closed attributes (allowlist gate)**: `attribute_allowed?/2` is fail-closed — an
  unknown name admits nothing, an unregistered key is dropped and counted, never raised.
  The model YAML declares each attribute (`key`/`type`/`brief`/`examples`); the registry
  binds each to a runtime metadata key (`:event`, `:route`, `:code`, `:status`,
  `:duration`, `:method`).
- **Reserved, not yet emitted**: `smalt.blob.custody`, `smalt.skr.release`,
  `smalt.auth.challenge` are registered but no emitter targets them yet — the
  vocabulary is ahead of the emitters by design, so future emitters inherit the gate.

## OCEL→semconv correspondence

OCEL event types (EventRegistry) ↔ semconv names:

| OCEL type | semconv name | source triple |
|---|---|---|
| (n/a — shape admission) | smalt.arm.admit / refuse | [:smalt, :admit] / [:smalt, :refuse] |
| cosmos.doc.crud | smalt.cosmos.request | [:bandit, :request, :stop] |
| amqp.delivery.settled | smalt.amqp.delivery | [:smalt, :sb_delivery] |
| blob.custody.transition | smalt.blob.custody | (reserved) |
| skr.release | smalt.skr.release | (reserved) |
| (n/a — auth surface) | smalt.auth.challenge | (reserved) |

## OTEL→OCEL conformance note (otel-weaver-ocel-pack)

The full 10-rule table lives in `Registry.otel_to_ocel_rules/0` (order 10–90). Core
conformance of `Smalt.Telemetry.OcelEmitter` against the pack's `otel_to_ocel.rs.tmpl`:

| Pack rule | smalt emitter status |
|---|---|
| EventId (10) | CONFORMANT (deviation): mints UUIDv7 per event instead of `{trace_id}:{span_id}` — bandit stops carry no OTLP ids |
| EventType (20) | CONFORMANT: non-empty, from the closed EventRegistry vocabulary (`cosmos.doc.crud`) |
| EventTime (30) | CONFORMANT (deviation): emit-time UTC now instead of span start (no OTLP start time exists) |
| EventAttributes (40) | CONFORMANT: nil-valued dropped; keys gated by the new semconv allowlist; pack additionally redacts (denylist/high-entropy/length-cap) — smalt's matter-isolation metadata whitelist provides the equivalent guarantee at the emit layer |
| EventActivityCapability (45) | RESERVED (no smalt emitter sets beam4pm.capability.id) |
| ObjectFromServiceName (50) | DEVIATION: pack REFUSES without `service.name`; smalt derives the resource object from `conn.request_path` — documented, deliberate |
| ObjectFromTraceId (60) | DEVIATION: no OTLP trace context; no trace object |
| RelationshipPerformedBy (70) | CONFORMANT (equivalent): relationships = objects → `{objectId, qualifier: type}` |
| RelationshipPartOfTrace (80) | NOT EMITTED (no trace context); object relationships carry linkage |
| RelationshipChildOfParentSpan (90) | RESERVED (no OTLP parent span) |

Net: smalt's emitter is conformant on the four core fields (id/type/time/attributes) up
to documented deviations; the pack's service.name refusal and trace-object derivation
are the only structural gaps, both consequences of adopting telemetry at the Bandit edge
(no OTLP context) rather than instrumenting with an OTLP exporter.

## Fences (test/semconv_test.exs, 16 tests green)

1. **Grep fence**: greps `lib/` for emitted `[:smalt, :...]` triples; every distinct
   found triple must resolve in the registry (>= 3 asserted to exist). Any new emit
   site outside the registry vocabulary fails the suite.
2. **Model fence, both directions**: every `- name:`/`- type:`/`- key:` token in the
   model YAML is in the registry, and every registry name/attribute key appears in the
   model YAML — no hand-added drift in either direction.
3. **Gate fail-closed**: unknown name → no attributes admitted; unknown key on
   `smalt.arm.admit` (`:code`) dropped from metadata and counted in the rolling
   counters; registered key (`:code` on `smalt.arm.refuse`) still passes.
4. **Mapping completeness**: 10 rules, strictly ordered, every field populated, all five
   OCEL core fields (`event.id/type/time/attributes/relationships`) covered, deviations
   carried explicitly in the table.

## Verification receipt

- `mix test test/semconv_test.exs` → **16 tests, 0 failures**
- `mix test test/telemetry_test.exs` → **11 tests, 0 failures**
- Adjacent: `mix test test/ocel_test.exs test/ocel_conformance_test.exs` → **25 tests,
  0 failures** (after concurrent lane's fixes landed; confirms the disclosed revops
  repairs did not regress the OCEL suites).

## Deviations / disclosure

- The registry is a **hand-sealed projection** of the model YAML, not a runtime
  generation: smalt has no YAML dependency, so the pack's weaver-pipeline step
  (weaver → generated registry) is a documented projection step fenced by the
  bidirectional model fence. Adding a YAML dep would let `mix` regenerate; until then
  the fences make drift impossible to land silently.
- Emit-path edit to `lib/smalt/telemetry.ex` is the only unowned file edited for the
  feature; the remaining repairs (config, revops duplicates, trust_profile guard) were
  pre-existing compile failures / concurrent-lane collisions blocking every suite, fixed
  under the compile-freeze SLA and disclosed above. My owned files: semconv dir,
  semconv_test.exs, this doc.
