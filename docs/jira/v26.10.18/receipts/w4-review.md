# W4 residual review receipt — group 3 (solo lane)

- **Date**: 2026-10-18
- **Lane**: W4 residual review, group 3 of `/tmp/rewrite-workqueue.json`
- **Repo**: /Users/sac/smalt (no git actions per contract)
- **Standing**: PASS

## Scope

Six files reviewed against `rewrite-drafts/NO-SLEEP-DOCTRINE.md` (v26.10.18).
Foundations treated as landed: `SmaltTest.AssertEventually`, `SmaltTest.Env`,
`SmaltTest.Store.resilient_clear/resilient_setup`,
`SmaltTest.Singleton.start_supervised_singleton!` (all in `test/support/`).

## Review verdicts

| File | Verdict | Action |
|---|---|---|
| test/affidavit_seal_test.exs | ALREADY-COMPLIANT | none |
| test/azapi_actions_test.exs | DEFECTIVE setup | resilient_setup |
| test/data_plane/r133_policy_cas_test.exs | DEFECTIVE setup | resilient_setup |
| test/event_stream_test.exs | DEFECTIVE setup + env | resilient_setup + Env.with |
| test/security/lens5_fuzz_test.exs | ALREADY-COMPLIANT | none |
| test/strata_compat_test.exs | DEFECTIVE clears | resilient_clear x3 |

Zero `Process.sleep` sites in any of the six files (grep-clean). The
defects were the bare shared-Store setup/clear pattern (the FLAKE_LEDGER
F2-F5/F10 class: dead-table race between `ensure_store_up` and `Store.clear`
against async sibling teardown) and a hand-rolled `Application.put_env` +
`after delete_env` restore.

### ALREADY-COMPLIANT citations

- **test/affidavit_seal_test.exs** — `setup` uses structural sync over a real
  observable: `reusable_engine?/0` makes a real `WasmEngine.call_json`
  capabilities probe, and the whereis→start race window is closed by
  `rescue RuntimeError → reusable_engine?() → reraise` fallback. Left
  unconverted to `SmaltTest.Singleton.start_supervised_singleton!`
  deliberately: WasmEngine is an app-owned NAMED singleton; a via-named
  start would be invisible to `WasmEngine.call_json`'s named lookup, i.e. a
  defective conversion. All assertions preserved verbatim, including the
  seal-latency-adjacent byte pins (`@ctrt_bytes 352`, CTRT magic/version/
  verdict offsets, delta-hash re-verify against the engine's own blake3
  commit op, chain_integrity flip).
  - run: `7 tests, 0 failures`
- **test/security/lens5_fuzz_test.exs** — pure-function hostile-input fuzz
  over ReceiptSigner/Attestation/ConfidentialLedger; no Store, no env, no
  sleeps, no coordination. Nothing to convert.
  - run: `7 tests, 0 failures` (combined run with affidavit_seal)

## Applied changes (assertions preserved verbatim)

1. **test/azapi_actions_test.exs** — `setup` swapped from
   `ensure_store(); Store.clear()` to `SmaltTest.Store.resilient_setup()`;
   removed the now-redundant `ensure_store/0` helper and the unused
   `alias Smalt.Store`. All 17 pinned precedence/envelope assertions
   (If-Match 412 rows, ActionNotFound-before-version-gate precedence row,
   Registry drift falsifier) unchanged.
2. **test/data_plane/r133_policy_cas_test.exs** — same setup swap; kept
   `BlobStorage.ensure_policy_table()` + policy-table wipe. `collect/5`
   already used a deadline-bounded `receive ... after 30_000` (compliant
   bounded wait on a real message). All W5-8 HOLD_LOST invariant pins
   unchanged.
3. **test/event_stream_test.exs** — setup swapped to
   `SmaltTest.Store.resilient_setup()` (previously had NO ensure_store_up at
   all); dedup test's bare `Application.put_env` + `after delete_env`
   converted to `SmaltTest.Env.with([event_stream_dedup_ids: true], fn -> ... end)`
   with the assertions moved inside verbatim; removed unused
   `alias Smalt.Store`.
4. **test/strata_compat_test.exs** — three bare `Smalt.Store.clear()` call
   sites replaced with `SmaltTest.Store.resilient_clear()` (lines 137/170/274);
   all KAT roots, chain-law pins, CAS exactly-one-winner assertion untouched.

## Verification (MIX_BUILD_ROOT=_build-ft-w4, all green x2)

Batch run 1 (exit 0):

```
$ MIX_BUILD_ROOT=_build-ft-w4 mix test test/azapi_actions_test.exs \
    test/data_plane/r133_policy_cas_test.exs test/event_stream_test.exs \
    test/strata_compat_test.exs
EXIT=0
```

Batch run 2: `48 tests, 0 failures`.

Per-file, two consecutive runs each:

```
== test/azapi_actions_test.exs            17 tests, 0 failures   (x2)
== test/data_plane/r133_policy_cas_test.exs  4 tests, 0 failures  (x2)
== test/event_stream_test.exs             18 tests, 0 failures   (x2)
== test/strata_compat_test.exs             9 tests, 0 failures   (x2)
```

Untouched files confirmed green on the post-edit tree (combined):
`7 tests, 0 failures`.

## Falsifier

Any of the four touched files going red on a re-run with
`MIX_BUILD_ROOT=_build-ft-w4 mix test <file>` falsifies this receipt.

## Receipt context

Context: solo. No git actions. No build roots left behind (`_build-ft-w4`
retained as the lane's private root per fast_test.sh convention).
