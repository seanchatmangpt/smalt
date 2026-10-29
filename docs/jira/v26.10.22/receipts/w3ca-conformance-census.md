# W3C-A Conformance Census — RDF-star / RDFC-1.0 / PROV-O

Standing: PARTIAL_ALIVE — measured, not assumed. Census only; no fixes implemented.
Context: solo
Date: 2026-10-21
Subject: /Users/sac/smalt @ main (uncommitted worktree) + /Users/sac/graphlaw @ main (read-only)

---

## Row 1 — RDF 1.2 / RDF-star (triple terms)

**Engine inventory (measured):**
- graphlaw hash path: purrdf 2.0.2 (crates.io, pinned `=2.0.2`), called directly from
  `/Users/sac/graphlaw/src/law.rs:733-748` (`LawState::from_dataset` →
  `purrdf::try_canonicalize` → blake3 over canonical N-Quads string).
- smalt Elixir side: `rdf` 3.0.1 + `json_ld` + `sparql` are mix deps
  (`/Users/sac/smalt/mix.lock:34,52`), but `grep -rn "RDF\." /Users/sac/smalt/lib`
  returns ZERO hits — the Elixir RDF libs are dep-only, dead code on the emission
  path. powl2 emits hand-rolled N-Triples strings (`powl2/andon.ex:159-181`,
  `pplan/receipt_engine.ex:245-276`).

**Probe 1 (purrdf, subject position) — ACCEPT:**
```
$ /tmp/w3ca-probe (cargo project, purrdf "=2.0.2", build 51.5s, run above)
input:  @prefix ex: <http://ex/> . ex:alice ex:says << ex:bob ex:age 40 >> .
output: <http://ex/alice> <http://ex/says> _:gts_00000000000000000000000000 .
        _:gts_... <http://www.w3.org/1999/02/22-rdf-syntax-ns#reifies> <<( <http://ex/bob> <http://ex/age> "40"^^<...#integer> )>> .
```
Object position: ACCEPT (same lowering). Quoted triples are lowered to a reifies
blank node + `rdf:reifies` reified quad. Canonical output uses the purrdf-private
predicate `<urn:purrdf:rdfc:reifies>` (P3 transcript below) — spec-adjacent, not
RDFC-1.0-of-triple-terms (RDFC-1.0 is quad-only by spec; the lowering is a typed
divergence, not a parse gap).

**Probe 1-EX (RDF.ex 3.0.1, smalt deps, object position) — ACCEPT:**
```
$ MIX_BUILD_ROOT=_build-w3ca mix run --no-start -e 'RDF.Turtle.Decoder.decode(...)'
Elixir 1.20.4-otp-29
ACCEPT: [{~I<http://ex/alice>, ~I<http://ex/says>, {~I<http://ex/bob>, ...}}]
```
RDF.ex 3.0.1 parses `<< >>` in object position (returns a triple term as the
object tuple). Subject-position support ships as `RDF.Star.*` modules in deps.

**Standing:** PARTIAL_ALIVE — Both engines on the real hash path parse `<< s p o >>`.
GAP-1a (typed divergence, not a parse gap): purrdf lowers triple terms to a reifies
blank node before canonicalizing, and the canonical N-Quads uses the purrdf-private
predicate `<urn:purrdf:rdfc:reifies>` (the serializer emits the standard
`rdf:reifies`). Close condition: purrdf's canonical form emits RDF 1.2 triple-term
syntax end-to-end, cross-checked against the W3C RDF-star semantics test suite.
Falsifier: re-parse a purrdf canonical N-Quads doc containing
`<urn:purrdf:rdfc:reifies>` with a standard RDF 1.2 parser — the IRI is a private
predicate no standard parser binds to the reifies relation, so a canonical form that
round-trips byte-exactly through a standard parser is the pass state; until then the
digest is defined only inside the purrdf identity universe.

## Row 4 — RDFC-1.0 canonicalization

**Implementation location (measured):** canonicalization IS on the hash path.
`/Users/sac/graphlaw/src/law.rs:733-748`: `LawState::from_dataset` runs
`purrdf::try_canonicalize(&dataset)` and digests the canonical N-Quads with blake3.
Raw bytes are NOT hashed.

**Probe 2 (initial run had a probe-authoring bug — first pair was NOT isomorphic;
superseded by Probe 2-fixed):** isomorphic blank-node graphs, different labels +
different line order, parsed as turtle:
```
A: _:b1 name "x" . _:b2 name "y" . _:b2 knows _:b1 .
B: _:z2 name "x" . _:z9 name "y" . _:z9 knows _:z2 .
identical: true  (byte-identical canonical N-Quads)
```
**Probe 4 (same pair as N-Triples):** identical: true — cross-dialect bnode identity
confirmed at the purrdf layer.

**LawState-level receipt (the real hash path):** graphlaw's own court,
`/Users/sac/graphlaw/tests/canonical_cross_dialect.rs`, run 2026-10-21:
```
$ cargo test --test canonical_cross_dialect   (in /Users/sac/graphlaw, no file changes)
running 6 tests
test n3_is_refused_unsupported_for_canonical ... ok
test nonvacuity_one_quad_perturbation_moves_id ... ok
test dataset_court_named_graph_differs_from_default_graph (named vs default graph MUST differ) ... ok
test dataset_court_named_graph_id_matches_across_trig_and_nquads ... ok
test blank_node_court_relabeling_and_cross_dialect_id ... ok
test graph_court_pure_graph_id_identical_across_dialects (turtle/ntriples/nquads/trig/rdf-xml/json-ld) ... ok

test result: ok. 6 passed; 0 failed
```

