package provider

import (
	"context"
	"errors"
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
	RegisterResource(NewKeyVaultResource)
}

const (
	keyVaultAPIVersion         = "2023-07-01"
	keyVaultFallbackAPIVersion = "2023-02-01"
)

var (
	_ resource.Resource                = (*keyVaultResource)(nil)
	_ resource.ResourceWithImportState = (*keyVaultResource)(nil)
)

func NewKeyVaultResource() resource.Resource {
	return &keyVaultResource{}
}

type keyVaultResource struct {
	client *Client
}

type keyVaultModel struct {
	ID                           types.String `tfsdk:"id"`
	Name                         types.String `tfsdk:"name"`
	ResourceGroupName            types.String `tfsdk:"resource_group_name"`
	Location                     types.String `tfsdk:"location"`
	TenantID                     types.String `tfsdk:"tenant_id"`
	SkuName                      types.String `tfsdk:"sku_name"`
	PurgeProtectionEnabled       types.Bool   `tfsdk:"purge_protection_enabled"`
	SoftDeleteRetentionDays      types.Int64  `tfsdk:"soft_delete_retention_days"`
	EnableRbacAuthorization      types.Bool   `tfsdk:"enable_rbac_authorization"`
	RbacAuthorizationEnabled     types.Bool   `tfsdk:"rbac_authorization_enabled"`
	PublicNetworkAccessEnabled   types.Bool   `tfsdk:"public_network_access_enabled"`
	EnabledForDeployment         types.Bool   `tfsdk:"enabled_for_deployment"`
	EnabledForDiskEncryption     types.Bool   `tfsdk:"enabled_for_disk_encryption"`
	EnabledForTemplateDeployment types.Bool   `tfsdk:"enabled_for_template_deployment"`
	VaultURI                     types.String `tfsdk:"vault_uri"`
	Tags                         types.Map    `tfsdk:"tags"`
}

func (r *keyVaultResource) Metadata(ctx context.Context, req resource.MetadataRequest, resp *resource.MetadataResponse) {
	resp.TypeName = req.ProviderTypeName + "_key_vault"
}

func (r *keyVaultResource) Schema(ctx context.Context, req resource.SchemaRequest, resp *resource.SchemaResponse) {
	resp.Schema = schema.Schema{
		Description:         "Manages an Azure Key Vault on the smalt ARM plane (azurerm_key_vault parity).",
		MarkdownDescription: "Manages an Azure Key Vault on the smalt ARM plane (`azurerm_key_vault` parity).",
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
			"tenant_id": schema.StringAttribute{
				Required: true,
			},
			"sku_name": schema.StringAttribute{
				Required: true,
			},
			"purge_protection_enabled": schema.BoolAttribute{
				Optional: true,
				Computed: true,
				PlanModifiers: []planmodifier.Bool{
					boolplanmodifier.UseStateForUnknown(),
				},
			},
			"soft_delete_retention_days": schema.Int64Attribute{
				Optional: true,
				Computed: true,
				PlanModifiers: []planmodifier.Int64{
					int64planmodifier.UseStateForUnknown(),
				},
			},
			"enable_rbac_authorization": schema.BoolAttribute{
				Optional: true,
				Computed: true,
				PlanModifiers: []planmodifier.Bool{
					boolplanmodifier.UseStateForUnknown(),
				},
			},
			"rbac_authorization_enabled": schema.BoolAttribute{
				Optional: true,
				Computed: true,
				PlanModifiers: []planmodifier.Bool{
					boolplanmodifier.UseStateForUnknown(),
				},
			},
			"public_network_access_enabled": schema.BoolAttribute{
				Optional: true,
				Computed: true,
				PlanModifiers: []planmodifier.Bool{
					boolplanmodifier.UseStateForUnknown(),
				},
			},
			"enabled_for_deployment": schema.BoolAttribute{
				Optional: true,
				Computed: true,
				PlanModifiers: []planmodifier.Bool{
					boolplanmodifier.UseStateForUnknown(),
				},
			},
			"enabled_for_disk_encryption": schema.BoolAttribute{
				Optional: true,
				Computed: true,
				PlanModifiers: []planmodifier.Bool{
					boolplanmodifier.UseStateForUnknown(),
				},
			},
			"enabled_for_template_deployment": schema.BoolAttribute{
				Optional: true,
				Computed: true,
				PlanModifiers: []planmodifier.Bool{
					boolplanmodifier.UseStateForUnknown(),
				},
			},
			"vault_uri": schema.StringAttribute{
				Computed: true,
				PlanModifiers: []planmodifier.String{
					stringplanmodifier.UseStateForUnknown(),
				},
			},
			"tags": schema.MapAttribute{
				ElementType: types.StringType,
				Optional:    true,
			},
		},
	}
}

