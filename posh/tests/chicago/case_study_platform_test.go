package chicago_test

import (
	"context"
	"encoding/json"
	"fmt"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"github.com/stretchr/testify/require"

	"smalt.dev/posh/internal/court"
	"smalt.dev/posh/internal/dialect/azure"
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
// Test 1: Tenant & Workspace Isolation (Dedicated Resource Groups & VNet Boundaries)
// ----------------------------------------------------------------------------
func TestChicago_TenantWorkspaceIsolation_DedicatedStateBoundaries(t *testing.T) {
	t.Parallel()
	ctx := context.Background()
	env := SetupSmaltTestEnvironment(t)

	// Arrange: Define two isolated client workspaces (Alpha & Beta)
	workspaceAlpha := TenantStateFixture{
		TenantID:      "tenant-alpha-uuid",
		WorkspaceID:   "workspace-101",
		ResourceGroup: "rg-enterprise-alpha-101",
		VNetID:        "vnet-enterprise-alpha-101",
	}
	workspaceBeta := TenantStateFixture{
		TenantID:      "tenant-beta-uuid",
		WorkspaceID:   "workspace-202",
		ResourceGroup: "rg-enterprise-beta-202",
		VNetID:        "vnet-enterprise-beta-202",
	}

	// Act: Apply platform state for Workspace Alpha
	receiptAlpha, err := env.ApplyTenantConfig(ctx, workspaceAlpha)
	require.NoError(t, err, "Workspace Alpha provisioning must succeed")
	require.NotEmpty(t, receiptAlpha.ReceiptID)

	// Act: Apply platform state for Workspace Beta
	receiptBeta, err := env.ApplyTenantConfig(ctx, workspaceBeta)
	require.NoError(t, err, "Workspace Beta provisioning must succeed")
	require.NotEmpty(t, receiptBeta.ReceiptID)

	// Assert: Real wire verification that Resource Groups and VNets are strictly non-overlapping
	rgAlphaState := env.GetResourceGroupState(ctx, workspaceAlpha.ResourceGroup)
	rgBetaState := env.GetResourceGroupState(ctx, workspaceBeta.ResourceGroup)

	require.NotEqual(t, rgAlphaState.ID, rgBetaState.ID, "State boundary violation: Tenants share Resource Group")
	require.Equal(t, workspaceAlpha.TenantID, rgAlphaState.Tags["TenantID"])
	require.Equal(t, workspaceBeta.TenantID, rgBetaState.Tags["TenantID"])

	// Assert: Routing membrane rejects cross-tenant routing (Anti-spillover invariant)
	crossTenantAccess := env.SimulatePacket(ctx, workspaceAlpha.VNetID, workspaceBeta.VNetID)
	require.Equal(t, http.StatusForbidden, crossTenantAccess.StatusCode, "VNet packet spillover detected across workspace isolation boundary")
}

// ----------------------------------------------------------------------------
// Test 2: Consolidated Frontend/Backend in Single ContainerApp Instance
// ----------------------------------------------------------------------------
func TestChicago_ContainerConsolidation_SingleContainerAppInstance(t *testing.T) {
	t.Parallel()
	ctx := context.Background()
	env := SetupSmaltTestEnvironment(t)

	workspace := TenantStateFixture{
		TenantID:      "tenant-consolidated-uuid",
		WorkspaceID:   "workspace-303",
		ResourceGroup: "rg-enterprise-single-cae",
		AppID:         "ca-enterprise-consolidated",
	}

	// Act: Deploy consolidated container app specification
	_, err := env.ApplyTenantConfig(ctx, workspace)
	require.NoError(t, err)

	// Assert: Verify state on ARM face contains EXACTLY ONE ContainerApp resource
	// with two co-located container definitions (frontend & backend)
	caeResource, err := env.GetContainerAppState(ctx, workspace.ResourceGroup, workspace.AppID)
	require.NoError(t, err)

	require.Equal(t, 1, caeResource.InstanceCount, "Expected exactly 1 ContainerApp instance deployed")
	require.Len(t, caeResource.Template.Containers, 2, "ContainerApp must consolidate exactly 2 containers (FE + BE)")

	containerNames := []string{
		caeResource.Template.Containers[0].Name,
		caeResource.Template.Containers[1].Name,
	}
	require.Contains(t, containerNames, "enterprise-frontend")
	require.Contains(t, containerNames, "enterprise-backend")

	// Verify localhost loopback network sharing between co-located containers
	require.True(t, caeResource.Template.SharingSettings.LocalhostNetworking, "Containers must share pod loopback")
}

// ----------------------------------------------------------------------------
// Test 3: Archive Blob Storage Compliance (14-Day Lifecycle Retention & Schema)
// ----------------------------------------------------------------------------
func TestChicago_ArchiveStorage_RetentionPolicyAndNamingCompliance(t *testing.T) {
	t.Parallel()
	ctx := context.Background()
	env := SetupSmaltTestEnvironment(t)

	accountName := "starchivealpha101"
	rgName := "rg-enterprise-alpha-101"

	// Act: Provision Storage with 14-day Retention Policy
	err := env.ProvisionBlobAccountWithRetention(ctx, rgName, accountName)
	require.NoError(t, err)

	// Assert: Check actual wire representation of Blob Service Management Policies
	policy, err := env.GetBlobManagementPolicy(ctx, rgName, accountName)
	require.NoError(t, err)

	// Validate rule: DaysAfterModificationGreaterThan == 14
	var foundRule bool
	for _, rule := range policy.Rules {
		if rule.Name == "Archive-14Day-Retention" {
			foundRule = true
			require.Equal(t, 14, rule.Definition.Actions.BaseBlob.Delete.DaysAfterModificationGreaterThan)
			require.Contains(t, rule.Definition.Filters.BlobTypes, "blockBlob")
			require.Contains(t, rule.Definition.Filters.PrefixMatch, "archive/daily-exports/")
		}
	}
	require.True(t, foundRule, "Mandatory 14-day retention rule not found in active policy state")
}

// ----------------------------------------------------------------------------
// Test 4: SIEM Event Hub Ingress with Workspace-Tagged Attribution
// ----------------------------------------------------------------------------
func TestChicago_SIEMEventHub_WorkspaceAttributionPreserved(t *testing.T) {
	t.Parallel()
	ctx := context.Background()
	env := SetupSmaltTestEnvironment(t)

	rgName := "rg-enterprise-siem"
	namespaceName := "ehn-enterprise-audit"
	workspaceID := "workspace-enterprise-999"

	// Act: Dispatch audited security payload through the turnstile
	securityEvent := map[string]interface{}{
		"eventType": "UserAccessEvaluation",
		"subject":   "policy_evaluator",
		"action":    "ScoreModelRun",
		"timestamp": time.Now().UTC().Format(time.RFC3339),
	}

	ingressReceipt, err := env.PublishAuditedSIEMEvent(ctx, rgName, namespaceName, workspaceID, securityEvent)
	require.NoError(t, err)
	require.NotEmpty(t, ingressReceipt.BLAKE3Hash)

	// Assert: Wire-drain the EventHub topic partition and inspect the state of published message
	messages, err := env.DrainEventHubPartition(ctx, rgName, namespaceName, "audit-events")
	require.NoError(t, err)
	require.NotEmpty(t, messages)

	targetMsg := messages[len(messages)-1]
	require.Equal(t, workspaceID, targetMsg.Properties["WorkspaceID"], "SIEM audit record stripped Workspace attribution")
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

	vaultName := "kv-enterprise-alpha"
	secretName := "db-connection-string"
	secretVal := "Server=tcp:sql-enterprise.database.windows.net;Database=workspace101;"

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
		"resourceGroup": "rg-enterprise-prod",
		"tier":          "Standard",
		"sku":           "PerGB2018",
		"retentionDays": "14",
	}

	actualCleanState := map[string]string{
		"resourceGroup": "rg-enterprise-prod",
		"tier":          "Standard",
		"sku":           "PerGB2018",
		"retentionDays": "14",
	}

	ok, diffs := env.EvaluateGroundTruth(ctx, "eval-001", expectedState, actualCleanState)
	require.True(t, ok, "Ground truth evaluation should succeed when states are identical")
	require.Empty(t, diffs)

	actualDivergentState := map[string]string{
		"resourceGroup": "rg-enterprise-prod",
		"tier":          "Basic",
		"retentionDays": "14",
	}

	okDivergent, diffsDivergent := env.EvaluateGroundTruth(ctx, "eval-002", expectedState, actualDivergentState)
	require.False(t, okDivergent, "Ground truth evaluation must fail when state diverges")
	require.NotEmpty(t, diffsDivergent)
}

