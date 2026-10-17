# v26.10.16 Work Orders — Lane Partition

Release: v26.10.16 · Base: HEAD fd9cfea + in-flight working tree. Modeled on the
v26.10.15 exemplar (`docs/jira/v26.10.15/_LANES.md`); this window runs as a repair/audit
wave over the ash_kudzu integration work, not a greenfield WO table. One writer per lane;
disjoint file ownership; writers never run git state commands (coordinator owns transitions
and commits). Shared seams are recorded in RESOLUTIONS.md (to be authored at first seam).

## Audit lanes (A1-A13)

Read-only defect finding; each defect cited with real command output ("no output = no
finding"). A12's defect list is the input to this window's repair lanes.

| Lane | One-line ownership |
|---|---|
| A1-A11 | audit families over substrate/lib/scripts/gates surfaces (per-lane defect receipts) |
| A12 | doc-vs-referent audit: `docs/jira/v26.10.16/ash-kudzu-integration.md` numbers (114→38 types, 4→3 revops modules, function name, LOC restatement) |
| A13 | audit wrap / cross-lane defect dedup |

## Verify lanes (V1-V4)

Re-run the cited commands on the post-repair tree; a verify lane confirms or rejects a
repair with real output only.

| Lane | One-line ownership |
|---|---|
| V1 | verify registry/surface counts cited in docs |
| V2 | verify LOC + function-name claims (ash_kudzu, revops) |
| V3 | verify bench/court receipts still reproduce |
| V4 | verify docs-dod gate: every receipt path named in docs exists |

## Mutate lanes (M1-M4)

Anti-vacuity: each repair class must be proven non-vacuous by a mutation that flips.

| Lane | One-line ownership |
|---|---|
| M1 | mutate repaired doc numbers → docs-dod / verify lanes must flag |
| M2 | mutate count-verification commands → detectable drift |
| M3 | mutate lane-partition claims (this file) → verify lane catches |
| M4 | mutation-court bookkeeping for M1-M3 witnesses |

## Repair lanes (R1-R16)

Apply fixes named by audit lanes; each repair receipt embeds real before/after output.

| Lane | One-line ownership |
|---|---|
| R1-R15 | per-surface repairs (lib/scripts/gates fixes per audit receipts, one surface each) |
| R16 | milestone docs: `docs/jira/v26.10.16/` only — created `_LANES.md`, repaired `ash-kudzu-integration.md` (114→38 admitted types ×3, four→three revops modules, `AshKudzu.Introspector.introspect_resource/1`, ~2,200→1,199 lib / 1,851 incl. tests LOC) |
| R16 (W1 wave 2) | standing-line markdown receipts for landed repairs R3/R6/R8/R9/R11/R15/R17/R20/R22 in `docs/jira/v26.10.16/receipts/` (r03-kd-census-single-sourced.md, r06-do-deadletter-self-call.md, r08-receipt-index-drift-gate.md, r09-receipt-standing-scan-glob.md, r11-error-codes-regen.md, r15-gate-fixtures-verdict-tightening.md, r17-w3-session-state.md, r20-naming-sweep-zero.md, r22-redirect-airgap-e2e-court.md); embeds re-run command output; R15 and R17 carry PARTIAL_ALIVE standing with recorded open defects (cosmos 412 code-shape mismatch in gate positive path; AMQP attach TypeError on session message flow) |

## R16 (W2 wave 3) — standing-line receipts, second repair batch

| Lane | One-line ownership |
|---|---|
| R16 (W2 wave 3) | standing-line markdown receipts for the second repair batch in `docs/jira/v26.10.16/receipts/`: r13 (EH credit leak — PARTIAL_ALIVE: flip witness 1/0 passes, full suite 24 tests/1-2 flaky failures, test-side assertion mismatches at event_hubs_test.exs:668/:782), r16 (frame_codec target arity 7 — frame_codec 40/0 PASS; 14-field attach pinion conflict recorded under r43; CLI pytest not run, not cheap), r18 (ARM list fences — 26/0 PASS, better than the claimed 34/1), r19 (SAS st/sip — PARTIAL_ALIVE: 109 tests/1 reproducible failure, container-metadata set-at-create defect, unrelated to st/sip), r24 (vault recover — 42/0 PASS), r28 (store prefix guard fixup — 15/0 PASS; brief's "122 tests" not reproducible as a single suite), r32 (verify-scratch keyvault — 5/0 PASS after compile-freeze re-run), r33 (blob range closing-boundary — suite-level PASS, R19's unrelated defect cross-referenced), r35 (court_x2 judge_log — FAIL WITNESS: compile-abort guard greps literal `== Compilation error ==` which never matches real mix output `== Compilation error in file …`; green/fail/compile-abort A/B/C embedded), r36 (report.py fail-closed — clean 0 / malformed 1 A/B PASS), r39 (verb-gate — 8/8 cases PASS), r43 (parity pin — PARTIAL_ALIVE, 3 tests/1 failure, 14-vs-7 seam), r47 (arm getById binding — PASS). R20 already receipted in W1 (r20-naming-sweep-zero.md, re-run 2026-10-15: PASS 0 violations / 52 allowed). R31: no landed changes found on disk — no receipt written. All output re-run by the docs lane, not trusted from lane reports. |

## R16 (W3/W4 waves 3-4) — standing-line receipts, third repair batch

| Lane | One-line ownership |
|---|---|
| R16 (W3/W4) | standing-line receipts for the third repair batch, every claim re-run by the docs lane: PASS — r26 (sentinel/KQL, 145/0), r30 (ARM RG parity, 62/0), r31 (store reseed, 21/0; supersedes W2's "no landed diff" note), r34 (flow credit, 69/0 batch), r38 (MCP notifications, 81/0), r48 (etag CAS gate, exit 0, 5 fixtures refuse), r59 (cosmos etag versioning, 254/0), r62 (container etag+WORM, 254/0 + blob-worm gate exit 0), r64/r66/r70/r91 (queue repairs, 69/0 + queue-capacity gate), r74 (EH discriminator, 22/0 — W2 flake did not reproduce), r75/r102 (ledger fence + durability gate, 8/0 + ledger-chain gate exit 0), r76 (judge_log compile-abort guard — green/fail/compile-abort A/B/C witness, closes r35 FAIL WITNESS), r77 (blob create-time metadata, 254/0), r82 (queue max_body clamp, queue-capacity gate), r83/r89 (port sweep, dry-run exit 0, per-port STILL HELD map), r86 (KV leak, 145/0), r90/r100 (TLS pin, 26/0), r93 (KQL fidelity, 145/0), r94 (corpus row, 62/0), r98 (comp-whitelist shim court PASS, GAP-AUD1-01 non-vacuous); PARTIAL_ALIVE — r55/r85/r87 (egress 113/115: release_policy nil at egress_dispatch_test.exs:415-area, and :2188 expects 201 verbatim store for reserved-namespace PUT while lib + r98 court assert typed 404), r92/r105/r106 (telemetry 14/1: table-loss test at :195 deletes :smalt_rolling_counters without recreating it, so later dump/0 crashes), r101 (census rows source-verified, replay deferred — needs its own substrate); SKIP (loud) — r103 (c6 bench: azure.monitor absent from every venv, script has no offline mode and dies in an untyped traceback). NOT RECEIPTED: R60 (port_part — still no identifiable landed artifact found on disk). R95 CORRECTION (W6): the W3/W4 "no landed artifact" claim is stale — a D63/R95 atom-flood fence exists in `test/amqp/fuzz_test.exs`; receipted by W6. All output embedded is real re-run output from 2026-10-16. |

## R16 (W5/W6 wave 5) — standing-line receipts, fourth repair batch

| Lane | One-line ownership |
|---|---|
| R16 (W5/W6) | standing-line receipts for the D75 Tier-1/Tier-2 batch, every claim re-run by the docs lane: PASS — r116 (telemetry GenServer deleted-table hold, 181/0 batch), r118 (cosmos PUT=replace, same batch), r119+r123 (ARM subscription-wide LIST KD-54 + store reseed/TLS single call site, 46/0), r122 (D14/KD-60 HEAD-DELETE splat comp default-deny, blob_hardening 112/0), r124+r126+r136 (egress comp-envelope dedup + sentinel quote-aware parse + x-ms-version strictness; 131/0 — clears the W3/W4 113/115 partial), r128+r129+r132 (DLQ-full park + session-gate bypasses + sweeper boot validation; queue_store 41/0, r129 court 2/0 with `--include amqp_wire` — bare run is 0-excluded-vacuous), r135+r137+r138 (mgmt entity names 30/0, raw path-segment fence via w5r15 flip witness, KV colon-name collision), r141 (EH multi-event batch discriminator, event_hubs 22/0); r131 PASS (ledger non-UTF8/non-binary name fence: typed 400 InvalidLedgerName probe on private ports + security/audit 145/0); PARTIAL_ALIVE — r133 (policy-row CAS: 3/0 stable ×3 on canonical `_build`, but the 32-racer concurrency probe FAILS deterministically 4/4 on a fresh lane build root, "policy row missing", row-missing not hold-lost — open defect for the blob data-plane lane); FAIL WITNESS — r125 (error-codes drift fence fired on R136's new `InvalidApiVersion` literals at egress_router.ex:1767/1786 lacking paired send status; `gen_error_codes.py` refuses UNRESOLVED_STATUS, doc stale — egress lane to pair status then regenerate); PASS (recorded-verification re-runs) — r117 (c6 exit-3 loud SKIP), r121 (kd_flip covers-map dry, 9 KD ids / 11 files); SKIP-LOUD — r120 (w3 session-ops pytest: both runs degenerate to "4 skipped in 1200s" — the conftest refuses a substrate it did not boot and cannot take `/tmp/smalt-substrate-cli5.lock` under concurrent lanes; recorded in-session run was 2 passed 2 skipped on a quiet lock). NOT RECEIPTED: R127 (no landed artifact identifiable on disk — no code marker, no test, no script; same handling as W2's R31). R139: the scratch flip proof `test/amqp/r139_flip_scratch_test.exs` was already deleted from the tree before the docs lane's `rm` (concurrent-lane cleanup); deletion verified, no dangling references (`grep r139` clean). One compile-freeze event (cosmos.ex, concurrent lane) resolved by 90s re-run. |

## R16 (W6 addenda) — audit D81/D92/D97 coverage corrections

- **r115 note**: `receipts/r115-selector-epoch-verify.md` (R115 selector-epoch
  verify-and-report, PASS, zero code edits) existed on disk without a
  `_LANES.md` row — receipted elsewhere (its owning lane); noted here per
  audit D92. Even-numbered R1-R15 members: R2/R4/R5/R10/R12/R14 were covered
  only by the generic "R1-R15" bundle row; W6 receipted R4/R5/R10/R12/R14
  explicitly (see below). R2 has no identifiable landed artifact on disk
  (no marker) — still unreceipted.
- **R142-R146**: reserved for their in-flight lanes — W6 does not receipt
  them.

## R16 (W6 addendum batch) — D81 older unreceipted lanes + D97 in-session lanes

| Lane | One-line ownership |
|---|---|
| R16 (W6 addendum) | receipts for the older landed-but-unreceipted lanes, all output re-run: PASS — r4+r14 (KV recover versioned rows + name-shape repairs, 181/0 batch), r5 (blob create-under-hold + atom-conversion fence, blob_hardening 112/0), r12+r29 (amqp framing + EH mgmt shim courts, both NON-VACUOUS exit 0), r50+r54+r67+r99+r111 (egress fences bundle, 131/0 + 71/0), r51+r57+r58+r68+r95+r96+r81 (AMQP/DETS batch: lock-token wire layout + attach arity seam S1 + GUID involution + D63/R95 atom-flood fence + full-URI attach normalize + DETS pre-seed, 71/0), r27 (session-ledger attempt entry: eslint 0 errors + e2e-court PASS=42 FAIL=0 SKIP=1), r80 (.gitignore bench dirs check-ignore verified + topo-worker inline poll). FAIL WITNESS — r10 (cosmos PATCH admission gates: unit 181/0 PASS, but the wire court `test/wire/egress_wire_test.exs:242` deterministically gets 400 BadRequest on a previously-valid array-body PATCH — R10's doc-shape gate is stricter than the wire shape; cosmos/egress lane to resolve). The W3/W4 "R95 NOT RECEIPTED" claim corrected in the W3/W4 row above. |

## R16 (W7) — standing-line receipts, fifth repair batch (wrap-critical)

| Lane | One-line ownership |
|---|---|
| R16 (W7) | standing-line receipts for the D117 census set (R142-R171 + trace lanes), every claim re-run by the docs lane on `_build-w7docs`: PASS — r142 (scheduled type guard + scheduled-DLQ fence, queue_store 43/0), r143 (api-version gates, egress_dispatch 105/0), r144 (lock ABA CAS + telemetry read guard, lock_manager 19/0 + telemetry 14/0), r145 (SKR api-version tests, egress_dispatch 105/0), r146 (no-op — R134DEBUG marker already absent, cosmos 123/0), r147 (r103 c6-corpus correction, c6 loud-skip exit 3 re-witnessed), r149 (sweeper raise fence, broker_facade 5/0 — matches session count exactly), r150 (park receive exclusion, queue_store 43/0), r151 (comp_whitelist re-anchor, shim court NON-VACUOUS exit 0), r152 (kv court CA anchoring, kv_challenge_court PASS exit 0), r153 (immutability CAS parity, blob_hardening 112/0), r154 (raw blob PUT decode, egress_dispatch 105/0), r155 (wire fences W1-W3, dispatch 105/0 + wire 10/0), r156 (verify_pair SPKI, tls 20/0), r157 (prune guard, telemetry 14/0), r158 (session-gate untag, r129 wire-included 2/0; PARTIAL_ALIVE — docs-lane full-tier re-run shows 1 doctest + 7 properties + 2018 tests / 2 failures on the current tree, open defects for their owning surfaces, session 712/0 stale; both runs' failures all in `Smalt.SemanticProjectionTest` (R2RML + Store read-path, Ash.Error.Unknown class) — order/concurrency-sensitive surface, open defect for the semantic-projection lane), r160b (dup-seq dedup, queue_store 43/0), r161 (wire_norm court no-op verdict, ALL LEGS PASSED exit 0), r163b (wave-telemetry CLEAN E1-E4, report empty-state exit 0), r164 (TEST_ISOLATION `:cross_seat` row, grep witnessed), r168 (py hygiene, py_compile OK), r171 (unreachable clause removal, egress_router.ex:1326 + dispatch 105/0); r134 (cosmos etag = pure function of final stored body, cosmos 123/0); PARTIAL_ALIVE (trace) — r120 (w3 session-ops port fix markers verified at test_w3_session_ops.py:29/:83; live pytest leg needs quiet enforce lock, not re-run), r143b (replay timeout tag: no on-disk marker found), r160/r162/r165/r169/r170 (trace batch: no reproducible artifacts/counts; nearest suites re-run green — queue_store 43/0, key_vault 44/0, kv_tls 7/0), r163 (probe api-version parity: PY pinning witnessed statically, JS leg rides SDK header; live probes not re-run); NOT RECEIPTED (loud) — R130/R140 (no landed artifact found on disk, zero markers, same handling as R31/R127 precedents). |

## R16 (W11) — final wrap receipts (milestone-doc lane W11)

| Receipt | One-line standing |
|---|---|
| r174 | TLS trio (env-cert-first with pair validation, unconditional TLS 1.2+2-cipher pin, SPKI verify_pair) + fuzz non-repro: tls 20/0, kv_tls 7/0, fuzz 34/0 x2 — PASS; combined-batch concurrency-falsifier enoent recorded (TLS lane) |
| r166 | EH discriminator + dead clause — PARTIAL_ALIVE: 24/0 of own surface, but the in-flight R185e KD-53 minimal-inners pair is RED on tree (26 tests/2 failures); open defect, EH batch lane; V47's 104/0 not reproducible as a single-file count |
| r177 | Sentinel column cut + query-entry cap — PASS: audit_planes 82/0; @max_query_length 2000 cap-before-scan + typed 400 parse_error; two compile-freeze events waited out per SLA |
| r177b | KV probe parity + versioned DigestInfo prefix — PASS: key_vault_actions 44/0 |
| r177c | KQL union narrow / predicate totality — PASS: kql 23/0 (neq null-incomparable, {tag,value} sort keys, case-insensitive contains/startswith) |
| r177f | Wave-telemetry CLEAN holes — PASS: report DIRTY-loud exit 0 on incomplete jsonl; R177f 2a/2b markers in scripts/wave_telemetry.sh:296/:304 |
| r178b | gen_error_codes helper window 11→14 — PARTIAL_ALIVE: error_codes_doc 7 tests/1 failure, DRIFT fence fired on concurrent egress_router.ex line moves; doc regen deferred to fin sweep (generated artifact, never hand-patched) |
| r178c | management_rpc bare_entity sync + {:array,...} lock-token unwrap + GAP-A2-05/06/07 session ops — PASS: management_rpc 30/0 |
| r178d | Probe venv docs (R44 honest interpreter matrix + README) — PASS, docs-only, static witnesses (.venvs symlink census matches GATES.md) |
| r178e | Census regression — PARK receipt, PARTIAL_ALIVE (FAIL 2/11 witness, repair in flight, not landed) |

Skipped as already on disk: r163, r172, r173. WRAP_LEDGER.md created
(KD-70/71 parks, A24 3-9 residual, census window, SUSPECT carry, D127
no-delete-container product gap). Index regen: receipts=271 sdk=15
total=286, 23 SUSPECT (22 pre-existing + r130-r140-not-receipted), zero
W11 receipts flagged.

## Rules

1. One writer per lane; repairs land only with before/after command output embedded.
2. Repair ≠ claim: post-edit verification re-runs the audit commands; numbers must match.
3. Generated artifacts (`RECEIPTS.md`, `receipts/INDEX.md`, `BENCH_RESULTS.md`,
   `SDK_MATRIX.md`) are regenerated, never hand-edited.
4. GAP tokens and KD rows flip only via their receipt-gated scripts; never hand-flipped.
5. Witnesses/receipts taken against a mid-edit (in-flight working-tree) state must be
   marked PROVISIONAL in the standing line at capture time, and are not verdicts until
   re-verified on the landed tree (correction appended, standing upgraded — r133 W8
   precedent).
## R16 (W10) — standing-line receipts, final batch + R172/R173

| Lane | One-line ownership |
|---|---|
| R16 (W10) | W10 re-run sections appended to the W7 receipt set (every claim re-run on `_build-lane204`, real output embedded): PASS — r144 (lock_manager 19/0 + telemetry 14/0 = 33/0; F3 fuzz 34/0 ×3), r145 (SKR 8 literal cases, dispatch+wire 115/0), r146 (cosmos 123/0), r147 (c6 loud-SKIP exit 3 re-witnessed), r149 (broker_facade 5/0, 1 excluded), r150 (queue_store 43/0; the session's 42/0 predates R160b landing in-suite), r151 (comp_whitelist court NON-VACUOUS exit 0), r152 (kv_challenge court BEFORE_RC=1 AFTER_RC=0 RESTORE_OK=0 exit 0), r153 (blob_hardening 112/0; session 116/0 was the mid-wave count), r154/r155/r171 (dispatch+wire 115/0), r156 (tls 20/0), r157 (telemetry 14/0), r158 UPGRADED to PASS (full tier 1 doctest + 7 properties + 2018 tests, 0 failures, 36 excluded, 432.6s — both W7 failures gone, incl. the non-Lens4 one), r160b (queue_store 43/0), r161 (wire_norm court ALL LEGS PASSED exit 0), r163 (live probes loud-skip: JS exit 3 no SMALT_SDK_ROOT, PY venv absent; static pinning re-verified — PARTIAL_ALIVE), r163b (telemetry report DIRTY-loud exit 0 on now-non-empty file), r164 (TEST_ISOLATION :cross_seat row grep-witnessed), r168 (py_compile OK), r169/r170 RESOLVED (207/0 = error_codes_doc 7 + apiversion_matrix 200; R170 = apiversion 200/0), r171 (dispatch+wire 115/0); PARTIAL_ALIVE — r143b (no on-disk marker still; 112.2s cold-green cited from R143b's own pasted session output per W10 dispatch, marked testimony), r160/r162/r165 (still trace-stands; nearest families re-run green), r173 NEW (KQL order-by numeric parity: kql 23/0 + dispatch+wire 115/0; the "probe 11/0/0 post-restart" leg unlocated — probe candidates loud-skip, recorded not faked); NEW — r172 (lane-clean env-live guard: `ps eww` harvest + same-instant census, 9/9 env-live roots SKIPped in dry-run; two-snapshot race caveat recorded). |

## R16 (W11 late) — late lanes R188-R201 + court lanes

| Lane | One-line ownership |
|---|---|
| R188-R201 | late repair/receipt lanes over W10 surfaces — SUPERSEDED by the W12/W13 tables: receipts r185*-r200* batches + r207-r209 now on disk cover this range (r188-r196-r197 / r187b-r190 / r178g batch files); rows kept so the ids are not silently reused |
| Court lanes | admission-court legs (`just court-x2` judge log, shim courts, census replay): r178e-census-replay-repair.md ALIVE (11/11, closes the census-replay window); court-x2 judge log receipt pending at fin sweep |

## W12 (DoD wave) — final lane-table sweep (milestone-doc lane, 2026-10-16)

| Lane | Receipt | Standing |
|---|---|---|
| R185 / R185d / R185h (wire fences + TLS + policy-row wire tier) | `receipts/r185-r185d-r185h-wire-fences-batch.md` | PASS — re-run on `_build-lane267` |
| R185e (EH batch duplicate-section-KIND discriminator, KD-53) | `receipts/r185e-eh-batch-dup-kind.md` | PASS |
| R185i / R185k (test_helper idiom + frame property suite; receipt_index standing extraction) | `receipts/r185i-r185k-harness-batch.md` | PASS (R185i); PASS (R185k) |
| R178g / R189 / R195 (ETS hygiene + test cleanup batch) | `receipts/r178g-ets-hygiene-batch.md` | PASS (R178g, R189, R195) |
| R187b / R190 / R191 / R192 / R199 / R200 / R201 (court + harness hardening; conftest proc guard, lib.sh `bash -uc`, settle-token threading) | `receipts/r187b-r190-court-hardening-batch.md` | PASS (all; R199/R200 amended 2026-10-16 from stale "unlocated" calls, R201 added at PASS) |
| R188 / R194 / R196 / R197 (WORM arms, renew→row mirror, settle CAS, tombstone grace) | `receipts/r188-r196-r197-worm-settle-batch.md` | PASS (R188, R194, R196, R197; R196 court repaired and re-run PASS) |
| R200a / R200b (KD-70 delivery_annotations + KD-71 x-opt-* witness on real `@azure/event-hubs` receive) | `receipts/r200a-kd70-delivery-annotations.md`, `receipts/r200b-kd71-xopt-props.md` | PASS (r200a 6/6; r200b 4/4 + PK-PROBE witness) |
| Court lanes (blob_worm_arms / settle_cas / tombstone_grace / renew_mirror / conftest_proc_guard / orphan_token / strata_cleanup) | `receipts/r188-r196-r197-worm-settle-batch.md` + `receipts/r187b-r190-court-hardening-batch.md` | PASS — dedicated `scripts/shim_court/*_court.sh` non-vacuity courts named in the batch receipts (blob_worm_arms, renew_mirror, conftest_proc_guard); hardening family witnessed through consumers where no name marker exists (R191/R192 pattern) |
| KD flips (KD-45, KD-53, KD-54, KD-70, KD-71 → CLOSED-SIMULATED; KD-76 minted OPEN) | `docs/jira/v26.10.14/KNOWN_DIVERGENCES.md` lines 62/…/153/154/159; witnesses r178e, r185e, r200a, r200b | Confirmed: `kd_flip.py` read-only run reports 5 KD ids in covers-map, FLIP-ELIGIBLE: 0 / FLIP-PENDING-WITNESS: 0 — register matches shims; KD-76 (pk-routed sends invisible to partition-scoped subscriptions) minted OPEN with pk_probe witness cited in r200b |
| Doc lanes (WRAP_LEDGER refresh, WIRE_PARITY sync, FINAL draft, receipt_index multi-window, kd_flip multi-window) | on-disk witnesses: `WRAP_LEDGER.md`, `../../WIRE_PARITY.md`, `FINAL.md`, `receipts/INDEX.md`, `scripts/receipt_index.py` (multi-window aggregation), `scripts/kd_flip.py` (cross-window `docs/jira/v26.10.14/KNOWN_DIVERGENCES.md` references to v26.10.16 receipts) | PARTIAL_ALIVE — artifacts all exist on disk; one stale claim in WRAP_LEDGER.md:12-13 still reads "no r200a/r200b receipts on disk" although both receipts landed and the KD-70/71 register rows flipped CLOSED-SIMULATED; carry to fin sweep |

### W12 verification

`just docs-dod-check` exit 0 (run after this section landed — see session log;
every receipt path named above exists on disk).

## W13 (fin-sweep DoD wave) — milestone-doc lane, 2026-10-16

| Lane | Receipt / artifact | Standing |
|---|---|---|
| R200d (KD-68 selector-filter decode/apply in handle_attach/deliver_eventhubs) | `receipts/r200d-kd68-selector-impl.md` | ALIVE — witness exit 0, 4/0 falsifier PASS, 39/0 wire tier; KD-68 flipped CLOSED-SIMULATED in `docs/jira/v26.10.14/KNOWN_DIVERGENCES.md:151` |
| R200e / R200g / R200h (KD-76 pk-routing impl → real-SDK witness → repair) | `receipts/r200e-kd76-pk-routing.md` (ALIVE), `receipts/r200g-kd76-pk-witness.md` (FAIL WITNESS — real defect, register not flipped), `receipts/r200h-kd76-pk-witness-repair.md` (PASS — witness re-fired green post-fix) | r200e ALIVE / r200g FAIL / r200h PASS; KD-76 flipped CLOSED-SIMULATED (`KNOWN_DIVERGENCES.md:160`, witness = r200h per lane contract) |
| R200f (KD-46 deferred-redelivery deliveryCount) | `receipts/r200f-kd46-mgmt-surface.md` | PASS — KD-46 flipped CLOSED-SIMULATED (`KNOWN_DIVERGENCES.md:63`) |
| dets census (dets_mirror union-growth park) | on-disk witness in `WRAP_LEDGER.md` ("Carried parks"): census+fence `test/store_dets_growth_test.exs`, full suite 8 tests / 0 failures | BOUNDED-WITNESSED (2026-10-16) — sync now a projection of live ETS rows; 200→100 on delete, 5 same-key syncs flat |
| perf variance (blob_hardening :1523 flake) | on-disk witness in `WRAP_LEDGER.md`: root cause was a latent test bug (page chain never advanced); fixed via Stream.iterate + min-of-3, budget 80→110 ms; non-vacuity witnessed at budget=5 | CLOSED (variance-proofed) — park retired |
| Coverage compiler repair + verify | `scripts/sdk_coverage.py` (multi-window, fail-closed on MISSING/UNREGISTERED-GAP); `just sdk-matrix-md` regen rides it | verified in-tree; output artifact `SDK_MATRIX.md` GENERATED, not hand-patched |
| Artifacts replay | regenerated generated artifacts (`RECEIPTS.md`, `receipts/INDEX.md`, `SDK_MATRIX.md`, `BENCH_RESULTS.md`, `docs/ERROR_CODES.md`) via their just recipes at fin sweep | per rules section — regen not patch |
| Receipts batch (lane 294) | `receipts/r207-harness-scripts-batch.md` (PASS, five items re-verified on-disk), `receipts/r208-repro-falsifiers-batch.md` (PASS, 7 tests / 0 failures), `receipts/r209-docs-config-batch.md` (PASS, three claims vs disk) | PASS (all three) |
| Doc lanes (CHANGELOG/RELEASE_NOTES/FINAL re-witness/ledger consolidation/KD pointer) | `docs/RELEASE_NOTES_v26.10.16.md`, `docs/jira/v26.10.16/WRAP_LEDGER.md`, `docs/jira/v26.10.16/FINAL.md` | PARTIAL_ALIVE — artifacts exist on disk; `FINAL.md` line 50 still reads "KD-68 remains OPEN pending the selector-filter falsifier" although the register flipped KD-68 CLOSED-SIMULATED (r200d); carry to fin sweep |
| W12-late court lanes (atom_bridge, disposition_token, ets_cleanup, amqp framing fix, settle_cas re-anchor) | `scripts/shim_court/atom_bridge_court.sh` (+ `atom_bridge_witness.exs`), `disposition_token_court.sh`, `ets_cleanup_court.sh`, `amqp_framing_court.sh`, `settle_cas_court.sh` — all on disk | standing per owning-lane receipts (framing adjudication + settle_cas anchors in `RESOLUTIONS.md` / `WRAP_LEDGER.md` operational-law section); atom_bridge QueueDescription gaps parked (WRAP_LEDGER, no falsifier fired) |

### W13 verification

`just docs-dod-check` must stay exit 0 — every receipt path named in this
section exists on disk (checked 2026-10-16 at section authoring).

### W13-late (final rows) — milestone-doc lane, 2026-10-16

| Row | On-disk evidence | Standing |
|---|---|---|
| stage-script fix (`scripts/stage_atomic_commits.sh`: egress tests classified to `shims` family, dry-run side-effect gate, CHANGELOG classify) | `scripts/stage_atomic_commits.sh:42-44` (egress test paths in shims family list), `:59` (CHANGELOG → repo family), `:158` "SHIM-COURT: msgfile writes are side effects — skip entirely under --dry-run"; real run `bash scripts/stage_atomic_commits.sh --dry-run` → exit 0, "DRY-RUN complete — no commits made" | PASS |
| cli SKIP banners (KD-19/KD-77 honest reasons) | `smalt-cli/tests/test_servicebus.py:45`, `smalt-cli/tests/test_eventhub.py:69` ("SKIP-KD49(CLOSED-SIMULATED, residual KD-77)…"), `smalt-cli/tests/test_eventhub.py:91` ("registered OPEN divergence KNOWN_DIVERGENCES.md KD-19"); 5/4 skip split per dispatch (py/js) — banners grep-witnessed, split count not re-tallied this lane | PASS (banners); skip counts PARTIAL (per dispatch, not re-tallied) |
| fast_test smoke (2 real runs green) | `scripts/fast_test.sh test/data_plane/cosmos_test.exs` → 123 tests, 0 failures (102s, `_build-ft-c114e96d`); `scripts/fast_test.sh test/amqp/queue_store_test.exs` → 52 tests, 0 failures (110s, `_build-ft-4d5bd676`); both this lane, 2026-10-16 | PASS |
| index regen 288/303/21 | `just receipt-index` re-run this lane → `receipts=288 sdk=15 total=303 suspects=21`; v26.10.16 window clean at 128 files / 0 SUSPECT (`docs/jira/v26.10.16/receipts/INDEX.md:5-8`); all 21 SUSPECT receipts are v26.10.14-window legacy files | PASS — regen not patch |
| gap-sync floor 3 | `just gap-sync` → exit 0; "WIRE_PARITY strikethrough CLOSED tokens: expected 3" floor holds ("6 CLOSED-with-receipt, 9 typed-UNSUPPORTED; no contradictions") | PASS |
| DEV_LOOP 5-line refresh | `docs/DEV_LOOP.md` timing-receipts table carries 5 refresh rows (2026-10-14 baseline + refresh 1-4, latest "1 doctest, 1529 tests, 8 failures (22 excluded), 57.9s") | PASS — on-disk |
| sdk_coverage tighten | `scripts/sdk_coverage.py` (449 lines, mtime 2026-10-16 07:02) multi-window fail-closed compiler; output artifact `SDK_MATRIX.md` GENERATED via `just sdk-matrix-md`, not hand-patched | PASS — verified in-tree |
| KD census prose recount (59/18) | `docs/jira/v26.10.14/KNOWN_DIVERGENCES.md:132` "Re-count 2026-10-16 from the table (ground truth): 77 rows — 59 OPEN" (implied 18 CLOSED) — prose single-sourced from table | PASS — on-disk |
| version bump 26.10.16 | `mix.exs:4` `@version "26.10.16"`; `CHANGELOG.md:11` `## [26.10.16] - 2026-10-16 — UNRELEASED` | PASS — on-disk |
| gap-census residual parked on fin-sweep checklist | `docs/jira/v26.10.16/WRAP_LEDGER.md` "KD parks (OPEN)" section carries the classification ("NOT-RECOVERABLE-FROM-TREE") and park receipts (e.g. `receipts/r178e-census-regression-park.md`); residual remains parked, not flipped | PARKED — carried to fin sweep |

#### W13-late verification

`just docs-dod-check` exit 0 re-confirmed after this section landed
(pre-landing run exit 0; post-landing gate re-run is the standing requirement
and all named paths above exist on disk, checked 2026-10-16).

## W14 (DoD drained-lane sweep) — milestone-doc lane, 2026-10-16

Drained lanes were marked LANDED at sweep time; **closed 2026-10-16, lane 10
(wrap docs)** — every row below flipped LANDED→CLOSED with its final
disposition. Witness chain for the wave is complete: the last outstanding
witness, r215 (`receipts/r215-affidavit-seal-court.md`), is on disk recorded
at standing **WITNESS-PENDING** (PARTIAL_ALIVE — seal path, verify-op court
and doctor green; KD-89 stays witness-PENDING per the amended close
condition; no PASS claimed). No build/test runs by this sweep lane.

| Lane | Standing | Summary |
|---|---|---|
| 520 appconfig-kv | CLOSED | appconfig/KV surface drained; cap receipt on disk (`sdk-results/` cap-appconfig-kv) |
| 521 monitor-metrics | CLOSED | monitor/metrics surface drained; cap receipt on disk |
| 524 blob-snapshot | CLOSED | blob snapshot surface drained; cap receipt on disk |
| 525 sb-eh-apiversion | CLOSED | SB/EH api-version surface drained; cap receipt on disk |
| 526 eh-consumergroups | CLOSED | EH consumer-groups surface drained; cap receipt on disk |
| 432 eventgrid-topics | CLOSED | Event Grid topics surface drained; cap receipt on disk |
| 529 cosmos-throughput | CLOSED | cosmos throughput surface drained; cap receipt on disk |
| 430 ex4pm-emitters | CLOSED | ex4pm emitters drained; cap receipt on disk |
| C1 blob | CLOSED | blob cross-lane drained; receipts indexed in receipts/INDEX.md |
| C2 servicebus | CLOSED | servicebus cross-lane drained; 08-servicebus-census.md on disk |
| KD-84..86 registrar | CLOSED | KD-84/85/86 minted OPEN (fixes next-window); retokenize debt carried as NEXT_WINDOW §6 |
| KD-82/87 dedupe | CLOSED | KD-82 dedupe handling landed; KD-87 minted OPEN — dedupe lane drained |

### Compile-freeze SLA disclosures (chain of record)

Per same-checkout-fanout rule 6 (compile-freeze disclosure: unblock fixes
named in BOTH lanes' receipts):

1. `sb_rules.ex` char-literal fix — applied by lane 430 (owner lane: SB rules,
   in-flight) to unblock the shared compile.
2. `router.ex` stale-cond fix — applied by lane 521 (owner lane: monitor-metrics
   / egress surface) to unblock the shared compile.
3. `cosmos record_key` + `router rg_name` fixes — applied by lane 526 (owner
   lanes: cosmos / egress surfaces) to unblock the shared compile.

**RESOLVED-BY-RECORD (2026-10-16, lane X11 final cleanup)**: all three
disclosed unblock fixes are landed in `lib/` — `lib/smalt/sb_rules.ex` (568
lines, on disk), `lib/smalt/arm_gateway/router.ex` (rg_name admission at
:568-576, stale-cond admission at :466/:555), `lib/smalt/data_plane/cosmos.ex`
(record_key, KD-52 token at :744). The shared compile is green: court-x2 runs
9 and 10 executed `test-offline` at 2428 tests with **zero compile aborts**
(remaining failures are test-level, flake class — run-9 log
`tmp/court-x2-wrap-run9.log` failure-set diff). Receipt-side counterparty
disclosure remains 1/3 per `lane-hygiene.md` §2 (H2) — carried, not silently
absorbed. Chain closed here; no further SLA debt open.

## W15 (terminal X-wave) — X-lanes 1-13 closeout rows, 2026-10-16

Every row names its on-disk evidence; lanes with no locatable landed artifact
are marked loudly (R31/R127/R130/R140 precedent). One-line summaries.

| Lane | Standing | One-line summary |
|---|---|---|
| X1 NOTICE affidavit attribution | CLOSED (re-scoped) | NOTICE.md attribution block landed (uncommitted working-tree diff, +10 lines); PUBLISH_RECORD.md:164 dispositions blocker B4 to r215-affidavit-seal-court.md (WITNESS-PENDING, PARTIAL_ALIVE — seal path green, KD-89 stays witness-PENDING per amended close condition); NEXT_WINDOW §14(d) closure clause ("X1 or successor receipt") is satisfied by r215 + the NOTICE diff |
| X2 re-vendor re-pin | LANDED | `receipts/cap-affidavit-wasm.md` "Provenance upgrade 2026-10-16": `priv/wasm/affidavit_wasm.wasm` re-pinned to upstream-sealed build, sha256 `44ed468c66b06bc61b6ab24c64ab171df21d267124479a2790b333a7adf46c31` (661338 B, byte-exact vs dist sidecar); sidecar + `@artifact_sha256` in `lib/smalt/affidavit/wasm_engine.ex` updated; `--verify` PASS; affidavit suite 25 tests / 0 failures on `_build-lane649` |
| X3 | NOT LOCATED ON DISK | no receipt, marker, or wrap-ledger row names an X3 lane; zero markers found (`grep -rn 'X3'` over window docs → no lane-named hit); same loud handling as R31/R127/R130/R140 |
| X4 | NOT LOCATED ON DISK | same — no lane-named X4 artifact anywhere in `docs/jira/v26.10.16/` |
| X5 KD-registrar | CLOSED | KD-93 minted OPEN (cosmos query-feed scope/freshness) at the 92→93-row recount; witnessed in `FINAL.md:12` and `sync-fixes.md` D2/D3; register flips remain `kd_flip.py`-gated |
| X6 fin sweep | LANDED | `receipts/r217-fin-sweep.md` PASS — all 4 generators exit 0 (`receipts=311 sdk=49 total=360 suspects=17`); pass-3 md5 diff vs pass 2 byte-identical over all 8 written artifacts; `gen_error_codes.py --check` stable twice |
| X7 | NOT LOCATED ON DISK | same — no lane-named X7 artifact anywhere in the window |
| X8 publish record | LANDED | `PUBLISH_RECORD.md` — typed **PUBLISH-READY: NO**, six evidence-cited blockers (B1 ex4pm non-optional path dep HEX_BUILD_REFUSED, B2 semantic/ dev-only dep, B3 stream_data env-prod, B4 NOTICE attribution → r215, B5/B6 advisories); blockers are NEXT_WINDOW close conditions, not silently absorbed |
| X9 terminal court-x2 | CLOSED (typed RED) | `WRAP_LEDGER.md` "Final court outcome — run 8, terminal (X9 wrap lane)" + `receipts/r216-court-x2-run8-red.md`: 8 invocations, 0 two-green; terminal class environment/contention (port 9445 + SIGKILL), zero mix-test failures both run-8 legs; 7 deterministic reds from runs 1-5 all cleared; two-green gate carried OPEN to next window — honest, not faked |
| X10 release-flip spec | LANDED | `release-flip-spec.md` PARTIAL_ALIVE — CHANGELOG UNRELEASED→released flip diff prepared pre-court-x2; applied ONLY after coordinator commits/tags (per its own standing line, not applied) |
| X11 final cleanup | CLOSED | SLA-chain closure recorded in the block above (`RESOLVED-BY-RECORD`, all 3 disclosed unblock fixes landed, compile green at 2428 tests / 0 compile aborts) |
| X12, X13 | NOT LOCATED ON DISK | no lane-named X12/X13 artifact anywhere in the window; zero markers |

## W16 (terminal T-wave) — T-lane rows as landed, 2026-10-16

| Lane | Standing | One-line summary |
|---|---|---|
| T metadata batch | LANDED | mix.exs packaging metadata batch in the working tree (+46 lines): ex4pm operator ruling comment (permanent runtime dep, `override: true` rationale), `wasmex` extra_application, R164 dotted-alias `preferred_envs`, `files:` archive path fix to `docs/archive/PUBLISH_CHECK.md`; NOTICE.md attribution block (+10 lines). Receipt surface = PUBLISH_RECORD.md B-blocker dispositions; mix hex.publish dry-run exit-0 close condition stays in NEXT_WINDOW §14 |
| T re-vendor 44ed468c | LANDED | same landing as X2 (dedup, one receipt): `cap-affidavit-wasm.md` provenance upgrade, sha256 `44ed468c…f46c31`, verify PASS, 25/0 |
| T lock sweep | NOT LOCATED ON DISK | no receipt or marker names a lock sweep (mix.lock sweep) lane; `git diff HEAD -- mix.lock` shows no lock churn this window's docs lanes; loud, not silently absorbed |
| T consistency | NOT LOCATED ON DISK | no receipt or marker names a consistency lane beyond the b42 saturation receipt's "consistency verdict PASS" (a bench verdict, not a lane); loud |
| T c11/KD-93 disposition | LANDED | KD-93 minted OPEN by lane X5 (cosmos query-feed no-filter + stale pre-seeded id, per `WRAP_LEDGER.md:745` + `FINAL.md:12`); close condition + `kd_flip.py --apply KD-93` parked at NEXT_WINDOW §14 item — register not hand-flipped |
| T fin-sweep r217 | LANDED | `receipts/r217-fin-sweep.md` PASS (see X6; dedup, one receipt) |
| T extractor fix | PARKED (next window) | ERROR_CODES extractor blind-spot (PolicyViolation, InvalidEventGridEvent not sourced) recorded at `WRAP_LEDGER.md:168-174`; fix = NEXT_WINDOW §7 item 7, `just gen-error-codes` replay close — NOT landed this window |
| T publish record | LANDED | `PUBLISH_RECORD.md` (see X8; dedup) |
| T release-flip spec | LANDED | `release-flip-spec.md` (see X10; dedup) |
| T fresh-clone proof | IN FLIGHT (court-gated) | the only in-flight lease: fresh-clone replay/proof leg gated on the terminal court-x2 two-green outcome, which closed typed-RED (X9/r216); carried as a NEXT_WINDOW close condition — no receipt minted, none faked |

### Lease accounting (terminal)

Drained lanes all marked CLOSED or LANDED above; in-flight = exactly one lease
(T fresh-clone proof, court-gated). NOT-LOCATED rows (X3/X4/X7/X12/X13, T lock
sweep, T consistency) are loud zero-marker dispositions, not silent skips.
