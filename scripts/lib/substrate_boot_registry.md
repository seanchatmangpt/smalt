# Substrate Boot Registry — design notes

`scripts/lib/substrate_boot.sh` + `scripts/substrate-ctl`. Generalization of
the per-harness boot machinery (lifted from
`docs/jira/v26.10.19/lifts/ts-run.mjs` and the identity-guard pattern in
`smalt-cli/tests/conftest.py`) into one sourced bash library + one CLI.

## Two-tier lock topology

```
/tmp/smalt-substrate.lock          # front door: canonical ports
                                   #   5672 5673 9443 8443 9444 9545
/tmp/smalt-substrate-<block>.lock  # lane blocks (private port ranges)
```

Acyclic lock order: **substrate.lock > block lock > any other**. A lane
touches exactly ONE lock in this library — the canonical block takes only
the front door, every lane block takes only its own — so no lock cycle is
constructible. The lock is held per-WINDOW (while spawning + verifying
health), never for the substrate's lifetime; the substrate is spawned
`9>&-` and detached, so it outlives the lock without holding it.

## Port-block formula

Role order in every block (6 ports): `amqp eh arm egress tls mcp`.

| block | formula | example |
|---|---|---|
| `front`/`canonical` | fixed | 5672 5673 9443 8443 9444 9545 |
| `bN` (N=1..99) | 39000+10N .. +5 | b1 = 39010–39015 |
| `cN` (N=1..99) | 39200+10N .. +5 | c1 = 39210–39215 |
| `vN` (N=1..99) | 39700+10N .. +5 | v1 = 39710–39715 |

## fd-9 law

The block lock is acquired on fd 9 (`exec 9>lock; flock -w $SMALT_LOCK_WAIT 9`).
The substrate spawn passes `9>&-` explicitly, and after health is confirmed
`sb_assert_no_fd9_leak` lsof-proves that no descendant of the spawn
(spawn -> mix -> beam, 3 levels, same tree-walk shape as
`scripts/substrate.sh tree_pids`) holds the lock file on ANY fd. Any holder
=> kill the spawn tree, remove the marker, exit 2. This closes the witnessed
27-minute starvation channel (a harness that lets the beam inherit the flock
fd holds the lock + ports after the harness exits).

## Marker schema and identity guard

`/tmp/smalt-substrate-state/markers/<block>.boot.json`:

```json
{"block": "b1", "ports": [39010, 39011, 39012, 39013, 39014, 39015],
 "pid": 84848, "auth": "anonymous", "booted": 1792428235,
 "log": "/tmp/smalt-substrate-state/logs/b1.log"}
```

Reuse is lawful ONLY when ALL of:
- marker present and parseable;
- age `now - booted <= 3600s` (`SMALT_SB_MAX_REUSE_AGE`);
- marker `pid` is in the lsof LISTEN set of the block's ARM port;
- marker `auth` equals the requested auth (mismatch is logged as
  `GUARD ... auth mismatch — sweep+fresh`, never silently adopted).

Anything else (missing/stale/foreign marker, wrong pid, wrong auth) =>
beamish-only sweep (SIGTERM to mix/beam LISTENers on the block's ports;
non-beam squatters are logged, NOT killed) + fresh boot. Sweep drain is
deadline-bounded (10s, `SB_SWEEP_DRAIN`); ports still occupied after the
drain => exit 3 fail-closed.

### Probe split (backlog hazard, witnessed 2026-10-19)

A CONNECT probe consumes a slot in the listener's accept backlog. Against a
pathological squatter with a tiny backlog (`listen(1)`), the first probe
succeeds and every later probe false-negatives — the sweep drain then
reports "drained" while the port is held, and the boot dies on bind. Split:

- `sb_port_listening` (lsof LISTEN, side-effect free): occupancy checks,
  sweep drain, reuse check, status.
- `sb_port_open` (bash /dev/tcp connect): health poll only, against the
  real beam which accepts continuously.

## Health poll (no-sleep law)

Bounded poll every 250ms until all 6 ports accept AND
`curl http://127.0.1:<arm>/metadata/endpoints` returns 200, deadline
`SMALT_UP_TIMEOUT` (default 90s). Spawn pid death pre-ready => typed
`SUBSTRATE_DIED` with a 30-line boot-log tail (exit 2); deadline expiry =>
`SUBSTRATE_TIMEOUT` (exit 2). No fixed sleeps; every wait is a bounded poll
on a real observable.

## Boot-eval shape (lifted from ts-run.mjs)

```
MIX_ENV=test mix run --no-start --no-halt -e '
  Application.put_env(:smalt, :sb_shared_key, "<random>");
  ... arm_port / amqp_port / event_hubs_port / egress_port /
      arm_tls_port / mcp_port / auth_mode ...;
  {:ok, _} = Application.ensure_all_started(:smalt)'
```

### Operator-env bridge (KD-110 mechanism, fixed 2026-10-19)

