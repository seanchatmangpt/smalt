# 00-azure-out-migration-charter

**Standing: DRAFT-DECISION-PENDING.** This document is a draft charter for
operator decision — it is NOT a decided record. Nothing in it authorizes
landing, code motion, or phase execution until the operator admits it.

Consolidation draft, assembled 2026-11-05 (lane L20, migration wave) on the
v26.10.31 charter pattern
(`/Users/sac/smalt/docs/jira/v26.10.31/00-charter.md`), restated from the
v26.10.31 decision record and current-tree law (smalt CLAUDE.md dialect law)
— not from session memory. Every phase below is UNVERIFIED / PLANNED until
a receipt proves execution.

## 1. Scope: what migrates vs stays

**Core stays BEAM (smalt, Elixir).** Per the v26.10.31 decision record's
SOVEREIGN list (F1–F8): GraphLaw admission + ontology ttl, turnstile/receipt
settlement, store/ETS state + supervision trees, ggen projection discipline,
courts, registry.ex generation path, ingress/egress turnstile supervision,
harness substrate-state assertions — none of this moves. smalt never grows a
per-vendor face; the core is a closed-world standards engine
(`priv/ontologies/public-cloud-core.ttl`, standards namespaces only,
`scripts/verify_public_cloud_ontology.py` zero-proprietary court).

**The Azure dialect layer migrates out of the BEAM core.** Dialect #1
(Azure/ARM, `posh/internal/dialect/azure` with armkv and kv7 sub-dialects)
and dialect #0 (STS wire face) leave the smalt/posh tree under this charter.
Where they land — the arcus-vs-posh membrane question — is the open decision
(§2).

Wire-compat pinions travel with the dialect: SASL ANONYMOUS only, sasl-outcome
descriptor 0x44, attach top-level <=14 arity tripwires, .NET-GUID lock-token
byte reordering, EH fixed partitions `["0","1"]`. These are load-bearing
byte-laws pinned by real-SDK censuses; any relocation must be byte-identical
and proved by a dialect wire court (SHIM-COURT R51 witness: a "cleaner"
lock-token layout caused 410 MESSAGE_LOCK_LOST).

## 2. The open decision: arcus vs posh as the dialect membrane

**Status: DRAFT-DECISION-PENDING.** The operator has not decided whether the
migrated Azure dialect layer lands in:

- **arcus** (`/Users/sac/arcus`, Go, zero-dependency law: `go.mod` declares
  no requires; three-zone law — SELECT / MANUFACTURE / OUT-OF-GENGEN zones;
  generated surface via ggen from `ontologies/arcus.ttl`) as a Go dialect
  membrane, or
- **posh** (the existing Go membrane in the smalt tree,
  `posh/internal/dialect/azure`), continuing the v26.10.31 arrangement.

**Candidate arguments (not adjudicated — operator decides):**

- arcus is already a zero-dependency Go module with a ggen projection
  discipline and golden byte-identity gates (`tests/goldens/verify.sh`,
  drift gate `written: []`); posh already hosts the dialect engine and the
  wire-proven surfaces. Moving to arcus re-homes the dialect under a
  separate governance boundary (independent repo, its own KD register at
  `arcus/KNOWN_DIVERGENCES.md`); staying on posh preserves the
  already-wire-proven layout with zero re-anchoring cost.
- The three-zone law cuts both ways: dialect code moving into arcus must
  classify into a zone; if the dialect engine is OUT-OF-GENGEN (hand-written
  hot path like A8/A9), it escapes ggen generation — or it must be modeled in
  `ontologies/arcus.ttl` and become a generated surface (fix the graph,
  re-run `ggen sync run`; never hand-patch generated files).
- posh is stateless-and-disposable (SPAF Rule 1, v26.10.31 charter §1 law 4);
  the accretion test applies to whichever membrane wins: any component that
  owns state or admission stops being a shim.

No falsifier has been run for either option. No work order is admitted for
either option. This charter does not decide.

## 3. Wave-1 evidence summary

Wave-1 evidence for this migration is THIN and mostly UNVERIFIED. What is
citable from disk today:

- The v26.10.31 decision record and charter are ALIVE on disk
  (`/Users/sac/smalt/docs/jira/v26.10.31/00-charter.md`, status line ALIVE;
  decision record at
  `docs/jira/posh/v26.10.31/00-unification-dialect-decision.md`).
