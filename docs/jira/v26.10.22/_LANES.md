# v26.10.22 Lane Partition

Reconciled 2026-10-22 (lane BK-8, hygiene) against reality: every receipt on
disk under `receipts/` (108 receipt files, standing lines re-read from disk at
reconcile time — not recalled) plus the checkpoint commit history
(`git log --oneline -40`). Standing is taken from each receipt's own embedded
standing line; a receipt with no standing line is **UNWITNESSED** (commit
message is evidence-of-activity, never standing). Live lanes at reconcile time
(hold their build roots): WPS-EXP4, WIRE-EXP4, EXP1-A, BK-7, KD-143,
KD-AMQP, KD-CONF, KD-BLOB, BK-85. All other `_build-*` roots were reclaimed
by BK-8 (~35.9 GiB); see `receipts/bk8-laneclean-wrap.md`.

## Lane ledger (reconciled)

Standing vocabulary: ALIVE / PASS / PARTIAL_ALIVE / SUSPECT / UNWITNESSED.
Evidence paths are relative to this directory (`receipts/<file>`).

### ATH (workspace client tiers)

| Lane | Files owned | Standing | Evidence |
|---|---|---|---|
| ATH-1 | batch frame receiver (workspace sync ingest) | ALIVE — 11/11 court gates green | `receipts/ath1-batch-frame-receiver.md` |
| ATH-2 | Next.js client | ALIVE (browser surface); sync server leg PARTIAL_ALIVE | `receipts/ath2-nextjs-client.md` |
| ATH-3 | law court | ALIVE | `receipts/ath3-law-court.md` |

### AZ (Azure service faces)

| Lane | Files owned | Standing | Evidence |
|---|---|---|---|
| AZ-2 | MAA attestation face | ALIVE — 7/7 court legs + shim court PASS | `receipts/az2-maa-attestation.md`; `receipts/az2b-maa-receipt.md` |
| AZ-3 | Confidential Ledger mount | PARTIAL_ALIVE — court 6/6 on real HTTP face | `receipts/az3-confidential-ledger.md` |
| AZ-4 | MHSM policies | ALIVE (policy face) / UNSUPPORTED (FIPS HSM silicon) | `receipts/az4-mhsm-policies.md`; `receipts/az4b-mhsm-receipt.md` |
| AZ-5 | Web PubSub face | ALIVE over landed BK-58 WS relay | `receipts/az5-webpubsub.md`; `receipts/az5b-webpubsub-receipt.md` |

### BK (checkpoint-snapshot hygiene/census lanes)

