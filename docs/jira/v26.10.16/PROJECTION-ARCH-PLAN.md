# PROJECTION-ARCH-PLAN — smalt × ggen projection architecture (v26.10.17 opening move)

**Status:** Plan (design decisions + wave execution). Wave status table: §1a (W1 LANDED, W2 lanes LANDED uncommitted, W3-W9 QUEUED). Engine law updated 2026-10-17: **one engine, no choice — graphlaw** (operator directive; 7/7 pack queries row-for-row vs the oxigraph reference, sparql + qlever deleted, ORDER BY post-sort workaround retired — ggen_igniter `b514bf5`).

**Sources:** 5 Explore surveys (E1 routes, E2 store, E3 scaffolds, E4 metadata, E5 blueprint) + the sjira bridge design.

## 0. Doctrine

Convert hand-written smalt code into **ontology-projected code**: rows in a closed vocabulary (`ontology.ttl`) are the only lawful way to add a projected artifact; templates render them; gates prove completeness; verify queries prove gates non-vacuous; replay tests prove byte-identity. Hand-written code survives only where genuinely singular (§6, residue doctrine).

### Design decisions

**D1 — Sequencing** (risk × ROI × dependency): metadata/low-risk first → structural mid → route macros high-ROI → sjira bridge last. ConfigKey and Canonical riders are zero-blast-radius and prove the replay-fence machinery before the store or router are touched. CascadeEdge depends on StoreTable; the sjira bridge depends on at least one proven code projection (shim-courts is the safest first code projection — outputs are test scaffolds, not production code). Route shells land after, because they delete arm lines and need priority-ordered macro emission.

**D2 — Where projections live:**
- **smalt-substrate-pack (extend):** StoreTable, CascadeEdge, HashChainLedger, ConfigKey, route-shell classes (ParentedChildRoute, EgTopicRoute, SpineRoute, AzapiAction, DefaultGetter), shim-court scaffold rows, KD-fence rows, corpus scaffold rows. All smalt-internal structure; the pack already owns the engine discipline, gates, verify, and the alias stanza.
- **New pack `smalt-jira-pack`:** sj:ProjectionSpec backend wiring, code-kind byte-fence classes (`sj:CodeKind` + byteFence property), per-order falsifier→gate mapping. Depends on the semantic-jira-pack vocabulary (`sj:Projection/ProjectionSpec/capabilityId/targetPack`) — stays a marketplace dependency, not vendored into substrate.
- **New pack `smalt-semconv-pack`:** semconv → pack projection. External-contract boundary; could fold into substrate if fewer packs preferred.
- **Canonical.write riders (not pack):** THIRD_PARTY, capabilities identity block, reference-doc grep-shaped sections. Elixir-native facts ride Canonical; ontological facts ride the pack.

**D3 — Migration law** (hand-written → projected, zero regression): the registry.ex precedent, mechanically:
1. Project alongside into a `_projected/` side dir (never over hand-written paths on first render).
2. Byte-compare rendered vs hand-written; iterate until byte-identical or an intentional documented delta. Byte-identity = the equivalence proof.
3. Land as DO-NOT-EDIT at the real path; delete the hand-written copy; commit both together.
4. Replay fence: subprocess ggen sync + byte-compare + pack.lock digest assertion.
5. Law-doc artifact-table row in `docs/explanation/ggen-projection-law.md`.

Route macros: behavioral equivalence instead of byte-compare — generate projected macros alongside hand-written inside arm_gateway/router.ex; replay fence asserts the generated section regenerates identically; delete hand-written macros **per family** after that family's court ladder is green and receipts are on file. Per-family, never big-bang.

**D3b — Route priority law:** macro emission order is **ontology-declared**: each route class carries a `smalt:priority` integer; the engine (graphlaw) honors ORDER BY natively, and the template sorts by (priority, canonical key). Specific routes get lower numbers than splats — the ordering becomes a pack fact, not an arm-code fact.

