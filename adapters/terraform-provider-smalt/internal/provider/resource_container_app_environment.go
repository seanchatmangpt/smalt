package provider

import (
	"context"
	"fmt"
	"net/http"
	"strings"

	"github.com/hashicorp/terraform-plugin-framework/diag"
	"github.com/hashicorp/terraform-plugin-framework/path"
	"github.com/hashicorp/terraform-plugin-framework/resource"
	"github.com/hashicorp/terraform-plugin-framework/resource/schema"
	"github.com/hashicorp/terraform-plugin-framework/resource/schema/boolplanmodifier"
	"github.com/hashicorp/terraform-plugin-framework/resource/schema/int64planmodifier"
	"github.com/hashicorp/terraform-plugin-framework/resource/schema/planmodifier"
	"github.com/hashicorp/terraform-plugin-framework/resource/schema/stringplanmodifier"
	"github.com/hashicorp/terraform-plugin-framework/types"
)

func init() {
	RegisterResource(NewContainerAppEnvironmentResource)
}

const (
	caeAPIVersion         = "2024-03-01"
	caeFallbackAPIVersion = "2023-05-01"
)

var (
	_ resource.Resource                = (*containerAppEnvironmentResource)(nil)
	_ resource.ResourceWithImportState = (*containerAppEnvironmentResource)(nil)
)

func NewContainerAppEnvironmentResource() resource.Resource {
	return &containerAppEnvironmentResource{}
}

type containerAppEnvironmentResource struct {
	client *Client
}

type workloadProfileModel struct {
	Name                types.String `tfsdk:"name"`
	WorkloadProfileType types.String `tfsdk:"workload_profile_type"`
	MinimumCount        types.Int64  `tfsdk:"minimum_count"`
	MaximumCount        types.Int64  `tfsdk:"maximum_count"`
}

type containerAppEnvironmentModel struct {
	ID                                      types.String           `tfsdk:"id"`
	Name                                    types.String           `tfsdk:"name"`
	ResourceGroupName                       types.String           `tfsdk:"resource_group_name"`
	Location                                types.String           `tfsdk:"location"`
	LogAnalyticsWorkspaceID                 types.String           `tfsdk:"log_analytics_workspace_id"`
	LogsDestination                         types.String           `tfsdk:"logs_destination"`
	ZoneRedundancyEnabled                   types.Bool             `tfsdk:"zone_redundancy_enabled"`
	InternalLoadBalancerEnabled             types.Bool             `tfsdk:"internal_load_balancer_enabled"`
	InfrastructureSubnetID                  types.String           `tfsdk:"infrastructure_subnet_id"`
	InfrastructureResourceGroupName         types.String           `tfsdk:"infrastructure_resource_group_name"`
	DaprApplicationInsightsConnectionString types.String           `tfsdk:"dapr_application_insights_connection_string"`
	MutualTLSEnabled                        types.Bool             `tfsdk:"mutual_tls_enabled"`
	Tags                                    types.Map              `tfsdk:"tags"`
	DefaultDomain                           types.String           `tfsdk:"default_domain"`
	StaticIPAddress                         types.String           `tfsdk:"static_ip_address"`
	DockerBridgeCidr                        types.String           `tfsdk:"docker_bridge_cidr"`
	PlatformReservedCidr                    types.String           `tfsdk:"platform_reserved_cidr"`
	PlatformReservedDnsIPAddress            types.String           `tfsdk:"platform_reserved_dns_ip_address"`
	CustomDomainVerificationID              types.String           `tfsdk:"custom_domain_verification_id"`
	WorkloadProfile                         []workloadProfileModel `tfsdk:"workload_profile"`
}

func (r *containerAppEnvironmentResource) Metadata(ctx context.Context, req resource.MetadataRequest, resp *resource.MetadataResponse) {
	resp.TypeName = req.ProviderTypeName + "_container_app_environment"
}

