# kd-register

POINTER document. The canonical KD register is
`docs/jira/v26.10.14/KNOWN_DIVERGENCES.md` — read it for rows; this file never
duplicates rows. Flips happen only via `scripts/kd_flip.py --apply`, gated on a
PASS witness receipt newer than the shim's mtime.

Counts as of 2026-10-16 (lane 9 refresh; counted from the on-disk table):

| metric | count | how counted |
|---|---|---|
| register rows | 94 | `^\| KD-` table rows |
| OPEN | 72 | status column not CLOSED-* (94 − 22 CLOSED-*) |
| CLOSED-WITH-RECEIPT | 13 | status column literal |
| CLOSED-SIMULATED | 9 | status column literal |
| CLOSED total | 22 | CLOSED-WITH-RECEIPT + CLOSED-SIMULATED |

(94 distinct KD ids are referenced across the file including prose/citation
mentions; the table carries 94 rows as of this refresh — earlier counts of
78/79 predate the KD-53..KD-94 batch landing.)

Related, non-canonical: `docs/WIRE_PARITY.md` GAP tokens (open gaps, receipt-
gated flips, never minted unilaterally) and per-window
`docs/jira/v*/KNOWN_DIVERGENCES.md` derivatives.

## See Also

- `docs/jira/v26.10.14/KNOWN_DIVERGENCES.md` — canonical register
- `scripts/kd_flip.py` — the only flip path
- `docs/WIRE_PARITY.md` — GAP token register