**D4 — sjira bridge:** a backend in sjira's existing backend system (`semantic_jira/execute.ex`), named `:projection`:
1. Resolve pack from `sj:targetPack` (pack.lock digest pinned)
2. Scope query by `sj:capabilityId` → single row → template (one WO ↔ one capability ↔ one row ↔ one render)
3. `Actuate.write_new_file!` at `sj:targetPath`
4. Post-render gates: the capability's gates/*.rq (≥1 row)
5. Falsifiers → gates: each WO falsifier becomes a verify/*.unbound.rq or test-existence gate keyed by capabilityId
6. Reconcile receipt: `{order_id, capability_id, pack_digest, render_digest, gate_results}` → standing advances
7. Idempotency: `write_new_file!` returns `:written|:unchanged|:skipped_exists`; re-running an admitted order is a no-op unless the pack digest changed — then byte-compare, gate, re-receipt

**Byte-fence for code kinds:** worker/verification/machine kinds land only via `write_new_file!` against a pinned pack digest, with a replay-identity test per kind; `machine` requires rendered bytes to match the pack digest exactly at admission; `worker`/`verification` get DO-NOT-EDIT headers + replay fences. Hand-edits to fenced files are lawful only through the pack.

**D5 — Residue doctrine (stays hand-written, permanently):** arm blob routes (~870 lines), /kv precondition matrix, RBAC PATCH, affidavit/finops witness wiring, dual parent-key lookup + `$default` synthesis, shim assertion content + needles/mutations + witness bodies (4 bespoke courts), security logic, shared runtimes (Lifecycle, common.py, lib.sh), sjira falsifier authorship (falsifiers are authored, then projected into gates — the projection projects the harness, not the judgment).

## 1. Waves

**W1 — ConfigKey ontology + Canonical riders (zero-risk machinery proof)**
46 keys → smalt:ConfigKey rows (accessor module + docs stanza + config stanza); THIRD_PARTY + capabilities identity block as Canonical.write riders. Receipts: config_keys.receipt (46/46, gates ≥1 row, verify 0 rows); replay-identity test on the accessor module; defaults-bijection.unbound.rq extended to full bijection.

**W2 — StoreTable (fixes a live bug class)**
33 @tables rows; ~20 shadow tables become owned rows (sweepStrategy=none, metadataOnly where lawful). Projects @tables, table_names/0, typed accessor shims, @metadata_tables, dets_mirror @default_tables. Gate: every :smalt_* atom in lib has an ownerModule (closes the blob_blocks swept-but-unowned class). Receipts: store.receipt + replay fence.

**W3 — CascadeEdge + HashChainLedger (depends on W2)**
CascadeEdge rows project capture-then-sweep (~85% regular; irregular tails stay hand-written, fenced by a verify query asserting every representable sweep is declared). HashChainLedger rows project ledger_writer + confidential_ledger (~70%); sentinel under the discipline. Receipts: cascade.receipt, ledger.receipt.

**W4 — Shim-courts scaffold (first projected code, safest ROI)**
1 template + 25 rows {court-name, subject-file, generated path, needle, replacement, mutation-id, witness-mode-pair, runner, env, skip-predicates}. 25 files/3,178 LOC → 1 template + 25 rows. Receipts: shim_courts.receipt; replay fence on all 25 rendered files. Actuate.write_new_file! gets its first production exercise (receipts record :written/:unchanged/:skipped_exists).

**W5 — KD-fence + corpus scaffold**
KD fence from the 94-row register (kd78/kd79 templates proven); corpus families (8/9 one shape) → 1 template + family rows; isolation blocks (env-snapshot + sink-dir + engine-reuse) as pack-managed includes. Receipts: kd_fences.receipt, corpus.receipt.

**W6 — Route shells, family-by-family** (D3 behavioral-equivalence law)
Order: EG topics (8 macros, smallest) → storage/KV singleton+default getters (~280→40) → azapi actions (~350→60) → roleAssignments/policy family (~400→50) → parented-child shells (~1,700→~150 rows). Each family: project alongside → behavioral equivalence → delete hand-written per family, court ladder green, receipts on file. D3b priority ordering from the first family. Receipts per family + cumulative arm_lines_deleted counter (~2,400-2,800 arm + ~300 egress by wave end).

**W7 — semconv pack**
YAML → pack rows; registry.ex.eex template shape; kills the hand-sync fence. Receipts: semconv.receipt; replay fence.

**W8 — sjira ProjectionSpec backend (depends on W4; W6 recommended)**
`:projection` backend per D4; sj:CodeKind byte-fence upgrade; falsifier→verify-gate projection keyed by capabilityId; receipts: projection_backend.receipt; acceptance: an end-to-end demo WO with sj:ProjectionSpec renders, gates, and reconciles without hand touch.

**W9 — ERROR_CODES judgment call (deferred; variant a on offer)**
Codes as ontology individuals projecting both the docs table and the emitting code — highest ceiling; land only after W2/W6 hardened the engine. Decision point at the W9 gate: land variant (a) or stand down with a verify query asserting ERROR_CODES.md is a rider of the codes file.

## 1a. Wave status (2026-10-17, terminal-status lane)

| Wave | Status | Evidence (as-of-date, on disk) |
|---|---|---|
| W1 ConfigKey + StoreTable | **LANDED** (commit `8361816`) | `lib/smalt/config.ex` 46 keys + 3 exemplar migrations; `lib/smalt/store_tables.ex` 52 rows (33 owned + 19 shadow typed) consumed by `store.ex`/`state.ex`/`dets_mirror.ex` — hand lists dead, swept-but-unowned class closed; replay fences 10/0 (config + store identity tests); pack lock converged |
| W2 CascadeEdge | **LANDED (uncommitted)** | `lib/smalt/cascade_edges.ex` 281 LOC, 23 CascadeEdge rows, GENERATED/DO-NOT-EDIT header; replay + coverage fence `test/cascade_replay_identity_test.exs` (241 LOC, verify/cascade-coverage.unbound.rq run in-test); drop functions stay hand-written (residue doctrine) |
| W2 semconv | **LANDED (uncommitted)** | `lib/smalt/telemetry/semconv/registry.ex` 252 LOC projected from `model/smalt.yaml`; closed-names + closed-attrs laws; drift fence `test/semconv_test.exs` (255 LOC: model fence + grep fence) |
| W2 Canonical riders | **LANDED (uncommitted)** | `lib/smalt/projection/canonical.ex` +277 LOC; THIRD_PARTY (96 lines changed) + capabilities.json (+525) identity blocks as Canonical.write riders; fence `test/canonical_projection_test.exs` (288 LOC) |
| W3 CascadeEdge full + HashChainLedger | QUEUED | plan §1 W3 (cascade edge-family completion + ledger_writer/confidential_ledger ~70%) |
| W4 Shim-courts scaffold | QUEUED | plan §1 W4 (1 template + 25 rows; first `Actuate.write_new_file!` production exercise) |
| W5 KD-fence + corpus scaffold | QUEUED | plan §1 W5 |
| W6 Route shells, family-by-family | QUEUED | plan §1 W6 (D3b priority law; ~2,400-2,800 arm lines) |
| W7 semconv pack | QUEUED | plan §1 W7 — note: YAML→registry projection already exercised ahead of the pack formalization (see W2 semconv row) |
| W8 sjira ProjectionSpec backend | QUEUED | plan §1 W8 (depends W4, W6 recommended) |
| W9 ERROR_CODES judgment call | QUEUED (deferred) | plan §1 W9 (decision point at the W9 gate) |

Engine law: §4 below is current — graphlaw fixed (one engine, no choice; sparql +
qlever deleted in ggen_igniter `b514bf5`); no reconciliation needed, the section was
already amended in-place by the engine lane.

## 2. Verification (per-wave, uniform)

1. ggen sync clean (pack.lock digest pinned per wave in receipts)
2. gates/*.rq ≥1 row each; verify/*.unbound.rq 0 rows, non-vacuous (invert-query test in receipt)
3. Replay-identity: subprocess sync → byte-compare all projected artifacts → pack.lock digest assertion
4. Court ladder per family (court → court-x2 → verify-all → invariant-gates; shim-courts where applicable)
5. Law-doc artifact-table row + CLAUDE.md generated-artifacts row

## 3. Residue accounting (expected)

arm −2,400-2,800 lines; egress −300; store −15-20%; shims −3,178→~300; KD+corpus scaffolds largely absorbed; ConfigKey accessor ~800 hand lines absorbed; semconv hand-sync fence killed. All converted artifacts carry DO-NOT-EDIT + replay fences; remaining hand-written code is residue-doctrine-protected and fenced by verify queries where representable.

## 4. Engine law (2026-10-17)

One engine, no choice — **graphlaw** (row-for-row vs the oxigraph reference on the full pack SELECT set; sparql + qlever deleted from ggen_igniter `b514bf5`). The sparql-hex constraint section (no FILTER NOT EXISTS, ORDER BY post-sort) is historical; templates keep their defensive re-sorts. `gate_verify` refuses non-`:graphlaw` fail-closed.
