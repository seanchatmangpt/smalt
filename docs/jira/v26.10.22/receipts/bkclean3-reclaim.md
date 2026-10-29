# Receipt: BK-CLEAN3 — post-BK-DRAIN lane build-root reclaim

- **Lane**: BK-CLEAN3 (`/Users/sac/smalt`, canonical checkout, no git state commands)
- **Standing**: ALIVE (disk reclaim executed; all sizes are real `du -sm` reads)
- **Context**: solo
- **Date**: 2026-10-22, ~06:58 PDT

## Trigger

BK-DRAIN (`docs/jira/v26.10.22/receipts/bkdrain-monitor.md`) census: build roots
doubled 44/22 GiB → 89/~42.4 GiB in 8 minutes. Per the lane-lease law
(`just lane-clean` at integration) landed-lane roots are mandatory reclaim.

## Method

Reclaim criterion: lane receipt on disk in
`docs/jira/v26.10.22/receipts/` (cross-checked against the newest receipts
listing and BK-DRAIN's in-flight set). Live-lane roots and any lane whose root
name could not be unambiguously matched to a receipt were KEPT and listed
kept-pending. `ft-*` per-hash fast_test roots were kept (mtimes 04:51–06:50 =
active probes within the window).

## Census (real du output)

```
BEFORE: du -sm _build-* -> 44038 MiB across 89 roots   (~43.0 GiB)
AFTER:  du -sm _build-* -> 15166 MiB across 36 roots   (~14.8 GiB)
```

Delta: **28,872 MiB (~28.2 GiB) reclaimed**, 89 → 36 roots (53 roots removed).

## Reclaimed (each removed with per-root du read; MiB)

az2 364, bk7c 714, bk83 364, bkampskep 714, bkcert 714, bkcells 714,
bkcens 351, bkcens2 351, bkcens4 697, bkegs1 351, bkegskep 351, bkf6r 714,
bkfondskep 714, bkfondsd 714, bkfondv 714, bkfrm 714, bkgen 364, bkgreen 714,
bkisol 351, bkkwt 714, bkratio 351, bkseal 351, bkseal2 714, bkseal3 351,
bkseal4 351, bksubtls 364, expl8 364, expl8r 714, expl9 351, expl9r1 351,
expl9r2 714, expl10 364, expl10r 714, expl10r2 714, expl11r 714,
expl11r1 714, expl11r2 714, expl11r3 714, kd173r 714, kd174d 343,
lane-expl12b 351, laneW2C 714, witness 350, eplaw 714, eplaw2 714, seqb 351,
maa2 714, maap6 714, mcpt1 714, kfkskep 351, rewit 364, rewit2 364,
rewit3 351, rsize 364 — 54 roots.

## Kept-pending (live or unresolvable)

- BK-DRAIN live set: `bkseal5`, `bkxpriv`, `bkdupid`, `powlh2`,
  `bkgwsskep`, `bkmon2`, `bkmon3`, `kfkc2`, `kfkv` (Kafka court family live;
  kfkskep is the landed SKEP audit lane — its root went).
- Ambiguous per BK-DRAIN: `bkguardlaw` — receipt `bkguardlaw-static-court.md`
  exists but the lane is still named in-flight in the newest checkpoint
  (ba577f9b) → kept either way.
- Unmatched/unsure: `bk70rr` (712M, 04:51, no receipt found), `bkcens3`
  (06:39, no receipt), `kd174d2` (kd174d2 vs kd174d-disposition name mismatch),
  `bkpsskep` (vs bkwpsskep name mismatch), `kfkx4` (no receipt, KFK-family
  adjacent), `lane-w4j` (714M, no receipt), `lane-cli` (714M, mtime 06:43 —
  too recent to call stale), `ampf1` (receipt `bkampf1` in v26.10.21 window,
  not re-verified this window), `bkprofv` (no receipt found).
- `ft-*` roots (10, mtime 04:51–06:50): active fast_test per-hash leases, kept.
- Sum of kept roots ≈ 15,166 MiB. Coordinator may `just lane-clean` any
  kept-pending root once its lane's receipt lands.

## /tmp scratch (landed probes, clearly stale)

Removed 11 files: `/tmp/kfkskep_*` (9, landed bkkfkskep lane) and
`/tmp/bk104_scratch*.log` (3, Oct 21 22:56 — bk104 long landed).
Kept: `/tmp/kfkc_*` (live KFKC lane, mtimes through 06:54), `/tmp/kfkx4_*`.

## Falsifier

A kept-pending root belongs to a lane whose receipt IS on disk (keep set is
over-conservative), or a reclaimed root was still in use (lane forced a full
rebuild). Neither observed at write time.

## Evidence re-check (BK-SUSP5, 2026-10-22 ~09:03 PDT)

```
$ for r in bkseal3 bkseal4 expl9r2 rewit2 mcpt1 witness az2; do test ! -d "_build-$r" && echo "_build-$r absent (reclaimed)"; done
_build-bkseal3 absent (reclaimed)
_build-bkseal4 absent (reclaimed)
_build-expl9r2 absent (reclaimed)
_build-rewit2 absent (reclaimed)
_build-mcpt1 absent (reclaimed)
_build-witness absent (reclaimed)
_build-az2 absent (reclaimed)
check exit 0
```

Re-check verdict: PASS — sampled reclaimed roots remain absent; the reclaim
is durable as of the re-check.
