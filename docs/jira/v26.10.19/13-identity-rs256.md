# V261019-13 — Identity plane: RS256 signing key + real-AAD discovery surface

> **Status at materialization (2026-10-19):** IN FLIGHT —
> `lib/smalt/auth/sts_key.ex` on disk (untracked); router/bearer edits present.

- **Release:** v26.10.19 · **Work order:** V261019-13 · **Plane:** Identity / STS (`:9443` ARM gateway bootstrap-auth surface)
- **Scope owners:** `lib/smalt/plane/identity/sts_gate.ex` (new RS256 signing-key module `lib/smalt/auth/sts_key.ex`), `lib/smalt/arm_gateway/router.ex` (JWKS route + `/common/discovery/instance` + `openid_envelope/2` only)
- **Test surface:** `test/compliance/c6_oauth.exs` (extensions), new `test/auth/sts_key_test.exs`
- **Docs surface:** `docs/compliance/C6_OAUTH_OIDC.md` (rows 7, 14, 17), `docs/jira/v26.10.14/KNOWN_DIVERGENCES.md` (KD-99/KD-100 close)

## 0. Decision gate (read first)

The whole WO rides on one falsifiable claim: **@azure/identity's `ClientSecretCredential` works against smalt with zero custom code** once (a) MSAL instance discovery resolves, and (b) the advertised alg list matches what the token endpoint actually signs with. Everything else in this WO is in service of that acceptance. If any scoped fix would require touching a non-identity plane, stop → typed-UNSUPPORTED per the lane-06 precedent.

**Acceptance (whole-WO):** a probe using `new ClientSecretCredential(...)` + `@azure/arm-resources` reaches **200 on `GET /subscriptions`** with **zero smalt-authored credential code** (no `SmaltTokenCredential`). Witnessed once as a real probe run with output in the receipt.

## 1. CLOSE — RS256 signing key module (C6 row 7)

**Defect.** `Smalt.ArmGateway.Router` signs v2.0 access tokens with a Joken HS256 signer (`router.ex:334,381` — `Joken.Signer.create("HS256", secret)`); C6 row 7 pins `{"typ":"JWT","alg":"HS256"}` vs AAD `RS256` as DEV-MODE. Real Azure AD never issues HS256 v2.0 tokens, and msal-node/Azure SDK clients refuse or distrust them.

**Fix (new module, `lib/smalt/auth/sts_key.ex`).**
1. Generate/hold an RSA-2048 keypair (persisted under `var/` or derived deterministically per boot; pick and pin one — persistence preferred so JWKS is stable across restarts; wire `Application` env `:smalt, :sts_signing_key` with boot-time load, fail-closed if unreadable).
2. Sign v2.0 access tokens with `RS256` via Joken's JOSE backend (`Joken.Signer.create("RS256", %{"jwk" => jwk_map})` or `%JOSE.JWS`); keep `kid` stable and in the JWT header.
3. **Delete `SmaltTokenCredential`** — `workspace/lib/azure/credential.ts` (whole file), plus every import in `workspace/lib/azure/arm-client.ts`, `resource-queries.ts`, `README.md`. The class exists only because the emulator lacked discovery (its own docblock: "msal-node resolves tenant endpoints via OIDC instance discovery before posting the client_credentials grant... `endpoints_resolution_error`"). Delete, do not deprecate — the acceptance probe is the replacement. Keep `assertLocalUrl` air-gap host check on the armBase path where it survives the refactor.

**Fence:** decode a minted access token, assert `"alg":"RS256"` + stable `kid` in the header; `test/auth/sts_key_test.exs` pins sign→verify round-trip through the JWKS; `grep -r SmaltTokenCredential workspace/` → 0 hits (outside receipts).

## 2. CLOSE — JWKS route serves the real public key (C6 row 14)

**Defect.** `get "/:tenant_id/discovery/v2.0/keys"` (`router.ex:~2640`) serves `{"keys":[]}` — honestly empty in HS256 dev-mode, but an RS256 deployment must publish the verification key or no OIDC client can verify an id_token.

**Fix.** Render `{"keys":[<RSA JWK from StsKey, kty=RSA, n/e/kid, use=sig, alg=RS256>]}` from the module in §1. Keep the honestly-empty fallback ONLY if no key is configured (fail behavior pinned in test).

