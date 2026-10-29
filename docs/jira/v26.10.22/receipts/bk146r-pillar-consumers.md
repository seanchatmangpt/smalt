# BK-146r — IND pillar consumers: ggen sync + gate-coverage verify + PILLARS.md disk truth

**Standing:** ALIVE
Context: solo
Date: 2026-10-22
Repos: /Users/sac/ggen (main, 1c99fade0), /Users/sac/ggen-marketplace (main, read-only — zero edits)

## Scope

IND-2 financial-ledger + IND-4 aero-defense consumers in `ggen/examples/industry/`:
(1) fresh `ggen sync run` ×2 determinism; (2) gate-coverage verify of rendered
outputs vs pack gates on disk; (3) PILLARS.md gate tables from disk truth.

## 1. Sync determinism (ggen 26.10.11)

financial-ledger run 1: both outputs `skipped: unchanged: content identical`, `written: []`.
financial-ledger run 2: identical (`written: []`).
aero-defense run 1 and run 2: all 3 outputs
(`rendered-shacl.ttl`, `air-gap-config.ttl`, `client-walkthrough.md`)
`unchanged: content identical`, `written: []`.

Deterministic ×2 on both consumers — byte-identical, zero drift.

## 2. Gate coverage vs disk truth

Pack gates on disk (ggen-marketplace packs, read-only reference):

- financial-ledger: 7 gates `010_unbalanced_entry`, `020_missing_account_ref`,
  `030_duplicate_entry_id`, `040_ledger_isolation`, `050_skr_attestation`,
  `060_proposer_judge`, `070_merkle_seal_missing`.
- aero-defense: 7 gates `010_artifact_classification_complete`,
  `020_cross_level_flow`, `030_nonloopback_endpoint`, `040_storage_segregation`,
  `050_execution_attestation`, `060_merkle_seal_missing`,
  `070_proposer_judge` (P3, landed via BK-143rr).

Rendered-output coverage:

- financial `generated/client_walkthrough.md`: ALL 7 gates listed in the
  gate table (rows 010–070) — the 040–070 rows came from the pre-429
  BK-146 attempt's template edit (`templates/client_walkthrough.md.tmpl`,
  +4 rows, uncommitted in the working tree) and sync admits it byte-exact.
- financial `generated/ledger_shapes.ttl`: mirrors gate 010 as a SHACL
  SPARQLRule (the balance law); 040–070 are walkthrough-listed laws, not
  shape-mirrored — by template design, unchanged.
- aero `generated/rendered-shacl.ttl` / `air-gap-config.ttl` /
  `client-walkthrough.md`: gates 010/020/030 named in rendered prose;
  040–070 are pack-court-side laws (pack templates read-only this lane, no
  consumer-side diff lawful). Rendered outputs are in sync with the pack
  templates as they exist on disk — no drift.

## 3. Pack courts (disk truth, re-run)

```
$ python3 qualification/verify.py   # packs/industry-aero-defense
standing=ALIVE, cells=14 (7 gates x pass/fail), exit=0
$ python3 scripts/marketplace.py check industry-aero-defense
check ok packs=1 turtle=ok qualify=ok   [exit=0]
$ python3 qualification/verify.py   # packs/industry-financial-ledger
standing=ALIVE, cells=14 (7 gates x pass/fail), exit=0
$ python3 scripts/marketplace.py check industry-financial-ledger
check ok packs=1 turtle=ok qualify=ok   [exit=0]
```

## 4. PILLARS.md updates (disk truth)

- financial-ledger `PILLARS.md`: already disk-true (7 gates, 040–070 rows,
  `cells=14 (7 gates x pass/fail)`) — no edit needed.
- aero-defense `PILLARS.md`: UPDATED. Was stale at 6 gates with P3 marked
  "no AI-proposer surface in IND-4 scope". Now carries the P3 row
  (`070_proposer_judge`, law + consumer surface + BK-143rr provenance),
  court receipt `cells=14 (7 gates x pass/fail), exit=0`, witness prose 7
  gates with 070 witness names.

## Working-tree delta (ggen, uncommitted — do not commit per task)

- `examples/industry/aero-defense/PILLARS.md` (this lane: P3/070 + counts)
- `examples/industry/financial-ledger/templates/client_walkthrough.md.tmpl`
  (pre-429 BK-146 attempt: +4 gate rows 040–070, verified in sync)
- `.ggen-v2/receipt.json` + `receipt-log.jsonl` in both consumers
  (sync receipts, refreshed by this lane's `ggen sync run`)

Receipt file: `docs/jira/v26.10.22/receipts/bk146r-pillar-consumers.md` (smalt tree).
