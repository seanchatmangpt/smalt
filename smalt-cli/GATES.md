# Gates — smalt-cli verification gates (v26.10.14, lane CLI-8)

Four gates under `smalt-cli gate` (typer sub-app in
`smalt_cli/gates.py:gate_app()`; register in `cli.py` with
`app.add_typer(gate_app(), name="gate")`) or via the standalone runner:

```sh
cd smalt-cli
.venv/bin/python run_gates.py            # all four, ledger receipts appended
.venv/bin/python run_gates.py --gate 3   # one gate
```

Exit 0 iff no gate FAILs. Every gate run appends a `gate<N>.run` record to
the append-only ledger (`audit_manifest.jsonl`, NIST AU-10 hash chain in
`smalt_cli/ledger.py`). GATE3 refusals append `gate3.mutation_refusal`
records; GATE4 verifies the whole chain and that every executed op of the
run is present by `params_digest`.

## GATE1 — sdk-wire-conformance

Aggregates the CLI-4/CLI-5 SDK wire pytest suites, discovered by convention
(`tests/sdk_wire/**`, `smalt_cli/test_sdk_wire_*.py`,
`smalt_cli/test_wire_*.py`). Each suite runs via subprocess pytest
(ADR-PY-002 venv layout `smalt-cli/.venvs/<lane>`; falls back to
`smalt-cli/.venv` or the ambient interpreter with a loud note in the result).
Zero failures required; a SKIP carries a loud reason in `reason`.

```sh
.venv/bin/python run_gates.py --gate 1
```

Standing 2026-10-15: **SKIP** — no CLI-4/CLI-5 suites landed yet (discovery
finds zero files). The gate is not exercising wire conformance until those
lanes land.

## GATE2 — hil-attestation

Invokes the hw sign flow: `python -m smalt_cli.cli hw sign --device <PORT>`.
No serial device → SKIP-loud with the exact command; the flow refusing to
run (hw lane not landed) is also SKIP-loud, never a silent pass. A real
runtime failure of an landed flow is FAIL.

```sh
.venv/bin/python run_gates.py --gate 2
```

Standing 2026-10-15: **SKIP** — `hw sign` is not landed in
`smalt_cli/cli.py` (typer: "No such option: --device"); the only serial
devices visible are macOS Bluetooth pseudo-ports, not HIL targets.

## GATE3 — zero-actuation

Adversarial probe. Boots a real stub upstream (`http.server` thread) that
records every mutation and serves the substrate RG count over HTTP, then
attempts through the gateway (`MutationInterceptor`):

- `PUT  /subscriptions/.../resourceGroups/rg-gate3-probe`
- `DELETE .../Microsoft.Storage/storageAccounts/stg-gate3-probe`

Each must return a typed 403 envelope
(`smalt.gateway.mutation_refused`, `MutationRefused`), land a
`gate3.mutation_refusal` ledger record, and leave the substrate untouched:
upstream mutation log empty, RG count identical before/after over real HTTP.

```sh
.venv/bin/python run_gates.py --gate 3
```

Standing 2026-10-15: **PASS** (both probes 403 + ledgered, 0 mutations,
RG count 3 → 3).

## GATE4 — audit-integrity

`ledger.verify_manifest` over the manifest written by gates 1-3 plus op
coverage: zero chain breaks, every executed op of the run present by
`params_digest`.

```sh
.venv/bin/python run_gates.py --gate 4
```

Standing 2026-10-15: **PASS** (chain intact; all executed ops covered).

## Tests

```sh
.venv/bin/python -m pytest smalt_cli/test_gates.py -q
# 18 passed — GATE3 against a real recording http.server upstream, GATE4
# against real intact and tampered manifests, GATE1 aggregation through a
# real pytest subprocess.
```

## Honest limits

- GATE1 currently verifies nothing about wire conformance (suites absent);
  it will PASS with loud SKIP notes until CLI-4/CLI-5 land.
- GATE2 has never executed a signed receipt; the command contract
  (`--device <PORT>`) is proposed here, not implemented — the hw lane owns it.
- GATE3's upstream is a stub of the smalt substrate, not the emulator
  itself; the refusal path it exercises (`MutationInterceptor`) is the real
  gateway code path.
