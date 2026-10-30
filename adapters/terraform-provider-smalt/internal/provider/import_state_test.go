package provider

import (
	"context"
	"strings"
	"testing"

	"github.com/hashicorp/terraform-plugin-framework/diag"
	"github.com/hashicorp/terraform-plugin-framework/resource/schema"
	"github.com/hashicorp/terraform-plugin-framework/path"
	"github.com/hashicorp/terraform-plugin-framework/resource"
	"github.com/hashicorp/terraform-plugin-framework/tfsdk"
)

// GAP22-1/2/3 close courts: real framework ImportState calls against real
// schema-backed states (Chicago discipline — no mocks; the framework's
// tfsdk.State is the real collaborator).

const importTestSub = "11111111-2222-3333-4444-555555555555"

func importTestClient(t *testing.T) *Client {
	t.Helper()
	c, err := NewClient(context.Background(), "http://127.0.0.1:9443", importTestSub, "", "", "")
	if err != nil {
		t.Fatalf("NewClient: %v", err)
	}
	return c
}

func importTestResource(t *testing.T, r resource.Resource, c *Client) (s schema.Schema) {
	t.Helper()
	if c != nil {
		f4Configure(t, r, c)
	}
	return f4Schema(t, r)
}

// importRun drives a real ImportState over a fresh null-attribute state and
// returns the response for assertion.
func importRun(ctx context.Context, t *testing.T, r resource.Resource, s schema.Schema, id string) *resource.ImportStateResponse {
	t.Helper()
	resp := &resource.ImportStateResponse{}
	resp.State = tfsdk.State{Schema: s, Raw: f4Raw(t, s, map[string]any{})}
	r.(resource.ResourceWithImportState).ImportState(ctx, resource.ImportStateRequest{ID: id}, resp)
	return resp
}

func importAttrString(ctx context.Context, t *testing.T, resp *resource.ImportStateResponse, attr string) string {
	t.Helper()
	var s string
	d := resp.State.GetAttribute(ctx, path.Root(attr), &s)
	if d.HasError() {
		t.Fatalf("GetAttribute %s: %+v", attr, d)
	}
	return s
}

func hasWarningDiag(d diag.Diagnostics) bool {
	return d.WarningsCount() > 0
}

// ---- GAP22-1: azurerm_resource_group ImportState ----

func TestImportResourceGroupFullName(t *testing.T) {
	ctx := context.Background()
	c := importTestClient(t)
	r := NewResourceGroupResource()
	s := importTestResource(t, r, c)

	full := "/subscriptions/" + importTestSub + "/resourcegroups/RG-Mixed-Case"
	resp := importRun(ctx, t, r, s, full)
	f4Diags(t, "import rg", resp.Diagnostics)
	if got := importAttrString(ctx, t, resp, "id"); got != "/subscriptions/"+importTestSub+"/resourceGroups/RG-Mixed-Case" {
		t.Fatalf("id = %q (NormalizeARMID casing not applied)", got)
	}
	if got := importAttrString(ctx, t, resp, "name"); got != "RG-Mixed-Case" {
		t.Fatalf("name = %q", got)
	}
}

func TestImportResourceGroupBareName(t *testing.T) {
	ctx := context.Background()
	c := importTestClient(t)
	r := NewResourceGroupResource()
	s := importTestResource(t, r, c)

	resp := importRun(ctx, t, r, s, "rg-bare-name")
	f4Diags(t, "import rg bare", resp.Diagnostics)
	want := "/subscriptions/" + importTestSub + "/resourceGroups/rg-bare-name"
	if got := importAttrString(ctx, t, resp, "id"); got != want {
		t.Fatalf("id = %q, want %q", got, want)
	}
	if got := importAttrString(ctx, t, resp, "name"); got != "rg-bare-name" {
		t.Fatalf("name = %q", got)
	}
}

func TestImportResourceGroupRefusesWrongShape(t *testing.T) {
	ctx := context.Background()
	c := importTestClient(t)
	r := NewResourceGroupResource()
	s := importTestResource(t, r, c)

	for _, id := range []string{
		// resource-in-group id: RG ids never carry a providers/ segment
		"/subscriptions/" + importTestSub + "/resourceGroups/rg/providers/Microsoft.KeyVault/vaults/kv",
		// vault id adopted as RG: refused
		"/subscriptions/" + importTestSub + "/resourceGroups/rg/providers/Microsoft.App/containerApps/ca",
		// subscription-only id: no resourceGroups segment
		"/subscriptions/" + importTestSub,
	} {
		resp := importRun(ctx, t, r, s, id)
		if !resp.Diagnostics.HasError() {
			t.Fatalf("import id %q: adopted without error (silent wrong-resource adoption)", id)
		}
	}
}

// ---- GAP22-2: UAI import seeds computed identity attrs honestly ----