- The smalt dialect law is resident in CLAUDE.md (dialect #0/#1 taxonomy,
  core proprietary-free court, 9443 cordon rule, KD dialect column
  CORE | AZURE-#1 | AZURE-#0 | POSH-MEMBRANE | CROSS).
- The 14-law wire census (7 NEUTRAL-CORE / 7 AZURE-DIALECT) is ALIVE as a
  census at `docs/jira/posh/v26.10.31/gaps/02-payload-laws-census.md`; the 7
  AZURE-DIALECT laws (L1, L3, L4, L6, L8b, L9, L12) are the ones that
  travel with the dialect layer under this migration.
- No wave-1 execution receipts exist under `docs/jira/v26.11.7/` — this
  charter is the first file in the window; prior-window
  `docs/jira/v26.11.6/` receipts concern Kafka/offset/BLAKE3 lanes, not
  dialect migration. All migration phases are UNVERIFIED.

Wave-2 obligations: before any landing, wave-2 must produce (a) a byte-census
of the dialect surfaces (routes, pinions, error codes) with sha256 pins,
(b) a membrane-comparison court (arcus vs posh) with a typed verdict the
operator can admit, and (c) a Byte-Identity Guard baseline (P0 freeze per
the v26.10.31 pattern, `receipts/p0-baseline-freeze.md` shape).

## 4. Constraints

1. **NOTICE hand-edit law.** `NOTICE.md` files are hand-edited legal
   instruments — never generated, never regen-fenced. The arcus NOTICE.md
   clean-room/trademark clause is drafted as a hand-edited file
   (`/Users/sac/arcus/NOTICE.md` (pending — see
   `docs/jira/v26.11.6/NOTICE-draft.md` in arcus), draft at
   `/Users/sac/arcus/docs/jira/v26.11.6/NOTICE-draft.md`). No generator,
   ggen pack, or `mix`/`make` recipe may own it; it never appears in a
   generated-artifacts table.
2. **Byte-identical KD pinions.** The five wire-compat pinions (SASL
   ANONYMOUS only; descriptor 0x44; attach top-level <=14 with locale
   fields omitted; .NET-GUID lock-token byte reordering; EH fixed
   partitions `["0","1"]`) are byte-laws pinned by real-SDK censuses.
   Relocation into whichever membrane wins must be byte-identical and
   proved by a dialect wire court (the `test/courts/court_wire.erl`
   pattern ported as a dialect wire court; SHIM-COURT R51 is the
   falsifier witness that "cleanup" regressions real handshakes).
3. **C1–C7 re-anchoring.** The migration re-anchors the seven consumer
   coupling points (C1–C7): SDK/CRC census legs, harness DIALECT-CONFORMANCE
   surfaces, KD register dialect column, receipt context law pins, wire
   court corpus, ggen pack namespace (`smalt.dev/posh/ns#` stays
   proprietary and OUT of the standards graph — inadmissible in
   `public-cloud-core.ttl`), and CLI profile endpoints. Each C1–C7 anchor
   must be re-pointed with a receipt; a re-anchor with no receipt is
   UNVERIFIED and blocks landing.
4. **9443 cordon.** Port 9443 (BEAM arm_port) must be cordoned BEFORE any
   new membrane binds it (port collision ambiguity BEAM router vs Go
   membrane). Cutover order is normative: cordon BEAM arm_port → verify
   quiet-check → then bind the new owner. A membrane binding 9443 while the
   BEAM arm_port is live is a REFUSED transition, not a failed one.

## 5. Sequencing (planned, not executed)

Phases follow the v26.10.31 P0–P4 pattern, each fenced by the Byte-Identity
Guard (harness tenant+version suites exit 0; terraform 0-drift plan exit 0;
smalt-side STS POST legs + sha256 of oidc_sts.ex/oidc_idp.ex unchanged).
All phases are PLANNED / UNVERIFIED in this draft.

- **P0** baseline freeze: sha256 pins of dialect surfaces, Go membrane
  binary, wire-court corpus hashes into `receipts/p0-baseline-freeze.md`.
- **P1** membrane decision record: the arcus-vs-posh court lands a typed
  verdict; operator admits or refuses. DRAFT-DECISION-PENDING until this
  closes.
- **P2** dialect extraction to the admitted membrane: byte-identical wire
  court across the full corpus; KD pinions proven byte-identical (§4.2).
  Rollback = delete the extracted package.
- **P3** C1–C7 re-anchoring with per-anchor receipts; 9443 cordon + bind
  under §4.4 order; KD register dialect column re-anchored.
- **P4** core-side strip evaluation: removal of the dialect layer from the
  smalt/posh tree is evaluation-only until P2/P3 receipts close. No landing
  without an admitted work order; UNSUPPORTED by default.

Input lane closure rule carries over: a phase whose input lanes are open is
BLOCKED, not failed.

## 6. Falsifiers

1. Membrane decision: a membrane choice that cannot name its own falsifier
   (e.g. "dialect #2 addable as TTL rows + one template pass with zero core
   edits" from the v26.10.31 design) is not admissible.
2. Pinion relocation: any pinion byte-law that flips a real-SDK census after
   relocation = migration FAIL (SHIM-COURT R51 pattern).
3. NOTICE: a NOTICE.md that becomes generator-owned or regen-fenced violates
   §4.1 — the constraint is the falsifier.
4. 9443 cordon: binding 9443 while BEAM arm_port holds it = REFUSED
   transition (typed, not a silent port conflict).

## 7. Status line

- This charter: **DRAFT-DECISION-PENDING** (written this session, lane L20,
  this Write, exit 0). Not a decided record.
- Arcus NOTICE draft: PARTIAL_ALIVE (draft written this session,
  `arcus/docs/jira/v26.11.6/NOTICE-draft.md`; the final hand-edited
  `/Users/sac/arcus/NOTICE.md` landing is a separate, receipted step).
- Wave-1 execution receipts: none exist — all phases UNVERIFIED.
- P0–P4: UNVERIFIED / PLANNED; P4 core-side strip: UNSUPPORTED by default.