| Lane | Files owned | Standing | Evidence |
|---|---|---|---|
| BK-50 | private-trip gate | PARTIAL_ALIVE (real-tree scan honest RED, 41 hits triaged) | `receipts/bk50-private-trip.md` |
| BK-53 | final release draft | PARTIAL_ALIVE (seal PENDING-GATE on 5 rows) | `receipts/bk53-finalrelease-draft.md` |
| BK-54 | private-trip remediation | ALIVE | `receipts/bk54-private-trip-remediation.md` |
| BK-56 | allow-origin | ALIVE | `receipts/bk56-allow-origin-actual.md` |
| BK-57 | heir guard | ALIVE (37/37 guarded, mutation probe witnessed) | `receipts/bk57-heir-guard.md` |
| BK-58 | AMQP relay | PARTIAL_ALIVE — host relay ALIVE; browser leg TYPED-PERMANENT | `receipts/bk58-amqp-relay.md` |
| BK-63 | sync interop | ALIVE (9/9 legs) | `receipts/bk63-sync-interop.md` |
| BK-66 | P12 wiring | ALIVE (static+browser; live wire leg typed SKIP pending SYNC-1) | `receipts/bk66-p12-wiring.md` |
| BK-67 | witness census | ALIVE (dry-run census; gated witness-all = wrap lane's job) | `receipts/bk67-witness-census.md` |
| BK-68 | standing backfill | ALIVE | `receipts/bk68-standing-backfill.md` |
| BK-69r | store reconciliation | ALIVE | `receipts/bk69r-store-reconciliation.md` |
| BK-73 | workspace combined | ALIVE | `receipts/bk73-workspace-combined.md` |
| BK-74 | popcorn regression | ALIVE (full suite green solo re-run) | `receipts/bk74-popcorn-regression.md` |
| BK-75 | KD final census | PASS | `receipts/bk75-kd-final-census.md` |
| BK-76 | sync auth witness | ALIVE (KD-15 challenge witnessed on real wire) | `receipts/bk76-sync-auth-witness.md` |
| BK-77 | seal refresh | PASS | `receipts/bk77-seal-refresh.md` |
| BK-81 | milestone-doc (lanes ledger v73) | ALIVE | `receipts/bk81-lanes-v73.md` |
| BK-82 | internal census green | ALIVE (plane_blast_radius 6/6) | `receipts/bk82-internal-census-green.md` |
| BK-83 | sync e2e auth | ALIVE (9/9 legs, court exit 0) | `receipts/bk83-sync-e2e-auth.md` |
| BK-84 | spofb correction | ALIVE | `receipts/bk84-spofb-correction.md` |
| BK-85 | seal invariant (LIVE — holds `_build-bk85`) | ALIVE — root cause fixed in caller | `receipts/bk85-seal-invariant.md` |
| BK-86 | KD-164 fold | UNWITNESSED (no-fold: BK-85 witness receipt absent at time) | `receipts/bk86-kd164-fold.md` |
| BK-88 | spof3 standing | ALIVE | `receipts/bk88-spof3-standing.md` |
| BK-90 | witness scope | ALIVE | `receipts/bk90-witness-scope.md` |
| BK-91 | blob CORS seed | ALIVE | `receipts/bk91-blob-cors-seed.md` |
| BK-92 | receipt SoT | ALIVE (cross-mint byte-identical) | `receipts/bk92-receipt-sot.md` |
| BK-93 | KD gates | ALIVE (all three gates exit 0) | `receipts/bk93-kd-gates.md` |
| BK-95 | witness full | PARTIAL_ALIVE (exit 1, all reds typed) | `receipts/bk95-witness-full.md` |
| BK-96 | runbook addendum | ALIVE | `receipts/bk96-runbook-addendum.md` |
| BK-97 | ops env notes | ALIVE | `receipts/bk97-ops-env-notes.md` |
| BK-98 | lane-clean sweep | ALIVE (deletions re-verified on disk) | `receipts/bk98-lane-clean-sweep.md` |
| BK-99 | KD-164 pointer | ALIVE | `receipts/bk99-kd164-pointer.md` |
| BK-100 | seal docs as-of | PASS | `receipts/bk100-seal-docs-asof.md` |
| BK-100b | standing backfill 2 | PARTIAL_ALIVE (8 Class-C reds repaired in-receipt) | `receipts/bk100b-standing-backfill2.md` |
| BK-101 | G3 disposition | ALIVE | `receipts/bk101-g3-disposition.md` |
| BK-102 | e2e harness | ALIVE (sync-e2e-court 5/5 ×consecutive) | `receipts/bk102-e2e-harness.md` |
| BK-103/103b | wsrelay leg + verify | ALIVE / PARTIAL_ALIVE (103b premise rot on BK-103 order) | `receipts/bk103-wsrelay-leg.md`; `receipts/bk103b-wsrelay-verify.md` |
| BK-104/104b | EH atom heirs + invariant gates | ALIVE | `receipts/bk104-eh-atom-heirs.md`; `receipts/bk104b-invariant-gates.md` |
| BK-105 | leg4b reauthor | ALIVE | `receipts/bk105-leg4b-reauthor.md` |
| BK-106 | sync engine fixes | ALIVE (sync-e2e-court 9/9 ×2) | `receipts/bk106-sync-engine-fixes.md` |
| BK-107/107b | wsrelay combined + IND fold | PASS (relay) / ALIVE (fold) | `receipts/bk107-wsrelay-combined.md`; `receipts/bk107b-ind-fold.md` |
| BK-108 | census kdconf | ALIVE | `receipts/bk108-census-kdconf.md` |
| BK-109/109b | KD-165 pointer + G2 telemetry | PASS / ALIVE (court 10/10) | `receipts/bk109-kd165-pointer.md`; `receipts/bk109b-g2-telemetry.md` |
| BK-10b | citation audit | PASS (0 broken citations) | `receipts/bk10b-citation-audit.md` |
| BK-110 | A7 disposition | ALIVE (wired + kill-tested) | `receipts/bk110-a7-disposition.md` |
| BK-111 | ProVo agent chain | ALIVE (all three legs on real emitters) | `receipts/bk111-provo-agent-chain.md` |
| BK-112 | KD-88/153 | ALIVE | `receipts/bk112-kd88-153.md` |
| BK-113 | RDF-star probe | PARTIAL_ALIVE (probe-only) | `receipts/bk113-rdfstar-probe.md` |
| BK-114 | verification reruns | PARTIAL_ALIVE (8/9 re-witnessed; private-trip FAIL owned below) | `receipts/bk114-verification-reruns.md` |
| BK-115b | trip regression | ALIVE (both gates green) | `receipts/bk115b-trip-regression.md` |
| BK-117b | typed exit | PASS (R-116-1 closed) | `receipts/bk117b-typed-exit.md` |
| BK-118 | useAsyncFn port | ALIVE (courts green ×1) | `receipts/bk118-useasyncfn-port.md` |
| BK-125 | sync3 reconcile | ALIVE | `receipts/bk125-sync3-reconcile.md` |
| BK-126 | spof4 reconcile | ALIVE (standing line repaired by BK-JAR, receipt_index clean) | `receipts/bk126-spof4-reconcile.md` |
| BK-127 | spofb reconcile | ALIVE (spofb court 7/7) | `receipts/bk127-spofb-reconcile.md` |
| BK-128 | KD-167 reconcile | ALIVE | `receipts/bk128-kd167-reconcile.md` |
| BK-129rr | pplan agent chain | PASS (10/10, W3C GAP-6a closed) | `receipts/bk129rr-pplan-agent-chain.md` |
| BK-130 | hook ports | PASS (hooks court ×2) | `receipts/bk130-hook-ports.md` |
| BK-131 | e2e rerun | ALIVE | `receipts/bk131-e2e-rerun.md` |
| BK-135r | matter journal | PARTIAL_ALIVE (court+regressions+shim green on exact subject) | `receipts/bk135r-matter-journal.md` |
| BK-139r | KD-166 fold | ALIVE (dual-claim folded → KD-170) | `receipts/bk139r-kd166-fold.md` |
| BK-143rr | aero P3 pillar | ALIVE | `receipts/bk143rr-aero-p3.md` |
| BK-146r | pillar consumers | ALIVE | `receipts/bk146r-pillar-consumers.md` |
| BK-150 | finisher sweep | PARTIAL_ALIVE (30 landed/folded; 5 zero-trace lanes) | `receipts/bk150-finisher-sweep.md` |

### ERL / EXPL / WIRE (exploration + wire-front lanes)

| Lane | Files owned | Standing | Evidence |
|---|---|---|---|
| ERL-3 | kafka wormhole proposer | ALIVE (court 8/8 ×2) | `receipts/erl3-kafka-wormhole-proposer.md` |
| ERL-4r | vc/twins/lakehouse | ALIVE (standing line repaired by BK-JAR, receipt_index clean) | `receipts/erl4r-vc-twins-lakehouse.md` |
| EXP1-A | worker/guard repairs (LIVE) | ALIVE — court PASS 17/17 legs | `receipts/exp1a-worker-guard-repairs.md` |
| EXPL-1 | workspace ERRC | ALIVE (read-only findings) | `receipts/expl1-workspace-errc.md` |
| EXPL-1r W1 | fail-closed gate repair | ALIVE | `receipts/expl1r-w1-repair.md` |
| EXPL-3 | dataplane ERRC | PARTIAL_ALIVE (code-read-confirmed findings) | `receipts/expl3-dataplane-errc.md` |
| EXPL-3r | dataplane repairs | ALIVE (12/12 court legs) | `receipts/expl3r-dataplane-repairs.md` |
| EXPL-4 | wirefronts ERRC | PARTIAL_ALIVE (read-only probes) | `receipts/expl4-wirefronts-errc.md` |
| WIRE-EXP4 | amqp10 frame-decoder court (LIVE) | ALIVE | `receipts/wire-exp4-frame-decoder.md`; commit ec56e70b |

### PAT (workspace pattern lanes)

| Lane | Files owned | Standing | Evidence |
|---|---|---|---|
| PAT-A | dom contract | ALIVE (real engine state) | `receipts/pat-a-dom-contract.md` |
| PAT-B | sync semantics | ALIVE (node courts exit 0) | `receipts/pat-b-sync-semantics.md` |
| PAT-C | pattern court | PARTIAL_ALIVE | `receipts/pat-c-pattern-court.md` |
| PAT-D | browser tier | PARTIAL_ALIVE (browser 4/4 PASS; pre-existing dom-lint rows FAIL) | `receipts/pat-d-browser-tier.md` |
| PAT-E | lint surface | ALIVE (6 dom-lint rows flipped PASS) | `receipts/pat-e-lint-surface.md` |

### SPOF / STORE / SYNC (sync-engine + SPOF lanes)

| Lane | Files owned | Standing | Evidence |
|---|---|---|---|
| SPOF-3 | affidavit fixes | ALIVE | `receipts/spof3-affidavit-fixes.md` |
| SPOF-4 | tab hardening | ALIVE (19/19 court) | `receipts/spof4-tab-hardening.md` |
| SPOFA | beam audit | PARTIAL_ALIVE (audit-only) | `receipts/spofa-beam-audit.md` |
| SPOFA-1 | journal fixes | ALIVE (court 3/3 + SJ-1/TTV-4 green) | `receipts/spofa1-journal-fixes.md` |
| SPOFB | boundary audit | SUSPECT (2 OPEN defect classes) | `receipts/spofb-boundary-audit.md` |
| SPOFB-fix | EH atom fixes | ALIVE (court green; pre-existing flake attributed) | `receipts/spofb-eh-atom-fixes.md` |
| STORE-2 | supervision wiring | PARTIAL_ALIVE (compile-verified) | `receipts/store2-supervision-wiring.md` |
| STORE-3 | wire regression | ALIVE | `receipts/store3-wire-regression.md` |
| STORE-4 | partition court | ALIVE (4/4 ×3) | `receipts/store4-partition-court.md` |
| SYNC-1 | batch receiver | ALIVE (compile 0 / court 11/11 / witness 9/9) | `receipts/sync1-batch-receiver.md` |
| W-3 | KQL sealed | PARTIAL_ALIVE → engine ALIVE | `receipts/w3-kql-sealed.md` |
| W-3Ca | conformance census | PARTIAL_ALIVE (census-only) | `receipts/w3ca-conformance-census.md` |
| W-3Cb | VC export | PARTIAL_ALIVE | `receipts/w3cb-vc-export.md` |
| W-3Cc | ACP shapes | PARTIAL_ALIVE (law files + court ALIVE) | `receipts/w3cc-acp-shapes.md` |
| W-3Ce | browser runtime | PARTIAL_ALIVE (rows 8/9/10 + gated) | `receipts/w3ce-browser-runtime.md` |
| W-6 | PQC disposition | ALIVE (GAP row CLOSED) | `receipts/w6-pqc-disposition.md` |

## Named in-flight lanes — resolved by BK-LANEAUD (2026-10-22, post-BK-8 audit)

Audited hours after BK-8's snapshot; each row re-verified on disk (receipts
dir, owned files, commit log). Receipt:
`receipts/bklanaud-inflight.md`.

