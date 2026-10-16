# Receipt: CLI-02 — NIST AU-10 Audit Ledger

- Subject: smalt-cli ledger lane, `smalt-cli/`
- Files owned and written:
  - `smalt_cli/ledger.py`
  - `smalt_cli/test_ledger.py`
  - `smalt_cli/ledger/README.md`
  - `docs/jira/v26.10.14/receipts/cli-02-ledger.md` (this file)
- Date: 2026-10-15
- Deps: stdlib only (`hashlib`, `json`, `os`).
- Commits: none (per lane contract).

## Verification (real output)

No venv present in the checkout; ran with system python3
(`/opt/homebrew/opt/python@3.14/bin/python3.14`, pytest 9.0.3):

```text
$ cd smalt-cli && python3 -m pytest smalt_cli/test_ledger.py -v
============================= test session starts ==============================
platform darwin -- Python 3.14.3, pytest-9.0.3, pluggy-1.6.0
collected 9 items

smalt_cli/test_ledger.py::test_append_and_verify_green PASSED            [ 11%]
smalt_cli/test_ledger.py::test_record_shape PASSED                       [ 22%]
smalt_cli/test_ledger.py::test_tamper_one_byte_detected_at_exact_line PASSED [ 33%]
smalt_cli/test_ledger.py::test_empty_manifest_genesis PASSED             [ 44%]
smalt_cli/test_ledger.py::test_missing_manifest_typed_failure PASSED     [ 55%]
smalt_cli/test_ledger.py::test_malformed_line_is_typed_not_exception PASSED [ 66%]
smalt_cli/test_ledger.py::test_chain_break_detected PASSED               [ 77%]
smalt_cli/test_ledger.py::test_determinism_two_runs_byte_identical PASSED [ 88%]
smalt_cli/test_ledger.py::test_params_digest_order_insensitive PASSED    [100%]

============================== 9 passed in 0.06s ===============================
```

9 passed, 0 failed.

## Contract

- `append_record(path, op, actor, params, ts) -> dict` — appends one
  canonical JSONL record to `audit_manifest.jsonl`; `prev_hash` chains to the
  last record's `hash` (GENESIS when empty/absent); write is flush+fsync.
- `verify_manifest(path) -> {intact, count, first_break, reason}` — full-chain
  recomputation of `hash = sha256(prev_hash + canonical(record-without-hash))`.
  Total: malformed/missing/chain-broken input yields typed results, never
  exceptions. Typed reasons: `missing_manifest`, `malformed_json`,
  `record_not_object`, `missing_field`, `chain_break`, `hash_mismatch`.
- Determinism (NFR-PY-05): canonical JSON = sorted keys, `separators=(",", ":")`;
  same record sequence → byte-identical file (test asserts byte equality of two
  independent runs).

## Falsifier status

Tamper falsifier executed: flipping one byte in record 1 of 3 returns
`{intact: false, first_break: 1, reason: "hash_mismatch", line: <tampered line>}`.
