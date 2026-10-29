# FINAL-RELEASE-26.10.22

# FINAL-RELEASE — v26.10.22 (Gate-3 Seal)

> **STATUS: DRAFT** — gates in flight, seal PENDING.
> This document is the Gate-3 seal skeleton per `docs/jira/v26.10.22/PRD.md` §5
> ("Gate 3 seal"). Every PENDING-GATE row below resolves mechanically to a lane
> and an expected receipt path; the document flips to FINAL only when each row
> has a landed receipt postdating this draft. Last refreshed 2026-10-22, lane
> BK-FIN4 (census re-run + gate-ledger refresh + seal-inputs freshness).

## Gate ledger

| Gate | Item | Standing | Evidence / expected receipt |
|---|---|---|---|
| Gate 0 — hardening | TTV-1/2/3 landed (JA-R3) | CLOSED | `docs/jira/v26.10.21/receipts/ja-r3-ja16-defect-fixes.md` (PASS) |
| Gate 1 — durability | TTV-4 journal boot-replay | CLOSED | `docs/jira/v26.10.21/receipts/ttv4-journal-boot-replay.md` (ALIVE) |
| Gate 1 — durability | TTV-5 store partitioning court | IN-FLIGHT | court file `test/integration/ttv5_store_partitioning_court.exs` on disk; expected receipt `docs/jira/v26.10.22/receipts/ttv5-store-partitioning.md` — still absent at the BK-FIN3 refresh; operator-mandated architecture disposition typed in `receipts/store4-partition-court.md` (ALIVE, court 4/4 PASS ×3) + `receipts/bkst4w-store4-disposition.md` (ALIVE, `test/internal/store4_no_boot_test.exs` proves the store does not boot in the default plane mix); census-fence closure: `test/internal/internal_tier_census_test.exs` registers the file (BK-SEAL5 SLA unblock, disclosed in `receipts/bkseal5-close.md`) |
| Gate 1 — durability | BK-33 warm-restart rebind | RESOLVED | `docs/jira/v26.10.21/receipts/bk33-warm-restart-rebind.md` (root cause: heir-to-init ETS table surviving `System.restart`) |
| Gate 2 — console+sync | ATH-2 Next.js browser client | ALIVE (browser) / PARTIAL (sync leg) | `docs/jira/v26.10.22/receipts/ath2-nextjs-client.md` |
| Gate 2 — console+sync | SYNC-1 batch-frame receiver | CLOSED — ALIVE | `docs/jira/v26.10.22/receipts/ath1-batch-frame-receiver.md` (court 11/11); finish-and-relay `docs/jira/v26.10.22/receipts/sync1-batch-receiver.md` (ALIVE) |
| Gate 2 — console+sync | FR-SNC-005/006 fast-forward Merkle + join gate ω | QUEUED | minted by PRD §5 as WOs, still OPEN (no implementation, typed UNBUILT in PRD §4); expected receipts `docs/jira/v26.10.22/receipts/fr-snc-005.md` / `fr-snc-006.md` — still absent at the BK-FIN4 refresh |
| Gate 2 — console+sync | BK-VCOURTS consolidated validation-board courts | CLOSED — ALIVE | `docs/jira/v26.10.22/receipts/bkvc-consolidated-courts.md` (`just bkvc-court` ×2 exit 0, 7/7; three VALIDATION.md PENDING rows closed/re-typed → row-level PENDING = 0) |
| Gate 2 — console+sync | smalt-cli surface (COURT-CLI-SURFACE) | ALIVE | `docs/jira/v26.10.22/receipts/bkclirow-cells.md` (ALIVE, Context: solo — PRD §4a COURT-CLI-SURFACE cell + VALIDATION §3 addendum 2 table, typed from `receipts/bkcliv-final-verify.md` ALIVE: 149+37+35(+2 skipped)+102 py passes on the live `:enforce` substrate, pyright 0 errors; typed residues `expl12-cli-flag-parity.md` / `expl12v-auth-uniform.md` PARTIAL_ALIVE preserved) |
| Gate 2 — console+sync | smalt-cli auth uniformity | PARTIAL_ALIVE | `docs/jira/v26.10.22/receipts/expl12v-auth-uniform.md` (PARTIAL_ALIVE) → final verify `docs/jira/v26.10.22/receipts/expl12f-auth-final.md` (ALIVE — METHOD auth path → status leg) |
| Gate 3 — seal | BK-50 COURT-PRIVATE-TRIP | CLOSED — ALIVE (remediation landed) | `docs/jira/v26.10.22/receipts/bk50-private-trip.md` (honest RED triage) → `docs/jira/v26.10.22/receipts/bk54-private-trip-remediation.md` → `receipts/bk115b-trip-regression.md` (ALIVE — both gates green on the exact subject; regression fix re-verified) |
| Gate 3 — seal | BK-44 witness-all full run | PARTIAL_ALIVE — owner: BK-WIT lane | latest landed: `docs/jira/v26.10.22/receipts/bkwit4-witness-final.md` (PARTIAL_ALIVE — 111 real greens, 180 fails every one classified, zero real substrate/surface defects; residue is owner-work + artifacts + one typed scope finding, closed by `receipts/bkwit4f-scope-fix.md` ALIVE — scope pinned by name); prior: `bkwit3-witness-final.md` / `bkwit3r-six-reds.md` (PARTIAL_ALIVE), `bkwit2-witness-all.md`, `bk95-witness-full.md`, census `bk67-witness-census.md` (ALIVE); expected green `docs/jira/v26.10.22/receipts/bk44-witness-all.md` — **not on disk at the BK-FIN4 refresh** |
| Gate 3 — seal | BK-SEAL full-green HEAD sweep | ALIVE — close condition MET | `receipts/bkseal-full-green.md` → `bkseal2-fullgreen-recheck.md` → `bkseal3-quiesced-rerun.md` (PARTIAL_ALIVE — no result line) → `bkseal4-close-condition.md` (PARTIAL_ALIVE — close condition NOT met) → `receipts/bkseal5-close.md` (**ALIVE** — close condition MET: full `mix test` verbatim line `Result: 868/872 passed`, 4 failures all classified load-contention flakes, each green in isolation; census 6/6; invariant-gates 6/6; sleep-gate + court non-vacuous; docs-dod OK; kd-fence OK; receipt-index regenerated clean; kd_flip 0 eligible. Post-quiet x2 rerun owed by coordinator at seal time) |
| Gate 3 — seal | BK-35 HEAD court sweep | PENDING-GATE — owner: BK-35 lane | **no receipt on disk** at the BK-FIN4 refresh; expected `docs/jira/v26.10.22/receipts/bk35-head-court-sweep.md` |
| Gate 3 — seal | TTV-7b quiesced re-run | PENDING-GATE — owner: TTV-7b lane | precondition receipt `docs/jira/v26.10.21/receipts/ttv7b-quiesced-rerun.md` standing **BLOCKED-ON-QUIESCENCE**; expected flip receipt `docs/jira/v26.10.22/receipts/ttv7b-quiesced-flip.md` — still absent at the BK-FIN4 refresh |
| Gate 3 — seal | receipt-index + docs-dod + tag | PENDING-GATE — owner: coordinator | `just receipt-index` + `just docs-dod-check` + tag `v26.10.22`; current docs-dod exit recorded in `docs/jira/v26.10.22/receipts/bk53-finalrelease-draft.md`; expected receipt `docs/jira/v26.10.22/receipts/bk53-finalrelease-seal.md` |
| Post-ledger — monitor face | BK-MON monitor truth → repair → final standing | ALIVE | `receipts/bkmon-monitor-truth.md` / `bkmon2-metrics-repair.md` → `bkmon3-final-standing.md` (PARTIAL_ALIVE; residue BK-MON3-F1 dead join predicate) → `bkmon3r-deadjoin-fix.md` (ALIVE — F1 fixed end to end, non-vacuity witnessed) → `bkmon4-final-verify.md` (ALIVE at HEAD `daea2d87`) → `bkmon5-metrics-verify.md` (ALIVE at HEAD `39bffd77`) → `bkmon6-integrity-verify.md` (ALIVE — exact-equality filter, zero cross-resource leakage, both fixes coexist); observation `bkdrain2-monitor.md` / `bkdrain3-sequencer.md` (ALIVE, disk/ps reads) |
| Post-ledger — kafka legacy face | KD-180 recordsCount divergence | CLOSED-WITH-EVIDENCE | audit `receipts/bkkfkskep-kafka-audit.md` → repair BK-KFKC (magic-first `count/1` dispatch + legacy F3 cross-check, `# KD-COVERS: KD-180`) → verify `receipts/bkkfkv-replay-verify.md` (ALIVE — mixed-size legacy series 3/3/254B byte-exact across seal→kill→restart; planted count=5 lie advances hwm exactly 2, never 5; magic-2 lie → typed err=2; suites 18 passed) → `receipts/bkkfkcw-merged-verify.md` (ALIVE — merged-tree verify); canonical row KD-180 close-typed at mint (lane KD-KLV 2026-10-22) |
| Post-ledger — b4 sender-link | BK-B4R/B4RC/B4RD/B7CR messaging chain | ALIVE | `receipts/bkb4r-sender-link.md` (ALIVE — b4 delivers end to end; SUSPECT-PERMANENT row flipped to ALIVE) → `receipts/bkb4rc-send-gate-court.md` (ALIVE — send-gate regression court) → `receipts/bkb4rd-json-route-verify.md` (ALIVE — JSON child-PUT route end-to-end + creation-path census) → `receipts/bkb7cr-consume-scope.md` (ALIVE — consume probe scoped to per-run unique prefix) |
| Post-ledger — wasm sandbox gates | GWS-SANDBOX-GATES witness + discharge | ALIVE | `receipts/bkgwsskep-wave-audit.md` (PARTIAL_ALIVE, F1/F2 typed) → `receipts/bkgws7v-gate5.md` (ALIVE — root cause was gate 6, not gate 5; gate-6 assertion converted to a bounded poll via `SmaltTest.Internal.Poll`, deterministic 6/6 pre-fix failure is the mutation witness) → `receipts/bkgwsq-discharge.md` (ALIVE — 3/3 green, honest-typing caveats C1/C2) → `receipts/bkgwsskep2-wave-verify.md` (ALIVE); register row `receipts/kdfv0-row.md` (ALIVE — KD-181 minted) |
| Post-ledger — powl2 chain | BK-PINIT/BK-1SAFE/BK-POWLV/H3/H4 planner2 chain | ALIVE | `receipts/bkpinit-stale-delete.md` (ALIVE — `:already_exists` init crash fixed) → `receipts/bk1safe-safeness.md` (ALIVE — boundary typed + court-pinned) → `receipts/bkpowlv-loop-verify.md` (ALIVE) → `receipts/bkpowlh3-walk-fix.md` + `receipts/bkpowlh4-pattern-fix.md` (ALIVE) |
| Post-ledger — bench gate | BK-GWSSKEP F1 bench-annotation close | CLOSED — ALIVE | `receipts/bkbgf-annotate.md` (ALIVE — BENCH-CLASS probe annotation on `pb4_merkle_dual.exs` timer.tc sites 255/266; bench-framework-gate exit 1→0; non-vacuity held: shim refused on a temp copy; relocated probe re-run exit 0) |
| Post-ledger — fence exemption | plug_status<500 crash-fence exemption + regression fix | CLOSED — ALIVE | `receipts/bkxprif-plug400-exempt.md` (ALIVE — deterministic HIGH regression flipped: typed 400 no longer swallowed by the crash-path fence, `lib/smalt/arm_gateway/router.ex:146`) → `receipts/bkxpriv-exempt-verify.md` (ALIVE — cross-suite verification of the landed exemption) |
| Post-ledger — citation fences | BK-CITEG fence + BK-CITEV verify | ALIVE | `receipts/bkciteg-citation-fence.md` (ALIVE) → `receipts/bkcitev-fence-verify.md` (ALIVE); census reconcile `receipts/bkcens6-wave6.md` (ALIVE — bkmon3r registered, BK-POWLH3-1 closed) |
| Post-ledger — standing contract | BK-STAND2/3/4 + BK-FMT + BK-100B hardening | PARTIAL_ALIVE | `receipts/bkstand2-normalize.md` (13/13 ad-hoc rows normalized, NO-STANDING 27→13) → `bkstand3-proseonly.md` (12 prose-only rows canonicalized, NO-STANDING 12→0) → `bkstand4-final-triage.md` (residue closed to a single honestly-typed extractor artifact) + `bkfmt-standing-norm.md` (PARTIAL_ALIVE) + `bk100b-standing-backfill2.md` (8 Class-C reds repaired, NO-STANDING 5→0) |
| Post-ledger — F1-A mirror | FOND planner/executor needs-at mirror closure | CLOSED — ALIVE | `receipts/bkf1a-needsat-mirror.md` → verify `bkfondv-f1a-verify.md` (PARTIAL_ALIVE) → closure `bkfondw-f1a-closure.md` (ALIVE); pattern companion `bkbmir3-mirror-wave3.md` (ALIVE — 25/25 jsonls snapshotted byte-identical, final census 0 untracked of 59) |

