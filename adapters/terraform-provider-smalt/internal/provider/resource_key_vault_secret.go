package provider

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"fmt"
	"net/http"
	"strings"

	"github.com/hashicorp/terraform-plugin-framework/diag"
	"github.com/hashicorp/terraform-plugin-framework/path"
	"github.com/hashicorp/terraform-plugin-framework/resource"
	"github.com/hashicorp/terraform-plugin-framework/resource/schema"
	"github.com/hashicorp/terraform-plugin-framework/resource/schema/planmodifier"
	"github.com/hashicorp/terraform-plugin-framework/resource/schema/stringplanmodifier"
	"github.com/hashicorp/terraform-plugin-framework/types"
)

func init() {
	RegisterResource(NewKeyVaultSecretResource)
}

const keyVaultSecretAPIVersion = "2023-07-01"

var (
	_ resource.Resource                = (*keyVaultSecretResource)(nil)
	_ resource.ResourceWithImportState = (*keyVaultSecretResource)(nil)
)

func NewKeyVaultSecretResource() resource.Resource {
	return &keyVaultSecretResource{}
}

type keyVaultSecretResource struct {
	client *Client
}

type keyVaultSecretModel struct {
	ID                    types.String `tfsdk:"id"`
	Name                  types.String `tfsdk:"name"`
	Value                 types.String `tfsdk:"value"`
	KeyVaultID            types.String `tfsdk:"key_vault_id"`
	ContentType           types.String `tfsdk:"content_type"`
	NotBeforeDate         types.String `tfsdk:"not_before_date"`
	ExpirationDate        types.String `tfsdk:"expiration_date"`
	Version               types.String `tfsdk:"version"`
	VersionlessID         types.String `tfsdk:"versionless_id"`
	ResourceID            types.String `tfsdk:"resource_id"`
	ResourceVersionlessID types.String `tfsdk:"resource_versionless_id"`
	Tags                  types.Map    `tfsdk:"tags"`
}

func (r *keyVaultSecretResource) Metadata(ctx context.Context, req resource.MetadataRequest, resp *resource.MetadataResponse) {
	resp.TypeName = req.ProviderTypeName + "_key_vault_secret"
}

