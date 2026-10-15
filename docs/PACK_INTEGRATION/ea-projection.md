# EA Projection — Admission Matrix (pack integration receipt)

Lane: EA-style admission projection. Canonical checkout: `~/smalt`. Date: 2026-10-14.

## Subject

`Smalt.Projection.Admission` — one typed record stream (the admission
matrix) composing all four smalt admission families into
`who / what / verdict / standing` rows, mounted read-side (no router or
producer edits anywhere in `lib/` outside the new `lib/smalt/projection/`
namespace).

## Pack lineage (prefix adaptation)

Source pack: `ggen-marketplace/packs/ea-projection-admission-pack`
(`ontology.ttl`, `pack.toml` v26.9.26, authority=NONE).

| pack term (`eap:`) | projected term |
|---|---|
| `eap:Standing` UNKNOWN | `:unknown` — refusal/denied verdicts |
| `eap:Standing` ADMITTED | `:admitted` — admits and admitted deviation records |
| `eap:Standing` CANDIDATE / QUALIFIED / ALIVE | reserved (`Admission.standings/0`) — not reachable from current smalt verdicts |
| `eap:exactSubject` | `record.subject` |
| `eap:sourceStanding`/`eap:claimsStanding` | `record.standing` |
| projection-matrix-compose `elixir-binding.ex.tmpl` projection map (subject/consumer/adapter/target_path) | record shape re-keyed to `family/subject/verdict/standing/code/timestamp` |

The packs expose no admission-record Elixir templates that fit the smalt
telemetry+Store composition directly (ea-projection-admission-pack ships
only RDF shapes + Python gates; projection-matrix-compose's only Elixir
template is the static `elixir-binding.ex.tmpl` binding stub). Per the
"where they fit" scope, the standing vocabulary and record shape were
adapted in-module instead of a `ggen_igniter sync` run; the render target
would have been outside this lane's owned files.

## Composition sources (read-side, producers untouched)

- `attach/0` — `:telemetry` handler on `[:smalt, :admit]` / `[:smalt, :refuse]`
  → one matrix row per event (family `:smalt_event`).
- `seed/3` — adapters over the REAL verdict tuples of
  `Smalt.GraphLaw.Validator` (`{:ok}` / `{:invalid, _}` / `{:refused, _}`),
  `Smalt.DataPlane.SKR.release/2` (`{:ok, 200, _}` / `{:error, s, body}`),
  `Smalt.Auth.Bearer.verify_bearer/1` (`:ok` / `{:refuse, code, reason}`),
  `Smalt.Ocel.DeviationAdmission.admit/2` (`{:ok, :conforms}` /
  `{:ok, id}` / `{:error, _}`).
- `from_store/1` — projects the durable deviation ledger
  (`tmp/ocel/deviations.jsonl`) into the matrix, idempotent per record id.

## Receipt

- Diff: `lib/smalt/projection/admission.ex` (new),
  `test/admission_projection_test.exs` (new),
  `docs/PACK_INTEGRATION/ea-projection.md` (new). No other files touched;
  no git commands run.
- Gate: `mix test test/admission_projection_test.exs` → **6 tests, 0 failures**
  (run three times; twice in an isolated `MIX_BUILD_ROOT=_build-laneproj`
  lane build root, which still exists at `~/smalt/_build-laneproj`
  — `rm` was permission-denied, coordinator should delete it at integration).
- Note: `Smalt.GraphLaw.Validator.validate_shape/2` admits with `{:ok}`
  (single-element tuple); the `:graphlaw` adapter accepts both `:ok` and
  `{:ok}`.
- Telemetry counter contract: `Telemetry.dump()` keys are
  `{{[:smalt, :admit] | [:smalt, :refuse], metadata} => n}` where
  `metadata.event` carries the head atom (verdict/code), not the event
  name — aggregation in the test groups by event name.
- Pre-existing (not session-introduced): intermittent compile breaks from
  other lanes' in-flight files (`telemetry/semconv/registry.ex`,
  `trust_profile.ex`, `ocel/revops/*.ex`, `AmqpDialect.ex`) during the run;
  owner lanes repaired them inside the compile-freeze SLA. Warnings in
  `messaging/amqp/connection.ex` are pre-existing.
