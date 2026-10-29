# BK-ARD21B — v26.10.21 doc-drift fixes (D1/D2/D3 from BK-ARD21 terminal audit)

Standing: **ALIVE** · Context: solo · Date: 2026-10-22 · Lane: BK-ARD21B · Repo: /Users/sac/smalt

Closes the 3 DRIFT rows typed by `docs/jira/v26.10.22/receipts/bkard21-terminal-audit.md`. Zero invented content — every edit below cites disk evidence verified this session.

## D1 — PRD.md §1 citation paths (fixed)

| Before (non-resolving) | After (resolves, `[ -f ]`-verified) |
|---|---|
| `receipts/wire-parity-matrix.md` | `../v26.10.20/receipts/wire-parity-matrix.md` |
| `receipts/../../tmp/bench/t43-p99-hunt.jsonl` | `../../../tmp/bench/t43-p99-hunt.jsonl` |

Post-fix spot-check (all PRD.md citation paths, dual-base resolution):

```
OK   ../../../tmp/bench/impl21-postupgrade-sdk.jsonl
OK   ../../../tmp/bench/t43-p99-hunt.jsonl
OK   ../v26.10.20/receipts/wire-parity-matrix.md
OK   docs/jira/v26.10.21/VALIDATION.md
OK   receipts/bk31-gws14-inwasm-courts.md
OK   receipts/bk32-gws15-sec-fuzz.md
OK   receipts/cas412r-postfix-regression.md
OK   tmp/bench/powl-native-face.jsonl
```

Note: the audit's third D1 mention, `receipts/cas412r-postfix-regression.md`, already
resolves (file on disk under `docs/jira/v26.10.21/receipts/`) — no edit needed.

## D2 — VALIDATION.md stale PENDING-GWS count (2 → 0, three sites)

Mechanical grep before: `PENDING-GWS: 2` at 3 sites (§1 summary prose, §Summary
arithmetic line, §GWS-wave tail); both remaining GWS rows already struck-through
CLOSED in the table, receipts `[ -f ]`-verified on disk:
`receipts/bk31-gws14-inwasm-courts.md`, `receipts/bk32-gws15-sec-fuzz.md`.

- §1 summary prose: "PENDING-GWS: 2 (down from v5's 4 … remaining: …)" →
  "PENDING-GWS: 0 … all four GWS wave rows now CLOSED, none remaining", both
  closures now named with their receipt paths (BK-31/BK-32).
- §Summary arithmetic line: "Row-level PENDING-GWS: 2." → 0, closures cited.
- §GWS-wave tail: "Row-level PENDING-GWS: 2 (was 4 at v5)" → 0 (was 4 at v5;
  BK-31/BK-32 receipts cited).

Post-fix grep: `grep "PENDING-GWS: 2" VALIDATION.md PRD.md` → no matches (exit 1).

## D3 — PRD.md §6 acceptance ledger (board v3 counts → v8/v9 census)

Mechanical census this session from the v8 board tables (§2.1–3.3, 40 rows) plus
the v9 folds (NFR-LATENCY → PASS, PRD-APIM → ALIVE, per `receipts/bkcells-board-triage.md`):

| Bucket | v3 (old PRD §6) | v8/v9 census (new PRD §6 + VALIDATION §Summary) |
|---|---|---|
| ALIVE-class | 23 | **29** |
| PARTIAL | 10 | **7** (DATA-01..04, POWL-CEIL, PB-1, PB-2) |
| REFUTED | 5 | 5 (CORE-02, CORE-03, WIRE-03, POWL-PERF, PB-4) |
| UNSUPPORTED/FAIL | 4 | 4 (CORE-04, SEC-03, POWL-01, NFR-FOOTPRINT idle) |
| PENDING-PB placeholder | 1 | **0** (resolved: PB-2/PB-5/FONDREC landed) |

Arithmetic 29+7+5+4 = 45 cells (board grew 43→45 when the PENDING-PB placeholder
resolved into PB-2/PB-5/FONDREC). The same census was folded into VALIDATION.md
§Summary (its own arithmetic line was still 27+9+5+4 with a stale Count column;
now 29/7/5/4 with the v9 cells named in the ALIVE-class bucket row).

## Gates

```
# just docs-dod-check
…62 OK rows…
kd-receipt-fence: checked 314 receipt cites across 6 registers -> OK
docs-dod exit=0
```

## See Also

- `docs/jira/v26.10.22/receipts/bkard21-terminal-audit.md` — the DRIFT rows closed here
- `docs/jira/v26.10.21/PRD.md`, `docs/jira/v26.10.21/VALIDATION.md` — edited subjects
