# BK-LANES3 — final lane accounting (seal census)

**Standing**: PARTIAL_ALIVE — Context: solo · Date: 2026-10-22 · Subject: `/Users/sac/smalt` (canonical checkout)
MIX_BUILD_ROOT: none (census lane, read-only + `_LANES.md`/this receipt only; never ran git state-mutating commands).

## Scope

Enumerated the last ~40 checkpoint commits (`git log --oneline -45`, window
07:2x–09:01, HEAD `e3985e66`) plus full disk re-read of
`docs/jira/v26.10.22/receipts/` (386 files) at 09:0x PDT. Every lane named
in-flight since BK-LANES2 was re-verified on disk: committed receipt
existence, owned-file mtimes, dirty working-tree entries, `_build-*` root
mtimes. Standing comes from each receipt's embedded standing line, re-read at
reconcile time — not recalled.

## Per-lane table (lanes born since BK-LANES2)

| Lane | Verdict | Standing | Evidence |
|---|---|---|---|
| BK-POWLV, BK-POWLH2, BK-MON3R, BK-WIT4P, BK-AMQPC, BK-MON5, BK-MON6, BK-PINIT, BK-WIT3R, BK-POWLH3, BK-B4R, BK-POWLH4, BK-1SAFE, BK-DRAIN3, BK-CENS6, BK-KFKC/KFKC2/KFKCW, BK-WIT4, BK-WIT4F, BK-B4RC, BK-B7CR, BK-BGF, BK-GWSSKEP/GWSSKEP2/GWSP, BK-GWSQ, BK-GWS7V, BK-B4RD, BK-GOPRE, BK-ZOMB, BK-WPARSE, BK-DUPID, BK-EXWV, BK-PROFV, BK-INTG, BK-BFFSEC, BK-SEC, BK-EPLAW/EPLAW2, BK-TRIO, BK-WIT (rerun), BK-WIT2 (rerun) | LANDED (~40 lanes, one row each) | ALIVE except: BK-WIT/BK-WIT2/BK-WIT4 PARTIAL_ALIVE; BK-WIT3R PARTIAL_ALIVE (4/6 resolved); BK-AMQPC PARTIAL_ALIVE (per-file verdicts); BK-GOPRE PARTIAL_ALIVE (census); BK-GWSQ ALIVE with typed caveats C1/C2 | per-lane receipt paths under `receipts/` (bkpowlv-loop-verify, bkpowlh2-loop-compile, bkmon3r-deadjoin-fix, bkwit4p-poll, bkamqpc-drift, bkmon5-metrics-verify, bkmon6-integrity-verify, bkpinit-stale-delete, bkwit3r-six-reds, bkpowlh3-walk-fix, bkb4r-sender-link, bkpowlh4-pattern-fix, bk1safe-safeness, bkdrain3-sequencer, bkcens6-wave6, bkkfkc-legacy-count, bkkfkc2-legacy-verify, bkkfkcw-merged-verify, bkwit4-witness-final, bkwit4f-scope-fix, bkb4rc-send-gate-court, bkb7cr-consume-scope, bkbgf-annotate, bkgwsskep-wave-audit, bkgwsskep2-wave-verify, bkgwsp-poll, bkgwsq-discharge, bkgws7v-gate5, bkb4rd-json-route-verify, bkgopref-check, bkzombie-census, bkwparse-hardening, bkdupid-dedup fix→bkdupid-dedup-fix.md, bkexwv-deploy-verify, bkprofv-profile-verify, bklanes2-final, bkbffsec-census, bksec-nfr-closures, bkeplaw-ephemeral-ports, bkeplaw2-bench-fences, bktrio-gates, bkwit-witness-all, bkwit2-witness-all — all committed, all standing lines re-read on disk this pass) |
| BK-SEAL5 | LANDED | ALIVE — seal close condition MET | `receipts/bkseal5-close.md` |
| KD-FV0 (KD-181) | LANDED | OPEN (registration-only row, by design) | `receipts/kdfv0-row.md` |
| BK-GOSEQ | **IN-FLIGHT** — witness-all run COMPLETED 08:43, receipt pending | PARTIAL output on disk | `/tmp/bkgoseq-witness-all.out` (110,946 bytes, mtime 08:43): `[WITNESS-SUMMARY] total=589 witnessed-green=171 stale-typed=386 failed=32`; `just witness-all` exited 1 (by design on residual failures). `_build-bkgoseq` warm 08:59. No `receipts/bkgoseq*`. |
| BK-SEAL6 | IN-FLIGHT (live) | — | `_build-bkseal6` 08:26; named in-flight through checkpoint `e3985e66` ("quiet x2 — load 3.64, KD-FV0 row"); no receipt |
| BK-NSP (UNREGISTERED) | IN-FLIGHT — unregistered lane | — | `test/integration/namespace_put_test.exs` dirty 09:01 (+1 line: `{:module,_} = :code.ensure_loaded(Smalt.EgressRouter.Peers)` before delete/purge — a real fix, not noise); `_build-bknsp` fresh 09:01 (freshest root on disk). Not named in any checkpoint. Registration owed. |
| BK-WIT / BK-WIT2 (BK-LANES2 DEAD-CANDIDATE) | **SUPERSEDED → LANDED** | PARTIAL_ALIVE / PARTIAL_ALIVE | Both now hold committed receipts: `receipts/bkwit-witness-all.md` (08:21, 424 legs, every red typed), `receipts/bkwit2-witness-all.md`. BK-LANES2's DEAD-CANDIDATE typing is retired; coordinator reap of `_build-witness` may proceed as ordinary landed-lane reclaim. |
| BK-119 (useWebLocks) | DEAD-NO-ARTIFACT (carried, unchanged) | — | No new artifact since BK-LANEAUD; still reap decision owed. |
| BK-GWSV / BK-MON5(early) / BK-WIT4(weak) / EXPL10-R / EXPL11-R / BK-GREEN / BK-MAAP6 / BK-MCPSHA / BK-AMPSKEP / BK-KFKSKEP / BK-WPSSKEP (BK-LANES2 weak in-flight rows) | LANDED-via-successor or superseded | — | Successor receipts landed this window: gws7→BK-GWS7V, mon5→`bkmon5-metrics-verify.md`, wit4→`bkwit4-witness-final.md`, expl11r→`expl11r3-planes-meta.md` lineage; kfkskep→BK-KFKC chain; wpsskep→BK-WPSS2; ampskep→BK-B4R chain. |

