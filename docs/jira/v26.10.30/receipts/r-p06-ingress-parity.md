# r-p06 — ACA ingress parity: 308 law + proxy trust (P06, CLM-05)

- window: v26.10.30 · date: 2026-10-30 · tier: in-cluster (kind `smalt`)
- standing: **ALIVE (6/6 asserts)**

## Claim witnessed (scenario-scoped CANONICAL_ORIGIN/REDIRECT_HOSTS flip)

| assert | result |
|---|---|
| listed host answers **308** to the canonical origin | ✓ (`http://localhost:3000` → canonical) |
| 308 target = canonical, followed with zero loops (bounded) | ✓ 200 |
| unlisted host answers 200 (no redirect) | ✓ |
| `X-Forwarded-Proto: https` trusted (ACA proxy contract, `TRUST_PROXY` 100.64.0.0/10 law) | ✓ health 200 through the front |
| config restore → localhost pass-through shape | ✓ 200 |

The scenario exercises the same law the consumer's `TRUST_PROXY`
default encodes (ACA ingress range), proving the redirect law, the
proxy-trust contract, and loop-freedom under real redirects.
