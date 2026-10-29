# BK-KDL — KD-180 evidence-chain cross-check

- **Lane**: BK-KDL (read-only cross-check; this receipt is the only write)
- **Date**: 2026-10-22
- **Context**: solo
- **Standing**: ALIVE

## Scope

Read-only verification that the Kafka legacy-count close's evidence chain is
complete and internally consistent on disk, and that the gates stay green on
the current tree.

## (1) Chain completeness — VERIFIED

All receipts re-checked on disk (ls + head, not session memory):

| receipt | exists | standing |
|---|---|---|
| `receipts/bkkfkc-legacy-count.md` (repair, 07:03) | yes | ALIVE |
| `receipts/bkkfkv-replay-verify.md` (replay verify) | yes | ALIVE |
| `receipts/bkkfkc2-legacy-verify.md` (final verify, 07:18) | yes | ALIVE |
| `receipts/bkkfkskep-kafka-audit.md` (defect audit) | yes | PARTIAL_ALIVE (correct: it witnesses the pre-fix defect) |
| `receipts/kdklv-row.md` (mint-then-close row lane) | yes | row in RECEIPTS.md as ALIVE |

KD-180 row present in BOTH registers, standings consistent:
- window register `docs/jira/v26.10.22/KNOWN_DIVERGENCES.md` —
  CLOSED-WITH-EVIDENCE (registrar close-typing, lane KD-KLV), evidence
  cites bkkfkskep + bkkfkv;
- canonical table `docs/jira/v26.10.14/KNOWN_DIVERGENCES.md:362` —
  CLOSED-WITH-EVIDENCE, full mechanism + falsifier ledger text matches the
  window row, explicitly notes "no tool flip taken — kd_flip read-only
  FLIP-ELIGIBLE 0 post-mint".

Close condition ("legacy frame >= 61B advances hwm by exactly 1; a planted
lying count never advances it") is met by documented falsifiers: BK-KFKV
mixed-size series 3/3/254B byte-exact across seal→kill→restart, count=5 lie
over 2 frames → hwm delta exactly 2, magic-2 count=5 header lie → typed
err=2; BK-KFKC2 re-refutes all falsifiers on the current tree (19/19 suites,
twice on fresh boots).

## (2) KD-174 truth cell + KD-180 dual-stamp precision vs BK-KFKC2 witnesses — CONSISTENT

- KD-174's truth-cell addendum (KD-174F: two layers — out-of-matrix Produce
  v3 REQUESTS crash-only `{:unsupported_version,0,3}`; magic-2 PAYLOADS
  inside in-matrix Produce v0-v2 served CRC32C-verified byte-exact) and the
  BK-KFKV-1 dual-stamp precision note (broker stamps base offset into BOTH
  wrapper offset and inner baseOffset; no-op at base 0; exact-compare
  witnesses at base > 0 must stamp both) both read back verbatim in the
  window register, matching the canonical-row cell.
- BK-KFKC2's two adjudications are honestly typed in the verify receipt, not
  contradicting the rows:
  - K1 leg `FAIL C out-of-matrix key=18 v1` → adjudicated in-receipt as err
    35 UNSUPPORTED_VERSION, the KIP-183 downgrade exception to crash-only,
    citing `lib/smalt/messaging/kafka/conn.ex:133-142` — matches the audit
    receipt's adjudication and the documented exception; not counted as a
    finding.
  - wireprobe leg B `exact=False` → adjudicated in-receipt as a
    fetch-offset-0 probe artifact (dirty/fresh journals, identical shape
    twice), with the dedicated single-frame legacy byte-exact witness being
    leg 2 `exact=True` — consistent with the dual-stamp precision note
    (base-0 no-op).
- K2b (new adversarial leg) confirms the close condition at the wire face:
  lying recordsCount=5 → typed err=2 CORRUPT_RECORD, hwm 6→6.

## (3) KD-COVERS token placement — CORRECT

`lib/smalt/messaging/kafka/records.ex:100`:
`# BK-KFKC: count/1 dispatches on the MAGIC BYTE first. # KD-COVERS: KD-180`
— comment directly above the `count/1` magic-first dispatch clauses
(magic-2 recordsCount clause + legacy magic-0/1 = 1 clause + typed-error
fallthrough), i.e. inside the exact block the row names as the shim
(count/1 clause ordering). Not in verify_batch or parse_records.

## (4) Gates

```
$ python3 scripts/kd_receipt_fence.py
kd-receipt-fence: checked 753 receipt cites across 6 registers + 2 pattern docs + 5 milestone docs (422 cites, 6 typed-gap skips) -> OK
exit 0

$ python3 scripts/kd_flip.py        (read-only, no --apply)
FLIP-ELIGIBLE: 0
FLIP-PENDING-WITNESS: 1 (KD-168 registrar hold — cross-id evidence matches are refused)
exit 0

$ just docs-dod-check
kd-receipt-fence ... -> OK
exit 0
```

No open defects. Chain complete, standings consistent, close condition
satisfied, token placement correct, gates green.

## Falsifier status

- "chain incomplete / receipt missing" — REFUTED (all five files on disk)
- "standing contradiction across registers" — REFUTED
- "adjudication contradicts a KD row" — REFUTED
- "KD-COVERS token in the wrong block" — REFUTED

Receipt: docs/jira/v26.10.22/receipts/bkkdl-chain-check.md
