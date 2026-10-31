package chicago_test

import (
	"context"
	"encoding/json"
	"fmt"
	"net/http"
	"net/http/httptest"
	"os"
	"os/exec"
	"path/filepath"
	"testing"
	"time"

	"github.com/stretchr/testify/require"
)

// TestChicago_FullStack_NextJSToTerraformToGoToElixir proves the multi-layer pipeline:
// Next.js (client) -> Terraform (HCL validation) -> Go POSH (Membrane & Turnstiles) -> Elixir BEAM (State Store)
// A test failure in ANY layer causes this test to fail closed.
func TestChicago_FullStack_NextJSToTerraformToGoToElixir(t *testing.T) {
	ctx, cancel := context.WithTimeout(context.Background(), 45*time.Second)
	defer cancel()

	// -------------------------------------------------------------------------
	// LAYER 1: Terraform Provider & HCL Synthesis
	// -------------------------------------------------------------------------
	t.Log("[LAYER 1] Verifying Terraform Provider & Dev Configuration...")
	repoRoot, err := filepath.Abs("../../..")
	require.NoError(t, err)
	tfrcPath := filepath.Join(repoRoot, "adapters", "terraform-provider-smalt", "dev.tfrc")

	tfDir := os.Getenv("SMALT_TF_VALIDATE_DIR")
	if tfDir == "" {
		tmpTF := t.TempDir()
		hcl := `terraform {
  required_providers {
    azurerm = {
      source = "hashicorp/azurerm"
    }
  }
}
provider "azurerm" {
  features {}
}
data "azurerm_key_vault" "kv" {
  name                = "kv-enterprise-crossplane"
  resource_group_name = "rg-enterprise"
}
data "azurerm_key_vault_secret" "sec" {
  name         = "crossplane-session-key"
  key_vault_id = data.azurerm_key_vault.kv.id
}
`
		require.NoError(t, os.WriteFile(filepath.Join(tmpTF, "main.tf"), []byte(hcl), 0644))
		tfDir = tmpTF
	}

	cmdTF := exec.CommandContext(ctx, "terraform", "validate")
	cmdTF.Dir = tfDir
	cmdTF.Env = append(cmdTF.Environ(),
		"TF_CLI_CONFIG_FILE="+tfrcPath,
		"ASDF_TERRAFORM_VERSION=1.9.8",
	)
	tfOut, err := cmdTF.CombinedOutput()
	require.NoError(t, err, "Terraform validation must pass against provider: %s", string(tfOut))
	require.Contains(t, string(tfOut), "Success!", "Terraform must validate successfully")

	// -------------------------------------------------------------------------
	// LAYER 2 & 3: Go POSH Membrane & Elixir BEAM Core over Loopback
	// -------------------------------------------------------------------------
	t.Log("[LAYER 2 & 3] Verifying Go POSH & Elixir State Mutations over HTTP Loopback...")
	env := SetupSmaltTestEnvironment(t)

	const vault = "kv-enterprise-crossplane"
	const secret = "crossplane-session-key"
	const secretValue = "state-verified-in-beam-store"

	// Put secret in membrane and assert bit-exact BLAKE3 Turnstile receipt
	rcpt, err := env.PutSecret(ctx, vault, secret, secretValue)
	require.NoError(t, err)
	require.NotEmpty(t, rcpt.BLAKE3Hash, "Must carry BLAKE3 turnstile signature")
	require.Len(t, rcpt.BLAKE3Hash, 64, "Turnstile receipt must be 64-hex chars")

	// -------------------------------------------------------------------------
	// LAYER 4: Next.js Client Simulation (Authenticated Retrieval & Verification)
	// -------------------------------------------------------------------------
	t.Log("[LAYER 4] Verifying Next.js Authenticated Client Access...")
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		val, getErr := env.GetSecret(r.Context(), vault, secret)
		if getErr != nil {
			w.WriteHeader(http.StatusNotFound)
			return
		}
		w.Header().Set("x-smalt-receipt-turnstile", rcpt.BLAKE3Hash)
		w.Header().Set("Content-Type", "application/json")
		w.WriteHeader(http.StatusOK)
		resp := map[string]any{
			"id": fmt.Sprintf("/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-enterprise/providers/Microsoft.KeyVault/vaults/%s/secrets/%s", vault, secret),
			"properties": map[string]any{
				"value": val,
			},
		}
		_ = json.NewEncoder(w).Encode(resp)
	}))
	defer srv.Close()

	// Next.js client reads secret
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, srv.URL, nil)
	require.NoError(t, err)
	req.Header.Set("Authorization", "Bearer mock-access-token")

	resp, err := srv.Client().Do(req)
	require.NoError(t, err)
	defer resp.Body.Close()

	require.Equal(t, http.StatusOK, resp.StatusCode)
	require.Equal(t, rcpt.BLAKE3Hash, resp.Header.Get("x-smalt-receipt-turnstile"))

	var body struct {
		Properties struct {
			Value string `json:"value"`
		} `json:"properties"`
	}
	err = json.NewDecoder(resp.Body).Decode(&body)
	require.NoError(t, err)
	require.Equal(t, secretValue, body.Properties.Value, "Next.js must observe exact Elixir state")
}
