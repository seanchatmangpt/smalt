# NEXT_WINDOW — v26.10.18

> **Stale-by-default law (v26.10.18 form).** Every figure, count, SHA, and
> standing named below is stale by default: **figures are re-derived at
> v26.10.18 open**, from the canonical registers on disk
> (`docs/jira/v26.10.14/KNOWN_DIVERGENCES.md`, `docs/WIRE_PARITY.md`,
> `docs/jira/v26.10.16/WRAP_LEDGER.md`, `scripts/bench/REGISTRY.md`) — not
> recalled from session memory of this mint. Receipt-cited counts are
> re-read at use time. No item in this file is closed by being listed
> here; each closes only with its named close-condition receipt.

## 1. KD parks from the v26.10.16 wrap ledger

Carried from `docs/jira/v26.10.16/WRAP_LEDGER.md` (ground truth at that
wrap); statuses must be re-verified against the canonical register at
v26.10.18 open.

- **KD-77** (AMQP delivery-tag encoding, settle path — pyamqp decodes the
  0x98 UUID delivery-tag to a struct, settle throws
  `` `object of type 'UUID' has no len()` ``). Implementation landed
  (r210, PARTIAL_ALIVE: vbin 0xA0 encode + disposition echo + mgmt-reply
  + DLQ reason wiring, `# KD-COVERS: KD-77` in `frame_codec.ex` /
  `connection.ex`) but the register flip is **blocked on a PASS
  re-witness** — kd_flip.py requires a literal PASS verdict and r210
  carries PARTIAL_ALIVE with a residual typed loud skip in
  `test_w3_session_ops.py` (stale locked-survivor premise, not a wire
  divergence). Close condition: a fresh witness receipt carrying a
  literal PASS verdict postdating the KD-77 shims; flip via
  `scripts/kd_flip.py --apply` only (registrar-owned).
- **c11 typed findings** (bench-c11-tf-loop, ledgered in WRAP_LEDGER;
  each is a real azurerm/terraform run failure first). Fixes are
  v26.10.18 work orders. Each close condition: a wire-visible probe
  receipt over real `Router.call/2` dispatch showing the fixed surface,
  or a registrar-minted KD/GAP row registering the divergence — no
  silent park.
  1. **blobServices/default singleton 404** — azurerm 4.54 storage
     create GETs `.../blobServices/default`; the ARM plane 404s it
     (only file/queue/tableServices defaults are synthesized,
     `lib/smalt/arm_gateway/router.ex` ~:3060). Blocks azurerm storage
     account apply. Close: probe receipt showing the GET answering the
     synthesized default, or a registrar-minted KD row.
  2. **azurerm cosmosdb CheckNameExists pre-check unparseable
     400/EOF** from the ARM plane — blocks azurerm cosmosdb apply
     (cosmos exercised data-plane only to date). Close: probe receipt
     showing the CheckNameExists pre-check answered parseably over real
     dispatch.
  3. **ARM-vs-blob store split** — ARM child-container PUT returns 201
     into a store the blob data plane does not read
     (`:smalt_blob_containers` DETS vs the ARM store); a subsequent
     data-plane blob PUT 404s ContainerNotFound. Close: a wire-visible
     probe receipt showing ARM-created containers visible to the blob
     data plane (or the split registered as a typed divergence).
  4. **Cosmos query-feed no-filter + stale pre-seeded projection**
     (KD-93, OPEN) — collection create is POST-only
     (`egress_router.ex` ~:318); the query feed ignores parameterized
     filters and is not scoped to the addressed db/coll (stale docs
     from prior runs returned: `doc_132`/`doc_259`/`doc_325`/`doc_388`
     across runs). Honesty note carried: the green "ryw cosmos doc
     put/query" bench row gates on direct doc GET, NOT query-feed
     read-your-write — query-feed ryw remains unproven. Close: KD-93
     flip receipt-gated (query feed filtered + scoped over real
     dispatch), registrar-owned.
  5. **kv PurgeDeleted route unimplemented** — RouteNotFound on
     `/providers/Microsoft.KeyVault/locations/:loc/deletedVaults/:vault/purge`;
     tf destroy aborts mid-graph leaving the RG. Close: probe receipt
     showing the purge route answering over real dispatch (or a
     registrar-minted divergence row).
