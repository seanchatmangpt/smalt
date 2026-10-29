# M4/SB-FIX verify + e2e zero-skip re-run receipt

**Standing:** PASS
Context: solo
Date: 2026-10-21

## Claim re-verified

VAL-NFR reported this suite passed in-session with no receipt on disk.
Re-run under `.venv-cli` with the derived-key client fix landed in
`smalt-cli/verify.py`: **11 passed, 0 skipped, 0 failed** (9.85s wall).

## Command + embedded output

```
$ cd /Users/sac/smalt/smalt-cli && .venv-cli/bin/python -m pytest tests/test_migrate_verify.py tests/test_migrate_e2e.py -v
============================= test session starts ==============================
platform darwin -- Python 3.13.11, pytest-9.1.1, pluggy-1.7.0 -- /Users/sac/smalt/smalt-cli/.venv-cli/bin/python
cachedir: .pytest_cache
rootdir: /Users/sac/smalt/smalt-cli
configfile: pyproject.toml
collecting ... collected 11 items

tests/test_migrate_verify.py::test_blob_wire_gate PASSED                 [  9%]
tests/test_migrate_verify.py::test_cosmos_wire_gate PASSED               [ 18%]
tests/test_migrate_verify.py::test_kv_wire_gate PASSED                   [ 27%]
tests/test_migrate_verify.py::test_servicebus_wire_gate PASSED           [ 36%]
tests/test_migrate_verify.py::test_zero_egress_loopback_only PASSED      [ 45%]
tests/test_migrate_verify.py::test_zero_egress_typed_violation_on_foreign_host PASSED [ 54%]
tests/test_migrate_verify.py::test_run_receipt_end_to_end PASSED         [ 63%]
tests/test_migrate_e2e.py::test_e2e_all_emits_manifest_and_env PASSED    [ 72%]
tests/test_migrate_e2e.py::test_e2e_verify_gate_and_receipt PASSED       [ 81%]
tests/test_migrate_e2e.py::test_e2e_rollback_restores_preexisting_env PASSED [ 90%]
tests/test_migrate_e2e.py::test_e2e_rollback_removes_injection_when_no_prior_env PASSED [100%]

============================== 11 passed in 9.85s ==============================
```

## Standing

PASS — zero skips; no typed finding. The ServiceBus wire gate
(`test_servicebus_wire_gate`) exercises the derived-key client path and
passes against the landed fix.