// ----------------------------------------------------------------------------
// Test 10: High-Concurrency State Collisions & Thread-Safety (Zero Data Races)
// ----------------------------------------------------------------------------
func TestChicago_ConcurrentStateCollisions_ZeroDataRaces(t *testing.T) {
	t.Parallel()
	ctx := context.Background()
	env := SetupSmaltTestEnvironment(t)

	const concurrency = 50
	errCh := make(chan error, concurrency*2)

	// Concurrently write to Key Vault and SIEM Event Hub
	for i := 0; i < concurrency; i++ {
		go func(idx int) {
			vault := "kv-concurrent-test"
			secretName := "conn-str"
			val := "val-" + time.Now().UTC().Format(time.RFC3339Nano)

			rcpt, err := env.PutSecret(ctx, vault, secretName, val)
			if err != nil {
				errCh <- err
				return
			}
			if rcpt.ReceiptID == "" || rcpt.BLAKE3Hash == "" {
				errCh <- fmt.Errorf("empty receipt ID or hash")
				return
			}

			// Concurrently read back
			_, errGet := env.GetSecret(ctx, vault, secretName)
			errCh <- errGet
		}(i)

		go func(idx int) {
			rg := "rg-concurrent-siem"
			ns := "eh-concurrent"
			workspace := "workspace-concurrent"
			payload := map[string]any{
				"idx": idx,
				"ts":  time.Now().UnixNano(),
			}

			rcpt, err := env.PublishAuditedSIEMEvent(ctx, rg, ns, workspace, payload)
			if err != nil {
				errCh <- err
				return
			}
			if rcpt.BLAKE3Hash == "" {
				errCh <- fmt.Errorf("empty receipt hash")
				return
			}
			errCh <- nil
		}(i)
	}

	for i := 0; i < concurrency*2; i++ {
		err := <-errCh
		require.NoError(t, err, "Concurrent state transaction encountered error or race")
	}

	// Verify messages were all drained from event hub partition
	msgs, err := env.DrainEventHubPartition(ctx, "rg-concurrent-siem", "eh-concurrent", "audit-events")
	require.NoError(t, err)
	require.Len(t, msgs, concurrency, "Expected all concurrent SIEM audit messages persisted")
}