- **KD-78 residual (register row, informational)** — code + fence
  landed and green (r213, 200 tests, 0 failures); canonical register
  row flip remains registrar-owned, gated on a PASS witness newer than
  the shim.

## 2. GAP tokens remaining in docs/WIRE_PARITY.md

Four gated tokens plus the Event Grid residue, re-verified at v26.10.17
wrap. Each disappears only with a closing receipt — no receipt, no flip;
tokens are never minted or retired unilaterally.

1. **GAP(blob-x-ms-date-unvalidated)** — blob `x-ms-date` not
   required/validated. Close condition: presence check + RFC 1123 parse
   + skew window shared with the other `:8443` planes, wire-visible
   probe receipt, then the token is struck from WIRE_PARITY.
2. **GAP(blob-comp-lease-absent)** — full `comp=lease` surface
   (acquire/renew/change/release/break, `:smalt_blob_leases`,
   enforcement seam alongside `check_worm`) is feature-scale; until it
   lands, `<LeaseStatus>unlocked</LeaseStatus>` in listings is the
   divergence marker. Closely coupled to the blob delete-precedence
   divergence (WORM-before-If-Match answers 409 where real Azure
   answers 412) — revisit the precedence reorder with the lease work.
   Close: lease surface probe receipt + precedence decision receipt.
3. **GAP(kql-datetime-dynamic-types-absent)** — KQL datetime/dynamic
   column-type inference absent (values report `"string"`). Close:
   typed column inference over real queries + probe receipt.
4. **GAP(atlas-search-relationship-get-absent)** — Purview
   `POST /atlas/v2/search/collection` and relationship read/GET beyond
   the edge-minting POST not implemented. Close: feature-scale
   implementation or a registrar-minted divergence row.
5. **GAP(eventgrid-eg1-schema-absent) — residue** (narrowed
   2026-10-16, EventGrid-topics lane): declared-topic EG1 ingest is
   CLOSED-WITNESSED (`cap-eventgrid-topics.md`, PARTIAL_ALIVE); the
   token stays OPEN for undeclared topics and
   system-topics-as-source events. Close: system-topic-sourced ingest
   + undeclared-topic decision receipt (admit or typed-refuse),
   witness receipt, then strike.

## 3. court-x2 two-green gate (carried typed-RED)

Twelve-plus wrap invocations at v26.10.16 closed with **zero
two-green**; the residual classes are carried, not faked:

- (a) `Smalt.Enclave.LifecycleTest` ordering pair
  (`enclave_lifecycle_test.exs:28`/`:75`; recurred runs 6/9).
- (b) solo-green churn flips (Affidavit.SealTest, Lens6
  [2 appearances], AffidavitWasmTest, SemanticProjection class).
- (c) environment: sdk-smoke exit-3 port-occupied harness-skip (9443 /
  9445) + SIGKILL harness-kill orphans — the private-port override for
  court runs remains unimplemented; post-harness-kill port sweep law
  (`scripts/port_sweep.sh`) applies.
- (d) orphan-beam port holds after harness kills; doctor fail-closed
  port-in-use FAULT is the detection layer.

If WO-2 closes typed-RED again this window, the gate carries to
v26.10.18 with an honest witness — never a faked pass.

**WO-2 VERDICT (filled at wrap): TYPED-RED (honest).** Attempt 3 of 3
(`receipts/r241-court-x2-attempt3-typed-red.md`) closed the chain:
quiet-check clear twice, `just quiesce` warm-up RC=2 (1 failure / 2655
tests), then `bash scripts/court_x2.sh` RC=1 — run 1 = 4 failures, run 2
= 1 failure (tmp/court-x2-v17-wrap3.log, COURT_X2_RC=1 at line 86).
Corrections r240→r241: fence 10 (WasmEngineFailClosed "restart hammer",
test/affidavit_wasm_failclosed_test.exs:502) REPEATED in both court legs
of attempt 3 — upgraded from CONTENTION to **PERSISTENT-FLAKE** (solo
PASS on same tree, repeats under court load; needs a real fix, not a
warm-up). Remaining faces contention-class: EgressDispatchTest setup
ETS `:smalt_subscriptions` teardown race (victims :1474/:975), Lro :543
op-record store miss. The gate carries to v26.10.18 with this honest
witness — no two-green exists; version stays 26.10.16.