| Lane | Verdict | Evidence |
|---|---|---|
| WPS-EXP4, WIRE-EXP4, EXP1-A, BK-7, KD-143, KD-AMQP, KD-CONF, KD-BLOB, BK-85 | LANDED (already receipted; rows above) | ledger rows above |
| BK-149 (smalt-cli typer probe) | LANDED — successor receipts | `receipts/bk149-smaltcli-closeout.md` (PARTIAL_ALIVE); `receipts/bk149b-cli-green.md` |
| BK-119 (useWebLocks PR branch) | **DEAD-NO-ARTIFACT** — never pushed: `git branch -a` = main only; no receipt, no doc trace beyond checkpoint name-drops; BK-150 (`receipts/bk150-finisher-sweep.md`) independently typed it missing/429-killed. Coordinator reap decision owed. | checkpoints 7dcdd9df..17848b75 name only |
| BK-148 (W3C GAP ledger) | LANDED (fold) — GAP ledger final: GAP-6a CLOSED, GAP-1a/4a UPSTREAM-OPEN, disposition ledger; docs-dod 65/65 | `W3C-FORMALIZATION.md`, commit 8475ca49 |
| BK-WIT / BK-WIT2 (witness re-run lanes) | **DEAD-CANDIDATE — typed for reap.** No receipt (`receipts/` has no bkwit*), no owned-file trace, only artifact is `_build-witness` (last write 03:56, >90 min stale; superseded by BK-REWIT wave 1+2 which landed the exit-capture re-witnesses at `receipts/bkrewit-wave1.md` + `receipts/bkrewit2-wave2.md`). Coordinator reap decision owed. | checkpoints 266e9e60/36a8b74c/c5fbce28 name only |

