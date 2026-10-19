# AZB-23 Court Rehearsal (cold-start face, current non-quiet tree)

- Date: 2026-10-18
- Context: solo (rehearsal only; machine busy with concurrent lanes)
- Machine: Apple M3 Max, 16 cores, 48 GB, Elixir 1.19.5 / OTP 28, Darwin 26.2
  (`just bench-machine` → `{"cpu":"Apple M3 Max","cores":16,"ram_gb":48,"elixir":"1.19.5","otp":"28","darwin":"26.2"}`)
- Standing: PASS (rehearsal) / quiet-check REFUSED as expected — see below
- Scope: REHEARSAL, not the gate. `just invariant-gates` SKIPPED (court ports
  9443/8443/5672 held by colima per dispatch; no ports evicted, no kills).

## 1) `just doctor` — PASS

```
[PASS] binaries (0.2ms): ok
[PASS] port-arm (0.1ms): ok
[PASS] port-data (0.0ms): ok
[PASS] port-amqp (0.0ms): ok
[PASS] gitignore-coverage (0.1ms): ok
[PASS] dev-key-perms (0.1ms): ok
[PASS] dev-certs (0.1ms): present (.smalt/tls/dev-cert.pem)
[ADVISORY] keychain-trust (19.6ms): dev CA not trusted by macOS System keychain
[PASS] tmp-dirs (0.1ms): ok
[PASS] mix-deps-freshness (909.3ms): INFO 89 locked deps
[PASS] recent-receipts (2.3ms): INFO 1/2 receipt(s) stale >24h: bench-receipt.json (25.4h old)
[PASS] spc-bands (56.7ms): PASS verdict=PASS tier=0 seeded=False
[SUBSTRATE] booted=False ports={'5672': 'listening', '5673': 'free', '8443': 'listening', '9443': 'listening', '9444': 'free'} receipts={'newest_receipt_age_hours': 1.06, 'stale': False, 'count': 2}
[PASS] Smalt doctor diagnostic court passed.
```

## 2) `MIX_BUILD_ROOT=_build-ft-reh mix test test/stress_tier_census_test.exs` — PASS

Cold build root `_build-ft-reh` (fresh compile, ~7 min wall under load ~88);
cold-start face surfaced and absorbed:

```
Running ExUnit with seed: 379738, max_cases: 32
Excluding tags: [:amqp_wire, :stress]
.
Finished in 23.5 seconds (23.5s async, 0.00s sync)
1 test, 0 failures
[exited with code 0]
```

Tier population fence green: `:stress` census test passed, tier exclusions
`[:amqp_wire, :stress]` applied as expected.

## 3) `python3 scripts/gen_error_codes.py --check` — PASS (exit 0)

```
docs/ERROR_CODES.md up to date
```

## 4) `just quiet-check` — REFUSED (exit 1), correct fail-closed behavior

Recipe (`justfile.d/24-quiesce.just:7`, backed by `scripts/quiet_check.py`)
measures, each veto-capable: (1) stray beam.smp processes with cwd outside
this checkout; (2) court ports 9443/8443/5672/5673/9444/9445 free;
(3) no concurrent mix test/court/substrate processes (own ancestry excluded);
(4) load gating: load1 > ncpu or load5 > 0.75*ncpu refuses.

Verdict on the current busy machine:

```
QUIET-CHECK REFUSE (typed violations):
  - court port 9443 occupied
  - court port 8443 occupied
  - court port 5672 occupied
  - concurrent suite/court processes: 147 /Users/sac/.erlmcp/otp-28.3.1/lib/erlang/erts-16.2/bin/beam.smp ...
  - load 88.9/77.7 > threshold (16 cpus)
QUIET-CHECK EXIT: 1
```

Expected: the tree is non-quiet (colima holds court ports, concurrent lanes
running). The gate refusing here is the fail-closed behavior working — the
rehearsal's purpose was to surface this face now rather than at the real gate.

## Summary

| Stage | Verdict |
|---|---|
| just doctor | PASS (1 advisory: keychain-trust, pre-existing) |
| stress tier census fence (cold _build-ft-reh) | 1 test, 0 failures, exit 0 |
| gen_error_codes --check | PASS, exit 0 |
| quiet-check | REFUSED (exit 1) — correct fail-closed on busy machine |

Cold-start findings: none beyond the known cold-compile wall-clock (~7 min for
a fresh private build root under load 88.9; test body itself 23.5s). No
failures, no edits, no kills, no git operations.