**Standing: ALIVE (measured).** Isomorphic blank-node graphs → byte-identical
canonical N-Quads → identical blake3 state id. Named-vs-default graph
distinguished. One-quad perturbation moves the id (non-vacuous court).

**GAP-4a (typed):** RDF.ex ships a real RDFC-1.0 implementation
(`/Users/sac/smalt/deps/rdf/lib/rdf/canonicalization/` — self-described "standard RDF
Dataset Canonicalization Algorithm", W3C rdf-canon, with HNDQ call-limit guard), but
`grep -rn "RDF.Canonicalization" /Users/sac/smalt/lib` returns ZERO hits — smalt's Elixir
side never canonicalizes RDF before hashing. This is only a latent gap (smalt has no
Elixir-side RDF hash path today; nothing hashes non-canonical RDF), typed so the gap
cannot be silently crossed: **close condition: any future Elixir-side RDF digest must
route through RDF.Canonicalization (or graphlaw) — a digest of non-canonical RDF bytes
is the forbidden state.** Falsifier: any Elixir code path that hashes RDF serialization
bytes without `RDF.Canonicalization.canonicalize/2` or a graphlaw canonical id.

## Row 6 — PROV-O / PROV-DM chain coverage

**Emission surface (measured):** `grep -rn "prov#" /Users/sac/smalt/lib` → exactly
two emitters (everything else matching "prov" is substring noise: approve/provide).

**Per-frame-class table:**

| Frame class | Module | prov:Entity | prov:Activity | prov:Agent | wasGeneratedBy | wasInvalidatedBy | wasAssociatedWith | wasAttributedTo | wasDerivedFrom | prov:value | time | p-plan:correspondsToStep |
|---|---|---|---|---|---|---|---|---|---|---|---|---|
| ANDON refusal receipt | `lib/smalt/powl2/andon.ex` ntriples/1 (lines 126-141) | Y | Y | **MISSING** | N | Y | **MISSING** | **MISSING** | N | Y (hexBinary digest) | endedAtTime Y; atTime JSON-LD only | N |
| P-PLAN step receipt | `lib/smalt/pplan/receipt_engine.ex` ntriples/2 (lines 245-276) | Y | Y | **MISSING** | Y | N | **MISSING** | **MISSING** | Y | Y (hexBinary delta_hash) | **MISSING (no time relations)** | Y |
| OCEL event line | `lib/smalt/telemetry/ocel_ndjson.ex` append/3 | — | — | — | — | — | — | — | — | — | — | — |

OcelNdjson emits ZERO PROV-O terms — pure OCEL 2.0 vocabulary
(`ocel:eventTypes/objectTypes/events/objects`), no PROV-O mapping layer. The
W3C-FORMALIZATION row 6 claim "OcelNdjson OCEL 2.0" is accurate as OCEL but
contributes nothing to PROV-O chain coverage.

**Standing:** PARTIAL_ALIVE
- Covered: Entity/Activity typing, wasGeneratedBy (pplan), wasInvalidatedBy (andon),
  wasDerivedFrom (step-chain threading), prov:value hexBinary digests,
  endedAtTime (andon), p-plan:correspondsToStep (pplan).
- **Agent-chain MISSING everywhere**: no prov:Agent, no wasAssociatedWith, no
  wasAttributedTo in any emitter. A PROV-O chain per PROV-DM requires Agent +
  wasAssociatedWith (activity↔agent); today the provenance chains terminate in
  activities with no responsible-agent edge. Only agent-shaped term is the
  andon JSON-LD `prov:wasInvalidatedBy` pointing at `urn:smalt:actor:...` (an
  untyped IRI, not a typed prov:Agent).
- Time relations partial: andon has endedAtTime; pplan has NONE (step receipts
  are time-free — the ts lives in the map, not the N-Triples).
- graphlaw ships `ontologies/core/prov-o.ttl` + process-conformance SHACL shapes
  but emits no prov: terms in src (grep: zero hits).

**GAP-6a (typed):** Agent chain (Agent/wasAssociatedWith/wasAttributedTo) missing in
all PROV-O emitters.
Close condition: andon + pplan emitters type the session/actor IRI as prov:Agent and
emit wasAssociatedWith from each Activity; W3C-FORMALIZATION row 6 flips to ALIVE
when a court round-trips the emitted N-Triples through a PROV-O validator.
Falsifier: any emitted PROV-O N-Triples block contains a prov:Activity with no
wasAssociatedWith edge to a typed prov:Agent — today 100% of emitters fail this.

---

## Probe environment receipts

- purrdf probe: /tmp/w3ca-probe (cargo, purrdf "=2.0.2" from crates.io — the exact
  pinned engine), compiled 51.5s, run 2026-10-21.
- graphlaw court run: `cargo test --test canonical_cross_dialect` in
  /Users/sac/graphlaw — 6/6 pass, no file changes, no branch change.
- RDF.ex probe: smalt deps, `MIX_BUILD_ROOT=_build-w3ca` (lane build root; delete at
  integration), Elixir 1.20.4-otp-29 via asdf, `mix run --no-start`.
- Probe-authoring correction disclosed: the FIRST P2 pair was non-isomorphic (knower
  had different name literals across the pair), so "identical: false" was the CORRECT
  answer for those inputs. All standing claims above rest on the FIXED pair.
