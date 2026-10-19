# V261019-09 — verification/py: external official-SDK suite (5 workflows), Python mirror

- **Release:** v26.10.19
- **Files owned (new tree):** `verification/py/` — `conftest.py` (lifted), `pyproject.toml` fragment or `requirements-azure.txt`, `harness/{substrate,credential,poll,assert,enum}.py`, `wf1..wf5/test_*.py`, `run.sh`
- **Status at open:** does not exist as an external suite. Lift sources: `smalt-cli/tests/conftest.py` (machinery) and the deleted `test/sdk-python/py_*.py` + `run.sh`/`boot_substrate.py` (extracted per WO-07 §0).

## 1. Layout (mirror of verification/ts)

```
verification/py/
  conftest.py           # lifted smalt-cli conftest: lazy session fixtures, reuse-else-boot, R177b marker guard
  harness/
    substrate.py        # _ensure_substrate / _kill_substrate / boot-eval strings / port blocks
    credential.py       # sts_token(), mint_jwt(), bearer(), SharedKey signing (from conftest.py)
    poll.py             # deadline-bounded poll helper (Event.wait(timeout=…)-based, per py run.sh:118 shape)
    assert.py           # wire-shape assertions + verdict mapping
    enum.py             # GREEN / REGISTERED-DIVERGENCE / MISSING (same three-verdict contract as WO-08 §3)
  wf1..wf5/test_wfN.py
  run.sh                # pytest -m <profile> orchestration, no fixed sleeps (see §4)
```

Workflow set (five, mirroring the ts suite; former `test/sdk-python/` imports are the coverage map):
1. **wf1 — Messaging**: `azure-servicebus` + `azure-eventhub` against the enforce AMQP/EH ports (`SMALT_SB_SHARED_KEY`, cf. former `py_servicebus.py:28`, `py_eventhub_grid.py`).
2. **wf2 — Storage**: `azure-storage-blob` SharedKey conn string (former `py_storage_blob.py`).
3. **wf3 — Data**: `azure-cosmos` master-key (former `py_cosmos.py`).
4. **wf4 — Management/Monitor**: `azure-mgmt-resource`/`azure-mgmt-resourcegraph` + `azure-mgmt-resource.subscriptions` + `azure-monitor.query` (former `py_arm_resources.py`, `py_resourcegraph_monitor.py`, incl. the five-seeded-accounts pagination fixture — conftest `seeded_resources`).
5. **wf5 — Identity/Keys/Events-grid face**: `azure-identity`-shaped STS client_credentials, `azure-keyvault-keys`/`azure-keyvault-keys.crypto` (former `py_auth_keyvault.py`), `azure-eventgrid` **only if** re-scoped in with WO-2 G3; default is excluded to mirror WO-08's no-eventgrid rule — wf5 defaults to identity+keyvault and the grid face stays with the G3 engine work.

## 2. conftest lift

`verification/py/conftest.py` carries over, verbatim in mechanism:
- Two-profile marker protocol (`pytest_configure` registering `anonymous` / `enforce`, per conftest `pytest_configure`); port blocks 39643/39644 (anon) and 38654/38655/38672/38673/38656 (enforce) with `_ANON_BOOT`/`_ENFORCE_BOOT` eval strings + `_ENFORCE_BOOT_SEED` queue seeding.
- Reuse-else-boot under per-profile flock with the R177b marker guard (marker-present AND age ≤ MAX_REUSE_AGE AND marker pid == ARM listener, lsof-verified; stale listeners swept).
- `_kill_substrate` poll-based kill (5s deadline, 50ms exit-polling, `os.killpg` SIGKILL escalation — the D3 no-blind-sleep pattern).
- R186 loud-skip: substrate-unavailable skips carry holder pid + log tail.
- Session teardown restores module-level ARM/EGRESS and kills only a substrate this session booted (the SHIM-COURT total-path discipline: `proc` bound before `try`).

Changes on lift: (a) namespaced locks/markers (`/tmp/smalt-verif-py-{anon,enforce}.lock` / `.boot.json`) so the suite cannot collide with any surviving smalt-cli lane; (b) drop the smalt-cli-specific `SUB = "sub-cli4"` naming in favor of a `SMALT_VERIF_SUB` env default.

## 3. Packaging: azure optional-extra

`smalt-cli/pyproject.toml` today declares only `dev = ["pytest>=8.0"]` and `aio = ["aiohttp>=3.9"]` under `[project.optional-dependencies]` (pyproject.toml:15-17). The azure SDK set moves to the verification tree's own packaging — either a standalone `verification/py/pyproject.toml` or a requirements file pinned per SDK. Required extra:

