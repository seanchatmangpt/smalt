package membrane_test

import (
	"context"
	"net/http"
	"testing"

	"smalt.dev/posh/internal/membrane"
)

func TestSmaltTestEnvironment_FullLifecycle(t *testing.T) {
	ctx := context.Background()
	env := membrane.NewSmaltTestEnvironment()

	// 1. Provision Workspace
	fixture := membrane.TenantStateFixture{
		TenantID:      "tenant-alpha",
		WorkspaceID:   "workspace-001",
		ResourceGroup: "rg-alpha",
		VNetID:        "vnet-alpha",
		AppID:         "ca-enterprise",
	}

	rcpt, err := env.ApplyTenantConfig(ctx, fixture)
	if err != nil {
		t.Fatalf("apply failed: %v", err)
	}
	if rcpt.ReceiptID == "" || rcpt.BLAKE3Hash == "" {
		t.Fatalf("invalid receipt: %+v", rcpt)
	}

	// 2. Resource Group State
	rg := env.GetResourceGroupState(ctx, "rg-alpha")
	if rg.Name != "rg-alpha" || rg.Tags["TenantID"] != "tenant-alpha" {
		t.Fatalf("unexpected rg state: %+v", rg)
	}

	// 3. ContainerApp State
	ca, err := env.GetContainerAppState(ctx, "rg-alpha", "ca-enterprise")
	if err != nil {
		t.Fatalf("get ca failed: %v", err)
	}
	if ca.InstanceCount != 1 || len(ca.Template.Containers) != 2 || !ca.Template.SharingSettings.LocalhostNetworking {
		t.Fatalf("unexpected ca state: %+v", ca)
	}

	// 4. VNet packet simulation (isolated vs cross-tenant)
	respAllowed := env.SimulatePacket(ctx, "vnet-alpha", "vnet-alpha")
	if respAllowed.StatusCode != http.StatusOK {
		t.Fatalf("expected 200 OK for intra-tenant, got %d", respAllowed.StatusCode)
	}

	respForbidden := env.SimulatePacket(ctx, "vnet-alpha", "vnet-other")
	if respForbidden.StatusCode != http.StatusForbidden {
		t.Fatalf("expected 403 Forbidden for cross-tenant, got %d", respForbidden.StatusCode)
	}
}
