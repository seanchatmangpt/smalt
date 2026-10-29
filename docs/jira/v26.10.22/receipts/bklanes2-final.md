# BK-LANES2 — final lane accounting for the seal

**Standing:** ALIVE · **Context:** solo · 2026-10-22 · Lane BK-LANES2

## Scope

Final census-lane reconcile of `docs/jira/v26.10.22/_LANES.md` for the seal's
quiet-tree gate. Enumeration source: the last ~50 coordinator tick checkpoints
(`git log --oneline -60`, window 06:39–07:24) plus the full receipts directory
listing (235 receipt files + INDEX.md, mtimes re-read from disk). Every lane
named in a checkpoint's in-flight snapshot list since BK-AUD2 (05:30) was
re-verified on disk: committed receipt existence, owned-file mtimes, dirty
working-tree entries, `_build-*` root mtimes. Standing is taken from each
receipt's own embedded standing line, re-read from disk — never recalled.

## Per-lane table (post-BK-AUD2 wave, 06:39–07:24)

| Lane | Verdict | Standing (from receipt) | Evidence |
|---|---|---|---|
| BK-RETOK | LANDED | ALIVE | `receipts/bkretok-arm-gateway.md` |
| BK-PRDA | LANDED | PARTIAL_ALIVE | `receipts/bkprda-matrix-audit2.md` |
| BK-SEAL4 | LANDED | PARTIAL_ALIVE (close condition NOT met, typed) | `receipts/bkseal4-close-condition.md` |
| KD-174F | LANDED | OPEN-hold (no flip) | `receipts/kd174f-truth-cell.md` |
| BK-RATIO | LANDED | ALIVE | `receipts/bkratio-fence-audit.md` |
| BK-AMPV | LANDED | ALIVE | `receipts/bkampv-parse-verify.md` |
| BK-WPS2V | LANDED | ALIVE (third pass on merged HEAD) | `receipts/bkwps2v-final-verify.md` |
| BK-FONDV | LANDED | PARTIAL_ALIVE (14/15) | `receipts/bkfondv-f1a-verify.md` |
| BK-QREAD | LANDED | PARTIAL_ALIVE | `receipts/bkqread-readiness.md` |
| BK-REWIT3 | LANDED | ALIVE (16 residual SUSPECT disposed) | `receipts/bkrewit3-wave3.md` |
| EXPL12-V | LANDED | PARTIAL_ALIVE | `receipts/expl12v-auth-uniform.md` |
| KD-N1 | LANDED | ALIVE | `receipts/kdn1-row.md` |
| EXPL12-W | LANDED | ALIVE | `receipts/expl12w-arm-handshake.md` |
| KD-MIR2 | LANDED | PARTIAL_ALIVE | `receipts/kdmir2-mirror-verify.md` |
| BK-CLEAN3 | LANDED | ALIVE | `receipts/bkclean3-reclaim.md` |
| BK-MON2 | LANDED | ALIVE | `receipts/bkmon2-metrics-repair.md` |
| BK-DUPID | LANDED | ALIVE (15/15) | `receipts/bkdupid-dedup-fix.md` |
| BK-ST4W | LANDED | DEAD/UNWIRED disposition, retained | `receipts/bkst4w-store4-disposition.md` |
| KD-WFIX | LANDED | ALIVE | `receipts/kdwfix-projection.md` |
| BK-XPRIF | LANDED | ALIVE | `receipts/bkxprif-plug400-exempt.md` |
| BK-XPRIV | LANDED | ALIVE | `receipts/bkxpriv-exempt-verify.md` |
| BK-DRAIN | LANDED | verdict DRAINING (not QUIET) | `receipts/bkdrain-monitor.md` |
| KD-ATON | LANDED | ALIVE (KD-179 minted) | `receipts/kdaton-row.md` |
| BK-AMPF1 | LANDED | ALIVE | `receipts/bkampf1-loopback-parse.md` |
| BK-WPSS2 | LANDED | ALIVE (recovery) | `receipts/bkwpss2-recovery.md` |
| BK-F1A | LANDED | ALIVE (needsat mirror) | `receipts/bkf1a-needsat-mirror.md` |
| BK-EXART | LANDED | ALIVE | `receipts/bkexart-fence-aware.md` |
| BK-QMON | LANDED | SUSPECT → BENCH-WINDOW-BLOCKED | `receipts/bkqmon-window.md` |
| BK-KDL | LANDED | ALIVE | `receipts/bkkdl-chain-check.md` |
| BK-MON3 | LANDED | PARTIAL_ALIVE (F1 dead-branch typed) | `receipts/bkmon3-final-standing.md` |
| BK-WIT3 | LANDED | PARTIAL_ALIVE (130/337/25, all typed) | `receipts/bkwit3-witness-final.md` |
| BK-KFKC2 | LANDED | ALIVE | `receipts/bkkfkc2-legacy-verify.md` |
| BK-CLIROW | LANDED | ALIVE | `receipts/bkclirow-cells.md` |
| BK-CLIV | LANDED | ALIVE | `receipts/bkcliv-final-verify.md` |
| BK-DRAIN2 | LANDED | ALIVE | `receipts/bkdrain2-monitor.md` |
| BK-SUB3 | LANDED | ALIVE | `receipts/bksub3-recycle.md` |
| BK-JRPC | LANDED | ALIVE (-32600 fix, swept-then-receipted) | `receipts/bkjrpc-codes-audit.md`; `receipts/bkjrpc2-leg.md` (BK-JRPC2 ALIVE) |
| BK-CENS5 | LANDED | ALIVE | `receipts/bkcens5-wave5.md` |
| BK-FONDW | LANDED | ALIVE (F1-A closed) | `receipts/bkfondw-f1a-closure.md` |
| BK-WIREC | LANDED | ALIVE | `receipts/bkwirec-cosmetics.md` |
| KD-SKEP2 | LANDED | ALIVE | `receipts/kdskep2-mint-audit.md` |
| KD-KLV | LANDED | ALIVE (KD-180 minted) | `receipts/kdklv-row.md` |
| BK-CITEG/CITEV | LANDED | ALIVE | `receipts/bkciteg-citation-fence.md`; `receipts/bkcitev-fence-verify.md` |
| BK-MON4 | LANDED | ALIVE | `receipts/bkmon4-final-verify.md` |
| EXPL12-F | LANDED | ALIVE | `receipts/expl12f-auth-final.md` |
| BK-KFKV | LANDED | ALIVE | `receipts/bkkfkv-replay-verify.md` |
| BK-MCPW | LANDED | ALIVE | `receipts/bkmcpw-attr-fix.md` |
| BK-BQUIET | LANDED | PARTIAL_ALIVE (4 PASS load-typed, 1 FAIL typed louder) | `receipts/bkbquiet-quiesced-bench.md` |
| BK-QMON/BK-DUCK | LANDED | ALIVE (orphan drain) | `receipts/bkduck-orphan-drain.md` |
| BK-KLVD | LANDED | ALIVE | `receipts/bklvd-kfkv-residue.md` |
| BK-FIN3 | LANDED | ALIVE | `receipts/bkfin3-refresh.md` |
| BK-MON5 | IN-FLIGHT | — (no receipt; `_build-bkmon5` 07:25, freshest root on disk, unregistered in any checkpoint) | `_build-bkmon5` mtime 07:25 |
| BK-GWSV | IN-FLIGHT | — (no receipt; named in-flight through checkpoint 128aba94; `_build-bkgwsv` 07:25) | `_build-bkgwsv` mtime 07:25 |
| BK-SEAL5 | IN-FLIGHT | — (named in-flight in the 3 latest checkpoints; `_build-bkseal5` 06:57; no receipt) | `_build-bkseal5` mtime 06:57 |
| BK-WIT4 | IN-FLIGHT (weak) | — (named in-flight in 3 latest checkpoints; no receipt, no owned-file trace) | checkpoints 628ad822/cfde55d8/128aba94 name only |
| BK-TRIO | IN-FLIGHT — **UNCOMMITTED-RECEIPT HAZARD typed** | ALIVE-in-receipt (uncommitted) | `docs/jira/v26.10.22/receipts/bktrio-gates.md` is UNTRACKED in `git status` (receipt written 07:23, never committed); owned surface `test/integration/powl2_gates_court.exs` (M). Git-clean-delete hazard: a checkout-level clean would destroy the receipt. Coordinator commit owed. |
| BK-MON3R | IN-FLIGHT | — (untracked court file `test/internal/bkmon3r_deadjoin_court_test.exs`, 07:2x; no receipt, not named in any checkpoint yet) | untracked file on disk |
| kafka wire face | IN-FLIGHT residue | — (`test/internal/kafka_exp4_court_test.exs` M on disk; kafka_exp4/wire courts were green at 07:2x per BK-KLVD; likely an in-flight edit by a live lane) | `git status` M entry |
| BK-WIT / BK-WIT2 | DEAD-CANDIDATE (carried) | — still no receipt, no owned-file trace; `_build-witness` last write 06:54 (touched after BK-AUD2 typed it, owner still absent). Typed for reap; coordinator decision owed. | `_build-witness` mtime 06:54; checkpoints name only |

