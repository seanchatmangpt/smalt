# Receipt: cli-01-scaffold — smalt-cli Python substrate

- **Lane**: CLI-1 (scaffold owner)
- **Date**: 2026-10-15
- **Subject**: `/Users/sac/smalt/smalt-cli/` (new directory, uncommitted per instructions)
- **Branch/SHA**: main @ 3fc2543 (worktree dirty from other lanes; no commits made by this lane)

## Produced

| file | role |
|---|---|
| `smalt-cli/pyproject.toml` | package metadata; hard deps typer + pyserial only; pytest config |
| `smalt-cli/README.md` | usage + conventions for the other 7 lanes |
| `smalt-cli/smalt_cli/__init__.py` | package root, `__version__ = "0.1.0"` |
| `smalt-cli/smalt_cli/cli.py` | Typer dispatcher: `test`, `hw`, `daemon`, `audit`, `gate` |
| `smalt-cli/smalt_cli/policy.py` | zero-actuation gate (AU-10): frozen read allowlist, typed refusal, exit 2 |
| `smalt-cli/smalt_cli/config.py` | env endpoints SMALT_ARM/SMALT_EGRESS/SMALT_AMQP → 9443/8443/5672; loopback enforcement; AZURE_* export plan (ADR-PY-001) |
| `smalt-cli/smalt_cli/test_policy.py` | 23 gate unit tests: reads pass, mutations refused typed, allowlist boundary cases, guard exit behavior |

## Commands / exits

- `python3 -m venv .venv` — OK
- `.venv/bin/pip install typer pytest pyserial` — OK
- `.venv/bin/python -m smalt_cli.cli --help` → exit 0, all 5 commands listed
- `.venv/bin/python -m smalt_cli.cli --version` → `smalt-cli 0.1.0`
- `.venv/bin/python -m pytest -q` → **23 passed**, 0 failed (final run)
- Gate end-to-end: `cli gate DELETE https://127.0.0.1:9443/r` → typed refusal JSON on stderr, exit 2; `gate GET ...` → `allowed`, exit 0.

## Defects found and fixed during verification

1. Allowlist matcher compared full URL against path entries — fixed to use `urlparse(url).path`.
2. Prefix matching was unbounded (`startswith`) so `/x/read` allowed `/x/readother` — tightened to exact path or `/`-boundary subpath.
3. `--version` flag not eager — replaced with explicit eager callback.

## Standing

ALIVE for the scaffold surface (dispatcher + gate + config + tests, verified by execution). `test`/`hw`/`daemon`/`audit` bodies are stubs awaiting their owning lanes.

## Falsifier status

Gate refusal falsified adversarially via `test_policy.py` (typed-refusal field set, exit code, path-boundary bypass attempts). No failures remain.
