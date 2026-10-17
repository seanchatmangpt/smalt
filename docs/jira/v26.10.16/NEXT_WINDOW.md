# NEXT WINDOW — planning handoff from v26.10.16

Source: verified carries from the v26.10.16 wrap (`WRAP_LEDGER.md`,
`FINAL.md`). Every item names a file:line referent and a close condition.
Verified 2026-10-16 against the on-disk tree at main (working tree).

## 1. KD-77 flip (pending r210 + token)

- **Referent**: canonical row `docs/jira/v26.10.14/KNOWN_DIVERGENCES.md:223`
  (KD-77, AMQP delivery-tag encoding / UUID settle path, OPEN);
  in-flight note `docs/jira/v26.10.16/WRAP_LEDGER.md:229` ("witness
  receipt r210 pending").
- **Close condition**: witness receipt r210 lands in
  `docs/jira/v26.10.16/receipts/` with real probe output (pyamqp
  send/receive/complete green, `object of type 'UUID' has no len()`
  signature gone); mtime(r210) > mtime of the KD-COVERS shim in
  `lib/smalt/messaging/amqp/`; then `scripts/kd_flip.py --apply KD-77`
  flips the canonical row. No receipt, no flip.

## 2. Gap-census residual: justfile exclusion list

> **UPDATE 2026-10-16, lane 4**: CLOSED this session — the struck
> `eventhubs-partition-metadata-absent` token was added to the
> exclusion list in `justfile.d/10-gap-register-sync.just`; census
> tightened 9→8; `just gap-sync` exit 0 (see WRAP_LEDGER "ERRC cycle"
> section). Remaining item only for the next window: none.

- **Referent**: `docs/jira/v26.10.16/WRAP_LEDGER.md:214-219` — the live-gap floor in
  `justfile.d/10-gap-register-sync.just` still counts the struck
  `eventhubs-partition-metadata-absent` token (exclusion list predates
  the closure); census reads 9 where the honest count is 8.
- **Close condition**: add the struck token to the exclusion list in
  `justfile.d/10-gap-register-sync.just`; census reads 8 = honest count;
  `just gap-register-sync` passes. The historical receipt
  `docs/jira/v26.10.14/receipts/13-gap-register.md` is NOT edited
  (records are not edited).

## 3. SUSPECT triage remainder — archival decision

- **Referent**: `docs/jira/v26.10.16/WRAP_LEDGER.md:62-68` (SUSPECT-21
  carried-not-repaired triage; W11 regen count 23 SUSPECT across all
  windows, incl. `r130-r140-not-receipted.md`) and the index count at
  `docs/jira/v26.10.16/FINAL.md:11` (`suspects=21`).
- **Scope**: the remainder after this window's 4 re-witnesses + 2
  SUPERSEDED flips (fin-04-gitignore / x7-bench-report /
  bench-07-store-beam / bench-08-amqp-beam re-witnessed;
  bench-12-consolidation / fin32-wrap-final SUPERSEDED). Coordinator
  triage names 7 historical-accept and 2 superseded-class receipts.
  Re-verify the split from `receipt_index.py` output at execution time —
  counts are stale-by-default per no-overclaiming discipline.
  - 7 historical-accept: leave in place, standing stays SUSPECT;
    session-era records are not edited.
  - 2 superseded-class (candidates: `bench-12-consolidation.md`,
    `fin32-wrap-final.md` in `docs/jira/v26.10.14/receipts/`): decide
    archival — either a superseded marker the indexer honors (indexer
    change = code change, needs its own WO) or leave flagged with the
    SUPERSEDED note in-body. Prefer leave-flagged; a new indexer
    SUPERSERVED/SUPERSEDED status is out of scope unless dispatched.
- **Close condition**: a docs-lane receipt naming each remaining SUSPECT
  receipt with its disposition (historical-accept | leave-flagged) and
  the receipt_index.py summary line embedded as evidence.

## 3b. r130-r140 receipt debt

- **Referent**:
  `docs/jira/v26.10.16/receipts/r130-r140-not-receipted.md` — trace
  concluded NO LANDED ARTIFACT for R130/R140 (same handling as R31/R127
  precedents in `_LANES.md`); the receipt itself is one of the 23
  SUSPECT (output-less, scratch-class).
- **Close condition**: none available to docs — R130/R140 have no
  artifacts to re-witness. Disposition: carry the trace receipt as the
  standing record; re-flag only if a lane later lands an artifact
  claiming R130/R140. Documented here so the debt cannot quietly drop.

## 4. QueueDescription gaps probe-authoring

- **Referent**: `docs/jira/v26.10.16/WRAP_LEDGER.md:91-100`
  ("atom_bridge QueueDescription gaps (audit 2026-10-16,
  schema-complete-for-SDK)"). 12 emitted fields cover the SDK's throwing
  getters; 9 optional-field gaps enumerated; soft spot: `getQueueRuntimeProperties`
  would fail today (throwing `getDate`); PUT round-trip persists only 4
  fields (atom_queue_properties).
- **Close condition**: probe-authoring rows in the next window's
  `_LANES.md` partition: a py/js probe leg for `getQueueRuntimeProperties`
  and a PUT round-trip fidelity leg; each lands with a real-probe
  receipt. Park status ends only when the probe legs land or are typed
  UNSUPPORTED with a receipt.

## 5. `use Plug.Test` deprecation lint

- **Referent**: coordinator-asserted carry; on-disk breadth witness:
  15 files under `test/` contain `use Plug.Test` (verified by grep
  2026-10-16). No doc referent exists in the window yet — first action
  is to capture the actual deprecation warning output (real compile
  output, exit codes embedded).
- **Close condition**: a receipt embedding the real deprecation warning
  (or an honest "no warning fires on current toolchain" finding), plus
  a typed disposition: migrate the 15 test files, or register a
  divergence/negation row if the lint is toolchain-conditional. A lint
  fix without a witnessed warning is an unverified premise.

## 6. FINAL.md planning-handoff pointer (fill at wrap)

- **Referent**: `docs/jira/v26.10.16/FINAL.md` (terminal doc). Prior
  exemplar: `docs/jira/v26.10.14/FINAL.md` ends with terminal standing
  only — the handoff pointer is a new convention this window adopts.
- **Close condition**: at v26.10.16 wrap, append a one-line pointer to
  this file (`NEXT_WINDOW.md`) to FINAL.md. Placeholder until then;
  fill only at wrap, never mid-window.

## 7. v26.10.16 sdk-results population (census run)

- **Referent**: `docs/jira/v26.10.16/` has `bench/` but no `sdk-results/`
  directory (verified `ls` 2026-10-16); compare v26.10.14 which carries
  `sdk-results/` + 15 indexed sdk-results entries
  (`FINAL.md:11`); WIRE_PARITY row at
  `docs/WIRE_PARITY.md:150` documents the same class of staleness (the
  ts-event-hubs cell lagged its court receipt until a re-probe landed).
- **Close condition**: run the SDK census
  (`just sdk-all` / per-SDK probes) against a live substrate; land
  `docs/jira/v26.10.16/sdk-results/` (one md per SDK leg, real output);
  `just receipt-index` + `just sdk-matrix-md` regenerate cleanly; the
  matrix must not read MISSING/UNREGISTERED-GAP.

## 8. RELEASE_NOTES standing flip post-court-x2

- **Referent**: `docs/RELEASE_NOTES_v26.10.14.md` (modified, working
  tree); WRAP_LEDGER.md:203 ("Confirm RELEASE_NOTES landing — v26.10.16
  notes on disk and named in FINAL.md").
- **Close condition**: v26.10.16 notes file on disk and named in
  FINAL.md; standing flip (PARTIAL_ALIVE → the two-green verdict) is
  applied to the notes only AFTER `just court-x2` returns two-green
  with embedded output in a receipt. Flip is receipt-gated, same law as
  KD/GAP flips: no court-x2 receipt, no standing flip.

## 9. Carried wire-parity parks (deliberate, fail-closed)

Each item below is a deliberate-open park, not a defect backlog. Every one
names its pinning mechanism (where the open state is registered) and is
typed fail-closed: the emulator refuses or honestly degrades, it never
returns an honest-looking 200 for a surface it did not implement. Tokens
are minted in `docs/WIRE_PARITY.md` and close only with a receipt (no
receipt, no flip). Source inventory: coordinator carry, verified on disk
2026-10-16.

- **SB session reply-to (`reply_to` / `reply_to_session_id`) dropped** —
  no code path stores or emits either field; SDKs setting
  `reply_to_session_id` on a requires-session queue observe the field
  dropped, not rejected. Pinning: typed UNSUPPORTED row
  `docs/WIRE_PARITY.md:145` (V261014-08); compliance receipt
  `docs/compliance/C5_SERVICEBUS.md` R11. Frame codec already parses
  `:reply_to` (`lib/smalt/messaging/amqp/frame_codec.ex:181`); the gap is
  storage + emission in build_properties. Parked fix: store on ingest,
  emit in build_properties, census probe.
- **SB subscription rules / filter engine absent** — no subscription
  concept in `route/2`, no add-rule/remove-rule ops in `normalize_op/1`,
  no SQL/correlation filter evaluator, no `$Default` rule; add-rule stays
  `:unknown-op` → fail-closed 501. Pinning: same typed UNSUPPORTED row
  `docs/WIRE_PARITY.md:145` (V261014-08), named in
  `docs/compliance/C7_EVENT_PLANES.md`.
- **atom_bridge QueueDescription optional-field gaps** — 12 emitted
  fields cover the SDK's throwing getters; 9 optional-field gaps remain;
  soft spot: `getQueueRuntimeProperties` would fail today (throwing
  `getDate`); PUT round-trip persists only 4 fields. Pinning: item 4 of
  this file (probe-authoring rows), audit note
  `docs/jira/v26.10.16/WRAP_LEDGER.md:91-100`. Duplication here is
  deliberate: item 4 carries the work order, this section carries the
  parity-park classification.
- **`GAP(blob-comp-lease-absent)`** — full `comp=lease` surface
  (acquire/renew/change/release/break, `:smalt_blob_leases`, enforcement
  seam alongside `check_worm`) is feature-scale; until it lands the
  hardcoded `<LeaseStatus>unlocked</LeaseStatus>`
  (`lib/smalt/data_plane/blob_service.ex:101`) is the divergence marker.
  Pinning: GAP token `docs/WIRE_PARITY.md:124` (C4 receipt,
  `docs/compliance/C4_BLOB.md`).
- **`GAP(blob-x-ms-date-unvalidated)`** — `x-ms-date` not
  required/validated. Bounded fix: presence + RFC 1123 parse + skew
  window shared with the other `:8443` planes. Pinning: GAP token
  `docs/WIRE_PARITY.md:124`.
- **delete_blob WORM-before-If-Match precedence divergence** —
  `delete_blob/4` evaluates `check_worm` before `check_if_match`
  (`lib/smalt/data_plane/blob_storage.ex:592-593`), so a blob both
  WORM-locked and If-Match-mismatched answers 409 `ContainerLocked`
  where real Azure evaluates preconditions first and answers 412
  `PreconditionFailed`. Deliberate: the reorder is contract-visible
  (tests + `@doc` pin 409-on-WORM) and interacts with the future lease
  seam — revisit with the lease work. Pinning: divergence note in
  `docs/WIRE_PARITY.md:124` (no GAP token; contract-pinned divergence).
- **`GAP(cosmos-sql-translator-absent)`** — no full SQL translator; a
  whitelist honesty gate admits only the trivial `SELECT * FROM <alias>`
  form and answers every other nonblank query a typed 400 `SyntaxError`
  (`lib/smalt/data_plane/cosmos.ex` `sql_whitelisted?/1`). Pinning: GAP
  token `docs/WIRE_PARITY.md:133`.
- **`GAP(eventgrid-eg1-schema-absent)`** — native Event Grid event
  schema (EG1/`GRIDEVENT`, system-topic events) not implemented;
  CloudEvents 1.0 admitted only. Pinning: GAP token
  `docs/WIRE_PARITY.md:123` (V261014-13).
- **`GAP(kql-datetime-dynamic-types-absent)`** — datetime/dynamic
  column-type inference absent (values report `"string"`). Pinning: GAP
  token `docs/WIRE_PARITY.md:130` (V261014-13).
- **`GAP(atlas-search-relationship-get-absent)`** — `POST
  /atlas/v2/search/collection` and relationship read/GET beyond the
  edge-minting POST not implemented. Pinning: GAP token
  `docs/WIRE_PARITY.md:132` (V261014-13).

## 10. Wave-surfaced register candidates (Phase 4 item 12)

Registered as documented candidates/parks in
`WRAP_LEDGER.md` ("Wave-surfaced register candidates", 2026-10-16 docs
lane) — no KD rows or GAP tokens minted; minting/flips are
registrar-owned. Six candidates, each with file:line referent and close
condition in the WRAP_LEDGER section:

1. resourcegraph unparseable-KQL → 200-inventory-leak
   (`sdk-results/ts-resourcegraph.md:29,44-52`);
2. ledger receipt.contents double-nesting (`sdk-results/py-ledger.md:38-43`);
3. azapi-lock-if-match-unverified — proposed in
   `docs/jira/v26.10.14/20-arm-gateway-hygiene.md:41,61`, token never
   minted in WIRE_PARITY;
4. D127×FR-6 cascade interaction — resolved wording on record
   (`lib/smalt/arm_gateway/router.ex:611` + WRAP_LEDGER D127 row);
   "FR-6" has no on-disk referent (disclosed);
5. SB subscription-rules 501 + reply_to drop — already registered,
   cross-link to `docs/WIRE_PARITY.md:145` / NEXT_WINDOW section 9;
6. metadata-doc `microsoftGraphResourceId` blocker
   (`sdk-results/tf-plan.md:14-19`) — P1 re-witness will resolve.

Close condition for the section as a whole: each candidate is either
acted on (fix lands with wire-visible receipt, or registrar mints the
KD/GAP token citing the WRAP_LEDGER entry) or explicitly re-parked by
the next window's opening wave. No candidate may silently drop.

## 12. External terraform tier retirement → opt-in T4-external (2026-10-16)

- **Referent**: `docs/jira/v26.10.16/sdk-results/native-lifecycle.md`
  (equivalence receipt, ALIVE) — native in-process lifecycle
  (`Smalt.Enclave.Lifecycle`) admits the same 3-resource graph as the
  external pipeline (all ids byte-identical), all six stages sub-100 ms
  (max apply 52 ms); `test/enclave_lifecycle_test.exs` green 1/0.
- **Ruling**: the external Go CLI tier (smalt-tf + raw terraform via
  `scripts/tf_smoke.sh`) is DEMOTED to an opt-in T4-external
  wire-compat suite. The native in-process lifecycle is the primary
  green gate for v26.10.16+; NFR-4 proof = `smalt_ets_baseline_identity`
  (tables exist post-destroy, zero residue: lifecycle test asserts
  `:ets.whereis` alive + `Store.keys/1 == []` on all resource-bearing
  tables) plus the lifecycle's fail-closed `residue` stage (17 tables
  verified empty).
- **Why demoted**: the external tier is single-flight on three global
  shared resources — `test/terraform_fixture/` state lock, `.smalt/tls`
  cert regen, provider-mirror revalidation. Under concurrent fan-out it
  degrades (witnessed live: state-lock failures, cross-lane cert-pin
  mismatch, mirror-race registry fallback — all embedded in the
  receipt). The tier is wire-compat evidence, not a gate.
- **Shim note**: the DYLD trust shim (`scripts/trust_shim/`) remains
  available for the external tier's convenience when run opt-in /
  single-flight; it is not on the native path (no Go, no terraform, no
  keychain trust).
- **Close condition**: none — retirement is the recorded decision.
  Re-open only if a wire-compat question arises that the native
  pipeline cannot answer (then run T4-external single-flight, isolated
  fixture copy per the T5 cleanroom pattern in
  `sdk-results/t5-cleanroom.md`).

## Execution order (dependency)

1. (7) sdk-results census — feeds (2)'s honest counts and the matrix
2. (1) KD-77 flip — gated on r210 landing
3. (2) gap-census exclusion list — mechanical, after (7) census
4. (5) Plug.Test warning witness
5. (3) SUSPECT triage receipt — needs (7)'s regen
6. (3b) r130-r140 — carry-record only, no action available
7. (4) QueueDescription probe legs — feature-scale, schedule per lane
8. (8) RELEASE_NOTES flip — last, post-court-x2
9. (6) FINAL.md pointer — at wrap only

## 11. ggen semantic-kernel roadmap (prototype lanes in flight)

Five prototype lanes map the five defect classes to pack projections; the
receipt for this roadmap is the prototype artifacts + verdicts, and the
utilization target is replacing the hand-written supplement/defaults/
cascade modules with generated ones next window.

### Prototype lanes (defect class → pack projection)

1. **Cascade DAG** → pack-projected cascade dispatch (replaces the
   hand-written ARM cascade path in `lib/smalt/arm_gateway/router.ex`
   — see the D127×FR-6 cascade interaction, WRAP_LEDGER item 4).
2. **Version lattice** → ontology-derived version lattice projection.
3. **Defaults-in-shape bijection** → defaults table generated in bijection
   with the shape (replaces the hand-written defaults table).
4. **Provider-matrix-from-ontology** → provider matrix generated from the
   ontology (replaces the hand-written provider_matrix supplement).
5. **Canonical IRI normalizer** → IRI normalization projection.

Receipt = prototype artifacts + verdicts (each prototype lands with its
falsifier run). Utilization = next window swaps the hand-written
provider_matrix supplement, defaults table, and cascade dispatch for the
generated modules.

### Single authoring surface (ggen/marketplace inventory lane capability matrix)

One authoring surface owns every projection: the **smalt-substrate-pack**
— `ontology.ttl` + `queries/*.rq` + `templates/*.eex` + `gates/*.rq`,
wired as one `--query`/`--template`/`--out` pair per projection in the
`mix.exs smalt.gen` alias. No external pack reuse except:

- **state-transition-pack** — idempotency FSM vocabulary; needs a port to
  smalt (vocabulary only, not machinery).
- **shacl-projection-pack** — bijection gates; manual composition (not a
  drop-in).

**sparql-engine caveat**: ORDER BY is ignored by the engine — re-sort
in-template. Any template relying on engine-side ordering is silently
unsorted; sort inside the Eex template, never in the .rq.

### Gates run two ways (reusability note)

- **GraphLaw hard-crash, smalt-side** — via the
  `gates/shapes-coverage.rq` pattern: the gate query runs against the
  live graph and a violation crashes smalt hard (fail-closed at runtime).
- **ggen law validate, pack-side** — the same gate shape runs as a ggen
  law validation during projection (fail-closed at generation time).

Pairing convention: `gates/0XX_*.rq` (numbered runtime gates) pair with
`verify/*.unbound.rq` (generation-time verification queries; `.unbound.`
marks queries that must return zero rows to pass). A gate landing without
its verify pairing is incomplete.

## Queued from v26.10.16 console + capability wave

- **KD-84 SB settlement race — disposition flush on receiver close**
  (`lib/smalt/messaging/amqp/connection.ex`): dispositions accepted but
  not flushed when a receiver closes mid-window can lose settlement
  state. Close: receiver-close path flushes pending dispositions with a
  real-probe receipt (settle-then-close race probe green); KD-84 row
  flips via `scripts/kd_flip.py --apply` gated on witness mtime > shim
  mtime.
- **KD-85 annotation key `x-opt-enqueued-time-utc` →
  `x-opt-enqueued-time`** (`lib/smalt/messaging/amqp/delivery_encoder.ex:94`):
  emitted annotation key diverges from the real-SDK-census-pinned
  surface. Close: key renamed, SDK probe receipt shows the census-pinned
  key on the wire, KD-85 row flips receipt-gated.
- **KD-86 auto-ensure flag-gate defaulting to typed
  MessagingEntityNotFound**: auto-creation flag currently defaults the
  wrong way. Close: flag-off path answers typed MessagingEntityNotFound
  (fail-closed), flag-on path unchanged, negative-fixture probe receipt
  embedded.
- **Retokenize KD-COVERS tokens** (`lib/smalt/arm_gateway/router.ex:76`
  + `lib/smalt/arm_gateway/bearer.ex:180-181`): deduplicated — see
  section 13 item 6 (KD-82 → KD-87), which carries the close condition.
- **Event Grid webhook delivery**: outbound webhook delivery leg absent.
  Close: webhook delivery probe receipt (real HTTP sink, signed
  delivery) or typed UNSUPPORTED row minted by the registrar — no
  silent park.
- **System-topic-sourced event ingest**: events originating from system
  topics not admitted. Close: ingest probe receipt naming the system
  topic surface, or registrar-minted GAP/KD token registering the
  divergence (overlaps `GAP(eventgrid-eg1-schema-absent)`,
  `docs/WIRE_PARITY.md:123`).
- **EH namespace-scoped consumergroup list-all**: list-all across the
  namespace not implemented. Close: SDK probe receipt covering the
  list-all surface (exit 0) or typed UNSUPPORTED/GAP row minted.
- **Console Ring 3/4 remainder** (resourcegraph, LRO, monitor views):
  workspace console views outstanding. Close: `just ws-court` green
  covering the Ring 3/4 surfaces, or per-view park rows in the window's
  `_LANES.md`.
- **KD-60/77/82 flip-court witnesses**: rows can only flip when a
  witness receipt postdates the shim. Close: witness receipts land in
  `docs/jira/v26.10.16/receipts/` with mtime > respective shim mtimes;
  flips applied via `scripts/kd_flip.py --apply` only. No receipt, no
  flip.
- **Elixir PATH pin**: lanes must resolve asdf Elixir 1.20.3, not
  Homebrew 1.19.5. Close: lane receipts embed `elixir --version` output
  showing 1.20.3; pin mechanism (PATH ordering or ASDF_ELIXIR_VERSION)
  documented in `_LANES.md`.

## 13. Affidavit-closure wave consolidated queue (Lane 12 wrap-prep, 2026-10-16)

Consolidated from the affidavit-closure wave, `next-window-errc.md`, and
affidavit kill-queue residue. Each item: one line + close condition.
Nothing existing above is modified by this section.

1. **Affidavit upstream work order (affidavit repo)** — expose ML_DSA65 in
   the engine `verify_signature` op; populate/reconsider the CTRT witness
   region `[240..352]`; two-target-dir reproducible rebuild; ARTIFACTS.sha256
   pin refresh. Close: affidavit-repo receipt with verify_signature probe
   green on ML_DSA65, reproducible rebuild byte-identical across the two
   target dirs, refreshed pin manifest — KD-89 close depends on it.
2. **In-process blake3 NIF (KD-90 close)** — kill the b3sum subprocess
   dominance (digest p50 4.4 ms → sub-ms). Close: bench jsonl re-run
   showing digest p50 < 1 ms on the same bench lane, receipt embedded, no
   subprocess invocation left on the hot path; `kd_flip.py --apply KD-90`
   (witness mtime > shim mtime).
3. **Graduate c11 tf→console lane — DONE (not queued)**. The external
   tf-tier retirement ruling is on record at section 12 of this file
   (receipt `docs/jira/v26.10.16/sdk-results/native-lifecycle.md`, ALIVE):
   the native in-process lifecycle is the primary green gate, T4-external
   is opt-in wire-compat only. No next-window lane row required; this
   line stands as the disposition record.
4. **Fold `next-window-errc.md` + affidavit kill-queue residue** — the
   ELIMINATE census (compiler-based unused-module kill), REDUCE items
   4-8, and kill-queue remnants land as work orders here rather than a
   separate file. Close: each errc item 1-8 has a lane row in the next
   window's `_LANES.md` or a disposition receipt; the file is then
   foldable/archived with a pointer (records not edited).
5. **KD-84/85/86 SB fixes** — settlement-race disposition flush,
   `x-opt-enqueued-time` annotation key, auto-ensure flag-gate typed
   default. Close: per-KD real-probe witness receipts (settle-then-close
   race, wire-captured annotation key, negative-fixture MessagingEntityNotFound)
   with mtime > shim mtimes; flips via `scripts/kd_flip.py --apply` only
   (details in the "Queued from v26.10.16" section above).
6. **KD-COVERS retokenize KD-82 → KD-87** —
   `lib/smalt/arm_gateway/router.ex:76` + `lib/smalt/arm_gateway/bearer.ex:180-181`.
   Close: grep shows `# KD-COVERS: KD-87` at both sites, kd_flip resolves
   the corrected tokens, no register row hand-edited.
7. **gen_error_codes extractor extension** — **DONE (2026-10-16, verified T5
   finalize)**: extractor carries both codes (`scripts/gen_error_codes.py:200-204`,
   `:390`); `docs/ERROR_CODES.md` rows regenerated (`:40` arm-gateway PolicyViolation,
   `:46` egress InvalidEventGridEvent); drift fence green — `python3
   scripts/gen_error_codes.py --check` → `docs/ERROR_CODES.md up to date`, exit 0.
8. **ash_extension manifest honesty for hand-adapted outputs** — manifest
   must mark hand-adapted outputs as hand-adapted, not generated; lane 16
   flagged 3 stale manifest entries claiming generated provenance on
   hand-adapted outputs. Close: manifest regen marks the adapted entries
   with an explicit hand-adapted provenance field, the 3 stale entries
   are corrected or re-projected, and a replay/verification receipt
   distinguishes the two classes.
9. **`--check` modes for receipt_index / bench-report / sdk_coverage** —
   read-only drift-check flags for the three generators. Close: each tool
   accepts `--check` that exits 1 on drift / 0 clean, negative fixture
   (drifted tree) shows exit 1, receipts embedded.
10. **ex4pm dual-pin + mix.lock refresh** — dual-pin the ex4pm dependency
   range and refresh `mix.lock`. Close: `mix deps.get` + full offline suite
   green on the refreshed lock, lock diff in the receipt, no diamond
   conflict in `mix deps.tree`.
11. **KD-91 close (ARM CheckNameExists HEAD empty-body route)** — fix
   landed (`lib/smalt/arm_gateway/router.ex:4410-4420`), row OPEN
   witness-pending (canonical row
   `docs/jira/v26.10.14/KNOWN_DIVERGENCES.md:238`). Close: witness re-run
   on a trusted substrate — azurerm cosmosdb apply proceeds past
   CheckNameExists, apply.log shows HEAD answered 204/404 with empty body
   (never 400/EOF); `kd_flip.py --apply KD-91` gated on witness mtime >
   fix mtime.
12. **KD-92 close (ARM-container vs data-plane container store split)** —
   ARM child container PUT writes only the ARM resource store; data-plane
   blob PUT answers 404 `ContainerNotFound` (canonical row
   `docs/jira/v26.10.14/KNOWN_DIVERGENCES.md:239`). Close: ARM container
   PUT mirrors into `:smalt_blob_containers` (or the planes share one
   store); falsifier probe — ARM PUT container → data-plane blob PUT →
   201, never 404; `kd_flip.py --apply KD-92` receipt-gated.
14. **KD-93 close (cosmos query feed no-filter + stale pre-seeded
   projection)** — the POST query feed ignores parameterized filters and
   is not scoped to the addressed db/coll: on a fresh run-unique db it
   returned a doc the run never wrote (`ids=["doc_132"] want c11-doc-1`,
   lane R7 duplicate-dispatch disclosure; canonical row
   `docs/jira/v26.10.14/KNOWN_DIVERGENCES.md:240`). Close: NEXT_WINDOW
   falsifier probe — POST query `WHERE c.mark = @mark` immediately after
   the doc PUT must return the just-written doc (`ids` contains
   c11-doc-1), never a pre-seeded id; `kd_flip.py --apply KD-93`
   receipt-gated.
13. **provider-matrix / cascade verify-pairing authoring (lane 16
   convention gap)** — the `gates/0XX_*.rq` ↔ `verify/*.unbound.rq`
   pairing convention (section 11) is unfilled for the provider-matrix
   and cascade-dispatch projections: no verify pairing exists for either.
   Close: `verify/` unbound queries authored for both projections, wired
   into the pack's generation-time validation; receipt shows a violated
   pairing refusing generation (negative fixture, exit nonzero).

## 14. ERRC prune/tighten residuals — folded from `next-window-errc.md` (lane 4, 2026-10-16)

Fold executed by the CLOSURE-wave errc lane; the source file is now
marked FOLDABLE with a pointer to this section. Each item is a
verify-then-kill work order, not a confirmed kill. Docs/scripts-only
freeze during the pass — no lib/ edits, no GAP/KD mints.

1. **Unused-module census via compiler, not grep** (`lib/`, next
   window). `MIX_BUILD_ROOT=_build-errc mix compile --warnings-as-errors`
   (or `mix xref graph`) and kill every lib/ module with zero inbound
   references. Grep-only kills are banned (grep misses alias/dynamic
   dispatch). Verify-first candidates (lowest inbound refs; re-verify):
   `lib/smalt/runtime_contracts/support.ex`, `kql.ex`/`resource_graph.ex`
   segments, `lib/smalt/hw/virtual_serial.ex`,
   `lib/smalt/ocel/revops/powl_bridge.ex`. Close: census receipt + per-
   module kill receipts (compile green post-kill, full offline suite green).
2. **KD-53 batch-callback fence test** (`test/`): EH multi-event batch
   drops inner messages 2..N (filed commit `fd9cfea`). Close: real
   pyamqp batch test that flips on the mutant fix and pins inner-message
   delivery; then `kd_flip.py --apply KD-53` per the kd-registrar path.
3. **Re-probe `ts-event-hubs`** named in the `docs/WIRE_PARITY.md` Event
   Hubs SDK smoke row. Close: `sdk-results/ts-event-hubs.md` refreshed
   from a live 4/4 probe, REGISTERED-DIVERGENCE cell flipped receipt-gated.
4. **`scripts/tf_provider_wrap.sh` kill-or-wire**. Only inbound ref is a
   comment at `scripts/tf_mirror_env.sh:93`. Close: invocation-absence
   proof (grep over justfile.d + scripts) in a receipt → delete script +
   comment; or wire it and probe-receipt the invocation.
5. **`docs/audit/` staleness re-check** vs canonical `SDK_MATRIX.md` +
   KD register; archive to `docs/archive/` with pointer in
   archive/README.md (v26.10.14 pattern) if duplicative. Close: archive
   commit or freshness receipt.
6. **`docs/PACK_INTEGRATION/REMAINING_CENSUS.md` re-census or archive**
   (dated 2026-10-14, carries an unverified I8 trio assumption). Close:
   re-census receipt or archive with pointer.
7. **`scripts/__pycache__` ignore check**: verify `.gitignore` covers it;
   if not, add the ignore line (scripts-lane edit). Close: `git status`
   clean of `__pycache__` entries.
8. **`wave-telemetry.jsonl` roll-up vs deletion** at wrap — coordinator
   decision, parked. Close: coordinator ruling on record + file rolled
   up or removed.

14. **hex.publish remediation set (pre-publish sweep, 2026-10-16)** —
   a. ex4pm hex-publish readiness: `mix.exs:112` carries
      `{:ash_ex4pm, path: "../ash_ex4pm", ...}` and `mix.exs:121`
      `{:ex4pm, path: "../ex4pm", override: true}` — path deps are not
      publishable; hex.publish needs the hex-side dual-pin. The dual-pin +
      mix.lock refresh half of this is ALREADY QUEUED as section 13
      item 10 (dedupe: execute once, under item 10; this item carries
      only the publish-facing remainder).
   b. AshR2RML: guard/stub-or-exclude decision needed so the publish
      package does not ship a dep that fails without its path sibling.
   c. `stream_data` (`mix.exs:127`) is declared env-prod but is
      test-usage only — retarget to `only: :test` (or prove the ash
      prod dependency requires it at runtime before moving).
   d. NOTICE attribution: upstream attribution pass not yet landed —
      no X1 receipt found in `docs/jira/v26.10.16/receipts/` and
      `NOTICE.md` carries no upstream license/attribution block
      (verified 2026-10-16). NOT DONE. Close: X1 (or successor) receipt
      lands with the attribution diff embedded.
   e. ARM-style description wording advisory — low-priority copy fix on
      the hex package description/metadata; close with the metadata
      diff in a receipt.
   Close: `mix hex.publish --dry-run` exit 0 with the warnings list
   empty or each remaining warning dispositioned in the receipt;
   sub-items (a)-(e) each named.
15. **cwd-relative boot paths → `:code.priv_dir(:smalt)`** —
   `lib/smalt/tls.ex`, `lib/smalt/enclave/doctor.ex`,
   `lib/smalt/enclave/lifecycle.ex`,
   `lib/smalt/affidavit/wasm_engine.ex` (wasm artifact + pin sidecar)
   resolve priv assets relative to cwd; a boot from any directory other
   than repo root fails to find `priv/`. Close: all priv-asset reads go
   through `:code.priv_dir(:smalt)` (or an app-env override), boot smoke
   green from a non-root cwd with the receipt embedded.
16. **`:inets`/`:xmerl` orphan extra_applications** —
   `mix.exs:64` declares both; verify against `mix xref`/`:application`
   usage. Close: census receipt; if truly unused, removed from
   extra_applications and full offline suite green; if used, a usage
   note replaces the removal.
17. **Mix.Tasks placement** — `lib/smalt/dspy/tasks/` ( Mix task
   modules) sit under `lib/smalt/` instead of `lib/mix/tasks/`; app
   mod list may need `:mix` considered. Close: tasks moved to
   `lib/mix/tasks/`, `mix compile` + task invocation green from a clean
   build, receipt embedded.
18. **`lib/smalt/projection/semantic_epoch.ex` lenient reads of
   `.ggen_igniter`** — NOTE ONLY, documented-degradation: reads of
   `.ggen_igniter` state degrade leniently when the manifest is absent
   or stale. No close condition; re-open only if the lenient read masks
   a real projection divergence. Referent: file as named; disposition
   recorded here so the audit finding cannot silently drop.

Parks carried verbatim (never auto-resolve): P1
`GAP(blob-comp-lease-absent)` blob delete-precedence divergence
(feature-scale, owner-proposal pending); P2 SUSPECT-receipt archival
mechanism (NEXT_WINDOW item 3, code lane).