func (r *containerAppEnvironmentResource) Schema(ctx context.Context, req resource.SchemaRequest, resp *resource.SchemaResponse) {
	resp.Schema = schema.Schema{
		Description:         "Manages a Container App Environment on the smalt ARM plane (azurerm_container_app_environment parity).",
		MarkdownDescription: "Manages a Container App Environment on the smalt ARM plane (`azurerm_container_app_environment` parity).",
		Attributes: map[string]schema.Attribute{
			"id": schema.StringAttribute{
				Computed: true,
				PlanModifiers: []planmodifier.String{
					stringplanmodifier.UseStateForUnknown(),
				},
			},
			"name": schema.StringAttribute{
				Required: true,
				PlanModifiers: []planmodifier.String{
					stringplanmodifier.RequiresReplace(),
				},
			},
			"resource_group_name": schema.StringAttribute{
				Required: true,
				PlanModifiers: []planmodifier.String{
					stringplanmodifier.RequiresReplace(),
				},
			},
			"location": schema.StringAttribute{
				Required: true,
				PlanModifiers: []planmodifier.String{
					stringplanmodifier.RequiresReplace(),
				},
			},
			"log_analytics_workspace_id": schema.StringAttribute{
				Optional: true,
			},
			"logs_destination": schema.StringAttribute{
				Optional: true,
				Computed: true,
				PlanModifiers: []planmodifier.String{
					stringplanmodifier.UseStateForUnknown(),
				},
			},
			"zone_redundancy_enabled": schema.BoolAttribute{
				Optional: true,
				Computed: true,
				PlanModifiers: []planmodifier.Bool{
					boolplanmodifier.UseStateForUnknown(),
				},
			},
			"internal_load_balancer_enabled": schema.BoolAttribute{
				Optional: true,
				Computed: true,
				PlanModifiers: []planmodifier.Bool{
					boolplanmodifier.UseStateForUnknown(),
				},
			},
			"infrastructure_subnet_id": schema.StringAttribute{
				Optional: true,
			},
			"infrastructure_resource_group_name": schema.StringAttribute{
				Optional: true,
			},
			"dapr_application_insights_connection_string": schema.StringAttribute{
				Optional:  true,
				Sensitive: true,
			},
			"mutual_tls_enabled": schema.BoolAttribute{
				Optional: true,
				Computed: true,
				PlanModifiers: []planmodifier.Bool{
					boolplanmodifier.UseStateForUnknown(),
				},
			},
			"tags": schema.MapAttribute{
				ElementType: types.StringType,
				Optional:    true,
			},
			"default_domain": schema.StringAttribute{
				Computed: true,
				PlanModifiers: []planmodifier.String{
					stringplanmodifier.UseStateForUnknown(),
				},
			},
			"static_ip_address": schema.StringAttribute{
				Computed: true,
				PlanModifiers: []planmodifier.String{
					stringplanmodifier.UseStateForUnknown(),
				},
			},
			"docker_bridge_cidr": schema.StringAttribute{
				Computed: true,
				PlanModifiers: []planmodifier.String{
					stringplanmodifier.UseStateForUnknown(),
				},
			},
			"platform_reserved_cidr": schema.StringAttribute{
				Computed: true,
				PlanModifiers: []planmodifier.String{
					stringplanmodifier.UseStateForUnknown(),
				},
			},
			"platform_reserved_dns_ip_address": schema.StringAttribute{
				Computed: true,
				PlanModifiers: []planmodifier.String{
					stringplanmodifier.UseStateForUnknown(),
				},
			},
			"custom_domain_verification_id": schema.StringAttribute{
				Computed: true,
				PlanModifiers: []planmodifier.String{
					stringplanmodifier.UseStateForUnknown(),
				},
			},
		},
		Blocks: map[string]schema.Block{
			"workload_profile": schema.ListNestedBlock{
				NestedObject: schema.NestedBlockObject{
					Attributes: map[string]schema.Attribute{
						"name": schema.StringAttribute{
							Required: true,
						},
						"workload_profile_type": schema.StringAttribute{
							Required: true,
						},
						"minimum_count": schema.Int64Attribute{
							Optional: true,
							Computed: true,
							PlanModifiers: []planmodifier.Int64{
								int64planmodifier.UseStateForUnknown(),
							},
						},
						"maximum_count": schema.Int64Attribute{
							Optional: true,
							Computed: true,
							PlanModifiers: []planmodifier.Int64{
								int64planmodifier.UseStateForUnknown(),
							},
						},
					},
				},
			},
		},
	}
}

