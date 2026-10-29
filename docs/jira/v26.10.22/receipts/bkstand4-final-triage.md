# BK-STAND4 — final witness-window standing triage (ad-hoc tokens + punctuation)

**Standing:** PARTIAL_ALIVE — witness-window standing residue closed to a single honestly-typed extractor artifact; 8 receipts given content-preserving canonical `**Standing:**` lines derived only from embedded evidence; zero fabrication, zero parser widening, zero evidence bodies edited.

Context: solo

## Method

Re-census with the BK-WPARSE one-parser contract (`scripts/witness_all.py --dry-run`):
NO-STANDING in the witness window was already 0 (BK-STAND3 closed the 12 real
prose-only rows; the raw grep figure of 1 is that receipt's own dry-run probe
line, not a row). The live residue set is therefore the non-canonical-token set —
9 rows, all triaged per-row from embedded evidence:

## Per-row derivation (embedded)

| receipt | was | now | derivation (from embedded evidence only) |
|---|---|---|---|
| v26.10.20/kd134-requester-delivery-witness.md | `ALIVE.` (footer line) | ALIVE | same evidence, canonical form: requester-addressed delivery WITNESSED on real wire post-fix; footer line punctuation only |
| v26.10.20/scvd-browser-witness.md | SUSPECT | PARTIAL_ALIVE | receipt's own leg table: 12 OK legs consistent ×3 (cosmos_sql, sb_rule, registry, cas, containers, lifecycle, live, matrix, param, rg, rules, tags) + Tier-1 boot budget FAIL (601 ms > 500 ms, all 3 runs) + kv leg FAIL + Concurrency [SKIP] loud — mixed witnessed, kept verbatim in the line |
| v26.10.22/az1c-kafka-receipt.md | `**Standing: ALIVE.**` | ALIVE | same evidence, canonical form: kafka wire suite green on HEAD 353d9470 |
| v26.10.22/bkazdt-azdata-untrack.md | `ALIVE.` | ALIVE | same evidence, canonical form: `.gitignore` line 140 on-disk match embedded; azdata untracked |
| v26.10.22/kdconf-kv-cosmos-queue.md | CLOSED-WITH-EVIDENCE | CLOSED — with evidence | receipt's own court: 5 tests / 0 failures (KD-147..152), one probe per row, register flipped receipt-gated; register-state name preserved in the line |
| v26.10.22/bkamqpf-f2a-boundary.md | CLOSED-BY-UPSTREAM-REPAIR | CLOSED — by upstream repair | receipt's own court: 3 tests / 9 corpus legs, typed `{:bad_frame, _}` DOWN reasons witnessed, zero code change; disposition prose preserved in the line |
| v26.10.22/kd166-witness.md | NOT-ALIVE | ALIVE (falsifier executed on the real wire, close condition NOT met — KD-166 fix NOT landed, row stays OPEN; typed, no flip) | raw 101 embedded shows NO `Sec-WebSocket-Protocol` echo; per BK-STAND3 kd69 precedent a witnessed refutation/fired falsifier is ALIVE as a receipt — all NOT-landed claims preserved verbatim in the line |
| v26.10.22/w3ca-conformance-census.md | `PARTIAL_ALIVE.` (×2) | PARTIAL_ALIVE | same evidence, canonical form: census measured, agent-chain MISSING typed, no fixes implemented |

Not edited (already canonical): SKIP-LOUD (powl3-projection-reauthor-superseded,
bk86-kd164-fold), UNKNOWN (w30-ci-matrix-sketch, spofb-boundary-audit),
UNSUPPORTED (bkp20-export-disposition) — all in `STANDING_TOKENS`.

## Typed residue (honest, owner noted — NOT edited)

- **bk146r-pillar-consumers.md** first-token `ALIVE,`: sourced from VERBATIM
  embedded command output (`standing=ALIVE, cells=14 ... exit=0`, ×2) inside the
  receipt's fenced block — the extractor's last-explicit-line rule over-matches
  tool output with `key=value` shapes. The receipt's own header is already
  canonical `**Standing:** ALIVE`. Editing embedded output is banned (BK-WPARSE
  non-vacuity law), so this row is left untouched: an extractor artifact, not a
  standing-less receipt. Owner: witness_all/receipt_index owner (BK-WPARSE
  lineage) — candidate fix is fenced-block awareness in `extract_standing`.

## Gates (embedded)

```
$ python3 scripts/witness_all.py --dry-run
  BEFORE: 0 NO-STANDING rows (BK-STAND3 closed the prose-only set;
          1 grep match = bkwparse probe line, not a row)
          9 non-canonical first tokens: 3 punctuation (ALIVE./ALIVE,/PARTIAL_ALIVE.
          in author voice), 4 ad-hoc tokens (SUSPECT, NOT-ALIVE,
          CLOSED-WITH-EVIDENCE, CLOSED-BY-UPSTREAM-REPAIR), 2 already-canonical
  AFTER:  0 NO-STANDING; canonical first tokens only —
          ALIVE 297, PARTIAL_ALIVE 133, PASS 61, CLOSED 6, UNKNOWN 2,
          SKIP-LOUD 2, UNSUPPORTED 1, plus the single bk146r `ALIVE,`
          extractor artifact
$ python3 scripts/receipt_index.py    # rc=0; receipts=1459 sdk=61 total=1520 suspects=23
$ just docs-dod-check                 # rc=0; 61 OK + kd-receipt-fence 325 cites OK
```

Standing: PARTIAL_ALIVE — witness-window residue is the honestly-typed extractor artifact only; no parser widening, no evidence edited, zero fabrication.
