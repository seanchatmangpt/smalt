# External workflow receipt: wf4-crypto-custody (ts)

Workflow: wf4-crypto-custody
Lang: ts
Window: v26.10.19
SUBJECT_SHA: b847c020ee6b0a7ef426e27379f960228932feb0
Profile: primary-tier external suite (official Azure SDKs; surfaces: keyvault, skr)
Generated: 2026-10-19T18:45:48.308450+00:00

## Cell tags

keyvault:challenge-witness-kd-15: keyvault/challenge-witness-kd-15 PASS (KD-15)
keyvault:create-rsa2048: keyvault/create-rsa2048 PASS
keyvault:two-versions: keyvault/two-versions PASS
keyvault:wrap-unwrap: keyvault/wrap-unwrap PASS
keyvault:sign-external-verify: keyvault/sign-external-verify SKIP (KD-105, KD-14)
keyvault:dead-port-plane-check: keyvault/dead-port-plane-check PASS
skr:dead-port-plane-check: skr/dead-port-plane-check PASS
keyvault:soft-delete: keyvault/soft-delete PASS
keyvault:get-deleted: keyvault/get-deleted FAIL
keyvault:recover: keyvault/recover FAIL
keyvault:purge: keyvault/purge PASS

## Runner output tail

```
e","verdict":"GREEN","detail":"DELETE /deletedkeys (purge) -> 404; post-purge /keys/wf4-0dd36d3e -> 404"}]}
{"id":"wf5","checks":[{"name":"arm-429-burst","verdict":"GREEN","detail":"180/200 requests 429'd, retry-after=1"},{"name":"arm-429-typed-code","verdict":"GREEN","detail":"error.code=TooManyRequests status429x180"},{"name":"arm-429-sdk-observability","verdict":"GREEN","detail":"SDK maxRetries:0 single GET: threw429=false resolved=false (window-dependent; burst leg is the throttle witness)"},{"name":"dead-port-plane-check","verdict":"GREEN","detail":"dead port typed failure (TypeError)"}]}

== VERDICT TABLE ==
-- wf4: child exit=0
   [GREEN] kv-challenge-witness-KD-15 — tokenless -> 401, WWW-Authenticate=Bearer authorization="https://localhost:39832/organizations", resource="https://localhost:39834", error="invalid_token",
   [GREEN] kv-create-rsa2048 — kid=https://localhost:8443/keys/wf4-0dd36d3e/132
   [GREEN] kv-two-versions — versions=2
   [GREEN] kv-wrap-unwrap — wrap/unwrap roundtrip equal=true
   [REGISTERED-DIVERGENCE#KD-14,KD-105] kv-sign-external-verify — external node:crypto verify=false (child status=0) — signature-shape divergence per KD-14/KD-105
   [GREEN] dead-port-plane-check — dead TLS twin typed failure (RestError)
   [GREEN] kv-soft-delete — DELETE /keys -> 200 (deletedDate present)
   [FAIL] kv-get-deleted — GET /deletedkeys -> 404 (recoverable-plane MISSING — recover/purge unexercisable)
   [FAIL] kv-recover — POST /deletedkeys/recover -> 404
   [GREEN] kv-purge — DELETE /deletedkeys (purge) -> 404; post-purge /keys/wf4-0dd36d3e -> 404
-- wf5: child exit=0
   [GREEN] arm-429-burst — 180/200 requests 429'd, retry-after=1
   [GREEN] arm-429-typed-code — error.code=TooManyRequests status429x180
   [GREEN] arm-429-sdk-observability — SDK maxRetries:0 single GET: threw429=false resolved=false (window-dependent; burst leg is the throttle witness)
   [GREEN] dead-port-plane-check — dead port typed failure (TypeError)
[run-all] done in 7.1s exit=1
```
