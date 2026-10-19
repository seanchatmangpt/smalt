# kd-register

POINTER document. The canonical KD register is
`docs/jira/v26.10.14/KNOWN_DIVERGENCES.md` — read it for rows; this file never
duplicates rows. Flips happen only via `scripts/kd_flip.py --apply`, gated on a
PASS witness receipt newer than the shim's mtime.

Counts as of 2026-10-19 @ HEAD 6681746 (re-derived from the on-disk table;
prior refresh 2026-10-16 carried 94/22/72 — predates the post-v26.10.16
flips):

| metric | count | how counted |
|---|---|---|
| register rows | 95 | `grep -c '^| KD-'` over the canonical table |
| OPEN | 63 | status column not CLOSED-* (95 − 32 CLOSED-*) |
| CLOSED-WITH-RECEIPT | 14 | status column literal |
| CLOSED-SIMULATED | 18 | status column literal |
| CLOSED total | 32 | CLOSED-WITH-RECEIPT + CLOSED-SIMULATED |

Related, non-canonical: `docs/WIRE_PARITY.md` GAP tokens (open gaps, receipt-
gated flips, never minted unilaterally) and per-window
`docs/jira/v*/KNOWN_DIVERGENCES.md` derivatives.

## See Also

- `docs/jira/v26.10.14/KNOWN_DIVERGENCES.md` — canonical register
- `scripts/kd_flip.py` — the only flip path
- `docs/WIRE_PARITY.md` — GAP token register
