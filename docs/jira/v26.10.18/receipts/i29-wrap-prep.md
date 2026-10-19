# i29 — wrap prep for AZB-23/24 (receipt-index, docs-dod, TEST_ISOLATION, TICKETS sweep)

Standing: PASS (all 4 wrap-prep checks green; 5 doc edits, all Context-law conformances)

Context: solo(just receipt-index + just docs-dod-check + Context-law sweep over docs/jira/v26.10.18/receipts/ + TICKETS.md status sweep; no git ops)

Subject: /Users/sac/smalt @ main (0009df3 at wrap start; tree carried 4 pre-existing dirty burn files owned by in-flight lanes).

## 1. just receipt-index — v26.10.18 SUSPECT count = 0

```
receipts=549 sdk=51 total=600 suspects=16
wrote /Users/sac/smalt/docs/jira/v26.10.18/RECEIPTS.md
wrote /Users/sac/smalt/docs/jira/v26.10.18/receipts/INDEX.md
```

All 16 SUSPECT flags belong to v26.10.14 (closed exemplar window, legacy
bench/fin/lc receipts) — none in v26.10.16/17/18:

```
docs/jira/v26.10.17/receipts/INDEX.md:8:- SUSPECT flags: 0 — none
docs/jira/v26.10.16/receipts/INDEX.md:8:- SUSPECT flags: 0 — none
docs/jira/v26.10.18/receipts/INDEX.md:8:- SUSPECT flags: 0 — none
docs/jira/v26.10.14/receipts/INDEX.md:8:- SUSPECT flags: 16 — 06-blob-x-ms-date-unvalidated.md, ... (16 names)
```

### Context-law repairs (5 edits)

Four receipts lacked a `^Context:` line and one had a non-conforming value
(law: `^Context:\s*(solo|pair\(|slice\(|full)`,
`docs/jira/v26.10.17/RECEIPT_CONTEXT_LAW.md`):

| receipt | before | after |
|---|---|---|
| i29-compile-clean.md | none | `Context: solo(fresh-compile census in private root _build-ft-cc, no shared _build touched)` |
| i29-corpus-fresh.md | none | `Context: slice(mix test test/corpus_test.exs test/compliance_test.exs, 3 runs, private root _build-ft-cs3)` |
| i29-stress-fresh.md | none | `Context: slice(mix test --include stress, compile-abort census at sovereign_midnight_test.exs; zero tests executed, no edits, no git ops)` |
| i29-wire-fresh.md | none | `Context: slice(mix test test/wire --include amqp_wire, 2 runs, private root _build-ft-w3)` |
| i29-pinion-spot.md | `Context: read-only spot-audit ...` (non-conforming verb) | `Context: solo(read-only spot-audit at HEAD dda0bf5; no edits, no git ops)` |

Post-fix sweep:

```
ALL-CONTEXT-CONFORMING
NO-CONTEXT: docs/jira/v26.10.18/receipts/INDEX.md   (generated file, exempt)
```

## 2. just docs-dod-check — exit 0

```
OK    README.md
EXIT=0
```

61 checks, all OK, zero MISS (full output: v26.10.14/16/17 named receipts,
Diataxis tree, v26.10.18 D15 pages, have-runbook, front door). No dangling
receipt paths; no fixes needed.

## 3. TEST_ISOLATION :sovereign_gap row + i29 indexing

Row present at `docs/TEST_ISOLATION.md:49`:

```
| `:sovereign_gap` | Sovereign Midnight capstone (v26.10.18): 6 failing phase bodies of `test/azsim/sovereign_midnight/sovereign_midnight_test.exs` — ... G1–G6 (docs/jira/v26.10.18/azsim-burn/SOVEREIGN_MIDNIGHT.md). Typed exclusion; re-enable when the v26.10.19 gaps close. | coordinator (spec-derived file) | `mix test --include sovereign_gap` |
```

All 13 `i29-*.md` receipts appear in the regenerated
`docs/jira/v26.10.18/RECEIPTS.md` (14 mentions = 13 receipt rows + index
header):

```
$ grep -c "i29-" docs/jira/v26.10.18/RECEIPTS.md
14
```

## 4. TICKETS.md status sweep

`docs/jira/v26.10.18/azsim-burn/TICKETS.md` carries **no per-ticket status
lines** — standing is receipt-derived by design (AZB-24 Accept:
"ticket standing table regenerated from receipts (`receipt_index.py`), never
typed by hand"). So there is nothing to mark stale. Receipt census vs tickets:

- Receipts landed: azb-01..16, azb-11b, azb-19, azb-20 (PARTIAL_ALIVE, 6 typed
  gap cells), azb-21 (ALIVE), azb-22 (RED — typed ZOMBIE_BEAM, jidoka
  line-stop; machinery green where witnessed).
- No receipt: AZB-17, AZB-18 (in flight per coordinator — not marked),
  AZB-23, AZB-24 (this wrap preps their landing).
- No azb receipt is SUSPECT; all embed real output.

## Edits this session

5 receipt files (Context lines only; no standing, output, or claim changed) +
this receipt. No generated file hand-edited; RECEIPTS.md/INDEX.md regenerated
via `just receipt-index` twice. No git operations.
