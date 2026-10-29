# BK-86 — KD-164 fold lane (wait-for-and-fold on BK-85)

**Standing:** SKIP-LOUD (no-fold — BK-85 witness receipt absent within the bounded wait window; KD-164 NOT minted, register UNCHANGED)
Context: solo
Date: 2026-10-21

## Outcome

BK-85 (`docs/jira/v26.10.22/receipts/bk85-seal-invariant.md`) never landed
within the bounded wait window. Per the fold lane's receipt-gate law
(a KD disposition may only mint from a PASS/typed witness receipt, never from
an anticipated one), **KD-164 was NOT minted** and the canonical register
(`docs/jira/v26.10.14/KNOWN_DIVERGENCES.md`) is UNCHANGED — zero diff.

## Wait record (bounded polls, not sleeps-as-assertion)

Three bounded poll windows over the receipt path, deadline-checked each window:

1. 540 s window, 15 s poll cadence — absent
2. 540 s window, 20 s cadence — absent
3. 540 s window, 20 s cadence — absent

Total ~27 min of waiting; `bk85-seal-invariant.md` absent from
`docs/jira/v26.10.22/receipts/` at final check
(`ls docs/jira/v26.10.22/receipts/ | grep -i bk85` → no match).

## Registrar prep completed (the fold is ready to re-run)

- Canonical register tail verified: highest minted id is **KD-163** (row at
  `docs/jira/v26.10.14/KNOWN_DIVERGENCES.md:343`); next mint id is **KD-164**.
- Pointer doc read (`docs/jira/v26.10.21/KNOWN_DIVERGENCES.md`): current range
  KD-01..KD-163 (160 rows), "Mint from KD-164" already correct for the
  no-mint case. If KD-164 lands later, this pointer doc needs: range bump to
  KD-164, a "Rows minted this window" bullet, and the next-mint line to
  KD-165.
- Register format confirmed: 6 cells (`| id | surface | divergence | evidence |
  close condition | status |`), pipes escaped inside cells, append after line 343.
- kd_flip.py read-only baseline (2026-10-21): `FLIP-ELIGIBLE: 0`,
  `FLIP-PENDING-WITNESS: 0` — zero skew.

## kd_flip.py parse output (read-only, tail)

```
  KD-93: [CLOSED-WITH-EVIDENCE] lib/smalt/data_plane/cosmos.ex
  KD-94: [CLOSED-SIMULATED] lib/smalt/auth/bearer.ex
  KD-97: [CLOSED-SIMULATED] lib/smalt/egress_router.ex
  KD-99: [CLOSED-SIMULATED] lib/smalt/auth/sts_key.ex

FLIP-ELIGIBLE: 0
FLIP-PENDING-WITNESS: 0
```

## Handoff

When BK-85 lands, re-dispatch this fold with its exact disposition
(caller-bug-fixed → CLOSED-WITH-EVIDENCE, or upstream layout drift → typed
open row): mint the 6-cell KD-164 row in the canonical register, bump the
v26.10.21 pointer doc (range KD-01..KD-164, next-mint KD-165), re-run
`python3 scripts/kd_flip.py` read-only for zero skew, and supersede this
receipt. Nothing is blocked on smalt's side; the only outstanding dependency
is BK-85's witness.
