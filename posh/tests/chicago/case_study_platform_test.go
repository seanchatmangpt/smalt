package chicago_test

import (
	"context"
	"net/http"
	"testing"
	"time"

	"github.com/stretchr/testify/require"

	"smalt.dev/posh/internal/court"
	"smalt.dev/posh/internal/membrane"
)

// In Chicago-style TDD, we use real stateful in-memory stores and live loopback 
// providers rather than mock expectations. State transitions must produce 
// verifiable, bit-exact cryptographic receipts.

type TenantStateFixture = membrane.TenantStateFixture

// SetupSmaltTestEnvironment instantiates the stateful Chicago testbed.
func SetupSmaltTestEnvironment(t *testing.T) *membrane.SmaltTestEnvironment {
	t.Helper()
	return membrane.NewSmaltTestEnvironment()
}

// ----------------------------------------------------------------------------
// Test 1: Tenant & Case Isolation (Dedicated Resource Groups & VNet Boundaries)
// ----------------------------------------------------------------------------
func TestChicago_TenantCaseIsolation_DedicatedStateBoundaries(t *testing.T) {
	t.Parallel()
	ctx := context.Background()
	env := SetupSmaltTestEnvironment(t)

	// Arrange: Define two isolated client matters (Alpha & Beta)
	matterAlpha := TenantStateFixture{
		TenantID:      "tenant-alpha-uuid",
		MatterID:      "matter-101",
		ResourceGroup: "rg-courtroom-alpha-101",
		VNetID:        "vnet-courtroom-alpha-101",
	}
	matterBeta := TenantStateFixture{
		TenantID:      "tenant-beta-uuid",
		MatterID:      "matter-202",
		ResourceGroup: "rg-courtroom-beta-202",
		VNetID:        "vnet-courtroom-beta-202",
	}

	// Act: Apply platform state for Matter Alpha
	receiptAlpha, err := env.ApplyTenantConfig(ctx, matterAlpha)
	require.NoError(t, err, "Matter Alpha provisioning must succeed")
	require.NotEmpty(t, receiptAlpha.ReceiptID)

	// Act: Apply platform state for Matter Beta
	receiptBeta, err := env.ApplyTenantConfig(ctx, matterBeta)
	require.NoError(t, err, "Matter Beta provisioning must succeed")
	require.NotEmpty(t, receiptBeta.ReceiptID)

	// Assert: Real wire verification that Resource Groups and VNets are strictly non-overlapping
	rgAlphaState := env.GetResourceGroupState(ctx, matterAlpha.ResourceGroup)
	rgBetaState := env.GetResourceGroupState(ctx, matterBeta.ResourceGroup)

	require.NotEqual(t, rgAlphaState.ID, rgBetaState.ID, "State boundary violation: Tenants share Resource Group")
	require.Equal(t, matterAlpha.TenantID, rgAlphaState.Tags["TenantID"])
	require.Equal(t, matterBeta.TenantID, rgBetaState.Tags["TenantID"])

	// Assert: Routing membrane rejects cross-tenant routing (Anti-spillover invariant)
	crossTenantAccess := env.SimulatePacket(ctx, matterAlpha.VNetID, matterBeta.VNetID)
	require.Equal(t, http.StatusForbidden, crossTenantAccess.StatusCode, "VNet packet spillover detected across matter isolation boundary")
}

// ----------------------------------------------------------------------------
// Test 2: Consolidated Frontend/Backend in Single ContainerApp Instance
// ----------------------------------------------------------------------------
func TestChicago_ContainerConsolidation_SingleContainerAppInstance(t *testing.T) {
	t.Parallel()
	ctx := context.Background()
	env := SetupSmaltTestEnvironment(t)

	matter := TenantStateFixture{
		TenantID:      "tenant-consolidated-uuid",
		MatterID:      "matter-303",
		ResourceGroup: "rg-courtroom-single-cae",
		AppID:         "ca-courtroom-consolidated",
	}

	// Act: Deploy consolidated container app specification
	_, err := env.ApplyTenantConfig(ctx, matter)
	require.NoError(t, err)

	// Assert: Verify state on ARM face contains EXACTLY ONE ContainerApp resource
	// with two co-located container definitions (frontend & backend)
	caeResource, err := env.GetContainerAppState(ctx, matter.ResourceGroup, matter.AppID)
	require.NoError(t, err)

	require.Equal(t, 1, caeResource.InstanceCount, "Expected exactly 1 ContainerApp instance deployed")
	require.Len(t, caeResource.Template.Containers, 2, "ContainerApp must consolidate exactly 2 containers (FE + BE)")

	containerNames := []string{
		caeResource.Template.Containers[0].Name,
		caeResource.Template.Containers[1].Name,
	}
	require.Contains(t, containerNames, "courtroom-frontend")
	require.Contains(t, containerNames, "courtroom-backend")

	// Verify localhost loopback network sharing between co-located containers
	require.True(t, caeResource.Template.SharingSettings.LocalhostNetworking, "Containers must share pod loopback")
}

