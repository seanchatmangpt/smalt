# BK-CERTA — mint_certificate {e,n} swap blast radius + vacuity sweep (v26.10.22)

**Standing: ALIVE** — post-fix courts green (7 passed, exit 0); real
(non-self-anchored) pkix validation of a fresh mint passes; cross-CA
validation refuses, proving the check is non-vacuous. Context: solo

## 1. Blast radius

`mint_certificate/4` (`lib/smalt/data_plane/certificates.ex:713`) has exactly
one production caller: `create/3` in the same module (line 137, the
`/certificates/:name/create` data-plane surface). Consumers:

| Consumer | File | Relied on swapped encoding? | Effect of fix |
|---|---|---|---|
| Certificates data plane `create/3` | `lib/smalt/data_plane/certificates.ex` | No — stores DER base64 in ETS (`:smalt_vault_certificates`), asserts shape only | Benefits: minted DER is now chain-valid |
| x-arr client-cert plug | `lib/smalt/auth/x_arr_cert.ex` (pkix_path_validation at :319) | No — it was the *victim*; every minted cert presented against a minted CA was refused `invalid_signature` | Benefits: minted leaf now validates under minted CA |
| BK-VCOURTS cert legs | `test/internal/bkvc_consolidated_court_test.exs` | No | Green (author of the fix) |
| certificates_pending tests | `test/internal/certificates_pending_test.exs` | No | Green |
| KD-104 witness | `test/integration/certificates_kd104_witness_test.exs` | No | Green |
| MCP descriptor / router | `lib/smalt/mcp/generated/mcp_descriptor.ex`, `lib/smalt/mcp/router.ex` | No — surface listing only, no crypto | Unaffected |
| ARM gateway mount | `lib/smalt/arm_gateway/router.ex` | No — plugs/mount only | Unaffected |

**Disk fixtures**: none. `find test priv -name '*.pem' -o -name '*.cer' -o
-name '*.crt'` → 0 hits; minted certs live only in ETS (no disk cache), so no
stale swapped-key artifact exists anywhere on disk. The only PEMs in the repo
come from `scripts/gen_dev_cert.sh` (`.smalt/tls/`), which uses real OpenSSL
keygen, never `mint_certificate`.

## 2. Court re-runs (real output)

```bash
export PATH="$HOME/.asdf/shims:$PATH"
MIX_BUILD_ROOT=_build-certa mix test test/internal/certificates_pending_test.exs \
  test/integration/certificates_kd104_witness_test.exs \
  test/internal/bkvc_consolidated_court_test.exs
```

```
Running ExUnit with seed: 840480, max_cases: 32
Finished in 2.4 seconds (0.00s async, 2.4s sync)
Result: 7 passed
```

No consumer regressed; zero fixture repairs were needed (nothing embedded the
swapped order).

## 3. Vacuity sweep (openssl verify / pkix usage)

Grep `openssl verify` + `pkix_path_validation|pkix_verify` over lib/ test/
scripts/ workspace/ smalt-cli/:

| Site | Subject | Can it fail? | Verdict |
|---|---|---|---|
| `scripts/gen_dev_cert.sh:53` | leaf `$CERT` vs distinct `$CA_CERT` | Yes — wrong leaf refuses | non-vacuous |
| `scripts/tf_plan_check.sh:66` | `dev-cert.pem` vs `ca-cert.pem` (distinct) | Yes | non-vacuous |
| `scripts/tf_enclave_loop.sh:214` | same distinct pair | Yes | non-vacuous |
| `scripts/bench/c11_tf_loop.sh:210` | same distinct pair | non-vacuous | non-vacuous |
| `lib/smalt/auth/x_arr_cert.ex:319` | minted leaf vs configured CA via `pkix_path_validation` | Yes — this is the check that caught the {e,n} swap | non-vacuous |
| `lib/smalt/tls.ex` `verify_pair` | SPKI identity cert↔key | Yes (R156 repair replaced the old self-signed-only `pkix_verify` — already fixed) | non-vacuous |
| bkvc debug probe `openssl verify -CAfile cert cert` | self-anchored | **No** — reproduced live this lane: `openssl verify -CAfile /tmp/bkcerta_leaf.pem /tmp/bkcerta_leaf.pem` → `/tmp/bkcerta_leaf.pem: OK` (exit 0) | **VACUOUS** — retired; exists only as prose in the bkvc receipt |

**Typed prescription for the vacuous face**: any court that proves a minted
cert chain must validate a leaf **issued by** the anchor (distinct subject and
fresh key) via `pkix_path_validation(anchor, [leaf], [])` — never a
self-anchored `openssl verify -CAfile X X`, and never `openssl verify` on a
self-signed anchor at all (openssl skips anchor self-signature checks, so it
cannot observe `invalid_signature`). Prescription: the bkvc court's pkix leg
is the correct pattern; if a probe wants an openssl face, it must be
`openssl verify -CAfile ca.pem leaf.pem` with a genuinely distinct leaf, plus
a negative control (cross-CA must refuse).

## 4. End-to-end mint → real pkix → x-arr accept

Fresh probe (this lane, `MIX_BUILD_ROOT=_build-certa mix run --no-start`):

```
SELF  {:ok, {{{1,2,840,113549,1,1,1}, {:RSAPublicKey, 22004...02033117399..., 65537}, :NULL}, []}}
CROSS {:error, {:bad_cert, :invalid_issuer}}
```

- `SELF`: real `:public_key.pkix_path_validation(der, [der], [])` on a
  just-minted certificate — `{:ok, ...}` with the modulus as the FIRST element
  (22004…, 65537 = e second). The fix holds.
- `CROSS`: the same minted leaf against a *different* minted CA refuses
  `{:error, {:bad_cert, :invalid_issuer}}` — the validation is load-bearing,
  not vacuous.
- openssl contrast, same PEMs: `openssl verify -CAfile ca.pem leaf.pem` →
  `error 18 at 0 depth lookup: self-signed certificate` (exit 2 — correct
  refusal, since the leaf is not issued by that CA), while
  `openssl verify -CAfile leaf.pem leaf.pem` → `OK` exit 0 — the vacuous face
  demonstrated on live output.
- x-arr accept face: covered by the landed bkvc court (real minted CA, real
  `X-ARR-ClientCert` header → `{:ok, conn}`, thumbprint + CN asserted) —
  re-ran green in §2 (3 bkvc legs inside the 7 passed).

## Falsifiers

- `pkix_path_validation` returning `{:error, {:bad_cert, :invalid_signature}}`
  on a fresh mint.
- The §2 court run exiting 1.
- A consumer surfacing that depended on `{e, n}` ordering (none found; none
  can, since the swap produced certs no real validator accepts).

## See Also

- `receipts/bkvc-consolidated-courts.md` (defect + fix)
- `lib/smalt/data_plane/certificates.ex` (mint_certificate/4, JA-R3-order fix)
- `lib/smalt/auth/x_arr_cert.ex` (the non-vacuous validator)