```
[project.optional-dependencies]
azure = [
  "azure-servicebus", "azure-eventhub", "azure-storage-blob",
  "azure-cosmos", "azure-mgmt-resource", "azure-mgmt-resourcegraph",
  "azure-monitor-query", "azure-keyvault-keys", "azure-identity",
]
```

(The exact import census from the former suite: `azure.core.exceptions/credentials/messaging/pipeline.policies`, `azure.cosmos`, `azure.eventhub`, `azure.servicebus` + `azure.servicebus.management`, `azure.keyvault.keys` + `.crypto`, `azure.mgmt.resource(.subscriptions/.resourcegraph/.models)`, `azure.monitor.query`, `azure.storage.blob` — 19 distinct `from azure…` imports across `test/sdk-python/py_*.py`.) No azure dep may land in smalt-cli's core `dependencies` (typer/pyserial stay the only core deps, pyproject.toml:11-14).

## 4. asyncio races & no fixed sleeps

- Workflows are sync pytest by default (the former suite is sync `urllib`/SDK); any async check uses `pytest-asyncio` with **explicit event-loop fixtures and awaited futures**, never `asyncio.sleep(N)` as a readiness wait. Race courts (send-vs-lock-renew, receive-vs-reclaim) are structured as concurrent tasks joined with `asyncio.gather` + deadline-bounded `asyncio.wait_for`, so outcome is asserted on final state, not on interleaving luck — the same determinism bar as the v26.10.14 exemplar F3 court ("2-process racing release-vs-claim … no sleeps").
- Boot/teardown readiness goes through `harness/poll.py` only (deadline + condition; `run.sh` port-probe loop with `sleep 0.05`/`sleep 0.2` at :53/:68 is the boot-probe exception, confined to run.sh, not workflow bodies).
- Former-suite cap classes (`if not done.wait(timeout=25)` at py run.sh:118) are replaced by poll.py deadlines sized to CI budget.

## 5. Native-exception table

`harness/assert.py` carries a typed table mapping SDK native exceptions to expected emulator faces, so workflows assert typed exceptions instead of bare `except Exception` (the former suite's `py_eventhub_grid.py:33,84,91,188` bare-except pattern and `test_servicebus.py:73` `# noqa: BLE001` are the anti-pattern being retired):

| SDK exception | Raised by | Expected emulator face |
|---|---|---|
| `HttpResponseError` (status 404, `error.code == "RouteNotReady"`) | mgmt/data clients on unmounted routes | MISSING verdict surface (WO-6 peek/clear class) |
| `HttpResponseError` (400, `SyntaxError`/`InvalidQuery`) | cosmos query on non-whitelist SQL | v26.10.14 07-cosmos item 5 whitelist gate |
| `ClientRequestError` / malformed-request family | bad api-version, forged continuation token | typed 400 corpus rows |
| `AuthenticationError` (401) | missing/bad Bearer or SAS | enforce-mode fence (conftest enforce profile) |
| `ServiceRequestError` / connect failures | substrate down | loud-skip (R186) or exit 2 per runner contract |
| `ResourceNotFoundError` | absent blob/container/key | MISSING verdict |

Every catch in a workflow must name a table row; a bare `except Exception` fails review. Rows map 1:1 to the WO-08 enum verdicts so cross-language rollups (GREEN / REGISTERED-DIVERGENCE / MISSING) are directly comparable with `verification/ts`.

**Acceptance criteria:**
- [ ] `cd verification/py && pip install -e '.[azure,dev]' && bash run.sh` boots per-profile substrates, runs wf1–wf5, exits 0 with the verdict table; substrate-down path exits 2/loud-skips with holder pid + log tail.
- [ ] conftest reuse-else-boot demonstrated: second invocation reuses a healthy substrate (marker present, pid match) and kills nothing it did not boot.
- [ ] `grep -rn "except Exception" verification/py/wf*/` → 0 hits; every catch cites a native-exception table row.
- [ ] `grep -rn "asyncio.sleep\|time.sleep" verification/py/wf*/ verification/py/harness/poll.py` → 0 hits (run.sh boot probe excepted).
- [ ] azure deps live only in the optional extra; `pip install smalt-cli` (core) pulls no azure package.
- [ ] No `test/sdk-python` survivors per the WO-07 falsifier (`git ls-files test/` post-rebuild shows only the fresh internal tier).
