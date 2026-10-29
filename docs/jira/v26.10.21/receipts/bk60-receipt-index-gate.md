# BK-60 — Receipt-index gate for the active windows (v26.10.21 + v26.10.22)

**Standing**: ALIVE
- **Context**: solo
- **Date**: 2026-10-21 · Repo: /Users/sac/smalt · branch main
- **Gate**: `python3 scripts/receipt_index.py` (terminal-gate clause: exit 0,
  zero SUSPECT/NO-CONTEXT scoped to the active windows)

## Before / after in-scope flag counts

| window | before | after |
|---|---|---|
| v26.10.21/receipts/ | 7 (2 SUSPECT + 5 NO-CONTEXT) | 0 |
| v26.10.22/receipts/ | 1 (1 SUSPECT) | 0 |
| total | 8 | 0 |

Pre-window flags (v26.10.14 canonical aggregate + older windows) remain
flagged and are out of scope per the gate clause — recorded, not fixed
(49 SUSPECT lines total across all windows in the before-run).

## Diagnosis (all 8 were format/law artifacts, zero content re-derivations)

1. **NO-CONTEXT x5** (`gws18-real-runner-court`, `ja13-supervisor-intensity-court`,
   `ja7-crash-only-court`, `sk5-sk3-credit-arbitration`, `wrap1-duckdb-rescope-decision`):
   each genuinely carried no `Context:` line (the CTXFILL regex
   `\bContext\*?\**\s*:\s*\**\s*(solo|pair|slice|full)\b` matched nothing).
   All five already had real output embedded (`Result: 7 passed`, `Result: 6
   passed`, 2x `Result: 13 passed`, `COURT JA13 PASS (5/5 phases)`,
   docs-dod-check 63 OK / EXIT=0, grep proofs). Fix: append the dated
   `## Gate re-embed (BK-60, 2026-10-21)` section with `Context: solo` +
   a fresh real subject re-check.
2. **SUSPECT x3** (`ja9-scaling-envelope`, `ttv8-spec-bounds`,
   `bk53-finalrelease-draft`): evidence tokens existed but in spellings the
   index regexes do not match:
   - ja9: numbers embedded but no `exit`/`N passed`/PASS token anywhere.
   - ttv8: wrote `exit=0` — the regex `\bexit (code|status)?\s*[:=]?\s*\d`
     requires a space after "exit", so `exit=0`/`EXIT=0` never match.
   - bk53: wrote `EXIT=0` (same miss).
   Fix: fresh gate re-run with the canonical spelling, embedded verbatim.

## Fresh verification embedded (real output, run 2026-10-21)

- `just docs-dod-check` re-run fresh: 63 OK rows, 0 MISS, exit 0 — embedded
  (trimmed tail) into ttv8 + bk53.
- ja9: `wc -l tmp/bench/ja9-scaling.jsonl` → 7 rows on disk, tail row matches
  the receipt's face-4 run-11 provenance numbers (ops_per_sec 16248, errors 1).
- gws18: court file present (`Smalt.Integration.WasmRealRunnerCourtTest`);
  real runner present (`/Users/sac/graphlaw/target/release/graphlaw-run`,
  rebuilt today 17:29, sha256 prefix `88dbe897ba74b33f` — runner rebuilt by
  the pin-drift lane, disclosed; the court serves a per-run snapshot so the
  drift report remains the authority).
- ja13/ja7/sk5: court files present with their load-bearing markers
  (12 `JA13.` sites; `Integration.Ja7CrashOnlyCourt` module; both re-pinned
  credit-boundary atoms at skeptic-court lines 262/377).
- wrap1: the recorded decision line still on disk at
  `WASM-SANDBOX-SPEC.md:101`.

## Final index output

```
$ python3 scripts/receipt_index.py ; echo "exit $?"
exit 0
v26.10.21/receipts/INDEX.md:  SUSPECT flags: 0 — none
v26.10.22/receipts/INDEX.md:  SUSPECT flags: 0 — none
```

Gate clause satisfied: exit 0, in-scope flag count 0. Not committed, per
dispatch. Formatting fixes: 3 (ttv8, bk53 exit-token spelling) + 5 Context
lines; content re-derivations: 0 (no lane rerun required — every flagged
receipt's subject re-verified on disk instead).
