# SCVD-T5: Connection-Pool Exhaustion Chaos — Receipt

**Standing:** **PASS** (recovery verified; flood refusal behavior typed)

- Date: 2026-10-21
- Lane script: `/Users/sac/smalt/tmp/bench/scvd_tier5_chaos.mjs`
- Result jsonl: `/Users/sac/smalt/tmp/bench/scvd-chaos-conn.jsonl` (2 lines: 1 harness-env FAIL + 1 PASS, see below)
- Subject: live smalt substrate, data plane TLS twin `https://127.0.0.1:9444` (beam.smp pid 56472); ARM 9443 used only for STS token mint (KD-15 handshake per T1 path). Shared ARM plane was NOT hammered.
- Machine: Darwin 25.2.0 arm64, Apple M3 Max, 16 cores, 48 GiB.
  (Note: `just bench-machine` is currently broken by a pre-existing justfile
  parse collision — `root :=` defined in multiple imported modules, first
  conflict at `justfile.d/31-have.just:9`. Machine identity probed directly
  via `uname`/`sysctl`.)

## Method

1. Preflight TLS probe on 9444 (loud SKIP contract; substrate confirmed live — never restarted).
2. Flood: 2000 rapid short-lived TLS connections, each opened and `destroy()`-ed abruptly (no graceful close), concurrency 128.
3. Recovery: repeat the T1 single PUT/GET path (Azure Cosmos JS SDK over 9444, STS bearer, `NODE_EXTRA_CA_CERTS=.smalt/tls/ca-cert.pem`), bounded poll (30s deadline, 5s per-op hang budget — the >5s-hang falsifier).

## Results (run 2, PASS)

- Flood: 2000/2000 TLS handshakes **accepted** in 1642 ms (~1218 conns/s); 0 refused, 0 resets, 0 timeouts. `refusal_class: accepted-all` — the substrate absorbed the full abrupt-close flood with no visible connection-limit backpressure at 2000 conns.
- Recovery: **first attempt, no retries**. db/container create 140 ms, PUT+GET round-trip 454 ms (read-back id match verified). Total recovery 594 ms — well under the 5s hang budget. No hangs, no untyped errors.
- Refusal behavior observed: none was required; where connections did close, all closes were client-initiated destroys (typed transport), never a server-side hang.

## Run 1 FAIL disclosure (harness env, not substrate)

Run 1 exited FAIL with `recovery_error: "unable to verify the first certificate"` — the recovery leg was launched without `NODE_EXTRA_CA_CERTS`, so the SDK could not trust the dev CA. This is a harness environment defect (run 1 did not source the T1 env), not a substrate fault; the flood leg of run 1 was identical (2000/2000 accepted). Run 2 corrected the env and passed. Both rows are retained in the jsonl for honesty.

## Verdict

The substrate serves normal cosmos data-plane ops immediately after a 2000-connection abrupt-close flood; no typed refusals were exercised because the pool never saturated at n=2000. No hangs >5s at any point. **PASS** with the observation that the exhaustion threshold lies above 2000 rapid connections; a higher-n ramp would be needed to force typed refusal/reset behavior.

## Artifacts

- Flood+recovery harness: `/Users/sac/smalt/tmp/bench/scvd_tier5_chaos.mjs`
- Result jsonl: `/Users/sac/smalt/tmp/bench/scvd-chaos-conn.jsonl`
- T1 reference path: `/Users/sac/smalt/tmp/bench/scvd_tier1.mjs`
