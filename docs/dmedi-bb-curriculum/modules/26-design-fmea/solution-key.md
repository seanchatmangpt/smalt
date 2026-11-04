# Module 26 Solution Key — DFMEA (court-re-derived)

Standing: court exit 0, 109 PASS, witnessed 2026-11-04 via
`python3 scripts/derive_keys.py`. Every value below is re-derived from
`data/dfmea-worksheet.csv` by the court; the key is a projection of the
worksheet, never the authority.

## Ranked RPNs (pre-action), RPN = S x O x D

| Rank | Mode | RPN pre | S/O/D pre | AP pre | AP post | RPN post |
|---|---|---|---|---|---|---|
| 1 | FM-01 | 360 | 10/6/6 | High | High | 90 |
| 2 | FM-06 | 288 | 9/4/8 | High | Medium | 36 |
| 3 | FM-10 | 245 | 7/5/7 | High | Low | 42 |
| 4 | FM-09 | 224 | 4/7/8 | Medium | Low | 12 |
| 5 | FM-05 | 216 | 9/3/8 | High | High | 72 |
| 6 | FM-03 | 210 | 6/5/7 | High | Low | 48 |
| 7 | FM-04 | 140 | 5/4/7 | Low | Low | 20 |
| 8 | FM-02 | 140 | 4/5/7 | Medium | Low | 32 |
| 9 | FM-08 | 126 | 3/6/7 | Medium | Low | 36 |
| 10 | FM-07 | 120 | 8/3/5 | Medium | Low | 32 |
| 11 | FM-12 | 108 | 9/2/6 | High | Medium | 36 |
| 12 | FM-11 | 100 | 5/5/4 | Low | Low | 40 |

## Post-action laws (court-enforced)

- Every post-action RPN is strictly lower than pre-action (all 12 improved).
- Severity never improves without a design change: all S unchanged.
- FM-01 (S=10) can never de-escalate below AP High — monitored, not closed.
- FM-05 stays AP High post-action (O 3→2, D 8→4, RPN 72): severity 9 with
  detection rating 4 cannot drop to Medium until D <= 3 under the AP table.
- FM-09 (RPN 224) outranks FM-05 (RPN 216) under RPN while AP puts S=9 modes
  above the S=4 mode — the computed RPN-vs-AP disagreement the module teaches.