## Named in-flight lanes — reconciled by BK-AUD2 (2026-10-22 05:30, full accounting)

Enumerated from the 16 coordinator tick-checkpoint commits in `git log -80`
(most recent c5fbce28 05:27). Every lane named in-flight in the LATEST
checkpoint was re-verified on disk at 05:30: receipt existence (committed),
owned-file mtimes, dirty working-tree files, `_build-*` root mtimes. Lanes
from earlier checkpoints that appear in no snapshot after ~05:0x are all
LANDED — each has a committed receipt under `receipts/` (BK-SEAL2, EXPL-11,
BK-SUBTLS, BK-PPDOC, BK-MAASKEP, BK-MCPSKEP, BK-N7, BK-FMT, BK-RSIZE,
BK-CONF, KD-169R, EXPL9-REG, BK-REWIT, BK-E2SKIP, KD-FIXF, EXPL-10, BK-WP2,
BK-EPLAW, BK-EPLAW2, MCP-T1, EXPL9-R1/R2, BK-SUSP, BK-SUSP2, KD-SKEP,
WSKEP-R1, KD-171R, BK-PRD5, BK-149C, BK-BSHAPE, BK-119B, BK-WSKEP, BK-ISOL,
BK-CENS, BK-CELLS, KD-173R, BK-7C, BK-CERTA, BK-SKIPPORT, BK-W2C, BK-KWT,
BK-ECREG, KD-FLIPFIX, BK-AMQPF, BK-VCOURTS, PB4-T, PB1-SDKFIX, BK-10C,
EXPL5-R2, EXPL7-R1, BK-5, EXPL8, BK-PRDR, EXPL-9).

