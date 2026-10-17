# WRAP_LEDGER — v26.10.16 parks and open windows

Standing: CURRENT (as of 2026-10-16, W11 docs lane, late refresh; matrix-wave
linkage refreshed 2026-10-16, Agent 15 final-certification lane)

## Matrix-wave receipts linkage (Agent 15, 2026-10-16 — linked-where-on-disk, PENDING-where-not)

Of the 14 named matrix-wave items, these have artifacts on disk and are
linked; the rest are PENDING and listed by name so they cannot quietly
drop. No receipt was fabricated for a missing artifact.

**Linked (artifact on disk):**

| Item | Artifact | Standing |
|---|---|---|
| nfr3-rss-500 | [sdk-results/nfr3-rss.md](sdk-results/nfr3-rss.md) | PASS (delta −31712 KB against 262144 KB budget) |
| spc-gate-receipt | [sdk-results/spc-bands.md](sdk-results/spc-bands.md) | PASS (tier 0, window 30) |
| pqc-attestation-audit | [sdk-results/pqc-attestation-audit.md](sdk-results/pqc-attestation-audit.md) | AUDIT_COMPLETE — GAP_TYPED, NOT_CLOSED (classical-only attestation; no ML-DSA-65 anywhere — honest gap, see FINAL.md) |
| nfr4-identity-proof | [sdk-results/native-lifecycle.md](sdk-results/native-lifecycle.md) | ALIVE (NFR-4 identity = tables alive + empty post-destroy, 17 tables verified empty) |
| doctor 3-env | [doctor-receipt.json](doctor-receipt.json) | 12/12 checks PASS — **single-env** receipt; the 3-env matrix is PENDING (below) |

**PENDING (no artifact on disk as of 2026-10-16):** nfr1-velocity,
dataplane-throughput, shacl-fuzz, version-lattice, ex4pm-conformance,
shim-v2-verification, tf-wire-ladder (closest referent
[sdk-results/tf-plan.md](sdk-results/tf-plan.md) is a plan census, not a
ladder), wire-replay-census, e1-console-bridge (console leg NOT REACHED
per [receipts/t5-cleanroom-validation.md](receipts/t5-cleanroom-validation.md)).
These close only with real receipts landing; this lane does not mint them.

Parked items that outlive this window. Each entry names its owner-surface
and close condition; nothing here is quietly dropped.

## KD parks (KD-68/70/71/76/77/78 — statuses re-verified against the canonical register 2026-10-16, docs lane)

| KD | Surface | Divergence | Status (verified vs canonical table) |
|---|---|---|---|
| KD-68 | EH selector-filter / eventPosition | sequenceNumber eventPosition ignored on decode/apply | CLOSED-SIMULATED — witness r200d-kd68-selector-impl.md (ALIVE, 4/0 falsifier + 39/0 wire tier); flipped in the canonical table (`docs/jira/v26.10.14/KNOWN_DIVERGENCES.md:151`) |
| KD-70 | EH delivery_annotations | delivery/annotation stamps not mirrored to the wire surface | CLOSED-SIMULATED — witness r200a-kd70-delivery-annotations.md (PASS 6/6); flipped via kd_flip 2026-10-16. Surface note: SDK 6.0.4 truth is partitionContext.lastEnqueuedEventProperties |
| KD-71 | EH x-opt stamps | x-opt application-property stamps not mirrored | CLOSED-SIMULATED — witness r200b-kd71-xopt-props.md (PASS 4/4 + PK-PROBE); flipped via kd_flip 2026-10-16. KD-76 (minted OPEN for pk-routing) also CLOSED-SIMULATED via r200h re-witness; the "partition-scoped subscribers need pk filtering" nuance was re-witnessed RESOLVED 2026-10-16 (lane-350 witness 11/11: routed partition receives all pk events, hub aggregation intact) |
| KD-77 | AMQP delivery-tag encoding (settle path) | pyamqp decodes 0x98 uuid delivery-tag to UUID → settle `object of type 'UUID' has no len()` | OPEN, **PARTIAL-blocked-flip** per canonical register (BLOCKED-STANDING 2026-10-16): fix landed (r210-kd77-delivery-tag.md, PARTIAL_ALIVE, vbin 0xA0 encode + disposition echo + mgmt-reply + DLQ reason wiring, `# KD-COVERS: KD-77` in frame_codec.ex/connection.ex) but kd_flip.py requires a literal PASS verdict and r210 carries PARTIAL_ALIVE (residual = typed loud skip in test_w3_session_ops.py on a stale locked-survivor premise, not a wire divergence). Flip deferred pending PASS re-witness — registrar-owned, not flipped by this lane |
| KD-78 | ARM api-version admissibility (resourceGroups 2021-04-01 vs azurerm 2023-07-01) | exact-string version check 400'd every terraform apply | **Closed in code + fence; register row still OPEN pending kd_flip.** Code landed: registry.ex:138 now pins `Microsoft.Resources/resourceGroups => "2023-07-01"` and router.ex:1331-1360 implements MONOTONIC api-version admission (any version <= latest admitted; malformed never), both tagged KD-78. Fence: `test/apiversion_matrix_test.exs` → **200 tests, 0 failures** (r213-registry-surface-fence-lane334.md, PASS). Canonical register row not yet flipped — flip is kd_flip.py's job (registrar), gated on a PASS witness newer than the shim; this lane records the on-disk state only |

## A24 audit findings 3-9 (enumeration debt — now ENUMERATED-AS-UNRECOVERABLE, 2026-10-16 audit lane)

A24 findings 3-9 are UNOWNED. Only the R96 follow-up is known to have
landed (receipted in the W6 batch). Enumeration attempted 2026-10-16
(audit lane, read-only + this ledger edit). Result:

