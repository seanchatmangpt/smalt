# V261019-07 — Clean-Room Reset: full test/ teardown, substrate/conftest substrate-boot lift, all-delete manifest

> **Status at materialization (2026-10-19):** the lifts and manifest this WO
> orders are DONE — `lifts/{ts-run.mjs,conftest.py,assert_eventually-reference.exs}`
> on disk, `receipts/reset-delete-manifest.txt` at 303 rows; deletion landed at
> `64f6099`.

- **Release:** v26.10.19
- **Files owned:** the entire `test/` tree (303 tracked files, no exceptions — operator pin), plus two lift-only reads that MUST happen before deletion: `test/sdk-full/ts-run.mjs` and `smalt-cli/tests/conftest.py`
- **Status at open:** `git ls-files test/ | wc -l` → **303** on HEAD. Subtree census (`git ls-files test/ | awk -F/ '{print $2}' | sort | uniq -c | sort -rn`): e2e 23, sdk-full 22, amqp 18, support 16, sdk-python 16, data_plane 16, azsim 14, sdk-smoke 13, corpus 11, redteam 10, terraform_fixture_per_resource 7, fixtures 7, compliance 7, terraform_fixture 6, security 5, wire 3, py-court 3, enclave-testbed 3, trust_shim_probe 2, chaos 2, arm 2, plus 23 top-level `*_test.exs` (incl. `test_helper.exs`) and remaining singletons. Full 303-path manifest is the delete list — see "Manifest" below.
- **Operator pin:** deletion is unconditional. There is no keep-list, no `git rm` exemption for green courts, no "we'll port that one later" carve-out. Coverage that survives does so by being rebuilt in `verification/ts`, `verification/py` (WO-08, WO-09) and a fresh residual `test/internal` tier — not by grandfathering.

## 0. Pre-deletion lifts (happen BEFORE `git rm`, otherwise the knowledge dies with the tree)

Two artifacts encode boot/poll/auth machinery that WO-08/WO-09 rebuild against external checkouts. Extract their content now (copy into the new trees or into `docs/jira/v26.10.19/receipts/`):

1. **Substrate boot** — `test/sdk-full/ts-run.mjs` (full file, 178 lines):
   - Canonical port set + env overrides (`ts-run.mjs:26-31`): AMQP 5672, EH 5673, ARM 9443, egress 8443, ARM-TLS 9444 via `SMALT_TS_{AMQP,EH,ARM,EGRESS,ARM_TLS}_PORT`.
   - Boot eval (`ts-run.mjs:75-87`): `mix run --no-start --no-halt -e` with `Application.put_env(:smalt, :sb_shared_key/:sb_endpoint/:amqp_port/:event_hubs_port/:arm_port/:egress_port/:arm_tls_port, ...)` then `{:ok, _} = Application.ensure_all_started(:smalt)` plus `Smalt.Store.put(:smalt_attestation_baseline, MEASUREMENT, ...)` seeding (fixed hex64 `MEASUREMENT = "11".repeat(32)`, :40-41).
   - TLS material: `SMALT_TLS_CERTFILE`/`SMALT_TLS_KEYFILE` from `scripts/gen_dev_cert.sh` output at `.smalt/tls/{ca-cert,dev-cert,dev-key}.pem`, fail-closed exit 3 if missing (`ts-run.mjs:43-55`); `NODE_EXTRA_CA_CERTS` wired to the dev CA so real SDKs trust it (`ts-run.mjs:140`).
   - Port-free preflight with remediation string `lsof -ti tcp:<port> | xargs kill -9` (`ts-run.mjs:63-73`).
   - TCP poll-until-listening with `POLL_DEADLINE_MS = 90_000` (`ts-run.mjs:34`, poll loop :123-137) — deadline-bounded, no fixed sleep.
   - Process-group teardown: `detached: true` + `process.kill(-pid)` escalation ladder SIGTERM→SIGKILL with bounded wait, signal handlers on SIGINT/SIGTERM/SIGHUP and an `exit` sweeper (`ts-run.mjs:89-120`).
   - Watchdog: `SMALT_TS_WATCHDOG_MS` default 200s → suite SIGKILL, exit 124 (`ts-run.mjs:36, 155-167`).
   - Fail-closed exit contract (`ts-run.mjs:5-10`): 0 pass / 1 test failure / 2 substrate-never-up / 3 harness failure / 124 watchdog.
