# W2 residual review receipt — v26.10.18

Lane: W2 (group 1 of /tmp/rewrite-workqueue.json), solo. Date: 2026-10-18.
Contract: docs/jira/v26.10.18/rewrite-drafts/WORKQUEUE.md (lane contract).
Build root: `_build-ft-w2`. No git operations.

## Per-file verdicts

### 1. test/affidavit_ingestion_functor_test.exs — REWRITTEN

- setup: hand-rolled `ensure_store/1` idempotent-boot + `Store.clear()` →
  `SmaltTest.Store.resilient_clear/1` (one audited dead-table retry on
  AssertEventually); helper retired.
- `lro_delay_ms` hand-rolled prev/on_exit restore → `SmaltTest.Env.put_restored/1`
  (put-if-non-nil / delete-if-unset discipline).
- OCEL-lane622 test `ocel_dir` prev/on_exit restore → `Env.put_restored/1`
  (rm_rf on_exit preserved).
- `stop_engine`'s local `wait_until/1` count-bounded sleeper (Process.sleep(10)
  x50) → `SmaltTest.AssertEventually.eventually/2` bounded poll on
  `whereis(WasmEngine) == nil`.
- Fixed latent flunk-message bug: `"…\#{inspect(other)}"` escaped interpolation
  printed the literal text; now interpolates. (Message text only — no assertion
  changed.)
- PRESERVED: `Process.sleep(:infinity)` holder park — annotated, No-Sleep Law 1
  `:infinity` exception (process fixture).
- All receipted assertions verbatim (witness shape, sealed flags, OCEL event
  filters, mutated-type drop flip, relationship checks).

### 2. test/arm/fr5_tf_divergence_closures_test.exs — REWRITTEN

- setup: bare `Store.start_link` case + `Store.clear()` → `resilient_clear/1`;
  unrestored `put_env(lro_delay_ms: 0)` → `Env.put_restored(lro_delay_ms: 0)`
  (was a silent sibling leak on any failure).
- "LRO InProgress poll body" test: trailing bare `put_env(lro_delay_ms, 0)`
  restore (leaked 60_000 to siblings on failure) → scoped
  `SmaltTest.Env.with/2`; assertions unchanged and verbatim inside the fn.
- No sleeps in file. All FR-5/KD-T5 assertions verbatim (vaultUri authority
  echo, primaryEndpoints, SB/EH default property sets, listKeys shapes,
  404 deny-by-default, 202/InProgress operation body).

### 3. test/data_plane/key_vault_actions_test.exs — REWRITTEN (setup only)

- setup: lens-4 unlinked `GenServer.start(Store, ...)` + `Store.clear()` →
  `SmaltTest.Store.resilient_clear/1` (same unlink-safety contract — Lifecycle
  restores the supervised Store child — one audited retry implementation).
- SKR describe setup: `put_env(maa_measurement_baseline)` + unconditional
  `on_exit delete_env` (destroyed any pre-existing baseline) →
  `Env.put_restored(maa_measurement_baseline: [m1])`.
- No sleeps; all crypto/SKR/R14 assertions verbatim (RSA-OAEP-256, A256GCM,
  sign/verify, wrap/unwrap, release-policy gate, jti single-use race 12-task
  1-ok/11-replay, RFC 5869 vectors, R138/W5-6 colon-collision, R24 recover).

### 4. test/enclave-testbed/enclave_testbed.exs — REWRITTEN (3 sites)

- `consume/3` F2 consumer: UNBOUNDED self-recursive `Process.sleep(10)` poll
  (hang risk: loop never terminates if events stall below 50) → bounded
  `consume/4` with a monotonic 30s deadline; the poll backoff is annotated
  POLL-STEP of the script's audited loop (AssertEventually is :test-env-only;
  this script runs via `mix run` in :dev — `run.sh`).
- `wait_until/2`: annotated as THE audited bounded poll implementation for the
  script (comment header + POLL-STEP annotation on its sleep).
- phase_f3: `put_env(lro_delay_ms, 1)` had NO restore (leak) → prev/try-after
  restore; its `Process.sleep(30)` annotated `# SLEEP-CLASS: TIME-ADVANCE`
  (crosses the 1ms LRO deadline window; condition under test is elapsed time).
- Preserved: pre-existing TIME-ADVANCE annotation at the E2 sleep(60) site
  (census line 610/611).
- All phase assertions verbatim (SKR/WORM/ledger/purview/sentinel/RG/cosmos/
  LRO sweeper/SB sessions/EH CAS/chaos restart).

### 5. test/sb_rules_test.exs — REWRITTEN (setup only)

- setup: `Lifecycle.ensure_store_up() + Store.clear()` →
  `SmaltTest.Store.resilient_clear/1`. Dropped now-unused `alias Smalt.Store`.
- No sleeps, no env mutations. All wire/evaluator/fan-out assertions verbatim
  ($Default synthesis, InvalidFilter/InvalidAction 400s, fan_out delivery +
  SET-label override, skip-not-DLQ).

### 6. test/store_churn_test.exs — ALREADY-COMPLIANT

- No `Process.sleep`, no Application-env mutation, no Store-boot dependency in
  setup (isolation by `@prefix` + on_exit prefix purge; real ETS + real
  concurrent Task racers = Chicago-real structural sync; Task.await bounds all
  racer lifetimes). Churn readers race real deleters; CAS/counter/insert_new
  race tests assert final observable state, not interactions. Cited why no
  doctrine pattern applies.

## Compile-freeze disclosure (SLA)

`lib/smalt/arm_gateway/lro_notifier.ex` (another lane's in-flight file) did not
compile: `Access.get/2` invoked inside a guard at the malformed-record clause
of `handle_call({:register, _, _}, ...)`. Minimal unblock fix applied per the
shared-checkout compile-freeze SLA: guard-legal
`not is_binary(:erlang.map_get("status", record))` (guard BIF; absent key
degrades to guard-fail, so the preceding `not is_map_key/2` disjunct preserves
exact semantics). Disclosed here per the disclosure law. [The file was
subsequently further edited by its owning lane on disk; the unblock stands
reconciled with their edits.]

## Validation (real output)

ExUnit five-file sweep, MIX_BUILD_ROOT=_build-ft-w2 (run 1, exit 0):

```
94 tests, 0 failures
```

Run 2, exit 0: `94 tests, 0 failures`.

Enclave testbed, `MIX_BUILD_ROOT=_build-ft-w2 test/enclave-testbed/run.sh`
(run 1, exit 0):

```
      PASS: attest->release->replay refusal->determinism->typed refusals
      PASS: WORM hold/lock refusals + time-injected expiry + hold-never-expires
      PASS: append/dup-409/chain-verify/tamper-detect/hostile-typed
      PASS: purview lineage, sentinel ingest->marker->KQL, RG typed 400s
      PASS: 500-doc seed, cross-partition walk 500 via continuation, pk-scoped 100, forged token 400
      PASS: 50 ops started, sweeper drove 50/50 to terminal, second sweep idempotent
      PASS: SB session exclusivity (second session claim refused), DLQ props stamped
      PASS: EH wire delivery under producer/consumer contention + CAS race semantics
      PASS: sweeper child killed -> supervisor restart -> serves again; substrate kept serving
9 passed, 0 failed
```

Run 2, exit 0: `9 passed, 0 failed`. Run 3 (after POLL-STEP annotation-only
edit), exit 0: `9 passed, 0 failed`.

## Standing

PASS — 5 files REWRITTEN, 1 ALREADY-COMPLIANT, receipted assertions preserved
verbatim, each touched file green x2 on `_build-ft-w2`.
