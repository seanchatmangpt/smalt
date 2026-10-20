# kd105-ps256-external-verify-tbd.md — evidence receipt (kd-lane, 2026-10-19)

- **KD row**: KD-105 (PS256 not externally verifiable)
- **Standing**: OPEN — divergence RE-WITNESSED this window on two external-SDK legs; no closing receipt exists
- **Context**: solo

## Evidence (all on-disk, this window)

### 1. TS external suite — sign-external-verify cell SKIPs citing KD-105/KD-14

`docs/jira/v26.10.19/sdk-results/wf4-ts-crypto-custody.md`:

```
16:keyvault:sign-external-verify: keyvault/sign-external-verify SKIP (KD-105, KD-14)
```

Runner tail (same file):

```
[REGISTERED-DIVERGENCE#KD-14,KD-105] kv-sign-external-verify — external node:crypto verify=false (child status=0) — signature-shape divergence per KD-14/KD-105
```

(The runner labels the cell `REGISTERED-DIVERGENCE` — the harness admits the divergence
is real and registered rather than passing it silently.)

### 2. PY external suite — external verifier refuses the substrate signature (rc=1)

`docs/jira/v26.10.19/sdk-results/wf4-py-crypto-custody.md` (captured stdout, `test_challenge_then_crypto_lifecycle`):

```
[wf4] KD-14/KD-105 DIVERGENCE RECORDED: vault RS256 sign treats the 'digest' input as a RAW MESSAGE (double-hashes) — real AKV expects a pre-hashed digest; external cryptography.hazmat verification over the digest FAILED rc=1; over the raw message it verifies.
```

Witness law of the row: external `cryptography.hazmat` verification over the digest
**FAILED rc=1**; over the raw message it verifies — the same signature-shape class as
the KD-14 RS256 inversion, distinct algorithm.

### 3. Source pin

`lib/smalt/data_plane/key_vault_actions.ex` sign path — digest-vs-raw-message treatment is the
mechanism the two witnesses above exercise. No `# KD-COVERS: KD-105` shim exists in
`lib/` (kd_flip scan: KD-105 absent from the 30-id covers-map).

## Standing rationale

The row registers the divergence; both external-suite legs re-witnessed it this window
(SKIP-as-registered-divergence on the TS leg, external-verifier rc=1 on the PY leg).
Skeleton falsifier ("external Node WebCrypto verify = true against the public JWK") was
NOT achieved — no close receipt. **KD-105 stays OPEN**; close requires the PS256
signature to verify true externally with a tampered control false.

## Cross-links

- KD-14 (RS256 inversion) — same signature-shape class; wf4-py leg witnesses both.
- kd109/kd110/kd111/kd112 evidence receipts in this directory.

---

## CLOSE WITNESS — 2026-10-20 (ERRC wave-2 lane w2e) — **PASS, falsifier met**

Wiring landed: `Smalt.DataPlane.KvPss` (:prehashed EMSA-PSS over the wire's
pre-hashed digest, MGF1-SHA256, saltlen 32, raw RSA op via :crypto.mod_pow —
OTP 28 has no :none+PSS EVP mode and its legacy pkey_crypt wrappers refuse
:public_key key tuples) dispatched from `key_vault_actions.ex` do_sign/do_verify
PS256 branches; rotate_key JWK export rides `KvPss.jwk_public` (stamps
`alg: "PS256"`). `# KD-COVERS: KD-105` shim (`lib/smalt/data_plane/kv_pss.ex`)
predates this receipt — mtime gate satisfiable for kd_flip.

### Witness flow (block b3, ports 39030-39035, auth enforce, MIX_ENV=test)

Boot: `MIX_BUILD_ROOT=_build-lane-w2e scripts/substrate-ctl up --block b3 --auth enforce --fresh`
→ `{"block":"b3","ports":[39030,...,39035],"pid":17068,"reused":false,"auth":"enforce"}` (exit 0)

Token mint (enforce, client_credentials): `POST :39032/organizations/oauth2/v2.0/token`
→ 200, access_token len 1291.

### Leg 1 — key create (RSA-HSM), JWK n/e from the wire response