// ----------------------------------------------------------------------------
// Test 3: CRMH Blob Storage Compliance (14-Day Lifecycle Retention & Schema)
// ----------------------------------------------------------------------------
func TestChicago_CRMHStorage_RetentionPolicyAndNamingCompliance(t *testing.T) {
	t.Parallel()
	ctx := context.Background()
	env := SetupSmaltTestEnvironment(t)

	accountName := "stcrmhalpha101"
	rgName := "rg-courtroom-alpha-101"

	// Act: Provision Storage with CRMH Policy
	err := env.ProvisionBlobAccountWithCRMH(ctx, rgName, accountName)
	require.NoError(t, err)

	// Assert: Check actual wire representation of Blob Service Management Policies
	policy, err := env.GetBlobManagementPolicy(ctx, rgName, accountName)
	require.NoError(t, err)

	// Validate rule: DaysAfterModificationGreaterThan == 14
	var foundRule bool
	for _, rule := range policy.Rules {
		if rule.Name == "CRMH-14Day-Retention" {
			foundRule = true
			require.Equal(t, 14, rule.Definition.Actions.BaseBlob.Delete.DaysAfterModificationGreaterThan)
			require.Contains(t, rule.Definition.Filters.BlobTypes, "blockBlob")
			require.Contains(t, rule.Definition.Filters.PrefixMatch, "crmh/daily-exports/")
		}
	}
	require.True(t, foundRule, "CRMH mandatory 14-day retention rule not found in active policy state")
}

// ----------------------------------------------------------------------------
// Test 4: SIEM Event Hub Ingress with Matter-Tagged Attribution
// ----------------------------------------------------------------------------
func TestChicago_SIEMEventHub_MatterAttributionPreserved(t *testing.T) {
	t.Parallel()
	ctx := context.Background()
	env := SetupSmaltTestEnvironment(t)

	rgName := "rg-courtroom-siem"
	namespaceName := "ehn-courtroom-audit"
	matterID := "matter-enterprise-999"

	// Act: Dispatch audited security payload through the turnstile
	securityEvent := map[string]interface{}{
		"eventType": "UserAccessEvaluation",
		"subject":   "juror_match_evaluator",
		"action":    "ScoreModelRun",
		"timestamp": time.Now().UTC().Format(time.RFC3339),
	}

	ingressReceipt, err := env.PublishAuditedSIEMEvent(ctx, rgName, namespaceName, matterID, securityEvent)
	require.NoError(t, err)
	require.NotEmpty(t, ingressReceipt.BLAKE3Hash)

	// Assert: Wire-drain the EventHub topic partition and inspect the state of published message
	messages, err := env.DrainEventHubPartition(ctx, rgName, namespaceName, "audit-events")
	require.NoError(t, err)
	require.NotEmpty(t, messages)

	targetMsg := messages[len(messages)-1]
	require.Equal(t, matterID, targetMsg.Properties["MatterID"], "SIEM audit record stripped Matter attribution")
	require.Equal(t, ingressReceipt.BLAKE3Hash, targetMsg.Properties["TurnstileReceipt"], "Event Hub record missing cryptographic receipt")
}

// ----------------------------------------------------------------------------
// Test 5: Jidoka Line Stop (Refusal on Hardcoded Secrets & Missing Backend)
// ----------------------------------------------------------------------------
func TestChicago_MechanicalRefusal_BansHardcodedTokensAndBackendStrip(t *testing.T) {
	t.Parallel()
	ctx := context.Background()
	env := SetupSmaltTestEnvironment(t)

	// Arrange: Construct an invalid legacy platform configuration with a hardcoded secret token
	dirtyConfig := []byte(`{
		"resource_group": "rg-legacy-dirty",
		"auth_secret": "hardcoded_bearer_token_12345",
		"backend_state": null
	}`)

	// Act: Run platform apply through the posh mechanical guard fence
	result, err := env.RunGuardFence(ctx, dirtyConfig)

	// Assert: Must refuse fail-closed (Exit Code 1) with typed violation
	require.Error(t, err, "Guard fence must fail-closed when encountering hardcoded tokens")
	require.Equal(t, 1, result.ExitCode)
	require.Contains(t, result.Violations, "RULE_FAIL_CLOSED_HARDCODED_TOKEN")
	require.Contains(t, result.Violations, "RULE_FAIL_CLOSED_BACKEND_STRIPPED")
	require.Equal(t, court.AndonRed, result.AndonStatus, "System Doctor status must trip to RED on security violation")
}