func (r *keyVaultSecretResource) Schema(ctx context.Context, req resource.SchemaRequest, resp *resource.SchemaResponse) {
	resp.Schema = schema.Schema{
		Description:         "Manages a Key Vault Secret via ARM control-plane routing (ARD-AZ-02 split-plane parity).",
		MarkdownDescription: "Manages a Key Vault Secret via ARM control-plane routing (`azurerm_key_vault_secret` parity, ARD-AZ-02).",
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
			"value": schema.StringAttribute{
				Required:  true,
				Sensitive: true,
			},
			"key_vault_id": schema.StringAttribute{
				Required: true,
				PlanModifiers: []planmodifier.String{
					stringplanmodifier.RequiresReplace(),
				},
			},
			"content_type": schema.StringAttribute{
				Optional: true,
			},
			"not_before_date": schema.StringAttribute{
				Optional: true,
			},
			"expiration_date": schema.StringAttribute{
				Optional: true,
			},
			"version": schema.StringAttribute{
				Computed: true,
				PlanModifiers: []planmodifier.String{
					stringplanmodifier.UseStateForUnknown(),
				},
			},
			"versionless_id": schema.StringAttribute{
				Computed: true,
				PlanModifiers: []planmodifier.String{
					stringplanmodifier.UseStateForUnknown(),
				},
			},
			"resource_id": schema.StringAttribute{
				Computed: true,
				PlanModifiers: []planmodifier.String{
					stringplanmodifier.UseStateForUnknown(),
				},
			},
			"resource_versionless_id": schema.StringAttribute{
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

func (r *keyVaultSecretResource) Configure(ctx context.Context, req resource.ConfigureRequest, resp *resource.ConfigureResponse) {
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

func parseKeyVaultID(rawKVID, fallbackSub string) (sub, rg, vaultName, normKVID string, err error) {
	norm := NormalizeARMID(rawKVID)
	parts := strings.Split(strings.TrimPrefix(norm, "/"), "/")
	sub = fallbackSub
	for i := 0; i < len(parts)-1; i++ {
		switch strings.ToLower(parts[i]) {
		case "subscriptions":
			sub = parts[i+1]
		case "resourcegroups":
			rg = parts[i+1]
		case "vaults":
			vaultName = parts[i+1]
		}
	}
	if rg == "" || vaultName == "" {
		return "", "", "", "", fmt.Errorf("invalid key_vault_id %q: expected /subscriptions/{sub}/resourceGroups/{rg}/providers/Microsoft.KeyVault/vaults/{vaultName}", rawKVID)
	}
	normKVID = NormalizeARMID(fmt.Sprintf("/subscriptions/%s/resourceGroups/%s/providers/Microsoft.KeyVault/vaults/%s", sub, rg, vaultName))
	return sub, rg, vaultName, normKVID, nil
}

func keyVaultSecretARMPath(sub, rg, vaultName, secretName string) string {
	return NormalizeARMID(fmt.Sprintf("/subscriptions/%s/resourceGroups/%s/providers/Microsoft.KeyVault/vaults/%s/secrets/%s", sub, rg, vaultName, secretName))
}

func deterministicSecretVersion(vaultName, secretName, value string) string {
	sum := sha256.Sum256([]byte(fmt.Sprintf("%s/%s/%s", strings.ToLower(vaultName), secretName, value)))
	return hex.EncodeToString(sum[:16])
}

func (r *keyVaultSecretResource) Create(ctx context.Context, req resource.CreateRequest, resp *resource.CreateResponse) {
	var plan keyVaultSecretModel
	resp.Diagnostics.Append(req.Plan.Get(ctx, &plan)...)
	if resp.Diagnostics.HasError() {
		return
	}

	sub, rg, vaultName, normKVID, err := parseKeyVaultID(plan.KeyVaultID.ValueString(), r.client.subscriptionID)
	if err != nil {
		resp.Diagnostics.AddError("invalid key_vault_id", err.Error())
		return
	}

	tags := map[string]string{}
	if !plan.Tags.IsNull() && !plan.Tags.IsUnknown() {
		resp.Diagnostics.Append(plan.Tags.ElementsAs(ctx, &tags, false)...)
		if resp.Diagnostics.HasError() {
			return
		}
	}

	props := map[string]any{
		"value": plan.Value.ValueString(),
	}
	if !plan.ContentType.IsNull() && !plan.ContentType.IsUnknown() && plan.ContentType.ValueString() != "" {
		props["contentType"] = plan.ContentType.ValueString()
	}

	body := map[string]any{
		"location":   "eastus",
		"properties": props,
	}
	if len(tags) > 0 {
		body["tags"] = tags
	}

	armPath := keyVaultSecretARMPath(sub, rg, vaultName, plan.Name.ValueString())
	var out map[string]any
	raw, etag, _, err := r.client.PutWithETag(ctx, armPath, keyVaultSecretAPIVersion, "", body, &out)
	if err != nil {
		resp.Diagnostics.AddError("create azurerm_key_vault_secret", err.Error())
		return
	}
	SavePrivateARMState(ctx, resp.Private, raw, etag)

	r.populateSecretState(ctx, &resp.Diagnostics, &plan, out, vaultName, normKVID, "", tags, false)
	resp.Diagnostics.Append(resp.State.Set(ctx, &plan)...)
}

func (r *keyVaultSecretResource) Read(ctx context.Context, req resource.ReadRequest, resp *resource.ReadResponse) {
	var state keyVaultSecretModel
	resp.Diagnostics.Append(req.State.Get(ctx, &state)...)
	if resp.Diagnostics.HasError() {
		return
	}

	sub, rg, vaultName, normKVID, err := parseKeyVaultID(state.KeyVaultID.ValueString(), r.client.subscriptionID)
	if err != nil {
		resp.Diagnostics.AddError("invalid key_vault_id", err.Error())
		return
	}

	armPath := keyVaultSecretARMPath(sub, rg, vaultName, state.Name.ValueString())
	var out map[string]any
	raw, etag, status, err := r.client.GetRaw(ctx, armPath, keyVaultSecretAPIVersion, &out)
	if err != nil {
		if status == http.StatusNotFound || IsNotFound(err) {
			resp.State.RemoveResource(ctx)
			return
		}
		resp.Diagnostics.AddError("read azurerm_key_vault_secret", err.Error())
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

	priorVersion := state.Version.ValueString()
	r.populateSecretState(ctx, &resp.Diagnostics, &state, out, vaultName, normKVID, priorVersion, mergedTags, true)
	resp.Diagnostics.Append(resp.State.Set(ctx, &state)...)
}

func (r *keyVaultSecretResource) Update(ctx context.Context, req resource.UpdateRequest, resp *resource.UpdateResponse) {
	var plan keyVaultSecretModel
	resp.Diagnostics.Append(req.Plan.Get(ctx, &plan)...)
	if resp.Diagnostics.HasError() {
		return
	}

	sub, rg, vaultName, normKVID, err := parseKeyVaultID(plan.KeyVaultID.ValueString(), r.client.subscriptionID)
	if err != nil {
		resp.Diagnostics.AddError("invalid key_vault_id", err.Error())
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
	if _, ok := rawMap["location"]; !ok {
		rawMap["location"] = "eastus"
	}
	props, _ := rawMap["properties"].(map[string]any)
	if props == nil {
		props = map[string]any{}
	}
	props["value"] = plan.Value.ValueString()
	if !plan.ContentType.IsNull() && !plan.ContentType.IsUnknown() && plan.ContentType.ValueString() != "" {
		props["contentType"] = plan.ContentType.ValueString()
	} else {
		delete(props, "contentType")
	}
	// Clear cached version in request properties so server or deterministic fallback computes fresh version on value change.
	delete(props, "version")
	rawMap["properties"] = props
	if len(tags) > 0 {
		rawMap["tags"] = tags
	} else {
		delete(rawMap, "tags")
	}

	armPath := keyVaultSecretARMPath(sub, rg, vaultName, plan.Name.ValueString())
	var out map[string]any
	raw, newETag, _, err := r.client.PutWithETag(ctx, armPath, keyVaultSecretAPIVersion, etag, rawMap, &out)
	if err != nil {
		resp.Diagnostics.AddError("update azurerm_key_vault_secret", err.Error())
		return
	}
	SavePrivateARMState(ctx, resp.Private, raw, newETag)

	r.populateSecretState(ctx, &resp.Diagnostics, &plan, out, vaultName, normKVID, "", tags, false)
	resp.Diagnostics.Append(resp.State.Set(ctx, &plan)...)
}

func (r *keyVaultSecretResource) Delete(ctx context.Context, req resource.DeleteRequest, resp *resource.DeleteResponse) {
	var state keyVaultSecretModel
	resp.Diagnostics.Append(req.State.Get(ctx, &state)...)
	if resp.Diagnostics.HasError() {
		return
	}

	sub, rg, vaultName, _, err := parseKeyVaultID(state.KeyVaultID.ValueString(), r.client.subscriptionID)
	if err != nil {
		resp.Diagnostics.AddError("invalid key_vault_id", err.Error())
		return
	}
	armPath := keyVaultSecretARMPath(sub, rg, vaultName, state.Name.ValueString())
	status, err := r.client.DeleteRaw(ctx, armPath, keyVaultSecretAPIVersion)
	if err != nil && status != http.StatusNotFound && !IsNotFound(err) {
		resp.Diagnostics.AddError("delete azurerm_key_vault_secret", err.Error())
	}
}

func (r *keyVaultSecretResource) ImportState(ctx context.Context, req resource.ImportStateRequest, resp *resource.ImportStateResponse) {
	id := NormalizeARMID(req.ID)
	if !requireImportSegment(&resp.Diagnostics, id, "/secrets/", "azurerm_key_vault_secret") {
		return
	}
	resp.Diagnostics.Append(resp.State.SetAttribute(ctx, path.Root("id"), id)...)
	parts := strings.Split(strings.TrimPrefix(id, "/"), "/")
	if len(parts) >= 2 {
		resp.Diagnostics.Append(resp.State.SetAttribute(ctx, path.Root("name"), parts[len(parts)-1])...)
	}
	for i := 0; i < len(parts)-1; i++ {
		if strings.EqualFold(parts[i], "vaults") {
			kvID := "/" + strings.Join(parts[:i+2], "/")
			resp.Diagnostics.Append(resp.State.SetAttribute(ctx, path.Root("key_vault_id"), NormalizeARMID(kvID))...)
			break
		}
	}
}

func (r *keyVaultSecretResource) populateSecretState(
	ctx context.Context,
	diags *diag.Diagnostics,
	m *keyVaultSecretModel,
	out map[string]any,
	vaultName, normKVID, priorVersion string,
	tags map[string]string,
	isRead bool,
) {
	secretName := m.Name.ValueString()
	props, _ := out["properties"].(map[string]any)

	// On Read: if Smalt ARM GET omits properties.value, preserve prior state value so terraform plan has zero drift.
	if remoteVal, ok := props["value"].(string); ok && remoteVal != "" {
		m.Value = types.StringValue(remoteVal)
	}
	if remoteCT, ok := props["contentType"].(string); ok && remoteCT != "" {
		m.ContentType = types.StringValue(remoteCT)
	} else if !isRead && (m.ContentType.IsNull() || m.ContentType.IsUnknown()) {
		m.ContentType = types.StringNull()
	}

	version := mapStringField(props, "version")
	if version == "" {
		version = mapStringField(out, "version")
	}
	if version == "" && isRead && priorVersion != "" {
		version = priorVersion
	}
	if version == "" {
		version = deterministicSecretVersion(vaultName, secretName, m.Value.ValueString())
	}

	versionlessID := fmt.Sprintf("https://%s.vault.azure.net/secrets/%s", strings.ToLower(vaultName), secretName)
	fullID := fmt.Sprintf("%s/%s", versionlessID, version)
	resourceVersionlessID := NormalizeARMID(fmt.Sprintf("%s/secrets/%s", normKVID, secretName))
	resourceID := fmt.Sprintf("%s/versions/%s", resourceVersionlessID, version)

	m.Version = types.StringValue(version)
	m.VersionlessID = types.StringValue(versionlessID)
	m.ID = types.StringValue(fullID)
	m.ResourceVersionlessID = types.StringValue(resourceVersionlessID)
	m.ResourceID = types.StringValue(resourceID)
	m.Tags = tagsValue(ctx, diags, tags)
}
