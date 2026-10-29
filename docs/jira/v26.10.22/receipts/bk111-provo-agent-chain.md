# BK-111 — GAP-6a PROV-O Agent chain (andon + ocel_ndjson)

**Standing: ALIVE** — all three court legs pass on the real emitters, tamper
legs refuse tampered leaves, zero warnings attributable to the diff.
Context: solo
Date: 2026-10-21
Subject: /Users/sac/smalt @ main (uncommitted worktree, BK-111 lane, MIX_BUILD_ROOT=_build-bk111)
Closes the andon + ocel_ndjson halves of GAP-6a
(docs/jira/v26.10.22/receipts/w3ca-conformance-census.md). The pplan
half (`lib/smalt/pplan/receipt_engine.ex`) is NOT in this lane's
ownership and remains MISSING there.

## Diffs

- `lib/smalt/powl2/andon.ex`
  - receipt gains `:agent` (opt `:agent`, default
    `urn:smalt:agent:<session>` — neutral, domain-blind).
  - `ntriples/1`: +3 lines — agent `rdf:type prov:Agent`,
    Activity `prov:wasAssociatedWith` Agent, Entity `prov:wasAttributedTo`
    Agent (7→10 lines per leaf).
  - `json_ld/2`: gains `prov:wasAssociatedWith`, `prov:wasAttributedTo`,
    and the typed node `andon:agent` `{"@id", "@type": "prov:Agent"}`.
    `prov:wasInvalidatedBy` (urn:smalt:actor) unchanged.
  - new `verify_ntriples/1`: fail-closed chain verifier, `:ok` only with
    the full Entity/Activity/Agent type set + the three chain edges;
    `{:error, missing}` otherwise.
- `lib/smalt/telemetry/ocel_ndjson.ex`
  - `append/3` opt `:agent`: injects the agent as an `eo:Agent` object
    (PROV-O `prov:Agent` mapped onto OCEL 2.0 object types, per the
    existing conventions) + a `prov:wasAssociatedWith` relationship
    (existing `objectId`/`qualifier` shape), idempotent.
  - new `agent_object/1` / `agent_relationship/1` public helpers.
  - new `agent_chain_violations/1` over an assembled document: any
    `prov:wasAssociatedWith` targeting a missing or non-`eo:Agent` object
    is a typed violation; `[]` = clean.
- `lib/smalt/powl2/andon_wire.ex` — compile-freeze disclosure: NOT owned by
  this lane, minimal unblock fix applied under the same-checkout SLA: its
  `error_map/1` called `Andon.json_ld` with an agent-less map, which would
  have raised KeyError at runtime after this diff. Fix: pass the
  session-derived default agent (`urn:smalt:agent:<session>`), honoring a
  `:agent` already present on the wire receipt. Named in this receipt per
  the disclosure law (BK-111 owns andon.ex/ocel_ndjson.ex + tests).
- `test/internal/powl2_andon_court.exs` — line-count 7→10, index-shifted
  assertions, GAP-6a chain leg, tamper leg (drop any one of the six chain
  terms → `verify_ntriples` errors), `:agent` override leg, json_ld chain
  leg. 10/10 pass.
- `test/integration/ocel_ndjson_agent_court_test.exs` (new) — real
  `append/3` to real on-disk NDJSON in a unique per-test tmp dir, real
  `read_document/1` round-trip, idempotence leg, tamper leg (strip the
  eo:Agent object from the on-disk bytes → assembly fails with typed
  violations; wrong-type leg → agent_chain_violations names the breach).
  4/4 pass.

## Court outputs

```
$ export PATH="$HOME/.asdf/installs/elixir/1.20.4-otp-29/bin:$PATH"
$ MIX_BUILD_ROOT=_build-bk111 mix test test/internal/powl2_andon_court.exs \
    test/internal/powl2_andon_wire_court.exs \
    test/integration/ocel_ndjson_agent_court_test.exs
...
Finished in 0.07 seconds (0.07s async, 0.00s sync)
Result: 20 passed   (exit 0)
```

Andon court 10/10, AndonWire court 6/6, OcelNdjson agent court 4/4.
Zero compiler/type warnings attributable to the diff files (the remaining
lib-wide warnings — law_compiler read_block, ash_r2rml dep, seal_failed —
are pre-existing, visible in the prior tick commits).

Pre-existing (session-introduced? no): `mix test
test/internal/internal_tier_census_test.exs` currently returns 5/6 — the
observables-allowlist leg fails on `ja15_error_logger_court_test.exs`
referencing `Smalt.Ja15.RefusalTelemetryHandler` /
`Smalt.DataPlane.BlobError`, neither allowlisted. Both hits are in
another lane's in-flight file; no BK-111 file trips any census leg
(population fence incl. test/internal unchanged — the new court lives in
test/integration, outside the fence).

## Falsifier status

- Census falsifier: "any emitted PROV-O N-Triples block contains a
  prov:Activity with no wasAssociatedWith edge to a typed prov:Agent" —
  REFUTED for andon + ocel_ndjson emitters (every leaf now carries the
  chain; verify_ntriples/agent_chain_violations refuse chain-less leaves).
- pplan emitter still fails the falsifier (out of lane scope).