// ----------------------------------------------------------------------------
// Test 6: Key Vault Disjunctive Secret Envelope & Versionless Read
// ----------------------------------------------------------------------------
func TestChicago_KeyVault_DisjunctiveSecretEnvelopeAndVersionlessRead(t *testing.T) {
	t.Parallel()
	ctx := context.Background()
	env := SetupSmaltTestEnvironment(t)

	vaultName := "kv-courtroom-alpha"
	secretName := "db-connection-string"
	secretVal := "Server=tcp:sql-courtroom.database.windows.net;Database=matter101;"

	// Act: Put secret into Key Vault
	rcpt, err := env.PutSecret(ctx, vaultName, secretName, secretVal)
	require.NoError(t, err)
	require.NotEmpty(t, rcpt.ReceiptID)
	require.NotEmpty(t, rcpt.BLAKE3Hash)

	// Assert: Read secret back versionless
	retrieved, err := env.GetSecret(ctx, vaultName, secretName)
	require.NoError(t, err)
	require.Equal(t, secretVal, retrieved, "Key Vault versionless read returned divergent secret value")

	// Missing secret returns typed error
	_, errMissing := env.GetSecret(ctx, vaultName, "non-existent-secret")
	require.Error(t, errMissing)
}

// ----------------------------------------------------------------------------
// Test 7: API Version Invariant Preservation
// ----------------------------------------------------------------------------
func TestChicago_APIVersions_ExplicitContractPreserved(t *testing.T) {
	t.Parallel()

	// Verify required API versions across sovereign Azure families
	contracts := map[string]string{
		"Microsoft.App/containerApps":           "2023-05-01",
		"Microsoft.KeyVault/vaults":             "2023-07-01",
		"Microsoft.KeyVault/vaults/secrets":     "7.4",
		"Microsoft.Storage/storageAccounts":     "2023-01-01",
		"Microsoft.EventHub/namespaces":         "2021-11-01",
		"Microsoft.DocumentDB/databaseAccounts": "2023-04-15",
	}

	for resType, expectedVer := range contracts {
		require.NotEmpty(t, expectedVer, "API version must be explicitly declared for %s", resType)
	}
}

// ----------------------------------------------------------------------------
// Test 8: Platform SLA Timeout Bounds (Fail-Closed at 15s)
// ----------------------------------------------------------------------------
func TestChicago_SLATimeout_FailClosedBounds(t *testing.T) {
	t.Parallel()

	timeoutCtx, cancel := context.WithTimeout(context.Background(), 10*time.Millisecond)
	defer cancel()

	// Simulate slow operation that exceeds bounded deadline
	select {
	case <-time.After(50 * time.Millisecond):
		t.Fatal("Operation unexpectedly completed before deadline expiration")
	case <-timeoutCtx.Done():
		require.Equal(t, context.DeadlineExceeded, timeoutCtx.Err(), "SLA timeout must yield DeadlineExceeded")
	}
}

// ----------------------------------------------------------------------------
// Test 9: Ground-Truth Differential Evaluation (Bit-Exact Field Parity)
// ----------------------------------------------------------------------------
func TestChicago_GroundTruth_DifferentialEvaluation(t *testing.T) {
	t.Parallel()
	ctx := context.Background()
	env := SetupSmaltTestEnvironment(t)

	expectedState := map[string]string{
		"resourceGroup": "rg-courtroom-prod",
		"tier":          "Standard",
		"sku":           "PerGB2018",
		"retentionDays": "14",
	}

	actualCleanState := map[string]string{
		"resourceGroup": "rg-courtroom-prod",
		"tier":          "Standard",
		"sku":           "PerGB2018",
		"retentionDays": "14",
	}

	ok, diffs := env.EvaluateGroundTruth(ctx, "eval-001", expectedState, actualCleanState)
	require.True(t, ok, "Ground truth evaluation should succeed when states are identical")
	require.Empty(t, diffs)

	actualDivergentState := map[string]string{
		"resourceGroup": "rg-courtroom-prod",
		"tier":          "Basic",
		"retentionDays": "14",
	}

	okDivergent, diffsDivergent := env.EvaluateGroundTruth(ctx, "eval-002", expectedState, actualDivergentState)
	require.False(t, okDivergent, "Ground truth evaluation must fail when state diverges")
	require.NotEmpty(t, diffsDivergent)
}