1. **The A24 finding list itself was never persisted.** Exhaustive
   search (docs/, scripts/, test/, gates/, tmp/ excluding cert noise,
   git log --all -S"A24" and --grep) finds the token at exactly three
   sites: this ledger, `_LANES.md:111` (both downstream citations), and
   `lib/smalt/messaging/amqp/connection.ex:1979` ("Repair lane R96
   (A24 follow-up)"). No file carries findings 1-9 with file:line
   claims. The minting audit lane's report was never written to disk.
2. **Per-finding classification is therefore impossible without
   minting findings unilaterally** (prohibited — same discipline as
   GAP tokens). No finding 3-9 row is filed here.
3. **The one recoverable A24-referent is verified:** R96 (finding
   follow-up) landed and is receipted — `receipts/r51-r57-r58-r68-r81-
   r95-r96-amqp-batch.md` (PASS, W6 batch): full-URI attach queue-link
   normalization (connection.ex handle_attach; bare_entity at :2202,
   post-authorized? per the :517 note) + removal of the unguarded
   stderr IO.puts at :1979 (Logger.debug-gated). Standing PASS, re-run
   witnessed 2026-10-16 by this lane: `MIX_BUILD_ROOT=_build-audit-a24
   mix test test/amqp/lock_manager_test.exs test/amqp/pyamqp_parity_test.exs
   test/amqp/connection_test.exs test/store_dets_test.exs --include
   amqp_wire` → exit 0, **42 tests, 0 failures** (167.5s).

Classification of the residual: **NOT-RECOVERABLE-FROM-TREE** (neither
FIXED-BY-SESSION nor STILL-OPEN nor OBSOLETE can be asserted — each
requires a finding referent that does not exist). They are neither
closed nor refuted.

Close condition: the A24 minting lane (or the next window's opening
wave, re-running the A24 audit from its prompt) must persist the
finding list with per-finding file:line claims; only then does
per-finding classification (FIXED-BY-SESSION / STILL-OPEN / OBSOLETE)
become executable against the tree. Until then this section stays
open as an enumeration debt with the debt itself now precisely
described.

## Census-replay substrate window — CLOSED

R178e landed: `receipts/r178e-census-replay-repair.md` (ALIVE) — census
exit 0, 11/11 probes PASS (was FAIL 2/11 per park receipt
`receipts/r178e-census-regression-park.md`, PARTIAL_ALIVE), substrate log
clean. Window closed 2026-10-16.

## Pre-existing SUSPECT receipts

21 pre-existing SUSPECT receipts (SUSPECT-21, re-triaged 2026-10-16) are carried, not repaired, this window. Cheap class (b) re-witnesses: receipts/fin-04-gitignore.md, x7-bench-report.md, bench-07-store-beam.md, bench-08-amqp-beam.md in docs/jira/v26.10.14/receipts/ now carry "## Re-witness 2026-10-16" sections (errc2-benchee.md carries an honest SKIP — needs 9443/8443/5672 free); bench-12-consolidation.md and fin32-wrap-final.md are marked SUPERSEDED.
(receipt_index flags receipts with no embedded command output). They are
session-era artifacts from earlier windows; flipping any requires its own
re-run receipt, not an edit. W11 regen count (2026-10-16): 23 SUSPECT
total across all windows — 22 pre-existing session-era receipts plus
r130-r140-not-receipted.md; ZERO of the ten W11 receipts are flagged.

## Product gap: no-delete-container (D127)

Blob container DELETE remains unimplemented by product decision (D127) —
a product gap, not a defect. Any future wire surface that starts refusing
or implementing container delete must cite D127 and update this row.

Teardown scope note (FR-6, 2026-10-16): D127's cascade DOES sweep the
data-plane blob tables (`smalt_blob_containers`/`smalt_blobs`/
`smalt_blob_policy`/`smalt_blob_blocks`/`smalt_blob_snapshots`, "acct/"
prefix via `BlobStorage.drop_account_data/1`) when a storageAccount is
deleted directly or via RG cascade — the gap covers only the per-container
DELETE route itself. Fence: `test/arm_cascade_teardown_test.exs`.

## Operational law (witnessed 2026-10-16): courts vs test tiers serialize

Shim courts and test runs must mutually serialize on shared subjects
(connection.ex, event_hubs.ex, sweeper.ex, queue_store.ex). Witnessed
twice: (1) amqp_framing_court traded the live connection.ex against a
stale Oct-15 snapshot mid-window, producing a phantom 14-failure wire
run (adjudicated VOID — quiet tree 381/0, lane281); (2) disposition
court read the same window as a loud subject-degraded SKIP. Courts
now flock per-subject; wire/full-tier lanes must wait for court
processes to drain (poll shim-court locks) before trusting a red run.
A mid-shim signature is: subject sha256 instability + live
shim-court processes — not SHIM-COURT marker presence (landed code
carries markers too).

## atom_bridge QueueDescription gaps (audit 2026-10-16, schema-complete-for-SDK)

The bridge's 12 emitted fields exactly cover the SDK's throwing
buildQueue getters (queueResourceSerializer.js:46-69, verified
line-for-line). Enumerated gaps vs the real Azure surface, all
optional (deserialize to undefined, no throw): Status, ForwardTo,
UserMetadata, AutoDeleteOnIdle, ForwardDeadLetteredMessagesTo,
AuthorizationRules, EntityAvailabilityStatus, MaxMessageSizeInKb.
Soft spot: getQueueRuntimeProperties needs
SizeInBytes/MessageCount/CountDetails/CreatedAt/UpdatedAt/AccessedAt
— createdAt uses a throwing getDate, so a getQueueRuntimeProperties
smoke leg would fail against the bridge today. PUT round-trip
fidelity gap: atom_queue_properties persists only 4 fields; GET
echoes hardcoded defaults for the rest. No falsifier fired; park
for a future window's probe-authoring rows.

## Carried parks (no receipt yet — named so they cannot quietly drop)

- **dets_mirror union-growth — BOUNDED-WITNESSED (2026-10-16)**: park was
  real — pre-fix census leaked 100/200 stale rows (200 mirror rows vs 100
  live after delete+sync; restore resurrected deleted keys). Fix landed:
  sync is now a projection of live ETS rows (stale-key delete before
  upsert) in `lib/smalt/store/dets_mirror.ex`. Census + fence:
  `test/store_dets_growth_test.exs` — post-fix: 200→100 rows on delete,
  mirror keys == live keys, 5 same-key syncs flat at 50 rows (no
  multiplication); full suite `mix test test/store_dets_test.exs
  test/store_dets_growth_test.exs` → 8 tests, 0 failures (incl. 129s
  insert_new churn race).
- **blob_hardening :1523 perf flake — CLOSED (variance-proofed, 2026-10-16)**:
  root cause was a latent test bug — the page chain never advanced
  (scope-isolated `marker` in the comprehension measured page 1 ten
  times). Chain fixed via Stream.iterate + last-page assert; assertion
  now min-of-3 reps, budget 80→110 ms (measured 62 ms true chain,
  ~1.7x headroom, still trips the ~205 ms full-materialization revert).
  Non-vacuity witnessed (budget=5 → contract violated). 5/5 green
  under 20-lane load. Gotcha: `mix test file:LINE` silently runs the
  PREVIOUS test when LINE lands on a comment/blank — reports green
  either way.
- **ERROR_CODES drift**: r178b (PARTIAL_ALIVE) — DRIFT fence fired on
  concurrent egress_router.ex line moves; `docs/ERROR_CODES.md` regen is
  a generated artifact, deferred to the fin-sweep regen pass
  (`just gen-error-codes`), in flight. Never hand-patched.
- **ERROR_CODES extractor blind-spot (2026-10-16, lane 10 wrap-docs)** —
  `docs/ERROR_CODES.md` (generated) omits two emitted wire codes the
  extractor does not source: **PolicyViolation** (emitted by
  `lib/smalt/policy.ex:490` via the deny path at
  `lib/smalt/arm_gateway/router.ex:778`) and **InvalidEventGridEvent**
  (emitted by `lib/smalt/egress_router.ex:3072`). Named as NEXT_WINDOW
  item 7 (extractor extension); close condition lives there — extractor
  picks up both sources, `just gen-error-codes --check` green.
- **rg-delete deny-by-default reclaim gap (code-review minor 9, 2026-10-16, lane 421)**:
  NO code — ledger row only. `Smalt.ArmGateway.Router.handle_rg_delete/2` on a
  malformed/corrupt resource-group record returns 404, so the cascade never
  runs and orphaned children are unreclaimable via the delete path
  (deny-by-default: refusal leaves no sweep). Close condition: a typed
  409/410 or an admin reclaim sweep for RGs whose stored record fails
  decode; owned by the ARM gateway surface.

## GAP owner proposals

- **GAP(ledger-lazy-create-default) — close-condition proposal (option c)**:
  WIRE_PARITY.md:121 premise audit. Code: confidential_ledger.ex:40-60
  (flag gate :49, lazy default :58), ledger_writer.ex:69-83 (in-writer
  fence, LedgerNotFound 404 :71). Real-service docs (Microsoft Learn,
  "Data Organization in Azure Confidential Ledger") specify Collection/
  Subledger IDs as user-specified optional keys supplied at write time
  with NO creation step and no pre-existence requirement (unnamed
  writes default to subledger-0); the append-404/creation flow exists
  only for the ARM ledger RESOURCE, not per sub-ledger name. Smalt's
  per-name ledgers model sub-ledgers, so the DEFAULT lazy-create
  matches real-service semantics — no falsifier needed. Close
  condition: re-grade the token to MATCHED (emulator default = service
  behavior); retain `ledger_enforce_existence` as a deliberate
  strictness opt-in documenting ARM-resource semantics, and correct the
  stale comment premise at confidential_ledger.ex:42-43 on next touch.
  Evidence: 2026-10-16 DoD audit lane; learn.microsoft.com
  confidential-ledger data-organization.

- **GAP(blob-worm-gate-fixture-corpus) — proposal: test-tier coverage
  sufficient, gate extension NOT warranted** (2026-10-16 DoD audit lane).
  The gate is wire-level and the arms are not reachable on the wire it
  drives: @blob_put_comps ~w(block blocklist metadata) (egress_router.ex:39)
  and the GAP-AUD1-01 fail-closed fence (egress_router.ex:1234-1246)
  answer 400 for any unhandled comp, so ?comp=snapshot/?comp=tier never
  reach check_worm_arm; set_blob_tier is wired only via $batch
  (batch_dispatch_op, egress_router.ex:2231). Gate fixtures would assert
  the 400 fence, not the WORM arms — structurally vacuous for KD-52.
  Arms already mutation-pinned at test tier: four KD-52 assertions in
  test/data_plane/blob_hardening_test.exs:124-190 + dedicated court
  blob_worm_arms_court.sh (typed flip, sha256 restore). Receipt:
  receipts/r188-r196-r197-worm-settle-batch.md. Future trigger: if
  snapshot/tier gain single-op wire routes, add snapshot-under-hold /
  tier-under-hold fixtures (409 ContainerLocked, accepted-variant
  refused) per the existing mutate_fixtures pattern.

## Wave-surfaced register candidates (Phase 4 item 12, docs lane, 2026-10-16)

Candidates surfaced by the wave, registered here as documented
candidates/parks ONLY. No KD rows or GAP tokens minted by this lane —
row/token minting and flips are registrar-owned (kd-registrar), and GAP
tokens are never minted unilaterally. Each entry names its referent
(file:line) and close condition.

1. **resourcegraph unparseable-KQL → 200-inventory-leak** —
   `POST /providers/Microsoft.ResourceGraph/resources` with a query the
   KQL parser cannot classify falls through to match-all: wire `200`
   with the unfiltered inventory where real Azure answers typed
   `400 BadQuery`. Referent:
   `docs/jira/v26.10.16/sdk-results/ts-resourcegraph.md:29` (DIVERGENCE
   row 5) and `:44-52` (finding D1, names
   `lib/smalt/data_plane/resource_graph.ex` as the fall-through site).
   Close condition: a typed 400 (BadQueryError-class) for unclassifiable
   KQL over real `Router.call/2` dispatch + a KD row minted by the
   registrar citing this receipt as close-condition evidence.
2. **ledger receipt.contents double-nesting** — POST body
   `{"contents": {...}}` yields wire receipt
   `{"contents": {"contents": {...}}}`; azure-confidentialledger
   surfaces the payload directly at `receipt["contents"]`. Shape-only
   (inner payload round-trips intact), pinned by probe check 3.
   Referent: `docs/jira/v26.10.16/sdk-results/py-ledger.md:38-43`.
   Close condition: registrar mints a ledger-family KD row; fix (or
   contract-pin the emulator convention) with a wire-visible probe
   receipt.
3. **azapi-lock-if-match-unverified (proposed, never minted)** —
   `check_lock_precondition/2` treats If-Match as presence-only; a
   mismatched etag yields 200 where real Azure returns 412
   PreconditionFailed. Proposed as `GAP(azapi-lock-if-match-unverified)`
   in Decision (b) of `docs/jira/v26.10.14/20-arm-gateway-hygiene.md:41`
   (decision gate restated :61) but the token was never minted in
   WIRE_PARITY. Close condition: EITHER Decision (a) lands — value-
   verified If-Match, mismatch → 412 over real `Router.call/2` dispatch,
   pin updated in `test/azapi_actions_test.exs` — OR the registrar
   mints the GAP token and the "pinned actual" test comment links it.
   Until then the gap is untokenized (silent, contrary to fence law).
4. **D127×FR-6 cascade interaction** — resolved wording, registered
   verbatim: ARM resource-group delete cascades and sweeps the blob
   containers inside the group per the D127 product decision
   (`lib/smalt/arm_gateway/router.ex:611` cascade comment — now :647 after
   the FR-6 D127 data-plane sweep landed; D127 row
   WRAP_LEDGER.md:71-75), while per-container DELETE remains the D127
   product gap — the cascade is not an implementation of container
   delete and does not close it. Note: "FR-6" carries no on-disk
   referent anywhere in the tree (exhaustive grep 2026-10-16); the
   interaction is pinned by the two referents above. Close condition:
   none needed — resolved wording on record; only revisit if a future
   surface starts refusing or implementing per-container DELETE (must
   cite D127 and update WRAP_LEDGER.md:71-75).
5. **SB subscription-rules 501 + reply_to drop** — already registered;
   cross-link only. Referents: `docs/WIRE_PARITY.md:145` (typed
   UNSUPPORTED row, V261014-08), NEXT_WINDOW.md section 9 (carried
   parks), `docs/compliance/C5_SERVICEBUS.md` R11. Close condition:
   parked fix (store reply_to on ingest, emit in build_properties,
   census probe; subscription-rules/filter-engine feature-scale) — see
   NEXT_WINDOW section 9; receipt-gated flip of the WIRE_PARITY row.
6. **metadata-doc `microsoftGraphResourceId` blocker** — all six
   terraform provider plan legs (cosmos, eventhub, keyvault, rg,
   servicebus, storage) fail metadata retrieval: "no
   `microsoftGraphResourceId` was returned". Referent:
   `docs/jira/v26.10.16/sdk-results/tf-plan.md:14-19`. Status: P1
   blocker; expected to be resolved by the P1 re-witness rather than a
   code change on this surface. Close condition: re-witness run shows
   the metadata endpoint returning `microsoftGraphResourceId` (or a
   registrar-minted divergence row if the field is contract-pinned
   absent); tf-plan census updated from DIVERGENCE on a green run.

## W11 receipts written

r174 (TLS trio + fuzz non-repro, PASS), r166 (EH discriminator +
dead clause, PARTIAL_ALIVE — R185e pair red on tree), r177 (sentinel
column cut, PASS), r177b (KV DigestInfo, PASS 44/0), r177c (KQL union
narrow, PASS 23/0), r177f (wave-telemetry CLEAN holes, PASS loud),
r178b (error-codes helper window, PARTIAL_ALIVE — drift fence fired,
regen deferred to fin sweep), r178c (bare_entity sync, PASS 30/0),
r178d (probe venv docs, PASS docs-only), r178e (census park,
PARTIAL_ALIVE); late landings now on disk: r178e-census-replay-repair.md
(ALIVE — census window closed, see above), r185e-eh-batch-dup-kind.md
(EH batch dup-kind lane). Skipped as already on disk: r163, r172, r173.
Batch receipts r207–r209 (lane 294, 2026-10-16, all PASS) close
unaccounted-diff items 1–7, 9, 10, 12 of the 2026-10-16 pre-commit audit.
Items 8 and 11 are now closed too: item 8 (dets census) is
BOUNDED-WITNESSED — fix landed in `lib/smalt/store/dets_mirror.ex` with
census+fence `test/store_dets_growth_test.exs` (see the carried-parks
dets_mirror entry above); item 11 (generated ggen artifacts) is
replay-identical per the artifacts-replay lane (regen matches on-disk
projections; receipts r207–r209 cover the batch). No in-flight owners
remain.

## Native pipeline (landed 2026-10-16, docs lane consolidation entry)

The external-Go/terraform-binary enclave lifecycle is replaced in-BEAM:

- **Modules landed**: `lib/smalt/enclave/hcl.ex` (HCL parser),
  `lib/smalt/enclave/engine.ex` (plan/apply engine),
  `lib/smalt/enclave/state.ex` (tfstate),
  `lib/smalt/enclave/lifecycle.ex` (provision→destroy→residue
  orchestration). Fence: `test/enclave_hcl_test.exs`.
- **Lane**: `scripts/enclave_native.sh` (bench lane id `e2-native`) —
  boots NOTHING external (no sockets, no TLS, no terraform binary, no
  Go processes); runs in-process over `mix run --no-start` with only
  the Store ETS owner; emits one bench_emit-shaped jsonl row per run.
  Exit contract 0/1/3.
- **Witnessed this lane** (real run, exit 0):
  `MIX_BUILD_ROOT=_build-lane-docs bash scripts/enclave_native.sh` →
  `[enclave-native] PASS` — timings: parse 16 ms, plan 5 ms, synthesize
  2 ms, apply 110 ms, destroy 31 ms, residue 0 ms (n=3 resources:
  RG + KeyVault + StorageAccount, full PUT→DELETE→404 lifecycle over
  the real ARM gateway). Honest note: the full-lifecycle apply hop is
  110 ms — per-hop sub-100 ms everywhere except apply; total wall is
  sub-200 ms. The external Go runner is demoted to **T4-external
  compat** (tf-binary tier only; the native lane no longer depends on
  it).

## Fin-sweep checklist (refreshed 2026-10-16, docs lane)

Run in order after the two-green court-x2 receipt lands:

**DONE (2026-10-16):**

- [x] 6. Generated artifacts regenerated (`just receipt-index`,
      `just bench-report`, `just sdk-matrix-md`, `just gen-error-codes`).
- [x] 7. `just docs-dod-check` green (0) at the pre-wrap tree.
- [x] ERROR_CODES drift converged — the r178b park (DRIFT fence fired on
      concurrent egress_router.ex line moves) is closed by the regen pass;
      `docs/ERROR_CODES.md` is a generated artifact, regenerated not
      hand-patched. Carried-parks entry above is historical record.
- [x] Enclave trust → shim reclassification landed ("Enclave trust hop"
      section above; tf_trust_setup.sh gates the host-setup prerequisite,
      T3/T5 execute on any trusted machine).

**REMAINING (in order after court-x2):**

1. `just court-x2` — the two-green release receipt gate (not yet run at
   the wrapped tree).
2. Mint the release receipt post-court: draft on disk at
   [release-receipt.md](release-receipt.md) (schema `chatman/release-receipt/v1`,
   standing **DRAFT-STANDING: PENDING-COURT**, supersedes the prior red
   court-x2 attempt at `fd9cfea`); the green court-x2 run replaces the
   placeholder SHA / execution block / mutant-kill report via
   `scripts/mint_release_receipt.py` — the draft never becomes evidence by
   edit, only by the real run minting over it.
3. Land commit SHAs into FINAL.md (each lane's landing commit named with
   its exact SHA; FINAL.md carries the planning handoff pointer to the
   next window).
4. `just publish-dry` re-run on the wrapped tree (tarball leak greps +
   ERROR_CODES identity must be green at the final SHA, not the pre-wrap
   SHA).
5. Confirm RELEASE_NOTES landing (v26.10.16 notes on disk and named in
   the release commit).
6. Confirm CHANGELOG entry for v26.10.16 exists and matches the release
   notes.
7. `just lane-clean` — reclaim all lane build roots before the final
   commit (cleanup law: leases, not assets).
8. Gap-census residual (flagged 2026-10-16 gap-sync lane): the live-gap
   floor in 10-gap-register-sync.just still counts the struck
   eventhubs-partition-metadata-absent token (its exclusion list
   predates the closure); passes but the open-token census is 9 where
   the honest count is 8. The matching "open, tokenized, 9" string in
   docs/jira/v26.10.14/receipts/13-gap-register.md is a historical
   receipt — records are not edited; align the justfile exclusion list
   only, in a next-window docs pass.

## W13 late (2026-10-16, in flight — owner items, not yet closed)

- Stage-script CHANGELOG classify fix landed: staging would have
  REFUSED on the v26.10.16 entry before the classify repair.
- CLI banner KD-honesty: KD-77 skips are now named in the banner
  instead of silently passing.
- KD-77 implementation lane LANDED: r210 (`receipts/r210-kd77-delivery-tag.md`,
  PARTIAL_ALIVE) — register flip blocked on PASS re-witness (see KD parks
  table KD-77 row). queue_store:332 flake repair: superseded by the
  landed courts batch (r211).
- Aggregate final re-run + courts batch receipt r211 LANDED
  (`receipts/r211-courts-final-batch.md`): 4 PASS + 1 loud SKIP
  (disposition_token) — see Courts final standings.

## Courts final standings (recounted 2026-10-16, lane 10 wrap-docs close)

Recount `ls scripts/shim_court/*_court.sh` → **25 court scripts on disk**
(amqp_framing, atom_bridge, blob_worm, blob_worm_arms, blocklist,
comp_whitelist, conftest_proc_guard, corpus_fence, dets_growth,
disposition_token, eh_batch, eh_mgmt, enclave_loop, etag_cas, ets_cleanup,
kv_challenge, ledger_chain, lock_clamp, orphan_token, queue_capacity,
renew_mirror, settle_cas, strata_cleanup, tombstone_grace, wire_norm).

- **22 witnessed**, aggregate **21 PASS / 1 loud SKIP**:
  - 20 carried PASS including the settle_cas=742 and renew_mirror=566
    re-anchors (settle_cas witnessed in
    `receipts/r211-courts-final-batch.md`, lane 311, exit 0 after
    disclosed anchor repair; renew_mirror re-run on the 566 anchor —
    BEFORE old-signature holds, R194 test fails under shim, restore
    byte-exact, `[PASS] renew_mirror_court` EXIT=0).
  - r211 adds ets_cleanup / atom_bridge / amqp_framing as fresh PASS
    (all non-vacuous, restore byte-exact).
  - disposition_token: **PARTIAL_ALIVE per r211** — loud SKIP (exit 3,
    "subject degraded: connection.ex lacks lock_token settle
    threading"), flip already landed in connection.ex; close condition
    named in r211 (re-run to PASS). Counted in the 22 witnessed, not a
    fake pass.
- **3 not in the receipt-witnessed aggregate**: dets_growth and enclave_loop
  (session-witnessed PASS exit 0 in the ERRC section below — **witness
  receipt PENDING**, no receipt names either yet) and corpus_fence (fully
  unwitnessed, listed as the 25th script). All three excluded from the
  22-witnessed aggregate until receipts land; receipt minting is the
  courts-owner's job, not this lane's.

## Enclave trust hop — reclassified host-setup prerequisite (2026-10-16)

Operator ruling: the dev workstation does not enter the enclave — darwin
keychain trust of smalt-dev-ca is a local bootstrap prerequisite, not an
enclave capability. tf_trust_setup.sh gates it loudly (fingerprint +
dump-trust-settings parse); T3/T5 (tf_smoke, tf_cleanroom) execute on any
trusted machine without blocking the v26.10.16 substrate deliverables.
The e1 lane's SKIP-LOUD semantics already encode this: absent trust =
loud per-family skips, never fake passes.

## Native lifecycle equivalence + external-tier retirement (2026-10-16, lane 409)

- `sdk-results/native-lifecycle.md` (ALIVE): native in-process lifecycle
  green (test 1/0; in-process run: parse 3 / apply 52 / plan 2 /
  synthesize 1 / destroy 15 / residue 0 ms; zero-drift plan []; 3 ids
  byte-identical to the external tfstate read from the T5 cleanroom
  lane's isolated fixture). Residue stage verified 17 tables empty;
  NFR-4 identity = tables alive + empty post-destroy.
- External terraform tier (smalt-tf + raw terraform) DEMOTED to opt-in
  T4-external wire-compat suite; native lifecycle is the primary green
  gate. Tier is single-flight on three global resources (fixture state
  lock, .smalt/tls cert regen, provider mirror) — degradation witnessed
  live and embedded in the receipt. Ruling recorded in
  `NEXT_WINDOW.md` section 12.
- One scratch artifact disclosed: an orphaned mid-cycle
  `terraform.tfstate` (concurrent lane's) parked to
  `/tmp/lane409-fixture-orphan/` to unblock the shared fixture.

## T5 tf_cleanroom — authored, execution-gated (2026-10-16)

T5 clean-room ladder authored by the consolidation lane:

- Receipt skeleton: `sdk-results/t5-cleanroom.md` — stage table, timing
  columns, per-stage pass criteria for the operator's ladder (apply →
  plan 0 drift → data-plane audit → destroy → NFR-4 identity), budget
  gates (apply/destroy < 30 s each), exit contract 0/1/3. Standing
  **PENDING-EXECUTION**; the validation lane fills it with real output.
- Ladder semantics + budget gates: `docs/BENCHMARKS.md` ("T5 terraform
  clean-room ladder" section).
- Execution is gated on (a) the cascade lane landing and (b) a trusted
  machine per the enclave-trust hop ruling (see "Enclave trust hop"
  section above). No receipt, no flip: PENDING-EXECUTION → PASS only
  with embedded real stage output; any red stage types FAIL, never a
  silent re-skip.
- ggen semantic-kernel roadmap (5 prototype lanes → pack projections;
  single authoring surface; gate dual-run semantics) appended to
  `NEXT_WINDOW.md` section 11.

## Zero-touch trust — hardened-runtime boundary (2026-10-16, shim integration lane)

**SUPERSEDED 2026-10-16** (shim-v2 verification lane,
sdk-results/shim-v2-verification.md section 2): this section's mechanism
claim is wrong in both directions. Hardened binaries (terraform CLI
`flags=0x10000(runtime)` — NOT ad-hoc — and the azurerm provider) DO load
the shim when launched directly; the real zero-touch boundary is that dyld
strips `DYLD_INSERT_LIBRARIES` from CHILD environments, so the shim covers
directly-launched leaf processes only, and the terraform→provider hop gets
nothing. The demotion rulings below (native tier primary, external wire
tier opt-in keychain trust) stand unchanged.

The trust shim (DYLD interpose, fingerprint-pinned, loopback-gated) covers
ad-hoc/non-hardened binaries only. Witnessed: the azurerm provider plugin
is hardened-runtime (codesign flags=0x10000) — DYLD_INSERT is silently
ignored there, and darwin Go ignores SSL_CERT_FILE. Consequence:
- Native tier (in-process HCL → Router dispatch): fully zero-touch,
  zero TLS — the PRIMARY gate. Unaffected.
- External wire tier (real azurerm): still requires the one-time opt-in
  keychain trust on darwin (scripts/tf_trust_setup.sh trust) OR a
  non-darwin runner with SSL_CERT_FILE. The shim covers the terraform
  CLI + probes (ad-hoc signed); re-signing the provider breaks the
  dependency-lock checksums (witnessed, reverted).
Also landed en route: SKI/AKI-compliant cert mint (Apple strict
evaluator rejected SKI-less leaves), gen_dev_cert self-heal against
dev-cert clobbering (witnessed 3x concurrent overwrites), presented-
chain scanning in the shim (evaluated chain drops self-signed CAs).

## Zero-touch validation lane — shim path does NOT flip terraform's TLS verdict (2026-10-16, lane 397)

**SUPERSEDES the "trusted machine" gating in "Enclave trust hop" and
"T5 execution gate (b)"** in one direction only: keychain trust is
DEMOTED from gate to OPTIONAL persistent alternative (scripts/smalt-tf
already treats it as fallback-only). But the validation verdict on the
shim path itself is **typed FAIL — not flip-capable for terraform**.
The zero-touch contract (no GUI, no sudo, no keychain mutation) was
exercised end-to-end with run evidence; it did not flip.

Precondition (documented, unchanged before and after every run):
`scripts/tf_trust_setup.sh status` → `FAIL — cert imported but ZERO
trust settings` (later `FAIL — DEAD CA` after concurrent CA re-mints),
exit 1. Exit 1 is the EXPECTED zero-touch precondition. No GUI dialog,
no sudo, no keychain mutation at any point in this lane.

Run evidence (all on lane ports 39410/39411, ad-hoc re-signed terraform
core on PATH where named):
1. `SMALT_TF_PORT=39410 SMALT_TLS_PORT=39411 bash scripts/tf_smoke.sh`
   (7 attempts): substrate boot PASS, offline-mirror `tf init` PASS,
   token POST landed on substrate PASS — then `tf plan` FAIL. Typed
   blocker chain, each step witnessed:
   a. Hardened runtime: homebrew terraform (`flags=0x10000(runtime)`)
      and mirror-installed azurerm/azapi providers silently ignore
      DYLD_INSERT_LIBRARIES → plan x509 `"localhost" certificate is not
      trusted`. Ad-hoc re-sign works mechanically but breaks the
      dependency-lock h1 checksums at plan (`cached package ... does
      not match any of the checksums recorded`) — by design, not a bug.
   b. **Even when the shim IS delivered** (ad-hoc go1.23.4 and go1.25.4
      crypto/tls probes, correct SMALT_CA_SHA256 pin, real loopback TLS
      dial against the dev chain): verdict unchanged — `x509:
      certificate signed by unknown authority` with and without the
      shim. Go's crypto/x509 never consults SecTrustEvaluate /
      SecTrustEvaluateWithError for the TLS verdict; the interpose
      surface of smalt_trust_shim.dylib is unreachable from Go.
      test/trust_shim_probe passes only because it calls
      SecTrustEvaluateWithError directly via cgo — vacuous for Go.
   c. SSL_CERT_FILE confirmed ignored on darwin (go1.23+go1.25 probes).
   d. Concurrent-lane leaf churn: lib/smalt/tls.ex auto-mint rewrites
      dev-cert.pem (self-signed CN=127.0.0.1) racing gen_dev_cert.sh
      (self-heal witnessed firing twice this lane); a mid-run remint
      also desyncs the shim's pinned fp from the served cert.
2. `tf_plan_check.sh` (six fixtures) and T5 `tf_cleanroom.sh`: NOT
   executed — the only witnessed-working trust path for the real
   azurerm provider on darwin remains keychain trust (opt-in, out of
   contract for this lane), and tf_plan_check.sh line ~59 performs a
   keychain `add-trusted-cert` attempt, which this lane's contract
   bans. Typed FAIL/NOT-EXECUTED, not a silent skip.

Verdict: zero-touch terraform-over-TLS on darwin requires a **shim v2
that interposes the anchor-enumeration surface Go actually reads
(SecTrustCopyAnchorCertificates — append the pinned CA for loopback
hosts)** rather than SecTrustEvaluate; or serving the metadata
endpoint over http (azurerm may not accept it); or the one-time
keychain trust. Until then: native lifecycle tier remains the primary
zero-touch gate (lane 409's demotion ruling stands); external wire
tier (T3/T5 on real azurerm) remains execution-gated on the opt-in
keychain trust — now as PERSISTENT ALTERNATIVE, not a "trusted
machine" class requirement.

Scratch disclosed (lane leases, not assets):
tmp/lane397-bin/ (wrapper), tmp/lane397-tlsprobe/ (go probes),
tmp/lane397-*.log. No lane build roots created.

## ERRC cycle (2026-10-16, errc-cycle skill — EDRC order executed)

- **ELIMINATE/tighten — gap-census residual CLOSED**: struck
  `eventhubs-partition-metadata-absent` added to the exclusion list in
  `justfile.d/10-gap-register-sync.just`; live census tightened 9→8 (honest
  count verified: 13 unique tokens − 5 exclusions = 8); OK banner updated to
  name the historical lane-13 "9" explicitly. `just gap-sync` exit 0.
- **RAISE — dets_growth + enclave_loop courts session-WITNESSED, witness
  receipt PENDING** (re-scoped at lane-10 close per sync-fixes D5: no witness
  receipt names either court, so they remain OUTSIDE the 22-receipt-witnessed
  aggregate until receipts land):
  both PASS exit 0 this session — dets_growth: BEFORE 2/0 green, AFTER growth
  census fails under shim (200-vs-100 leak), restore byte-exact; enclave_loop:
  all three families' SKIP-LOUD emissions proven load-bearing (loud→silent-PASS
  flip observed per artifact), restores byte-exact. `just shim-courts` run
  covered both; the flip evidence lives only in this session record until a
  witness receipt is minted.
- **CREATE — SUSPECT triage receipt r214 LANDED**
  (`receipts/r214-suspect-triage.md`, standing PASS): honest census 16 SUSPECT
  (re-derived from receipt_index.py at execution time; prior 21/23 drafts
  stale), split 14 historical-accept + 2 leave-flagged (bench-12-consolidation,
  fin32-wrap-final — SUPERSEDED banners verified in-body, no indexer change).
  NEXT_WINDOW section 3 close condition satisfied.
- **Stale/parked**: KD-77 flip (registrar-owned, PASS-witness gate per
  register row — not acted on); tf-plan apply-shape divergences — repairs
  verified LANDED in `lib/smalt/arm_gateway/router.ex` (networkRuleSets
  default GET, listKeys context, vaultUri/primaryEndpoints enrichment), item
  skipped per handoff; "blob_hardening minCount-0 sweep pattern" — NO on-disk
  referent found anywhere in docs/scripts/gates (grep across v26.10.14/15/16
  receipts, NEXT_WINDOW, WRAP_LEDGER): carried item is unlocatable, needs a
  file:line referent before it can be acted on (parked with typed UNKNOWN).

## W15 wrap-prep (2026-10-16, wrap-infra lane)

- **10 landed cap receipts now linked** (artifacts on disk): cap-appconfig-kv,
  cap-monitor-metrics, cap-blob-snapshot-metadata, cap-sb-eh-apiversion-2024,
  cap-eh-consumergroups, cap-eventgrid-topics, cap-cosmos-throughput,
  cap-ex4pm-emitters, 08-servicebus-census, b42-dataplane-saturation.
- **KD-80/81/83/87 minted this window** (OPEN rows in the canonical register;
  flips are registrar-owned, fixes next-window).
- **3 compile-freeze SLA disclosures** on record (_LANES.md W14 section):
  sb_rules.ex char-literal (lane 430), router.ex stale-cond (lane 521),
  cosmos record_key + router rg_name (lane 526).
- **Witness chain closed 2026-10-16 (lane 10 wrap-docs)**: the wave's last
  outstanding witness, [r215-affidavit-seal-court.md](receipts/r215-affidavit-seal-court.md)
  (lane 5 VERIFY), is on disk at standing **WITNESS-PENDING** (PARTIAL_ALIVE —
  seal path, verify-op court, doctor green, 113/0 green ladder run; ladder
  flake DEF-1 + red `appconfig-etag-cas` gate DEF-2 named; no PASS claimed).
  KD-89 stays OPEN / witness-PENDING per the amended close condition; flip
  registrar-owned.

## PQC attestation-debt closure (KD-89) — PARTIAL, witness pending

Standing: PARTIAL_ALIVE — implementation landed, D-lane ladder witness
receipt NOT yet on disk. This section flips to full closure only when that
receipt lands; no receipt, no flip.

Operator-specified closure of KD-89 (v26.10.14 register row, KD-89
"trust_profile PQC path": close condition = wasm artifact shipped +
`just doctor` OK + forge-rejection court green; falsifier = forge-tampered
ML-DSA-65 signature rejected by the wasm engine court, honest signature
accepted):

- **wasmex-mounted `affidavit_wasm`**: engine landed at
  `/Users/sac/smalt/lib/smalt/affidavit/wasm_engine.ex` with the live
  vendored artifact `/Users/sac/smalt/priv/wasm/affidavit_wasm.wasm`
  (+ checksum `/Users/sac/smalt/priv/wasm/affidavit.sha256`). The
  operator-mandated real-run test
  `/Users/sac/smalt/test/smalt_affidavit_wasm_test.exs` exists on disk —
  3 tests, no mocks, no skips: (1) `call_admit_and_seal/4` (tariff 12345,
  modality 0x01) returns a 352-byte CTRT with magic "CTRT"; (2) tariff
  basis cents round-trip byte-exact at CTRT offset 167 (8-byte LE u64);
  (3) fail-closed tier — oversized payload (> 16 MiB) returns typed
  `{:error, :payload_too_large}`, garbage delta returns typed
  `{:error, _}`, and a subsequent well-formed call still succeeds (no
  crash-loop). A genuine engine load failure is a verbatim BLOCKED flunk,
  never a skip.
- **CTRT seal path**: the 352-byte / "CTRT"-magic / offset-167 LE u64
  tariff layout is asserted in the test file above; the seal module is
  `/Users/sac/smalt/lib/smalt/affidavit/seal.ex`.
- **ML-DSA-65 witness block replacing `:PQC_NOT_PROVISIONED` when engine
  live**: operator-specified contract. The typed refusal currently stands
  at `lib/smalt/trust_profile/trust_profile.ex` (profile scaffolding; see
  `/Users/sac/smalt/docs/jira/v26.10.16/sdk-results/pqc-attestation-audit.md`,
  which records the refusal verbatim). Replacement of the refusal with the
  live-engine witness is receipt-gated on the pending D-lane ladder output.
- **Typed refusal retained as fail-closed fallback**: the
  `:PQC_NOT_PROVISIONED` typed refusal stays as the fail-closed fallback
  path alongside the live engine; the test file's fail-closed tier
  (typed errors, no crash-loop) witnesses the same discipline at the
  engine layer.

**Pending witness (named)**: the D lane's ladder receipt for
`test/smalt_affidavit_wasm_test.exs` (expected in
`docs/jira/v26.10.16/receipts/`). Not on disk at section-write time —
newest receipt present is
`/Users/sac/smalt/docs/jira/v26.10.16/receipts/lane606-affidavit-seal-event.md`
(a sibling lane: affidavit.seal OCEL event emitter + fence test
`test/affidavit_ocel_emit_test.exs`, 3 tests 0 failures, standing ALIVE;
it also discloses a compile-freeze SLA unblock touching
`lib/smalt/affidavit/wasm_engine.ex`). KD-89 register row remains OPEN
pending doctor + forge-court witness; flip is registrar-owned
(`scripts/kd_flip.py --apply`).

### Honesty correction (2026-10-16, milestone-doc lane, validator-witnessed)

The KD-89 closure contract above is overstated on two axes. (1) Validator
inspection of the upstream seal path — `WireCtrt`
(`/Users/sac/affidavit/src/wire_ctrt.rs:249,283,305`) and the handler that
builds it (`/Users/sac/affidavit/src/handlers.rs:336`) — shows the CTRT
112-byte witness region `[240..352]` (`pqc_witness_signature`) is never
populated: it serializes as **ZEROS**, and `compiler_binary_digest` is a
`0x5a` placeholder (`handlers.rs:336`). No ML-DSA-65 signature bytes are
embedded in the sealed CTRT today.

(2) The wasm engine smalt mounts (`affidavit-wasm`) has **no ML-DSA-65
verify path**. Its `verify_signature` op
(`/Users/sac/affidavit/affidavit-wasm/src/signature.rs:29-55`) supports
only `ES256` / `ES256K` / `Ed25519`; `ML_DSA65` returns
`unsupported_algorithm`. Real ML-DSA-65 math (`ml_dsa65_verify`,
`crypto_trust_pqc.rs`) exists in the affidavit **CLI crate**
(`/Users/sac/affidavit/src/`), which smalt does not mount — not in the
wasm engine.

What IS real and live for smalt: the CTRT **seal path** (PQC-free by
construction) and the wasm engine's classical `verify_signature`
adjudication. Sealing is PQC-free; engine-side PQC verification does not
exist yet.

**Corrected live witness contract for smalt**: today there is **no**
PQC witness surface at all — no CTRT-embedded signatures (region zeroed)
and no engine ML-DSA-65 verify op (unsupported upstream). Any
"ML-DSA-65 verify-op verdict over sealed content" contract is aspirational
until the upstream engine gains ML_DSA65 support.

**Standing scope**: `:PQC_AFFIDAVIT_SEALED` may only claim (CTRT seal +
classical verify ops); the zeroed `[240..352]` witness region and the
engine's missing `ML_DSA65` support are both named as
**affidavit-side (upstream) typed gaps**, not smalt-side ones.

**KD-89 close condition, amended accordingly**: KD-89 close **requires
upstream work first** — the wasm engine's `verify_signature` must support
`ML_DSA65` before any forge-rejection court can exercise a PQC verify
path. Once upstream lands it, the court must exercise the **VERIFY path**
(forge-tampered content rejected by the ML-DSA-65 verify op over sealed
content, honest content accepted). A court that only asserts CTRT byte
layout does not satisfy the close condition while the witness region is
zeroed and the engine verify op is classical-only.
## c11 substrate typed findings (bench-c11-tf-loop, 2026-10-16 — ledgered by lane 4 errc)

Typed substrate gaps surfaced by the c11 tf-loop lane, each a real run
failure first; full run evidence lives in
[receipts/bench-c11-tf-loop.md](receipts/bench-c11-tf-loop.md) ("Typed
findings" section). Carried here so they cannot quietly drop; fixes are
next-window work orders.

1. **blobServices/default singleton 404** — azurerm 4.54 storage create
   GETs `.../blobServices/default` and the ARM plane 404s it (only
   file/queue/tableServices defaults are synthesized,
   `lib/smalt/arm_gateway/router.ex:3060`). Blocks azurerm storage
   account apply.
2. **azurerm cosmosdb CheckNameExists pre-check unparseable 400/EOF**
   from the ARM plane — blocks azurerm cosmosdb apply; cosmos exercised
   data-plane only.
3. **ARM-vs-blob store split** — ARM child-container PUT returns 201
   into a store the blob data plane does not read
   (`:smalt_blob_containers` DETS vs ARM store); data-plane blob PUT
   then 404s ContainerNotFound.
4. **Cosmos query-feed no-filter + stale pre-seeded projection** —
   collection create is POST-only (`egress_router.ex:318`) and the query
   feed ignores parameterized filters AND is not scoped to the addressed
   db/coll: on a fresh run-unique db it returned a doc the run never
   wrote (witnessed `ids=["doc_132"] want c11-doc-1`, lane R7
   duplicate-dispatch disclosure; also `doc_259`/`doc_325`/`doc_388`
   across runs). Registered as **KD-93** (OPEN). Honesty note: recorded
   informationally in the lane — the green "ryw cosmos doc put/query"
   row gates on the direct doc GET (wire transport + single-doc read),
   NOT on query-feed read-your-write; query-feed ryw remains
   unproven.
5. **kv PurgeDeleted route unimplemented** — RouteNotFound on
   `/providers/Microsoft.KeyVault/locations/:loc/deletedVaults/:vault/purge`;
   tf destroy aborts mid-graph leaving the RG. Related (informational):
   azurerm create-then-exists double-check recovery = terraform import +
   re-apply; RG DELETE 404-poll passes while the child vault survives.

Close condition (each): a wire-visible probe receipt over real
`Router.call/2` dispatch showing the fixed surface, or a registrar-minted
KD/GAP row registering the divergence — no silent park.

- **DEF-2 solo-classification (lane 2 REPAIR, 2026-10-16) — two typed
  FLAKE_SOLO rows, both load-churn-only**: DEF-2 (appconfig gate) was a
  gate defect, fixed, not a flake (see
  `tmp/invariant-gates/appconfig-adjudication.json`). The two churn-red
  tests pass solo twice each on fresh build roots:
  - `test/wire/amqp_wire_test.exs:56` (protocol-header frame):
    FLAKE_SOLO (deterministic-solo ruled out — 2/2 green solo,
    `MIX_BUILD_ROOT=_build-lane631-c1/c2`, fresh compile each run,
    `mix test test/wire/amqp_wire_test.exs:56 --include wire` →
    `1 test, 0 failures`, EXIT=0 twice, 0.07-0.09s). Hypothesis: the
    churn-window failure is port/listener contention under concurrent
    lanes, not protocol logic.
  - `test/pplan_test.exs:2631` (post-restart 10k-op fuzz):
    FLAKE_SOLO (2/2 green solo, fresh roots, `1 test, 0 failures
    (72 excluded)`, EXIT=0 twice, 2.2-2.4s). Hypothesis: barrier-batch
    timing budget under 20-lane load; law asserts hold either way.

- **court-x2 run 2 red class — native HCL ladder suite (2026-10-16,
  lane 5 residue close)**: `test/smalt_native_hcl_ladder_test.exs` went red under
  full-gate ordering in court-x2 run 2 while green solo ×4 and green
  in run 1 — an ordering/churn-window red, same class as the two
  FLAKE_SOLO rows above, not an assertion failure on the law.
  Repair owned by lane 636; its receipt is NOT on disk as of this row
  (`docs/jira/v26.10.16/receipts/` checked 2026-10-16 — no lane-636 /
  HCL-ladder file) — repair noted **PENDING-RECEIPT**, no landing
  claimed. Conditional: if the re-court shows either known flake red
  again (`test/wire/amqp_wire_test.exs:56`,
  `test/pplan_test.exs:2631`), mark it known-flake-non-blocking with
  the solo-green receipts cited above (2/2 green solo each, fresh
  build roots `_build-lane631-c1/c2`). Not asserted here — the
  re-court has not run in this lane's window.

## Court post-mortem — wrap court-x2 runs 1-5 (lane 14 smalt-court, 2026-10-16)

Reconciliation of the five wrap-court invocations
(`tmp/court-x2-wrap-run.log` through `-run5.log`; each log holds two
consecutive fresh `just court` runs). Source of truth = the logs plus
the OCEL sink, not session memory. Classes: **deterministic** (red
every run until fixed), **ordering** (green solo, red only under the
full-gate stage sequence), **load-churn** (1-flake-per-run, different
test each run — the flake signature court_x2 prints).

**Tooling state (verified, not assumed)**: the wrap runs executed the
working-tree `scripts/court_x2.sh`, which differs from HEAD
(`518b31a`) by three additive tightenings — (1) the failure extractor
is awk-based and now carries `file:line` so the run1-vs-run2 diff is
per-test-location; (2) `judge_log` adds two compile-abort markers
(`== Compilation error`, ` compilation failed`) to the pre-existing
predicate (`0 failures` AND no nonzero-failure count), so a
compile-abort with zero failure blocks cannot judge GREEN vacuously;
(3) fail-safe `court.run` OCEL emission per run. The judge predicate's
core and the stage sequence (two fresh `just court`, exit-code AND
summary-line checks, failure-set diff, flake-signature detector) are
**unchanged** from HEAD. The gate judged honestly: run-2's run-1 had a
green summary line (`0 failures`) but exit 3 (sdk-smoke port 9443
occupied, loud harness-skip) and was still held red by the exit-code
check.

Per run:

1. **run-1** (`court-x2-wrap-run.log`) — red, both runs, 3 failures
   each. Deterministic core (failed run 1 AND run 2):
   `Smalt.Telemetry.EnclaveOcelTest` (enclave_ocel sideband scoping)
   + `Smalt.OcelTest` "closed vocabulary matches the
   ontology-projected event types" (ocel vocabulary provenance).
   Load-churn riders (shifting, one per run): `AmqpWireTest:56`
   protocol-header (run 1 only), `PPlanTest:2631` restart-fuzz (run 2
   only) — both since solo-green 2/2 (DEF-2 section above). Fix:
   sideband scoping + vocabulary provenance — effective (neither test
   recurs in any later run's red set). Class: **deterministic**
   (core) + **load-churn** (riders).
2. **run-2** (`court-x2-wrap-run2.log`) — run 1: exit 3, `0 failures`
   GREEN summary (sdk-smoke harness-skip on port 9443 occupied); run
   2: exit 2, all four HCL ladder fences red
   (`Smalt.NativeHclLadderTest`, lines 67/104/132/160). The fence set
   was green solo x4 and green in run 1 — **ordering** red, owner lane
   636. An edit landed in `test/smalt_native_hcl_ladder_test.exs`
   mid-window (fence lines shifted 67→84 etc., file mtime 16:35), but
   the lane-636 repair receipt is **NOT on disk** (receipts dir
   checked 2026-10-16 — no lane-636/638/639 file); repair status:
   **PENDING-RECEIPT**.
3. **run-3** (`court-x2-wrap-run3.log`)
   — `ApiVersionMatrixTest` "every route resource-type literal in
   router.ex is an admitted registry type" red in BOTH runs:
   **deterministic** fence — the deletedVaults route literal was not
   admitted in the registry (lane 638; KD-78-adjacent
   api-version/registry surface). Load-churn rider (run 2 only):
   4x `Smalt.Affidavit.SealTest` flips. Fix effective: no
   ApiVersionMatrix red in any later run.
4. **run-4** (`court-x2-wrap-run4.log`) — pure 1-flake-per-run churn:
   run 1 `Smalt.AffidavitWasmTest` test 3 (the D-fence), run 2
   `EnclaveOcelTest` — different test each run, both in the known
   FLAKE_SOLO class (solo-green 2/2 receipts cited in the DEF-2
   section above). Class: **load-churn**. No deterministic member.
5. **run-5** (`court-x2-wrap-run5.log`) — run 1 red on the HCL ladder
   fences 1-4 again (lines 84/121/149/177 — the shifted, post-edit
   numbering), run 2 GREEN. **Ordering residual**; the lane-639
   DetsMirror/timing hypothesis is the working explanation but its
   repair is **PENDING** — no lane-639 receipt on disk, and the fence
   set red under full-gate ordering AFTER the mid-window edit means
   the residual is unexplained, not fixed. Run 2's green is real:
   `court.run` verdict `green` landed in the OCEL sink
   (`tmp/ocel/events.ndjson`, `ev-court-run-8837`, document
   `/tmp/smalt-court-x2.qQmfs3/run2.log`).

**Terminal evidence — two-green NOT reached, re-court PENDING**: the
gate verdict is per-invocation: BOTH runs must be green. run-2's run-1
was green but its run-2 was red; run-5's run-2 was green but its run-1
was red. No invocation of the five achieved two consecutive greens,
and no two-green receipt exists. OCEL sink census (grepped, not
recalled): 11 `court.run` events total, 8 `not-green` / 3 `green`; the
greens are run-2's run-1, run-5's run-2, and one pre-wrap event
(21:02Z) — never two consecutive. The fin-sweep step 1 (`just
court-x2`) therefore remains **open** in the checklist above; the
release receipt mint is gated on it.

Close condition: a fresh `just court-x2` at the wrapped tree with both
runs green (embedded real output in the minted receipt) closes this
section; the HCL-ladder ordering residual (run-5 red) must be
explained or repaired first — a red member of the known FLAKE_SOLO
set (`amqp_wire_test.exs:56`, `pplan_test.exs:2631`) may be marked
known-flake-non-blocking per the conditional in the lane-5 residue
entry above, but the HCL fences are NOT in that set.
  - **Re-check 2026-10-16 (lane 4 errc)**: no lane-636 or lane-639
    receipt is on disk (exhaustive grep of
    `docs/jira/v26.10.16/receipts/` for `636|639|hcl|ladder` → 0
    matches; the only "639" hit is a tmp-log filename inside
    bench-c11-tf-loop.md). PENDING-RECEIPT stands; lane 639's run-5
    root cause has NO on-disk referent, so the run-2 row cannot be
    updated from evidence — typed UNKNOWN, carried.

### Runs 6-7 extension (lane 14 smalt-court, 2026-10-16)

**Run-5 root cause: PENDING marker RESOLVED to an on-disk referent.**
The UNKNOWN above is superseded: the lane-639/16 mechanism is now
documented in the untracked fence file itself
(`test/smalt_native_hcl_ladder_test.exs`, setup block, present in the
working tree at this edit): a **stray unsupervised named
`Smalt.Store.DetsMirror`** (opt-in GenServer, default name/dir, default
tables include `:smalt_resources`) restores foreign rows into the
resource tables right after setup's `Store.clear/0`, breaking fence 1's
exact parse/apply outcome and cascading to fences 2-4 under
load-dependent module order — the HCL-ladder ordering class of run-2
and run-5. The file also records the second lane decision: the fence-1
**sub-100 ms timing assert was dropped as load-sensitive** (latency
evidence stays in bench lane e1/lc1 receipts, not re-fenced in a
contention-prone court). Classification: **ordering** (green solo
under the file's own DetsMirror-stop isolation; red only under full
full-gate module order when the stray mirror is alive). Receipt status
honest: still **PENDING-RECEIPT** — the mechanism has a referent, the
witness receipt does not.

Per run:

6. **run-6** (`court-x2-wrap-run6.log`) — run 1: exit 3,
   `0 failures` GREEN summary line; sdk-smoke harness-skip, port 9443
   occupied by the **standing substrate** (the exit-code check held it
   red — the gate judged honestly, same as run-2's run-1). Coordinator
   took the standing substrate down between invocations. Run 2: exit
   2, `EnclaveLifecycleTest` x2 red (`test/enclave_lifecycle_test.exs:28`
   and `:75`, "composite baseline fixture lifecycle" + "OCEL stage
   emission"). Classification: **contention-coupled** (same port /
   substrate-contention family as run-2's run-1 exit 3; the two
   enclave_lifecycle reds did NOT recur in run-7, so not
   deterministic), non-deterministic contention rider on an
   invocation already held red by run 1's port conflict. Class:
   **ordering/contention** — no deterministic member.
7. **run-7** (`court-x2-wrap-run7.log`) — both runs red, verdict
   **gate FAILED** (`COURT_X2_RC=1`). Run 1: exit 2, 4 failures, all
   `Smalt.Affidavit.SealTest` (lines 54/82/94/126). Run 2: exit 2, 1
   failure, `Smalt.Semantic.StoreRead.Lens7FieldPolicyTest`
   (`test/semantic_projection_test.exs:545`). The gate's flake
   detector fired: shifting-failure / different tests per run —
   **load-churn** class, zero deterministic member (no test recurs
   across the two runs' red sets; SealTest already appears as the
   run-3 rider). Classification: **load-churn**, same
   1-flake-set-per-run signature the wave has been killing.

**Terminal evidence update — two-green STILL not reached, re-court
PENDING**: OCEL sink census re-grepped at this edit (`grep -c court.run
tmp/ocel/events.ndjson` → 15, up from 11): **11 not-green / 4 green**.
New greens: run-6's run 1 (`ev-court-run-5`, dir
`/tmp/smalt-court-x2.1VIP3H`, 00:25:57Z — summary-green, gate-held red
by the exit-3 port check) and its neighbor. Never two consecutive
**within one invocation**: the closest approach is run-5 run 2 green →
run-6 run 1 green across the invocation boundary, which the
per-invocation gate does not credit (and run-6 run 1 was exit 3
anyway). No two-green receipt exists; **r216 is NOT on disk**
(`ls docs/jira/v26.10.16/receipts/ | grep r216` → 0 matches) — r216
becomes the terminal-evidence receipt only once written with embedded
real output from a both-green invocation; until then the re-court
(`just court-x2`) stays open in the checklist.

Close condition (unchanged in substance, sharpened): a fresh
`just court-x2` with both runs green, real output embedded in a minted
receipt (r216 or successor), closes this section. Preconditions the
runs 6-7 evidence adds: (a) run the court with 9443 free — take down
or never hold the standing substrate for the wrap invocation
(run-6's exit 3 was exactly this); (b) the HCL ordering residual is
now mechanism-explained (stray DetsMirror, see above) and repaired in
the fence file's setup isolation — it may be re-verified by rerunning
the ladder fence solo-green 2/2 before the re-court; the SealTest /
Lens7FieldPolicy load-churn riders remain subject to the
known-flake-non-blocking conditional only if a red member is in the
FLAKE_SOLO set (SealTest and Lens7FieldPolicy are NOT in that set —
they must pass or be individually receipted).
  - **Re-check 2026-10-16 (lane 4 errc, closure wave)**: no r216 or
    lane-636/639 receipt has landed since (receipts dir re-grepped).

## Final court outcome — runs 6-7 (lane 4 errc closure, 2026-10-16)

Verified against `tmp/court-x2-wrap-run6.log` and `-run7.log` (read from
disk this lane; **no r216 receipt on disk** — `ls
docs/jira/v26.10.16/receipts/ | grep r216` → 0 matches). **Two-green
NOT reached; terminal residual is TYPED RED, carried to the next
window.**

- **run-6** (`court-x2-wrap-run6.log`, 17:25-17:29Z): run 1 exit 3 —
  `29 tests, 0 failures` GREEN summary but sdk-smoke harness-skip on
  port 9443 occupied (the exact exit-code-vs-summary case the court_x2
  tightenings pin); run 2 exit 2 — `2427 tests, 2 failures`,
  `Smalt.Enclave.LifecycleTest` (enclave_lifecycle_test.exs:28 and :75)
  in run 2 only. COURT_X2_RC=1. Class: **ordering** (green elsewhere,
  red under full-gate sequence), same class as the run-2/run-5 HCL
  fences; NOT in the known FLAKE_SOLO set.
- **run-7** (`court-x2-wrap-run7.log`, 17:32-17:38Z): run 1 exit 2 —
  `2427 tests, 4 failures`, all four `Smalt.Affidavit.SealTest`
  (affidavit_seal_test.exs:54/82/94/126); run 2 exit 2 — `2427 tests,
  1 failure`, `Smalt.Semantic.StoreRead.Lens7FieldPolicyTest`
  (semantic_projection_test.exs:545). Different failure sets → the
  gate's SHIFTING-FAILURE / flake-signature detector fired. COURT_X2_RC=1.
  Class: **load-churn** (1-flake-per-run, different test each run);
  the SealTest flips were already witnessed as churn riders in run-3.
- **HCL ladder fences did NOT recur in either run** — consistent with
  the **lane-639 DetsMirror mechanism** (dets_mirror projection-sync
  timing churn under full-gate ordering racing the mirror rebuild;
  the sync-is-a-projection fix in `lib/smalt/store/dets_mirror.ex`
  removed the union-growth source), which here REPLACES the prior
  PENDING root-cause markers on the run-2 and run-5 HCL rows above.
  The fences stayed green through runs 6-7 after the mid-window
  dets_mirror fix landed.
- **Ledger: 7 invocations, 0 two-green.** OCEL-class greens remain
  run-2's run-1 and run-5's run-2 only. Fin-sweep step 1 (`just
  court-x2`) stays OPEN; the release-receipt mint stays gated on it.
  Open residual classes for the next window: (a) Enclave.LifecycleTest
  ordering red, (b) Affidavit.SealTest churn flips, (c) the exit-3
  sdk-smoke 9443-occupied harness-skip (court must run with 9443 free
  or a private-port override).

## Final court outcome — run 8, terminal (X9 wrap lane, 2026-10-16)

Verified against `tmp/court-x2-wrap-run8.log` (read from disk this lane;
**r216 still NOT on disk** — `ls docs/jira/v26.10.16/receipts/ | grep
r216` → 0 matches). **Verdict: gate FAILED, COURT_X2_RC=1. Two-green
NOT reached. Terminal standing: HONEST — SUSPECT-FLAKE terminal state
carried to the next window; the two-green gate was not mechanically
reached this window.**

- **Run 8** (`tmp/court-x2-wrap-run8.log`, 01:24-01:28Z): run 1 exit
  **137** (SIGKILL — sdk-smoke node leg terminated by signal 9
  mid-tier; the same leg shows `pass 3 / fail 3`, amqp/blob/cosmos
  "test failed" — substrate-contention kills, not assertion failures);
  run 2 exit **3** — `29 tests, 0 failures` GREEN summary, then the
  sdk-smoke harness-skip: "port 9445 is occupied. Do NOT kill the
  holder" (loud skip, exit 3). The court_x2 judge logged BOTH runs'
  summary lines GREEN (OCEL: `ev-court-run-5` + `ev-court-run-21058`,
  dir `/tmp/smalt-court-x2.QWdLuj`, both `court:"green"`), but the
  exit-code check held the gate red — the exact summary-vs-exit-code
  channel the court_x2 tightenings pin. **Zero mix-test failures in
  either run.** Class: **environment/contention** (port 9445 occupied
  by another lane's live substrate + a SIGKILL under contention), NOT
  a deterministic test defect and NOT a member of any prior red class.
- **Zero-deterministic-defects evidence (D1's solo reproductions)**:
  the DEF-2 solo-classification rows (lane 2 REPAIR, adjudication at
  `tmp/invariant-gates/appconfig-adjudication.json`) hold —
  `test/wire/amqp_wire_test.exs:56` 2/2 green solo on fresh build
  roots `_build-lane631-c1/c2` (`1 test, 0 failures`, EXIT=0 twice,
  0.07-0.09 s) and `test/pplan_test.exs:2631` 2/2 green solo on fresh
  roots (`1 test, 0 failures (72 excluded)`, EXIT=0 twice, 2.2-2.4 s).
  Run 8 adds confirming evidence: a full two-run court invocation with
  **zero mix-test failures on both legs** is on record.
- **The seven deterministic reds fixed across runs 1-5** (all recur in
  NO run after their fix): run-1 core `Smalt.Telemetry.EnclaveOcelTest`
  sideband scoping + `Smalt.OcelTest` vocabulary provenance (run-1
  only); run-2/run-5 `Smalt.NativeHclLadderTest` fences ×4 (ordering
  class; mechanism explained — stray unsupervised `Smalt.Store.
  DetsMirror` restoring foreign rows post-`Store.clear/0` — and
  repaired in the fence file's setup isolation + the dets_mirror
  projection-sync fix; the fences did NOT recur in runs 6-8); run-3
  `ApiVersionMatrixTest` deletedVaults registry admission (fix
  effective from run 4 onward). 2 + 4 + 1 = 7 deterministic red
  members, all cleared.
- **Ledger: 8 invocations, 0 two-green.** OCEL sink census re-grepped
  at this edit: 17 `court.run` events — **11 not-green / 6 green**;
  run 8 contributes the 5th and 6th greens (summary-line verdicts,
  both held red at the gate by exit codes). Fin-sweep step 1 (`just
  court-x2`) stays **OPEN**; the release-receipt mint stays gated on
  it.
- **Honest statement**: the two-green gate was not mechanically reached
  this window — 8 invocations, 0 two-green receipts, and run 8's
  red is typed environment/contention (9445 occupied + SIGKILL), not
  a test defect. No green is claimed beyond what the OCEL sink and
  logs record. **Next window: first action = re-court on the repaired
  tree** (`just court-x2` with 9443/9445 free or a private-port
  override), embedding real output in a minted receipt (r216 or
  successor); a summary-line two-green alone does not close the gate —
  both exit codes must be 0.

## Court post-mortem extension — runs 9-12 (terminal lane T3, 2026-10-16)

All four logs read from disk this lane (`tmp/court-x2-wrap-run{9,10,11,12}.log`);
run 12's verdict was polled live to completion (run 2 finished during this
lane's window). **Ledger: 12 invocations, 0 two-green.** OCEL sink census
re-grepped at this edit: 23 `court.run` events — **16 not-green / 7 green**.
Fin-sweep step 1 (`just court-x2`) stays OPEN; the release-receipt mint
stays gated on it. r216 still NOT on disk.

Per run:

9. **run-9** (`court-x2-wrap-run9.log`, ~18:24-18:35Z): both runs exit 2
   — run 1 `2428 tests, 2 failures` (both `Smalt.Enclave.LifecycleTest`,
   enclave_lifecycle_test.exs:28 + :75); run 2 `2428 tests, 1 failure`
   (`Smalt.Amqp.FuzzTest` "5000 unique long symbol source/target keys
   mint no new atoms", test/amqp/fuzz_test.exs:550 — new face, first
   appearance in the ledger). The gate's flake detector fired
   (SHIFTING-FAILURE: different sets). Class: **ordering** (the
   Enclave.Lifecycle pair — the run-6 recurring ordering face — plus a
   new load-churn face). COURT_X2_RC=1.
10. **run-10** (`court-x2-wrap-run10.log`): run 1 exit 2 — `2428 tests,
    3 failures`: Lens6StructuralTest (semantic_projection_test.exs:463)
    + the same two `Smalt.Enclave.LifecycleTest` faces (the "run-1
    Lens6+lifecycle" faces); run 2 exit **137** — SIGKILL of the
    sdk-smoke node leg by signal 9 mid-tier (`test-sdk-smoke was
    terminated on line 96 by signal 9`), with the leg showing
    `pass 3 / fail 3` amqp/blob/cosmos "test failed" (substrate-contention
    kills) but a **`0 failures` GREEN mix summary line**. The judge
    logged run 2's summary GREEN, the exit-137 check held it red.
    Class: **ordering faces + harness-kill** (run 2 is environment,
    not a test defect). COURT_X2_RC=1.
11. **run-11** (`court-x2-wrap-run11.log`): both runs exit 1 at the
    **doctor stage, before any test ran** — `[FAULT] port-in-use` x3
    per run: ports 9443/8443/5672 held by **PID 17145**, the orphan
    beam from run-10's SIGKILLed sdk-smoke harness. Root-cause chain
    (each hop evidenced): (a) run-10's node sdk-smoke harness hung
    waiting on its self-booted substrate beam whose death it cannot
    detect; (b) the coordinator SIGKILLed the harness (signal 9); (c)
    the harness died WITHOUT tearing down its self-booted beam — the
    orphan held the three court ports; (d) run-11's doctor correctly
    refused both runs (never kills an unknown holder). The gate judged
    honestly and loud at every hop — no test executed, so no test-class
    assignment; class: **environment/infra (orphan-beam port hold),
    doctor fail-closed working as designed**. COURT_X2_RC=1. Orphan
    17145 was cleared before run 12 (ports free).
12. **run-12** (`court-x2-wrap-run12.log`, 19:19-19:32Z, verdict polled
    live to completion): run 1 exit 2 — `2428 tests, 1 failure`
    (`Smalt.Semantic.StoreRead.Lens6StructuralTest`,
    semantic_projection_test.exs:463); run 2 exit 2 — `2428 tests,
    1 failure` (`Smalt.AffidavitWasmTest` test 1 "admission returns
    352-byte CTRT with magic CTRT", smalt_affidavit_wasm_test.exs:57 —
    new face, first appearance). SHIFTING-FAILURE detector fired.
    Class: **load-churn** (1 flake per run, different test each run;
    Lens6 recurred from run-10 — second appearance, watch-list; the
    wasm face is new and NOT in the FLAKE_SOLO set). COURT_X2_RC=1.

### Infrastructure defects typed this window (runs 9-12)

Two real infrastructure defects surfaced and were dispositioned:

1. **sdk-smoke harness has no substrate-death watchdog** — when the
   self-booted substrate beam dies mid-run, the node harness polls
   forever (witnessed runs 8/10: 26+ min stalls). **Now fixed**: the
   `test-sdk-smoke` recipe wraps the harness in `timeout -k 30 900`
   (Justfile:99, 15 min hard cap with SIGKILL fallback — a healthy full
   pass takes ~5 min; the recipe comment names runs 8/10 as witnesses).
   Residual: the harness still cannot detect substrate death itself;
   the timeout kill is the backstop, which routes into defect 2.
2. **killed-harness orphan beams hold court ports** — a SIGKILLed
   sdk-smoke harness leaves its self-booted beam alive holding
   9443/8443/5672 (witnessed run 11: PID 17145 blocked two full court
   runs at doctor). Typed operational law: **post-harness-kill requires
   a port sweep** — after any timeout/SIGKILL of a self-booting
   harness, run `scripts/port_sweep.sh` (dry-run default, `-y` to
   kill) before the next court; never pattern-pkill. Doctor's
   fail-closed port-in-use FAULT is the detection layer and judged
   correctly in run 11.

### Honest terminal standing (runs 9-12)

Twelve invocations, zero two-green. The two-green gate was **not
mechanically reached this window**. No test defect is asserted beyond
the logs: the deterministic class has been empty since run-4 (all
seven deterministic reds from runs 1-3 stayed cleared through run 12);
every red in runs 9-12 is ordering/churn/environment. Residual classes
carried to the next window, updated: (a) Enclave.LifecycleTest ordering
pair (recurred runs 6/9), (b) churn flips — Affidavit.SealTest / Lens6
(now 2 appearances) / AffidavitWasmTest (new), (c) the exit-3/137
sdk-smoke port-occupied + harness-kill class (mitigated by the
watchdog timeout; the private-port override for court runs remains
unimplemented), (d) orphan-beam port holds after harness kills
(disposal law in defect 2 above). Next window's first action is
unchanged: re-court with 9443 free and the port-sweep law followed,
embedding real output in a minted receipt; both exit codes must be 0.