| Lane | Verdict at 05:30 | Evidence |
|---|---|---|
| BK-TYPORT | LANDED — committed receipt + HEAD commit | `receipts/bktyport-lane-ports.md`, commit 2dd5c028 |
| BK-REWIT2 (wave 2) | LANDED | `receipts/bkrewit2-wave2.md` (05:27, committed) |
| KD-173C (harness) | IN-FLIGHT — harness dirty 05:29 | `workspace/scripts/lib/kd173c-harness.mjs` (M, 05:29); `_build-ft-*` roots |
| KD-174D2 (register) | IN-FLIGHT — KD register dirty 05:29 | `docs/jira/v26.10.14/KNOWN_DIVERGENCES.md` (M, 05:29); `_build-kd174d2` 05:22 |
| EXPL10-R | IN-FLIGHT (weak) — build root only | `_build-expl10r` 05:24; no receipt, no dirty owned file |
| EXPL10-R2 | IN-FLIGHT — court file dirty 05:29 | `test/internal/expl10r2_court_test.exs` (M, 05:29) |
| EXPL11-R | IN-FLIGHT (weak) — build root only | `_build-expl11r` 05:27; no receipt, no dirty owned file |
| EXPL11-R1 | IN-FLIGHT — court file committed, receipt pending | `test/internal/expl11r1_ledger_range_court_test.exs` (tracked, 05:26); no receipt |
| EXPL11-R2 | IN-FLIGHT — untracked court file 05:29; census registered it as mid-edit | `test/internal/expl11r2_wps_service_events_court_test.exs` (??, 05:29) |
| BK-GREEN | IN-FLIGHT (weak) — build root only | `_build-bkgreen` 05:15; no receipt, no dirty owned file |
| BK-FIN | IN-FLIGHT — FINAL doc dirty 05:29 | `docs/jira/v26.10.22/FINAL-RELEASE-26.10.22.md` (M, 05:29) |
| BK-MAAP6 | IN-FLIGHT (weak) — build root only | `_build-maap6` 05:27; no receipt, no dirty owned file |
| BK-MCPSHA | IN-FLIGHT (weak) — build root only | `_build-bkmcpsha` 05:27; no receipt, no dirty owned file |
| BK-AMPSKEP | IN-FLIGHT — build root 05:23, no receipt yet | `_build-bkampskep` |
| BK-KFKSKEP | IN-FLIGHT — build root 05:21, no receipt yet | `_build-kfkskep` (+`_build-kfkx4`) |
| BK-WPSSKEP | IN-FLIGHT — build root 05:17, no receipt yet | `_build-bkpsskep` |
| BK-CENS2 | IN-FLIGHT (active) — census file dirty 05:30 | `test/internal/internal_tier_census_test.exs` (M, 05:30) |