func (r *containerAppEnvironmentResource) Configure(ctx context.Context, req resource.ConfigureRequest, resp *resource.ConfigureResponse) {
	if req.ProviderData == nil {
		return
	}
	client, ok := req.ProviderData.(*Client)
	if !ok {
		resp.Diagnostics.AddError("client cast", "expected *Client")
		return
	}
	r.client = client
}

func caeARMPath(subscriptionID, rg, name string) string {
	return NormalizeARMID(fmt.Sprintf("/subscriptions/%s/resourceGroups/%s/providers/Microsoft.App/managedEnvironments/%s", subscriptionID, rg, name))
}

func (r *containerAppEnvironmentResource) putCAE(ctx context.Context, armPath, ifMatch string, body any, out *map[string]any) ([]byte, string, int, error) {
	raw, etag, status, err := r.client.PutWithETag(ctx, armPath, caeAPIVersion, ifMatch, body, out)
	if err != nil && isInvalidAPIVersionError(err) {
		raw, etag, status, err = r.client.PutWithETag(ctx, armPath, caeFallbackAPIVersion, ifMatch, body, out)
	}
	return raw, etag, status, err
}

func (r *containerAppEnvironmentResource) getCAE(ctx context.Context, armPath string, out *map[string]any) ([]byte, string, int, error) {
	raw, etag, status, err := r.client.GetRaw(ctx, armPath, caeAPIVersion, out)
	if err != nil && isInvalidAPIVersionError(err) {
		raw, etag, status, err = r.client.GetRaw(ctx, armPath, caeFallbackAPIVersion, out)
	}
	return raw, etag, status, err
}

func (r *containerAppEnvironmentResource) deleteCAE(ctx context.Context, armPath string) (int, error) {
	status, err := r.client.DeleteRaw(ctx, armPath, caeAPIVersion)
	if err != nil && isInvalidAPIVersionError(err) {
		status, err = r.client.DeleteRaw(ctx, armPath, caeFallbackAPIVersion)
	}
	return status, err
}

func (r *containerAppEnvironmentResource) Create(ctx context.Context, req resource.CreateRequest, resp *resource.CreateResponse) {
	var plan containerAppEnvironmentModel
	resp.Diagnostics.Append(req.Plan.Get(ctx, &plan)...)
	if resp.Diagnostics.HasError() {
		return
	}

	tags := map[string]string{}
	if !plan.Tags.IsNull() && !plan.Tags.IsUnknown() {
		resp.Diagnostics.Append(plan.Tags.ElementsAs(ctx, &tags, false)...)
		if resp.Diagnostics.HasError() {
			return
		}
	}

	r.applyDefaults(&plan)
	loc := NormalizeLocation(plan.Location.ValueString())
	armPath := caeARMPath(r.client.subscriptionID, plan.ResourceGroupName.ValueString(), plan.Name.ValueString())

	body := map[string]any{
		"location":   loc,
		"properties": r.buildProperties(&plan, nil),
	}
	if len(tags) > 0 {
		body["tags"] = tags
	}

	var out map[string]any
	raw, etag, _, err := r.putCAE(ctx, armPath, "", body, &out)
	if err != nil {
		resp.Diagnostics.AddError("create azurerm_container_app_environment", err.Error())
		return
	}
	SavePrivateARMState(ctx, resp.Private, raw, etag)

	r.applyResponseToModel(ctx, &resp.Diagnostics, &plan, out, armPath, loc, tags)
	resp.Diagnostics.Append(resp.State.Set(ctx, &plan)...)
}

