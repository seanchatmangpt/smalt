# v26.10.30 — Courtroom consumer, end to end

Window goal: prove [courtroom-platform-az](~/cai/courtroom-platform-az)
runs "perfectly" on the smalt substrate in kind — every identity,
session, fence, and ingress law witnessed by real browsers and real
client libraries, zero cloud.

## Verdict

**ALIVE.** See `receipts/r-p08-harness.md` (the P08 milestone gate): the
full P01–P09 ladder witnessed, plus the kind court's 9/9 flow
(`COURT-VERDICT: ALIVE` ×3) on baked manifests.

## Receipts

- r-p01 — browser-witnessed SAML sign-in (full claim shape)
- r-p02 — SLO round trip + store eviction witness
- r-p03 — browser + openid-client OIDC (RS256 id_token via live JWKS)
- r-p04 — 10 concurrent browser contexts, zero desync
- r-p05 — tenant fence through the browser path (typed, data-free)
- r-p06 — ingress 308 + proxy-trust parity
- r-p08 — the milestone gate ladder (ALIVE)
- scaffolds/ — the ggen-rendered P-ticket boundary scaffolds
- tickets/ — P01–P09 claim-first tickets
