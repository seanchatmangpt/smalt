# fin-11: census front door pins substrate ports (TS-4 harness finding)

- Subject: `scripts/sb_census_replay.sh` (repo `/Users/sac/smalt`, branch `main`, no commit)
- Standing: ALIVE (witnessed execution on exact subject)

## Defect

`config/test.exs` (lines 23-42) binds each listener to a probed-free **random
ephemeral port** whenever `SMALT_TEST_*_PORT` is unset. The census front door
`scripts/sb_census_replay.sh` never exported any `SMALT_TEST_*_PORT`, so the
substrate landed on random ports while `test/sdk-smoke/census-run.mjs` polls
fixed 5672/9443 — the front door structurally failed exit 2 ("substrate never
came up") even when the substrate was healthy.

## Fix

`scripts/sb_census_replay.sh` now exports, before booting (both overridable,
defaulting into the documented private range 39000-39999 per
`docs/DEV_LOOP.md` "Private port allocation"):

```
SMALT_TEST_ARM_PORT=39790
SMALT_TEST_EGRESS_PORT=39791
SMALT_TEST_AMQP_PORT  =39792
SMALT_TEST_EVENT_HUBS_PORT=39793
```

`SMALT_SDK_ROOT` handling unchanged (same gate + same export). Residual scope:
`SMALT_TEST_ARM_TLS_PORT` / `SMALT_TEST_MCP_PORT` remain unpinned per task
DoD; if 9444/9545 are occupied the substrate boot can still abort (separate
defect class, not the exit-2 port race this fix closes).

## Proof

1. Env unset previously random; now pinned — full front-door run
   (`SMALT_SDK_ROOT=.../test/sdk-smoke/node_modules bash scripts/sb_census_replay.sh`):

   ```
   [census-run] substrate up on 39792/39790 after 1504ms
   ```

   Exit 1 (8/12 pass, 4 probe failures: stale-handle / lock-duration /
   deferred-receive RestError HPE_INVALID_CONSTANT + DEFERRED_DELIVERY_COUNT).
   Exit 1 = census probe failures, pre-existing substrate/SDK gaps — the exit-2
   "substrate never came up" class did not occur; boot was deterministic.

2. Direct substrate boot with the four exported vars, all four pinned ports:

   ```
   port 39790: OPEN
   port 39791: OPEN
   port 39792: OPEN
   port 39793: OPEN
   arm   :39790 /metadata/endpoints -> HTTP 200
   egress :39791 / -> HTTP 200
   ```

   (No `/health` route exists on the ARM gateway; `/metadata/endpoints` and
   egress `/` serve as the HTTP-200 liveness witnesses. The AMQP/EH ports are
   witnessed via the census run itself: CBS put-token status=200 over
   127.0.0.1:39792.)

3. Teardown: all four ports released, no `mix run --no-halt` process remains.

## Verification ladder

Narrow (port env read by config/test.exs) -> integration (front door boots
substrate on pinned ports) -> e2e (census probes execute against pinned AMQP
port, 8 pass). Falsifier for the original claim: "env unset → previously
random" — `config/test.exs:36` `System.fetch_env("SMALT_TEST_#{name}_PORT")`
falls through to `free_port.()` when unset; exported values now win.
