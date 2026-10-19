# kd99-sts-hs256-tbd.md — KD-99 evidence receipt (kd-registrar witness lane, 2026-10-19)

- **KD row**: KD-99 (STS HS256-only / no JWKS)
- **Standing**: PASS — witnessed by this lane against substrate block b5
  (auth enforce), receipt mtime postdates both shim mtimes
  (sts_key.ex 2026-10-19 10:10:45, bearer.ex 09:50:57).
- **Probe**: /tmp/kd99-witness/probe.mjs (@azure/identity 4.14.0 /
  msal-node 6.0.1), raw transcript embedded verbatim in
  `receipts/v261019-13-identity-rs256.md` (exit 0, VERDICT: PASS).

## Raw output (verbatim from the PASS run)

```
$ curl -s https://127.0.0.1:39054/organizations/discovery/v2.0/keys  -> 200
JWK: {"kty":"RSA","alg":"RS256","use":"sig","kid":"wjcaIELc5UpUcPaQ_AETkAC4sHVPU0MHsFW8UM-ublw"}
RFC7638 thumbprint(kid): wjcaIELc5UpUcPaQ_AETkAC4sHVPU0MHsFW8UM-ublw byte-equal: true
crypto.verify(RS256): valid=true tampered=false
  [ok] JWKS kid byte-equal + RS256 signature verifies (tampered control fails) (KD-99)
JWT header: {"alg":"RS256","kid":"wjcaIELc5UpUcPaQ_AETkAC4sHVPU0MHsFW8UM-ublw","typ":"JWT"}
getToken: OK  expiresOnTimestamp=1792434802000
VERDICT: PASS
EXIT=0
```

(Excerpt; full ordered transcript in `receipts/v261019-13-identity-rs256.md`.)

- **Falsifier result**: signature validates (true) against the served JWK
  and FAILS on a tampered payload (false) — the control makes the check
  non-vacuous. Replay: see the commands block of the linked receipt.