## 4. NOTICE upstream-attribution — B1 CLOSED 2026-10-17 (r244); NOTICE
attribution remainder still open

publish-dry is TYPED-BLOCKED per the v26.10.16 PUBLISH_RECORD (item B1
of the publish B1/B2 chain). Operator ruling stands: ex4pm is a
permanent runtime dep; publish ex4pm to hex first, then dual-pin
(hex version + path override locally). `NOTICE.md` still carries no
upstream license/attribution block (verified 2026-10-17). Close
conditions (all receipt-gated):

- ~~ex4pm on hex satisfying smalt's pin; smalt `mix.exs` flipped to the
  dual-pin~~ — **DONE (2026-10-17)**, witness `receipts/r244-publish-record.md`.
- `mix hex.publish --dry-run` exit 0, or each warning dispositioned in
  a receipt — including the NOTICE attribution remainder (upstream
  license/attribution block added to `NOTICE.md`).
- Sub-item (b): AshR2RML guard/stub-or-exclude dispositioned.
- Sub-item (c): `stream_data` `only: :test` retarget dispositioned.

## 5. bench REGISTRY register-or-retire flags

From `scripts/bench/REGISTRY.md` (ground truth at that edit;
re-derive at v26.10.18 open):

- **b42 dataplane-saturation — UNAUDITED**: no port block registered
  in the REGISTRY; register a block or retire the lane before its next
  run. Close: b42's block added to `scripts/bench/REGISTRY.md` (or a
  retire marking naming the result files as historical, same rule as
  b10/b11).
- **a-family / n-family (a1-a9, n1-n8)** — register-or-retire: no port
  blocks registered beyond a9 39490 (a) and n5 39555 (n). Any
  re-activated a/n lane must register its block here or be retired;
  result files without an active registered lane are historical
  artifacts (same rule as b10/b11). Close: per-lane registration or an
  explicit retire marking per family.
- Standing law: any row embedding the global substrate ports
  (9443/8443/5672/5673) is VOID.

## 6. Other named carry-forwards

- **ERROR_CODES extractor blind-spot** — PolicyViolation
  (`lib/smalt/policy.ex` deny path) and InvalidEventGridEvent
  (`lib/smalt/egress_router.ex`) omitted from the generated
  `docs/ERROR_CODES.md`. Fix owned by I13 this window; close condition
  is a `just gen-error-codes --check`-green replay at v26.10.18 open,
  never a hand patch.
- **A24 findings 3-9 enumeration debt** — NOT-RECOVERABLE-FROM-TREE;
  the minting audit's finding list was never persisted. Close: the
  finding list persisted with per-finding file:line claims, then
  per-finding classification becomes executable.
- **Receipt context law adoption** — every witness receipt must state its
  run context (`Context: solo|pair(A,B)|slice(...)|full`); per-file greens do
  NOT certify suite-context behavior (evidence:
  `receipts/i3-witness-sweep.md` §4 batched-run finding — 8 solo-green files,
  71 failures in one batched invocation — and `receipts/r236-court-run1-red-75.md`).
  Adopt `docs/jira/v26.10.17/RECEIPT_CONTEXT_LAW.md` in the next window's
  receipt template + spot-audit.

### Court ledger + residual classes (2026-10-17 wrap, r240 chain)

- court-x2 ledger: 34 completed invocations, 0 two-green (attempts 1-2 this
  window typed-RED, receipts r240-court-x2-attempts12-typed-red.md). Both run-1
  faces were CONTENTION class, solo-green 3/3; run 2 of each attempt green.
- Known load faces for the next court: WasmEngineFailClosedTest fence 10
  (restart hammer), EgressDispatchTest batch-list boundary (:1221), blob
  pagination 110ms perf budget (witnessed 119ms under load), StoreDets churn
  300s budget under self-load, BrokerFacade sweeper whereis-nil (private-tree
  stop vs async modules). Close condition: quiesce + warm-up before the gate;
  per-face falsifiers in receipts/i20b-contention-mechanism.md.

## 7. Top WOs for v26.10.18 — court residual repair surfaces (from r241)

### WO-A: WasmEngineFailClosed fence 10 (restart hammer) — PERSISTENT-FLAKE fix

