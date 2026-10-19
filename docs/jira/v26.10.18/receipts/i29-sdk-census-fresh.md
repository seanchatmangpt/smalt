# Receipt: i29 SDK census fresh attempt (SUBSTRATE_DOWN → offline tier)

- Date: 2026-10-18
Context: solo(ports 9443/8443/5672 held by colima ssh mux pid 61023, not a smalt beam; multiple concurrent mix test beams on the machine; offline tier run under load)
- Standing: SUSPECT → environment-blocked; **SUBSTRATE_DOWN** — census leg NOT executed, offline tier executed with failures

## Port pre-flight (why SUBSTRATE_DOWN)

```
$ lsof -nP -iTCP:9443 -iTCP:8443 -iTCP:5672 -sTCP:LISTEN
COMMAND   PID USER   FD   TYPE             DEVICE SIZE/OFF NODE NAME
ssh     61023  sac   11u  IPv4 0x98876537b05ac1f5      0t0  TCP *:9443 (LISTEN)
ssh     61023  sac   14u  IPv4 0x98876537b05ac1f5      0t0  TCP *:5672 (LISTEN)
ssh     61023  sac   18u  IPv4 0x98876537b05ac1f5      0t0  TCP *:8443 (LISTEN)
```

Holder is `ssh: /Users/sac/.colima/_lima/colima/ssh.sock [mux]` (ppid 1, up 7h24m) —
a foreign tunnel, not a live smalt substrate beam. Per directive: no eviction, no kills.
`just sdk-census` therefore NOT run. `just verify-all` run instead.

## Offline tier: `just verify-all` — exit 1 (7 stages failed)

```
==================== VERIFY-ALL VERDICT TABLE ====================
STAGE               RESULT  DETAIL
doctor              PASS    -
doctor-dod          FAIL    exit 1
test-offline        FAIL    exit 2  (2722 tests, 15 failures, 99 excluded)
test-stress         FAIL    exit 2  (2754 tests, 28 failures, 1 invalid, 67 excluded)
test-budget         FAIL    exit 1  (app boot: already started: #PID<0.414.0> — Smalt.Store double-start under concurrent load)
workspace-court     PASS    -
smalt-cli-pytest    FAIL    exit 2  (8 collection errors: ModuleNotFoundError hypothesis/azure — venv deps missing)
naming-sweep        PASS    -
receipt-index-check FAIL    exit 1  (DRIFT — committed index does not match regeneration)
invariant-gates     FAIL    exit 1  (all 4 gates: "substrate exited rc=1 before binding :<ephemeral>")
sleep-gate          SKIP    honest-red pending repair WOs (336 unclassified sites); SLEEP_GATE_ENFORCE=1 to enforce
have-guard          SKIP    un-enforced pending cron install
have-telemetry      SKIP    un-enforced pending cron install
==================================================================
[VERIFY-ALL] FAIL: 7 stage(s) failed.
error: recipe `verify-all` failed on line 8 with exit code 1
```

## Failure causes (observed output)

- **doctor-dod (exit 1)** — 6 FAIL:
  - `smalt-cli/.venv missing`
  - 5 GAP tokens absent from WIRE_PARITY.md: GAP(blob-error-envelope-json),
    GAP(cosmos-sql-translator-absent), GAP(ledger-lazy-create-default),
    GAP(eventhubs-partition-metadata-absent), GAP(eventhubs-consumer-group-enumeration-absent)
  - WARN: 5 live GAP tokens vs census 9 (drift); 2 lane build roots, 676.7 MiB.
- **test-offline / test-stress (exit 2)**: 15 / 28 test failures under concurrent
  machine load (other lanes' `mix test` beams running: sovereign_midnight, stress
  tier, azb14 writer, ggen replay). Named failures include
  Smalt.Azsim.IntegrationPlaneTest (3), ApiVersionAdmissionTest (3),
  EnclaveDoctorEnvTest (2), Smalt.McpTest (5), R129SessionGateTest (2),
  plus `:lock_drift` — ggen_igniter.pack.lock pins 43c15edb... but live pack
  computes a454f2f0... (config_replay_identity_test).
- **smalt-cli-pytest (exit 2)**: collected 118 items / 8 errors —
  `ModuleNotFoundError: No module named 'hypothesis'/'azure'` (venv not built;
  matches doctor-dod FAIL).
- **invariant-gates (exit 1)**: cosmos-etag-cas, blob-worm, ledger-chain,
  queue-capacity — each `substrate exited rc=1 before binding :<ephemeral port>`.
- **receipt-index-check (exit 1)**: "receipt-index: DRIFT — committed index does
  not match regeneration (restored committed bytes)".

## Classification

Environmental / pre-existing, not session-introduced: this session made no edits
and killed nothing. The colima ssh tunnel owns the SDK ports; the machine was
carrying several concurrent `mix test` beams, which explains the port-binding
races in invariant-gates, the Store double-start in test-budget, and likely a
share of the 15/28 test failures. The `.venv` / GAP-token / pack-lock-drift /
receipt-index-drift findings are repo-state defects independent of load.

## Replay

```
lsof -nP -iTCP:9443 -iTCP:8443 -iTCP:5672 -sTCP:LISTEN
ps -p 61023 -o pid,command
just verify-all    # exit 1 this run
```
