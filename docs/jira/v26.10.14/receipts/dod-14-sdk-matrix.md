# DoD-14 — SDK Coverage Matrix (receipt)

Lane DoD-14, v26.10.14, 2026-10-15. Subject: /Users/sac/smalt (working tree, no commits made).

## Delivered

- `scripts/sdk_coverage.py` — matrix compiler. Surface inventory is mechanical:
  each of the 12 surfaces is grounded by keyword search against the live
  implementation ((a) `lib/smalt/data_plane/*.ex` modules, (b) route families in
  `lib/smalt/egress_router.ex`, (c) `lib/smalt/registry.ex` admitted types +
  `arm_gateway/router.ex`); a surface whose grounding keywords are absent fails
  `grounded` and is reported. Cells: TS probe (test/sdk-full/*.probe.mjs),
  Python probe (test/sdk-python/py_*.py), and the per-language
  `docs/jira/v26.10.14/sdk-results/*.md` receipt verdict. Every non-pass cell
  carries the KD ids whose register row cites that receipt, else
  UNREGISTERED-GAP.
- `docs/jira/v26.10.14/SDK_MATRIX.md` — generated table + machine summary.
- `justfile.d/14-sdk-matrix.just` — `sdk-matrix`, `sdk-matrix-md`.

## Gate semantics (as implemented)

- Cell statuses: PASS (clean receipt), REGISTERED-DIVERGENCE (receipt records
  FAIL/DIVERGENCE and >=1 KD row cites the receipt), UNREGISTERED-GAP
  (failures recorded, no KD row cites it), MISSING (no probe or no receipt).
- Exit 0 = every cell pass-or-registered. Exit 1 = findings exist (MISSING /
  UNREGISTERED-GAP) — surfaced, not hidden.
- Census CRC: `probe(` registrations in census.test.cjs counted mechanically
  and cross-checked against receipts/08-servicebus-census.md ("registers 11
  probes") and the file header. Result: registered=11, receipt_claim=11,
  header=11 -> OK. The receipt's own OPEN flag on "11 green" remains about
  *execution*, which this CRC does not claim.

## Witnessed run (exit 1 — findings exist)

```
divergence register: 35 KD rows loaded
arm              TS=REGISTERED-DIVERGENCE[KD-30,31,32] PY=REGISTERED-DIVERGENCE[KD-24..27,35]
blob             TS=REGISTERED-DIVERGENCE[KD-01,04,05] PY=REGISTERED-DIVERGENCE[KD-01,02,03]
cosmos           TS=MISSING                            PY=REGISTERED-DIVERGENCE[KD-06..09]
keyvault         TS=REGISTERED-DIVERGENCE[KD-10..15,33,34] PY=PASS
skr              TS=REGISTERED-DIVERGENCE[KD-10..15,33,34] PY=PASS
eventgrid        TS=MISSING                            PY=REGISTERED-DIVERGENCE[KD-21]
eventhubs        TS=REGISTERED-DIVERGENCE[KD-18,19,20] PY=REGISTERED-DIVERGENCE[KD-21]
sentinel         TS=MISSING                            PY=REGISTERED-DIVERGENCE[KD-22,23]
resource-graph   TS=MISSING                            PY=REGISTERED-DIVERGENCE[KD-22,23]
purview-atlas    TS=MISSING                            PY=MISSING
ledger           TS=MISSING                            PY=MISSING
servicebus       census CRC: registered=11 receipt_claim=11 header=11 -> OK
cells PASS: 2  MISSING=8  UNREGISTERED-GAP=0  REGISTERED-DIVERGENCE=12
```

Executed: `python3 scripts/sdk_coverage.py` -> exit 1;
`just -f justfile.d/14-sdk-matrix.just sdk-matrix-md` -> compiler exit 1, SDK_MATRIX.md regenerated on disk (verified by read-back above).

## Findings (for the ledger, not hidden)

1. **MISSING cells (8)**: no TS probe/receipt for cosmos, sentinel,
   resource-graph, eventgrid; no TS or PY cells at all for purview-atlas and
   ledger. These are gaps to file, not silent rows.
2. **UNREGISTERED-GAP: 0.** Every non-pass cell's failures trace to KD rows in
   KNOWN_DIVERGENCES.md (35 rows parsed, including escaped-pipe rows KD-16/23).
   Expected open cells (KV challenge-auth = KD-15, error-code token = KD-04,
   EH message_format/credit/$management = KD-18/19/20, pyamqp open-frame =
   KD-21) all surface as REGISTERED-DIVERGENCE cells, mechanically explicit.
3. keyvault PY receipt (13/13 PASS in its verdict line) is classified PASS
   after cross-checking; its divergences (D1-D6) are registered (KD-10/13/15/
   16/17/35) and render on the register rows.

## Standing

ALIVE for the representation + gate: the matrix compiles from live sources,
the census CRC passes, exit codes behave per spec. The covered surfaces remain
as their receipts record (12 REGISTERED-DIVERGENCE cells + 2 PASS). No lib/
edits; owned files only; no commits.