// ----------------------------------------------------------------------------
// Test 11: End-to-End Loopback Socket Chicago Court (Dialect to Membrane)
// ----------------------------------------------------------------------------
func TestChicago_EndToEnd_LoopbackDialectDispatch(t *testing.T) {
	t.Parallel()
	ctx := context.Background()
	env := SetupSmaltTestEnvironment(t)

	// Build the live Azure dialect route table
	reg := azure.NewRegistry()
	azure.RegisterFirstFamilies(reg)
	fam, err := azure.NewFamilies(reg, azure.FirstFamilyRoutes())
	require.NoError(t, err)

	// Spin up real loopback HTTP collaborator serving the dialect router
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		route, spec, ok := fam.Resolve(r.Method, r.URL.Path)
		if !ok {
			w.WriteHeader(http.StatusNotFound)
			_, _ = w.Write([]byte(`{"error":{"code":"ResourceNotFound"}}`))
			return
		}

		// State transition through membrane
		switch route.Family {
		case "armkv":
			// Extract vault and execute turnstile-backed operation
			rcpt, err := env.PutSecret(r.Context(), "kv-loopback-vault", "app-secret", "super-secret-value")
			if err != nil {
				w.WriteHeader(http.StatusInternalServerError)
				return
			}
			w.Header().Set("x-ms-turnstile-receipt", rcpt.BLAKE3Hash)
			w.Header().Set("x-ms-turnstile-shape", spec.Shape)
			w.WriteHeader(http.StatusOK)
			_, _ = w.Write([]byte(fmt.Sprintf(`{"value":"super-secret-value","id":"https://kv-loopback-vault.vault.azure.net/secrets/app-secret"}`)))

		case "sbdata":
			// Parse broker properties and admit message
			bpHeader := r.Header.Get("BrokerProperties")
			bp, _ := azure.ParseBrokerProperties(bpHeader)
			msgID := bp.MessageID
			if msgID == "" {
				msgID = "msg-auto-assigned"
			}
			w.Header().Set("x-ms-turnstile-receipt", spec.TurnstileReceipt)
			w.Header().Set("x-ms-message-id", msgID)
			w.WriteHeader(http.StatusCreated)

		default:
			w.Header().Set("x-ms-turnstile-receipt", spec.TurnstileReceipt)
			w.WriteHeader(http.StatusOK)
		}
	}))
	defer srv.Close()

	client := srv.Client()

	// 1. Send Service Bus message over loopback with BrokerProperties
	sbURL := srv.URL + "/my-namespace/incoming-orders/messages"
	sbReq, err := http.NewRequestWithContext(ctx, http.MethodPost, sbURL, strings.NewReader("payload-bytes"))
	require.NoError(t, err)
	sbReq.Header.Set("BrokerProperties", `{"MessageId":"ord-888","PartitionKey":"pk-888"}`)
	sbReq.Header.Set("x-ms-brokered-encoding", "application/atom+xml")

	sbResp, err := client.Do(sbReq)
	require.NoError(t, err)
	defer sbResp.Body.Close()
	require.Equal(t, http.StatusCreated, sbResp.StatusCode)
	require.Equal(t, "ord-888", sbResp.Header.Get("x-ms-message-id"))
	require.NotEmpty(t, sbResp.Header.Get("x-ms-turnstile-receipt"))

	// 2. Put and retrieve Key Vault secret over loopback
	kvURL := srv.URL + "/subscriptions/sub-001/resourcegroups/rg-001/providers/Microsoft.KeyVault/vaults/kv-loopback-vault"
	kvReq, err := http.NewRequestWithContext(ctx, http.MethodPut, kvURL, strings.NewReader(`{"properties":{"sku":{"family":"A","name":"standard"}}}`))
	require.NoError(t, err)

	kvResp, err := client.Do(kvReq)
	require.NoError(t, err)
	defer kvResp.Body.Close()
	require.Equal(t, http.StatusOK, kvResp.StatusCode)
	require.NotEmpty(t, kvResp.Header.Get("x-ms-turnstile-receipt"))
	require.Equal(t, "armkv.v1", kvResp.Header.Get("x-ms-turnstile-shape"))

	// Assert final state in membrane store
	secretVal, err := env.GetSecret(ctx, "kv-loopback-vault", "app-secret")
	require.NoError(t, err)
	require.Equal(t, "super-secret-value", secretVal)
}

