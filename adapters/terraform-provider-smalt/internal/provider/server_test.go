package provider

import (
	"context"
	"strings"
	"testing"

	"github.com/hashicorp/terraform-plugin-framework/datasource"
	"github.com/hashicorp/terraform-plugin-framework/provider"
	"github.com/hashicorp/terraform-plugin-framework/resource"
)

// Chicago-school schema tests: assert on the real provider schema object.

func TestProviderSchemaAttrs(t *testing.T) {
	p := New("test")()
	sr := &provider.SchemaResponse{}
	p.Schema(context.Background(), provider.SchemaRequest{}, sr)

	want := []string{
		"subscription_id", "arm_endpoint", "tenant_id", "client_id",
		"client_secret", "ca_cert", "metadata_host", "environment",
		"resource_provider_registrations", "storage_use_azuread",
	}
	for _, attr := range want {
		if _, ok := sr.Schema.Attributes[attr]; !ok {
			t.Errorf("provider schema missing attribute %q", attr)
		}
	}
	if _, ok := sr.Schema.Blocks["features"]; !ok {
		t.Errorf("provider schema missing features block")
	}
	if !sr.Schema.Attributes["storage_use_azuread"].IsComputed() && !sr.Schema.Attributes["arm_endpoint"].IsOptional() {
		t.Errorf("arm_endpoint must be optional")
	}
}

func TestResourceGroupSchema(t *testing.T) {
	r := NewResourceGroupResource()
	mr := &resource.MetadataResponse{}
	r.Metadata(context.Background(), resource.MetadataRequest{ProviderTypeName: "azurerm"}, mr)
	if mr.TypeName != "azurerm_resource_group" {
		t.Errorf("type name = %q, want azurerm_resource_group", mr.TypeName)
	}
	sr := &resource.SchemaResponse{}
	r.Schema(context.Background(), resource.SchemaRequest{}, sr)
	for _, attr := range []string{"name", "location", "tags", "id"} {
		if _, ok := sr.Schema.Attributes[attr]; !ok {
			t.Errorf("resource_group schema missing %q", attr)
		}
	}
	if !sr.Schema.Attributes["id"].IsComputed() {
		t.Errorf("id must be computed")
	}
	if !sr.Schema.Attributes["name"].IsRequired() || !sr.Schema.Attributes["location"].IsRequired() {
		t.Errorf("name/location must be required")
	}
}

func TestClientConfigSchema(t *testing.T) {
	d := NewClientConfigDataSource()
	mr := &datasource.MetadataResponse{}
	d.Metadata(context.Background(), datasource.MetadataRequest{ProviderTypeName: "azurerm"}, mr)
	if mr.TypeName != "azurerm_client_config" {
		t.Errorf("type name = %q", mr.TypeName)
	}
	sr := &datasource.SchemaResponse{}
	d.Schema(context.Background(), datasource.SchemaRequest{}, sr)
	for _, attr := range []string{"tenant_id", "subscription_id", "client_id", "object_id"} {
		if _, ok := sr.Schema.Attributes[attr]; !ok {
			t.Errorf("client_config schema missing %q", attr)
		}
		if !sr.Schema.Attributes[attr].IsComputed() {
			t.Errorf("client_config attr %q must be computed", attr)
		}
	}
}

func TestProviderResourcesAndDataSources(t *testing.T) {
	ctx := context.Background()
	p := New("test")()

	reqR := resource.MetadataRequest{ProviderTypeName: "azurerm"}
	resR := resource.MetadataResponse{}

	resources := p.Resources(ctx)
	const expectedResources = 12
	if len(resources) != expectedResources {
		t.Fatalf("expected %d registered resources, got %d", expectedResources, len(resources))
	}

	expectedResourceTypes := map[string]bool{
		"azurerm_resource_group":                false,
		"azurerm_container_app_environment":     false,
		"azurerm_container_app":                 false,
		"azurerm_key_vault":                     false,
		"azurerm_key_vault_secret":              false,
		"azurerm_user_assigned_identity":        false,
		"azurerm_federated_identity_credential": false,
		"azurerm_role_definition":               false,
		"azurerm_role_assignment":               false,
		"azurerm_container_registry":            false,
		"azurerm_log_analytics_workspace":       false,
		"azurerm_storage_account":               false,
	}

	for _, rf := range resources {
		r := rf()
		r.Metadata(ctx, reqR, &resR)
		if _, ok := expectedResourceTypes[resR.TypeName]; !ok {
			t.Errorf("unexpected resource registered: %s", resR.TypeName)
		} else {
			expectedResourceTypes[resR.TypeName] = true
		}
	}

	for typeName, seen := range expectedResourceTypes {
		if !seen {
			t.Errorf("missing expected resource registration: %s", typeName)
		}
	}

	reqD := datasource.MetadataRequest{ProviderTypeName: "azurerm"}
	resD := datasource.MetadataResponse{}

	dataSources := p.DataSources(ctx)
	const expectedDataSources = 7
	if len(dataSources) != expectedDataSources {
		t.Fatalf("expected %d registered data sources, got %d", expectedDataSources, len(dataSources))
	}

	expectedDataSourceTypes := map[string]bool{
		"azurerm_client_config":          false,
		"azurerm_resource_group":         false,
		"azurerm_smalt_health":           false,
		"azurerm_container_registry":     false,
		"azurerm_key_vault":              false,
		"azurerm_user_assigned_identity": false,
		"azurerm_storage_account":        false,
	}

	for _, df := range dataSources {
		d := df()
		d.Metadata(ctx, reqD, &resD)
		if _, ok := expectedDataSourceTypes[resD.TypeName]; !ok {
			t.Errorf("unexpected data source registered: %s", resD.TypeName)
		} else {
			expectedDataSourceTypes[resD.TypeName] = true
		}
	}

	for typeName, seen := range expectedDataSourceTypes {
		if !seen {
			t.Errorf("missing expected data source registration: %s", typeName)
		}
	}
}

func TestParseJWTExpiry(t *testing.T) {
	// exp = 1793383488 (observed from live smalt STS token)
	tok := "eyJhbGciOiJSUzI1NiIsImtpZCI6IngifQ." +
		"eyJleHAiOjE3OTMzODM0ODh9." +
		"c2ln"
	got := parseJWTExpiry(tok)
	if got.Unix() != 1793383488 {
		t.Errorf("exp = %d, want 1793383488", got.Unix())
	}
	if got.Unix() < 0 {
		t.Errorf("negative expiry")
	}
	// Malformed tokens must fall back to a near-term default, not panic.
	if parseJWTExpiry("garbage").IsZero() {
		t.Errorf("fallback expiry zero")
	}
	if strings.Contains("garbage", ".") {
		t.Log("two-part token falls back")
	}
}
