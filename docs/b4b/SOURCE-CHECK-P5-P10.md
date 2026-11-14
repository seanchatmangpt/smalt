# SOURCE-CHECK-P5-P10

Standing: PARTIAL

## Rates (fetched 2026-11-14)

- NY Fed SOFR 2024-03-14: fixture percentiles/volume differed from live API
  (p1 5.27, p75 5.34, p99 5.39, vol 1782; rate 5.31 and p25 5.30 matched). FIXED.
- FRED DGS10 03-11/12/14: fixture 4.08/4.15/4.30 vs fetched 4.19/4.23/4.21. FIXED
  (summarizer-relayed values, not raw file). 03-13 fixture "." kept: fetched 4.24, so
  the "." is a synthetic missing marker (FRED does emit "." on holidays); the test
  asserts exactly one "." so it was left. Envelope keys match FRED docs.
- EDGAR Apple CIK0000320193 10-Q 0000320193-24-000006: UNVERIFIED (not fetched);
  second row (8-K 2024-01-30) UNVERIFIED.

## ERP

- QBO JournalEntry, QBO Account, Xero ManualJournal, NetSuite journalentry: field
  names consistent with recalled public docs; docs not fetched. UNVERIFIED.

## Test changes needed

- None. Optional: erp/rates tests asserting on DGS10 values would need the new numbers
  (current test only counts "." entries).