## Open residuals — KD register census (re-verified 2026-10-22, lane BK-FIN4)

Census method: `awk -F'|'` status-cell (`$(NF-1)`) extraction over every
`| KD-nn |` row in `docs/jira/v26.10.14/KNOWN_DIVERGENCES.md` — **178 rows
total** (mechanical count, not recalled; re-run at the BK-FIN4 refresh; was 177
at the BK-FIN3 refresh — KD-181 is the row minted since, KD-180 was minted and
closed in the same window; was 172 at the BK-FIN refresh; was 166/158 at
`receipts/bk10c-census-refresh.md`). Distribution (prefix classification on
the raw status cell — a naive substring scan over- and under-counts because
status prose embeds "OPEN"/"CLOSED" words):

- CLOSED (all faces: CLOSED-SIMULATED, CLOSED-WITH-RECEIPT incl. case-variant
  `CLOSED-with-receipt`, CLOSED-WITH-EVIDENCE, CLOSED-OBSOLETE, CLOSED):
  **166**
- OPEN (TYPED DISPOSITION): **6** — KD-168 (attestation cross-binding,
  environment-gated hardware-UNSUPPORTED, DO-NOT-FLIP registrar hold),
  KD-174 (Kafka Produce v3/magic-2; owner BK-122r; truth-cell reconciled
  two-layer by KD-174F), KD-177 (loopback-unwitnessable hardware-anchored
  trust class row), KD-178 (Web PubSub broker-restart vs Bandit child
  supervision split — registration completed by lane KD-N1), KD-179
  (sas_verifier inet_aton shorthand loopback literals — typed
  accepted-because-genuinely-loopback, PINION-WITNESSED registration row),
  KD-181 (Kafka Fetch-v0 legacy-face magic-2 verbatim-serve divergence,
  minted by lane KD-FV0 with a fresh wire witness).
