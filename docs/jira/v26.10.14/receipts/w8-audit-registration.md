# W-8 Registration Receipt — Audit GAP consolidation into KNOWN_DIVERGENCES

Date: 2026-10-15. Lane W-8. Subject: `/Users/sac/smalt` @ main (uncommitted;
no commits per task instruction).

## What was done

Consolidated all wire-parity audit findings
(`docs/audit/sections/aud1-blob-cosmos.md`, `aud2-eh-sb-kv.md`,
`aud3-arm-mgmt.md`) into
`docs/jira/v26.10.14/KNOWN_DIVERGENCES.md`. Numbering continued from the
existing max KD-53; AUD-3's proposed KD-54..59 honored as proposed, AUD-1/
AUD-2 gaps filed as KD-60..75. No existing rows renumbered.

## Status determination

No W-lane closure receipts (`receipts/w1..w7-*.md`) existed at registration
(receipts dir enumerated 2026-10-15) — all new rows are OPEN with the audit
section as evidence and the GAP block's close condition + falsifier.

## Full id map (audit GAP id → KD id → status)

| audit gap | KD | status |
|---|---|---|
| GAP-AUD3-54 (subscription resource list) | KD-54 | OPEN |
| GAP-AUD3-55 (provider surface holes) | KD-55 | OPEN |
| GAP-AUD3-56 (provider register/unregister) | KD-56 | OPEN |
| GAP-AUD3-57 (generic PATCH) | KD-57 | OPEN |
| GAP-AUD3-58 (tag operations) | KD-58 | OPEN |
| GAP-AUD3-59 (RG export/move) | KD-59 | OPEN |
| GAP-AUD1-01 (+09, comp mis-dispatch class) | KD-60 | OPEN |
| GAP-AUD1-02 (blob batch) | KD-61 | OPEN |
| GAP-AUD1-03 (user delegation key + SAS) | KD-62 | OPEN |
| GAP-AUD1-04 (cosmos change feed) | KD-63 | OPEN |
| GAP-AUD1-05 (cosmos Patch RFC 6902) | KD-64 | OPEN |
| GAP-AUD1-06 + 06b (sprocs/triggers/UDFs; silent no-op) | KD-65 | OPEN |
| GAP-AUD1-09b (range content-md5/crc64) | KD-66 | OPEN |
| GAP-AUD1-10 (x-ms-version value unvalidated) | KD-67 | OPEN |
| GAP-A2-01 (EH selector-filter) | KD-68 | OPEN |
| GAP-A2-02 (EH epoch not enforced) | KD-69 | OPEN |
| GAP-A2-03 (EH delivery_annotations) | KD-70 | OPEN |
| GAP-A2-04 (EH x-opt-offset/enqueued/partition-key) | KD-71 | OPEN |
| GAP-A2-05 (session-state ops) | KD-72 | OPEN |
| GAP-A2-06 (get-message-sessions) | KD-73 | OPEN |
| GAP-A2-07 (batch-delete-messages) | KD-74 | OPEN |
| GAP-A2-09 (updateKey PUT) | KD-75 | OPEN |

Dedupes (cross-referenced in the register's "Audit cross-references"
section, no duplicate rows):

- GAP-AUD1-07 → KD-02 (confirms OPEN)
- GAP-AUD1-08 → KD-05 (confirms OPEN)
- GAP-AUD1-09 → filed within KD-60
- GAP-A2-08 → extends KD-33/KD-34 class (route shape)
- GAP-A2-10 → extends KD-33/KD-16 class (versioned crypto URLs)
- GAP-A2-12 → duplicate surface of KD-12

Net: register now KD-01..KD-75 — 68 OPEN, 7 closed (KD-01/03/07, KD-15,
KD-18/19/20 + KD-21/49 CLOSED-SIMULATED, KD-52; census text updated).

## Verification

- `python3 scripts/kd_flip.py` → exit 0 (7 KD ids across 8 files,
  0 flip-eligible, 0 pending-witness; covers-map consistent).
- `just gap-sync` → exit 0 ("census floors hold; WIRE_PARITY census matches
  lane-13 ...; no contradictions").

## Falsifier

A missing registration would show as: a GAP id from
`docs/audit/sections/*.md` with no KD row and no cross-reference entry in
KNOWN_DIVERGENCES.md. Swept: GAP-AUD1-01..10 (incl. 06b, 09b) and
GAP-A2-01..12 and GAP-AUD3-54..59 are all mapped above.
