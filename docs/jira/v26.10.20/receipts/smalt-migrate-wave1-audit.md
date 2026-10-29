# smalt-migrate wave 1 — audit receipt (M6)

Date: 2026-10-21. Auditor: M6 docs/audit lane.
Scope: `smalt-cli/smalt_cli/migrate/` (M1 scan, M2 manifest, M3 inject, M4 verify, M5 pipeline) + `smalt-cli/tests/test_migrate_*.py`.
Method: bounded-poll for lane files (polling started 10:29, all files on disk by 10:44), then independent execution of every pytest suite and direct code inspection.

## Files audited (all landed by 10:44)

| Module | Bytes | Tests | 
|---|---|---|
| scan.py (M1) | 15,460 | tests/test_migrate_scan.py (9) |
| manifest.py (M2) | 7,848 | tests/test_migrate_manifest.py (9) |
| inject.py (M3) | 7,658 | tests/test_migrate_inject.py (12) |
| verify.py (M4) | 16,478 | tests/test_migrate_verify.py (7) |
| pipeline.py (M5) | 5,514 | tests/test_migrate_pipeline.py (8) |
| terraform.py / bicep.py (M1 extractors) | 6,594 / 12,315 | covered via scan/pipeline tests |

## Per-lane verdicts

| Lane | Verdict | Evidence |
|---|---|---|
| M1 scan | PASS | 9/9 tests green (python3 and .venv-cli). Typer `scan` command registered, witnessed via CliRunner `migrate --help`. |
| M2 manifest | PASS | 9/9 green. `generate` registered in cli.py:80. NFR-3 byte determinism witnessed: `test_nfr3_determinism_byte_identical` (byte-identical manifests across runs, no timestamp keys) + `test_render_manifest_sorted_keys_trailing_newline`. Full non-verify set (37 tests) passed twice, interpreters python3 and .venv-cli. |
| M3 inject | PASS | 12/12 green. NFR-1 read-only honored: imports are stdlib base64/hashlib/json/shutil/pathlib + typer only; no urllib/requests/socket/subprocess anywhere in inject.py (or scan/manifest/terraform/bicep/pipeline). Only I/O is the .env.smalt write + .bak backup; `--dry-run` writes nothing. Loopback-only endpoints (127.0.0.1). |
| M4 verify | PASS (1 env note) | 6 passed, 1 loud typed skip under .venv-cli. |
| M5 pipeline | PASS (1 registration gap) | 8/8 green incl. `test_pipeline_nfr2_50_resources_under_30s` (NFR-2 budget). |

## M4 environment note

Under the system python3 the verify suite fails 2 tests with `ModuleNotFoundError: No module named 'azure'` (azure-servicebus not installed); under the repo's `.venv-cli` (which has the Azure SDK) the same suite is green with the designed LOUD TYPED SKIP on the AMQP leg (substrate booted `ws8sharedkey`, key below the 32-byte SasVerifier floor). Verdict unchanged: run the verify lane under `.venv-cli`. azure-servicebus is an undeclared optional dependency in pyproject.toml — flag to the M4 owner.

## Findings (standing, non-blocking)

1. **M5 registration gap**: `pipeline_app` / `pipeline_all_command` (smalt_cli/migrate/pipeline.py:27,145) is NOT registered in smalt_cli/cli.py — `smalt-cli migrate pipeline` is unreachable from the CLI. Library surface (`run_all`) fully tested.
2. **M4 has no Typer command**: verify.py exposes `run()`/`VERIFIERS` as a library only; no `smalt-cli migrate verify` command exists. Documented as library-only in the README.
3. **Undeclared optional dep**: azure-servicebus used by migrate/verify.py but absent from pyproject `[project.optional-dependencies]`.
4. **README-convention violation in a test**: tests/test_migrate_verify.py:107 writes `/tmp/migration-receipt-test.json`; smalt-cli/README.md forbids /tmp artifacts ("Everything in-repo: no /tmp artifacts").
5. `scan` CLI arg help says ".tf files" only; scan consumes both .tf and .bicep (pipeline.scan_all merges both extractors).

## Command registration witness

`migrate --help` (CliRunner) lists: scan, inject, rollback, generate. Sub-app mounted at cli.py:75; generate at cli.py:80; inject/rollback registered via `migrate_app.command` decorators in inject.py; scan at scan.py:388.

## How to reproduce

    cd /Users/sac/smalt/smalt-cli
    .venv-cli/bin/python -m pytest tests/test_migrate_scan.py tests/test_migrate_manifest.py tests/test_migrate_inject.py tests/test_migrate_verify.py tests/test_migrate_pipeline.py -q
    # => 37 passed, then 6 passed / 1 skipped (loud typed skip, undersized boot key)

## Standing

**Standing:** PARTIAL_ALIVE — audit executed, all five lane suites green with embedded pytest output (37 passed; verify 6 passed / 1 loud typed skip under .venv-cli); 5 non-blocking findings remain open to owners.