func (r *containerAppEnvironmentResource) Read(ctx context.Context, req resource.ReadRequest, resp *resource.ReadResponse) {
	var state containerAppEnvironmentModel
	resp.Diagnostics.Append(req.State.Get(ctx, &state)...)
	if resp.Diagnostics.HasError() {
		return
	}

	armPath := state.ID.ValueString()
	if armPath == "" {
		armPath = caeARMPath(r.client.subscriptionID, state.ResourceGroupName.ValueString(), state.Name.ValueString())
	} else {
		armPath = NormalizeARMID(armPath)
	}

	var out map[string]any
	raw, etag, status, err := r.getCAE(ctx, armPath, &out)
	if err != nil {
		if status == http.StatusNotFound || IsNotFound(err) {
			resp.State.RemoveResource(ctx)
			return
		}
		resp.Diagnostics.AddError("read azurerm_container_app_environment", err.Error())
		return
	}
	SavePrivateARMState(ctx, resp.Private, raw, etag)

	priorTags := map[string]string{}
	if !state.Tags.IsNull() && !state.Tags.IsUnknown() {
		state.Tags.ElementsAs(ctx, &priorTags, false)
	}
	remoteTags := mapTagsField(out)
	mergedTags := mergeTags(priorTags, remoteTags)
	if state.Tags.IsNull() && len(remoteTags) == 0 {
		mergedTags = nil
	}

	r.applyDefaults(&state)
	loc := NormalizeLocation(mapStringField(out, "location"))
	if loc == "" {
		loc = NormalizeLocation(state.Location.ValueString())
	}
	r.applyResponseToModel(ctx, &resp.Diagnostics, &state, out, armPath, loc, mergedTags)
	resp.Diagnostics.Append(resp.State.Set(ctx, &state)...)
}

func (r *containerAppEnvironmentResource) Update(ctx context.Context, req resource.UpdateRequest, resp *resource.UpdateResponse) {
	var plan containerAppEnvironmentModel
	resp.Diagnostics.Append(req.Plan.Get(ctx, &plan)...)
	if resp.Diagnostics.HasError() {
		return
	}

	tags := map[string]string{}
	if !plan.Tags.IsNull() && !plan.Tags.IsUnknown() {
		resp.Diagnostics.Append(plan.Tags.ElementsAs(ctx, &tags, false)...)
		if resp.Diagnostics.HasError() {
			return
		}
	}

	rawMap, etag := LoadPrivateARMState(ctx, req.Private)
	if rawMap == nil {
		rawMap = map[string]any{}
	}
	existingProps, _ := rawMap["properties"].(map[string]any)

	r.applyDefaults(&plan)
	loc := NormalizeLocation(plan.Location.ValueString())
	armPath := caeARMPath(r.client.subscriptionID, plan.ResourceGroupName.ValueString(), plan.Name.ValueString())

	rawMap["location"] = loc
	rawMap["properties"] = r.buildProperties(&plan, existingProps)
	if len(tags) > 0 {
		rawMap["tags"] = tags
	} else {
		delete(rawMap, "tags")
	}

	var out map[string]any
	raw, newETag, _, err := r.putCAE(ctx, armPath, etag, rawMap, &out)
	if err != nil {
		resp.Diagnostics.AddError("update azurerm_container_app_environment", err.Error())
		return
	}
	SavePrivateARMState(ctx, resp.Private, raw, newETag)

	r.applyResponseToModel(ctx, &resp.Diagnostics, &plan, out, armPath, loc, tags)
	resp.Diagnostics.Append(resp.State.Set(ctx, &plan)...)
}

