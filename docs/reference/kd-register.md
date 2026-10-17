# kd-register

POINTER document. The canonical KD register is
`docs/jira/v26.10.14/KNOWN_DIVERGENCES.md` — read it for rows; this file never
duplicates rows. Flips happen only via `scripts/kd_flip.py --apply`, gated on a
PASS witness receipt newer than the shim's mtime.

Counts as of 2026-10-16 (counted from the on-disk table):

| metric | count | how counted |
|---|---|---|
| register rows | 78 | `^\| KD-` table rows |
| OPEN | 52 | status column not CLOSED-* |
| CLOSED (CLOSED-WITH-RECEIPT / CLOSED-SIMULATED) | 26 | status column CLOSED-* |

(79 distinct KD ids are referenced across the file including prose/citation
mentions; the table carries 78 rows — the id-space has gaps and some ids are
cited before being tabled.)

Related, non-canonical: `docs/WIRE_PARITY.md` GAP tokens (open gaps, receipt-
gated flips, never minted unilaterally) and per-window
`docs/jira/v*/KNOWN_DIVERGENCES.md` derivatives.

## See Also

- `docs/jira/v26.10.14/KNOWN_DIVERGENCES.md` — canonical register
- `scripts/kd_flip.py` — the only flip path
- `docs/WIRE_PARITY.md` — GAP token register
