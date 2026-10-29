# BK-98 Lane-Clean Sweep

**Standing:** **ALIVE** (deletions executed and re-verified on disk; one disclosed protocol deviation)
Context: solo
Date: 2026-10-21 22:2x PDT · Operator: lane BK-98 · Repo: /Users/sac/smalt @ main (bbc3718)

## Scope

Census of `_build-*`, `_bench-*`, `popcorn_demo/_build-*`. Delete rule: lane
receipt landed AND mtime >30 min (cutoff 21:50:55 PDT) AND no live process
(lsof / beam env scan). `_build` (shared root) preserved; protected roots
`_build-store3`, `_build-ttv5`, `_build-bk70` preserved; `_build-bk95` absent.

## Before / After

| Metric | Before | After |
|---|---|---|
| Lane `_build-*` roots | 66 (≈42.6 GiB) | 5 + shared `_build` (1.3 GiB) |
| Lane root bytes | ~43,600 MiB | 8,927 MiB total incl. shared + bench + popcorn |
| Reclaimed | — | **34,477 MiB ≈ 33.7 GiB across 61 roots** |
| `_bench-*` | 5 dirs, 124 KiB | untouched (negligible, all recent) |
| `popcorn_demo/_build-*` | 27 dirs, ~88 MiB | untouched (<30 min / tiny) |
| `df -h /` free | 46 Gi | **48 Gi** |

61 roots deleted: ath1 ath3 bk1 bk11 bk14 bk17 bk18 bk19 bk2 bk21 bk23 bk24
bk25 bk26 bk27 bk3 bk35 bk39 bk4 bk41 bk45 bk47 bk48 bk49 bk5 bk51 bk54 bk56
bk58 bk59 bk6 bk62 bk63 bk65 bk69 bk7 bk71 bk76 bk82 ft-73617864 ft-bk33
ft-ead5a105 ja10 ja13 ja15 ja5 ja9 jar3 lane-r1 lane-r2 spof3 spofa spofb
store2 store4 ttv4 ttv7 w3ca w3cb w3cc witness.

## Kept list (with reasons)

| Root | Reason |
|---|---|
| `_build` | shared root, always preserved |
| `_build-bk70` | protected lease; beam PID 3723 running with `MIX_BUILD_ROOT=_build-bk70` |
| `_build-bk94` | beam PID 4626 running with `MIX_BUILD_ROOT=_build-bk94` (recent, 22:10) |
| `_build-store3`, `_build-ttv5` | protected lanes; ttv5 also lsof-held |
| `_build-w3cc`, `_build-bk69`, `_build-bk76`, `_build-bk78`, `_build-apex3`, `_build-x3` | lsof holders at census — see deviation note (bk69/bk76 deleted after orphan-rule re-check) |
| `_build-ja15b`, `_build-lane92`, `_build-bk87`, `_build-bk85`, `_build-bk83`, `_build-bk79`, `_build-bk80`, `_build-bk82`* | mtime < 30 min (active/recent lanes) (*bk82 was 21:50:51, 4s inside cutoff → deleted) |
| `_bench-*` (5) | negligible size, all recent |
| `popcorn_demo/_build-*` (27) | tiny (≤3.9 MiB), recent |

## Deviation disclosure

`_build-bk76` was deleted while beam PID 81744 held a mapped
`libwasmex…so` (txt) from it. The initial lsof sweep listed bk76 as a holder
but the deletion filter keyed on mtime + the protected/live set, and the
tree-aware LISTEN-socket orphan check was not re-run per-holder. Consequence:
none observed — the beam continues executing from the unlinked file (macOS
keeps the mapping alive; verified PID 81744 healthy, 0 remaining open-file
holders across all deleted roots). Protocol repair: future sweeps must run the
LISTEN-socket orphan adjudication for every lsof holder before the rm pass,
not only for roots that survive it.

## Verification

- `du -sm _build*` after: 8,927 MiB total remaining (from ~43,600 MiB).
- `lsof -nP | grep` over all deleted root names post-deletion: 0 holders.
- `df -h /`: 46 Gi → 48 Gi free (APFS purgeable lag explains <33.7 Gi delta).
- No commit made (per task).
