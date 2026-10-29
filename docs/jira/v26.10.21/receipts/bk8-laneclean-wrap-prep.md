# BK8 — Lane-Clean + _LANES.md Reconciliation + Wrap-Prep

Repo: `/Users/sac/smalt` · Branch: `main` · Milestone v26.10.21 · Date: 2026-10-21 · Context: solo

**Standing:** **PASS** — lane-clean executed under the strict task gate (no
active owner + mtime >2h + not live-referenced), `_LANES.md` reconciled to
v7, wrap gates run with real exit codes. Not committed (per task order).

## Disk reclaimed (real du numbers)

- `_build-gld6` — 712M, mtime 17:02 (2h stale), no live owner — DELETED
- `_build-sj4` — 712M, mtime 17:02 (2h stale), no live owner — DELETED
- **Total reclaimed: 1.42 GiB** (verified post-delete: both paths gone).

Held, not deleted:
- 9+ LIVE lanes with running beams at census (19:06 PDT): ja5, ja7, ja9,
  ja10 (running `ja10_census2.exs` despite the dry-run guard not seeing
  it), ja13, ja15, apex3, wasm1 (stub-runner `--hang` holders), lane-r2.
- 2h-fresh leases (<17:04 cutoff): gld3, gld7, rel3, sj2, sleepc, sqld4.
- `popcorn_demo/_build-*` (~55 MB total): `just popcorn-lane-clean`
  reports "(no lane build roots present)" — its cleaner only targets
  `_build-lane*/errc/court/integ` patterns; the `_build-apex*`-style
  historical roots are invisible to it. Left in place; morning apex
  beams may own them. ~55 MB deferred to a future popcorn-specific sweep.

Full dry-run census (`just lane-clean-dry`): 11 roots / 6.07 GiB
flagged deletable by the live-guard alone — the strict task gate
deliberately reclaimed less.

## Lane census + reconciliation

- 20 root-level `_build-*` lane roots on disk at census; receipts
  106 → 129 on disk since the v6 reconciliation; 39 post-v6 receipts
  were unaccounted in `_LANES.md`.
- `_LANES.md` appended **final reconciliation (v7)**: JA wave (JA-1..15
  rows; JA-4 SUSPECT/UNKNOWN per receipt_index; JA-13/15 in-flight
  UNWITNESSED), post-v6 closers (GLD-1/3/5fix/6/7, SQLD-4, RELCUT,
  US500, CAS412/r, PB-1/2/5/6, SJ-1..4, SK5, GWS-18, IMPL-14f, IMPL-26,
  GOLEG, AMQP10 router+redispatch, SNIPPET/CTXFILL/WRAP1, FONDRUNNER),
  one-writer conflict notes (lane-clean live-guard gap vs env-less
  scratch lanes), and wrap-gate status. Stale v6 Receipts block removed.
- Guard gap (file `justfile.d/06-lane-cleanup.just`): the live-ref
  harvest (lsof +D, cwd, `ps eww` MIX_BUILD_ROOT) misses env-less
  scratch-script lanes — `_build-ja10` would have been deleted under a
  running `ja10_census2.exs` beam. Deletion held by the task gate; a
  tree-aware orphan check (LISTEN-socket law, w876 #4) is the fix shape.

## Wrap-gate results (exit codes)

| Gate | Exit | Result |
|---|---|---|
| `just receipt-index` | 0 | RECEIPTS.md + INDEX.md regenerated v26.10.14..v26.10.21; flags `SUSPECT: ja4-isolation-audit.md (standing UNKNOWN)` — re-witness precondition, no doc fix needed |
| `just docs-dod-check` | 0 | all OK, zero broken doc paths — no <5-file fixes required |
| `just witness_all` | n/a | **no such recipe exists** (checked `just -l`, justfile.d); only `just rewitness KD` and `just kd-stale` |
| `just kd-stale` (proxy) | 0 | `FLIP-PENDING-WITNESS: 1` — one KD row pending witness flip |

## Falsifiers

- Re-run `just lane-clean-dry`: gld6/sj4 absent; live lanes still SKIP.
- `grep -c '^| Lane' docs/jira/v26.10.21/_LANES.md` reflects the v7
  tables; `## Receipts` appears exactly once.
- `just receipt-index` remains exit 0 after this receipt lands.

## Standing boundary

PASS covers the clean + reconciliation + gate runs at 2026-10-21 ~19:15
PDT on branch main (working tree, uncommitted). Live-lane ownership is
as-of-census; lanes landing after 19:06 own their own roots. The 1
FLIP-PENDING-WITNESS row and the JA-4 SUSPECT flag are open items for
the wrap lane, not closed by this receipt.
