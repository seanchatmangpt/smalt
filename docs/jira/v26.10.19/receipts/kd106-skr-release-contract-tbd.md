# kd106-skr-release-contract-tbd.md — KD-106 witness (lane, 2026-10-19)

- **KD row**: KD-106 (SKR release contract)
- **Standing**: PASS-EVIDENCED (wire behavior witnessed this session; register row flip is registrar's call)
- **Close condition**: SKR release returns the release blob per contract; falsifier: SDK release flow receives well-formed release payload
- **Falsifier status**: CONFIRMED OPEN — release evaluates attestation but refuses before any release blob (transcripts below)

## Evidence

Same substrate session as kd102 (block b6, auth=enforce, egress 39063).
`$T` = Bearer token.

```
=== create non-exportable key (default) ===
$ curl -s -w '\nHTTP %{http_code}\n' -X POST "$E/keys/wf-kd106/create?api-version=7.4" \
    -H "Authorization: Bearer $T" -H 'Content-Type: application/json' \
    -d '{"kty":"RSA","key_size":2048}'
{"attributes":{"created":1792430822,"enabled":true,"exportable":false},"key":{"e":"AQAB","key_ops":["encrypt","decrypt","sign","verify","wrapKey","unwrapKey"],"kid":"https://localhost:8443/keys/wf-kd106/6","kty":"RSA","n":"wiV3gZbUWHqrkZ2a1xz3FohvcM2jA6a-BpC9SiTlY2EZza7jqM5GoirAdmcNpqBfSVPisJT-PrvmTl7mOPs0B4LCcXDIZjsh0BYxP4Sx_Fnzu7zpdWlaaLzm6-kWn9LSi6qd_2Gz-Za_GFggUq4I0fLT2nvvP12WtD6E91ap0YR_OEwwORMbGfeSPxPu5WVs4n8GguJmJVmf_WrbctVaV71FOuDwKZErOTA63RxDgyr2k3tOXGWgFmvT6482-ZJobjjVoWSBBxl5GepJnY1Cj6O1t4JTG0VAunBNJMmoARQYI826zbsHLvvG0CDP4UBUj_Dn3Jgx9KMtYnXiujAWVw"},"kid":"https://localhost:8443/keys/wf-kd106/6","release_policy":null}
HTTP 200

=== release on non-exportable key ===
$ curl -s -w '\nHTTP %{http_code}\n' -X POST "$E/keys/wf-kd106/release?api-version=7.4" \
    -H "Authorization: Bearer $T" -H 'Content-Type: application/json' \
    -H 'x-ms-version: 2021-12-02' \
    -d '{"target":{"attestation":"eyJhbGciOiJub25lIn0.e30."},"enc":"CKM_RSA_AES_KEY_WRAP"}'
{"error":{"code":"KeyNotExportable","message":"Key does not contain an exportable release policy."}}
HTTP 400

=== create exportable key with release_policy ===
$ curl -s -w '\nHTTP %{http_code}\n' -X POST "$E/keys/wf-kd106b/create?api-version=7.4" \
    -H "Authorization: Bearer $T" -H 'Content-Type: application/json' \
    -d '{"kty":"RSA","key_size":2048,"key_ops":["export"],"attributes":{"exportable":true},"release_policy":{"anyOf":[{"allOf":[{"claim":"x","equals":"y"}],"authority":"https://attest.example"}]}}'
{"attributes":{"created":1792430845,"enabled":true,"exportable":true},"key":{"e":"AQAB","key_ops":["export","encrypt","decrypt","sign","verify","wrapKey","unwrapKey"],"kid":"https://localhost:8443/keys/wf-kd106b/70","kty":"RSA","n":"tHvhQcyAx7ze1AIrPv0RxpEQ4bBgkmTJsLuWY0CcPclOZvBFYa-dMloewCYo8dD4tOkihhWzw_CyW3GvvAndIPs0FQ1YsJMML5HfMmLH8axn4LmpcHC45u2BuGgNTgRV-j0RuDGm0Z88qEyR-ZNjcdBeRIuGwigunCEJ_FOeiEUowUI9x2ojlY96_BW-tRHcKa-1ia8CJbKIcQcHAvZa2G2bFPyP-jVotaXm9lnpZZ9LF7jzZzl__PMoAjcB3v40P1YTevSje4hhoh6M4q8LbXzLbFqG2GlT7dZDwAKSZsqZ8m4haOhT7KBzLK4jQtYBVs1S2ivD1JUg3FZXC-gNuw"},"kid":"https://localhost:8443/keys/wf-kd106b/70","release_policy":{"anyOf":[{"allOf":[{"claim":"x","equals":"y"}],"authority":"https://attest.example"}]}}
HTTP 200

=== release on exportable key with minimal attestation ===
$ curl -s -w '\nHTTP %{http_code}\n' -X POST "$E/keys/wf-kd106b/release?api-version=7.4" \
    -H "Authorization: Bearer $T" -H 'Content-Type: application/json' \
    -d '{"target":{"attestation":"eyJhbGciOiJub25lIn0.e30."},"enc":"CKM_RSA_AES_KEY_WRAP"}'
{"error":{"code":"UnauthorizedAttestation","message":"Secure Key Release refused: target environment failed azure-compliant-cvm attestation validation."}}
HTTP 403
```

## Reading

The SKR surface exists and evaluates real contract preconditions:
create accepts `release_policy` and echoes it; release on a
non-exportable key refuses `KeyNotExportable` 400; release with a
minimal attestation on an exportable key refuses
`UnauthorizedAttestation` 403 ("failed azure-compliant-cvm attestation
validation"). No release blob was produced — the 200-with-envelope
branch was not reachable with a minimal attestation this session, so
the release contract remains unwitnessed past the attestation gate.
Close condition (well-formed release payload per contract) open.

Context: solo (lane witness run, block b6, auth=enforce)
