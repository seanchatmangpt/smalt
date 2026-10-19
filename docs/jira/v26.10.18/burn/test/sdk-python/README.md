# Python SDK probes (`test/sdk-python/`)

Each probe runs under its own dedicated virtualenv. Running a probe under the
wrong venv fails on import (or worse, silently uses the wrong SDK version), so
the venv identity is pinned here and in each probe's docstring. Authoritative
per-lane receipts live in `docs/jira/v26.10.14/sdk-results/py-*.md`.

## Venv → probe mapping

| Probe | Venv | Receipt |
|---|---|---|
| `py_arm_resources.py` | `.venv-arm` | `py-arm-resources.md` |
| `py_storage_blob.py` | `.venv-blob` | `py-storage-blob.md` |
| `py_cosmos.py`, `py_headers.py` | `.venv-cosmos` | `py-cosmos.md` |
| `py_eventhub_grid.py` | `.venv-eh` | `py-eventhub-eventgrid.md` |
| `py_servicebus.py` | `.venv-sb` | `py-servicebus.md` |
| `py_resourcegraph_monitor.py` | `.venv-rg` | `py-resourcegraph-monitor.md` |
| `py_auth_keyvault.py` | `.venv-auth` | `py-auth-keyvault.md` |

Every mapping row above was verified against the cited receipt on 2026-10-16
(lane R178d); the receipt is ground truth if this table drifts.

## The PY-5 exception (`run.sh`)

`run.sh` is the PY-5 lane runner. It uses `.venv-eh` (the PY-5 lane venv) to
boot the substrate via `mix run` and run the Event Hubs / Event Grid probes.
Note that `run.sh` is the only entrypoint that boots its own substrate; the
other probes expect a substrate already listening (see each docstring).

## Loud-skip exit-3 contract

`run.sh` never fakes a pass. If the primary substrate lock
(`/tmp/smalt-substrate.lock`) is leaked (the PY-5 finding: a detached beam.smp
inheriting the flock fd) it falls back to the lane lock
(`/tmp/smalt-substrate-py5.lock`); if that lock also cannot be acquired, it
exits **3** — a loud, typed SKIP, never a silent pass. Exit codes: `0` all
probes pass, non-zero probe failure, `3` harness-skip.
