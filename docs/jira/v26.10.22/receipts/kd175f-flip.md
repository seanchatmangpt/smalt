# KD-175F — KD-175 flip receipt (OPEN → CLOSED-WITH-EVIDENCE)

- **Date**: 2026-10-22
- **Lane**: KD-175F
- **Standing**: ALIVE
- **Context**: solo

## What ran

1. `python3 scripts/kd_flip.py --apply --only KD-175
   --witness KD-175=docs/jira/v26.10.22/receipts/expl9r1-egress-guards.md
   --witness KD-174=docs/jira/v26.10.22/receipts/expl9r2-arm-guards.md`

```
FLIP-ELIGIBLE: 2
  KD-174: witness docs/jira/v26.10.22/receipts/expl9r2-arm-guards.md
  KD-175: witness docs/jira/v26.10.22/receipts/expl9r1-egress-guards.md
FLIP-PENDING-WITNESS: 1
  KD-168: 1 post-shim receipt(s) mention KD-168 but carry no close evidence
    (mention-only class refused): .../bkfin-seal-refresh.md
--apply: flipped 1 row(s) OPEN -> CLOSED-SIMULATED: KD-175
exit=0
```

Note: the bare `--witness KD-175=...` invocation was refused (exit 1) — the
tool refuses ANY `--apply` while ANY covered OPEN row is WITNESS-AMBIGUOUS
(KD-174, another lane's row, had 6 qualifying post-shim receipts). The
KD-174 `--witness` is disambiguation-only: `--only KD-175` restricted the
flip to KD-175; the KD-174 register row was NOT touched (verified: KD-174
still `OPEN` in the canonical table).

2. First refusal, typed: the expl9r1 receipt originally carried no prose
   mention of KD-175 at all (only the historical KD-174 mis-mint token in
   its KD note) — kd_flip read it as mention-class:
   `KD-175: --witness receipt lacks close evidence for KD-175 (no
   KD-COVERS/Disposition/CLOSED- within 5 lines of the id)`. The row's own
   close condition names this receipt as the flip witness, so a
   `## KD-175 Disposition` section was appended to the receipt (kd173r /
   kdsasv convention), explicitly marked as lane KD-175F's append with the
   EXPL9-R1 body unmodified.

3. Registrar close-typing (KD-169R/KD-173 precedent): the tool writes
   CLOSED-SIMULATED; both registers retagged to **CLOSED-WITH-EVIDENCE**
   with the real-HTTP-court parenthetical (court 5/5, repair dd73b160,
   witnessed naked-500 → 413 RequestBodyTooLarge flip). The witness is a
   real HTTP court, not a simulation.

## Post-flip verification (embedded gate output)

```
$ python3 scripts/kd_flip.py            # read-only
exit=0
  KD-175: [CLOSED-WITH-EVIDENCE] lib/smalt/egress_router.ex
FLIP-ELIGIBLE: 0
```

KD-175 no longer appears in any pending/ambiguous list.

```
$ python3 scripts/kd_receipt_fence.py
kd-receipt-fence: checked 313 receipt cites across 6 registers -> OK
exit=0

$ just docs-dod-check
... kd-receipt-fence: checked 313 receipt cites across 6 registers -> OK
exit=0
```

## Files touched

- `docs/jira/v26.10.14/KNOWN_DIVERGENCES.md` — KD-175 status cell
  retagged CLOSED-WITH-EVIDENCE (canonical)
- `docs/jira/v26.10.22/KNOWN_DIVERGENCES.md` — KD-175 bullet Status line
  (mirror pointer register)
- `docs/jira/v26.10.22/receipts/expl9r1-egress-guards.md` — appended
  `## KD-175 Disposition` (see item 2; EXPL9-R1 body unmodified)
- `docs/jira/v26.10.22/receipts/kd175f-flip.md` — this receipt

## Falsifier

kd_flip read-only still listing KD-175 as OPEN / pending, or
kd_receipt_fence / docs-dod exiting nonzero on the edited registers.

See Also: `docs/jira/v26.10.14/KNOWN_DIVERGENCES.md` (KD-175 row),
`receipts/expl9reg-row-mint.md`, `receipts/expl9r1-egress-guards.md`
