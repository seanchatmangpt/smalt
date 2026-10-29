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

## smalt-migrate (Terraform/Bicep -> smalt topology)

`smalt_cli/migrate/` — offline, read-only migration surface (PRD Module 1).
`scan`, `generate`, `inject`, `rollback` are registered Typer commands
(cli.py mounts the sub-app at `app.add_typer(migrate_app, name="migrate")`).

- **`smalt-cli migrate scan DIRECTORY [--output/-o TOPO.json]`** — extracts
  `azurerm_*` blocks from Terraform (.tf, rglob-sorted) and Bicep templates,
  maps them to the topology IR (`smalt-migrate/topology-v1`), and emits JSON
  to stdout or `--output`. Fail-closed: parse failures and unsupported
  resource types are reported, never dropped. Tests:
  `tests/test_migrate_scan.py` (9, offline).
- **`smalt-cli migrate generate --iac-path DIR --output-dir DIR`** — topology
  IR -> `smalt.manifest.json` (seed fixtures per service, unresolved summary).
  Byte-deterministic (NFR-3: sorted keys, trailing newline, no timestamps).
  Tests: `tests/test_migrate_manifest.py` (9, offline, incl. byte-identity).
- **`smalt-cli migrate inject [--topology topo.json] [--target .env.smalt] [--dry-run]`** —
  renders loopback-only connection strings (cosmos/blob/servicebus/eventhubs/
  keyvault, ports 8443/5672/5673/9443) into `.env.smalt`; backs up an existing
  target to `.bak` first; `--dry-run` prints without writing. NFR-1: read-only
  vs the cloud — no network calls anywhere in the module. Tests:
  `tests/test_migrate_inject.py` (12, offline).
- **`smalt-cli migrate rollback [--target .env.smalt]`** — restores `.bak`
  over the injected env, or removes the injection when no `.bak` exists.
- **Pipeline (library)** — `smalt_cli.migrate.pipeline.run_all(iac_dir, ...)`
  chains scan -> generate -> inject with per-stage typed results; NFR-2
  budget <=30s for 50 resources (tested on a generated 50-resource fixture).
  NOTE: not yet registered as a Typer command (see wave-1 audit receipt,
  Finding 1). Tests: `tests/test_migrate_pipeline.py` (8, offline).
- **Verify (library)** — `smalt_cli.migrate.verify.run(...)` runs per-service
  wire-fidelity gates against the LIVE loopback substrate (ARM :9443, egress
  :8443) and asserts zero non-loopback egress (`NonLoopbackEgress` is typed).
  Requires the Azure SDK — run under `.venv-cli`. No Typer command yet.
  Tests: `tests/test_migrate_verify.py` (7; loud SKIP when substrate down,
  loud typed skip on the AMQP leg when the boot key is undersized).

    .venv-cli/bin/python -m pytest tests/test_migrate_scan.py \
      tests/test_migrate_manifest.py tests/test_migrate_inject.py \
      tests/test_migrate_verify.py tests/test_migrate_pipeline.py -q
    # 37 passed (offline lanes) + 6 passed, 1 skipped (verify, substrate up)

### Showcase fixture: `tests/fixtures/migrate-enterprise/`

A realistic ~66-resource orders/payments/inventory estate across 12 files
(8 Terraform + 4 Bicep), used as the README demo and as a parser regression
corpus. Counts below are asserted by `tests/test_migrate_enterprise_fixture.py`
(5 tests) — they are measured outputs of the real pipeline, not targets.

- **Scan**: 12 files, 66 supported resource blocks, 0 scan errors.
  By type: 1 cosmos account / 3 databases / 8 containers, 5 storage
  containers, 2 key vaults + 6 secrets, 2+1 servicebus namespaces with
  7 queues / 5 topics / 7 subscriptions, 3 eventhub namespaces with 6 hubs /
  8 consumer groups, 3 APIM gateways.
- **Typed-error paths (deliberate)**: 6 unsupported resource types counted,
  never dropped (`azurerm_storage_account`, `azurerm_resource_group`,
  `azurerm_application_insights`, `azurerm_log_analytics_workspace`,
  `Microsoft.Insights/actionGroups`,
  `Microsoft.OperationalInsights/workspaces`); `${var.environment}` /
  `${envName}` interpolations surface typed `unresolved`, never guessed.
- **Generate**: `smalt.manifest.json` with 8 seed fixtures;
  unresolved summary: 2 orphan namespaces, 4 unresolved storage-account refs,
  0 orphan containers/vaults/databases, 0 scan errors.
- **Inject**: loopback-only `.env.smalt`, 9 lines, services
  `blob, cosmos, eventhubs, keyvault, servicebus`.

Demo replay (offline legs):

    .venv-cli/bin/python - <<'PY'
    from pathlib import Path
    from smalt_cli.migrate.pipeline import run_all
    r = run_all(Path("smalt-cli/tests/fixtures/migrate-enterprise"),
                Path("out"), Path("out/.env.smalt"))
    for s in r.stages:
        print(s.name, s.status, s.detail)
    PY

Live verification (`smalt_cli.migrate.verify.run`, loud SKIP when the
substrate is down): run against the generated manifest's services — measured
2026-10-21 with the substrate up: PASS on blob/cosmos/kv/servicebus,
`zero_egress: true`, hosts `["127.0.0.1"]`.