func (r *containerAppEnvironmentResource) Delete(ctx context.Context, req resource.DeleteRequest, resp *resource.DeleteResponse) {
	var state containerAppEnvironmentModel
	resp.Diagnostics.Append(req.State.Get(ctx, &state)...)
	if resp.Diagnostics.HasError() {
		return
	}

	armPath := state.ID.ValueString()
	if armPath == "" {
		armPath = caeARMPath(r.client.subscriptionID, state.ResourceGroupName.ValueString(), state.Name.ValueString())
	} else {
		armPath = NormalizeARMID(armPath)
	}
	status, err := r.deleteCAE(ctx, armPath)
	if err != nil && status != http.StatusNotFound && !IsNotFound(err) {
		resp.Diagnostics.AddError("delete azurerm_container_app_environment", err.Error())
	}
}

func (r *containerAppEnvironmentResource) ImportState(ctx context.Context, req resource.ImportStateRequest, resp *resource.ImportStateResponse) {
	id := NormalizeARMID(req.ID)
	resp.Diagnostics.Append(resp.State.SetAttribute(ctx, path.Root("id"), id)...)
	if rg := extractResourceGroupFromID(id); rg != "" {
		resp.Diagnostics.Append(resp.State.SetAttribute(ctx, path.Root("resource_group_name"), rg)...)
	}
	parts := strings.Split(id, "/")
	if len(parts) > 0 {
		resp.Diagnostics.Append(resp.State.SetAttribute(ctx, path.Root("name"), parts[len(parts)-1])...)
	}
}

func (r *containerAppEnvironmentResource) applyDefaults(m *containerAppEnvironmentModel) {
	if m.ZoneRedundancyEnabled.IsNull() || m.ZoneRedundancyEnabled.IsUnknown() {
		m.ZoneRedundancyEnabled = types.BoolValue(false)
	}
	if m.InternalLoadBalancerEnabled.IsNull() || m.InternalLoadBalancerEnabled.IsUnknown() {
		m.InternalLoadBalancerEnabled = types.BoolValue(false)
	}
	if m.MutualTLSEnabled.IsNull() || m.MutualTLSEnabled.IsUnknown() {
		m.MutualTLSEnabled = types.BoolValue(false)
	}
	if m.LogsDestination.IsNull() || m.LogsDestination.IsUnknown() {
		if !m.LogAnalyticsWorkspaceID.IsNull() && !m.LogAnalyticsWorkspaceID.IsUnknown() && m.LogAnalyticsWorkspaceID.ValueString() != "" {
			m.LogsDestination = types.StringValue("log-analytics")
		} else {
			m.LogsDestination = types.StringNull()
		}
	}
	for i := range m.WorkloadProfile {
		if m.WorkloadProfile[i].MinimumCount.IsNull() || m.WorkloadProfile[i].MinimumCount.IsUnknown() {
			m.WorkloadProfile[i].MinimumCount = types.Int64Value(0)
		}
		if m.WorkloadProfile[i].MaximumCount.IsNull() || m.WorkloadProfile[i].MaximumCount.IsUnknown() {
			m.WorkloadProfile[i].MaximumCount = types.Int64Value(0)
		}
	}
}

func (r *containerAppEnvironmentResource) buildProperties(m *containerAppEnvironmentModel, existing map[string]any) map[string]any {
	props := map[string]any{}
	for k, v := range existing {
		props[k] = v
	}
	props["zoneRedundant"] = m.ZoneRedundancyEnabled.ValueBool()

	dest := m.LogsDestination.ValueString()
	lawID := m.LogAnalyticsWorkspaceID.ValueString()
	if dest != "" || lawID != "" {
		if dest == "" {
			dest = "log-analytics"
		}
		appLogs := map[string]any{
			"destination": dest,
		}
		if lawID != "" {
			appLogs["logAnalyticsConfiguration"] = map[string]any{
				"customerId": lawID,
			}
		}
		props["appLogsConfiguration"] = appLogs
	}

	if len(m.WorkloadProfile) > 0 {
		profiles := make([]map[string]any, 0, len(m.WorkloadProfile))
		for _, wp := range m.WorkloadProfile {
			entry := map[string]any{
				"name":                wp.Name.ValueString(),
				"workloadProfileType": wp.WorkloadProfileType.ValueString(),
				"minimumCount":        wp.MinimumCount.ValueInt64(),
				"maximumCount":        wp.MaximumCount.ValueInt64(),
			}
			profiles = append(profiles, entry)
		}
		props["workloadProfiles"] = profiles
	}

	if !m.InfrastructureSubnetID.IsNull() && !m.InfrastructureSubnetID.IsUnknown() && m.InfrastructureSubnetID.ValueString() != "" {
		props["vnetConfiguration"] = map[string]any{
			"infrastructureSubnetId": m.InfrastructureSubnetID.ValueString(),
			"internal":               m.InternalLoadBalancerEnabled.ValueBool(),
		}
	}

	return props
}

