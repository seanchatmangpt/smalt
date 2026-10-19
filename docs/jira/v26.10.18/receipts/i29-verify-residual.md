# i29 — verify-all residual faces triage at current HEAD

Context: pair(i29-sdk-census-fresh)
Standing: **ALIVE** — 3 of 4 residual faces cleared with executed gates; 1 residual pytest face (w3 session ops) listed, not fixed.
Base: main @ 2106032 (tree shared with the in-flight budget re-seed lane).

## 1. doctor-dod — now exit 0

Two stale-census faces, both fixed by reconciling `scripts/doctor_dod.py` to
on-disk/receipt reality (identical change landed concurrently in commit 1a309e2
"chore: land doctor-dod GAP census retirement + sdk-smoke deps"; this lane's
edit is byte-equivalent, no conflict):

- `.venv missing` → ADR-PY-002 documents that a bare `.venv` does not exist and
  is never created; `.venv-cli` is the interpreter for all CLI lanes
  (`justfile.d/03-cli-wiring.just:4-5,17-19`). `check_cli` now checks
  `.venv-cli/bin/python`; `py_compile clean over 12 files`.
- 5 GAP tokens absent + count drift 5 vs 9 → all 5 absences are receipt-gated
  retirements, NOT missing tokens (no new tokens minted, none restored):
  - `blob-error-envelope-json` — retired v26.10.14 lane 06
    (`docs/jira/v26.10.14/06-blob.md:10,74`)
  - `cosmos-sql-translator-absent` — superseded,
    `docs/jira/v26.10.16/receipts/r-lane523-cosmos-sql-flip.md`
  - `ledger-lazy-create-default` — token deleted from WIRE_PARITY.md,
    `docs/jira/v26.10.17/verify-ledger/w0-b12.md` / `w1-b3.md`
  - `eventhubs-partition-metadata-absent`,
    `eventhubs-consumer-group-enumeration-absent` — RETIRED,
    `docs/compliance/C7_EVENT_PLANES.md:60,65` +
    `docs/jira/v26.10.16/receipts/cap-eh-consumergroups.md`
  Census re-based to the 5 live-open tokens (blob-comp-lease-absent,
  blob-x-ms-date-unvalidated, eventgrid-eg1-schema-absent,
  atlas-search-relationship-get-absent, kql-datetime-dynamic-types-absent);
  `EXPECTED_UNSUPPORTED_COUNT` 9→5, `EXPECTED_CLOSED_COUNT` 5→3 (matches the
  3 `CLOSED 2026-10-15` stamps in the register text).

Executed gate:

```
$ just doctor-dod
...
INFO  smalt-cli: .venv present (python: /Users/sac/smalt/smalt-cli/.venv-cli/bin/python)
INFO  envelope/defect cross-check: all 5 expected gap tokens present
INFO  gap register sync: 3 'CLOSED 2026-10-15' stamps; 5 distinct live GAP(...) tokens in WIRE_PARITY.md (lane-13 census: 3 CLOSED + 5 UNSUPPORTED)
summary: 0 FAIL, 1 WARN (exit 0 unless FAIL fired)
exit=0
```

Remaining WARN (pre-existing, not a FAIL): 8 lane build roots, 3.0 GiB —
`just lane-clean` remediation, coordinator call.

## 2. smalt-cli pytest — 0 collection errors

Full CLI suite via `.venv-cli` (both lanes, per cli-test recipe):

```
$ cd smalt-cli && .venv-cli/bin/python -m pytest tests/ smalt_cli/ -q -p no:cacheprovider
3 failed, 141 passed, 6 skipped, 12 warnings in 776.99s (0:12:56)
```

The i29-sdk-census-fresh "8 collection errors (ModuleNotFoundError
hypothesis/azure)" face does not reproduce at HEAD: 0 collection errors, 0
dependency installs needed (hypothesis is not imported by any test file; azure
SDKs were already present in `.venv-cli`). The earlier face is consistent with
the missing-`.venv` interpreter fallthrough to system python3.

**Residual (listed, not fixed): 3 failures, all in
`smalt-cli/tests/test_w3_session_ops.py`** — `test_session_state_round_trip`,
`test_list_sessions_witness`, `test_batch_delete_removes_exactly_n`
(urllib.error / azure exceptions against the live session-ops endpoints). Left
for the session-ops owner; not touched.

## 3. receipt-index drift — cleared

```
$ just receipt-index   # regenerated 8 files (RECEIPTS.md + INDEX.md × v26.10.14/16/17/18)
$ just receipt-index   # second run: no drift, exit 0 (idempotent)
```

Known SUSPECT flags from the indexer (pre-existing, informational):
`lc1-8hop-tax-chain.md` (ALIVE), `lc2-tco-ledger.md` (UNKNOWN).

## 4. stress tier — files from i29-stress-real-fixes green

```
$ FAST_TEST_BUILD_ROOT=_build-ft-i29res scripts/fast_test.sh \
    test/store_tables_replay_identity_test.exs \
    test/smalt_ets_composite_identity_test.exs --include stress
→ 5 tests, 0 failures   (58s wall, second run with full log captured)
```

Both deterministic faces from i29-stress-real-fixes (StoreTables `:smalt_`
coverage + ETS composite teardown residue) are green post-2106032. Disclosure:
an earlier rerun of the same pair showed 1 failure whose test name was lost to
a tail-piped log; the full-capture rerun above is clean — classify as the
typed LOAD-FLAKE class, not a deterministic regression (does not reproduce,
36s isolated finish).

Other stress failure names from i29-stress-full (typed LOAD-FLAKE, isolation
PASS witnessed there — listed only, no fix):
`test/semconv_replay_identity_test.exs`, `test/chaos/crash_isolation_test.exs`,
`test/azsim/dr_scenarios_test.exs`; plus the `sovereign_midnight_test.exs`
compile-abort face (excluded from that run; require-path defect since repaired
by 9cf4e69 — not re-witnessed this lane).

## Lane hygiene

`_build-ft-i29res` lane build root created by this lane's fast_test runs —
LEASE LEFT IN PLACE (fast_test per-hash root, ~1 GiB class): an in-place
`rm -rf` was refused by the permission system and a global `just lane-clean`
would sweep the concurrently-live budget lane's roots. Reclaim via
`just lane-clean` at integration, or `rm -rf _build-ft-i29res` directly.

Lane wrote: `scripts/doctor_dod.py` (census + venv-cli reconciliation, landed
as 1a309e2) and this receipt. No bench jsonl, no shared-infra edits.