### BK-AUD2 side-audits (05:30)

- **Untracked receipts: ZERO.** All 221 files in `receipts/` are committed;
  `git status` shows no untracked/modified receipt. Git-clean-delete hazard
  clear as of 05:30.
- **`_build-*` orphan census (report-only, nothing deleted):** 44 roots,
  22 GiB total (`du -sch`). 40 carry this session's live lane leases (mtimes
  03:56–05:29, each maps to a lane above); 4 pre-date the current wave and
  are reap candidates for the coordinator: `_build-az2`, `_build-bk70rr`
  (v26.10.21 straggler per BK-WRAP2), `_build-bk7c`, `_build-bk83`. Do not
  delete without owner confirmation; BK-8's ~35.9 GiB reclaim pattern
  (`receipts/bk8-laneclean-wrap.md`) applies at next integration.
| BK-142/142r (pillar matrix) | LANDED (fold) — PARTIAL_ALIVE disk-truth fold; aero P3 open cell subsequently closed by BK-143rr | `pillars-cross-industry.md`, commits 3e8baf0f + da0a434c; successor receipts `receipts/bk143rr-aero-p3.md` (ALIVE), `receipts/bk146r-pillar-consumers.md` (ALIVE) |
| AZ-1 (kafka wire court) | LANDED-via-successor — kafka wire court/repairs landed as KAFKA-EXP4 + ERL-3 | `receipts/kafka-exp4-repairs.md` (ALIVE, commit 853ca62c); `receipts/erl3-kafka-wormhole-proposer.md` (ALIVE, court 8/8 ×2) |
| AZCLI-3/AZCLI-4 (cli.py/typer pack) | LANDED-via-successor — Typer command groups + ty_* probes are exactly the owned files courted by BK-149 closeout | `smalt-cli/smalt_cli/cli.py` + 5 typer groups + `smalt-cli/tests/test_ty_*.py`; `receipts/bk149-smaltcli-closeout.md` (PARTIAL_ALIVE); `receipts/bk149b-cli-green.md` (12/12 ty_* green) |

Zero rows remain genuinely-in-flight. One row (BK-119) typed
DEAD-NO-ARTIFACT for coordinator reap decision.

## Final lane accounting — BK-LANES2 (2026-10-22 07:2x, post-BK-FIN3)

Enumerated from the last ~50 coordinator tick checkpoints (window 06:39–07:24,
`git log --oneline -60`) plus a full disk re-read of `receipts/` (235 receipt
files). Every lane named in-flight in a checkpoint since BK-AUD2 was
re-verified on disk: committed receipt existence, owned-file mtimes, dirty
working-tree entries, `_build-*` root mtimes. Standing comes from each
receipt's embedded standing line, re-read at reconcile time. Full per-lane
table: `receipts/bklanes2-final.md`.

