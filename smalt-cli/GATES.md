# Gates — smalt-cli verification gates (v26.10.14, lane CLI-8)

Four gates under `smalt-cli gate` (typer sub-app in
`smalt_cli/gates.py:gate_app()`; register in `cli.py` with
`app.add_typer(gate_app(), name="gate")`) or via the standalone runner:

```sh
cd smalt-cli
.venv-cli/bin/python run_gates.py            # all four, ledger receipts appended
.venv-cli/bin/python run_gates.py --gate 3   # one gate
```

Exit 0 iff no gate FAILs. Every gate run appends a `gate<N>.run` record to
the append-only ledger (`audit_manifest.jsonl`, NIST AU-10 hash chain in
`smalt_cli/ledger.py`). GATE3 refusals append `gate3.mutation_refusal`
records; GATE4 verifies the whole chain and that every executed op of the
run is present by `params_digest`.

## GATE1 — sdk-wire-conformance

Aggregates the SDK wire pytest suites, discovered by convention
(`tests/test_*.py` — the real, flat layout — plus the historical
`tests/sdk_wire/**`, `smalt_cli/test_sdk_wire_*.py`,
`smalt_cli/test_wire_*.py` patterns kept for forward compatibility). Each
suite runs via subprocess pytest.

**Interpreter matrix — honest description (repair R44, resolved 2026-10-17).**
ADR-PY-002 prescribes per-lane venvs at `smalt-cli/.venvs/<lane>`. That layout
still does not exist, and the old `.venvs/test_*.py -> ../.venv-cli` symlinks
(never a venv layout, never consulted by `resolve_venv`) were deleted on
2026-10-17. `resolve_venv` now falls back to the **documented fallback**
`smalt-cli/.venv-cli` and every result carries the loud `venv_note`
"ADR-PY-002 per-lane venv .venvs/<lane> missing; ran against .venv-cli
(documented fallback)". The interpreter matrix is therefore **one real
interpreter** (`.venv-cli/bin/python`, existence+executability fenced by
`smalt_cli/test_gates.py::test_resolve_venv_falls_back_to_venv_cli_with_note`);
per-lane isolation is not exercised. A truthfulness fence
(`test_resolve_venv_never_claims_test_file_symlinks_are_venvs`) pins that
`resolve_venv` never returns a test-file-named entry as an interpreter.

Zero failures required; a SKIP carries a loud reason in `reason`.

```sh
.venv-cli/bin/python run_gates.py --gate 1
```

Standing 2026-10-17: suites are discovered from the flat `tests/test_*.py`
layout and actually run (10 suites, 45 passed / 1 skipped / 2 failed).
`test_keyvault` is green — 6/6, no batch-delete cases in the suite (the
KD-49 batch-delete cases were never present to SKIP). The only red is
`test_cosmos` (2 failed, 7 passed): the cosmos query whitelist is in flight
by a separate lane (KD-06); those 2 failures are classified to that lane,
not this one. GATE1's aggregate verdict is FAIL until the KD-06 fix lands.
The per-suite breakdown is printed to stdout at run time; the ledger stores
only the hashed `params_digest` for each `gate1.run` record, never the
breakdown itself.

## GATE2 — hil-attestation

Invokes the hw sign flow: `python -m smalt_cli.cli hw sign --device <PORT>`.
No serial device → SKIP-loud with the exact command; the flow refusing to
run (hw lane not landed) is also SKIP-loud, never a silent pass. A real
runtime failure of an landed flow is FAIL.

```sh
.venv-cli/bin/python run_gates.py --gate 2
```

Standing 2026-10-15 (S-5 landing): **PASS on the virtual HIL device** —
`hw sign --device <PORT>` is landed (typer `--device` alias, S-5), and the
Elixir virtual device (Smalt.Hw.VirtualSerial over a raw-mode pty, spawned by
`python -m smalt_cli.hw.sim_host`) answers the sign flow. Witness:
`python -m smalt_cli.hw.sim_host --gate2` -> PASS "signed receipt produced".
Without a device (SMALT_HW_PTY unset, no USB), GATE2 remains SKIP-loud.

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
.venv-cli/bin/python run_gates.py --gate 3
```

Standing 2026-10-15: **PASS** (both probes 403 + ledgered, 0 mutations,
RG count 3 → 3).

## GATE4 — audit-integrity

`ledger.verify_manifest` over the manifest written by gates 1-3 plus op
coverage: zero chain breaks, every executed op of the run present by
`params_digest`.

```sh
.venv-cli/bin/python run_gates.py --gate 4
```

Standing 2026-10-15: **PASS** (chain intact; all executed ops covered).

## Tests

```sh
.venv-cli/bin/python -m pytest smalt_cli/test_gates.py -q
# 19 passed — GATE3 against a real recording http.server upstream, GATE4
# against real intact and tampered manifests, GATE1 aggregation through a
# real pytest subprocess.
```

## Honest limits

- GATE1 discovery previously pointed at `tests/sdk_wire/**` paths that never
  existed, producing a standing SKIP with a false close condition ("lanes not
  landed yet"). Fixed in R44: discovery matches the real flat `tests/` layout.
- The ADR-PY-002 per-lane venv layout (`.venvs/<lane>`) does not exist; the
  broken `test_*.py -> ../.venv-cli` symlinks were deleted 2026-10-17 and
  every suite resolves to the documented `.venv-cli` fallback (loud
  `venv_note` per result). Per-lane venv creation remains open with the
  coordinator.
- **CLI↔MCP de-scope (honest limits).** The CLI exposes 4 infra commands
  while the MCP surface carries 8 read-only tools. These serve distinct
  actors (human operators driving infrastructure vs agents reading
  substrate state), and the CLI commands actuate through the ARM gateway's
  own admission path — a 1:1 CLI↔MCP parity would duplicate routing with no
  consumer. Recorded as a deliberate de-scope, not a gap.
- GATE2 executed its first signed receipt against the Elixir virtual HIL
  device (S-5, 2026-10-15); the `--device <PORT>` contract is implemented
  (typer alias in smalt_cli/hw/cli.py).
- GATE3's upstream is a stub of the smalt substrate, not the emulator
  itself; the refusal path it exercises (`MutationInterceptor`) is the real
  gateway code path.
