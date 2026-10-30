# P06 — ACA ingress & proxy-trust parity under real redirects

- window: v26.10.30 · id: CLM-05 · receipt: r-p06-ingress-parity.md

## Claim

Canonical-origin 308 law, `X-Forwarded-*` trust behavior (the ACA
100.64.0.0/10 contract the consumer's `TRUST_PROXY` encodes), and zero
redirect loops, all exercised by a browser following real redirects across
custom hostnames.

## Falsifier

A redirect loop, a dropped `X-Forwarded-Proto` (secure cookie silently
lost), or an unauthorized host answering 200 instead of 308.
