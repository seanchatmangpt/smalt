# GAP-01: STS face classification — sovereign vs Azure-dialect (v26.10.31)

Lane 1 of 17, unification-dialect migration. Reads: `00-unification-dialect-decision.md`,
`lib/smalt/identity/*`, `lib/smalt/arm_gateway/plug/oidc_sts.ex`, `lib/smalt/auth/{bearer,sts_key}.ex`,
`lib/smalt/plane/identity/sts_gate.ex`, consumers (harness `smalt-client.ts`,
`scripts/tf_cleanroom.sh`, azurerm Go provider).

## Verdict

The STS face is **Azure-dialect, not sovereign** — with one sovereign residue.

- **Wire shape is dialect**: the mint recipe is pinned to Entra wire shapes at every
  layer — `POST /{tenant}/oauth2/v2.0/token` (fixed literal in `oidc_idp.ex:121` and
  `oidc_sts.ex`), the Entra-shaped response envelope
  (`token_type/expires_in/ext_expires_in/scope/access_token`), the claim set
  (`aud` = `https://management.azure.com`, `iss` = `{authority}/{tenant}/v2.0`, `tid`,
  `appid`, `azp`, `oid`, `roles`) — all Azure vocabulary. Since the decision record's
  law 1 ("smalt never grows a per-vendor face") and its open question 3 (neutral core
  needs a principal/credential model), the STS wire face classifies as **dialect #0:
  the identity dialect**, preceding dialect #1 (Azure ARM). Consumers reaching the
  STS through the Azure-dialect token endpoint are dialect consumers.
- **The in-memory token authority is sovereign**: StsGate (AZB-15 DR gate,
  `lib/smalt/plane/identity/sts_gate.ex`), `Smalt.Auth.StsKey` (RS256/HS256 key custody,
  env-PEM-first, once-per-VM lock), Bearer authority registry (cross-seat trust,
  membership at mint time never from client-asserted claims), sign-ins ring
  (AF-L14-GAP-1). None of this speaks Azure on the wire; it is smalt's own identity
  plane. Under law 4 (posh stateless), this authority **stays in smalt** — a posh
  component owning token issuance would repeat the internal/wasm SPAF violation.
  The STS wire face (the Bandit plug serving Entra-shaped mint/discovery/JWKS) is
  the Azure-dialect projection of that sovereign authority.

STS = a sovereign in-memory credential authority with an Azure-dialect wire projection,
not two things to split apart — the projection is thin and all-Azure.

## Migration table

