# Receipt — KD-MIR2 post-KD-175 register mirror verify

Standing: PARTIAL_ALIVE
Context: solo
Date: 2026-10-22

Read-only verification of the KD-169..179 mint/close wave against the canonical
register (`docs/jira/v26.10.14/KNOWN_DIVERGENCES.md`) and the v26.10.22 pointer
(`docs/jira/v26.10.22/KNOWN_DIVERGENCES.md`). Lane KD-MIR2; no lib/, test/, or
register edits.

## 1. Census

- Zero duplicate ids canonical-wide (fresh grep, row-start `^| KD-nn` field):
  `grep -oE "^\| KD-[0-9]+" ... | sort | uniq -c | awk '$1>1'` → EMPTY (no output,
  the two prior corrections held). Full-document mention counts >1 are
  cross-references, not duplicate rows.
- Every window row KD-169..179 exists in canonical EXCEPT KD-177:
  canonical carries a full KD-177 class row (environment-gated
  hardware-anchored trust surfaces) but the v26.10.22 pointer has NO
  `- KD-177` section — `grep -n "^- KD-177"` on the window doc → no matches,
  while `^- KD-` count = 10 (169,170,171,172,173,174,175,176,178,179).
  **FINDING (drift): KD-177 is missing from the window pointer doc.**
- Row census: canonical table rows KD-170..KD-179 = 10
  (`grep -cE "^\| KD-17[0-9] "` → 10); window `- KD-` sections = 10 (missing 177).

## 2. Pointer

- Window pointer line 4: `Mint from KD-180 (highest minted id is KD-179 …)` —
  highest+1 ✓ (highest canonical row id KD-179, next free KD-180).
- The canonical register carries NO "Mint from" line by design (append-only
  ground-truth table; the mint pointer lives in the window pointer doc only,
  consistent with KD-ATON's receipt wording "v26.10.22 pointer bumped
  Mint-from KD-179 -> KD-180").

## 3. Status parity (canonical vs window)

| KD | canonical status | window status | match |
|---|---|---|---|
| 169 | CLOSED-WITH-EVIDENCE | CLOSED-WITH-EVIDENCE | ✓ |
| 170 | CLOSED-WITH-EVIDENCE | CLOSED-WITH-EVIDENCE | ✓ |
| 171 | CLOSED-WITH-EVIDENCE | CLOSED-WITH-EVIDENCE | ✓ |
| 172 | CLOSED-WITH-EVIDENCE | CLOSED-WITH-EVIDENCE | ✓ |
| 173 | CLOSED-SIMULATED (kd173c-devplane-close.md) | **OPEN (registered)** | **MISMATCH** |
| 174 | OPEN (two-layer truth cell) | OPEN (registered) | ✓ |
| 175 | CLOSED-WITH-EVIDENCE | CLOSED-WITH-EVIDENCE (KD-175F) | ✓ |
| 176 | CLOSED-WITH-EVIDENCE (KD-P6 registrar close-typing) | CLOSED-WITH-EVIDENCE | ✓ |
| 177 | OPEN — TYPED ENVIRONMENT-GATED | (row absent in window) | — |
| 178 | OPEN — TYPED DELIBERATE-CONTRACT | OPEN (registered) | ✓ |
| 179 | OPEN — TYPED ACCEPTED-BECAUSE-GENUINELY-LOOPBACK | OPEN — TYPED | ✓ |

**FINDING (drift): KD-173 window status is stale** — window says
`Status: OPEN (registered)` while canonical is CLOSED-SIMULATED with witness
receipt `docs/jira/v26.10.22/receipts/kd173c-devplane-close.md` (receipt exists
on disk, verified). Canonical is ground truth; the window pointer text lags.

## 4. Holds / FLIP-PENDING-WITNESS honesty

- KD-168 (registrar hold, DO-NOT-FLIP): honestly listed canonical row 348
  ("DO-NOT-FLIP (registrar hold, lane KD-168F 2026-10-22)"); kd_flip read-only
  reports `FLIP-PENDING-WITNESS: 1 / KD-168: registrar hold — cross-id evidence
  matches are refused` ✓.
- KD-174 (two-layer truth, OPEN): honestly listed canonical row 354 with the
  KD-174F reconciliation; window Status OPEN ✓. No spurious eligibility minted.
- KD-175 (CLOSED-WITH-EVIDENCE, shim token KD-175 after EXPL9-REG re-token from
  the mis-minted KD-174): honestly listed, re-token note present both sides ✓.
- No spurious FLIP-ELIGIBLE anywhere: `FLIP-ELIGIBLE: 0`.

## 5. Gates (real output)

```
$ python3 scripts/kd_flip.py            # read-only
FLIP-ELIGIBLE: 0
FLIP-PENDING-WITNESS: 1
  KD-168: registrar hold — cross-id evidence matches are refused
exit=0

$ python3 scripts/kd_receipt_fence.py
kd-receipt-fence: checked 329 receipt cites across 6 registers + 2 pattern docs -> OK
exit=0

$ just docs-dod-check
OK docs/jira/v26.10.18/RECEIPTS.md … OK README.md
kd-receipt-fence: checked 329 receipt cites across 6 registers + 2 pattern docs -> OK
exit=0
```

## 6. Verdict

Zero drift on the canonical side of the checked set (all 10 canonical rows
honest, holds intact, pointers correct, no duplicates, gates green), but two
window-side projection-lag findings:

1. KD-177 has no v26.10.22 pointer row (canonical-only).
2. KD-173 window status text is stale (OPEN vs canonical CLOSED-SIMULATED).

Standing PARTIAL_ALIVE, not ALIVE: the drift is real but confined to the
window pointer doc's prose, canonical ground truth is clean. Owners: next
window-registrar lane should add the KD-177 pointer row and refresh the
KD-173 window status. No lib/, test/, or register edits made.
