// Package azure — dialect-#0 classification shard for the STS face
// (docs/jira/posh/v26.10.31/gaps/01-sts-migration.md, wave-2 gap lane).
//
// Classification (GAP-01): the STS wire face is Azure-dialect #0 (the
// identity dialect), NOT sovereign wire and NOT a posh port target. The
// wire face stays in smalt byte-identical — same disposition as the ARM
// face (dialect #1). This file is a classification + mapping table
// only: it registers the dialect-#0 identity of the STS face in the
// posh dialect layer and pins the GAP-01 migration table as typed data.
// It deliberately carries NO mint capability, NO route rows, and NO key
// custody — posh never mints (GAP-01 CC-4; StsGate/StsKey/Bearer/
// SignIns stay in smalt per the decision record's law 4).
package azure

// STSDialect is the dialect number of the identity dialect. Dialect #0
// precedes dialect #1 (Azure ARM) because every ARM-plane token the ARM
// face consumes is minted through this face first.
const STSDialect = 0

// STSFaceClassifiesDialect0 witnesses GAP-01's verdict: the STS wire
// face (token endpoint, OIDC discovery, SAML, Entra claim set) is
// dialect #0.
const STSFaceClassifiesDialect0 = true

// STSAuthorityIsSovereign pins the sovereign residue: the in-memory
// token authority behind the dialect-#0 projection (StsGate DR gate,
// StsKey key custody, Bearer cross-seat registry, sign-ins ring) is
// smalt's own identity plane and stays in smalt. posh projects; posh
// never owns issuance.
const STSAuthorityIsSovereign = true

// stsMigrationRow is one row of the GAP-01 migration table, pinned as
// typed data so the classification survives doc drift: if the doc and
// the shard ever disagree, the court (sts_test.go) fails one of them.
type stsMigrationRow struct {
	item           string
	location       string
	classification string
	migration      string
}

// stsMigrationTable is the GAP-01 migration table pinned as typed data
// (GAP-01 CC-1 classification artifact).
var stsMigrationTable = []stsMigrationRow{
	{
		item:           "STS token endpoint POST /{tenant}/oauth2/v2.0/token",
		location:       "lib/smalt/arm_gateway/plug/oidc_sts.ex + lib/smalt/identity/oidc_idp.ex",
		classification: "azure-dialect",
		migration:      "stays-smalt-byte-identical",
	},
	{
		item:           "OIDC discovery + JWKS",
		location:       "lib/smalt/identity/oidc_idp.ex + lib/smalt/identity/oidc_jwks.ex",
		classification: "azure-dialect",
		migration:      "stays-smalt-byte-identical",
	},
	{
		item:           "SAML (entra_saml, saml_idp, saml_slo)",
		location:       "lib/smalt/identity/",
		classification: "azure-dialect",
		migration:      "stays-smalt-byte-identical",
	},
	{
		item:           "Mint recipe (Entra claim set + envelope)",
		location:       "lib/smalt/arm_gateway/plug/oidc_sts.ex issue_token/2",
		classification: "azure-dialect",
		migration:      "stays-smalt-byte-identical",
	},
	{
		item:           "StsGate (AZB-15 DR gate)",
		location:       "lib/smalt/plane/identity/sts_gate.ex",
		classification: "sovereign",
		migration:      "stays-smalt",
	},
	{
		item:           "StsKey (RS256/HS256 key custody)",
		location:       "lib/smalt/auth/sts_key.ex",
		classification: "sovereign",
		migration:      "stays-smalt",
	},
	{
		item:           "Bearer authority registry (cross-seat trust)",
		location:       "lib/smalt/auth/bearer.ex",
		classification: "sovereign",
		migration:      "stays-smalt",
	},
	{
		item:           "Sign-ins ring",
		location:       "lib/smalt/egress/signins.ex",
		classification: "sovereign",
		migration:      "stays-smalt",
	},
	{
		// Client-side minting is already dialect-side (GAP-01 row 9):
		// the clients speak the Azure token-endpoint wire against a
		// byte-identical smalt STS face. Nothing to migrate.
		item:           "Client-side minting",
		location:       "consumer harness + scripts/tf_cleanroom.sh + vendored azurerm provider",
		classification: "azure-dialect",
		migration:      "already-posh-court-side",
	},
	{
		// CC-3: core principal/credential classes do not exist yet —
		// open charter item, named so the shard never silently claims
		// the core model is landed.
		item:           "Neutral-core principal/credential model",
		location:       "priv/ontologies/public-cloud-core.ttl",
		classification: "neutral-core",
		migration:      "new-work-core-level (CC-3, charter item, OPEN)",
	},
}
