package provider

import (
	"context"
	"os"
	"sync"

	"github.com/hashicorp/terraform-plugin-framework/datasource"
	"github.com/hashicorp/terraform-plugin-framework/path"
	"github.com/hashicorp/terraform-plugin-framework/provider"
	"github.com/hashicorp/terraform-plugin-framework/provider/schema"
	"github.com/hashicorp/terraform-plugin-framework/resource"
	"github.com/hashicorp/terraform-plugin-framework/schema/validator"
	"github.com/hashicorp/terraform-plugin-framework/types"
)

var (
	registeredMu               sync.Mutex
	registeredExtraResources   []func() resource.Resource
	registeredExtraDataSources []func() datasource.DataSource
)

func RegisterResource(fn func() resource.Resource) {
	registeredMu.Lock()
	defer registeredMu.Unlock()
	registeredExtraResources = append(registeredExtraResources, fn)
}

func RegisterDataSource(fn func() datasource.DataSource) {
	registeredMu.Lock()
	defer registeredMu.Unlock()
	registeredExtraDataSources = append(registeredExtraDataSources, fn)
}

// Compile-time interface checks.
var _ provider.Provider = (*smaltProvider)(nil)

type smaltProvider struct {
	version string
}

func New(version string) func() provider.Provider {
	return func() provider.Provider {
		return &smaltProvider{version: version}
	}
}

func (p *smaltProvider) Metadata(ctx context.Context, req provider.MetadataRequest, resp *provider.MetadataResponse) {
	resp.TypeName = "azurerm"
	resp.Version = p.version
}

func (p *smaltProvider) Schema(ctx context.Context, req provider.SchemaRequest, resp *provider.SchemaResponse) {
	resp.Schema = schema.Schema{
		Description: "azurerm-compatible provider backed by the smalt local ARM plane.",
		Attributes: map[string]schema.Attribute{
			"subscription_id": schema.StringAttribute{
				Optional:    true,
				Description: "Azure subscription ID (UUID). Falls back to `ARM_SUBSCRIPTION_ID` when omitted.",
				Validators: []validator.String{
					uuidValidator{},
				},
			},
			"arm_endpoint": schema.StringAttribute{
				Optional:    true,
				Description: "smalt ARM plane endpoint (absolute `http(s)` URL). Falls back to `SMALT_ARM_ENDPOINT`, then `http://127.0.0.1:9443`.",
				Validators: []validator.String{
					urlValidator{},
				},
				// Default (SMALT_ARM_ENDPOINT env, then
				// http://127.0.0.1:9443) is resolved at configure time in
				// NewClient — provider-schema attributes cannot carry
				// Computed/defaults in the framework.
			},
			"tenant_id": schema.StringAttribute{
				Optional:    true,
				Description: "Azure tenant ID (UUID). Defaults to the smalt mock tenant when omitted.",
				Validators: []validator.String{
					uuidValidator{},
				},
			},
			"client_id": schema.StringAttribute{
				Optional:    true,
				Description: "Azure client (app) ID used for the token mint. Defaults to the smalt mock tenant UUID when omitted.",
			},
			"client_secret": schema.StringAttribute{
				Optional:    true,
				Sensitive:   true,
				Description: "Azure client secret. Unused by the smalt mock plane; accepted for azurerm parity.",
			},
			"ca_cert": schema.StringAttribute{
				Optional: true,
				Description: "PEM CA certificate appended to the trust pool for the " +
					"`https://127.0.0.1:9444` TLS twin.",
			},
			"metadata_host": schema.StringAttribute{
				Optional:    true,
				Description: "Metadata host override for azurerm parity; accepted but unused by the smalt plane.",
				// azurerm parity: azurerm deprecates metadata_host in favor
				// of environment. Kept optional here; parity without
				// removing the attr (schema-parity gate depends on the set).
				DeprecationMessage: "metadata_host is deprecated in azurerm; prefer omitting it (accepted for parity, unused by smalt).",
			},
			"environment": schema.StringAttribute{
				Optional:    true,
				Description: "Azure cloud environment name (e.g. `public`). Accepted for azurerm parity; unused by the smalt plane.",
			},
			"resource_provider_registrations": schema.StringAttribute{
				Optional:    true,
				Description: "Resource-provider registration mode (`none`, `legacy`, `registration`, `disabled`). Accepted for azurerm parity; unused by the smalt plane.",
				Validators: []validator.String{
					oneOfCIValidator("none", "legacy", "registration", "disabled"),
				},
			},
			"storage_use_azuread": schema.BoolAttribute{
				Optional:    true,
				Description: "Whether to use Azure AD for storage authorization. Accepted for azurerm parity; defaults to `false` when omitted.",
				// Default false is applied where the value is consumed;
				// provider-schema attributes cannot carry defaults in the
				// framework.
			},
			"skip_provider_registration": schema.BoolAttribute{
				Optional:    true,
				Description: "Skip provider registration for azurerm parity.",
			},
			"use_msi": schema.BoolAttribute{
				Optional:    true,
				Description: "Accepted for azurerm parity.",
			},
			"use_oidc": schema.BoolAttribute{
				Optional:    true,
				Description: "Accepted for azurerm parity.",
			},
			"use_cli": schema.BoolAttribute{
				Optional:    true,
				Description: "Accepted for azurerm parity.",
			},
		},
		Blocks: map[string]schema.Block{
			"features": schema.SingleNestedBlock{
				Description: "Empty features block, azurerm-compatible.",
				Blocks: map[string]schema.Block{
					"key_vault": schema.SingleNestedBlock{
						Attributes: map[string]schema.Attribute{
							"purge_soft_delete_on_destroy":               schema.BoolAttribute{Optional: true},
							"purge_soft_deleted_secrets_on_destroy":      schema.BoolAttribute{Optional: true},
							"purge_soft_deleted_keys_on_destroy":         schema.BoolAttribute{Optional: true},
							"purge_soft_deleted_certificates_on_destroy": schema.BoolAttribute{Optional: true},
							"recover_soft_deleted_key_vaults":            schema.BoolAttribute{Optional: true},
							"recover_soft_deleted_secrets":               schema.BoolAttribute{Optional: true},
							"recover_soft_deleted_keys":                  schema.BoolAttribute{Optional: true},
							"recover_soft_deleted_certificates":          schema.BoolAttribute{Optional: true},
						},
					},
					"resource_group": schema.SingleNestedBlock{
						Attributes: map[string]schema.Attribute{
							"prevent_deletion_if_contains_resources": schema.BoolAttribute{Optional: true},
						},
					},
					"container_app": schema.SingleNestedBlock{
						Attributes: map[string]schema.Attribute{},
					},
					"log_analytics_workspace": schema.SingleNestedBlock{
						Attributes: map[string]schema.Attribute{
							"permanently_delete_on_destroy": schema.BoolAttribute{Optional: true},
						},
					},
					"virtual_machine": schema.SingleNestedBlock{
						Attributes: map[string]schema.Attribute{
							"delete_os_disk_on_deletion":     schema.BoolAttribute{Optional: true},
							"graceful_shutdown":              schema.BoolAttribute{Optional: true},
							"skip_shutdown_and_force_delete": schema.BoolAttribute{Optional: true},
						},
					},
				},
			},
		},
	}
}