| Lane | Verdict | Standing | Evidence |
|---|---|---|---|
| BK-RETOK, KD-174F, BK-RATIO, BK-AMPV, BK-WPS2V, BK-FONDV, BK-QREAD, BK-REWIT3, EXPL12-V, KD-N1, EXPL12-W, KD-MIR2, BK-CLEAN3, BK-MON2, BK-DUPID, BK-ST4W, KD-WFIX, BK-XPRIF, BK-XPRIV, BK-DRAIN, KD-ATON, BK-AMPF1, BK-WPSS2, BK-F1A, BK-EXART, BK-QMON, BK-KDL, BK-MON3, BK-WIT3, BK-KFKC2, BK-CLIROW, BK-CLIV, BK-DRAIN2, BK-SUB3, BK-JRPC(+JRPC2), BK-CENS5, BK-FONDW, BK-WIREC, KD-SKEP2, KD-KLV, BK-CITEG/CITEV, BK-MON4, EXPL12-F, BK-KFKV, BK-MCPW, BK-BQUIET, BK-DUCK, BK-KLVD, BK-FIN3, BK-PRDA, BK-SEAL4 | LANDED (51 lanes, one row each) | ALIVE except: BK-PRDA/BK-FONDV/BK-QREAD/EXPL12-V/KD-MIR2/BK-MON3/BK-WIT3/BK-BQUIET/BK-SEAL4 PARTIAL_ALIVE; BK-QMON SUSPECT (BENCH-WINDOW-BLOCKED); KD-174F OPEN-hold; BK-ST4W DEAD/UNWIRED disposition | `receipts/bklanes2-final.md` (per-lane table with exact receipt paths) |
| BK-GWSV | IN-FLIGHT (live) | — | `_build-bkgwsv` 07:25, no receipt; named in-flight through checkpoint 128aba94 |
| BK-MON5 | IN-FLIGHT (live, unregistered) | — | `_build-bkmon5` 07:25, no receipt, not named in any checkpoint |
| BK-SEAL5 | IN-FLIGHT | — | named in-flight in the 3 latest checkpoints; `_build-bkseal5` 06:57; no receipt |
| BK-WIT4 | IN-FLIGHT (weak) | — | named in-flight in 3 latest checkpoints; no receipt, no owned-file trace |
| BK-TRIO | IN-FLIGHT — **UNCOMMITTED-RECEIPT HAZARD** | ALIVE (in uncommitted receipt) | `receipts/bktrio-gates.md` is UNTRACKED; owned surface `test/integration/powl2_gates_court.exs` (M). A checkout-level clean would destroy the receipt — coordinator commit owed. |
| BK-MON3R | IN-FLIGHT | — | untracked `test/internal/bkmon3r_deadjoin_court_test.exs`; no receipt, unregistered |
| kafka wire face (WIRE-EXP4 lineage) | IN-FLIGHT residue | — | `test/internal/kafka_exp4_court_test.exs` (M) |
| BK-WIT / BK-WIT2 | **DEAD-CANDIDATE** (carried from BK-AUD2/BK-LANEAUD) | — | still no receipt, no owned-file trace; `_build-witness` last write 06:54 (touched after the DEAD typing, owner still absent). Typed for reap; coordinator decision owed. |

### BK-LANES2 cross-checks (07:2x)

- **Untracked receipts: ONE — git-clean-delete hazard LIVE** for
  `receipts/bktrio-gates.md` (BK-AUD2 measured zero at 05:30; this is a
  regression of that check, typed loudly). Untracked court files: ONE
  (`test/internal/bkmon3r_deadjoin_court_test.exs`).
- **Build roots census (post-BK-CLEAN3):** `ls -d _build-* | wc -l` = 53,
  `du -sch _build-*` = 24G total. Freshest `_build-bkgwsv`/`_build-bkmon5`
  (07:25, live lanes). `_build-witness` (06:54) has a DEAD owner and is a
  reap candidate. `_build-ft-*` per-hash roots are regenerable scratch.
  Coordinator reclaim at final integration per the BK-8/BK-CLEAN3 pattern.
- **Coordinator-owned regen residue:** `RECEIPTS.md`/`receipts/INDEX.md` for
  both v26.10.14 and v26.10.22 plus `bench/c8-chaos-cross.jsonl` are dirty —
  post-FIN3 regen drift, coordinator-owned, not lane debt.
- `lib/smalt/arm_gateway/router.ex` and `lib/smalt/monitor/metrics.ex` were
  dirty at session start but are clean at reconcile time (swept to HEAD by
  tick checkpoints).

## Final lane accounting — BK-LANES3 (2026-10-22 09:0x, post-BK-GWS7V, pre-seal)

Enumerated from the last ~40 coordinator tick checkpoints (window 07:2x–09:01,
`git log --oneline -45`, HEAD `e3985e66`) plus a full disk re-read of
`receipts/` (386 files). Every lane named in-flight since BK-LANES2 was
re-verified on disk; standings re-read from receipt standing lines at
reconcile time. Full per-lane table: `receipts/bklanes3-final.md`.