**Fence:** `GET /{tid}/discovery/v2.0/keys` → 200, `keys` length 1, `kty=="RSA"`, `kid` equals the token-header `kid` (C6 fence test extension: mint → fetch JWKS → verify signature with the published key, end-to-end).

## 3. CLOSE — `/common/discovery/instance` AAD instance-metadata aliases form (row 19 family)

**Defect.** `get "/common/discovery/instance"` (`router.ex:2615-2630`) returns the legacy minimal form (`tenantId`, `authorization_endpoint`, `token_endpoint`, `issuer`, `tenant_discovery_endpoint`). Modern msal-node posts/gets **instance discovery** and expects the Azure AD instance-metadata envelope: top-level `tenant_discovery_endpoint` **plus** a `metadata` array whose entries carry `preferred_network`, `preferred_cache`, and `aliases` (e.g. `login.microsoftonline.com`, `login.microsoft.com`, `localhost` — the request authority's host must appear in `aliases`, fail-closed to the request host). Without the aliases entry msal-node's instance-discovery validation can refuse a non-canonical host.

**Fix.** Extend the envelope additively: keep every existing member byte-identical, add `"metadata" => [%{"preferred_network" => host, "preferred_cache" => host, "aliases" => [host | canonical_aliases]}]` derived from the same `request_authority/1` shared with `openid_envelope/2` (lane-90 TS court law: advertise the authority the CLIENT reached, never a hardcoded NXDOMAIN).

**Fence:** `/common/discovery/instance` → 200 with `metadata[0].aliases` containing the request host; existing discovery tests unmodified green.

## 4. CLOSE — openid-config alg list (C6 row 17)

**Defect.** `openid_envelope/2` advertises `"id_token_signing_alg_values_supported" => ["HS256"]` (`router.ex:396`), self-consistent with row 7 but both are DEV-MODE vs AAD `["RS256"]`.

**Fix.** After §1 lands: `["RS256"]`. Single source of truth — read the alg from `Smalt.Auth.StsKey` (not a second literal) so the advertisement can never drift from the signer again.

**Fence:** discovery doc → `["RS256"]`; fence test asserts envelope alg list == signer alg (drift falsifier).

## 5. KD-99 / KD-100 close

Close both KDs **receipt-gated only**:
- KD-99 (HS256-only token signing — rows 7/17 family): closes when §1+§4 land and the acceptance probe passes over RS256-issued tokens.
- KD-100 (empty JWKS — row 14 family): closes when §2 lands and the end-to-end mint→JWKS-verify fence is green.

Flips go through `scripts/kd_flip.py` / `just gap-sync` discipline — no unilateral register edits; the KD rows cite this receipt.

## 6. Documentation work items

1. `docs/compliance/C6_OAUTH_OIDC.md`: **row 7** DEV-MODE→PASS (RS256 signer, `sts_key.ex` cite), **row 14** PASS with the populated-JWKS shape, **row 17** DEV-MODE→PASS (`["RS256"]`, single-source-from-signer note). Update the "Court method" test count.
2. `workspace/lib/azure/README.md`: remove the custom-credential section; document the zero-custom-code path (`ClientSecretCredential` + authority override).
3. `KNOWN_DIVERGENCES.md`: KD-99/KD-100 rows rewritten CLOSED with the receipt path.

## 7. Acceptance & sequencing

**Acceptance (restated, the WO's terminal fence):** `test/sdk-smoke`-style probe — `new ClientSecretCredential(tenantId, clientId, clientSecret, {authorityHost: <smalt authority>})` + `@azure/arm-resources` SDK client → `resourceClient.subscriptions.list()` → **200** with `azure-mgmt-resource` (the PY twin may substitute `azure-mgmt-resource` / `DefaultAzureCredential` for the same 200) — **zero custom code**, receipt records the real run output (exit code + probe counts, per the RECEIPTS SUSPECT rule).

Sequencing: 1 → 2 (same module; §2 fails closed until §1 exists) → 3 → 4 → 5 (KD flips after the probe) → 6 (docs last). Test extensions land with each task.