func uaiID() string {
	return "/subscriptions/" + importTestSub + "/resourceGroups/rg/providers/Microsoft.ManagedIdentity/userAssignedIdentities/id-uai"
}

func TestImportUAIDefaultRefusesFabricatedAttrs(t *testing.T) {
	ctx := context.Background()
	t.Setenv("TFPOSH_ALLOW_FABRICATED_IDS", "")
	c := importTestClient(t)
	r := NewUserAssignedIdentityResource()
	s := importTestResource(t, r, c)

	resp := importRun(ctx, t, r, s, uaiID())
	if !resp.Diagnostics.HasError() {
		t.Fatal("UAI import without prior identity attrs must refuse (honesty law), got no error")
	}

	// The id/rg/name are set, but client_id/principal_id stay null — the
	// refusal is loud, not a silent null that blows up on first refresh.
	var m userAssignedIdentityModel
	f4Diags(t, "state get", resp.State.Get(ctx, &m))
	if !m.ClientID.IsNull() || !m.PrincipalID.IsNull() {
		t.Fatalf("attrs set despite refusal: client_id=%q principal_id=%q", m.ClientID.ValueString(), m.PrincipalID.ValueString())
	}
}

func TestImportUAIOptInMintsLoudly(t *testing.T) {
	ctx := context.Background()
	t.Setenv("TFPOSH_ALLOW_FABRICATED_IDS", "1")
	c := importTestClient(t)
	r := NewUserAssignedIdentityResource()
	s := importTestResource(t, r, c)

	resp := importRun(ctx, t, r, s, uaiID())
	f4Diags(t, "import uai opt-in", resp.Diagnostics)
	var m userAssignedIdentityModel
	f4Diags(t, "state get", resp.State.Get(ctx, &m))
	if want := mintDeterministicGUID("uai-client:" + uaiID()); m.ClientID.ValueString() != want {
		t.Fatalf("client_id = %q, want deterministic mint %q", m.ClientID.ValueString(), want)
	}
	if want := mintDeterministicGUID("uai-principal:" + uaiID()); m.PrincipalID.ValueString() != want {
		t.Fatalf("principal_id = %q, want deterministic mint %q", m.PrincipalID.ValueString(), want)
	}
	if !hasWarningDiag(resp.Diagnostics) {
		t.Fatal("opt-in mint must carry a LOUD warning diag")
	}
}

// ---- GAP22-3: per-type segment assertion across every ImportState ----

