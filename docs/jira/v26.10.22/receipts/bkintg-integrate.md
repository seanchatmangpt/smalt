# BK-INTG — seal-residue integration receipt

- **Standing**: PASS
- **Context**: solo
- **Date**: 2026-10-22
- **Lane**: BK-INTG (coordinator integration delegate, BK-LANES2/BK-SEAL5 flagged seal work)

## Census (git status at lane start)

| Group | Status |
|---|---|
| BK-SEAL5 census registration edit (`store4_no_boot_test.exs` @registered row) | ALREADY COMMITTED — `test/internal/internal_tier_census_test.exs:94` present in HEAD, file clean in status |
| BK-CENS6 bkmon3r census row | ALREADY COMMITTED — `test/internal/internal_tier_census_test.exs:104` (`bkmon3r_deadjoin_court_test.exs => :wire`) in HEAD |
| BK-TRIO regenerated RECEIPTS.md / INDEX.md (4 files) | UNCOMMITTED — committed this lane (see below) |
| Untracked receipts/court files (git-clean-delete hazard) | NONE FOUND — `git status --porcelain` showed only the 5 modified files; hazard closure: nothing pending |

## Per-group commits

### Group (b) — regenerated receipt indexes

- Command: `python3 scripts/receipt_index.py` → exit 0 (`receipts=1554 sdk=61 total=1615 suspects=9`), regenerated all 16 RECEIPTS.md/INDEX.md pairs; idempotence verified: re-run left the modified-file set unchanged (same 4 files).
- Committed explicit paths only: `docs/jira/v26.10.14/RECEIPTS.md`, `docs/jira/v26.10.14/receipts/INDEX.md`, `docs/jira/v26.10.22/RECEIPTS.md`, `docs/jira/v26.10.22/receipts/INDEX.md`.
- **Commit**: `de1aec1a` (main).
- v26.10.22 index: 366 → 385 receipt files.

### Group (a) / (c)

No commits needed — both groups already landed or absent (see census).

## Disclosure: index sweep in commit de1aec1a

The shared git index held a pre-staged rename from another lane:
`test/integration/sqld2_sql_ingest_court.exs` → `test/integration/sqld2_sql_ingest_court_test.exs`
(100% rename, zero content change). `git add <paths> && git commit -F` committed the whole
index, so the rename rode along in de1aec1a despite a 4-path commit message. Commits are
immutable (no reset); content is benign (rename-only), but attribution: the rename is NOT
BK-INTG work — it belongs to whichever lane staged it (sqld2). No follow-up action taken;
disclosed here per the same-checkout disclosure law.

## Post-integrate status

Remaining modified (other lanes' genuinely in-flight, untouched by BK-INTG):

- `test/integration/namespace_put_test.exs` (+1: `:code.ensure_loaded(Smalt.EgressRouter.Peers)` before delete/purge)
- `test/internal/ets_auto_court_test.exs` (+26/-3)

`receipt_index.py` exit 0. HEAD advanced past de1aec1a by coordinator commit `c37814b1`
(BK-KD181V) during this lane — no conflict.
