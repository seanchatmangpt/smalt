# Receipt: B-11 chaos kill + TLS churn re-run

- Date: 2026-10-15 18:49-18:54 PDT
- Lane: B-11 (chaos + TLS churn under load), v26.10.14 release DoD wave
- Repo: `/Users/sac/smalt`, branch main, darwin/arm64, OTP 28.3.1 / Elixir 1.19.5
- Scripts: `scripts/stress/chaos_kill.py`, `scripts/stress/tls_churn.py` (unchanged contracts)
- Receipts: `tmp/chaos-kill-receipt.json` (per-request records) → mirrored rows
  in `docs/jira/v26.10.14/bench/b11-chaos.jsonl`. TLS run is stdout-receipted; per-scenario
  numbers transcribed above/below.
- No commits made. `scripts/stress/chaos_kill.py` received three minimal harness
  contract fixes (disclosed below); no `lib/` edits, no doc edits beyond dated rows.

## Chaos kill-under-load — verdict: BETTER_OR_EQUAL vs prior (2026-10-14)

rc=0, full profile (20 rps ARM+Cosmos, t30 flood / t60 gate / t90 SIGKILL).

| metric | prior (2026-10-14) | this run | delta |
|---|---|---|---|
| baseline p95 | 1.3-1.7 ms | 1.2 ms | equal |
| flood p95 | 1.5-1.8 ms | 1.0 ms | better |
| gate p95 | 1.6-1.9 ms | 1.2 ms | better |
| in-flight failures at kill | 90-142 | 49 | better |
| reboot (ports bound) | 15.0-18.0 s | 4.775 s | better |
| TTFS from kill | 4.95-7.56 s | 2.981 s | better |
| post-recovery | 240/240, 300/300, p95 1.6-1.9 ms | 505/505, p95 1.2 ms | equal-or-better |

Reboot time improved because prior runs paid first-attempt boot instability
(rc=1 retry); this run booted first-attempt clean.

### Harness fixes (disclosed, scripts only — the harness had drifted out of
### contract with the tightened router)

1. **Token endpoint**: `validate_token_request/1`
   (`lib/smalt/arm_gateway/router.ex:181-218`, RFC 6749 §5.2) now requires
   non-blank `client_id`/`client_secret`; the harness sent `grant_type` only →
   400 `invalid_client`, all 3 boot attempts failed. Harness now sends
   `client_id=chaos-harness&client_secret=chaos-harness` (values unchecked by
   the endpoint).
2. **SUB_ID**: used by `arm_put_rg`/`arm_get_rg` but never defined (NameError
   on the auth canary). Now `SMALT_CHAOS_SUB_ID` env-overridable, default
   `chaos-sub`.
3. **api-version gate**: RG verbs now validate api-version (row 6b); latest
   admitted 2021-04-01; harness sent `2021-01-01` → 400 on 100% of ARM
   good traffic (first completed run measured 50% fail with 586 ARM 400s).
   Harness updated to 2021-04-01.

With the fixes, the same script produces the clean table above — one full run,
no retries needed after fix 3. A second full rc=0 run (18:58, receipt
overwritten in place) replicated it: TTFS 2.769s, reboot 4.526s, 45 in-flight
failures, post-recovery 509/509 p95 1.575ms (row 3 of the jsonl).

## TLS churn — verdict: REPRODUCED_WITHIN_NOISE vs prior (2026-10-14 21:47 PT)

Substrate: MIX_ENV=test, private ports http 29443 / TLS 29444 (doc usage
block), `scripts/dev_env.sh` env, server pid 88174. Gate: TLSv1.2
`ECDHE-RSA-AES256-GCM-SHA384`, GET /tenant → 200 (44.5 ms first handshake).
Server alive after all scenarios, RSS 241 MB (prior 155 MB).

| # | scenario | prior | this run |
|---|---|---|---|
| gate | verified handshake + GET | TLSv1.2 AES256-GCM 200 | same |
| 2 | TLS1.2 pinned cipher 10s | 503.6 hs/s, p50 1.96, n=5037, 0 fail | **496.4 hs/s**, p50 1.95, n=4965, 0 fail (−1.4%) |
| 1 | sustained 30s churn | 466.9 hs/s, p50 2.06, p99 2.89, n=14008, 0 fail | **462.9 hs/s**, p50 2.07, p99 3.34, n=13889, 0 fail (−0.9%) |
| 3 | 20x50 concurrent bursts | 1000/1000, wall p50 15.4 / max 18.6 ms | 1000/1000, wall p50 18.1 / max 28.4 ms |
| 4 | 100 bad ClientHello | survived; good HS 2.1 ms | same (2.1 ms) |
| 5 | plain-http 10s | 1736.7 req/s, p50 0.14, n=17367 | **1808.5 req/s**, p50 0.15, n=18085 (+4%) |

Failure accounting unchanged: scenario 5 failures are client-side
`EADDRNOTAVAIL` (errno 49) ephemeral-port exhaustion (21,027), a single-host
harness ceiling, not server refusals; TLS vs plain ratio holds at ~3.7x.
Sandbox SIGKILL note from the prior receipt did not reproduce — server ran
outside-sandbox-equivalent to completion twice-equivalent runs.

## LRO sweeper kill target

NOT SUPPORTED by the script: `Smalt.ArmGateway.LroSweeper` is an in-beam
GenServer child of `Smalt.Supervisor`
(`lib/smalt/arm_gateway/lro_sweeper.ex:10,41`), not a separate OS process, and
`chaos_kill.py` has no per-target kill parameter — it SIGKILLs the substrate
process group, which covers the sweeper implicitly. A per-child kill class
would need a new harness target parameter.

## Verdicts

- **chaos_kill: BETTER_OR_EQUAL.** All chaos phases landed; SIGKILL remains the
  only chaos that lands; recovery is faster than prior (TTFS 2.98s vs 4.95-7.56s).
- **tls_churn: REPRODUCED_WITHIN_NOISE.** Handshake rates within 1.4% of prior;
  zero server-side failures; fail-closed gates never fired.

## See Also

`docs/STRESS/CHAOS_KILL.md` · `docs/STRESS/TLS_CHURN.md` ·
`docs/jira/v26.10.14/bench/b11-chaos.jsonl`
