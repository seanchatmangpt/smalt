# W6 residual review receipt — v26.10.18

Context: solo (r177d_repro_test.exs x2) + slice(4-file batch, 35 tests 0 failures)
Standing: PASS — 1 file REWRITTEN, 3 ALREADY-COMPLIANT, touched file green x2

Lane: W6 (group 5 of /tmp/rewrite-workqueue.json), solo. Date: 2026-10-18.
Contract: docs/jira/v26.10.18/rewrite-drafts/WORKQUEUE.md (lane contract).
Build root: `_build-ft-w6`. No git operations.

Scope note: group 5 is shared with W5's lease at its head
(test/affidavit_wasm_engine_test.exs, and test/canonical_projection_test.exs
per WORKQUEUE.md's W5 line). W6's files = the remainder:
r177d_repro, fin_ops_calculator, lens6_crash_class, telemetry_test.

## Per-file verdicts

### 1. test/data_plane/r177d_repro_test.exs — REWRITTEN (setup + storm drain)

- setup: `Lifecycle.ensure_store_up(); Store.clear()` →
  `SmaltTest.Store.resilient_clear/1` (canonical i21/i22 hardening);
  dropped the now-unused `alias Smalt.Store`.
- Storm test ("concurrent hold-vs-immutability storm"): the 80-message
  drain was an UNBOUNDED `receive do :done -> :ok end` with no `after` —
  any crashed racer (e.g. a failed `{:ok, 200, _, _}` match inside the
  spawned process, which dies silently) would hang the suite forever.
  Now bounded: `after 30_000 -> flunk("racer #{i}/80 never reported :done
  (spawn crashed)")` — typed immediate-fail on deadline expiry (No-Sleep
  Law 1), the same law as AssertEventually's deadline, applied to the
  structural-sync receive.
- PRESERVED verbatim: all four R177d assertions (metadata-survives chain,
  hold→metadata 409, legal_hold survives immutability PUT, storm final
  state: legal_hold==true, imm period_days==1, metadata==nil) and the
  40-racer spawn shape itself.

### 2. test/fin_ops_calculator_test.exs — ALREADY-COMPLIANT

- Pure-function suite over `Smalt.FinOps.Calculator`: async: true, no
  `Process.sleep`, no Application-env mutation, no Store/shared-singleton
  dependency, no timing bounds (the "deterministic: repeated calls
  byte-identical" fence is 50 real invocations compared for equality —
  structural, not time-based). All tariff/cent/region assertions are
  exact-value receipts; nothing to migrate.

### 3. test/security/lens6_crash_class_test.exs — ALREADY-COMPLIANT

- No sleeps, no env mutation, no setup/boot dependency (Store keys
  namespaced `l6-wrap*`/`l6-jti-*` + `System.unique_integer` jti; isolation
  by namespacing, not by clear). Courts are state-observation asserts on
  the typed 400 envelope and no-burn conservation
  (`Store.get == :error` post-refusal) — Chicago-real through the real
  `SKR.release/2` Plug path with a real `ReceiptSigner.sign/1` token.
  Nothing to migrate.

### 4. test/telemetry_test.exs — ALREADY-COMPLIANT (already migrated)

- Already on the canonical machinery: the prune test uses
  `SmaltTest.AssertEventually.eventually/2` with a named observable;
  cumulative-counter asserts use pre-test-baseline DELTAS, not absolute
  counts; the post-boot table-loss falsifier bounds its repair via
  supervised terminate/restart in `after` (no sleep). Env-free,
  handler ids unique-per-test with on_exit detach. Nothing to migrate.

## Validation (real output)

r177d_repro_test.exs, MIX_BUILD_ROOT=_build-ft-w6, run 1 (exit 0):

```
4 tests, 0 failures
```

Run 2 (exit 0): `4 tests, 0 failures`.

Untouched trio (fin_ops + lens6 + telemetry) sanity sweep, same build
root, exit 0:

```
35 tests, 0 failures
```

## Standing

PASS — 1 file REWRITTEN, 3 ALREADY-COMPLIANT (cited), receipted
assertions preserved verbatim, touched file green x2 on `_build-ft-w6`.