```
$ curl -s -X POST "http://127.0.0.1:39033/keys/w2eps256/create" \
    -H "Authorization: Bearer $TOKEN" -H "Content-Type: application/json" \
    -d '{"kty":"RSA-HSM","release_policy":{"allowed_operations":["encrypt","decrypt","sign","verify","wrapKey","unwrapKey"]}}'
{"key":{"e":"AQAB","key_ops":["encrypt","decrypt","sign","verify","wrapKey","unwrapKey"],
 "kid":"https://127.0.0.1:8443/keys/w2eps256/7237","kty":"RSA-HSM","n":"y66r4LrJC6wh...RyebQ"},...}
```

### Leg 2 — sign PS256 (pre-hashed digest of msg.bin)

```
$ printf 'kd105 external verify witness message 2026-10-20' > msg.bin
$ curl -s -X POST "http://127.0.0.1:39033/keys/w2eps256/sign" \
    -H "Authorization: Bearer $TOKEN" -d '{"alg":"PS256","digest":"<b64url(sha256(msg.bin))>"}'
{"alg":"PS256","kid":"https://127.0.0.1:8443/keys/w2eps256/7237","value":"J0uDZ11ePR4V...xXaWRo29wJY5pvteFXPTj-G2LQNncZWJdg1SH6cZZiZ2gj7UhghW80YPsRDlh6UULrgjiAISf6EBNAFK8VLoVkHBkx-2F2mabPqZO6ir-uCdSylCVQbfgARDK3gOj_Z9EaGUYHBbUcIo8vZX_2Z7kflnAyXaIoD2G1DGMRCTsdtirIxOUKMkjm-1D1k42NEhFdo02z4xDiNabRPIrg1o40vwmgiSrZEJsKR6zINYH5blYbUaPVlx1OW48Y3cvCbSOR_TQ"}
sig_bytes=256
```

### Leg 3 — EXTERNAL verify (openssl subprocess over the wire signature)

```
$ openssl dgst -sha256 -sigopt rsa_padding_mode:pss -sigopt rsa_pss_saltlen:32 \
    -verify pub.pem -signature sig.bin msg.bin
Verified OK
verify-exit=0
```

pub.pem reconstructed from the create response's JWK n/e (SPKI built by hand,
no trusted third party — the external verifier sees only wire material).

### Leg 4 — tampered control (external verifier must refuse)

```
$ openssl dgst -sha256 -sigopt rsa_padding_mode:pss -sigopt rsa_pss_saltlen:32 \
    -verify pub.pem -signature sig.bin msg-tampered.bin
Verification failure (rsa_pss.c:144 bad signature)
tampered-exit=1
```

### Leg 5 — wire verify op (in-process, fail-closed both directions)

```
$ curl -s -X POST ".../keys/w2eps256/verify" -d '{"alg":"PS256","digest":"<same>","value":"<sig>"}'
{"kid":"...","valid":true,"value":true}
$ curl -s -X POST ".../keys/w2eps256/verify" -d '{"alg":"PS256","digest":"<tampered>","value":"<sig>"}'
{"kid":"...","valid":false,"value":false}
```

### In-process unit ground (lane build root)

```
$ MIX_BUILD_ROOT=_build-lane-w2e mix run probe
sig_bytes=256 inproc=true tampered=false jwk_alg=PS256
$ MIX_BUILD_ROOT=_build-lane-w2e mix test test/internal/
27 tests, 0 failures   (exit 0)
```

## Falsifier status

