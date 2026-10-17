# how-to-clean

Lane hygiene on a shared checkout: reclaim orphaned build roots, free ports,
and verify teardown left no ETS residue.

## Lane build roots

The canonical build root is `_build`. Every other `_build*` dir in the repo
root is an orphaned lane lease (`MIX_BUILD_ROOT=_build-lane<N>` etc.) unless a
live process still references it. Build roots are leases, not assets.

```bash
just lane-clean-dry    # list candidates with du -sh per dir + total; SKIPs live-referenced roots
just lane-clean        # delete orphaned roots; live-referenced dirs are never touched
```

"Live-referenced" is determined three ways (defense in depth): `lsof +D .`
open-file scan, the cwd of any running beam/elixir/mix process, and the
`MIX_BUILD_ROOT=_build...` env harvested from running processes (`ps eww`).
A root held by a live beam is printed `SKIP (live-referenced)` and kept.
Concurrent-lane law: the coordinator deletes all lane build roots at
integration, BEFORE the final commit; a lane that mints a per-run build root
must delete it `on_exit` in the same file. Never `git stash` in a shared
checkout — snapshot a file via `git show HEAD:path > /tmp/...` instead.

## Port law

Fixed port blocks, one owner each — never pattern-pkill beams:

- Shared substrate: 9443 (ARM), 9444 (TLS twin), 8443 (data), 5672 (AMQP),
  5673 (Event Hubs), 9545 (MCP).
- Bench lane N: `39000+10N .. +5` (lane 33 → 39330-39335, the tf-plan probe;
  lane 39 → 39390-39395, the cleanroom).
- Native lifecycle beam: 29445-29450 (private flock
  `/tmp/smalt-substrate-native.lock`, lock fd closed on spawn).
- Enclave testbed: 29440-29444.

Probes refuse to boot if their block is already held (collision, exit 1) —
so a stuck run leaks as "port already held" and the fix is:

```bash
just substrate-status          # is the shared substrate healthy?
scripts/port_sweep.sh          # dry-run: shows holders per port
scripts/port_sweep.sh -y       # actually kill (explicit opt-in; never pkill beams by pattern)
just substrate-down            # managed stop of the shared substrate
```

## The ETS-table teardown contract

Teardown is not "delete what you created" — it is a fail-closed residue audit
over the resource-bearing Store tables. After a destroy:

- `Smalt.Enclave.State.destroy/1` returns `%{deleted, residue}`: residue maps
  every non-metadata Store table to its remaining keys. Of the 28 Store
  tables, 11 are metadata (LRO operations, subscriptions, cosmos LSN, ledger
  meta, SB tokens/locks/sessions, EH checkpoints, resource-graph tokens,
  attestation baseline, sentinel streams) — they legitimately survive, they
  are bookkeeping, not resource state. 17 resource-bearing tables are audited.
- The lifecycle runner prints `residue clean across 17 tables` and exits 0,
  or `RESIDUE NONZERO: ...` and exits 1. Zero-count residue is the contract:
  a destroy that leaves one row is a failure, not a warning.
- Standalone fence: `mix test test/smalt_ets_baseline_identity_test.exs`
  (fresh Store snapshot → real RG+topic lifecycle over the router → strict
  ETS identity restored).

To check teardown after your own run: `just audit-residue` (apply + destroy +
per-table residue audit, fail-closed).

See Also: [how-to-develop-native.md](how-to-develop-native.md) ·
[how-to-debug-agent.md](how-to-debug-agent.md)