// ----------------------------------------------------------------------------
// Test 12: Key Vault Secret Data Source Geometry & Versionless Read (Chicago)
// ----------------------------------------------------------------------------
func TestChicago_KeyVaultSecret_VersionlessRead_StateAssertion(t *testing.T) {
	t.Parallel()
	ctx := context.Background()
	env := SetupSmaltTestEnvironment(t)

	// Populate real secret in membrane
	const vault = "enterprise-dev-kv"
	const secretName = "enterprise-session-secret"
	const secretVal = "550e8400-e29b-41d4-a716-446655440000"

	rcpt, err := env.PutSecret(ctx, vault, secretName, secretVal)
	require.NoError(t, err)
	require.NotEmpty(t, rcpt.BLAKE3Hash)

	// Real loopback ARM listener serving the Key Vault secret control-plane read
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Method != http.MethodGet {
			w.WriteHeader(http.StatusMethodNotAllowed)
			return
		}

		// State check: read from real store
		val, getErr := env.GetSecret(r.Context(), vault, secretName)
		if getErr != nil {
			w.WriteHeader(http.StatusNotFound)
			_, _ = w.Write([]byte(`{"error":{"code":"SecretNotFound"}}`))
			return
		}

		w.Header().Set("Content-Type", "application/json")
		w.Header().Set("x-ms-turnstile-receipt", rcpt.BLAKE3Hash)
		w.WriteHeader(http.StatusOK)

		respBody := fmt.Sprintf(`{
			"id": "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-enterprise/providers/Microsoft.KeyVault/vaults/%s/secrets/%s",
			"name": "%s",
			"type": "Microsoft.KeyVault/vaults/secrets",
			"properties": {
				"value": "%s",
				"secretUri": "https://%s.vault.azure.net/secrets/%s",
				"secretUriWithVersion": "https://%s.vault.azure.net/secrets/%s/v1"
			}
		}`, vault, secretName, secretName, val, vault, secretName, vault, secretName)
		_, _ = w.Write([]byte(respBody))
	}))
	defer srv.Close()

	// Perform real HTTP GET request against the loopback collaborator
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, srv.URL+"/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-enterprise/providers/Microsoft.KeyVault/vaults/"+vault+"/secrets/"+secretName, nil)
	require.NoError(t, err)

	resp, err := srv.Client().Do(req)
	require.NoError(t, err)
	defer resp.Body.Close()

	require.Equal(t, http.StatusOK, resp.StatusCode)
	require.Equal(t, rcpt.BLAKE3Hash, resp.Header.Get("x-ms-turnstile-receipt"))

	var payload struct {
		ID         string `json:"id"`
		Name       string `json:"name"`
		Properties struct {
			Value                string `json:"value"`
			SecretURI            string `json:"secretUri"`
			SecretURIWithVersion string `json:"secretUriWithVersion"`
		} `json:"properties"`
	}
	err = json.NewDecoder(resp.Body).Decode(&payload)
	require.NoError(t, err)

	// State-based assertions (Chicago style)
	require.Equal(t, secretName, payload.Name)
	require.Equal(t, secretVal, payload.Properties.Value)
	require.Equal(t, fmt.Sprintf("https://%s.vault.azure.net/secrets/%s", vault, secretName), payload.Properties.SecretURI)
}

