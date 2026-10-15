# V261014-13 — GAP Register Closure & Tokenization Sweep

- **Release:** v26.10.14
- **Lane:** docs-corpus (register flip lane)
- **Owns:** `docs/compliance/C1..C7`, `docs/WIRE_PARITY.md`, `docs/TEST_ISOLATION.md` GAP-register rows, `test/test_helper.exs` vacuous-tag entries
- **Coordinates (does NOT own):** lanes 05-08 own their code. This lane owns the **register flip gate**: a row flips PENDING→CLOSED **only on receipt-file existence** from the owning lane (`docs/jira/v26.10.14/receipts/<lane>-<gap-name>.md`). No code changes in scope.
- **Principle (WIRE_PARITY.md:6-8):** a `GAP(name)` token names an OPEN gap and disappears when it closes. Every GAP is either **CLOSED-with-receipt** (token deleted) or **typed-UNSUPPORTED-with-close-condition** (token kept, type + close condition inline).

## 1. Gap census (11 named GAPs, final disposition)

| # | GAP token | Anchor | Disposition | Gate |
|---|---|---|---|---|
| 1 | `GAP(vacuous-tag-arm-seam)` | TEST_ISOLATION.md:43, test_helper.exs:19 | **CLOSE — delete** | `mix test` green |
| 2 | `GAP(vacuous-tag-dp-seam)` | TEST_ISOLATION.md:44, test_helper.exs:20 | **CLOSE — delete** | `mix test` green |
| 3 | `GAP(blob-x-ms-error-code-header-absent)` | WIRE_PARITY.md:124 | CLOSE (bounded) — lane 06 | receipt file |
| 4 | `GAP(blob-x-ms-date-unvalidated)` | WIRE_PARITY.md:124; C4_BLOB.md:23,:68 | CLOSE (bounded) — lane 06 | receipt file |
| 5 | `GAP(lro-lazy-terminality)` | C1_ARM_REST.md:84 + stale dup :86 | CLOSE (bounded) — lane 05; also delete dup :86 | receipt file |
| 6 | `GAP(lro-retention-unbounded)` | C1_ARM_REST.md:85 | CLOSE (bounded) — lane 05 | receipt file |
| 7 | `GAP(cosmos-sql-translator-absent)` | WIRE_PARITY.md:133,:229; C3 | UNSUPPORTED-doc — tokenize + close condition | token present |
| 8 | `GAP(ledger-lazy-create-default)` | WIRE_PARITY.md:121 | UNSUPPORTED-doc — already tokenized + documented (config-flippable `ledger_enforce_existence`); verify only | none |
| 9 | `GAP(blob-comp-lease-absent)` | WIRE_PARITY.md:124; C4:27,:107 | UNSUPPORTED-doc — lane 06 | token present |
| 10 | `GAP(blob-error-envelope-json)` | WIRE_PARITY.md:124; C4 error-envelope rows | UNSUPPORTED-doc — lane 06 | token present |
| 11 | C7 untokenized five | C7_EVENT_PLANES.md:44-53 | UNSUPPORTED-doc — tokenize the five items | tokens present |

## 2. Work items

### WI-1 — delete the two vacuous tags (first; only code-adjacent edit this lane owns)

1. `test/test_helper.exs:16-22` — remove `:arm_seam` and `:dp_seam` from `ExUnit.configure(exclude: [...])`, leaving `:amqp_wire`. Both tags proven unused: zero `@tag`/`@moduletag` hits across `test/` (grep-verified 2026-10-15); TEST_ISOLATION.md:43-44 already records both rows VACUOUS with deletion as the close condition.
2. `docs/TEST_ISOLATION.md` §3 — convert both rows to the strikethrough RETIRED form used by `:closed_shape_gap` (:45): "RETIRED 2026-10-15 (V261014-13): vacuous exclusion entry deleted from test_helper.exs; no test carries this tag; re-introduce only with a real named-gap test." Delete both `GAP(vacuous-tag-*)` tokens.
3. Prove: `grep -r "arm_seam\|dp_seam" test/ lib/` → zero hits; `mix test` green (deleting a vacuous exclusion cannot change results — that IS the proof).

### WI-2 — register flip: four bounded gaps (PENDING→CLOSED only on receipt)

For GAP #3-#6 the owning lane delivers `receipts/<lane>-<gap-name>.md`. **No receipt, no flip.** On receipt:

- `C1_ARM_REST.md` §Typed gap register (:74-86):
  - `GAP(lro-lazy-terminality)` (:84): flip OPEN→CLOSED 2026-10-15 (lane-05 receipt), token to strikethrough form; update the WIRE_PARITY.md:94 inline reference. **Delete the stale duplicate row at :86** — the register carries exactly one row per token.
  - `GAP(lro-retention-unbounded)` (:85): flip on lane-05 receipt; update the :109 "Eviction interaction" bullet from future tense.
  - Blob pair: flip on lane-06 receipts. Update `WIRE_PARITY.md:124` — delete the closed tokens from the gaps sentence; re-grade the verdict cell to the surviving count.