func (r *keyVaultResource) Configure(ctx context.Context, req resource.ConfigureRequest, resp *resource.ConfigureResponse) {
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

func keyVaultARMPath(subscriptionID, rg, name string) string {
	return NormalizeARMID(fmt.Sprintf("/subscriptions/%s/resourceGroups/%s/providers/Microsoft.KeyVault/vaults/%s", subscriptionID, rg, name))
}

func isInvalidAPIVersionError(err error) bool {
	var apiErr *ApiError
	if errors.As(err, &apiErr) {
		return apiErr.Status == http.StatusBadRequest && strings.Contains(apiErr.Body, "InvalidApiVersionParameter")
	}
	return false
}

func (r *keyVaultResource) putKeyVault(ctx context.Context, armPath, ifMatch string, body any, out *map[string]any) ([]byte, string, int, error) {
	raw, etag, status, err := r.client.PutWithETag(ctx, armPath, keyVaultAPIVersion, ifMatch, body, out)
	if err != nil && isInvalidAPIVersionError(err) {
		raw, etag, status, err = r.client.PutWithETag(ctx, armPath, keyVaultFallbackAPIVersion, ifMatch, body, out)
	}
	if err != nil {
		return nil, "", status, err
	}
	// If PUT returned a 202 LRO operation envelope without properties, read the persisted vault record.
	if status == http.StatusAccepted || (*out != nil && (*out)["properties"] == nil && strings.Contains(mapStringField(*out, "id"), "/operations/")) {
		var getOut map[string]any
		if getRaw, getETag, _, getErr := r.getKeyVault(ctx, armPath, &getOut); getErr == nil && getOut != nil {
			*out = getOut
			raw = getRaw
			if getETag != "" {
				etag = getETag
			}
		}
	}
	return raw, etag, status, nil
}

func (r *keyVaultResource) getKeyVault(ctx context.Context, armPath string, out *map[string]any) ([]byte, string, int, error) {
	raw, etag, status, err := r.client.GetRaw(ctx, armPath, keyVaultAPIVersion, out)
	if err != nil && isInvalidAPIVersionError(err) {
		raw, etag, status, err = r.client.GetRaw(ctx, armPath, keyVaultFallbackAPIVersion, out)
	}
	return raw, etag, status, err
}

func (r *keyVaultResource) deleteKeyVault(ctx context.Context, armPath string) (int, error) {
	status, err := r.client.DeleteRaw(ctx, armPath, keyVaultAPIVersion)
	if err != nil && isInvalidAPIVersionError(err) {
		status, err = r.client.DeleteRaw(ctx, armPath, keyVaultFallbackAPIVersion)
	}
	return status, err
}

func (r *keyVaultResource) Create(ctx context.Context, req resource.CreateRequest, resp *resource.CreateResponse) {
	var plan keyVaultModel
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
	armPath := keyVaultARMPath(r.client.subscriptionID, plan.ResourceGroupName.ValueString(), plan.Name.ValueString())

	body := map[string]any{
		"location":   loc,
		"properties": r.buildProperties(&plan, nil),
	}
	if len(tags) > 0 {
		body["tags"] = tags
	}

	var out map[string]any
	raw, etag, _, err := r.putKeyVault(ctx, armPath, "", body, &out)
	if err != nil {
		resp.Diagnostics.AddError("create azurerm_key_vault", err.Error())
		return
	}
	SavePrivateARMState(ctx, resp.Private, raw, etag)

	r.applyResponseToModel(ctx, &resp.Diagnostics, &plan, out, armPath, loc, tags)
	resp.Diagnostics.Append(resp.State.Set(ctx, &plan)...)
}

func (r *keyVaultResource) Read(ctx context.Context, req resource.ReadRequest, resp *resource.ReadResponse) {
	var state keyVaultModel
	resp.Diagnostics.Append(req.State.Get(ctx, &state)...)
	if resp.Diagnostics.HasError() {
		return
	}

	armPath := state.ID.ValueString()
	if armPath == "" {
		armPath = keyVaultARMPath(r.client.subscriptionID, state.ResourceGroupName.ValueString(), state.Name.ValueString())
	} else {
		armPath = NormalizeARMID(armPath)
	}

	var out map[string]any
	raw, etag, status, err := r.getKeyVault(ctx, armPath, &out)
	if err != nil {
		if status == http.StatusNotFound || IsNotFound(err) {
			resp.State.RemoveResource(ctx)
			return
		}
		resp.Diagnostics.AddError("read azurerm_key_vault", err.Error())
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

func (r *keyVaultResource) Update(ctx context.Context, req resource.UpdateRequest, resp *resource.UpdateResponse) {
	var plan keyVaultModel
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
	armPath := keyVaultARMPath(r.client.subscriptionID, plan.ResourceGroupName.ValueString(), plan.Name.ValueString())

	rawMap["location"] = loc
	rawMap["properties"] = r.buildProperties(&plan, existingProps)
	if len(tags) > 0 {
		rawMap["tags"] = tags
	} else {
		delete(rawMap, "tags")
	}

	var out map[string]any
	raw, newETag, _, err := r.putKeyVault(ctx, armPath, etag, rawMap, &out)
	if err != nil {
		resp.Diagnostics.AddError("update azurerm_key_vault", err.Error())
		return
	}
	SavePrivateARMState(ctx, resp.Private, raw, newETag)

	r.applyResponseToModel(ctx, &resp.Diagnostics, &plan, out, armPath, loc, tags)
	resp.Diagnostics.Append(resp.State.Set(ctx, &plan)...)
}

func (r *keyVaultResource) Delete(ctx context.Context, req resource.DeleteRequest, resp *resource.DeleteResponse) {
	var state keyVaultModel
	resp.Diagnostics.Append(req.State.Get(ctx, &state)...)
	if resp.Diagnostics.HasError() {
		return
	}
	armPath := state.ID.ValueString()
	if armPath == "" {
		armPath = keyVaultARMPath(r.client.subscriptionID, state.ResourceGroupName.ValueString(), state.Name.ValueString())
	} else {
		armPath = NormalizeARMID(armPath)
	}
	status, err := r.deleteKeyVault(ctx, armPath)
	if err != nil && status != http.StatusNotFound && !IsNotFound(err) {
		resp.Diagnostics.AddError("delete azurerm_key_vault", err.Error())
	}
}

func (r *keyVaultResource) ImportState(ctx context.Context, req resource.ImportStateRequest, resp *resource.ImportStateResponse) {
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

func (r *keyVaultResource) applyDefaults(m *keyVaultModel) {
	if m.PurgeProtectionEnabled.IsNull() || m.PurgeProtectionEnabled.IsUnknown() {
		m.PurgeProtectionEnabled = types.BoolValue(false)
	}
	if m.SoftDeleteRetentionDays.IsNull() || m.SoftDeleteRetentionDays.IsUnknown() {
		m.SoftDeleteRetentionDays = types.Int64Value(90)
	}
	rbac := false
	if !m.RbacAuthorizationEnabled.IsNull() && !m.RbacAuthorizationEnabled.IsUnknown() {
		rbac = m.RbacAuthorizationEnabled.ValueBool()
	} else if !m.EnableRbacAuthorization.IsNull() && !m.EnableRbacAuthorization.IsUnknown() {
		rbac = m.EnableRbacAuthorization.ValueBool()
	}
	if m.RbacAuthorizationEnabled.IsNull() || m.RbacAuthorizationEnabled.IsUnknown() {
		m.RbacAuthorizationEnabled = types.BoolValue(rbac)
	}
	if m.EnableRbacAuthorization.IsNull() || m.EnableRbacAuthorization.IsUnknown() {
		m.EnableRbacAuthorization = types.BoolValue(rbac)
	}
	if m.PublicNetworkAccessEnabled.IsNull() || m.PublicNetworkAccessEnabled.IsUnknown() {
		m.PublicNetworkAccessEnabled = types.BoolValue(true)
	}
	if m.EnabledForDeployment.IsNull() || m.EnabledForDeployment.IsUnknown() {
		m.EnabledForDeployment = types.BoolValue(false)
	}
	if m.EnabledForDiskEncryption.IsNull() || m.EnabledForDiskEncryption.IsUnknown() {
		m.EnabledForDiskEncryption = types.BoolValue(false)
	}
	if m.EnabledForTemplateDeployment.IsNull() || m.EnabledForTemplateDeployment.IsUnknown() {
		m.EnabledForTemplateDeployment = types.BoolValue(false)
	}
}

func (r *keyVaultResource) buildProperties(m *keyVaultModel, existing map[string]any) map[string]any {
	props := map[string]any{}
	for k, v := range existing {
		props[k] = v
	}
	rbac := m.RbacAuthorizationEnabled.ValueBool() || m.EnableRbacAuthorization.ValueBool()
	pna := "Enabled"
	if !m.PublicNetworkAccessEnabled.ValueBool() {
		pna = "Disabled"
	}
	props["tenantId"] = m.TenantID.ValueString()
	props["sku"] = map[string]any{
		"family": "A",
		"name":   m.SkuName.ValueString(),
	}
	props["enablePurgeProtection"] = m.PurgeProtectionEnabled.ValueBool()
	props["softDeleteRetentionInDays"] = m.SoftDeleteRetentionDays.ValueInt64()
	props["enableRbacAuthorization"] = rbac
	props["publicNetworkAccess"] = pna
	props["enabledForDeployment"] = m.EnabledForDeployment.ValueBool()
	props["enabledForDiskEncryption"] = m.EnabledForDiskEncryption.ValueBool()
	props["enabledForTemplateDeployment"] = m.EnabledForTemplateDeployment.ValueBool()
	if _, ok := props["accessPolicies"]; !ok {
		props["accessPolicies"] = []any{}
	}
	return props
}

func (r *keyVaultResource) applyResponseToModel(ctx context.Context, diags *diag.Diagnostics, m *keyVaultModel, out map[string]any, armPath, loc string, tags map[string]string) {
	id := mapStringField(out, "id")
	if id == "" || strings.Contains(id, "/operations/") {
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
	if tid := mapStringField(props, "tenantId"); tid != "" && (m.TenantID.IsNull() || m.TenantID.IsUnknown() || m.TenantID.ValueString() == "") {
		m.TenantID = types.StringValue(tid)
	}
	if skuMap, ok := props["sku"].(map[string]any); ok {
		if sn := mapStringField(skuMap, "name"); sn != "" && (m.SkuName.IsNull() || m.SkuName.IsUnknown() || m.SkuName.ValueString() == "") {
			m.SkuName = types.StringValue(sn)
		}
	}
	if v, ok := mapBoolField(props, "enablePurgeProtection"); ok {
		m.PurgeProtectionEnabled = types.BoolValue(v)
	}
	if v, ok := props["softDeleteRetentionInDays"].(float64); ok && v > 0 {
		m.SoftDeleteRetentionDays = types.Int64Value(int64(v))
	}
	if v, ok := mapBoolField(props, "enableRbacAuthorization"); ok {
		m.EnableRbacAuthorization = types.BoolValue(v)
		m.RbacAuthorizationEnabled = types.BoolValue(v)
	}
	if pna := mapStringField(props, "publicNetworkAccess"); pna != "" {
		m.PublicNetworkAccessEnabled = types.BoolValue(!strings.EqualFold(pna, "Disabled"))
	}
	if v, ok := mapBoolField(props, "enabledForDeployment"); ok {
		m.EnabledForDeployment = types.BoolValue(v)
	}
	if v, ok := mapBoolField(props, "enabledForDiskEncryption"); ok {
		m.EnabledForDiskEncryption = types.BoolValue(v)
	}
	if v, ok := mapBoolField(props, "enabledForTemplateDeployment"); ok {
		m.EnabledForTemplateDeployment = types.BoolValue(v)
	}

	vaultURI := mapStringField(props, "vaultUri")
	if vaultURI == "" {
		vaultURI = fmt.Sprintf("https://%s.vault.azure.net/", m.Name.ValueString())
	}
	m.VaultURI = types.StringValue(vaultURI)
	m.Tags = tagsValue(ctx, diags, tags)
}