| Lane | Verdict | Standing | Evidence |
|---|---|---|---|
| BK-POWLV, BK-POWLH2/H3/H4, BK-MON3R/MON4/MON5/MON6, BK-PINIT, BK-WIT3R, BK-B4R, BK-1SAFE, BK-DRAIN3, BK-CENS6, BK-KFKC/KFKC2/KFKCW, BK-WIT4/WIT4F/WIT4P, BK-B4RC, BK-B7CR, BK-BGF, BK-GWSSKEP/GWSSKEP2/GWSP, BK-GWSQ, BK-GWS7V, BK-B4RD, BK-GOPRE, BK-ZOMB, BK-WPARSE, BK-DUPID, BK-EXWV, BK-PROFV, BK-INTG, BK-BFFSEC, BK-SEC, BK-EPLAW/EPLAW2, BK-TRIO, BK-WIT (rerun), BK-WIT2 (rerun) | LANDED (~40 lanes) | ALIVE except: BK-WIT/WIT2/WIT4/WIT3R/AMQPC/GOPRE PARTIAL_ALIVE; BK-GWSQ ALIVE w/ typed caveats | `receipts/bklanes3-final.md` (per-lane receipt paths, standings re-read this pass) |
| BK-SEAL5 | LANDED | ALIVE — seal close condition MET | `receipts/bkseal5-close.md` |
| KD-FV0 (KD-181) | LANDED | OPEN (registration-only row, by design) | `receipts/kdfv0-row.md` |
| BK-GOSEQ | IN-FLIGHT — witness-all run completed 08:43, receipt pending | — | `/tmp/bkgoseq-witness-all.out`: `[WITNESS-SUMMARY] total=589 witnessed-green=171 stale-typed=386 failed=32`, exit 1 (by design); `_build-bkgoseq` 08:59; no `receipts/bkgoseq*` |
| BK-SEAL6 | IN-FLIGHT (live) | — | `_build-bkseal6` 08:26; named in-flight through `e3985e66`; no receipt |
| BK-NSP (UNREGISTERED) | IN-FLIGHT — real edit, unregistered | — | `test/integration/namespace_put_test.exs` (M, 09:01, +1 ensure_loaded fix); `_build-bknsp` 09:01; not named in any checkpoint — registration owed |
| BK-WIT / BK-WIT2 | **SUPERSEDED → LANDED** (was DEAD-CANDIDATE at BK-LANES2) | PARTIAL_ALIVE ×2 | `receipts/bkwit-witness-all.md`; `receipts/bkwit2-witness-all.md` |
| BK-119 | DEAD-NO-ARTIFACT (carried, unchanged) | — | reap decision owed |

### BK-LANES3 cross-checks (09:0x)

- **Untracked receipts: ZERO** — BK-LANES2's live git-clean-delete hazard
  (`receipts/bktrio-gates.md`) is CLEAR: committed. Untracked court files:
  ZERO (bkmon3r court registered by BK-CENS6, swept to HEAD).
- **Build roots delta (post-BK-CLEAN3):** 53 roots / 24G (BK-LANES2, 07:2x)
  → **24 roots / 11G**. Live: `_build-bknsp` 09:01, `_build-bkgoseq` 08:59,
  `_build-bkgwsq` 08:46, `_build-bkseal6` 08:26, `_build-bkgws7v` 08:23.
  ~19 landed-owner roots are reap candidates at final integration (~11G at
  stake; BK-8/BK-CLEAN3 pattern).
- **Dirty tree (all coordinator-owned regen/in-flight, not lane debt):**
  `RECEIPTS.md`+`receipts/INDEX.md` ×2 windows, BK-INTG staged rename
  (`sqld2_sql_ingest_court.exs` → `_test.exs`), BK-NSP
  `namespace_put_test.exs` edit.

## History

Original hygiene WO (BK-8): census orphaned `_build-*` roots, delete those
whose lane has a LANDED receipt and no live agent, reconcile this ledger,
commit only `_LANES.md` + `receipts/bk8-laneclean-wrap.md`. Build-root keep
set (live lanes): `_build-wpsx4 _build-wirex4 _build-kfkx4 _build-bk7
_build-kd143 _build-kdamqp _build-kdconf _build-kdblob _build-bk85`.