func TestImportPerTypeSegmentAssertions(t *testing.T) {
	ctx := context.Background()
	c := importTestClient(t)
	sub := importTestSub

	cases := []struct {
		resourceType string
		newResource  func() resource.Resource
		goodID       string
		foreignIDs   []string
	}{
		{
			resourceType: "azurerm_resource_group",
			newResource:  func() resource.Resource { return NewResourceGroupResource() },
			goodID:       "/subscriptions/" + sub + "/resourceGroups/rg",
			foreignIDs: []string{
				"/subscriptions/" + sub + "/resourceGroups/rg/providers/Microsoft.KeyVault/vaults/kv",
			},
		},
		{
			resourceType: "azurerm_key_vault",
			newResource:  func() resource.Resource { return NewKeyVaultResource() },
			goodID:       "/subscriptions/" + sub + "/resourceGroups/rg/providers/Microsoft.KeyVault/vaults/kv",
			foreignIDs: []string{
				// CAE id into key_vault: silently adopted before GAP22-3
				"/subscriptions/" + sub + "/resourceGroups/rg/providers/Microsoft.App/managedEnvironments/cae",
				// bare RG path
				"/subscriptions/" + sub + "/resourceGroups/rg",
			},
		},
		{
			resourceType: "azurerm_key_vault_secret",
			newResource:  func() resource.Resource { return NewKeyVaultSecretResource() },
			goodID:       "/subscriptions/" + sub + "/resourceGroups/rg/providers/Microsoft.KeyVault/vaults/kv/secrets/nested/name",
			foreignIDs: []string{
				"/subscriptions/" + sub + "/resourceGroups/rg/providers/Microsoft.KeyVault/vaults/kv",
			},
		},
		{
			resourceType: "azurerm_container_app",
			newResource:  func() resource.Resource { return NewContainerAppResource() },
			goodID:       "/subscriptions/" + sub + "/resourceGroups/rg/providers/Microsoft.App/containerApps/ca",
			foreignIDs: []string{
				// vault id into container_app: silently adopted before GAP22-3
				"/subscriptions/" + sub + "/resourceGroups/rg/providers/Microsoft.KeyVault/vaults/kv",
				"/subscriptions/" + sub + "/resourceGroups/rg/providers/Microsoft.App/managedEnvironments/cae",
			},
		},
		{
			resourceType: "azurerm_container_app_environment",
			newResource:  func() resource.Resource { return NewContainerAppEnvironmentResource() },
			goodID:       "/subscriptions/" + sub + "/resourceGroups/rg/providers/Microsoft.App/managedEnvironments/cae",
			foreignIDs: []string{
				"/subscriptions/" + sub + "/resourceGroups/rg/providers/Microsoft.App/containerApps/ca",
			},
		},
		{
			resourceType: "azurerm_user_assigned_identity",
			newResource: func() resource.Resource {
				t.Setenv("TFPOSH_ALLOW_FABRICATED_IDS", "1") // seeding law tested separately
				return NewUserAssignedIdentityResource()
			},
			goodID: "/subscriptions/" + sub + "/resourceGroups/rg/providers/Microsoft.ManagedIdentity/userAssignedIdentities/uai",
			foreignIDs: []string{
				"/subscriptions/" + sub + "/resourceGroups/rg/providers/Microsoft.KeyVault/vaults/kv",
			},
		},
		{
			resourceType: "azurerm_federated_identity_credential",
			newResource:  func() resource.Resource { return NewFederatedIdentityCredentialResource() },
			goodID:       "/subscriptions/" + sub + "/resourceGroups/rg/providers/Microsoft.ManagedIdentity/userAssignedIdentities/uai/federatedIdentityCredentials/fic",
			foreignIDs: []string{
				"/subscriptions/" + sub + "/resourceGroups/rg/providers/Microsoft.ManagedIdentity/userAssignedIdentities/uai",
			},
		},
		{
			resourceType: "azurerm_role_definition",
			newResource:  func() resource.Resource { return NewRoleDefinitionResource() },
			goodID:       "/subscriptions/" + sub + "/providers/Microsoft.Authorization/roleDefinitions/abc",
			foreignIDs: []string{
				"/subscriptions/" + sub + "/providers/Microsoft.Authorization/roleAssignments/abc",
			},
		},
		{
			resourceType: "azurerm_role_assignment",
			newResource:  func() resource.Resource { return NewRoleAssignmentResource() },
			goodID:       "/subscriptions/" + sub + "/resourceGroups/rg/providers/Microsoft.Authorization/roleAssignments/abc",
			foreignIDs: []string{
				"/subscriptions/" + sub + "/resourceGroups/rg/providers/Microsoft.Authorization/roleDefinitions/abc",
			},
		},
		{
			resourceType: "azurerm_container_registry",
			newResource:  func() resource.Resource { return NewContainerRegistryResource() },
			goodID:       "/subscriptions/" + sub + "/resourceGroups/rg/providers/Microsoft.ContainerRegistry/registries/cr",
			foreignIDs: []string{
				"/subscriptions/" + sub + "/resourceGroups/rg/providers/Microsoft.App/containerApps/ca",
			},
		},
		{
			resourceType: "azurerm_log_analytics_workspace",
			newResource:  func() resource.Resource { return NewLogAnalyticsWorkspaceResource() },
			goodID:       "/subscriptions/" + sub + "/resourceGroups/rg/providers/Microsoft.OperationalInsights/workspaces/log",
			foreignIDs: []string{
				"/subscriptions/" + sub + "/resourceGroups/rg/providers/Microsoft.Storage/storageAccounts/sa",
			},
		},
		{
			resourceType: "azurerm_storage_account",
			newResource:  func() resource.Resource { return NewStorageAccountResource() },
			goodID:       "/subscriptions/" + sub + "/resourceGroups/rg/providers/Microsoft.Storage/storageAccounts/sa",
			foreignIDs: []string{
				"/subscriptions/" + sub + "/resourceGroups/rg/providers/Microsoft.ContainerRegistry/registries/cr",
			},
		},
	}

	for _, tc := range cases {
		t.Run(tc.resourceType, func(t *testing.T) {
			r := tc.newResource()
			s := importTestResource(t, r, c)

			resp := importRun(ctx, t, r, s, tc.goodID)
			f4Diags(t, "good id", resp.Diagnostics)
			if got := importAttrString(ctx, t, resp, "id"); got != tc.goodID {
				t.Fatalf("good id stored as %q, want %q", got, tc.goodID)
			}

			for _, fid := range tc.foreignIDs {
				resp := importRun(ctx, t, r, s, fid)
				if !resp.Diagnostics.HasError() {
					t.Fatalf("foreign id %q adopted into %s without error", fid, tc.resourceType)
				}
				found := false
				for _, d := range resp.Diagnostics {
					if d.Severity() == diag.SeverityError && strings.Contains(d.Detail(), "GAP22-3") {
						found = true
					}
				}
				if !found {
					t.Fatalf("foreign id %q refused but without the GAP22-3 typed diagnostic", fid)
				}
			}
		})
	}
}
