# smalt-cli

Headless CLI companion to the [smalt](../) Azure emulator. Wire-parity over
mocking: official Azure SDKs run against local loopback endpoints served by the
smalt substrate. Zero-actuation is enforced in code (AU-10).

## Install

```sh
cd smalt-cli
python3 -m venv .venv-cli
. .venv-cli/bin/activate
pip install -e '.[dev]'
```

`smalt-cli` uses the single `.venv-cli` interpreter (ADR-PY-002 documented
fallback — a bare `.venv` does not exist and is never created; the historical
per-lane `.venvs/<lane>` layout is not in use).

Hard deps: `typer`, `pyserial` only. Python 3.10+. `aiohttp` optional (`aio`
extra).

## Endpoints (env, ADR-PY-001)

| var | default | surface |
|---|---|---|
| `SMALT_ARM` | `https://127.0.0.1:9443` | ARM control plane |
| `SMALT_EGRESS` | `https://127.0.0.1:8443` | data-plane egress (blob, etc.) |
| `SMALT_AMQP` | `127.0.0.1:5672` | AMQP messaging |

Non-loopback values are refused at config load (`config.enforce_loopback`).

### AZURE_* export plan

Point official Azure SDKs at the emulator by exporting `AZURE_CLIENT_ID`,
`AZURE_TENANT_ID`, `AZURE_CLIENT_SECRET`, `AZURE_AUTHORITY_HOST`,
`AZURE_ARM_ENDPOINT`, `AZURE_STORAGE_CONNECTION_STRING` — mapping table in
`smalt_cli/config.py:AZURE_EXPORT_PLAN`. Credentials live in the process env
only; nothing is written to disk and nothing leaves loopback.

## Commands

`python -m smalt_cli.cli <command>`

- `test` — hardware-in-the-loop test profiles against the substrate (scaffold
  echo; the HIL profile lane is not landed)
- `hw` — pyserial hardware transport (real implementation when a `typer`
  import succeeds; a scaffold echo otherwise)
- `daemon` — scaffold echo for the long-lived loopback daemon (lane not
  landed; the loopback check still runs)
- `audit` — scaffold echo for the AU-10 audit surface (lane not landed)
- `gate` — verification-gates sub-app (lane CLI-8): `gate sdk-wire-conformance`
  (GATE1 aggregate), `gate hil-attestation` (GATE2), `gate zero-actuation`
  (GATE3), `gate audit-integrity` (GATE4). The retired
  `gate VERB URL` scaffold command is superseded by `gate zero-actuation`.

See `smalt-cli/GATES.md` for the gate contracts.

## Zero-actuation gate (AU-10)

`smalt_cli/policy.py`: frozen read allowlist — `GET`/`HEAD` pass; `PUT`/`POST`/
`PATCH`/`DELETE` are refused unless explicitly allowlisted as
`"VERB:path-prefix"` entries in `EXPLICIT_READ_OPS` (empty by default).
Unknown verbs refused. Refusals are typed JSON on stderr
(`{refused, reason, verb, url, ts}`) with exit code 2.

## Conventions for lanes

- **Layout**: one module per lane under `smalt_cli/<module>/`; register new
  commands in `smalt_cli/cli.py` via `@app.command()` or a sub-`typer.Typer()`.
- **Tests**: `pytest`, two real locations — SDK wire suites flat in
  `tests/test_*.py` (the real layout GATE1 discovery matches; the historical
  `tests/sdk_wire/**` globs never existed) and package lanes co-located in
  `smalt_cli/test_*.py`. Chicago style: real collaborators, no mocks.
- **Language level**: Python 3.10+; stdlib-first. No new hard dependencies —
  propose optional extras via `pyproject.toml [project.optional-dependencies]`.
- **Everything in-repo**: no `/tmp` artifacts, no external analytics services, zero network egress
  beyond `127.0.0.1` (enforced by `config.enforce_loopback`).
- **Zero-actuation**: all outbound requests route through `policy.guard()`.

## Verify

```sh
python -m smalt_cli.cli --help
# SDK wire lanes (tests/) run as two auth-exclusive pytest sessions (X-6):
.venv-cli/bin/python -m pytest tests/ -m anonymous -q   # blob/cosmos — substrate 39643/39644
.venv-cli/bin/python -m pytest tests/ -m enforce -q     # identity/resourcegraph/servicebus/eventhub/keyvault — substrate 38654-38656/38672-38673
```

Wire lanes share NO substrate lock: each session fixture (`tests/conftest.py`)
probes its port block and reuses a healthy substrate read-only, else boots a
private-port one under its own lock (`/tmp/smalt-substrate-cli4.lock` /
`/tmp/smalt-substrate-cli5.lock`) pinned to the session's auth mode. No
import-time boot — provisioning is lazy and fixture-scoped.
