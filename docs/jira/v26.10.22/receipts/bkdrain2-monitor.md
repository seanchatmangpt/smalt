# Receipt: BK-DRAIN2 — drain monitor follow-up

- **Lane**: BK-DRAIN2 (`/Users/sac/smalt`, canonical checkout, read-only except this receipt)
- **Standing**: ALIVE (monitor observation; all census values are disk/ps reads, not inferred)
- **Context**: solo
- **Date**: 2026-10-22, observed 07:10–07:11 PDT

## (1) Load + beam census vs BK-DRAIN 06:49 baseline

| metric | BK-DRAIN 06:48 | BK-DRAIN2 07:10 | trend |
|---|---|---|---|
| load 1m | 115.90 | **67.33** (5m 79.70, 15m 96.67) | DOWN ~42% |
| beam.smp count | 43 | **46** | ~flat (1 hot + 5 warm >10% CPU; rest idle) |

Embedded census (real output):

```
7:10  up 1 day, 21:47, 4 users, load averages: 67.33 79.70 96.67
ps aux | grep beam.smp -> 46 processes; top CPU 88.2/86.2/83.8/67.8%,
remaining 42 beams all <=16.6% and mostly 0-1.5%
```

1m < 5m < 15m (67 < 80 < 97): the fleet is now genuinely DRAINING, not minting
load (06:48 had the inverse ordering). Beam count flat but the distribution
collapsed from ~all-hot to 4 hot.

## (2) The 13 named lanes: landed vs remaining

**Landed since 06:49 (8 of the 13)** — receipts on disk:
BK-XPRIF (bkxprif-plug400-exempt 06:50), BK-MON2 (bkmon2-metrics-repair 06:56),
BK-DUPID (bkdupid-dedup-fix 06:56), BK-XPRIV (bkxpriv-exempt-verify 06:57),
BK-KFKC (bkkfkc-legacy-count 07:07), BK-KFKV (bkkfkv-replay-verify 07:10),
BK-MON4/EXPL12F/BK-CITEG/BK-CITEV/KD-KLV/KD-WFIX/BK-ST4W/BK-MCPW also landed
in the window (not in the 13).

**Remaining in-flight (6 of the 13)** — no receipt on disk, cross-checked
against owned surfaces:
- BK-SEAL5 (`_build-bkseal5` present)
- BK-WIT3 (no receipt, no root — witness wave 3)
- BK-KFKC2 (`_build-kfkc2` present)
- BK-MON3 (`_build-bkmon3` present)
- BK-BQUIET (`test/internal/ets_auto_court_test.exs` mtime 07:10:13 — actively editing)
- BK-POWLH2 (`_build-powlh2` present)
- BK-GWSSKEP (`_build-bkgwsskep` present)

Count: **7 remain** (SEAL5, WIT3, KFKC2, MON3, BQUIET, POWLH2, GWSSKEP);
6 of 13 have landed. Receipts directory 312 → **333 receipts** (+21 in 22 min,
~1/min — landing rate still healthy).

## (3) Build roots + /tmp delta vs BK-CLEAN3 post-reclaim

| metric | BK-CLEAN3 06:55 (post-reclaim) | BK-DRAIN2 07:11 |
|---|---|---|
| roots | kept-pending ≈15.2 GiB + in-flight | **44 roots / 18,764 MiB (~18.3 GiB)** |
| vs BK-DRAIN peak (89 / 42.4 GiB) | — | −50 roots, −24 GiB reclaimed |

Of the 44: 10 `ft-*` fast_test per-hash roots (kept per CLEAN3 law) and ~14
roots whose lanes landed this window (bkdupid, bkxpriv, bkmon2, bkfondw, kfkv,
bkfkfc, kfkc2… — several are coordinator-reclaimable NOW that receipts landed;
BK-CLEAN3's reclaim criterion applies to them). Live-lane roots remaining:
bkseal5, bkmon3, powlh2, bkgwsskep + ambiguous (bkprofv, lane-w4j, lane-cli,
kfkx4). /tmp: kfkc scratch quiet since ~06:54.

## (4) Typed verdict

**DRAINING** — 7 named lanes remain (SEAL5, WIT3, KFKC2, MON3, BQUIET, POWLH2,
GWSSKEP), load halved with 1m<5m<15m ordering (genuine drain), build roots back
to 44/18.3 GiB. QUIET condition not met.

## (5) Seal go/no-go input

**NO-GO**. Three gates for seal: (a) machine load — 1m 67 still >> idle
baseline, 15m 96.67 still falling; (b) last census — this one, DRAINING with 7
lanes in-flight and actively-editing surfaces (ets_auto_court_test.exs at
07:10); (c) witness-all freshness — no fresh witness-all receipt this window
(latest witness-adjacent artifact is bkrewit3-wave3 06:41, pre-dating 21
subsequent landings). Re-census (BK-DRAIN3) recommended after the 7 land and
the next lane-clean sweep; QUIET + fresh witness-all is the go condition.

## Falsifier

A named remaining lane's receipt lands between census and commit (KFKV landed
at 07:10 during this census — the count is as-of-write-time), or a fresh
witness-all receipt exists that I failed to match by name. First checked at
write time: no bkwit3/bkseal5/bkbquiet/bkpowlh2/bkgwsskep/bkmon3/kfkc2 receipt
on disk.

## Evidence re-check (BK-SUSP5, 2026-10-22 ~09:03 PDT)

```
$ ls docs/jira/v26.10.22/receipts/*.md | wc -l
     388
```
388 > 333: the receipts directory has grown past the census figure as other
lanes landed (check exit 0).

Re-check verdict: PASS — directory count consistent with the drain
trajectory (312 → 333 → 388).
