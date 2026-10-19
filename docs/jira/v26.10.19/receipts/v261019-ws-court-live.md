# Receipt: ws-court LIVE leg — substrate up, ARM probe PASS

- **Date**: 2026-10-19
- **Lane**: read-mostly witness lane (ws-court live leg)
- **Repo**: /Users/sac/smalt
- **Standing**: ALIVE
- **Context**: solo (commands)
- **Scope**: canonical substrate boot + `workspace/scripts/e2e-court.mjs` with the
  9443 control plane live, proving the court's live leg (`live: ARM read-only probe`)
  executes as PASS rather than SKIP. Read-only lane: no code edits, no git.

## Commands and output

### 1. Substrate boot

```
$ bash scripts/substrate.sh up
[UP] acquiring per-WINDOW flock on /tmp/smalt-substrate.lock ...
[UP] lock held on fd 9; spawning substrate with fd 9 CLOSED (9>&-)
[substrate] WARNING: SMALT_SB_SHARED_KEY unset — using the pinned dev default key. Set SMALT_SB_SHARED_KEY (scripts/dev_env.sh) for anything beyond loopback dev.
[UP] spawned pid 41600 (lock fd NOT inherited); verifying listeners...
[UP] lock released (fd 9 closed); substrate stays up, pid tagged in /tmp/smalt-substrate-state/substrate.pid
```

Note: a prior orphan lock-holder (pid 40828, no listening socket) was cleared by
`substrate.sh down` before boot — status read `lock HELD ... ORPHAN` first, `lock FREE`
after.

### 2. Listener verification (all five canonical ports)

```
$ bash scripts/substrate.sh status
[STATUS] port 9443: UP (pid 41600)
[STATUS] port 9444: UP (pid 41600)
[STATUS] port 5672: UP (pid 41600)
[STATUS] port 5673: UP (pid 41600)
[STATUS] substrate UP (pid 41600)

$ nc -z 127.0.0.1 8443  # plus 9443/9444/5672/5673 — all succeeded
Connection to 127.0.0.1 port 8443 [tcp/pcsync-https] succeeded!
port 8443 UP
```

### 3. Court run 1 (substrate up)

```
$ cd workspace && NODE_PATH=$PWD/node_modules node scripts/e2e-court.mjs
...
[PASS] composition: panel component type-surface — tsc --strict --noEmit clean over components+app+lib
[PASS] live: ARM read-only probe — GET http://127.0.0.1:9443/subscriptions?api-version=2020-01-01 -> 200 ({"value":[{"displayName":"Sovereign Smalt Subscription","id":"/subscriptions/00000000-0000-0000-0000-000000000000","stat)

# court verdict
# PASS=50 FAIL=0 SKIP=1
# SKIP: composition: panel rendering: DOM/Web Serial rendering is not executable in node — witnessed instead at the type layer below
EXIT=0
```

Full transcript: 50 PASS lines (40 `import` surface checks + typecheck + crc16/etf/
bellman/jcs/verb-gate/attestation/ledger-chain/serial-codec + panel type-surface +
**live ARM probe**), 1 SKIP (browser-only panel rendering, structural — not the live
leg). Verbatim line for the live leg:

```
[PASS] live: ARM read-only probe — GET http://127.0.0.1:9443/subscriptions?api-version=2020-01-01 -> 200 ({"value":[{"displayName":"Sovereign Smalt Subscription","id":"/subscriptions/00000000-0000-0000-0000-000000000000","stat
```

### 4. Court run 2 (stability, same substrate, no restart)

Identical verdict: `PASS=50 FAIL=0 SKIP=1`, live leg `[PASS] live: ARM read-only probe
— GET http://127.0.0.1:9443/... -> 200`, `EXIT=0`. Two consecutive green runs over one
substrate boot — no flake in the live leg.

### 5. Teardown

```
$ bash scripts/substrate.sh down
[DOWN] killing substrate pid 43148
[DOWN] port 9443 free
[DOWN] port 9444 free
[DOWN] port 5672 free
[DOWN] port 5673 free
[DOWN] done
[STATUS] substrate DOWN / lock FREE
```

(Note: the down step reported `killing substrate pid 43148` vs boot pid 41600 — the
boot spawner begets the actual listener beam as a child; both readings come from
substrate.sh itself, ports confirmed free after.)

## Finding

The live leg was previously SKIP-class (no substrate). With the canonical substrate
up on 9443 (auth `:enforce` default), the court's `live: ARM read-only probe` runs a
real GET to `http://127.0.0.1:9443/subscriptions?api-version=2020-01-01` through
`lib/smalt.ts` (`smaltFetch`) and receives HTTP 200 with the Sovereign Smalt
Subscription payload — PASS in both runs. No code change was needed or made; the
SKIP was environmental (substrate down), not a wiring defect.