2. **conftest machinery** — `smalt-cli/tests/conftest.py` (this file lives OUTSIDE `test/` and survives, but its patterns are the lift source for `verification/py`):
   - Session protocol: fixture-scoped lazy provisioning, NO import-time boot; two mutually exclusive auth profiles — `pytest -m anonymous` (ports 39643/39644, lock `/tmp/smalt-substrate-cli4.lock`) vs `pytest -m enforce` (ports 38654/38655/38672/38673/38656, lock `/tmp/smalt-substrate-cli5.lock`).
   - Reuse-else-boot: probe port block, reuse only with a boot marker (`/tmp/cli[45]-substrate.boot.json`, marker age ≤ MAX_REUSE_AGE, marker pid == actual ARM-port listener via lsof — the R177b identity guard); stale listeners swept, never adopted on faith.
   - `_ENFORCE_BOOT_SEED` queue seeding via `Smalt.Amqp.QueueStore.ensure_queue/1` + `Smalt.Store.put(:smalt_resources, key, %{"properties" => props})` (lockDuration `"PT2S"` on the lock queue).
   - `sts_token()` client_credentials against `{ARM}/oauth2/v2.0/token` with claims decode; `mint_jwt()` HS256 helper; raw-JSON `http()` helper returning `(status, parsed)`; `_kill_substrate` poll-based escalation (no blind 1s sleeps — D3, 50ms polling with a 5s SIGKILL deadline).
   - Loud-skip discipline (R186): on substrate-unavailable, `_skip_substrate_unavailable` includes holder pid + log tail rather than a silent skip.

## 1. The delete

`git rm -r test/` — all 303 paths, single commit. Include untracked-but-present build artifacts only as directory removal (`test/sdk-full/node_modules/`, `__pycache__/`, `.logs/`, stray `py5-*.log`/`substrate.log` in `test/sdk-python/` are already untracked; the tracked census above is the authoritative manifest).

**Do NOT delete in this WO:** `smalt-cli/tests/` (outside `test/`; its conftest is the WO-09 lift source and stays until WO-09 rehomes it), `scripts/gen_dev_cert.sh`, `docs/jira/` receipts.

## 2. Manifest form

Emit the delete list as a receipt artifact (counts must reconcile to 303):

```
git ls-files test/ > docs/jira/v26.10.19/receipts/reset-delete-manifest.txt
wc -l docs/jira/v26.10.19/receipts/reset-delete-manifest.txt   # must print 303
```

Per-subtree counts above are the checksum of the manifest; any drift between census and manifest at execution time re-runs the census — the receipt records the number actually deleted, not the number planned.

## 3. Sequencing & blast radius

1. Extract `ts-run.mjs` + `conftest.py` lifts to the WO-08/WO-09 working trees (or a receipts file) — **blocking first step**.
2. `git ls-files test/ | xargs git rm` at a pinned SHA (flock discipline per WO-1).
3. `mix compile` still green (no lib code may import test helpers — grep `Code.ensure_compiled.*Test` / `test/support` aliases in `mix.exs` `elixirc_paths`; if `mix.exs` has a `test/` elixirc path clause, strip it in the same commit).
4. Recreate only the fresh residual `test/internal` tier (per WO-08/WO-09 close conditions, new files, not restored ones).

**Acceptance / falsifier:**
- `git ls-files test/` immediately post-deletion returns **0 lines** (before the new tier lands). After the rebuild window closes, it returns ONLY recreated internal-tier paths — any pre-reset path reappearing is a grandfathering violation and fails the WO.
- `wc -l < reset-delete-manifest.txt` == 303.
- `mix compile` and `mix test test/internal/` green post-rebuild; `grep -rn "ts-run\|py_arm_resources\|sdk-smoke" mix.exs justfile` shows no dangling references to deleted suites (justfile recipes referencing `test/sdk-full` are updated or removed in the same window).