- PINION / PINION-WITNESSED: **4** — KD-05, KD-101 (PINION); KD-159, KD-160
  (PINION-WITNESSED via `docs/jira/v26.10.21/receipts/bk48-pinion-witness.md`)
- ENVIRONMENT-PINION: **1** — KD-162 (`:msacc`/`runtime_tools.app` unusable on
  local OTP 29.1.2 install; environment, not a smalt divergence)
- UNSUPPORTED-BY-COST: **1** — KD-90 (affidavit wasm-engine seal latency,
  b3sum subprocess dominance, bench-pinned, typed disposition)

166+6+4+1+1 = 178, no skew; 0 duplicate ids. The 6 OPEN rows are
receipt-backed with owner + falsifier + next-action in the register; none is a
Gate-3 blocker per PRD §5 (KD-168/177 environment-gated; KD-174/181 have typed
owners in the kafka-parity lane; KD-178/179 are typed
registration/accepted-loopback rows). Census
lineage: `receipts/bk10c-census-refresh.md` (166/158) → KD-SYNC
`receipts/kdsync-pointer-sync.md` (167/159) → BK-PRD5 (171) → BK-FIN
(172/162/4) → BK-FIN3 (177/166/5) → this BK-FIN4 refresh (178/166/6). The
v26.10.22 pointer (`docs/jira/v26.10.22/KNOWN_DIVERGENCES.md`) names KD-181 as
highest minted and KD-182 as next mint id — consistent with the canonical
table.