| Item | Location | Classification | Migration |
|---|---|---|---|
| STS token endpoint `POST /{tenant}/oauth2/v2.0/token` | `lib/smalt/arm_gateway/plug/oidc_sts.ex`, `lib/smalt/identity/oidc_idp.ex` | Azure-dialect wire face (dialect #0, identity dialect) | **Stays in smalt byte-identical** (same law as the ARM face: wire-proven, azurerm-swap-depended-on). No posh port. |
| OIDC discovery (`/.well-known/openid-configuration`, `discovery/keys`) | `oidc_idp.ex:322,344`, `OidcJwks` | Azure-dialect wire face | Stays byte-identical in smalt. |
| SAML (entra_saml, saml_idp, saml_slo) | `lib/smalt/identity/` | Azure-dialect wire face | Stays byte-identical. |
| Mint recipe (claim set + envelope) | `oidc_sts.ex issue_token/2` | Azure vocabulary | Stays byte-identical; reclassified native→dialect projection, same as ARM-face reclassification in the decision record. |
| StsGate (AZB-15 DR gate) | `lib/smalt/plane/identity/sts_gate.ex` | Sovereign identity-plane state | **Stays in smalt.** posh never mints. |
| StsKey (RS256/HS256 key custody) | `lib/smalt/auth/sts_key.ex` | Sovereign key custody | **Stays in smalt.** |
| Bearer authority registry (cross-seat trust) | `lib/smalt/auth/bearer.ex` | Sovereign admission state | **Stays in smalt.** |
| Sign-ins ring | `lib/smalt/egress/signins.ex` | Sovereign audit state | Stays in smalt. |
| Client-side minting (harness `smalt-client.ts`, tf_cleanroom curl leg, azurerm provider's client_credentials) | courtroom-platform-az `apps/web/test/harness/lib/smalt-client.ts`, `~/smalt/scripts/tf_cleanroom.sh:291,527`, vendored azurerm Go provider | Client-side, already dialect-side | **Already posh/court-side** — nothing to migrate; the clients speak the Azure token endpoint wire, so they continue against a byte-identical smalt STS face. |
| Neutral-core principal/credential model | (does not exist) | Neutral core (open question 3) | **New work, core-level**: `smalt-core.ttl` principal/credential classes; the STS face becomes dialect #0 projecting into them. Core classes named before first non-Azure dialect. |

## Close conditions

1. **CC-1 (reclassification, no code)**: the STS face is registered as dialect #0
   (identity dialect) in the v26.10.31 charter; `registry.ex` entry reclassified
   native→dialect projection, generated via regen, no hand-edit. Close on charter
   registration + regen receipt.
2. **CC-2 (byte-identity)**: `tf_cleanroom.sh` zero-state + residue STS legs still pass
   with the wire face unchanged (sha of `oidc_sts.ex` + `oidc_idp.ex` unchanged is
   the cheap witness; the curl legs are the live witness). Close on a passing
   tf_cleanroom receipt.
3. **CC-3 (core model)**: `smalt-core.ttl` carries principal/credential classes
   (per open question 3) that the STS claims set maps onto 1:1
   (principal = oid/sub/appid, credential = the minted token + its authority + TTL,
   roles = core authorization roles). Close on ttl + regen receipt + a court
   asserting the mapping (e.g. a minted token's claims resolve to core IRIs).
4. **CC-4 (sovereignty fence)**: posh stays token-mint-free — a grep court over the
   posh tree for mint-capable code (key custody, JWT signing, `StsKey`-class logic)
   returns zero hits; re-run per wave. Zero hits closes; any hit reopens.

CC-2 witnesses live: `tf_cleanroom.sh` runs two real STS POSTs (lines 291, 527) and
fails closed on mint failure (line  fence at 550). CC-4 is a real grep court, not a
tautology: any signing capability found in posh fails the court.

## Status

- STS wire face: **ALIVE** (tf_cleanroom STS POST legs, `scripts/tf_cleanroom.sh:291,527`).
- Sovereign identity plane (StsGate/StsKey/Bearer/SignIns): **ALIVE** (booted in
  `lib/smalt/application.ex` identity subtree; tf_cleanroom mints succeed against it).
- Neutral-core principal/credential model: **UNVERIFIED** (does not exist — CC-3 is
  open, charter item).
- posh-side client minting: **ALIVE** (harness `smalt-client.ts:12` POSTs the smalt
  STS endpoint; tf_cleanroom curl legs pass).

## Wave-2 close note (gap lane, 2026-10-30)

- **Dialect-#0 classification artifact LANDED**: `posh/internal/dialect/azure/sts.go`
  pins the verdict as typed data (`STSDialect=0`, sovereign-authority const, 10-row
  migration table with all dispositions) + `sts_test.go` court. Courts PASS in
  isolation (`go test` in /tmp/sts-lane: 2/2 PASS, exit 0); the azure package itself
  does not compile this hour due to OTHER lanes' in-flight files
  (`lro.go`, `lro_parity_test.go` `splitPath` redeclared, `family_translate.go`
  `NormalizeARMID` undefined) — not introduced by this lane.
- **CC-4 grep court RUN, PASS**: zero mint-capable code in posh non-test files after
  classification — `internal/auth/jwt.go` is RS256/HS256 VERIFICATION-only (no
  signing path), `internal/armclient/client.go mintToken` is client-side exchange
  (allowed per migration table row 9), `internal/mock/mock.go handleOAuthToken`
  emits an opaque `mock-posh-bearer-token-<unix>` string (no key custody, no JWT
  signing). Zero mint-capable hits closes CC-4 for this wave.
- **CC-2 sha witness recorded**: `oidc_sts.ex` = `c6622b05b3e7bff03c255952897cabf7afc1654a`,
  `oidc_idp.ex` = `f78fd3aefb360ade57f51947eac2b3c1e8c068db` (2026-10-30, this lane,
  unchanged by it). Live tf_cleanroom curl legs NOT re-run by this lane — still open
  for the coordinator (or a substrate lane).
- **CC-1 premise rot noted**: `lib/smalt/registry.ex` carries **zero** STS rows today
  (grep count 0) — there is no native STS entry to reclassify. CC-1 is therefore
  ADDITIVE registration (pack ontology + regen), not a native→dialect flip. Charter
  registration (`00-unification-dialect-decision.md` + charter doc) and the registry
  regen are coordinator/charter-scribe-owned; remains OPEN for them.
- **CC-3**: remains OPEN (core principal/credential classes absent from
  `priv/ontologies/public-cloud-core.ttl`; charter item).
- **oidc_sts.ex untouched** by this lane (strip lane's lease).
