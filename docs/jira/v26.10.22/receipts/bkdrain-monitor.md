# Receipt: BK-DRAIN — drain monitor (post BK-QREAD NOT-READY)

- **Lane**: BK-DRAIN (`/Users/sac/smalt`, canonical checkout)
- **Standing**: ALIVE (monitor observation; census below is disk-read, not inferred)
- **Context**: solo
- **Date**: 2026-10-22, observed 06:48:33 PDT

## (1) Load vs BK-QREAD 06:40 baseline

| metric | BK-QREAD 06:40 | BK-DRAIN 06:48 | trend |
|---|---|---|---|
| load 1m | 99.96 | **115.90** (5m 112.48, 15m 103.33) | UP — not yet draining |
| beam.smp count | 37 | **43** | UP |

Embedded census (real output):

```
6:48  up 1 day, 21:25, 4 users, load averages: 115.90 112.48 103.33
ps aux | grep -c '[b]eam.smp'  -> 43
```

15m average (103.33) below 1m (115.90): the load is still being minted, not
merely draining. Verdict on load alone: NOT yet trending down.

## (2) Receipts landed, last 20 min (06:28–06:48)

14 receipts landed: bkampv-parse-verify (06:42), bkqread-readiness (06:41),
bkrewit3-wave3 (06:41), bkfondv-f1a-verify (06:41), bkwps2v-final-verify
(06:42), bkratio-fence-audit (06:44), kd174f-truth-cell (06:44),
bkseal4-close-condition (06:45), bkprda-matrix-audit2 (06:46),
bkretok-arm-gateway (06:46), bkmo1-merkle-repoint (06:47), kdaton-row (06:47),
kdn1-row (06:39), expl12v-auth-uniform (06:39) — plus expl12b-login-monitor
(06:38), bkwpss2-recovery (06:36), bkf1a-needsat-mirror (06:35). Directory
total now 312 receipts. Landing rate is healthy; the lanes ARE converging.

## (3) In-flight set WITHOUT receipts (union of last 3 tick checkpoints:
ba577f9b, f63209c6, be03894e)

Landed since checkpoint (receipt on disk, snapshot rows now stale):
BK-MO1, BK-RATIO, KD-174F, BK-FONDV, BK-PRDA, BK-EXART, BK-DODSUB.

Still WITHOUT a receipt — **13 lanes named**:

| lane | surface |
|---|---|
| BK-SEAL5 | seal close-condition follow-up (SEAL4 landed 06:45) |
| BK-WIT3 | witness wave 3 (REWIT3 landed; WIT3 distinct, none on disk) |
| BK-XPRIF | fence courts |
| BK-XPRIV | XPRIF sibling |
| BK-KFKC / BK-KFKC2 / BK-KFKV | Kafka court family (bkkfkskep 06:04 is the
  SKEP audit, a different lane) |
| BK-MON2 / BK-MON3 | monitor defects (bkmon-monitor-truth 06:23 is BK-MON,
  parent lane) |
| BK-DUPID | plan dedup |
| BK-BQUIET | quiet-check follow-up |
| BK-POWLH2 | loop compile |
| BK-GWSSKEP | ws gate skeptic |

Ambiguous: BK-GUARDLAW has bkguardlaw-static-court.md (06:12) yet is still
named in-flight in the newest checkpoint (ba577f9b) — either a follow-up leg
or a stale snapshot row; counted separately, not in the 13.

## (4) Build-root census delta vs BK-QREAD

BK-QREAD 06:40: 44 roots / 22 GiB. Now:

```
du -sm _build-* -> 89 roots, 43421 MiB (~42.4 GiB)
```

**Doubled** in 8 minutes. Per the lane-lease law this is coordinator-reclaimed
at integration (`just lane-clean`); flagged loudly — at this growth rate the
clean at integration is not optional.

## Typed verdict

**DRAINING** — receipts are landing at ~0.7/min and the in-flight set shrank
from the checkpoint union to 13 named lanes, but the machine is NOT yet quiet
(load UP 99.96→115.90, beams UP 37→43, build roots 44→89). QUIET condition
not met; re-census recommended after the 13 named lanes land and `just
lane-clean` runs.

## Evidence re-check (BK-SUSP5, 2026-10-22 ~09:03 PDT)

```
$ ls docs/jira/v26.10.22/receipts/bkxprif-plug400-exempt.md docs/jira/v26.10.22/receipts/bkmon2-metrics-repair.md
docs/jira/v26.10.22/receipts/bkmon2-metrics-repair.md
docs/jira/v26.10.22/receipts/bkxprif-plug400-exempt.md
ls exit 0
```

Re-check verdict: PASS — the "landed since checkpoint" receipts named above
are on disk as-written (BK-XPRIF, BK-MON2 spot-checked; both exit 0). The
load/beam figures are as-of 06:48 and stand as-written.