## Seal inputs

| Input | State at BK-FIN4 refresh (2026-10-22) | Evidence |
|---|---|---|
| Court census 6/6 | **GREEN** — waves 4, 5 and 6 all census-green | `receipts/bkcens4-wave4.md` (ALIVE — census 6/6 on the sealed population); `receipts/bkcens5-wave5.md` (ALIVE — internal census exit 0 `Result: 5 passed`); `receipts/bkcens6-wave6.md` (ALIVE — bkmon3r registered into the census, BK-POWLH3-1 closed, reconcile wave 6 green) |
| witness-all freshness | **IN-FLIGHT (no green yet)** — BK-WIT4 landed PARTIAL_ALIVE, scope closed by BK-WIT4F; a green witness-all still does not exist | `receipts/bkwit4-witness-final.md` (PARTIAL_ALIVE — 111 real greens, 180 fails every one classified, zero real substrate/surface defects) + `receipts/bkwit4f-scope-fix.md` (ALIVE — scope pinned by name). Expected green `receipts/bk44-witness-all.md` — **absent at the BK-FIN4 refresh**; typed IN-FLIGHT, not smoothed |
| last full-suite line | **GREEN under contention, ALIVE close condition** — not yet quiescent x2 | `receipts/bkseal5-close.md` (**ALIVE** — full `mix test` verbatim `Result: 868/872 passed, Failed: 4 tests`; all 4 classified load-contention flakes, each green in isolation and a differently-shaped failing set across runs; census 6/6, invariant-gates 6/6, sleep-gate + court non-vacuous, docs-dod OK, kd-fence OK, receipt-index regenerated clean, kd_flip 0 eligible). Run was under load 42-121 (typed REFUSE quiesce attempt in-receipt) — coordinator owes a post-quiet x2 rerun at seal time |

