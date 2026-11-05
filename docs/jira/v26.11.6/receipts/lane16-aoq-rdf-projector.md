# Lane 16 — AoQ SchemaBindings + RdfProjector (v26.11.6)

Standing: ALIVE

## Landed

- `lib/smalt/aoq/schema_bindings.ex` (new): `{:aoq, :schema_bindings}`
  persistent_term snapshot — boot-only sealed write
  (`boot/1`, idempotent re-derivation is the only lawful mutation class),
  ONE drain-boundary read (`snapshot/1`), `binding/1`, optional unrouted
  `register_schema/2` hook (disclosed for the `eh_schema_registry.ex` owner;
  raises sealed-error pre/post-boot, never routed by this lane).
- `lib/smalt/aoq/rdf_projector.ex` (new): `project_batch/2` at the drain
  boundary — ONE `:persistent_term` read, ONE `admit_envelope/2` per batch
  on the REAL pinned GraphLaw wasm engine; blank-node event identity
  (content-addressed labels `_:f<epoch>_<seq>` / `_:s<sha256-prefix of guid>`,
  ZERO IRIs in instance data); dotted header terms exactly as landed by G2
  (`cimi:frame.magic` "AOQ1", `cimi:frame.version/epoch/sequence/type/flags/
  payloadLength/crc32`, `dcterms:identifier "epoch:seq"`,
  `prov:startedAtTime` `^^xsd:dateTime`, `prov:used` → typed
  `cimi:StreamSource` with guid in `dcterms:identifier` + `dcterms:title`);
  iolist-only emission, ONE flatten.
- `test/smalt/aoq/rdf_projector_court_test.exs` (new): 10 courts, all green.

## Namespace reconciliation (LANE-16 decision)

G2's PROV-only core graph stands as landed. The canonical TTL carries NO
OCEL terms (the zero-proprietary verifier rejects the ocel-standard
namespace); OCEL projection stays confined to the ggen projector side
(`crates/ggen-graph/src/ocel/projection.rs`). The original lane plan's
"OCEL 2.0 + verifier amendment" path is REJECTED; rationale: the verifier
is the admission kernel for the standards graph — amending it to admit a
vendor-neutral-but-nonstandard namespace weakens the closed-world law for
one lane's convenience. Rationale + falsifier live in the projector
moduledoc.

## Courts (10, real engine, no stubs)

1. empty batch → `{:refused, :aoq_batch_empty, %{}}`
2. unbound schema guid → exact `{:refused, :aoq_schema_unbound, %{schema_id}}`
3. engine-absent seam → `{:refused, :smalt_projector_engine_absent, %{dep: :ash_graphlaw}}`
   (via disclosed `:shacl_module` court seam)
4. golden vector: 2 records → 30 sorted triple terms == compile-time literal;
   emitted Turtle zero-IRI (no `<http` outside `@prefix` lines)
5. missing `prov:startedAtTime` → typed `:smalt_shacl_violation`
   (shape non-vacuity: the shape's `sh:minCount 1` refuses the mutation; the
   projector never pre-checks)
6. order invariance: same records, any order → same sorted triple multiset
7. document determinism: same records, same order → byte-identical Turtle
8. batch invariance: 1 batch of 2 == 2 batches of 1 (same triple multiset;
   sound under content-addressed blank-node labels + disjoint guids)
9. `SchemaBindings` sealed write + one-key snapshot
10. sh:closed load-bearing court (see non-vacuity below)

## SHIM-COURT non-vacuity (executed, witnessed)

Mutation: remove `sh:closed true ;` from `prov:StreamFrameShape` in
`priv/ontologies/public-cloud-core.ttl` (+ `SHIM-COURT` marker line).
Court flipped RED: exactly test 10 fails (9/10), the closed-dependent court
only. Restore: `cp` from byte-exact backup, sha256 re-verified:

    baseline  = 7167998269f1139cc6f107b9e799fa6935df77569311cf1f93b0899cde25ff84
    restored  = 7167998269f1139cc6f107b9e799fa6935df77569311cf1f93b0899cde25ff84

## FINDING (coordinator-relevant): G2 court test 5 does NOT depend on sh:closed

Under the same shim, G2's
`test/integration/graphlaw_canonical_shapes_court_test.exs` test 5
("out-of-vocabulary predicate refuses under sh:closed") STAYS GREEN — it is
not sh:closed-dependent. Root cause: the court's `@oov_frame` heredoc is
INDENTED; on that indented text the wasm engine's Turtle parse drops/mangles
the `a cimi:StreamSource` type declaration, so the OOV refusal is carried by
`ClassConstraintComponent` (prov:used → untyped source) in BOTH shim and
baseline. The same data at column 0 admits under the shim
(witnessed probe: `verdict=ok` with closed removed, col-0 text). G2's test 5
is therefore tautological w.r.t. its named constraint — worth a G2 follow-up
(de-indent the corpus or assert the component id).

## Constraints honored / disclosures

- tables.ex needed NO new key (bindings live in their own
  `{:aoq, :schema_bindings}` key); no edit to tables.ex, no edit to
  eh_schema_registry.ex (hook disclosed in SchemaBindings moduledoc).
- Shared seam: ONE AshGraphLaw Host, `ShaclAdmission.admit_envelope/2` at
  the drain boundary — same call chain as L9; my projector passes
  `shape_iri: "prov:StreamFrameShape"` and `[server: pid]` engine_opts;
  no Host code touched.
- Two shared-compile freezes during the lane (L1 `group_manager.ex`, L9
  `shacl_admission.ex` splice), ~12 min total; courts were staged via
  parse-checks during the freeze and run after it cleared. Courts run with
  `mix test --no-start` (test env boots only what they need) because the
  shared data plane was mid-flight; plain `mix test` works too when the
  tree boots.
- Batch-invariance court premise adjustment, disclosed in the test file:
  the original "1 batch vs 2 batches" form is unsound under positional
  blank-node labels; fixed by content-addressed labels (frame:
  epoch_seq, source: sha256-prefix of guid) — then both the 1-vs-2-batch
  and order-invariance forms are sound.

## Gate outputs (this session, real)

- `mix test test/smalt/aoq/rdf_projector_court_test.exs` → 10 passed
- `mix test test/integration/graphlaw_canonical_shapes_court_test.exs` → 5 passed
- `scripts/verify_public_cloud_ontology.py` → exit 0, "VERDICT: ALIVE [GREEN]"
- `mix compile` → exit 0, zero diagnostics for both new files

## Falsifiers

- Remove sh:closed → court 10 RED (executed, restored sha-exact).
- Remove started_at → court 5's refusal disappears (minCount owns it).
- Unbind a guid → court 2 refuses typed.

## Residuals

- `:shacl_module` opt is a disclosed court seam, not production surface.
- G2 test 5 tautology follow-up (not my lease; flagged above).