- **Surface**: `test/affidavit_wasm_failclosed_test.exs:502` ("restart
  hammer", fence 10). Solo PASS on the same tree (r241); repeated in
  BOTH court legs of attempt 3 (wrap3.log lines 68 + 72) — the only
  repeating face in the window. Witnessed timing face: 129ms vs a
  bound that fires at 1.08x budget under suite load (see BUDGET-1 in
  the verify ledger; the 110ms perf-budget class acts as a load
  sensor, not a regression detector).
- **Repair**: give fence 10's timing bound real slack (budget raised
  to the documented ~3.3x revert-threshold discrimination band) or
  serialize/de-parallelize the restart hammer in the harness — either
  is a real fix; a warm-up is not (r241 showed warm-start does not
  de-conflict it).
- **Close condition**: a court-context witness (not solo) showing
  fence 10 PASS across two consecutive `just court` legs, plus the
  court-x2 gate; flip recorded in the receipt chain (r241 successor),
  registrar-owned.

### WO-B: EgressDispatchTest seed_default_subscription async isolation

- **Surface**: `Smalt.Store.seed_default_subscription/0`
  (`lib/smalt/store.ex:194`) seeding ETS `:smalt_subscriptions` in
  EgressDispatchTest setup races another async module's Store
  teardown — "table identifier does not refer to an existing ETS
  table" (r241 pre-court full log; victims `:1474` and `:975`, same
  mechanism both). Typed as async-module isolation, NOT a product
  defect (r241 disposition).
- **Repair**: async-isolation boundary for the seeded table (async
  context tag / per-test ownership of `:smalt_subscriptions`, or move
  the seeding test out of async), not a retry.
- **Close condition**: wire-visible witness: the two victim tests PASS
  inside a full batched suite run with the teardown race absent
  (Context: full per the receipt context law), repeated across two
  court legs; contention-class faces Lro :543 and the remaining
  shifters re-evaluated on the same receipt.

## 8. Verify-ledger confirmed findings — carry-forwards (2026-10-17 wrap)

Source of truth: `docs/jira/v26.10.17/verify-ledger/` (w0 x 24 + w1 x
14 batch files, re-derived on disk). Ledger actuals at wrap: 78
finding verdict entries; 55 unique CONFIRMED findings; 6 PREMISE-ROT
(F1, F2, SDK-7, TIL-06, TIL-07, IG-7) and 1 CONTENTION (C12) complete
the set. (The wrap dispatch figure of "36 confirmed" does not
re-derive against the ledger on disk — ledger counts above are the
ground truth; re-derive at v26.10.18 open.)

Families folded into carry-forwards (each finding carries its own
file:line evidence in the ledger; none closed by listing here):

- **SDK-surface (SDK-1..SDK-9)** — SDK parity/divergence claims;
  per-row evidence in w0-b19..b23 / w1-b11..b14. Close per-finding:
  probe receipt or registrar-minted KD row.
- **UC-01..UC-12 (receipt-orphaned surfaces)** — confirmed surfaces
  with no this-window receipt: e2e scenario courts (s1_iac..s10_attest,
  incl. s7_worm / s8_cosmos_race — court composition has no e2e
  stage), plus fin_ops/hw, pplan, dspy receipt-orphaned surfaces.
  Close: a real witness receipt per surface or explicit
  retire/register disposition.
- **IG-2..IG-6 (invariant-gates integrity)** — isolation receipt
  FAIL-TREE-LEAKS under a green aggregate (IG-2), and kin. Close:
  fail-closed gate receipt where the aggregate cannot go green while
  the isolation receipt is RED.
- **BUDGET-1..BUDGET-3 (perf-budget sensor class)** — blob pagination
  110ms budget fires at 1.08x under suite load (witnessed 119ms;
  ~3.3x is the documented revert threshold). Close: budget re-based
  to the discrimination band or a load-invariant measurement harness.
- **TIL-01..TIL-09 (test-env isolation)** — bare
  `Application.put_env` port keys in wire-tier setups with no
  save/restore (test/wire/amqp_wire_test.exs:28-33 et al.). Close:
  save/restore on every mutated env key, batched-run witness.
- **Court-doc residue (F3, F05-F09, C1-C11, KD-04/KD-13/KD-AMQP/
  KD-LEDGER rows)** — claim/ledger drift items, each with file:line
  in the ledger; close per-finding with a corrected doc or receipt.