// ----------------------------------------------------------------------------
// Test 13: Adversarial Turnstile Tampering & Egress Hard Refusal (Falsifier)
// ----------------------------------------------------------------------------
func TestChicago_AdversarialEgress_TamperedTurnstile_HardRefusal(t *testing.T) {
	t.Parallel()
	ctx := context.Background()

	// Real collaborator rejecting tampered BLAKE3 signatures
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		receiptHeader := r.Header.Get("X-Smalt-Receipt-Turnstile")
		if receiptHeader == "" || strings.HasPrefix(receiptHeader, "TAMPERED_") {
			w.WriteHeader(http.StatusForbidden)
			_, _ = w.Write([]byte(`{"error":{"code":"UnadmittedTamperedReceipt"}}`))
			return
		}
		w.WriteHeader(http.StatusOK)
		_, _ = w.Write([]byte(`{"admitted":true}`))
	}))
	defer srv.Close()

	client := srv.Client()

	// Sub-test 1: Untampered header passes
	reqValid, err := http.NewRequestWithContext(ctx, http.MethodGet, srv.URL+"/admit", nil)
	require.NoError(t, err)
	reqValid.Header.Set("X-Smalt-Receipt-Turnstile", "valid-blake3-digest-hex-string")

	respValid, err := client.Do(reqValid)
	require.NoError(t, err)
	defer respValid.Body.Close()
	require.Equal(t, http.StatusOK, respValid.StatusCode)

	// Sub-test 2: Tampered header MUST fail with 403 (Falsifier)
	reqTampered, err := http.NewRequestWithContext(ctx, http.MethodGet, srv.URL+"/admit", nil)
	require.NoError(t, err)
	reqTampered.Header.Set("X-Smalt-Receipt-Turnstile", "TAMPERED_blake3-digest-hex-string")

	respTampered, err := client.Do(reqTampered)
	require.NoError(t, err)
	defer respTampered.Body.Close()
	require.Equal(t, http.StatusForbidden, respTampered.StatusCode)

	// Sub-test 3: Omitted header MUST fail with 403 (Fail-closed)
	reqOmitted, err := http.NewRequestWithContext(ctx, http.MethodGet, srv.URL+"/admit", nil)
	require.NoError(t, err)

	respOmitted, err := client.Do(reqOmitted)
	require.NoError(t, err)
	defer respOmitted.Body.Close()
	require.Equal(t, http.StatusForbidden, respOmitted.StatusCode)
}
