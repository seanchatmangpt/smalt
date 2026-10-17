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

Aggregates the SDK wire pytest suites, discovered by convention
(`tests/test_*.py` — the real, flat layout — plus the historical
`tests/sdk_wire/**`, `smalt_cli/test_sdk_wire_*.py`,
`smalt_cli/test_wire_*.py` patterns kept for forward compatibility). Each
suite runs via subprocess pytest.

**Interpreter matrix — honest description (repair R44).** ADR-PY-002
prescribes per-lane venvs at `smalt-cli/.venvs/<lane>`. That layout does not
exist: `.venvs/` contains only symlinks named after test files
(`test_blob.py -> ../.venv-cli` etc.), none of which resolves to a venv with
a `bin/python`. This is a known defect, reported here rather than papered
over — the `.venvs/` symlinks need to be removed and real per-lane venvs
created (owner: coordinator, not lane R44). Until then every suite resolves
through `resolve_venv`'s fallback to `smalt-cli/.venv`, and the result
carries the loud `venv_note` "ADR-PY-002 per-lane venv .venvs/<lane>
missing; ran against .venv". The interpreter matrix is therefore currently
**nominal**: one real interpreter (`.venv`), per-lane isolation not exercised.

Zero failures required; a SKIP carries a loud reason in `reason`.

```sh
.venv/bin/python run_gates.py --gate 1
```

Standing 2026-10-16 (post-R120): suites are discovered from the flat
`tests/test_*.py` layout and actually run. `test_w3_session_ops` is now
pass-or-skip-loud (R120 rewrite); the only remaining known red is
`test_keyvault`, whose batch-delete cases SKIP on the KD-49 delivery-tag
signature while the rest of the suite FAILs and is reported as FAIL —
GATE1's aggregate verdict is FAIL until `test_keyvault` goes green. The
per-suite breakdown is printed to stdout at run time; the ledger stores only
the hashed `params_digest` for each `gate1.run` record, never the breakdown
itself.

## GATE2 — hil-attestation

Invokes the hw sign flow: `python -m smalt_cli.cli hw sign --device <PORT>`.
No serial device → SKIP-loud with the exact command; the flow refusing to
run (hw lane not landed) is also SKIP-loud, never a silent pass. A real
runtime failure of an landed flow is FAIL.

```sh
.venv/bin/python run_gates.py --gate 2
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

- GATE1 discovery previously pointed at `tests/sdk_wire/**` paths that never
  existed, producing a standing SKIP with a false close condition ("lanes not
  landed yet"). Fixed in R44: discovery matches the real flat `tests/` layout.
- The ADR-PY-002 per-lane venv layout (`.venvs/<lane>`) does not exist;
  `.venvs/` holds broken symlinks (`test_*.py -> ../.venv-cli`) and every
  suite actually runs against `.venv`. Defect reported, not deleted, in
  lane R44; the interpreter matrix is nominal until real per-lane venvs land.
- GATE2 executed its first signed receipt against the Elixir virtual HIL
  device (S-5, 2026-10-15); the `--device <PORT>` contract is implemented
  (typer alias in smalt_cli/hw/cli.py).
- GATE3's upstream is a stub of the smalt substrate, not the emulator
  itself; the refusal path it exercises (`MutationInterceptor`) is the real
  gateway code path.
