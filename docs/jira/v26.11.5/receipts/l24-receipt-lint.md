# L24 — Receipt Standing Lint Port (smalt)

Standing: ALIVE

## What landed

- `scripts/receipt_standing_lint.py` — Gate 3 port of cgap
  `scripts/receipt_standing_lint.py` (8d15fcca; ggen ancestor lane L21).
  Synonym keys `Standing|Status|verdict|Result|Exit code` (case-insensitive),
  closed vocabulary = receipt-standing-law six (ALIVE / PARTIAL_ALIVE /
  PARTIAL / BLOCKED / UNVERIFIED / PASS — UNVERIFIED always lintable) plus a
  documented smalt extension set (tokens receipt_index.py already honors +
  observed corpus spellings), `Exit code: N` -> `Exit-code-N`, annotation
  stripping (backticks, parenthesized suffix, markdown emphasis, trailing
  punctuation), standing-map hash `7f38336fee60c175`,
  map at `docs/jira/receipt-standing-map.json`.
- `--backfill` (diff-only, canonical) and `--write` (smalt addition used once
  for the initial batched backfill).
- `justfile.d/64-receipts.just` + ONE import line in root `Justfile`
  (adjacent to lanes L12r/L29's lines, neither rewritten).
- Regenerated `docs/jira/v26.10.14/RECEIPTS.md` +
  `v26.10.14/receipts/INDEX.md` (receipt_index.py extraction legitimately
  changed by the inserted lines; small diff, values quoted from files' own
  heads) and `docs/jira/v26.11.5/RECEIPTS.md` / `INDEX.md` side effects.
- Batched backfill: 1018 files got `Standing: <X>` inserted after the H1
  (260 UNVERIFIED fallback; 758 quoting only vocabulary already present in
  the file head); 51 files with pre-existing MALFORMED standing lines got a
  lawful `Standing:` line inserted after the H1 above the historical line
  (historical line left intact as evidence): 16 PARTIAL_ALIVE / 15 UNVERIFIED
  / 12 ALIVE / 7 PASS / 1 PARTIAL. Final census 1683/1683 parse OK, exit 0
  (`just receipt-standing-lint` PASS).

## Composition with receipt_index.py (not a clobber)

receipt_index.py (lane 13) checks evidence behind the standing claim (SUSPECT
census, wired into verify-all); this lint checks that a parseable standing
line exists at all in the closed vocabulary. Different questions; both stay.
Generated `INDEX.md` files are excluded from lint targets (no standing line
by design). `receipt-index-check` still passes on the regenerated index
(bytes committed).

## Collision disclosure (shared seam: root Justfile import block)

L12r (`62-bin-opt.just`) and L29 (`63-aoq.just`) import lines were present in
the working tree when I added mine; I appended one comment+import pair after
L29's line and rewrote nothing. Only my lane-owned files plus that single
Justfile seam pair were touched.

## Verification

- `python3 scripts/receipt_standing_lint.py` — PASS, 1683 files, 0 FAIL, exit 0
- `just receipt-standing-lint` — exit 0
- `python3 scripts/receipt_index.py` — rc 0; index regenerated + committed
- Backfill value law honored: quote-only-present vocabulary, else UNVERIFIED;
  one line per file, immediately after the H1.
