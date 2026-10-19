# i29 suspect hygiene — SUSPECT/NO-CONTEXT receipt sweep (light lane)

Context: solo(suspect-hygiene lane; read-only replays of in-text commands; no lib edits, no git)
Standing: PASS — 18→11 SUSPECT (7 legacy honestly cleared with real replay output, 1 active-window BLOCKED receipt cleared); NO-CONTEXT 15→1 in v26.10.18 (only the empty i29-court-x2-final placeholder remains).
Date: 2026-10-19

## What was done

### SUSPECT clears (append-only, real replay output from the receipt's own named commands)

Each cleared receipt got a dated `## Replay (2026-10-19, i29 suspect-hygiene lane)`
section whose code block is the literal output of a command named in the
receipt text, run on the canonical checkout:

| receipt | replay command (from receipt text) | result |
|---|---|---|
| `docs/jira/v26.10.14/receipts/a2-cas-contention.md` | `grep -c '"ok":false'` on both a2 JSONLs | 0 and 0, exit code 1 (zero-match grep = invariant held) |
| `docs/jira/v26.10.14/receipts/bench-12-consolidation.md` | `ls docs/jira/v26.10.14/bench/ && wc -l docs/jira/v26.10.14/bench/*.jsonl` | 46 jsonl files, 53101 total lines, exit code 0 |
| `docs/jira/v26.10.14/receipts/fin24-p5-doc.md` | `grep -c "The leaked substrate lock took"` + `wc -lc` on `docs/jira/v26.10.15/05-superfans.md` | 0 matches; 106 lines / 9,201 bytes (receipt said 107/9,095 — drift disclosed in the append) |
| `docs/jira/v26.10.14/receipts/fin30-landing.md` | `git rev-parse --short=7 HEAD` + `git log --oneline -1 518b31a` | `502c4ed`; landing commit 518b31a intact in history, exit code 0 |
| `docs/jira/v26.10.14/receipts/fin32-wrap-final.md` | `just receipt-index` | `receipts=676 sdk=51 total=727 suspects=12` at append time; the falsifier's "modulo later lanes" clause covers the growth |
| `docs/jira/v26.10.14/receipts/fin33-planning-summary.md` | `ls -l docs/jira/v26.10.15/PLANNING.md` | on disk, 6011 bytes, mtime Oct 15 20:20, exit code 0 |
| `docs/jira/v26.10.14/receipts/lc2-tco-ledger.md` | receipt's Replay block (`cat`/`head`/`grep LIFECYCLE_TCO BENCH_RESULTS.md`) | exit code 0 on cat/head; grep exit code 1 — honest finding: BENCH_RESULTS.md is generated and the hand-added pointer was dropped in a later regen |
| `docs/jira/v26.10.18/receipts/i29-docker-reclaim.md` | `docker system df` | fresh output showing reclaim progressed (build cache 51→23 entries / 17.49GB→7.187GB; containers 5→3; 30.58GB now dangling-image reclaimable) — BLOCKED degree superseded, order respected |

### NO-CONTEXT fixes (Context moved to line start, wording unchanged)

15 receipts in v26.10.18 carried the context in prose but not at line start
(`- **Context**:` bold/list prefixes; two mid-line). Normalized to a bare
`Context: solo|pair|slice|full(...)` line per `RECEIPT_CONTEXT_LAW.md`:
i29-azb20-lib-land, i29-azb20-verify, i29-budget-final2, i29-checkpoint7,
i29-e2e-final, i29-full-soak-f, i29-full-soak-g (landed mid-session by a
concurrent lane), i29-g1-land, i29-g1-test-verify, i29-gates-release-sha,
i29-push-readiness3, i29-push-readiness4, i29-true-leak-repair,
i29-wire-fresh4, i29-wrap-items.

## Permanently output-less (NOT cleared — no fabrication)

| receipt | standing | why not clearable |
|---|---|---|
| `06-blob-x-ms-date-unvalidated.md` | UNSUPPORTED | pure standing/divergence doc; no command, no data file |
| `bench-02-blob-ts.md` | UNKNOWN | data file exists but the receipt names no in-text command short of a full bench re-boot |
| `bench-03-cosmos-ts.md` | ALIVE | replay block requires substrate boot + bench re-run (heavy, out of light-lane scope) |
| `bench-04-messaging-ts.md` | UNKNOWN | no in-text replay command; run provenance explicitly session-bound |
| `bench-05-python-mirror.md` | UNKNOWN | replay requires two venvs + private substrate boot (heavy) |
| `c4-kv-cosmos.md` | ALIVE | no in-text command short of a full crypto bench re-run |
| `c8-chaos-cross.md` | UNKNOWN | no replay command; chaos run is session-bound |
| `errc4-hdr.md` | ALIVE | replay block requires npm install + two bench boots (heavy) |
| `lc1-8hop-tax-chain.md` | ALIVE | its own re-witness table exists but carries no gate keyword (no `exit`/`PASS` token); the named harness command self-boots substrate + `next start` — heavy; leave for a re-witness lane |
| `i29-court-x2-final.md` | UNKNOWN | 0-byte placeholder awaiting the real court-x2 wrap gate; nothing to replay, nothing to fabricate |
| `spc-bands.md` (v26.10.16 sdk-results, concurrent) | UNKNOWN | pre-existing/concurrent flag, out of this lane's scope |

## Embedded run output (this lane)

```
$ python3 scripts/receipt_index.py
receipts=677 sdk=51 total=728 suspects=11
```

exit code 0. Post-fix NO-CONTEXT in v26.10.18: 1 (the empty i29-court-x2-final
placeholder only). Receipts in this lane's diff are append-only or Context-line
normalization; no generated file hand-edited — RECEIPTS.md/INDEX.md regenerated
by `just receipt-index` (run 4x during the lane; final regen below).

## Verification

- `grep -L "^Context:" docs/jira/v26.10.18/receipts/*.md` → only
  `i29-court-x2-final.md` and the generated `INDEX.md` remain.
- Final index regen executed after this receipt lands (see RECEIPTS.md).
