# P09 — Identity topology & trust wiring inside the cluster

- window: v26.10.30 · receipt: folded into r-p08-harness.md
- sequence: FIRST (P07 -> P01 -> {P02..P06} -> P08 depend on its surfaces).

## Claim

The cluster presents the identity surfaces and app origins under stable
in-cluster names with a trust chain the production parsers accept (SAML/OIDC
signature checks pass against the substrate's own CA material — certificate
distribution is an implementation detail for ggen). Success is
name-resolution stability across multi-redirect flows and zero TLS-trust
shortcuts in the production validators.

## Falsifier

Any `ignoreHTTPSErrors`-style bypass surviving into the final gate, or DNS
flake between redirects.
