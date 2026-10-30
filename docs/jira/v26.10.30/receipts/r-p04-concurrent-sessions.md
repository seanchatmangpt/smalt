# r-p04 — Concurrent browser sessions on one substrate (P04, CLM-04)

- window: v26.10.30 · date: 2026-10-30 · tier: in-cluster (kind `smalt`)
- standing: **ALIVE**

## Claim witnessed

Ten concurrent headless-chromium contexts inside the `r30-driver` pod,
each performing the complete SAML sign-in and five authenticated
mutations (`GET /api/auth/me`), all against one substrate:

```json
{"verdict":"P04-PASS","passed":10,"of":10,"failures":[]}
```

Zero connection drops, zero protocol desync (the RESP3 wire law held:
HELLO 3 map + pipeline drain under 10 parallel clients), zero session
loss. The redis wire + express-session + substrate Cachex served every
context through the same faces.
