# Receipt — V261014-13 GAP Register Closure & Tokenization Sweep

- **Lane:** 13 (docs-corpus, register flip gate) · Checkout: /Users/sac/smalt (canonical, main) · 2026-10-15
- **Status:** COMPLETE (see "Test suite" below for the one standing caveat)
- **Owned files touched:** `docs/compliance/C4_BLOB.md`, `docs/compliance/C7_EVENT_PLANES.md`, `docs/compliance/C1_ARM_REST.md` (one bullet), `docs/WIRE_PARITY.md`, `docs/TEST_ISOLATION.md`, `docs/RELEASE_NOTES_v26.10.14.md`, `test/test_helper.exs` (the lane's single code-adjacent edit).

## WI-1 — vacuous tags deleted

- `test/test_helper.exs` — `:arm_seam` and `:dp_seam` removed from `ExUnit.configure(exclude: [...])`; only `:amqp_wire` remains. Lane 01's `ensure_store_up` lifecycle helper untouched.
- `docs/TEST_ISOLATION.md` §3 — both rows converted to the `:closed_shape_gap` strikethrough RETIRED form; both `GAP(vacuous-tag-*)` tokens deleted; owner lanes "—", re-enable condition "re-introduce only with a real named-gap test".
- Proof: `grep -r "arm_seam\|dp_seam" test/ lib/` → **zero hits** (exit 1, re-run post-edit).

## WI-2 — register flips (receipt-gated, all four receipts verified on disk before flipping)

Receipts verified: `receipts/05-lro-lazy-terminality.md`, `receipts/05-lro-retention-unbounded.md`, `receipts/06-blob-x-ms-error-code-header-absent.md`, `receipts/06-blob-x-ms-date-unvalidated.md`.

- Lane 05 had already landed C1 register rows :84/:85 CLOSED + dup :86 deleted — **verified, not redone**.
- Lane 06 had landed WIRE_PARITY:124 prose but left both closed tokens in `GAP(...)` form; I completed the flip: both tokens → `~~token~~ (CLOSED, receipt named)` strikethrough form with receipt paths.
- **Disposition correction (recorded, not silent):** the WO census listed `GAP(blob-x-ms-date-unvalidated)` as "CLOSE (bounded)", but lane 06's receipt types it **UNSUPPORTED for v26.10.14** with a bounded fix deferred (presence + RFC 1123 parse + skew window). The register now says UNSUPPORTED-with-close-condition, matching the receipt. It is NOT counted among the four CLOSED.
- C1:109 "Eviction interaction" bullet de-future-tensed (`:lro_retention` landing now past-tense CLOSED reference).
- WIRE_PARITY:124 verdict cell re-checked: "2 UNSUPPORTED gaps above + delete-precedence divergence" — correct surviving count.

## WI-3 — tokenization sweep

- **C3_COSMOS.md** — `GAP(cosmos-sql-translator-absent)` already tokenized at :63 + WIRE_PARITY:133/:234 — verified, no edit.
- **C4_BLOB.md**:
  - Verdict rows re-graded: Container PUT → CONFORMANT (re-graded 2026-10-15, V261014-13); Blob GET conditional (304) → CONFORMANT (re-graded); x-ms-date → UNSUPPORTED with token; comp=lease → UNSUPPORTED with token; comp=immutabilityPolicy GET → PARTIAL named divergence.
  - Detail sections: Container PUT (:75) and Blob GET conditional (:163) converted to CONFORMANT re-grades with `_Historic (fixed)_` superseded records; x-ms-date (:68) and comp=lease (:109) headings kept prose, bare-GAP prose replaced by `GAP(...)` token + close condition.
  - **immutabilityPolicy-GET (fifth blob divergence)**: not minted as a new token — recorded as a named divergence attached to the error-envelope family per the WO's "do not mint unilaterally" instruction; bounded fix noted (render the same XML envelope `blob_error_xml/4` already produces, scoped to the immutabilityPolicy GET arm).
- **C7_EVENT_PLANES.md** — GAP list rewritten: convention note (typed UNSUPPORTED, not open defects), five tokens minted with close conditions (`GAP(eventgrid-eg1-schema-absent)`, `GAP(eventhubs-partition-metadata-absent)`, `GAP(eventhubs-consumer-group-enumeration-absent)`, `GAP(atlas-search-relationship-get-absent)`, `GAP(kql-datetime-dynamic-types-absent)`), Service Bus paragraph kept untokenized (owned by V261014-08 / C5 R11), cross-links to C7-2c and §Named divergences 2/3 added.
- **WIRE_PARITY.md** — the five C7 tokens added to the register rows (Event Grid ingest, Sentinel/Log Analytics, Purview, Event Hubs module-semantics) as "Typed-UNSUPPORTED (C7, V261014-13)"; :229/:234 cosmos cross-ref intact.

## WI-4 — release-notes honesty paragraph

`docs/RELEASE_NOTES_v26.10.14.md` — new "Wire-parity honesty statement" subsection adjacent to the wave paragraph: **"parity for the documented surface; named gaps for the rest."** + one-sentence register census (4 CLOSED-with-receipt + 2 vacuous deletions; 9 typed-UNSUPPORTED tokens + V261014-08 Service Bus UNSUPPORTED). No token deleted without a receipt; no open gap claimed closed.

## Final register census

- CLOSED-with-receipt: `lro-no-failed-path` (pre-release), `lro-lazy-terminality`, `lro-retention-unbounded`, `blob-x-ms-error-code-header-absent`, `blob-error-envelope-json` (5) + 2 vacuous-tag deletions.
- Typed-UNSUPPORTED with close condition (open, tokenized, 9): `cosmos-sql-translator-absent`, `ledger-lazy-create-default`, `blob-x-ms-date-unvalidated`, `blob-comp-lease-absent`, `eventgrid-eg1-schema-absent`, `eventhubs-partition-metadata-absent`, `eventhubs-consumer-group-enumeration-absent`, `atlas-search-relationship-get-absent`, `kql-datetime-dynamic-types-absent` — plus 1 untokenized named divergence (immutabilityPolicy-GET XML shape, minting deferred) and the Service Bus reply-to/rules UNSUPPORTED (typed in WIRE_PARITY:145/C5 R11).

## Acceptance gates

1. `grep -n "GAP" docs/compliance/C3_COSMOS.md docs/compliance/C4_BLOB.md docs/compliance/C7_EVENT_PLANES.md` → every hit is token form, CLOSED record, convention note, or permitted historical record (audited post-edit; C3:28/:30, C1:24/:57 historical records preserved).
2. Register audit: WIRE_PARITY §4 + C1 + TEST_ISOLATION §3 — every GAP CLOSED-with-receipt or typed-UNSUPPORTED-with-close-condition. PASS.
3. Release-notes gap paragraph present. PASS.
4. Both vacuous tags deleted, `grep -r "arm_seam\|dp_seam" test/ lib/` zero hits. PASS. `mix test` — **see caveat**.

## Test suite

Two full `mix test` runs over the shared working tree:

- Run 1 (post test_helper edit, tail-truncated output): 1 doctest, 1885 tests, **17 failures** (27 excluded), 189.9 s.
- Run 2 (identical tree, full log `/tmp/lane13_test_full.log`, `mix test` exit=2): **17 failures + 2 invalid, 1885 tests**, 189.0 s — same count both runs.
- Failure census (run 2): registry replay identity (2), azapi lock If-Match (1), AMQP wire protocol-header (1), Lens6 structural setup_all invalidation (1), KvTls (4), ERROR_CODES doc-projection byte-identity (1), StoreChurn concurrent-delete (1), ARM child routes (1), ApiVersionMatrix cite-drift (1), EgressDispatch fail-closed cluster (5).
- **Classification: pre-existing / concurrent-lane, not introduced by this lane.** This lane's only code-adjacent edit deletes two exclusion entries whose tags are carried by ZERO tests (grep-verified, zero hits in `test/ lib/` pre- and post-edit) — by construction the executed test set is identical with or without the edit. The failure profile is the signature of other lanes' in-flight `lib/`/doc edits on the shared tree: the cite-drift fence (`ApiVersionMatrixTest`) fails on moved `router.ex` line numbers, the ERROR_CODES doc-projection test fails byte-identity on lanes' doc edits, and the EgressDispatch 503 `store_not_ready` cluster is a shared-tree/table-lifecycle interaction. Classification is by construction + profile, not by a clean-tree baseline (unavailable — one canonical checkout, no baselining per fan-out law).
- Coordinator note: the 17 failures reproduce identically across runs; they are owned by the code lanes (05-08 et al.), unchanged by V261014-13.

## Out of scope, respected

No lib/ code changes; C5/C6/C2 untouched; no OPEN token deleted without receipt; no git state changes, no commits.
