# 00-MASTER-PLAN — v26.10.18 test-surface rewrite (post-attempt-5)

Consolidation of 19 rewrite drafts in this directory. Input: all 19 drafts
read in full; `docs/jira/v26.10.17/FLAKE_LEDGER.md` (F1-F17); tree at HEAD
`885c451`, frozen. Plan audience: 20 implementation agents, post-attempt-5.
No edits to `test/`, `lib/`, or any draft; this file is the execution order.

---

## 1. Consolidation map

### 1.1 Draft → file coverage

| Draft | Files covered | Notes |
|---|---|---|
| foundations.md | mix.exs, test/test_helper.exs, test/support/{assert_eventually,store,env,case,singleton}.ex | P0 prerequisite; nobody else may land test/support before it |
| corpus-compliance.md | test/corpus/helper.exs, corpus/shacl_fuzz.exs, corpus/tags_normalization.exs, compliance/{c1_arm,c3_cosmos,c4_blob}.exs | canonical on-disk draft for the c-family scaffolding |
| c567.md | compliance/{c5_servicebus,c6_oauth,c7_events}.exs + Lifecycle.save_envs/restore_envs/uid | c6 is cosmetics-only |
| amqp.md | test/amqp/{fuzz,broker_facade,flow_credit,queue_store,event_hubs}_test.exs | self-contained; depends only on AssertEventually |
| fence10-ratio.md | test/affidavit_wasm_failclosed_test.exs (fence 10 block only) + FLAKE_LEDGER F6 flip | includes §1: fuzz atom fence already retired (885c451) |
| store-lro-wasm.md | store_dets_test (churn), lro_test (sweeper), arm_error_corpus (poll), affidavit_wasm_failclosed (§4), data_plane/blob_hardening (perf manifest) | §3 and §4 overlap other drafts — see 1.2 |
| apiversion-refusal.md | apiversion_matrix_test, wire_tier_refusal_sweep_test, arm_error_corpus_test, arm_cors_test (none), smalt_arm_gateway_test + new test/support/route_cites.ex | cite system swap |
| auth-wire-egress.md | auth_enforce_test, egress_dispatch_test, kd79_blob_apiversion_wire_test, eventgrid_{topics_arm,conformance}_test, mix_auth_scope_test (none), data_plane/blob_hardening_test (non-perf) + new test/support/wire_helpers.ex | largest single draft |
| assert-eventually.ex.md | new test/support/assert_eventually.ex | module of record, smoke-verified |
| sleeps.md | 29 fixed-sleep sites in 15 test files (A/B1/B2 classes) | inventory + per-site drafts |
| lib-sleeps.md | 6 lib/ sleep sites | superseded in part by lib-redesign-wasm-lro.md |
| lib-redesign-wasm-lro.md | lib/ WasmEngine supervisor + LRO Notifier redesign | changes the fence-10 subject; see 1.2 R4 |
| NO-SLEEP-DOCTRINE.md | doctrine + sleep-leak gate (scripts/sleep_gate.py seed census) | Law 3 gate is a new artifact |
| budget-gate.md | test/support/budget_formatter.ex, scripts/test_budget_gate.py, justfile.d/28-test-budget.just, docs/jira/v26.10.18/test_budgets.json | consumes `:stress` tag |
| stress-tier.md | `:stress` tag introduction, test_helper exclude, justfile.d stress stage | its test_helper diff = foundations §2 |
| gates-python.md | smalt-cli/tests/conftest.py, test/sdk-python/{run,run_ledger,run_atlas}.sh, py_auth_keyvault.py, py_servicebus.py, workspace e2e-court.mjs (optional) | non-ExUnit tiers |
| js-harness.md | test/sdk-smoke/{run,census-run,eh-run}.mjs, test/sdk-full/*.probe.mjs + ts-run.mjs, test/sdk-python/run.sh + boot_substrate.py | node/python harness teardown |
| e2e-wire.md | e2e s6/s9 + wire/{egress,amqp,arm}_wire_test.exs, runtime_contracts_test, zero_drift_serialization_test + new test/support/port_env.ex + test/e2e/lib.sh | D1-D4 |
| mcp-ash-misc.md | mcp_test.exs, ash_extension_test.exs, lro_test.exs (backdate class), trust_profile_deployment_test.exs | misc sweep enumeration |

### 1.2 Dedup overlaps and resolutions (binding for implementers)

R1. **AssertEventually has four competing drafts.** Canonical:
    `assert-eventually.ex.md` (only one with a verification receipt).
    `foundations.md` §3.1 already states this precedence. `corpus-compliance.md`'s
    `assert_eventually!/3` is NOT landed; its `quiescent_read` lands as
    `SmaltTest.Store.quiescent_read/2` (foundations §3.2). `sleeps.md`'s
    truthy-poll variant is NOT landed; its genuine addition,
    `eventually_stays/3` (B2 absence-check class), lands as a second function
    on the canonical module. `store-lro-wasm.md` §3's macro form is NOT
    landed — its contract (rescue scope exactly `[ExUnit.AssertionError]`,
    re-raise last error) is absorbed into the canonical module's
    immediate-fail arm semantics. One module, one contract.

R2. **Env save/restore has five spellings.** Canonical:
    `SmaltTest.Env` (foundations §3.3: `with/2` + `put_restored/1`, `:__unset__`
    sentinel). Fold in e2e-wire's `PortEnv` nil-preservation (delete_env when
    prev unset — Env already has this via the sentinel) and c567's
    `save_envs/restore_envs` token form (subsumed by `put_restored/1` for
    setup-form use; the opaque-token form is not needed once Lifecycle
    helpers land). `auth-wire-egress.md`'s `Wire.save_restore` macro and
    `Wire.pin_ports!` become thin wrappers over `Env.put_restored/1` or are
    dropped in favor of it. One module (`SmaltTest.Env`), not five.

R3. **resilient_clear canonical location: `SmaltTest.Store.resilient_clear/1`**
    (foundations §3.2, built on AssertEventually). corpus-compliance's
    `Corpus.Helper.resilient_clear/1` becomes a delegating shim; c1/c3/c4
    private copies deleted; auth-wire-egress's `Wire.resilient_clear!` also
    delegates. The c3 missing-monitor-wait divergence (a real defect
    corpus-compliance logged) closes by construction.

R4. **Fence-10 conversion: `fence10-ratio.md` is canonical** (paired rounds,
    min-of-5, sleep-free baseline, bound 3.0, vacuity probe mandatory).
    `store-lro-wasm.md` §4 (control×ratio + 250 ms floor) is the fallback
    only if the paired-baseline probe shows the baseline leg is not
    sleep-free-by-construction; do not land both. Dependency note: if
    `lib-redesign-wasm-lro.md` Part 1 (supervised WasmEngine) lands, fence 10
    becomes STRUCTURAL (zero sleeps in the engine) and the ratio fence is
    not landed at all — the two drafts are alternatives, sequenced so the
    coordinator picks exactly one path per window.

R5. **lro_test.exs elapsed-delay sites (144/338/402/651/672/701/734/1147) have
    two competing treatments.** Resolution: **backdate `startedAtMs`**
    (mcp-ash-misc §3) wherever the test itself seeds the op record; **poll
    via AssertEventually** (sleeps.md A1) only where the op is created
    through the wire and the test cannot author the record. Rationale:
    backdating has a zero-width race window; polling has a bounded one. The
    per-site assignment is a batch-4 implementer decision, disclosed in the
    receipt per site.

R6. **lro_sweeper lib change appears twice.** store-lro-wasm §2 (`name:` opt +
    `tick_ms: :manual`) is the landed form; foundations §3.4
    `SmaltTest.Singleton` covers only the general named-instance case and
    lands with P0 but the sweeper consumes §2's direct form.

R7. **run.sh boot/cleanup has two drafts.** js-harness §4a and gates-python
    D4 both rewrite `test/sdk-python/run.sh`. Same target shape (bounded
    liveness poll + `9>&-` + typed SUBSTRATE_DIED/TIMEOUT); assign to ONE
    lane (gates-python lane, which covers run_ledger/run_atlas too);
    js-harness lane skips run.sh and owns the node harnesses + boot_substrate.py.

R8. **start_supervised! conversions are consistent** across corpus-compliance,
    auth-wire-egress, mcp-ash-misc, amqp §3.3 — no conflict; the shared
    helper question resolves to plain `ExUnit.Callbacks.start_supervised!/1`
    plus `SmaltTest.Wire.start_wire_tree/1` only where a two-router tree is
    needed (eventgrid pair). `Wire` shrinks to: `start_wire_tree/1`,
    `http_request/4`, `get_free_port/0` (e2e-wire D4 moves free_port here),
    thin delegates to Env/Store.

R9. **`get_free_port/0` census (e2e-wire D4):** 10+ private copies collapse
    to `SmaltTest.PortEnv.free_port/0`. Landing home: `test/support/port_env.ex`
    may merge into `env.ex` as `SmaltTest.Env.free_port/0` if the coordinator
    prefers one file — either is fine, pick once at B0.

R10. **shared-file seam `test/test_helper.exs`:** foundations (exclude list +
     Lifecycle move + registries) and c567 (save_envs/uid — superseded by
     Env, so only `uid/1` remains) both touch it. c567's `uid/1` lands in the
     same B0 atomic test_helper edit. One lane owns test_helper per batch.

### 1.3 Conflicts requiring coordinator assignment (do not self-resolve)

- `test/arm_error_corpus_test.exs` is claimed by THREE drafts: apiversion-refusal
  (cite system), store-lro-wasm §3 (poll migration), assert-eventually collapse
  #2, plus sleeps.md B1 (`:477` wait_for_fresh_window is KEEP). Assignment:
  store-lro-wasm §3 is the owner (mechanism, ledger-ranked P5); apiversion-refusal's
  cite changes apply in the SAME batch as a second pass after the poll
  migration is green (batch 6, same file, sequential not concurrent).
- `test/data_plane/blob_hardening_test.exs` claimed by auth-wire-egress §3.7
  (non-perf faces) and store-lro-wasm §5 (perf manifest). Complementary by
  construction (auth-wire-egress EXCLUDES the perf test; store-lro-wasm
  touches ONLY the perf test). Both may run in the same batch with disjoint
  hunks; both name the exclusion in receipts.
- `test/affidavit_wasm_failclosed_test.exs`: fence10-ratio.md owns fence 10;
  sleeps.md A5 owns `:42`/`:71` (typed_start). Disjoint line ranges; same
  batch OK with per-hunk disclosure.

---

## 2. Prioritized application order

Rank = FLAKE_LEDGER recurrence, then court-stage criticality
(corpus/amqp wire surfaces first — they carry the receipted verdict pins —
then mechanisms, then foundations consumers, then cosmetics).

| Batch | Contents (drafts) | Ledger driver | Why here |
|---|---|---|---|
| B0 | foundations P0: mix.exs elixirc_paths, test_helper (exclude `:stress`, Lifecycle move, registries), test/support/{assert_eventually,store,env,case,port_env,singleton}.ex per R1/R2/R3, c567 `uid/1` | all | prerequisite; zero behavior change by itself |
| B1 | corpus-compliance (helper shim + shacl_fuzz + tags_normalization + c1/c3/c4 scaffolding) | F2-F5 (recur 1, corpus stage) | corpus is the court's first stage; the c3 divergence is a live defect |
| B2 | amqp.md all five files | F17 (wire/amqp stage, OPEN-ROTATING) + attach-arity/SASL pinion surfaces | amqp wire tier is court-critical; pinions preserved verbatim |
| B3 | fence10-ratio.md + sleeps.md A5 (same file, disjoint hunks) | F9 (recur 3, PERSISTENT-FLAKE) | highest recurrence in the ledger |
| B4 | store-lro-wasm §1 (dets churn) + §2 (sweeper ownership + lib 1-liner) + mcp-ash-misc §3 (lro backdate) + sleeps.md A1/A2/A3/A4/A6/A7 + B2 sites (eventually_stays consumers) | F11, F12-adjacent, F14 | LRO/store contention class |
| B5 | auth-wire-egress (wire_helpers, egress_dispatch, eventgrid pair, kd79, blob_hardening non-perf) + e2e-wire D1/D4 | F10 (recur 2+) + leak-batch residue | auth flatten is largest; lands after its resilient_clear dependency (B1) exists |
| B6 | apiversion-refusal (cite system) + arm_error_corpus second pass + mcp-ash-misc §1/§2 + trust_profile async flip | F15 cite-drift (recur 2, CLOSED — lock the mechanism) | cite-system swap is the recurrence-prevention tier |
| B7 | gates-python D1-D7 + js-harness (node harnesses, per R7) + e2e-wire D2/D3 + stress-tier tagging + budget-gate | T1 determinism; non-ExUnit tiers | harness tier; budget gate needs `:stress` from B7's stress tagging (same batch, stress first) |
| B8 | NO-SLEEP-DOCTRINE law-3 sleep gate + lib-sleeps / lib-redesign-wasm-lro (lib/ WOs — separate window decision, see 2.1) + c567 residue (c6 cosmetics) + docs-dod-check wrap | doctrine adoption order steps 2-6 | gates + doctrine land last so the allowlists are final |

### 2.1 lib/ scope note

lib-sleeps.md and lib-redesign-wasm-lro.md touch `lib/` (production). They
are drafted and sequenced here but their landing is a coordinator decision
distinct from the test-surface rewrite (R4 dependency: lib Part 1 cancels
fence-10's ratio conversion). Recommendation: run B3 (fence-10) FIRST; only
if the lib supervisor redesign is separately approved does B3's diff become
moot. Do not land both in one window without an explicit coordinator call.

## 3. Per-file risk class

**preserve-contract** = receipted assertion rows move verbatim or by named
reference; only scaffolding changes. **free-rewrite** = helper/module bodies
are new code (still zero assertion edits). **hybrid** = both.

| Class | Files |
|---|---|
| preserve-contract | corpus/shacl_fuzz.exs (assertions verbatim, snapshot tail only), corpus/tags_normalization.exs, compliance/c1_arm.exs, c3_cosmos.exs, c4_blob.exs, c5_servicebus.exs, c6_oauth.exs, c7_events.exs, egress_dispatch_test.exs, eventgrid_topics_arm_test.exs, eventgrid_conformance_test.exs, kd79_blob_apiversion_wire_test.exs, blob_hardening_test.exs (non-perf), apiversion_matrix_test.exs (KD-78 pins verbatim), wire_tier_refusal_sweep_test.exs, smalt_arm_gateway_test.exs, auth_enforce_test.exs (pinned-row inventory ⊆ check mandatory), amqp/fuzz_test.exs, event_hubs_test.exs (pinions verbatim), flow_credit_test.exs (drain/credit pins), queue_store_test.exs, broker_facade_test.exs, lro_test.exs, arm_error_corpus_test.exs, affidavit_wasm_failclosed_test.exs (typed vocabulary), store_dets_test.exs (fresh-wins assert), mcp_test.exs, runtime_contracts_test.exs, zero_drift_serialization_test.exs |
| free-rewrite | test/support/* (all new modules), scripts/test_budget_gate.py, scripts/sleep_gate.py, test/support/budget_formatter.ex, justfile.d/28-*.just, test/e2e/lib.sh, test/sdk-smoke/*.mjs, test/sdk-full/*.probe.mjs, test/sdk-python/run.sh family, smalt-cli/tests/conftest.py, py_auth_keyvault.py, py_servicebus.py, gates/*.py (none needed — CLEAN) |
| hybrid | apiversion_matrix_test.exs (cite tuples change shape — pins verbatim), arm_error_corpus_test.exs (cite tags + poll migration), apiversion rows render, mix.exs (elixirc_paths — standard contract), test_helper.exs (exclude list — named-exclusion law), lro_test.exs (backdate vs poll per R5), py_servicebus.py D7 (owner decision flagged in draft) |

Risk notes:
- Every draft explicitly enumerates its preserved invariants; the WO for
  each batch carries that enumeration as the acceptance checklist.
- auth_enforce's flatten (B5) requires the mechanical check from its draft
  §5.5: quoted strings old ⊆ new ∪ moved-to-shared.
- The wire pinions (SASL ANONYMOUS, attach <=14 arity, .NET-GUID tokens, EH
  partitions ["0","1"]) are untouched by every draft; any WO whose diff
  touches those lines is wrong by construction.

## 4. Validation gate sequence (per batch)

Every batch, in order, real output in the batch receipt:

1. **File gate**: `mix test <each touched test file>` — green, counts
   recorded. (For scaffolding-only batches, the consumers' files.)
2. **Corpus stage**: `mix test test/corpus_test.exs` AND
   `mix test test/compliance_test.exs` — green, verdict counts byte-equal
   to the pre-batch run (shacl-fuzz prints `[shacl-fuzz] verdicts:` — diff it).
3. **Full suite x3**: `mix test` three times with distinct seeds
   (`--seed <s1/s2/s3>`), zero failures all three. A RED face is classified
   against FLAKE_LEDGER v26.10.17 before it is called new (attempt-5
   classification protocol).
4. **Batch-specific gates** (where named by the draft): vacuity probe
   (fence-10, budget-gate fixtures, sleep-gate SHIM-COURT), paired-run
   co-batch (eventgrid + egress_dispatch — the i21 race is only observable
   co-batched), `just docs-dod-check`, `python3 gates/test_isolation_leak_gate.py`
   (B5+), corpus verdict-count byte-equality.

Gate cost control: batches run with `MIX_BUILD_ROOT=_build-ft-b<N>` per
lane; the coordinator deletes all lane build roots at integration.

## 5. Totals

- **Test count**: ~2,655 tests in the full offline suite (r246 warm-up leg:
  2655 tests / 0 failures; ~2,404 `test`/`property` macros over 243 files,
  plus property/corpus expansion). The rewrite is count-invariant: every
  batch's full-suite count must equal the pre-batch count except where a
  draft merges duplicate probes (auth_enforce §3.1 — merged rows documented
  per-row) or adds doctests (AssertEventually: +2).
- **Batches**: 9 (B0-B8). B0 is a prerequisite with zero assertion surface;
  B1-B6 are the court-critical test surface; B7-B8 are harness/gate/doctrine.
- **Est. wall-clock**: B0-B4 ~1 court cycle each (file gate + corpus + 3x
  full ≈ 3 x 7 min + overhead); B5 is the long pole (auth flatten +
  co-batch pairs); B7-B8 add non-ExUnit tiers (~30-40 min of harness
  re-verification each).

## 6. Standing and limits of this plan

Every draft is DRAFT standing; none has landed. Draft-internal corrections
(foundations §3.3 stray tokens, store-lro-wasm §1 typo'd sketch, stress-tier
broken tables, c567 §3 helper contract) are noted in the drafts themselves —
implementers land the corrected CONTRACT forms, not the typo'd sketches.
Line numbers are as-of HEAD 885c451 and must be re-derived on the working
tree at batch time. FLAKE_LEDGER standings are stale-by-default; re-verify
before citing. This plan mints no GAP tokens, proposes no KD flips, and
edits no generated artifact.
