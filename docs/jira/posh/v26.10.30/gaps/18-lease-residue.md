# Gap 18 — Lease-Residue Census (read-only, 2026-10-30)

Status: **ALIVE** — census executed this session; commands: `du -sh`, `lsof +D <root>`, `ps eww $(pgrep -f beam)`. No deletions performed.

## Method

- Existence: `ls -d`; size: `du -sh`; liveness: `lsof +D` (0 open fds = no live holder) + `ps eww` env scan for `MIX_BUILD_ROOT`.
- One live beam.smp (pid 98191) has files under `/Users/sac/smalt/_build` (canonical root) — standing substrate, not residue.

## Census table

| Path | Exists | Size | Live-referenced | Owner | Deletion timing |
|---|---|---:|---|---|---|
| `/Users/sac/smalt/_build` | yes | 754M | YES (beam pid 98191) | substrate | KEEP — live |
| `_build-c4` | yes | 754M | no (0 fds) | coordinator | at integration commit pass |
| `_build-f4` | yes | 373M | no | coordinator | at integration |
| `_build-f5` | yes | 754M | no | coordinator | at integration |
| `_build-f9` | yes | 754M | no | coordinator | at integration |
| `_build-f12` | yes | 381M | no | coordinator | at integration |
| `_build-acrfix` | no | — | — | — | already deleted; no action |
| `_build-poshl4` | no | — | — | — | already deleted; no action |
| `_build-lane*`, `_build-coord` | no | — | — | — | never created this wave |
| `/tmp/f2-provider` | yes | 413M | no | lane f2 (safety-net: coordinator) | lane now, or coordinator at integration |
| `/tmp/f3-provider` | yes | 170M | no | lane f3 | lane now, or coordinator at integration |
| `/tmp/f3` | yes | 728M | no | lane f3 | lane now, or coordinator at integration |
| `/tmp/f16_*` | yes (2 files) | 0B | no | lane f16 | lane now (zero-byte) |
| `/tmp/posh*` (~30 files) | yes | ~49M total | no | coordinator (posh spike) | coordinator at integration |
| `tmp/posh/` court logs, router snapshot/baseline, tfrc, ops/ | yes | (75M dir incl. archive) | no | coordinator | coordinator at integration |
| `tmp/posh/archive/` (74M tarball + 20K provider dir) | yes | 74M | no | coordinator | **KEEP** — archived elixir spike, referenced by migration ledger |
| `posh/bin/` | yes | 9.6M | no | coordinator | at integration, but only after confirming `tmp/posh/ops/terraform-provider-smalt` and archive copies cover any references |

## Verified totals

- Deletable lane build roots: `_build-{c4,f4,f5,f9,f12}` = 754+373+754+754+381 = **3016M ≈ 3.0G**.
- Deletable /tmp residue: `/tmp/f2-provider` + `/tmp/f3` + `/tmp/f3-provider` = 413+728+170 = **1311M ≈ 1.3G**; `/tmp/posh*` ≈ 49M; `/tmp/f16_*` 0B. Total /tmp ≈ **1.36G**.
- Grand total deletable ≈ **4.4G**. KEEP: `_build` (754M, live), `tmp/posh/archive` (74M, ledger-referenced).

## Deletion order (coordinator, final commit pass)

1. `/tmp/f3`, `/tmp/f3-provider`, `/tmp/f2-provider` (~1.3G, zero fds, largest first).
2. `_build-c4`, `_build-f5`, `_build-f9`, `_build-f4`, `_build-f12` (~3.0G, all 0 fds).
3. `/tmp/posh*` set (~49M).
4. `tmp/posh/` court logs + `tfrc` (small; retain `router.snapshot.ex` only if migration ledger references it).
5. `posh/bin/` (9.6M) — last, after ledger-reference check.
6. Never delete: `_build` (live beam), `tmp/posh/archive/` (KEEP).

## Notes

- `.gitignore` already covers all `_build*` forms (lines 2-4, 131-137 incl. `**/_build-*/`), so no repo hygiene gap — all residue is disk-only, not git-tracked.
- `wave2-membrane-receipt.json` lives in-tree at `docs/jira/posh/v26.10.30/receipts/wave2-membrane-receipt.json` — tracked content, not tmp residue; no action.