## BK-LANES3 cross-checks (09:0x)

- **Untracked receipts: ZERO** (was ONE live hazard at BK-LANES2 —
  `receipts/bktrio-gates.md`; now committed, hazard CLEAR).
  `git status --short docs/jira/v26.10.22/receipts/` → empty. Untracked court
  files: ZERO (BK-LANES2's `bkmon3r_deadjoin_court_test.exs` was registered by
  BK-CENS6 and swept to HEAD).
- **Build roots post-BK-CLEAN3 delta:** 53 roots / 24G at BK-LANES2 (07:2x) →
  **24 roots / 11G** now (`ls -d _build-* | wc -l` = 24; `du -sch _build-*`
  = 11G total). Freshest live: `_build-bknsp` 09:01, `_build-bkgoseq` 08:59,
  `_build-bkgwsq` 08:46, `_build-bkseal6` 08:26, `_build-bkgws7v` 08:23.
  Reap candidates (owner LANDED or DEAD): `_build-witness` (06:54, owner
  BK-WIT now LANDED), `_build-lane18`, `_build-lane-cli`, `_build-az3`,
  `_build-kd174d2`, `_build-gws7`, `_build-witck`, `_build-eplaw`,
  `_build-expl11r3`, `_build-bksec`, `_build-bkb4rd`, `_build-bkprofv`,
  `_build-bkampv`, `_build-bkmon2`, `_build-bkgwsskep`, `_build-ampf1`,
  `_build-bk7`, `_build-bkgoseq` (once its receipt lands). Coordinator
  reclaim at final integration per the BK-8/BK-CLEAN3 pattern (~11G at
  stake).
- **Coordinator-owned regen residue (still dirty, not lane debt):**
  `RECEIPTS.md` + `receipts/INDEX.md` for v26.10.14 and v26.10.22,
  plus the BK-INTG staged rename
  `sqld2_sql_ingest_court.exs → sqld2_sql_ingest_court_test.exs` and the
  BK-NSP `namespace_put_test.exs` edit. No other dirty files.

## Falsifier

A lane named in-flight in a checkpoint whose receipt is absent on disk AND
whose owned surface shows no fresh mtime should have been typed IN-FLIGHT
here; any lane tabled LANDED whose receipt path is missing on disk invalidates
this census.