## Path verification

All cited paths were `[ -f ]`-verified on disk at draft time (receipts, PRD,
charters, courts, gate scripts): 14/14 OK. Full per-path record in
`docs/jira/v26.10.22/receipts/bk53-finalrelease-draft.md`. BK-PRD5 refresh
(2026-10-22) re-verified newly cited paths; BK-FIN refresh re-verified
existence + standing line for every gate-row receipt (21/26 exist, 5 typed
MISSING). BK-FIN3 refresh (2026-10-22) re-verified every newly cited path at
use time. BK-FIN4 refresh (2026-10-22) re-verified every newly cited path at
use time: bkwit4-witness-final, bkwit4f-scope-fix, bkseal5-close,
bkcens6-wave6, bkgws7v-gate5, bkgwsq-discharge, bkgwsskep-wave-audit,
bkgwsskep2-wave-verify, kdfv0-row, bkbgf-annotate, bkb4r-sender-link,
bkb4rc-send-gate-court, bkb4rd-json-route-verify, bkb7cr-consume-scope,
bkmon3r-deadjoin-fix, bkmon5-metrics-verify, bkmon6-integrity-verify,
bkdrain3-sequencer, bkkfkcw-merged-verify, bkpinit-stale-delete,
bk1safe-safeness, bkpowlv-loop-verify, bkpowlh3-walk-fix,
bkpowlh4-pattern-fix — all `[ -f ]` OK (see
`receipts/bkfin4-refresh.md` for the command output). Still-typed-MISSING
expected receipts (each row types the gap, none smoothed): fr-snc-005,
fr-snc-006, bk44-witness-all, bk35-head-court-sweep, ttv7b-quiesced-flip,
bk53-finalrelease-seal, ttv5-store-partitioning.

## Seal condition

Flip DRAFT → FINAL when: every PENDING-GATE row above has a landed receipt with
mtime postdating this draft; receipt-index, docs-dod-check exit 0 re-confirmed
at seal time; tag `v26.10.22` cut on the sealed HEAD.
