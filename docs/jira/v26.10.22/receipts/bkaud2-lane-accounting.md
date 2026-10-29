# BK-AUD2 — full lane accounting for the seal's quiet-tree gate

**Standing: ALIVE** — every verdict below re-verified on disk at 2026-10-22
05:30 PDT: receipts dir listing, owned-file mtimes, `git status` /
`git diff --stat`, `_build-*` root mtimes, and the 16 tick-checkpoint commits
from `git log --oneline -80`. Nothing recalled from session memory.
`Context: solo`

## Counts

Latest checkpoint (c5fbce28, 05:27) named 18 in-flight lanes. Verdicts at
05:30: **2 LANDED** (BK-TYPORT, BK-REWIT2), **14 IN-FLIGHT** (6 with dirty
owned files ≤3 min old — genuinely active, 8 weak on build-root signal only),
**2 DEAD-CANDIDATE** (BK-WIT, BK-WIT2 — typed for reap). All ~53 lanes named
in-flight by EARLIER checkpoints are LANDED — each has a committed receipt
under `receipts/` (names in the `_LANES.md` BK-AUD2 section).

## Per-lane table (latest checkpoint snapshot, c5fbce28)

| Lane | Verdict at 05:30 | Evidence |
|---|---|---|
| BK-TYPORT | LANDED | `receipts/bktyport-lane-ports.md` ("Standing: ALIVE"), commit 2dd5c028 (HEAD) |
| BK-REWIT2 | LANDED | `receipts/bkrewit2-wave2.md` ("Standing: ALIVE — 38 → 28 suspects"), committed |
| KD-173C | IN-FLIGHT | `workspace/scripts/lib/kd173c-harness.mjs` dirty, mtime 05:29 |
| KD-174D2 | IN-FLIGHT | `docs/jira/v26.10.14/KNOWN_DIVERGENCES.md` dirty, mtime 05:29; `_build-kd174d2` 05:22 |
| EXPL10-R | IN-FLIGHT (weak) | `_build-expl10r` mtime 05:24; no receipt, no dirty owned file |
| EXPL10-R2 | IN-FLIGHT | `test/internal/expl10r2_court_test.exs` dirty, mtime 05:29 |
| EXPL11-R | IN-FLIGHT (weak) | `_build-expl11r` mtime 05:27; no receipt, no dirty owned file |
| EXPL11-R1 | IN-FLIGHT (receipt pending) | `test/internal/expl11r1_ledger_range_court_test.exs` tracked+committed 05:26; no receipt yet |
| EXPL11-R2 | IN-FLIGHT | `test/internal/expl11r2_wps_service_events_court_test.exs` untracked, mtime 05:29; census file registers it as mid-edit |
| BK-GREEN | IN-FLIGHT (weak) | `_build-bkgreen` mtime 05:15; no receipt, no dirty owned file |
| BK-FIN | IN-FLIGHT | `docs/jira/v26.10.22/FINAL-RELEASE-26.10.22.md` dirty, mtime 05:29 |
| BK-MAAP6 | IN-FLIGHT (weak) | `_build-maap6` mtime 05:27; no receipt, no dirty owned file |
| BK-MCPSHA | IN-FLIGHT (weak) | `_build-bkmcpsha` mtime 05:27; no receipt, no dirty owned file |
| BK-AMPSKEP | IN-FLIGHT | `_build-bkampskep` mtime 05:23; no receipt yet |
| BK-KFKSKEP | IN-FLIGHT | `_build-kfkskep` mtime 05:21 (+`_build-kfkx4`); no receipt yet |
| BK-WPSSKEP | IN-FLIGHT | `_build-bkpsskep` mtime 05:17; no receipt yet |
| BK-CENS2 | IN-FLIGHT (active) | `test/internal/internal_tier_census_test.exs` dirty, mtime 05:30 |
| BK-WIT / BK-WIT2 | DEAD-CANDIDATE (reap owed) | no receipt (zero bkwit* in the 221 receipts), only `_build-witness` mtime 03:56 (>90 min stale); superseded by BK-REWIT wave 1 (`receipts/bkrewit-wave1.md`) + wave 2 (`receipts/bkrewit2-wave2.md`), both ALIVE |

## Side-audits

- **Untracked receipts: ZERO.** All 221 files in
  `docs/jira/v26.10.22/receipts/` are committed; `git status` shows no
  untracked or modified receipt file. Git-clean-delete hazard clear at 05:30.
- **`_build-*` orphan census (report-only, nothing deleted):** 44 roots,
  22 GiB total (`du -sch` ground output: `22G total`). 40 are this session's
  live lane leases (mtimes 03:56–05:29, each maps to a lane above); 4
  pre-date the current wave and are coordinator reap candidates:
  `_build-az2`, `_build-bk70rr` (v26.10.21 straggler, per BK-WRAP2 receipt),
  `_build-bk7c`, `_build-bk83`.
- **Working tree (05:30):** dirty = KD register (KD-174D2), FINAL-RELEASE
  (BK-FIN), kd173c-harness (KD-173C), expl10r2 court (EXPL10-R2),
  internal_tier_census (BK-CENS2), untracked expl11r2 court, plus a stray
  `.ggen_igniter/.sync.lock` (untracked lockfile — flag to substrate lanes;
  not deleted). Every dirty file maps to a typed in-flight lane above — no
  anonymous dirt.

## Reconciliation action

`_LANES.md` updated: BK-WIT/BK-WIT2 row added to the BK-LANEAUD section as
DEAD-CANDIDATE; new "BK-AUD2 (05:30) full accounting" section appended with
the table above. One earlier corruption note: this receipt's first draft
self-corrupted mid-write and was rewritten whole before commit; the
`_LANES.md` section is the authoritative table.
## Evidence re-check (BK-SUSP5, 2026-10-22 ~09:03 PDT)

```
$ ls docs/jira/v26.10.22/receipts/bktyport-lane-ports.md docs/jira/v26.10.22/receipts/bkrewit2-wave2.md docs/jira/v26.10.22/_LANES.md
docs/jira/v26.10.22/_LANES.md
docs/jira/v26.10.22/receipts/bkrewit2-wave2.md
docs/jira/v26.10.22/receipts/bktyport-lane-ports.md
$ grep -c "BK-AUD2" docs/jira/v26.10.22/_LANES.md
5
ls exit 0; grep exit 0
```

Re-check verdict: PASS — the table's anchor receipts and the `_LANES.md`
BK-AUD2 section are on disk as-written (re-checks exit 0). Original census
figures above are as-of 05:30 and stand as-written.