type providerConfigModel struct {
	SubscriptionID                types.String `tfsdk:"subscription_id"`
	ArmEndpoint                   types.String `tfsdk:"arm_endpoint"`
	TenantID                      types.String `tfsdk:"tenant_id"`
	ClientID                      types.String `tfsdk:"client_id"`
	ClientSecret                  types.String `tfsdk:"client_secret"`
	CaCert                        types.String `tfsdk:"ca_cert"`
	MetadataHost                  types.String `tfsdk:"metadata_host"`
	Environment                   types.String `tfsdk:"environment"`
	ResourceProviderRegistrations types.String `tfsdk:"resource_provider_registrations"`
	StorageUseAzureAD             types.Bool   `tfsdk:"storage_use_azuread"`
	Features                      types.Object `tfsdk:"features"`
}

func (p *smaltProvider) Configure(ctx context.Context, req provider.ConfigureRequest, resp *provider.ConfigureResponse) {
	var subscriptionID, armEndpoint, tenantID, clientID, caCert types.String
	resp.Diagnostics.Append(req.Config.GetAttribute(ctx, path.Root("subscription_id"), &subscriptionID)...)
	resp.Diagnostics.Append(req.Config.GetAttribute(ctx, path.Root("arm_endpoint"), &armEndpoint)...)
	resp.Diagnostics.Append(req.Config.GetAttribute(ctx, path.Root("tenant_id"), &tenantID)...)
	resp.Diagnostics.Append(req.Config.GetAttribute(ctx, path.Root("client_id"), &clientID)...)
	resp.Diagnostics.Append(req.Config.GetAttribute(ctx, path.Root("ca_cert"), &caCert)...)
	if resp.Diagnostics.HasError() {
		return
	}

	sub := subscriptionID.ValueString()
	if sub == "" {
		sub = os.Getenv("ARM_SUBSCRIPTION_ID")
	}

	client, err := NewClient(ctx, armEndpoint.ValueString(), sub, tenantID.ValueString(),
		clientID.ValueString(), caCert.ValueString())
	if err != nil {
		resp.Diagnostics.AddError("provider configuration", err.Error())
		return
	}
	resp.ResourceData = client
	resp.DataSourceData = client
}

func (p *smaltProvider) Resources(ctx context.Context) []func() resource.Resource {
	registeredMu.Lock()
	extra := append([]func() resource.Resource(nil), registeredExtraResources...)
	registeredMu.Unlock()

	all := append([]func() resource.Resource{NewResourceGroupResource}, extra...)
	seen := make(map[string]int, len(all))
	out := make([]func() resource.Resource, 0, len(all))
	for _, fn := range all {
		if fn == nil {
			continue
		}
		r := fn()
		var mr resource.MetadataResponse
		r.Metadata(ctx, resource.MetadataRequest{ProviderTypeName: "azurerm"}, &mr)
		if idx, ok := seen[mr.TypeName]; ok && mr.TypeName != "" {
			out[idx] = fn
			continue
		}
		seen[mr.TypeName] = len(out)
		out = append(out, fn)
	}
	return out
}

func (p *smaltProvider) DataSources(ctx context.Context) []func() datasource.DataSource {
	registeredMu.Lock()
	extra := append([]func() datasource.DataSource(nil), registeredExtraDataSources...)
	registeredMu.Unlock()

	all := append([]func() datasource.DataSource{NewClientConfigDataSource}, extra...)
	seen := make(map[string]int, len(all))
	out := make([]func() datasource.DataSource, 0, len(all))
	for _, fn := range all {
		if fn == nil {
			continue
		}
		d := fn()
		var mr datasource.MetadataResponse
		d.Metadata(ctx, datasource.MetadataRequest{ProviderTypeName: "azurerm"}, &mr)
		if idx, ok := seen[mr.TypeName]; ok && mr.TypeName != "" {
			out[idx] = fn
			continue
		}
		seen[mr.TypeName] = len(out)
		out = append(out, fn)
	}
	return out
}

func (p *smaltProvider) ConfigValidators(ctx context.Context) []provider.ConfigValidator {
	return nil
}