- Downstream sync: the release-notes honesty paragraph gains the four closures per WI-4.

### WI-3 — tokenization sweep (receipt-independent; do while waiting on lanes 05/06)

1. **C3_COSMOS.md** — add one tokenized line: "`GAP(cosmos-sql-translator-absent)` — UNSUPPORTED: no full SQL translator; `SELECT ... FROM c` is not parsed; wire answers the partition-scoped query feed only. Close condition: query parser over the real service's SQL grammar subset, fenced at the wire." (WIRE_PARITY already tokenizes it — verify, no edit.)
2. **C4_BLOB.md — re-grade two rows CLOSED before tokenizing:**
   - **Line 24** `Container PUT — GAP (no ETag/Last-Modified)` and **line 32** `Blob GET conditional (304) — GAP` are **stale**: both behaviors landed and are pinned in WIRE_PARITY.md:124 (container PUT 201 with quoted ETag + RFC 1123 Last-Modified; RFC 7232 304 path at `egress_router.ex:258-262,:1062-1088`, engine `blob_storage.ex:479 get_blob_conditional/4`). Re-grade to `CONFORMANT (re-graded 2026-10-15, V261014-13; see WIRE_PARITY.md:124 pins)` and delete/supersede the detail sections at :73 and :153.
   - **Lines 23 (`x-ms-date`), 27 (`comp=lease`), error-envelope rows** — tokenize `GAP(blob-x-ms-date-unvalidated)`, `GAP(blob-comp-lease-absent)`, `GAP(blob-error-envelope-json)`. Implementer check: the WIRE_PARITY:124 sentence names exactly four blob tokens; the C4 token set must match exactly. The immutabilityPolicy-GET row (:35, :189 "JSON, real = XML") is a fifth blob divergence not covered by the four — handle via an implementer-time check: attach a note inside `GAP(blob-error-envelope-json)` or mint `GAP(blob-immutability-policy-get-xml)` with justification; do not mint unilaterally.
   - Line 68 / line 107 detail sections: keep prose, replace bare "GAP" headings with token form + close-condition line. After the sweep, no bare-GAP prose remains (grep-clean).
3. **C7_EVENT_PLANES.md:44-53** — tokenize the five as typed UNSUPPORTED with close conditions:
   - `GAP(eventgrid-eg1-schema-absent)` — EG1/GRIDEVENT native schema; smalt admits CloudEvents 1.0 only.
   - `GAP(eventhubs-partition-metadata-absent)` — `getEventHubProperties` / partition-count surface.
   - `GAP(eventhubs-consumer-group-enumeration-absent)` — `$default` group enumeration.
   - `GAP(atlas-search-relationship-get-absent)` — search/collection POST + relationship GET beyond edge-minting.
   - `GAP(kql-datetime-dynamic-types-absent)` — datetime/dynamic column-type inference.
   Append a convention note: these are typed UNSUPPORTED (deliberately not implemented this release), not open defects. Cross-link row C7-2c and §Named divergences items 2/3 to their tokens.
4. **WIRE_PARITY.md** — add the five C7 tokens (+ any new C4 token) to the §4 register so the machine-greppable register is the single census; keep the :229 cross-ref.

### WI-4 — release-notes honesty paragraph

`docs/RELEASE_NOTES_v26.10.14.md`: the parity statement reads exactly **"parity for the documented surface; named gaps for the rest."** followed by the register census in one sentence: at release, every `GAP(name)` is either CLOSED-with-receipt (four flips + two deletions) or typed-UNSUPPORTED with a close condition (the seven-plus tokens). Adjacent to the existing `GAP(lro-no-failed-path)` CLOSED note (:140).

## 3. Sequencing

1. WI-1 (deletion; independent) → `mix test` immediately.
2. WI-3 (receipt-independent).
3. WI-2 — strictly receipt-gated; if lane 05/06 receipts are absent at wrap, the four rows stay OPEN and the release-notes paragraph says so honestly.
4. WI-4 last.

## 4. Out of scope (hard boundary)

- Any code change to LRO/blob/cosmos/ledger/event planes (lanes 05-08).
- Re-grading C5/C6/C2 (no GAP tokens in this census).
- Deleting OPEN tokens without receipts (false closure — forbidden).

## Acceptance gates

1. `grep -n "GAP" docs/compliance/C3_COSMOS.md docs/compliance/C4_BLOB.md docs/compliance/C7_EVENT_PLANES.md` — zero un-tokenized GAP prose (every hit is `GAP(name)` token form, a CLOSED/superseded record, or the C7 convention line; historical CLOSED records in C3:28-30 / C1:24,:57 are permitted).
2. Every GAP row CLOSED-with-receipt or typed-UNSUPPORTED-with-close-condition (register audit of WIRE_PARITY §4 + C1 + TEST_ISOLATION §3).
3. Release-notes gap paragraph present.
4. Both vacuous tags deleted, `mix test` green, `grep -r "arm_seam\|dp_seam" test/ lib/` zero hits.