`SMALT_ARM_RATE_LIMIT` / `SMALT_COSMOS_RU_LIMIT` (integer-valued) are bridged
into app env by the boot eval (`Application.put_env(:smalt, :arm_rate_limit, N)`)
before `ensure_all_started`. Mechanism: the ARM throttle plug reads
`Application.get_env(:smalt, :arm_rate_limit, :infinity)` DIRECTLY
(`lib/smalt/arm_gateway/router.ex`), not the env-first accessor
`Smalt.Config.arm_rate_limit/0` — so the env var sat in `System.get_env`,
unreachable by the plug, and `substrate-ctl` boots throttled nothing
(KD-110 evidence lane: 0x429 witnessed). The ctl spawn already inherits the
operator env and never sanitized it — the defect was the plug's read path,
bridged here without touching the router (router fix belongs to its lane).

### KNOWN-INTERACTION: ARM throttle disarms after first burst (router, NOT fixed here)

Witnessed live 2026-10-19 on block b3 (limit=10, boot A-leg): burst 1 →
56x200 + 4x429 (throttle armed); immediately-after burst 2 (same wall
second-window chain, 120 requests) → 115x200 + 5x500, ZERO 429s. The 500s
match the shadow-ETS defect: `rate_table/0` creates the
`:smalt_arm_rate` table from the request process — when that process dies
the table dies with it; subsequent `:ets.update_counter` raises and renders
as 500 while the throttle is silently disarmed (`router.ex` ~:200). The fix
belongs to the router lane (own the table from a supervision-tree process,
typed behavior on table death); this registry records the interaction only.

Spawned detached (`9>&-`), `MIX_BUILD_ROOT` isolation via env passthrough,
boot log at `/tmp/smalt-substrate-state/logs/<block>.log`. TLS gate: refuses
(exit 1) unless `.smalt/tls/{ca-cert,dev-cert,dev-key}.pem` exist (hint:
`bash scripts/gen_dev_cert.sh`); exports `SMALT_TLS_CERTFILE/KEYFILE` +
`SSL_CERT_FILE`.

## Receipt

The LAST stdout line of a successful `up` is:

```json
{"block": "b1", "ports": [39010, 39011, 39012, 39013, 39014, 39015],
 "pid": 84848, "reused": false,
 "marker": "/tmp/smalt-substrate-state/markers/b1.boot.json", "auth": "anonymous"}
```

## Exit contract

| code | meaning |
|---|---|
| 0 | up or reused |
| 1 | refused (unknown block, bad args->64 aside, TLS missing, owner-down with unverifiable marker) |
| 2 | substrate died pre-ready or health timeout |
| 3 | lock timeout OR ports occupied after sweep |
| 64 | usage error |

## Falsifier spec (non-vacuity)

1. **Collision storm (8 lanes)**: run `substrate-ctl up --block b<N>`
   N=1..8 concurrently; each must return 0 with a distinct port set and
   pid; no lane may hold another's lock (`lsof /tmp/smalt-substrate-*.lock`
   empty after all boots). Then run the same block b1 from 4 concurrent
   callers: exactly one boots (`reused:false`), three reuse (`reused:true`)
   with the SAME pid as the receipt.
2. **fd-9 leak proof**: after any successful up,
   `lsof /tmp/smalt-substrate-<block>.lock` must be empty while the
   substrate is still up — the substrate does NOT hold its own lock.
   Negative control: a spawn with `9>&-` removed (shim, marker
   `SHIM-COURT`) must trip `sb_assert_no_fd9_leak` and exit 2.
3. **Hostile identity**: rewrite the marker with a fresh `booted`, correct
   auth, but a pid that is not the ARM listener => the next `up` must
   sweep + boot fresh (`reused:false`, new pid), never adopt. (Witnessed:
   marker pid+1, up returned reused:false pid+3 — adopted nothing.)
4. **Auth mismatch**: marker auth=anonymous, request --auth enforce =>
   `GUARD auth mismatch` log + sweep + fresh boot, exit 0 with the new
   auth in the receipt.
5. **Occupied-after-sweep**: non-beam python listener on one block port =>
   up must exit 3 with `ports still occupied after sweep` (witnessed).
   Regression guard: the sweep drain must use the lsof probe, not connect —
   a connect-probe shim against a `listen(1)` squatter flips this to a
   spurious SUBSTRATE_DIED (witnessed defect, fixed by the probe split).
6. **Lock timeout**: hold the block lock with `flock -x ... -c 'sleep 8'`,
   run up with `SMALT_LOCK_WAIT=2` => exit 3 with
   `lock timeout ... (holder: lsof <lock>)` (witnessed; also witnessed the
   inverted-rc defect where `if ! acquire` collapsed 3 to 1 — fixed by
   capturing rc before negation).

## Regression ledger (this window)

| case | first run | after fix |
|---|---|---|
| up fresh (b1, anonymous) | exit 0, JSON receipt | — |
| reuse | reused:true, same pid | — |
| `--fresh` sweep+reboot | exit 0, new marker | — |
| hostile marker pid | sweep+fresh, nothing adopted | — |
| auth mismatch | GUARD + fresh | — |
| occupied-after-sweep (python squatter) | **exit 2 (WRONG)** | exit 3 typed |
| lock timeout | **exit 1 (WRONG)** | exit 3 (up and down) |
| fd-9 leak | lsof: no holder of block lock while substrate up | — |
| owner down, wrong default auth | typed refusal exit 1 | — |
| owner down, matching auth | exit 0, ports drain | — |
