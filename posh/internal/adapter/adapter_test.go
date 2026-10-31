package adapter_test

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"testing"

	"github.com/stretchr/testify/require"

	"smalt.dev/posh/internal/adapter"
	"smalt.dev/posh/internal/api"
	"smalt.dev/posh/internal/config"
)

// In Chicago-style testing, we spin up real local loopback HTTP servers
// and assert real state transitions and bit-exact receipt shapes.
func TestChicago_MembraneAdapter_DispatchRealCollaborator(t *testing.T) {
	t.Parallel()

	// 1. Arrange a real loopback HTTP collaborator
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		defer r.Body.Close()
		w.Header().Set("Content-Type", "application/json")
		w.WriteHeader(http.StatusOK)
		_, _ = w.Write([]byte(`{"status":"admitted"}`))
	}))
	defer srv.Close()

	// 2. Configure egress fence to admit loopback
	cfg := &config.Config{
		EgressAllowlist: []string{srv.URL, "http://127.0.0.1:9443"},
	}

	// 3. Verify DialectRegistry admits the projected ops
	spec, ok := adapter.DialectRegistry.LookupOp("arm.container_app")
	require.True(t, ok, "arm.container_app must be admitted by projected DialectRegistry")
	require.Equal(t, "https://smalt.dev/posh/ns#receiptContainerApp", spec.TurnstileReceipt)
	require.Contains(t, spec.AllowHosts, "http://127.0.0.1:9443")

	// Verify unadmitted op fails closed
	_, okUnadmitted := adapter.DialectRegistry.LookupOp("unadmitted.op.spec")
	require.False(t, okUnadmitted, "unadmitted op must fail closed")

	// 4. Verify Dispatch rejects unadmitted operations fail-closed
	reqPayload, err := json.Marshal(api.Request{
		ID: "req-alpha-001",
		Op: "unadmitted.op.fake",
	})
	require.NoError(t, err)

	_, errDispatch := adapter.Dispatch(cfg, "unadmitted.op.fake", reqPayload)
	require.Error(t, errDispatch, "dispatch must refuse unadmitted ops")

	// 5. Verify Dispatch rejects op when host is refused by egress fence
	strictCfg := &config.Config{
		EgressAllowlist: []string{"http://10.0.0.1:9999"}, // Does NOT admit 127.0.0.1:9443
	}
	validAppPayload, err := json.Marshal(api.Request{
		ID: "req-app-002",
		Op: "arm.container_app",
	})
	require.NoError(t, err)

	_, errFenced := adapter.Dispatch(strictCfg, "arm.container_app", validAppPayload)
	require.Error(t, errFenced, "dispatch must refuse host not in egress allowlist")
}

func TestChicago_MembraneAdapter_AllRegisteredOpsAdmitted(t *testing.T) {
	t.Parallel()

	expectedOps := []string{
		"arm.container_app_environment",
		"arm.container_app",
		"arm.container_registry",
		"arm.federated_identity_credential",
		"arm-get",
		"arm.key_vault_secret",
		"arm.key_vault",
		"arm.log_analytics_workspace",
		"arm.request",
		"arm.resource_group",
		"arm.role_assignment",
		"arm.role_definition",
		"arm.storage_account",
		"arm.user_assigned_identity",
		"echo",
	}

	for _, op := range expectedOps {
		spec, ok := adapter.DialectRegistry.LookupOp(op)
		require.True(t, ok, "op %s must be admitted in DialectRegistry", op)
		require.NotEmpty(t, spec.TurnstileReceipt, "op %s must have turnstile receipt", op)
		require.NotEmpty(t, spec.AllowHosts, "op %s must declare allow hosts", op)
	}
}
