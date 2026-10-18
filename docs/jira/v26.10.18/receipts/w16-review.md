# W16 residual review — workqueue group 15

Date: 2026-10-18. Context: solo lane. Contract: review 5 files
(`/tmp/rewrite-workqueue.json` group 15; the dispatch named 6 but the JSON
group carries 5) vs NO-SLEEP-DOCTRINE, canonicalize where defective,
PRESERVE receipted assertions verbatim. Foundations landed (AssertEventually
/ Env / Store.resilient / Singleton in `test/support/`).

Standing: **PASS** — 41 test results across the 5 files, 0 failures, two
green passes each (MIX_BUILD_ROOT=_build-ft-w16).

## Findings + actions (per file)

### test/court_ocel_test.exs — CONVERTED
No sleeps; all writes are sync function calls into the NDJSON sink (Law 1
form 2). Setup already had the correct nil-preserving restore (put when prev
non-nil, delete when nil) — but hand-rolled. Canonicalized onto
`SmaltTest.Env.put_restored(ocel_dir: dir)`; the scratch-dir `on_exit`
rm_rf stays. Zero assertion edits.

### test/r32_repairs_test.exs — CONVERTED
No sleeps. Two defects in setup: (1) `Application.put_env(:smalt,
:auth_mode, :anonymous)` with NO restore at all — leaked the env mutation
past the suite (Env moduledoc leak-batch1 class); (2) bare
`ensure_store_up(); Store.clear()` — the FLAKE_LEDGER F2-F5 ensure→wipe
race window `SmaltTest.Store.resilient_setup/1` exists to close. Converted
to `Env.put_restored(auth_mode: :anonymous)` + `resilient_setup()`. All
receipted assertions preserved verbatim (oversize-RSA 400 InvalidValue
envelope, 4-form b64u decrypt round-trip, distinct-JWK projection,
key_ops policy intersection).

### test/enclave_hcl_test.exs — ALREADY-COMPLIANT
Pure fixture-file parsing against `test/terraform_fixture*`: no
`Process.sleep`, no env mutations, no shared-singleton or Store
dependencies, `async: true` with no shared state at all (each test calls
`Hcl.parse/1` on read-only fixtures and asserts on the returned doc).
Doctrine-compliant by construction; no edits.

### test/smalt_services_test.exs — CONVERTED
Two defects. (1) `defp poll/1` was an UNBOUNDED recursion on
non-"Succeeded" — a non-terminal-but-forever LRO spins the test process
with no deadline and no typed failure. Converted to a bounded
`SmaltTest.AssertEventually.eventually/2` poll on the status observable:
retries only "not terminal yet", immediate typed failure with the offending
status otherwise, monotonic deadline (Law 1 form 1). (2) setup was bare
`ensure_store_up(); Store.clear()` (F2-F5 class) + `put_env` with an
UNCONDITIONAL `delete_env` on_exit — destroys a pre-existing sibling value
(leak-batch1 finding 2). Converted to
`Env.put_restored(maa_measurement_baseline: [@measurement])` +
`resilient_setup(post_seed: ...)` with the default-subscription seed INSIDE
the retry window (c1_arm rescue-scope law). Zero assertion edits; all
15-service registry census and Tier 1-4 ARM assertions verbatim.

### test/amqp/selector_epoch_test.exs — CONVERTED
KD-68/KD-69 falsifier courts (receipted; @moduletag :amqp_wire). No sleeps;
all wire reads are bounded `recv` timeouts (`:gen_tcp` 5000ms connect /
`recv_f_safe` 300ms typed `:timeout` assert — bounded waits on events,
lawful). Defect: setup used `Application.put_env` + UNCONDITIONAL
`on_exit delete_env(:sb_shared_key)` — leak-batch1 finding 2 class.
Converted to `SmaltTest.Env.put_restored(sb_shared_key: ...)`; the guarded
`start_supervised!(Smalt.Store)` (async: false, nil-guarded) and all
KD-68/KD-69 attach/epoch assertions preserved verbatim.

## Verification (real output, two passes each)

Pass 1 — offline four together:

```
33 tests, 0 failures        # court_ocel 4 + r32_repairs 5 + enclave_hcl 15 + smalt_services 9
```

Pass 1 — wire file (`--include amqp_wire`):

```
8 tests, 0 failures         # selector_epoch, exit 0
```

Pass 2 (each set, individually re-run):

```
test/court_ocel_test.exs + r32 + enclave_hcl + smalt_services
  => 33 tests, 0 failures  (exit 0)
test/amqp/selector_epoch_test.exs --include amqp_wire
  => 8 tests, 0 failures  (exit 0)
```

No git operations performed (per contract).