## Cross-checks (real output, 07:2x)

- **Untracked receipts: ONE — hazard typed.** `git status --porcelain` shows
  `?? docs/jira/v26.10.22/receipts/bktrio-gates.md` (plus `??
  test/internal/bkmon3r_deadjoin_court_test.exs`). Unlike BK-AUD2's zero, the
  git-clean-delete hazard is now LIVE for one receipt. Fix is one coordinator
  commit; typed loudly in _LANES.md.
- **Untracked court files: ONE** —
  `test/internal/bkmon3r_deadjoin_court_test.exs` (BK-MON3R, unregistered).
- **Modified non-receipt files**: `lib/smalt/arm_gateway/router.ex`,
  `lib/smalt/monitor/metrics.ex` (per snapshot at session start; NOTE: at
  reconcile time `git status` shows these NO LONGER dirty — swept to HEAD by
  tick checkpoints), `test/integration/powl2_gates_court.exs` (M, BK-TRIO),
  `test/internal/kafka_exp4_court_test.exs` (M, kafka wire face),
  `RECEIPTS.md`/`receipts/INDEX.md` for v26.10.14 + v26.10.22 and
  `bench/c8-chaos-cross.jsonl` (coordinator-owned regens; BK-FIN3 restored
  them byte-exact once already — current dirt is post-FIN3 regen residue,
  coordinator-owned, not lane debt).
- **Build roots census (post-BK-CLEAN3):** `ls -d _build-* | wc -l` = **53**,
  `du -sch _build-*` = **24G total**. Freshest: `_build-bkgwsv` and
  `_build-bkmon5` (07:25, live); stalest still-present: `_build-witness`
  (06:54, DEAD owner), `_build-ft-*` fast-test roots (05:xx–07:23,
  regenerable per-hash scratch). BK-CLEAN3 already reclaimed the post-BK-DRAIN
  wave; the 53/24G includes this session's new lane roots — coordinator
  reclaim at final integration per BK-8/BK-CLEAN3 pattern.

## Seal-inputs contribution

The quiet-tree gate's lane accounting: every lane from the last ~50
checkpoints is now LANDED except the typed IN-FLIGHT set above
(BK-GWSV, BK-MON5, BK-SEAL5, BK-WIT4, BK-TRIO, BK-MON3R, kafka-wire residue)
and the carried DEAD pair (BK-WIT/BK-WIT2). One uncommitted receipt
(`bktrio-gates.md`) is the only git-clean-delete hazard.