func (r *containerAppEnvironmentResource) applyResponseToModel(ctx context.Context, diags *diag.Diagnostics, m *containerAppEnvironmentModel, out map[string]any, armPath, loc string, tags map[string]string) {
	id := mapStringField(out, "id")
	if id == "" {
		id = armPath
	}
	m.ID = types.StringValue(NormalizeARMID(id))

	if m.Location.IsNull() || m.Location.IsUnknown() || m.Location.ValueString() == "" {
		if loc != "" {
			m.Location = types.StringValue(NormalizeLocation(loc))
		}
	} else if loc != "" && NormalizeLocation(m.Location.ValueString()) != NormalizeLocation(loc) {
		m.Location = types.StringValue(NormalizeLocation(loc))
	}

	props, _ := out["properties"].(map[string]any)
	defaultDomain := mapStringField(props, "defaultDomain")
	if defaultDomain == "" {
		defaultDomain = fmt.Sprintf("%s.%s.azurecontainerapps.io", m.Name.ValueString(), m.Location.ValueString())
	}
	staticIP := mapStringField(props, "staticIp")
	if staticIP == "" {
		staticIP = "10.0.0.100"
	}
	customDomainID := mapStringField(props, "customDomainVerificationId")
	if customDomainID == "" {
		customDomainID = "smalt-cae-verification-id"
	}

	m.DefaultDomain = types.StringValue(defaultDomain)
	m.StaticIPAddress = types.StringValue(staticIP)
	m.DockerBridgeCidr = types.StringValue("10.2.0.1/16")
	m.PlatformReservedCidr = types.StringValue("10.1.0.0/16")
	m.PlatformReservedDnsIPAddress = types.StringValue("10.1.0.2")
	m.CustomDomainVerificationID = types.StringValue(customDomainID)

	if v, ok := mapBoolField(props, "zoneRedundant"); ok {
		m.ZoneRedundancyEnabled = types.BoolValue(v)
	}
	if appLogs, ok := props["appLogsConfiguration"].(map[string]any); ok {
		if dest := mapStringField(appLogs, "destination"); dest != "" {
			m.LogsDestination = types.StringValue(dest)
		}
	}
	if len(m.WorkloadProfile) == 0 {
		if rawProfiles, ok := props["workloadProfiles"].([]any); ok && len(rawProfiles) > 0 {
			profiles := make([]workloadProfileModel, 0, len(rawProfiles))
			for _, item := range rawProfiles {
				pm, ok := item.(map[string]any)
				if !ok {
					continue
				}
				minC := int64(0)
				if v, ok := pm["minimumCount"].(float64); ok {
					minC = int64(v)
				}
				maxC := int64(0)
				if v, ok := pm["maximumCount"].(float64); ok {
					maxC = int64(v)
				}
				profiles = append(profiles, workloadProfileModel{
					Name:                types.StringValue(mapStringField(pm, "name")),
					WorkloadProfileType: types.StringValue(mapStringField(pm, "workloadProfileType")),
					MinimumCount:        types.Int64Value(minC),
					MaximumCount:        types.Int64Value(maxC),
				})
			}
			m.WorkloadProfile = profiles
		}
	}

	m.Tags = tagsValue(ctx, diags, tags)
}
