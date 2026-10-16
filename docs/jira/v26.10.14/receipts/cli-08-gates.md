# CLI-8 — Verification Gates Runner Receipt

- Date: 2026-10-15
- Lane: CLI-8 (smalt-cli, /Users/sac/smalt/smalt-cli)
- Files owned: `smalt-cli/smalt_cli/gates.py`, `smalt-cli/smalt_cli/test_gates.py`, `smalt-cli/run_gates.py`, `smalt-cli/GATES.md`
- Subject SHAs (git hash-object, 12-hex): see Hash IDs below.

## Scope

Four gates as `smalt-cli gate` commands (typer sub-app `gate_app()` in
`gates.py`; `cli.py` is another lane's file, so registration is a documented
one-liner) plus the `run_gates.py` runner that appends per-gate receipt
records to the AU-10 ledger.

- GATE1 `sdk-wire-conformance`: subprocess pytest of the CLI-4/CLI-5 suites,
  ADR-PY-002 venvs (`smalt-cli/.venvs/<lane>`, fallback `.venv` with a loud
  note), per-suite pass/SKIP/fail aggregation, zero failures required.
- GATE2 `hil-attestation`: invokes `python -m smalt_cli.cli hw sign --device <PORT>`;
  no device or unlanded flow → SKIP-loud with the exact command.
- GATE3 `zero-actuation`: real stub upstream (`http.server` thread recording
  mutations, serving RG count over HTTP); adversarial RG PUT + storage DELETE
  through `MutationInterceptor` → typed 403 + `gate3.mutation_refusal` ledger
  record + zero substrate mutation (RG count 3 → 3 over real HTTP).
- GATE4 `audit-integrity`: `verify_manifest` over the gates-1-3 manifest plus
  op coverage by `params_digest`.

## Verification (real output)

```
$ cd smalt-cli && .venv/bin/python -m pytest smalt_cli/test_gates.py -q -p no:cacheprovider
18 passed in 2.08s

$ .venv/bin/python run_gates.py   # fresh audit_manifest.jsonl
{"gate": 1, "name": "sdk-wire-conformance", "status": "SKIP", "reason": "SKIP-LOUD: no CLI-4/CLI-5 SDK wire suites found under /Users/sac/smalt/smalt-cli (patterns: tests/sdk_wire/test_*.py, tests/sdk_wire_*/test_*.py, smalt_cli/test_sdk_wire_*.py, smalt_cli/test_wire_*.py) — lanes not landed yet", ...}
{"gate": 2, "name": "hil-attestation", "status": "SKIP", "reason": "SKIP-LOUD: hw sign flow not landed in smalt_cli.cli (typer refused the command; hw lane outstanding). Run once landed: python -m smalt_cli.cli hw sign --device <PORT>", ...}
{"gate": 3, "name": "zero-actuation", "status": "PASS", "details": {"probes": [{"verb": "PUT", "status": 403, "typed_refusal": true, "ledger_entry": true, "mutated": false}, {"verb": "DELETE", "status": 403, "typed_refusal": true, "ledger_entry": true, "mutated": false}], "rg_count_before": 3, "rg_count_after": 3, "upstream_mutations": 0, "no_state_mutation": true}}
{"gate": 4, "name": "audit-integrity", "status": "PASS", "details": {"intact": true, "count": 5, "coverage_ok": true, "missing_ops": []}}
gates: 4 run, 2 PASS, 2 SKIP, 0 FAIL   (exit 0)

$ .venv/bin/python -c "from smalt_cli.ledger import verify_manifest; print(verify_manifest('audit_manifest.jsonl'))"
{'intact': True, 'count': 6, 'first_break': None, 'reason': None}   # 6 = 4 gate receipts + 2 gate3 refusals (gate4 audited the pre-its-own-receipt state of 5)
```

Full-suite context: `pytest` over the whole package = 100 passed,
1 failed — `test_daemon.py::TestWsHandshakeAndRoundtrip` (another lane's
in-flight file, pre-existing to this lane; not touched by CLI-8).

Tests are Chicago-real: GATE3 runs against an in-process recording
`http.server`; GATE4 against a real intact manifest built through
`ledger.append_record` and a tampered one (op rewritten in place →
`intact: false, first_break: 1`); GATE1 aggregation through a real pytest
subprocess. No mocks.

## Hash IDs (git hash-object)

```
$ git hash-object smalt-cli/smalt_cli/gates.py smalt-cli/smalt_cli/test_gates.py smalt-cli/run_gates.py smalt-cli/GATES.md
793fb46ab323afc3ce8107e9646c684fdaab646d  gates.py
d82d7a2c0ffe390844e31cb111b6468bf7a09665  test_gates.py
0520f1c50d899c3110c3b7d63ac15d51ed10e166  run_gates.py
808b163ff715df7a32fd8e9aff85bfc3585f657e  GATES.md
```

## Honest standing

| Gate | Standing | Falsifier |
|---|---|---|
| GATE1 sdk-wire-conformance | SKIP (loud) — CLI-4/CLI-5 suites absent; gate exercises nothing yet | A landed suite failing still yields PASS, or a suite runs with zero loud note on venv fallback |
| GATE2 hil-attestation | SKIP (loud) — `hw sign` not landed; only Bluetooth pseudo-ports visible | A device-attached run that fails silently, or SKIP without the exact command |
| GATE3 zero-actuation | PASS — both probes typed-403 + ledgered, 0 mutations, RG count unchanged | A mutation reaching the stub upstream, or a refusal without a ledger entry, or RG count drift |
| GATE4 audit-integrity | PASS — chain intact, full op coverage | A tampered line reading intact, or an executed op missing from the manifest while PASS |

Limits: GATE3's upstream is a stub of the substrate, not the smalt emulator
itself; the refusal path exercised (`MutationInterceptor`) is the real
gateway code. GATE2's `--device` command contract is proposed here, not
implemented (hw lane owns it). No commits made.