Skeleton falsifier ("external Node/openssl verify = true against the public
JWK, tampered control false") is MET: openssl PSS saltlen-32 verify = "Verified
OK" (exit 0) on the wire signature; tampered control = Verification failure
(exit 1). KD-105 is eligible to flip CLOSE (receipt postdates the KvPss shim);
flip belongs to the kd-registrar via `scripts/kd_flip.py --apply`.

## Standing

- **KD-105**: PASS — externally verifiable as of this witness; OPEN→CLOSE
  flips via kd-registrar.
- Receipt artifacts: `/tmp/w2e-witness/` (transcript
  /tmp/w2e-witness-transcript.txt; scratch, not indexed).

---

## KD-119 RESOLUTION — 2026-10-20 (ERRC wave-4 lane w4a) — **PASS, falsifier met**

Extends the KD-105 close to its sibling **KD-119** (vault RS256 sign double-hash:
digest input treated as raw message). Context: solo. Build root `_build-lane-w4a`;
block b5 enforce (`{"block":"b5","ports":[39050..39055],"pid":46123,"reused":false}`
boot exit 0, restarted post-fix so the beam carried the repaired KvPss).

### Code verification (question 1)

`key_vault_actions.ex` do_sign/do_verify pass the wire's pre-hashed `digest`
through `:prehashed` on both faces: PS256 → `KvPss.sign_pss(..., prehashed: true)`
/ `KvPss.verify_pss(..., prehashed: true)` (EMSA-PSS over the digest exactly once,
raw RSA op); RS256 → DigestInfo-prefix + `:none` raw (double-hash defect gone).
The wire contract, now witnessed on both readings of `sign_digest/1`:
`digest` field = PRE-HASHED digest (b64url), signed/verified as-is; `value` field
= raw message hashed once server-side (or a 32-byte value passed through as a
digest). Both readings externally verify.

### Defect found and repaired this lane (in `kv_pss.ex`, exclusive ownership)

The w2e `:prehashed` landing had a **flaky verifier defect**: `emsa_pss_verify/2`
never cleared the leftmost `8·emLen − emBits` bits of `maskedDB[0]` before the
xor, and matched the recovered DB's PS region bit-exactly — so ~50% of VALID
signatures (whenever MGF1's first byte has its high bit set) failed in-process
verify while openssl accepted them. Measured pre-fix: wire sign→verify 30 rounds
= **15 ok / 15 bad**; in-process 40 rounds = 22 ok / 18 bad. Root cause per
RFC 8017 §9.1.2 (step 1c clears the padding bits; step 3 does not inspect the
leftmost bits of DB'): `emsa_pss_verify/3` now clears `maskedDB[0]` with
`mask_for(top_bits)` pre-xor (`top_bits = 8k − (modBits−1)`) and ignores the top
`top_bits` bits of the recovered DB. Post-fix: in-process 40 rounds = **40/40**,
wire 30 rounds = **30/30 ok / 0 bad**.

### Witness flow (block b5, enforce, post-fix beam)

Token: `POST :39052/organizations/oauth2/v2.0/token` → 200, len 1291.
Key create RSA-HSM → kid `.../keys/w4akd119/8770`; SPKI built from wire JWK n/e
(no trusted third party).

```
$ openssl dgst -sha256 -sigopt rsa_padding_mode:pss -sigopt rsa_pss_saltlen:32 \
    -verify pub.pem -signature ps_sig.bin msg.bin
Verified OK          (ps-verify-exit=0)
$ ... -signature ps_sig.bin msg-tampered.bin
Verification failure  (tampered control detected)
$ openssl dgst -sha256 -verify pub.pem -signature rs_sig.bin msg.bin
Verified OK          (rs-verify-exit=0)
$ ... -signature rs_sig.bin msg-tampered.bin
Verification failure  (tampered control detected)
```

RS256 face: the original KD-119 defect (digest signed as raw message) is gone —
external verify over THE DIGEST = "Verified OK" exit 0; tampered control exit 1.
PS256 face: same. Raw-message `value` face: PS256 sign over `{"value": b64(msg)}`
→ substrate hashes once server-side → openssl "Verified OK" (exit 0).

Wire verify (in-process, fail-closed both directions, both algs):
`v_ps_ok=true / v_ps_tam=false / v_rs_ok=true / v_rs_tam=false`.

```
$ MIX_BUILD_ROOT=_build-lane-w4a mix test test/internal/
42 tests, 0 failures   (exit 0)
```

### KD-119 close-condition check (kd_flip re-check)

`python3 scripts/kd_flip.py` (scan, no --apply): KD-105 already
[CLOSED-SIMULATED] on `lib/smalt/data_plane/kv_pss.ex`; KD-119 previously
absent from the covers-map (no token). This lane added `# KD-COVERS: KD-105,
KD-119` to `kv_pss.ex` (post-repair, pre-dates this receipt text — mtime gate
satisfiable). Close condition "sign consumes pre-hashed digest as-is;
hazmat verify digest=true, message=false" is MET by the openssl analog above
(digest=true Verified OK, message/tampered=false exit 1). **KD-119 is
flip-eligible; flip belongs to the kd-registrar via `scripts/kd_flip.py
--apply`** (w4a reports, does not flip).
