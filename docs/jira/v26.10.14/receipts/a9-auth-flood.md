# A-9 Receipt — Adversarial Cross-Tenant Auth Challenge Flood (v26.10.14)

**Lane**: A-9 (adversarial cross-product bench)
**Date**: 2026-10-16
**Status**: PASS — 1,389,656 requests executed, 0 transport errors, substrate down after
**Subject**: `scripts/bench/a9_auth_flood.mjs` against an enforce-mode substrate
(private port block 39490–39495, `auth_mode: :enforce`, `MIX_ENV=dev`)
**Result file**: `docs/jira/v26.10.14/bench/a9-auth-flood.jsonl`
(+ RSS series companion `a9-auth-flood-rss.jsonl`)

## Substrate identity

- Booted exactly as `scripts/substrate.sh` boots it but pinned `:enforce`
  and private ports (A-9 is not in the b1..b12 port-law range; 39490–39495
  chosen collision-checked free). No lib/ edits, no commits.
- Pre-flight witness: tokenless `GET /subscriptions?api-version=2021-04-01`
  → `401` with the KD-15/S-3 enriched challenge on the wire:

  ```
  www-authenticate: Bearer authorization="http://127.0.0.1:39490/organizations", resource="http://127.0.0.1:39490", error="invalid_token", error_description="MissingBearerToken"
  ```

## Challenge-rate table (Apple M3 Max, 16 cores, 48 GB, Elixir 1.19.5 / OTP 28)

| phase | requests | result | throughput | p50 | p95* | p99 | errors |
|---|---|---|---|---|---|---|---|
| 1. challenge flood (tokenless, amount=20k) | 20,000 | 100% 401 | **19,802 challenges/s** | 1 ms | 6 ms | 8 ms | 0 |
| 2a. token-attach 50/50 — 401 leg | 10,000 | 100% 401 | 10,000/s | 1 ms | — | 8 ms | 0 |
| 2b. token-attach 50/50 — 200 leg | 10,000 | 100% 200 | 10,000/s | 1 ms | — | 8 ms | 0 |
| 2. mixed combined | 20,000 | 50/50 | **20,000 mixed/s** | — | — | — | 0 |
| 3. all-valid baseline (10 virtual tenants) | 10,000 | 100% 200 | **9,901 reads/s** | 1 ms | 4 ms | 4 ms | 0 |
| 4. sustained flood (tokenless, duration=20 s) | 1,339,656 | 100% 401 | **66,949 challenges/s** | 1 ms | 3 ms | 7 ms | 0 |

\* autocannon exposes p97_5, not p95; the p95 column carries p97_5 and every
JSONL row sets `p97_is_p95: true` so the substitution is explicit.

Tokens: 10 HS256 JWTs minted live from the enforce substrate's own STS
(`POST /{tid}/oauth2/v2.0/token`, `grant_type=client_credentials`), one per
virtual tenant `11111111-0000-0000-0000-{i}`, spread one-per-connection in
phases 2b/3.

**200-rate delta analysis**: mixed 200-leg ran at 10,000/s while the
all-valid baseline ran 9,901/s — the tokenless leg running concurrently did
NOT depress valid-read throughput (delta vs baseline ≈ +1%, within run
noise). The enriched challenge serialization is not a measurable tax on the
valid path; the challenge path itself sustains 66.9k/s — ~6.8x the B-2-class
all-valid read rate — because 401-refusal short-circuits before any router
body work.

## Memory verdict

**The enriched challenge is allocated per-request and collected — it is NOT
cached, and it does not accumulate.**

- `Smalt.Auth.Bearer.challenge_value/2` builds the `authorization` origin URL
  and `resource` origin by string interpolation on every refusal (source
  witness: `lib/smalt/auth/bearer.ex` — `challenge_value/2` reads
  `conn.scheme/host/port` per call; nothing is stored in `:persistent_term`
  or ETS).
- Witness RSS (substrate beam pid, 250 ms samples, `a9-auth-flood-rss.jsonl`):
  - 20 s sustained flood, 1.34 M challenges: RSS sawtooth
    first=243,344 KB, mid=248,576 KB, last=250,720 KB, max=250,896 KB —
    total envelope 7.5 MB over 1.34 M requests (~5.6 bytes/req net, i.e. GC
    lag, not retention).
  - The series oscillates (last-10 window swings 244,784–250,720 KB) —
    sawtooth, not monotone climb.
  - 10 s idle after flood: RSS returned to 244,880 KB — at/below the
    pre-flood base. A per-request-allocated-but-retained pattern would
    ratchet (≈130 B × 1.34 M ≈ 175 MB); observed is a bounded GC plateau.
- Phases 1–3 (~1 s each) were too short to witness; phase 4 exists precisely
  to give the sampler a window.

## Entra-ID billable row (directional, as-of-knowledge labels)

| model | pricing shape (as of training knowledge, verify before quoting) | measured auth/s | directional cost read |
|---|---|---|---|
| Entra ID P1 | ~$6 user/month, includes unlimited self-service auths + MFA; no per-auth charge in the standard model | 19.8k–66.9k challenges/s (local substrate) | Real Entra does NOT charge per auth at P1/P2; a flood of this class is a rate-limit/Smart-Lockout problem, not a billing problem |
| Entra ID P2 | ~$9 user/month (adds Identity Protection + PIM) | same | Same — per-user license, not per-auth metering |
| Entra External ID / B2C | per-MAU (monthly active user) pricing, first ~50k MAU free tier, then ~$0.02/MAU tiered; historical per-auth pricing was retired in favor of MAU | 66.9k/s from 10 tenant identities | 10 virtual identities doing 1.34 M auths would be 10 MAU, not 1.34 M billables — MAU dedupes by identity per month |

Directional conclusion: the measured 66.9k challenge/s flood would be a
black-hole amplification target in production only at the rate-limit layer;
under every Entra licensing model above it costs ~nothing incremental per
request because none of them meter per-authentication at this shape.

## Falsifier status

- Flood leg any non-401 → would FAIL (observed: every 401-leg request was a
  401 — 20,000/20,000, 10,000/10,000 mixed, 1,339,656/1,339,656 sustained;
  1,369,656 total challenges, zero non-401).
- Mixed leg 200-rate collapsing vs baseline → observed +1% (no collapse).
- RSS monotone climb → observed sawtooth + idle return to base (refuted
  accumulation).

## Commands (replay)

```bash
# substrate (enforce, private ports 39490-39495)
MIX_ENV=dev mix run --no-start -e 'Application.put_env(:smalt, :auth_mode, :enforce); ... ; Process.sleep(:infinity)' &
A9_ARM=http://127.0.0.1:39490 A9_RSS_PID=<beam pid> node scripts/bench/a9_auth_flood.mjs
```

Exit 0; `[VERDICT] PASS (flood=true mixed=true baseline=true sustained=true)`.
