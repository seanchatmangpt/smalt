# T26 — One-Command Migration Rehearsal Demo

**Standing: ALIVE** — real end-to-end run against the live substrate, exit 0.

## Script

`scripts/demo_migration_rehearsal.sh` (new, executable). One command:

```bash
bash scripts/demo_migration_rehearsal.sh [iac-dir] [workdir]
```

Chains `smalt-cli migrate all` (scan → generate → inject, typed per-stage
lines) plus `smalt-cli migrate verify` (wire-fidelity gate, REQ-4.1/4.2) over
the enterprise fixture `smalt-cli/tests/fixtures/migrate-enterprise`
(12 files, 66 resource blocks) into a fresh `mktemp -d` workdir.

Exit contract:

- `0` — all 4 stages ok, `REHEARSAL-PASS`
- `2` — substrate down: loud typed `[SKIP]` line per stage, never a fake pass,
  never boots the substrate (lane never restarts the shared substrate)
- `3` — harness skip (venv/fixture missing) or any stage failed, `REHEARSAL-FAIL`

Probe seam: `ARM_PROBE_URL` (default `http://127.0.0.1:9443/`) — lets the
down-branch be proven without stopping the shared substrate.

## Run output (live, 2026-10-21)

Command: `bash scripts/demo_migration_rehearsal.sh` — **EXIT=0**

```
[rehearsal] substrate UP (ARM 9443 probe=401); iac=/Users/sac/smalt/smalt-cli/tests/fixtures/migrate-enterprise
[rehearsal] workdir=/tmp/t26-rehearsal.HOOSRp

| stage    | status | detail |
|----------|--------|--------|
| scan | ok | {'files_scanned': 12, 'resource_blocks': 66, 'unsupported_types': {'Microsoft.Insights/actionGroups': 1, 'Microsoft.OperationalInsights/workspaces': 1, 'azurerm_application_insights': 1, 'azurerm_log_analytics_workspace': 1, 'azurerm_resource_group': 1, 'azurerm_storage_account': 1}, 'scan_errors': 0} |
| generate | ok | {'manifest_path': '/tmp/t26-rehearsal.HOOSRp/out/smalt.manifest.json', 'seed_fixtures': 8, 'bytes': 40139} |
| inject | ok | {'env_path': '/tmp/t26-rehearsal.HOOSRp/.env.smalt', 'backup_written': False, 'services': ['blob', 'cosmos', 'eventhubs', 'keyvault', 'servicebus'], 'lines': 9} |
| verify | ok | zero_egress true; receipt=/tmp/t26-rehearsal.HOOSRp/migration-receipt.json |

[rehearsal] REHEARSAL-PASS stages=4/4 iac=/Users/sac/smalt/smalt-cli/tests/fixtures/migrate-enterprise workdir=/tmp/t26-rehearsal.HOOSRp
```

Verify receipt (migration-receipt.json): all services ok —
`[('blob', True), ('cosmos', True), ('kv', True), ('servicebus', True)]`,
`zero_egress=True`, `hosts=['127.0.0.1']` (REQ-4.2 loopback-only asserted by
the gate itself).

## Non-vacuity (down branch witnessed)

`ARM_PROBE_URL=http://127.0.0.1:9999/` (dead port) — the skip path fires
loudly, exit 2, substrate untouched:

```
[scan] SKIP: substrate-down — ARM plane 9443 not answering (probe=000/no-answer); NOT booting (lane never restarts the shared substrate)
[generate] SKIP: substrate-down — ...
[inject] SKIP: substrate-down — ...
[verify] SKIP: substrate-down — ...
[rehearsal] REHEARSAL-SKIP substrate-down
EXIT=2
```

## Defects found and fixed in-session

1. `${S_STATUS[$s]}` with string keys required `declare -A` (was `declare -a`,
   `scan: unbound variable` under `set -u`, exit 1).
2. Down-detection originally used a non-matching glob guard that classified
   probe=000 as UP; replaced with `[[ -z "$ARM_CODE" || "$ARM_CODE" == "000" ]]`.
3. Upstream note: `migrate verify --manifest <generated manifest>` fails with
   `ValueError: no 'services' list` — the generated `smalt.manifest.json` does
   not carry a `services` key, so the demo passes `--services` explicitly.
   Candidate upstream fix (not landed from this lane): have `build_manifest`
   emit `services: sorted(discovered_services(topo))`.

## Notes

- Zero network beyond loopback: the verify gate records every host touched and
  asserts 127.0.0.1-only before emitting its receipt.
- Verify rode the real wire: blob container/block/byte-equal/delete, cosmos
  etag mint + CAS 200/412, KV secret set/get/delete, ServiceBus ARM queue
  ensure + send/receive/complete over AMQP.
- Workdir artifacts are scratch (`/tmp/t26-rehearsal.*`), not indexed.
