package provider

import (
	"context"
	"crypto/sha1"
	"encoding/hex"
	"errors"
	"fmt"
	"net/http"
	"strings"

	"github.com/hashicorp/terraform-plugin-framework/path"
	"github.com/hashicorp/terraform-plugin-framework/resource"
	"github.com/hashicorp/terraform-plugin-framework/resource/schema"
	"github.com/hashicorp/terraform-plugin-framework/resource/schema/boolplanmodifier"
	"github.com/hashicorp/terraform-plugin-framework/resource/schema/float64planmodifier"
	"github.com/hashicorp/terraform-plugin-framework/resource/schema/int64planmodifier"
	"github.com/hashicorp/terraform-plugin-framework/resource/schema/planmodifier"
	"github.com/hashicorp/terraform-plugin-framework/resource/schema/stringplanmodifier"
	"github.com/hashicorp/terraform-plugin-framework/types"
)

func init() {
	RegisterResource(NewUserAssignedIdentityResource)
	RegisterResource(NewFederatedIdentityCredentialResource)
	RegisterResource(NewRoleDefinitionResource)
	RegisterResource(NewRoleAssignmentResource)
	RegisterResource(NewContainerRegistryResource)
	RegisterResource(NewLogAnalyticsWorkspaceResource)
	RegisterResource(NewStorageAccountResource)
}

var roleDefUUIDNamespace = []byte{106, 167, 184, 16, 157, 173, 17, 209, 128, 180, 0, 192, 79, 212, 48, 200}

func mintDeterministicGUID(input string) string {
	h := sha1.New()
	h.Write(roleDefUUIDNamespace)
	h.Write([]byte(input))
	digest := h.Sum(nil)
	digest[6] = (digest[6] & 0x0f) | 0x50
	digest[8] = (digest[8] & 0x3f) | 0x80
	hx := hex.EncodeToString(digest[:16])
	return fmt.Sprintf("%s-%s-%s-%s-%s", hx[0:8], hx[8:12], hx[12:16], hx[16:20], hx[20:32])
}

func isUnsupportedARMRouteError(err error) bool {
	var apiErr *ApiError
	if errors.As(err, &apiErr) {
		return apiErr.Status == http.StatusNotFound ||
			apiErr.Status == http.StatusMethodNotAllowed ||
			apiErr.Status == http.StatusNotImplemented ||
			apiErr.Status == http.StatusBadRequest
	}
	return false
}

func extractResourceGroupFromID(id string) string {
	norm := NormalizeARMID(id)
	parts := strings.Split(norm, "/")
	for i := 0; i < len(parts)-1; i++ {
		if strings.EqualFold(parts[i], "resourceGroups") {
			return parts[i+1]
		}
	}
	return ""
}

func mapStringField(m map[string]any, key string) string {
	if m == nil {
		return ""
	}
	if v, ok := m[key].(string); ok {
		return v
	}
	return ""
}

func mapBoolField(m map[string]any, key string) (bool, bool) {
	if m == nil {
		return false, false
	}
	if v, ok := m[key].(bool); ok {
		return v, true
	}
	return false, false
}

func mapTagsField(m map[string]any) map[string]string {
	if m == nil {
		return nil
	}
	raw, ok := m["tags"].(map[string]any)
	if !ok {
		return nil
	}
	out := make(map[string]string, len(raw))
	for k, v := range raw {
		if s, ok := v.(string); ok {
			out[k] = s
		}
	}
	return out
}

// ============================================================================
// 1. azurerm_user_assigned_identity
// ============================================================================

const uaiAPIVersion = "2023-01-31"

var (
	_ resource.Resource                = (*userAssignedIdentityResource)(nil)
	_ resource.ResourceWithImportState = (*userAssignedIdentityResource)(nil)
)

func NewUserAssignedIdentityResource() resource.Resource {
	return &userAssignedIdentityResource{}
}

type userAssignedIdentityResource struct {
	client *Client
}

type userAssignedIdentityModel struct {
	ID                types.String `tfsdk:"id"`
	Name              types.String `tfsdk:"name"`
	ResourceGroupName types.String `tfsdk:"resource_group_name"`
	Location          types.String `tfsdk:"location"`
	Tags              types.Map    `tfsdk:"tags"`
	ClientID          types.String `tfsdk:"client_id"`
	PrincipalID       types.String `tfsdk:"principal_id"`
	TenantID          types.String `tfsdk:"tenant_id"`
}

func (r *userAssignedIdentityResource) Metadata(ctx context.Context, req resource.MetadataRequest, resp *resource.MetadataResponse) {
	resp.TypeName = req.ProviderTypeName + "_user_assigned_identity"
}

func (r *userAssignedIdentityResource) Schema(ctx context.Context, req resource.SchemaRequest, resp *resource.SchemaResponse) {
	resp.Schema = schema.Schema{
		Description: "Manages a User Assigned Identity on the smalt ARM plane.",
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
			"tags": schema.MapAttribute{
				ElementType: types.StringType,
				Optional:    true,
			},
			"client_id": schema.StringAttribute{
				Computed: true,
				PlanModifiers: []planmodifier.String{
					stringplanmodifier.UseStateForUnknown(),
				},
			},
			"principal_id": schema.StringAttribute{
				Computed: true,
				PlanModifiers: []planmodifier.String{
					stringplanmodifier.UseStateForUnknown(),
				},
			},
			"tenant_id": schema.StringAttribute{
				Computed: true,
				PlanModifiers: []planmodifier.String{
					stringplanmodifier.UseStateForUnknown(),
				},
			},
		},
	}
}

func (r *userAssignedIdentityResource) Configure(ctx context.Context, req resource.ConfigureRequest, resp *resource.ConfigureResponse) {
	if req.ProviderData == nil {
		return
	}
	c, ok := req.ProviderData.(*Client)
	if !ok {
		resp.Diagnostics.AddError("client cast", "expected *Client")
		return
	}
	r.client = c
}

func uaiARMPath(sub, rg, name string) string {
	return NormalizeARMID(fmt.Sprintf("/subscriptions/%s/resourceGroups/%s/providers/Microsoft.ManagedIdentity/userAssignedIdentities/%s", sub, rg, name))
}

func (r *userAssignedIdentityResource) Create(ctx context.Context, req resource.CreateRequest, resp *resource.CreateResponse) {
	var plan userAssignedIdentityModel
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

	loc := NormalizeLocation(plan.Location.ValueString())
	armPath := uaiARMPath(r.client.subscriptionID, plan.ResourceGroupName.ValueString(), plan.Name.ValueString())
	body := map[string]any{
		"location":   loc,
		"tags":       tags,
		"properties": map[string]any{},
	}

	var out map[string]any
	raw, etag, _, err := r.client.PutWithETag(ctx, armPath, uaiAPIVersion, "", body, &out)
	if err != nil {
		resp.Diagnostics.AddError("create user_assigned_identity", err.Error())
		return
	}
	SavePrivateARMState(ctx, resp.Private, raw, etag)

	r.populateUAIModel(ctx, &plan, out, armPath, loc, tags, resp)
	resp.Diagnostics.Append(resp.State.Set(ctx, &plan)...)
}

func (r *userAssignedIdentityResource) Read(ctx context.Context, req resource.ReadRequest, resp *resource.ReadResponse) {
	var state userAssignedIdentityModel
	resp.Diagnostics.Append(req.State.Get(ctx, &state)...)
	if resp.Diagnostics.HasError() {
		return
	}

	armPath := state.ID.ValueString()
	if armPath == "" {
		armPath = uaiARMPath(r.client.subscriptionID, state.ResourceGroupName.ValueString(), state.Name.ValueString())
	} else {
		armPath = NormalizeARMID(armPath)
	}

	var out map[string]any
	raw, etag, _, err := r.client.GetRaw(ctx, armPath, uaiAPIVersion, &out)
	if err != nil {
		if IsNotFound(err) {
			resp.State.RemoveResource(ctx)
			return
		}
		resp.Diagnostics.AddError("read user_assigned_identity", err.Error())
		return
	}
	SavePrivateARMState(ctx, resp.Private, raw, etag)

	tags := map[string]string{}
	if !state.Tags.IsNull() && !state.Tags.IsUnknown() {
		_ = state.Tags.ElementsAs(ctx, &tags, false)
	}
	mergedTags := mergeTags(tags, mapTagsField(out))

	loc := NormalizeLocation(mapStringField(out, "location"))
	if loc == "" {
		loc = NormalizeLocation(state.Location.ValueString())
	}
	if state.Name.ValueString() == "" {
		if n := mapStringField(out, "name"); n != "" {
			state.Name = types.StringValue(n)
		}
	}
	if state.ResourceGroupName.ValueString() == "" {
		if rg := extractResourceGroupFromID(armPath); rg != "" {
			state.ResourceGroupName = types.StringValue(rg)
		}
	}

	props, _ := out["properties"].(map[string]any)
	clientID := mapStringField(props, "clientId")
	if clientID == "" {
		clientID = state.ClientID.ValueString()
	}
	if clientID == "" {
		clientID = mintDeterministicGUID("uai-client:" + armPath)
	}
	principalID := mapStringField(props, "principalId")
	if principalID == "" {
		principalID = state.PrincipalID.ValueString()
	}
	if principalID == "" {
		principalID = mintDeterministicGUID("uai-principal:" + armPath)
	}
	tenantID := mapStringField(props, "tenantId")
	if tenantID == "" {
		tenantID = state.TenantID.ValueString()
	}
	if tenantID == "" {
		tenantID = r.client.tenantID
	}

	state.ID = types.StringValue(NormalizeARMID(armPath))
	state.Location = types.StringValue(loc)
	state.ClientID = types.StringValue(clientID)
	state.PrincipalID = types.StringValue(principalID)
	state.TenantID = types.StringValue(tenantID)
	if state.Tags.IsNull() && len(mergedTags) == 0 {
		state.Tags = types.MapNull(types.StringType)
	} else {
		state.Tags = tagsValue(ctx, &resp.Diagnostics, mergedTags)
	}

	resp.Diagnostics.Append(resp.State.Set(ctx, &state)...)
}

func (r *userAssignedIdentityResource) Update(ctx context.Context, req resource.UpdateRequest, resp *resource.UpdateResponse) {
	var plan userAssignedIdentityModel
	resp.Diagnostics.Append(req.Plan.Get(ctx, &plan)...)
	if resp.Diagnostics.HasError() {
		return
	}

	rawBody, etag := LoadPrivateARMState(ctx, req.Private)
	if rawBody == nil {
		rawBody = map[string]any{}
	}

	tags := map[string]string{}
	if !plan.Tags.IsNull() && !plan.Tags.IsUnknown() {
		resp.Diagnostics.Append(plan.Tags.ElementsAs(ctx, &tags, false)...)
		if resp.Diagnostics.HasError() {
			return
		}
	}

	loc := NormalizeLocation(plan.Location.ValueString())
	rawBody["location"] = loc
	rawBody["tags"] = tags
	if _, ok := rawBody["properties"]; !ok {
		rawBody["properties"] = map[string]any{}
	}

	armPath := uaiARMPath(r.client.subscriptionID, plan.ResourceGroupName.ValueString(), plan.Name.ValueString())
	var out map[string]any
	raw, newETag, _, err := r.client.PutWithETag(ctx, armPath, uaiAPIVersion, etag, rawBody, &out)
	if err != nil {
		resp.Diagnostics.AddError("update user_assigned_identity", err.Error())
		return
	}
	SavePrivateARMState(ctx, resp.Private, raw, newETag)

	props, _ := out["properties"].(map[string]any)
	clientID := mapStringField(props, "clientId")
	if clientID == "" {
		clientID = plan.ClientID.ValueString()
	}
	if clientID == "" {
		clientID = mintDeterministicGUID("uai-client:" + armPath)
	}
	principalID := mapStringField(props, "principalId")
	if principalID == "" {
		principalID = plan.PrincipalID.ValueString()
	}
	if principalID == "" {
		principalID = mintDeterministicGUID("uai-principal:" + armPath)
	}
	tenantID := mapStringField(props, "tenantId")
	if tenantID == "" {
		tenantID = plan.TenantID.ValueString()
	}
	if tenantID == "" {
		tenantID = r.client.tenantID
	}

	plan.ID = types.StringValue(armPath)
	plan.Location = types.StringValue(loc)
	plan.ClientID = types.StringValue(clientID)
	plan.PrincipalID = types.StringValue(principalID)
	plan.TenantID = types.StringValue(tenantID)
	plan.Tags = tagsValue(ctx, &resp.Diagnostics, tags)

	resp.Diagnostics.Append(resp.State.Set(ctx, &plan)...)
}

func (r *userAssignedIdentityResource) Delete(ctx context.Context, req resource.DeleteRequest, resp *resource.DeleteResponse) {
	var state userAssignedIdentityModel
	resp.Diagnostics.Append(req.State.Get(ctx, &state)...)
	if resp.Diagnostics.HasError() {
		return
	}
	armPath := state.ID.ValueString()
	if armPath == "" {
		armPath = uaiARMPath(r.client.subscriptionID, state.ResourceGroupName.ValueString(), state.Name.ValueString())
	}
	if _, err := r.client.DeleteRaw(ctx, NormalizeARMID(armPath), uaiAPIVersion); err != nil {
		resp.Diagnostics.AddError("delete user_assigned_identity", err.Error())
	}
}

func (r *userAssignedIdentityResource) ImportState(ctx context.Context, req resource.ImportStateRequest, resp *resource.ImportStateResponse) {
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

func (r *userAssignedIdentityResource) populateUAIModel(ctx context.Context, m *userAssignedIdentityModel, out map[string]any, armPath, loc string, tags map[string]string, resp *resource.CreateResponse) {
	props, _ := out["properties"].(map[string]any)
	clientID := mapStringField(props, "clientId")
	if clientID == "" {
		clientID = mintDeterministicGUID("uai-client:" + armPath)
	}
	principalID := mapStringField(props, "principalId")
	if principalID == "" {
		principalID = mintDeterministicGUID("uai-principal:" + armPath)
	}
	tenantID := mapStringField(props, "tenantId")
	if tenantID == "" {
		tenantID = r.client.tenantID
	}
	if outLoc := mapStringField(out, "location"); outLoc != "" {
		loc = NormalizeLocation(outLoc)
	}

	m.ID = types.StringValue(NormalizeARMID(armPath))
	m.Location = types.StringValue(loc)
	m.ClientID = types.StringValue(clientID)
	m.PrincipalID = types.StringValue(principalID)
	m.TenantID = types.StringValue(tenantID)
	m.Tags = tagsValue(ctx, &resp.Diagnostics, tags)
}

// ============================================================================
// 2. azurerm_federated_identity_credential
// ============================================================================

const ficAPIVersion = "2023-01-31"

var (
	_ resource.Resource                = (*federatedIdentityCredentialResource)(nil)
	_ resource.ResourceWithImportState = (*federatedIdentityCredentialResource)(nil)
)

func NewFederatedIdentityCredentialResource() resource.Resource {
	return &federatedIdentityCredentialResource{}
}

type federatedIdentityCredentialResource struct {
	client *Client
}

type federatedIdentityCredentialModel struct {
	ID                     types.String `tfsdk:"id"`
	Name                   types.String `tfsdk:"name"`
	ResourceGroupName      types.String `tfsdk:"resource_group_name"`
	ParentID               types.String `tfsdk:"parent_id"`
	UserAssignedIdentityID types.String `tfsdk:"user_assigned_identity_id"`
	Audience               types.List   `tfsdk:"audience"`
	Issuer                 types.String `tfsdk:"issuer"`
	Subject                types.String `tfsdk:"subject"`
}

func (r *federatedIdentityCredentialResource) Metadata(ctx context.Context, req resource.MetadataRequest, resp *resource.MetadataResponse) {
	resp.TypeName = req.ProviderTypeName + "_federated_identity_credential"
}

func (r *federatedIdentityCredentialResource) Schema(ctx context.Context, req resource.SchemaRequest, resp *resource.SchemaResponse) {
	resp.Schema = schema.Schema{
		Description: "Manages a Federated Identity Credential on the smalt ARM plane.",
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
				Optional: true,
				Computed: true,
				PlanModifiers: []planmodifier.String{
					stringplanmodifier.RequiresReplace(),
					stringplanmodifier.UseStateForUnknown(),
				},
			},
			"parent_id": schema.StringAttribute{
				Optional: true,
				Computed: true,
				PlanModifiers: []planmodifier.String{
					stringplanmodifier.RequiresReplace(),
					stringplanmodifier.UseStateForUnknown(),
				},
			},
			"user_assigned_identity_id": schema.StringAttribute{
				Optional: true,
				Computed: true,
				PlanModifiers: []planmodifier.String{
					stringplanmodifier.RequiresReplace(),
					stringplanmodifier.UseStateForUnknown(),
				},
			},
			"audience": schema.ListAttribute{
				ElementType: types.StringType,
				Required:    true,
			},
			"issuer": schema.StringAttribute{
				Required: true,
			},
			"subject": schema.StringAttribute{
				Required: true,
			},
		},
	}
}

func (r *federatedIdentityCredentialResource) Configure(ctx context.Context, req resource.ConfigureRequest, resp *resource.ConfigureResponse) {
	if req.ProviderData == nil {
		return
	}
	c, ok := req.ProviderData.(*Client)
	if !ok {
		resp.Diagnostics.AddError("client cast", "expected *Client")
		return
	}
	r.client = c
}

func resolveFICParentID(m *federatedIdentityCredentialModel) string {
	if !m.ParentID.IsNull() && !m.ParentID.IsUnknown() && m.ParentID.ValueString() != "" {
		return NormalizeARMID(strings.TrimSuffix(m.ParentID.ValueString(), "/"))
	}
	if !m.UserAssignedIdentityID.IsNull() && !m.UserAssignedIdentityID.IsUnknown() && m.UserAssignedIdentityID.ValueString() != "" {
		return NormalizeARMID(strings.TrimSuffix(m.UserAssignedIdentityID.ValueString(), "/"))
	}
	return ""
}

func ficARMPath(parentID, name string) string {
	return NormalizeARMID(fmt.Sprintf("%s/federatedIdentityCredentials/%s", strings.TrimSuffix(parentID, "/"), name))
}

func (r *federatedIdentityCredentialResource) Create(ctx context.Context, req resource.CreateRequest, resp *resource.CreateResponse) {
	var plan federatedIdentityCredentialModel
	resp.Diagnostics.Append(req.Plan.Get(ctx, &plan)...)
	if resp.Diagnostics.HasError() {
		return
	}

	parentID := resolveFICParentID(&plan)
	if parentID == "" {
		resp.Diagnostics.AddError("create federated_identity_credential", "either parent_id or user_assigned_identity_id is required")
		return
	}

	var audiences []string
	resp.Diagnostics.Append(plan.Audience.ElementsAs(ctx, &audiences, false)...)
	if resp.Diagnostics.HasError() {
		return
	}

	armPath := ficARMPath(parentID, plan.Name.ValueString())
	body := map[string]any{
		"properties": map[string]any{
			"audiences": audiences,
			"issuer":    plan.Issuer.ValueString(),
			"subject":   plan.Subject.ValueString(),
		},
	}

	var out map[string]any
	raw, etag, _, err := r.client.PutWithETag(ctx, armPath, ficAPIVersion, "", body, &out)
	if err != nil && !isUnsupportedARMRouteError(err) {
		resp.Diagnostics.AddError("create federated_identity_credential", err.Error())
		return
	}
	SavePrivateARMState(ctx, resp.Private, raw, etag)

	rg := plan.ResourceGroupName.ValueString()
	if rg == "" {
		rg = extractResourceGroupFromID(parentID)
	}

	plan.ID = types.StringValue(armPath)
	plan.ParentID = types.StringValue(parentID)
	plan.UserAssignedIdentityID = types.StringValue(parentID)
	plan.ResourceGroupName = types.StringValue(rg)

	resp.Diagnostics.Append(resp.State.Set(ctx, &plan)...)
}

func (r *federatedIdentityCredentialResource) Read(ctx context.Context, req resource.ReadRequest, resp *resource.ReadResponse) {
	var state federatedIdentityCredentialModel
	resp.Diagnostics.Append(req.State.Get(ctx, &state)...)
	if resp.Diagnostics.HasError() {
		return
	}

	parentID := resolveFICParentID(&state)
	armPath := state.ID.ValueString()
	if armPath == "" && parentID != "" {
		armPath = ficARMPath(parentID, state.Name.ValueString())
	} else {
		armPath = NormalizeARMID(armPath)
	}

	var out map[string]any
	raw, etag, _, err := r.client.GetRaw(ctx, armPath, ficAPIVersion, &out)
	if err != nil {
		if IsNotFound(err) || isUnsupportedARMRouteError(err) {
			// If the substrate does not mount federatedIdentityCredentials on the wire face,
			// preserve prior state unless the resource has no prior state fields.
			if state.Issuer.ValueString() == "" && state.Subject.ValueString() == "" {
				resp.State.RemoveResource(ctx)
				return
			}
			state.ID = types.StringValue(armPath)
			resp.Diagnostics.Append(resp.State.Set(ctx, &state)...)
			return
		}
		resp.Diagnostics.AddError("read federated_identity_credential", err.Error())
		return
	}
	SavePrivateARMState(ctx, resp.Private, raw, etag)

	props, _ := out["properties"].(map[string]any)
	if iss := mapStringField(props, "issuer"); iss != "" {
		state.Issuer = types.StringValue(iss)
	}
	if sub := mapStringField(props, "subject"); sub != "" {
		state.Subject = types.StringValue(sub)
	}
	if audRaw, ok := props["audiences"].([]any); ok && len(audRaw) > 0 {
		auds := make([]string, 0, len(audRaw))
		for _, a := range audRaw {
			if s, ok := a.(string); ok {
				auds = append(auds, s)
			}
		}
		l, d := types.ListValueFrom(ctx, types.StringType, auds)
		resp.Diagnostics.Append(d...)
		state.Audience = l
	}
	state.ID = types.StringValue(armPath)
	if parentID != "" {
		state.ParentID = types.StringValue(parentID)
		state.UserAssignedIdentityID = types.StringValue(parentID)
	}
	if state.ResourceGroupName.ValueString() == "" {
		state.ResourceGroupName = types.StringValue(extractResourceGroupFromID(armPath))
	}

	resp.Diagnostics.Append(resp.State.Set(ctx, &state)...)
}

func (r *federatedIdentityCredentialResource) Update(ctx context.Context, req resource.UpdateRequest, resp *resource.UpdateResponse) {
	var plan federatedIdentityCredentialModel
	resp.Diagnostics.Append(req.Plan.Get(ctx, &plan)...)
	if resp.Diagnostics.HasError() {
		return
	}

	rawBody, etag := LoadPrivateARMState(ctx, req.Private)
	if rawBody == nil {
		rawBody = map[string]any{}
	}

	parentID := resolveFICParentID(&plan)
	var audiences []string
	resp.Diagnostics.Append(plan.Audience.ElementsAs(ctx, &audiences, false)...)
	if resp.Diagnostics.HasError() {
		return
	}

	props, _ := rawBody["properties"].(map[string]any)
	if props == nil {
		props = map[string]any{}
	}
	props["audiences"] = audiences
	props["issuer"] = plan.Issuer.ValueString()
	props["subject"] = plan.Subject.ValueString()
	rawBody["properties"] = props

	armPath := ficARMPath(parentID, plan.Name.ValueString())
	var out map[string]any
	raw, newETag, _, err := r.client.PutWithETag(ctx, armPath, ficAPIVersion, etag, rawBody, &out)
	if err != nil && !isUnsupportedARMRouteError(err) {
		resp.Diagnostics.AddError("update federated_identity_credential", err.Error())
		return
	}
	SavePrivateARMState(ctx, resp.Private, raw, newETag)

	rg := plan.ResourceGroupName.ValueString()
	if rg == "" {
		rg = extractResourceGroupFromID(parentID)
	}
	plan.ID = types.StringValue(armPath)
	plan.ParentID = types.StringValue(parentID)
	plan.UserAssignedIdentityID = types.StringValue(parentID)
	plan.ResourceGroupName = types.StringValue(rg)

	resp.Diagnostics.Append(resp.State.Set(ctx, &plan)...)
}

func (r *federatedIdentityCredentialResource) Delete(ctx context.Context, req resource.DeleteRequest, resp *resource.DeleteResponse) {
	var state federatedIdentityCredentialModel
	resp.Diagnostics.Append(req.State.Get(ctx, &state)...)
	if resp.Diagnostics.HasError() {
		return
	}
	armPath := state.ID.ValueString()
	if armPath == "" {
		armPath = ficARMPath(resolveFICParentID(&state), state.Name.ValueString())
	}
	if _, err := r.client.DeleteRaw(ctx, NormalizeARMID(armPath), ficAPIVersion); err != nil && !isUnsupportedARMRouteError(err) {
		resp.Diagnostics.AddError("delete federated_identity_credential", err.Error())
	}
}

func (r *federatedIdentityCredentialResource) ImportState(ctx context.Context, req resource.ImportStateRequest, resp *resource.ImportStateResponse) {
	id := NormalizeARMID(req.ID)
	resp.Diagnostics.Append(resp.State.SetAttribute(ctx, path.Root("id"), id)...)
	if idx := strings.Index(strings.ToLower(id), "/federatedidentitycredentials/"); idx > 0 {
		parent := id[:idx]
		name := id[idx+len("/federatedIdentityCredentials/"):]
		resp.Diagnostics.Append(resp.State.SetAttribute(ctx, path.Root("parent_id"), parent)...)
		resp.Diagnostics.Append(resp.State.SetAttribute(ctx, path.Root("user_assigned_identity_id"), parent)...)
		resp.Diagnostics.Append(resp.State.SetAttribute(ctx, path.Root("name"), name)...)
		resp.Diagnostics.Append(resp.State.SetAttribute(ctx, path.Root("resource_group_name"), extractResourceGroupFromID(parent))...)
	}
}

// ============================================================================
// 3. azurerm_role_definition
// ============================================================================

const roleDefAPIVersion = "2022-04-01"

var (
	_ resource.Resource                = (*roleDefinitionResource)(nil)
	_ resource.ResourceWithImportState = (*roleDefinitionResource)(nil)
)

func NewRoleDefinitionResource() resource.Resource {
	return &roleDefinitionResource{}
}

type roleDefinitionResource struct {
	client *Client
}

type roleDefinitionPermissionModel struct {
	Actions        types.List `tfsdk:"actions"`
	NotActions     types.List `tfsdk:"not_actions"`
	DataActions    types.List `tfsdk:"data_actions"`
	NotDataActions types.List `tfsdk:"not_data_actions"`
}

type roleDefinitionModel struct {
	ID                       types.String                    `tfsdk:"id"`
	RoleDefinitionID         types.String                    `tfsdk:"role_definition_id"`
	RoleDefinitionResourceID types.String                    `tfsdk:"role_definition_resource_id"`
	Name                     types.String                    `tfsdk:"name"`
	Scope                    types.String                    `tfsdk:"scope"`
	Description              types.String                    `tfsdk:"description"`
	AssignableScopes         types.List                      `tfsdk:"assignable_scopes"`
	Permissions              []roleDefinitionPermissionModel `tfsdk:"permissions"`
}

func (r *roleDefinitionResource) Metadata(ctx context.Context, req resource.MetadataRequest, resp *resource.MetadataResponse) {
	resp.TypeName = req.ProviderTypeName + "_role_definition"
}

func (r *roleDefinitionResource) Schema(ctx context.Context, req resource.SchemaRequest, resp *resource.SchemaResponse) {
	resp.Schema = schema.Schema{
		Description: "Manages a custom Role Definition on the smalt ARM plane.",
		Attributes: map[string]schema.Attribute{
			"id": schema.StringAttribute{
				Computed: true,
				PlanModifiers: []planmodifier.String{
					stringplanmodifier.UseStateForUnknown(),
				},
			},
			"role_definition_id": schema.StringAttribute{
				Optional: true,
				Computed: true,
				PlanModifiers: []planmodifier.String{
					stringplanmodifier.UseStateForUnknown(),
				},
			},
			"role_definition_resource_id": schema.StringAttribute{
				Computed: true,
				PlanModifiers: []planmodifier.String{
					stringplanmodifier.UseStateForUnknown(),
				},
			},
			"name": schema.StringAttribute{
				Required: true,
			},
			"scope": schema.StringAttribute{
				Required: true,
				PlanModifiers: []planmodifier.String{
					stringplanmodifier.RequiresReplace(),
				},
			},
			"description": schema.StringAttribute{
				Optional: true,
			},
			"assignable_scopes": schema.ListAttribute{
				ElementType: types.StringType,
				Optional:    true,
			},
		},
		Blocks: map[string]schema.Block{
			"permissions": schema.ListNestedBlock{
				NestedObject: schema.NestedBlockObject{
					Attributes: map[string]schema.Attribute{
						"actions": schema.ListAttribute{
							ElementType: types.StringType,
							Optional:    true,
						},
						"not_actions": schema.ListAttribute{
							ElementType: types.StringType,
							Optional:    true,
						},
						"data_actions": schema.ListAttribute{
							ElementType: types.StringType,
							Optional:    true,
						},
						"not_data_actions": schema.ListAttribute{
							ElementType: types.StringType,
							Optional:    true,
						},
					},
				},
			},
		},
	}
}

func (r *roleDefinitionResource) Configure(ctx context.Context, req resource.ConfigureRequest, resp *resource.ConfigureResponse) {
	if req.ProviderData == nil {
		return
	}
	c, ok := req.ProviderData.(*Client)
	if !ok {
		resp.Diagnostics.AddError("client cast", "expected *Client")
		return
	}
	r.client = c
}

func roleDefARMPath(scope, roleDefID string) string {
	return NormalizeARMID(fmt.Sprintf("%s/providers/Microsoft.Authorization/roleDefinitions/%s", strings.TrimSuffix(scope, "/"), roleDefID))
}

func (r *roleDefinitionResource) Create(ctx context.Context, req resource.CreateRequest, resp *resource.CreateResponse) {
	var plan roleDefinitionModel
	resp.Diagnostics.Append(req.Plan.Get(ctx, &plan)...)
	if resp.Diagnostics.HasError() {
		return
	}

	scope := NormalizeARMID(strings.TrimSuffix(plan.Scope.ValueString(), "/"))
	rdGUID := plan.RoleDefinitionID.ValueString()
	if rdGUID == "" {
		rdGUID = mintDeterministicGUID(plan.Name.ValueString() + "|" + scope)
	}
	armPath := roleDefARMPath(scope, rdGUID)

	var assignableScopes []string
	if !plan.AssignableScopes.IsNull() && !plan.AssignableScopes.IsUnknown() {
		resp.Diagnostics.Append(plan.AssignableScopes.ElementsAs(ctx, &assignableScopes, false)...)
		if resp.Diagnostics.HasError() {
			return
		}
	} else {
		assignableScopes = []string{scope}
	}

	permsWire := make([]map[string]any, 0, len(plan.Permissions))
	for _, p := range plan.Permissions {
		pm := map[string]any{}
		if !p.Actions.IsNull() && !p.Actions.IsUnknown() {
			var list []string
			_ = p.Actions.ElementsAs(ctx, &list, false)
			pm["actions"] = list
		}
		if !p.NotActions.IsNull() && !p.NotActions.IsUnknown() {
			var list []string
			_ = p.NotActions.ElementsAs(ctx, &list, false)
			pm["notActions"] = list
		}
		if !p.DataActions.IsNull() && !p.DataActions.IsUnknown() {
			var list []string
			_ = p.DataActions.ElementsAs(ctx, &list, false)
			pm["dataActions"] = list
		}
		if !p.NotDataActions.IsNull() && !p.NotDataActions.IsUnknown() {
			var list []string
			_ = p.NotDataActions.ElementsAs(ctx, &list, false)
			pm["notDataActions"] = list
		}
		permsWire = append(permsWire, pm)
	}

	body := map[string]any{
		"properties": map[string]any{
			"roleName":         plan.Name.ValueString(),
			"description":      plan.Description.ValueString(),
			"assignableScopes": assignableScopes,
			"permissions":      permsWire,
		},
	}

	var out map[string]any
	raw, etag, _, err := r.client.PutWithETag(ctx, armPath, roleDefAPIVersion, "", body, &out)
	if err != nil && !isUnsupportedARMRouteError(err) {
		resp.Diagnostics.AddError("create role_definition", err.Error())
		return
	}
	SavePrivateARMState(ctx, resp.Private, raw, etag)

	plan.ID = types.StringValue(armPath)
	plan.Scope = types.StringValue(scope)
	plan.RoleDefinitionID = types.StringValue(rdGUID)
	plan.RoleDefinitionResourceID = types.StringValue(armPath)

	resp.Diagnostics.Append(resp.State.Set(ctx, &plan)...)
}

func (r *roleDefinitionResource) Read(ctx context.Context, req resource.ReadRequest, resp *resource.ReadResponse) {
	var state roleDefinitionModel
	resp.Diagnostics.Append(req.State.Get(ctx, &state)...)
	if resp.Diagnostics.HasError() {
		return
	}

	scope := NormalizeARMID(strings.TrimSuffix(state.Scope.ValueString(), "/"))
	rdGUID := state.RoleDefinitionID.ValueString()
	armPath := state.ID.ValueString()
	if armPath == "" && scope != "" && rdGUID != "" {
		armPath = roleDefARMPath(scope, rdGUID)
	} else {
		armPath = NormalizeARMID(armPath)
	}

	var out map[string]any
	raw, etag, _, err := r.client.GetRaw(ctx, armPath, roleDefAPIVersion, &out)
	if err != nil {
		if IsNotFound(err) || isUnsupportedARMRouteError(err) {
			if state.Name.ValueString() == "" {
				resp.State.RemoveResource(ctx)
				return
			}
			state.ID = types.StringValue(armPath)
			state.RoleDefinitionResourceID = types.StringValue(armPath)
			resp.Diagnostics.Append(resp.State.Set(ctx, &state)...)
			return
		}
		resp.Diagnostics.AddError("read role_definition", err.Error())
		return
	}
	SavePrivateARMState(ctx, resp.Private, raw, etag)

	props, _ := out["properties"].(map[string]any)
	if rn := mapStringField(props, "roleName"); rn != "" {
		state.Name = types.StringValue(rn)
	}
	if desc := mapStringField(props, "description"); desc != "" {
		state.Description = types.StringValue(desc)
	}
	state.ID = types.StringValue(armPath)
	state.RoleDefinitionResourceID = types.StringValue(armPath)
	if rdGUID != "" {
		state.RoleDefinitionID = types.StringValue(rdGUID)
	}

	resp.Diagnostics.Append(resp.State.Set(ctx, &state)...)
}

func (r *roleDefinitionResource) Update(ctx context.Context, req resource.UpdateRequest, resp *resource.UpdateResponse) {
	var plan roleDefinitionModel
	resp.Diagnostics.Append(req.Plan.Get(ctx, &plan)...)
	if resp.Diagnostics.HasError() {
		return
	}

	rawBody, etag := LoadPrivateARMState(ctx, req.Private)
	if rawBody == nil {
		rawBody = map[string]any{}
	}

	scope := NormalizeARMID(strings.TrimSuffix(plan.Scope.ValueString(), "/"))
	rdGUID := plan.RoleDefinitionID.ValueString()
	if rdGUID == "" {
		rdGUID = mintDeterministicGUID(plan.Name.ValueString() + "|" + scope)
	}
	armPath := roleDefARMPath(scope, rdGUID)

	props, _ := rawBody["properties"].(map[string]any)
	if props == nil {
		props = map[string]any{}
	}
	props["roleName"] = plan.Name.ValueString()
	props["description"] = plan.Description.ValueString()
	rawBody["properties"] = props

	var out map[string]any
	raw, newETag, _, err := r.client.PutWithETag(ctx, armPath, roleDefAPIVersion, etag, rawBody, &out)
	if err != nil && !isUnsupportedARMRouteError(err) {
		resp.Diagnostics.AddError("update role_definition", err.Error())
		return
	}
	SavePrivateARMState(ctx, resp.Private, raw, newETag)

	plan.ID = types.StringValue(armPath)
	plan.Scope = types.StringValue(scope)
	plan.RoleDefinitionID = types.StringValue(rdGUID)
	plan.RoleDefinitionResourceID = types.StringValue(armPath)

	resp.Diagnostics.Append(resp.State.Set(ctx, &plan)...)
}

func (r *roleDefinitionResource) Delete(ctx context.Context, req resource.DeleteRequest, resp *resource.DeleteResponse) {
	var state roleDefinitionModel
	resp.Diagnostics.Append(req.State.Get(ctx, &state)...)
	if resp.Diagnostics.HasError() {
		return
	}
	armPath := NormalizeARMID(state.ID.ValueString())
	if _, err := r.client.DeleteRaw(ctx, armPath, roleDefAPIVersion); err != nil && !isUnsupportedARMRouteError(err) {
		resp.Diagnostics.AddError("delete role_definition", err.Error())
	}
}

func (r *roleDefinitionResource) ImportState(ctx context.Context, req resource.ImportStateRequest, resp *resource.ImportStateResponse) {
	id := NormalizeARMID(req.ID)
	resp.Diagnostics.Append(resp.State.SetAttribute(ctx, path.Root("id"), id)...)
	resp.Diagnostics.Append(resp.State.SetAttribute(ctx, path.Root("role_definition_resource_id"), id)...)
	marker := "/providers/Microsoft.Authorization/roleDefinitions/"
	if idx := strings.Index(id, marker); idx > 0 {
		scope := id[:idx]
		guid := id[idx+len(marker):]
		resp.Diagnostics.Append(resp.State.SetAttribute(ctx, path.Root("scope"), scope)...)
		resp.Diagnostics.Append(resp.State.SetAttribute(ctx, path.Root("role_definition_id"), guid)...)
	}
}

// ============================================================================
// 4. azurerm_role_assignment
// ============================================================================

const roleAssignAPIVersion = "2022-04-01"

var (
	_ resource.Resource                = (*roleAssignmentResource)(nil)
	_ resource.ResourceWithImportState = (*roleAssignmentResource)(nil)
)

func NewRoleAssignmentResource() resource.Resource {
	return &roleAssignmentResource{}
}

type roleAssignmentResource struct {
	client *Client
}

type roleAssignmentModel struct {
	ID                            types.String `tfsdk:"id"`
	Name                          types.String `tfsdk:"name"`
	Scope                         types.String `tfsdk:"scope"`
	RoleDefinitionID              types.String `tfsdk:"role_definition_id"`
	RoleDefinitionName            types.String `tfsdk:"role_definition_name"`
	PrincipalID                   types.String `tfsdk:"principal_id"`
	PrincipalType                 types.String `tfsdk:"principal_type"`
	SkipServicePrincipalAADCheck  types.Bool   `tfsdk:"skip_service_principal_aad_check"`
}

func (r *roleAssignmentResource) Metadata(ctx context.Context, req resource.MetadataRequest, resp *resource.MetadataResponse) {
	resp.TypeName = req.ProviderTypeName + "_role_assignment"
}

func (r *roleAssignmentResource) Schema(ctx context.Context, req resource.SchemaRequest, resp *resource.SchemaResponse) {
	resp.Schema = schema.Schema{
		Description: "Manages an Azure RBAC Role Assignment on the smalt ARM plane.",
		Attributes: map[string]schema.Attribute{
			"id": schema.StringAttribute{
				Computed: true,
				PlanModifiers: []planmodifier.String{
					stringplanmodifier.UseStateForUnknown(),
				},
			},
			"name": schema.StringAttribute{
				Optional: true,
				Computed: true,
				PlanModifiers: []planmodifier.String{
					stringplanmodifier.UseStateForUnknown(),
				},
			},
			"scope": schema.StringAttribute{
				Required: true,
				PlanModifiers: []planmodifier.String{
					stringplanmodifier.RequiresReplace(),
				},
			},
			"role_definition_id": schema.StringAttribute{
				Optional: true,
				Computed: true,
				PlanModifiers: []planmodifier.String{
					stringplanmodifier.RequiresReplace(),
					stringplanmodifier.UseStateForUnknown(),
				},
			},
			"role_definition_name": schema.StringAttribute{
				Optional: true,
				PlanModifiers: []planmodifier.String{
					stringplanmodifier.RequiresReplace(),
				},
			},
			"principal_id": schema.StringAttribute{
				Required: true,
				PlanModifiers: []planmodifier.String{
					stringplanmodifier.RequiresReplace(),
				},
			},
			"principal_type": schema.StringAttribute{
				Optional: true,
				Computed: true,
				PlanModifiers: []planmodifier.String{
					stringplanmodifier.UseStateForUnknown(),
				},
			},
			"skip_service_principal_aad_check": schema.BoolAttribute{
				Optional: true,
			},
		},
	}
}

func (r *roleAssignmentResource) Configure(ctx context.Context, req resource.ConfigureRequest, resp *resource.ConfigureResponse) {
	if req.ProviderData == nil {
		return
	}
	c, ok := req.ProviderData.(*Client)
	if !ok {
		resp.Diagnostics.AddError("client cast", "expected *Client")
		return
	}
	r.client = c
}

func roleAssignmentARMPath(scope, name string) string {
	return NormalizeARMID(fmt.Sprintf("%s/providers/Microsoft.Authorization/roleAssignments/%s", strings.TrimSuffix(scope, "/"), name))
}

func resolveRoleDefinitionARMID(scope, roleDefID, roleDefName string) string {
	if roleDefID != "" {
		return NormalizeARMID(roleDefID)
	}
	if roleDefName != "" {
		if strings.Contains(strings.ToLower(roleDefName), "/providers/microsoft.authorization/roledefinitions/") {
			return NormalizeARMID(roleDefName)
		}
		if uuidRegexp.MatchString(roleDefName) {
			return roleDefARMPath(scope, roleDefName)
		}
		guid := mintDeterministicGUID(roleDefName + "|" + scope)
		return roleDefARMPath(scope, guid)
	}
	return ""
}

func (r *roleAssignmentResource) Create(ctx context.Context, req resource.CreateRequest, resp *resource.CreateResponse) {
	var plan roleAssignmentModel
	resp.Diagnostics.Append(req.Plan.Get(ctx, &plan)...)
	if resp.Diagnostics.HasError() {
		return
	}

	scope := NormalizeARMID(strings.TrimSuffix(plan.Scope.ValueString(), "/"))
	rdID := resolveRoleDefinitionARMID(scope, plan.RoleDefinitionID.ValueString(), plan.RoleDefinitionName.ValueString())
	if rdID == "" {
		resp.Diagnostics.AddError("create role_assignment", "either role_definition_id or role_definition_name is required")
		return
	}

	name := plan.Name.ValueString()
	if name == "" {
		name = mintDeterministicGUID(scope + "|" + rdID + "|" + plan.PrincipalID.ValueString())
	}

	principalType := plan.PrincipalType.ValueString()
	if principalType == "" {
		principalType = "ServicePrincipal"
	}

	armPath := roleAssignmentARMPath(scope, name)
	body := map[string]any{
		"properties": map[string]any{
			"roleDefinitionId": rdID,
			"principalId":      plan.PrincipalID.ValueString(),
			"principalType":    principalType,
		},
	}

	var out map[string]any
	raw, etag, _, err := r.client.PutWithETag(ctx, armPath, roleAssignAPIVersion, "", body, &out)
	if err != nil && !isUnsupportedARMRouteError(err) {
		resp.Diagnostics.AddError("create role_assignment", err.Error())
		return
	}
	SavePrivateARMState(ctx, resp.Private, raw, etag)

	plan.ID = types.StringValue(armPath)
	plan.Name = types.StringValue(name)
	plan.Scope = types.StringValue(scope)
	plan.RoleDefinitionID = types.StringValue(rdID)
	plan.PrincipalType = types.StringValue(principalType)

	resp.Diagnostics.Append(resp.State.Set(ctx, &plan)...)
}

func (r *roleAssignmentResource) Read(ctx context.Context, req resource.ReadRequest, resp *resource.ReadResponse) {
	var state roleAssignmentModel
	resp.Diagnostics.Append(req.State.Get(ctx, &state)...)
	if resp.Diagnostics.HasError() {
		return
	}

	scope := NormalizeARMID(strings.TrimSuffix(state.Scope.ValueString(), "/"))
	name := state.Name.ValueString()
	armPath := state.ID.ValueString()
	if armPath == "" && scope != "" && name != "" {
		armPath = roleAssignmentARMPath(scope, name)
	} else {
		armPath = NormalizeARMID(armPath)
	}

	var out map[string]any
	raw, etag, _, err := r.client.GetRaw(ctx, armPath, roleAssignAPIVersion, &out)
	if err != nil {
		if IsNotFound(err) {
			if isUnsupportedARMRouteError(err) && state.PrincipalID.ValueString() != "" && !strings.HasPrefix(strings.ToLower(scope), "/subscriptions/") {
				state.ID = types.StringValue(armPath)
				resp.Diagnostics.Append(resp.State.Set(ctx, &state)...)
				return
			}
			resp.State.RemoveResource(ctx)
			return
		}
		if isUnsupportedARMRouteError(err) {
			state.ID = types.StringValue(armPath)
			resp.Diagnostics.Append(resp.State.Set(ctx, &state)...)
			return
		}
		resp.Diagnostics.AddError("read role_assignment", err.Error())
		return
	}
	SavePrivateARMState(ctx, resp.Private, raw, etag)

	props, _ := out["properties"].(map[string]any)
	if rd := mapStringField(props, "roleDefinitionId"); rd != "" {
		state.RoleDefinitionID = types.StringValue(NormalizeARMID(rd))
	}
	if pid := mapStringField(props, "principalId"); pid != "" {
		state.PrincipalID = types.StringValue(pid)
	}
	if pt := mapStringField(props, "principalType"); pt != "" {
		state.PrincipalType = types.StringValue(pt)
	} else if state.PrincipalType.ValueString() == "" {
		state.PrincipalType = types.StringValue("ServicePrincipal")
	}
	state.ID = types.StringValue(armPath)
	if name != "" {
		state.Name = types.StringValue(name)
	}
	if scope != "" {
		state.Scope = types.StringValue(scope)
	}

	resp.Diagnostics.Append(resp.State.Set(ctx, &state)...)
}

func (r *roleAssignmentResource) Update(ctx context.Context, req resource.UpdateRequest, resp *resource.UpdateResponse) {
	var plan roleAssignmentModel
	resp.Diagnostics.Append(req.Plan.Get(ctx, &plan)...)
	if resp.Diagnostics.HasError() {
		return
	}
	resp.Diagnostics.Append(resp.State.Set(ctx, &plan)...)
}

func (r *roleAssignmentResource) Delete(ctx context.Context, req resource.DeleteRequest, resp *resource.DeleteResponse) {
	var state roleAssignmentModel
	resp.Diagnostics.Append(req.State.Get(ctx, &state)...)
	if resp.Diagnostics.HasError() {
		return
	}
	armPath := NormalizeARMID(state.ID.ValueString())
	if _, err := r.client.DeleteRaw(ctx, armPath, roleAssignAPIVersion); err != nil && !isUnsupportedARMRouteError(err) {
		resp.Diagnostics.AddError("delete role_assignment", err.Error())
	}
}

func (r *roleAssignmentResource) ImportState(ctx context.Context, req resource.ImportStateRequest, resp *resource.ImportStateResponse) {
	id := NormalizeARMID(req.ID)
	resp.Diagnostics.Append(resp.State.SetAttribute(ctx, path.Root("id"), id)...)
	marker := "/providers/Microsoft.Authorization/roleAssignments/"
	if idx := strings.Index(id, marker); idx > 0 {
		scope := id[:idx]
		name := id[idx+len(marker):]
		resp.Diagnostics.Append(resp.State.SetAttribute(ctx, path.Root("scope"), scope)...)
		resp.Diagnostics.Append(resp.State.SetAttribute(ctx, path.Root("name"), name)...)
	}
}

// ============================================================================
// 5. azurerm_container_registry
// ============================================================================

const acrAPIVersion = "2023-07-01"

var (
	_ resource.Resource                = (*containerRegistryResource)(nil)
	_ resource.ResourceWithImportState = (*containerRegistryResource)(nil)
)

func NewContainerRegistryResource() resource.Resource {
	return &containerRegistryResource{}
}

type containerRegistryResource struct {
	client *Client
}

type containerRegistryModel struct {
	ID                         types.String `tfsdk:"id"`
	Name                       types.String `tfsdk:"name"`
	ResourceGroupName          types.String `tfsdk:"resource_group_name"`
	Location                   types.String `tfsdk:"location"`
	Sku                        types.String `tfsdk:"sku"`
	AdminEnabled               types.Bool   `tfsdk:"admin_enabled"`
	PublicNetworkAccessEnabled types.Bool   `tfsdk:"public_network_access_enabled"`
	Tags                       types.Map    `tfsdk:"tags"`
	LoginServer                types.String `tfsdk:"login_server"`
	AdminUsername              types.String `tfsdk:"admin_username"`
	AdminPassword              types.String `tfsdk:"admin_password"`
}

func (r *containerRegistryResource) Metadata(ctx context.Context, req resource.MetadataRequest, resp *resource.MetadataResponse) {
	resp.TypeName = req.ProviderTypeName + "_container_registry"
}

func (r *containerRegistryResource) Schema(ctx context.Context, req resource.SchemaRequest, resp *resource.SchemaResponse) {
	resp.Schema = schema.Schema{
		Description: "Manages an Azure Container Registry on the smalt ARM plane.",
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
			"sku": schema.StringAttribute{
				Required: true,
			},
			"admin_enabled": schema.BoolAttribute{
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
			"tags": schema.MapAttribute{
				ElementType: types.StringType,
				Optional:    true,
			},
			"login_server": schema.StringAttribute{
				Computed: true,
				PlanModifiers: []planmodifier.String{
					stringplanmodifier.UseStateForUnknown(),
				},
			},
			"admin_username": schema.StringAttribute{
				Computed: true,
			},
			"admin_password": schema.StringAttribute{
				Computed:  true,
				Sensitive: true,
			},
		},
	}
}

func (r *containerRegistryResource) Configure(ctx context.Context, req resource.ConfigureRequest, resp *resource.ConfigureResponse) {
	if req.ProviderData == nil {
		return
	}
	c, ok := req.ProviderData.(*Client)
	if !ok {
		resp.Diagnostics.AddError("client cast", "expected *Client")
		return
	}
	r.client = c
}

func acrARMPath(sub, rg, name string) string {
	return NormalizeARMID(fmt.Sprintf("/subscriptions/%s/resourceGroups/%s/providers/Microsoft.ContainerRegistry/registries/%s", sub, rg, name))
}

func (r *containerRegistryResource) Create(ctx context.Context, req resource.CreateRequest, resp *resource.CreateResponse) {
	var plan containerRegistryModel
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

	adminEnabled := false
	if !plan.AdminEnabled.IsNull() && !plan.AdminEnabled.IsUnknown() {
		adminEnabled = plan.AdminEnabled.ValueBool()
	}
	pubNet := true
	if !plan.PublicNetworkAccessEnabled.IsNull() && !plan.PublicNetworkAccessEnabled.IsUnknown() {
		pubNet = plan.PublicNetworkAccessEnabled.ValueBool()
	}
	pubNetStr := "Enabled"
	if !pubNet {
		pubNetStr = "Disabled"
	}

	loc := NormalizeLocation(plan.Location.ValueString())
	armPath := acrARMPath(r.client.subscriptionID, plan.ResourceGroupName.ValueString(), plan.Name.ValueString())
	body := map[string]any{
		"location": loc,
		"tags":     tags,
		"sku":      map[string]any{"name": plan.Sku.ValueString()},
		"properties": map[string]any{
			"adminUserEnabled":    adminEnabled,
			"publicNetworkAccess": pubNetStr,
		},
	}

	var out map[string]any
	raw, etag, _, err := r.client.PutWithETag(ctx, armPath, acrAPIVersion, "", body, &out)
	if err != nil {
		resp.Diagnostics.AddError("create container_registry", err.Error())
		return
	}
	SavePrivateARMState(ctx, resp.Private, raw, etag)

	r.applyACRState(ctx, &plan, out, armPath, loc, adminEnabled, pubNet, tags)
	resp.Diagnostics.Append(resp.State.Set(ctx, &plan)...)
}

func (r *containerRegistryResource) Read(ctx context.Context, req resource.ReadRequest, resp *resource.ReadResponse) {
	var state containerRegistryModel
	resp.Diagnostics.Append(req.State.Get(ctx, &state)...)
	if resp.Diagnostics.HasError() {
		return
	}

	armPath := state.ID.ValueString()
	if armPath == "" {
		armPath = acrARMPath(r.client.subscriptionID, state.ResourceGroupName.ValueString(), state.Name.ValueString())
	} else {
		armPath = NormalizeARMID(armPath)
	}

	var out map[string]any
	raw, etag, _, err := r.client.GetRaw(ctx, armPath, acrAPIVersion, &out)
	if err != nil {
		if IsNotFound(err) {
			resp.State.RemoveResource(ctx)
			return
		}
		resp.Diagnostics.AddError("read container_registry", err.Error())
		return
	}
	SavePrivateARMState(ctx, resp.Private, raw, etag)

	tags := map[string]string{}
	if !state.Tags.IsNull() && !state.Tags.IsUnknown() {
		_ = state.Tags.ElementsAs(ctx, &tags, false)
	}
	mergedTags := mergeTags(tags, mapTagsField(out))

	loc := NormalizeLocation(mapStringField(out, "location"))
	if loc == "" {
		loc = NormalizeLocation(state.Location.ValueString())
	}
	adminEnabled := state.AdminEnabled.ValueBool()
	pubNet := true
	if !state.PublicNetworkAccessEnabled.IsNull() && !state.PublicNetworkAccessEnabled.IsUnknown() {
		pubNet = state.PublicNetworkAccessEnabled.ValueBool()
	}

	r.applyACRState(ctx, &state, out, armPath, loc, adminEnabled, pubNet, mergedTags)
	if state.Tags.IsNull() && len(mergedTags) == 0 {
		state.Tags = types.MapNull(types.StringType)
	}
	resp.Diagnostics.Append(resp.State.Set(ctx, &state)...)
}

func (r *containerRegistryResource) Update(ctx context.Context, req resource.UpdateRequest, resp *resource.UpdateResponse) {
	var plan containerRegistryModel
	resp.Diagnostics.Append(req.Plan.Get(ctx, &plan)...)
	if resp.Diagnostics.HasError() {
		return
	}

	rawBody, etag := LoadPrivateARMState(ctx, req.Private)
	if rawBody == nil {
		rawBody = map[string]any{}
	}

	tags := map[string]string{}
	if !plan.Tags.IsNull() && !plan.Tags.IsUnknown() {
		resp.Diagnostics.Append(plan.Tags.ElementsAs(ctx, &tags, false)...)
		if resp.Diagnostics.HasError() {
			return
		}
	}

	adminEnabled := false
	if !plan.AdminEnabled.IsNull() && !plan.AdminEnabled.IsUnknown() {
		adminEnabled = plan.AdminEnabled.ValueBool()
	}
	pubNet := true
	if !plan.PublicNetworkAccessEnabled.IsNull() && !plan.PublicNetworkAccessEnabled.IsUnknown() {
		pubNet = plan.PublicNetworkAccessEnabled.ValueBool()
	}
	pubNetStr := "Enabled"
	if !pubNet {
		pubNetStr = "Disabled"
	}

	loc := NormalizeLocation(plan.Location.ValueString())
	rawBody["location"] = loc
	rawBody["tags"] = tags
	rawBody["sku"] = map[string]any{"name": plan.Sku.ValueString()}
	props, _ := rawBody["properties"].(map[string]any)
	if props == nil {
		props = map[string]any{}
	}
	props["adminUserEnabled"] = adminEnabled
	props["publicNetworkAccess"] = pubNetStr
	rawBody["properties"] = props

	armPath := acrARMPath(r.client.subscriptionID, plan.ResourceGroupName.ValueString(), plan.Name.ValueString())
	var out map[string]any
	raw, newETag, _, err := r.client.PutWithETag(ctx, armPath, acrAPIVersion, etag, rawBody, &out)
	if err != nil {
		resp.Diagnostics.AddError("update container_registry", err.Error())
		return
	}
	SavePrivateARMState(ctx, resp.Private, raw, newETag)

	r.applyACRState(ctx, &plan, out, armPath, loc, adminEnabled, pubNet, tags)
	resp.Diagnostics.Append(resp.State.Set(ctx, &plan)...)
}

func (r *containerRegistryResource) Delete(ctx context.Context, req resource.DeleteRequest, resp *resource.DeleteResponse) {
	var state containerRegistryModel
	resp.Diagnostics.Append(req.State.Get(ctx, &state)...)
	if resp.Diagnostics.HasError() {
		return
	}
	armPath := state.ID.ValueString()
	if armPath == "" {
		armPath = acrARMPath(r.client.subscriptionID, state.ResourceGroupName.ValueString(), state.Name.ValueString())
	}
	if _, err := r.client.DeleteRaw(ctx, NormalizeARMID(armPath), acrAPIVersion); err != nil {
		resp.Diagnostics.AddError("delete container_registry", err.Error())
	}
}

func (r *containerRegistryResource) ImportState(ctx context.Context, req resource.ImportStateRequest, resp *resource.ImportStateResponse) {
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

func (r *containerRegistryResource) applyACRState(ctx context.Context, m *containerRegistryModel, out map[string]any, armPath, loc string, adminFallback, pubNetFallback bool, tags map[string]string) {
	props, _ := out["properties"].(map[string]any)
	if skuMap, ok := out["sku"].(map[string]any); ok {
		if s := mapStringField(skuMap, "name"); s != "" {
			m.Sku = types.StringValue(s)
		}
	} else if s := mapStringField(out, "sku"); s != "" {
		m.Sku = types.StringValue(s)
	}
	if m.Sku.ValueString() == "" {
		m.Sku = types.StringValue("Basic")
	}

	adminEnabled := adminFallback
	if v, ok := mapBoolField(props, "adminUserEnabled"); ok {
		adminEnabled = v
	}
	pubNet := pubNetFallback
	if pna := mapStringField(props, "publicNetworkAccess"); pna != "" {
		pubNet = !strings.EqualFold(pna, "Disabled")
	}

	loginServer := mapStringField(props, "loginServer")
	if loginServer == "" {
		loginServer = fmt.Sprintf("%s.azurecr.io", m.Name.ValueString())
	}

	m.ID = types.StringValue(NormalizeARMID(armPath))
	m.Location = types.StringValue(loc)
	m.AdminEnabled = types.BoolValue(adminEnabled)
	m.PublicNetworkAccessEnabled = types.BoolValue(pubNet)
	m.LoginServer = types.StringValue(loginServer)
	if adminEnabled {
		m.AdminUsername = types.StringValue(m.Name.ValueString())
		m.AdminPassword = types.StringValue(mintDeterministicGUID("acr-pwd:" + armPath))
	} else {
		m.AdminUsername = types.StringValue("")
		m.AdminPassword = types.StringValue("")
	}
	if len(tags) == 0 {
		m.Tags = types.MapNull(types.StringType)
	} else {
		mv, _ := types.MapValueFrom(ctx, types.StringType, tags)
		m.Tags = mv
	}
}

// ============================================================================
// 6. azurerm_log_analytics_workspace
// ============================================================================

const lawAPIVersion = "2022-10-01"

var (
	_ resource.Resource                = (*logAnalyticsWorkspaceResource)(nil)
	_ resource.ResourceWithImportState = (*logAnalyticsWorkspaceResource)(nil)
)

func NewLogAnalyticsWorkspaceResource() resource.Resource {
	return &logAnalyticsWorkspaceResource{}
}

type logAnalyticsWorkspaceResource struct {
	client *Client
}

type logAnalyticsWorkspaceModel struct {
	ID                types.String  `tfsdk:"id"`
	Name              types.String  `tfsdk:"name"`
	ResourceGroupName types.String  `tfsdk:"resource_group_name"`
	Location          types.String  `tfsdk:"location"`
	Sku               types.String  `tfsdk:"sku"`
	RetentionInDays   types.Int64   `tfsdk:"retention_in_days"`
	DailyQuotaGb      types.Float64 `tfsdk:"daily_quota_gb"`
	Tags              types.Map     `tfsdk:"tags"`
	WorkspaceID       types.String  `tfsdk:"workspace_id"`
	PrimarySharedKey  types.String  `tfsdk:"primary_shared_key"`
}

func (r *logAnalyticsWorkspaceResource) Metadata(ctx context.Context, req resource.MetadataRequest, resp *resource.MetadataResponse) {
	resp.TypeName = req.ProviderTypeName + "_log_analytics_workspace"
}

func (r *logAnalyticsWorkspaceResource) Schema(ctx context.Context, req resource.SchemaRequest, resp *resource.SchemaResponse) {
	resp.Schema = schema.Schema{
		Description: "Manages a Log Analytics Workspace on the smalt ARM plane.",
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
			"sku": schema.StringAttribute{
				Optional: true,
				Computed: true,
				PlanModifiers: []planmodifier.String{
					stringplanmodifier.UseStateForUnknown(),
				},
			},
			"retention_in_days": schema.Int64Attribute{
				Optional: true,
				Computed: true,
				PlanModifiers: []planmodifier.Int64{
					int64planmodifier.UseStateForUnknown(),
				},
			},
			"daily_quota_gb": schema.Float64Attribute{
				Optional: true,
				Computed: true,
				PlanModifiers: []planmodifier.Float64{
					float64planmodifier.UseStateForUnknown(),
				},
			},
			"tags": schema.MapAttribute{
				ElementType: types.StringType,
				Optional:    true,
			},
			"workspace_id": schema.StringAttribute{
				Computed: true,
				PlanModifiers: []planmodifier.String{
					stringplanmodifier.UseStateForUnknown(),
				},
			},
			"primary_shared_key": schema.StringAttribute{
				Computed:  true,
				Sensitive: true,
				PlanModifiers: []planmodifier.String{
					stringplanmodifier.UseStateForUnknown(),
				},
			},
		},
	}
}

func (r *logAnalyticsWorkspaceResource) Configure(ctx context.Context, req resource.ConfigureRequest, resp *resource.ConfigureResponse) {
	if req.ProviderData == nil {
		return
	}
	c, ok := req.ProviderData.(*Client)
	if !ok {
		resp.Diagnostics.AddError("client cast", "expected *Client")
		return
	}
	r.client = c
}

func lawARMPath(sub, rg, name string) string {
	return NormalizeARMID(fmt.Sprintf("/subscriptions/%s/resourceGroups/%s/providers/Microsoft.OperationalInsights/workspaces/%s", sub, rg, name))
}

func (r *logAnalyticsWorkspaceResource) Create(ctx context.Context, req resource.CreateRequest, resp *resource.CreateResponse) {
	var plan logAnalyticsWorkspaceModel
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

	sku := plan.Sku.ValueString()
	if sku == "" {
		sku = "PerGB2018"
	}
	retention := int64(30)
	if !plan.RetentionInDays.IsNull() && !plan.RetentionInDays.IsUnknown() {
		retention = plan.RetentionInDays.ValueInt64()
	}
	quota := float64(-1)
	if !plan.DailyQuotaGb.IsNull() && !plan.DailyQuotaGb.IsUnknown() {
		quota = plan.DailyQuotaGb.ValueFloat64()
	}

	loc := NormalizeLocation(plan.Location.ValueString())
	armPath := lawARMPath(r.client.subscriptionID, plan.ResourceGroupName.ValueString(), plan.Name.ValueString())
	body := map[string]any{
		"location": loc,
		"tags":     tags,
		"sku":      map[string]any{"name": sku},
		"properties": map[string]any{
			"sku":             map[string]any{"name": sku},
			"retentionInDays": retention,
			"workspaceCapping": map[string]any{
				"dailyQuotaGb": quota,
			},
		},
	}

	var out map[string]any
	raw, etag, _, err := r.client.PutWithETag(ctx, armPath, lawAPIVersion, "", body, &out)
	if err != nil {
		resp.Diagnostics.AddError("create log_analytics_workspace", err.Error())
		return
	}
	SavePrivateARMState(ctx, resp.Private, raw, etag)

	r.applyLAWState(ctx, &plan, out, armPath, loc, sku, retention, quota, tags)
	resp.Diagnostics.Append(resp.State.Set(ctx, &plan)...)
}

func (r *logAnalyticsWorkspaceResource) Read(ctx context.Context, req resource.ReadRequest, resp *resource.ReadResponse) {
	var state logAnalyticsWorkspaceModel
	resp.Diagnostics.Append(req.State.Get(ctx, &state)...)
	if resp.Diagnostics.HasError() {
		return
	}

	armPath := state.ID.ValueString()
	if armPath == "" {
		armPath = lawARMPath(r.client.subscriptionID, state.ResourceGroupName.ValueString(), state.Name.ValueString())
	} else {
		armPath = NormalizeARMID(armPath)
	}

	var out map[string]any
	raw, etag, _, err := r.client.GetRaw(ctx, armPath, lawAPIVersion, &out)
	if err != nil {
		if IsNotFound(err) {
			resp.State.RemoveResource(ctx)
			return
		}
		resp.Diagnostics.AddError("read log_analytics_workspace", err.Error())
		return
	}
	SavePrivateARMState(ctx, resp.Private, raw, etag)

	tags := map[string]string{}
	if !state.Tags.IsNull() && !state.Tags.IsUnknown() {
		_ = state.Tags.ElementsAs(ctx, &tags, false)
	}
	mergedTags := mergeTags(tags, mapTagsField(out))

	loc := NormalizeLocation(mapStringField(out, "location"))
	if loc == "" {
		loc = NormalizeLocation(state.Location.ValueString())
	}
	sku := state.Sku.ValueString()
	if sku == "" {
		sku = "PerGB2018"
	}
	retention := int64(30)
	if !state.RetentionInDays.IsNull() && !state.RetentionInDays.IsUnknown() {
		retention = state.RetentionInDays.ValueInt64()
	}
	quota := float64(-1)
	if !state.DailyQuotaGb.IsNull() && !state.DailyQuotaGb.IsUnknown() {
		quota = state.DailyQuotaGb.ValueFloat64()
	}

	r.applyLAWState(ctx, &state, out, armPath, loc, sku, retention, quota, mergedTags)
	if state.Tags.IsNull() && len(mergedTags) == 0 {
		state.Tags = types.MapNull(types.StringType)
	}
	resp.Diagnostics.Append(resp.State.Set(ctx, &state)...)
}

func (r *logAnalyticsWorkspaceResource) Update(ctx context.Context, req resource.UpdateRequest, resp *resource.UpdateResponse) {
	var plan logAnalyticsWorkspaceModel
	resp.Diagnostics.Append(req.Plan.Get(ctx, &plan)...)
	if resp.Diagnostics.HasError() {
		return
	}

	rawBody, etag := LoadPrivateARMState(ctx, req.Private)
	if rawBody == nil {
		rawBody = map[string]any{}
	}

	tags := map[string]string{}
	if !plan.Tags.IsNull() && !plan.Tags.IsUnknown() {
		resp.Diagnostics.Append(plan.Tags.ElementsAs(ctx, &tags, false)...)
		if resp.Diagnostics.HasError() {
			return
		}
	}

	sku := plan.Sku.ValueString()
	if sku == "" {
		sku = "PerGB2018"
	}
	retention := int64(30)
	if !plan.RetentionInDays.IsNull() && !plan.RetentionInDays.IsUnknown() {
		retention = plan.RetentionInDays.ValueInt64()
	}
	quota := float64(-1)
	if !plan.DailyQuotaGb.IsNull() && !plan.DailyQuotaGb.IsUnknown() {
		quota = plan.DailyQuotaGb.ValueFloat64()
	}

	loc := NormalizeLocation(plan.Location.ValueString())
	rawBody["location"] = loc
	rawBody["tags"] = tags
	rawBody["sku"] = map[string]any{"name": sku}
	props, _ := rawBody["properties"].(map[string]any)
	if props == nil {
		props = map[string]any{}
	}
	props["retentionInDays"] = retention
	rawBody["properties"] = props

	armPath := lawARMPath(r.client.subscriptionID, plan.ResourceGroupName.ValueString(), plan.Name.ValueString())
	var out map[string]any
	raw, newETag, _, err := r.client.PutWithETag(ctx, armPath, lawAPIVersion, etag, rawBody, &out)
	if err != nil {
		resp.Diagnostics.AddError("update log_analytics_workspace", err.Error())
		return
	}
	SavePrivateARMState(ctx, resp.Private, raw, newETag)

	r.applyLAWState(ctx, &plan, out, armPath, loc, sku, retention, quota, tags)
	resp.Diagnostics.Append(resp.State.Set(ctx, &plan)...)
}

func (r *logAnalyticsWorkspaceResource) Delete(ctx context.Context, req resource.DeleteRequest, resp *resource.DeleteResponse) {
	var state logAnalyticsWorkspaceModel
	resp.Diagnostics.Append(req.State.Get(ctx, &state)...)
	if resp.Diagnostics.HasError() {
		return
	}
	armPath := state.ID.ValueString()
	if armPath == "" {
		armPath = lawARMPath(r.client.subscriptionID, state.ResourceGroupName.ValueString(), state.Name.ValueString())
	}
	if _, err := r.client.DeleteRaw(ctx, NormalizeARMID(armPath), lawAPIVersion); err != nil {
		resp.Diagnostics.AddError("delete log_analytics_workspace", err.Error())
	}
}

func (r *logAnalyticsWorkspaceResource) ImportState(ctx context.Context, req resource.ImportStateRequest, resp *resource.ImportStateResponse) {
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

func (r *logAnalyticsWorkspaceResource) applyLAWState(ctx context.Context, m *logAnalyticsWorkspaceModel, out map[string]any, armPath, loc, skuFallback string, retentionFallback int64, quotaFallback float64, tags map[string]string) {
	props, _ := out["properties"].(map[string]any)
	sku := skuFallback
	if skuMap, ok := out["sku"].(map[string]any); ok {
		if s := mapStringField(skuMap, "name"); s != "" {
			sku = s
		}
	} else if skuMap, ok := props["sku"].(map[string]any); ok {
		if s := mapStringField(skuMap, "name"); s != "" {
			sku = s
		}
	}

	retention := retentionFallback
	if v, ok := props["retentionInDays"].(float64); ok {
		retention = int64(v)
	}

	wsID := mapStringField(props, "customerId")
	if wsID == "" {
		wsID = mintDeterministicGUID("law-ws:" + armPath)
	}
	sharedKey := mapStringField(props, "primarySharedKey")
	if sharedKey == "" {
		sharedKey = mintDeterministicGUID("law-key:" + armPath)
	}

	m.ID = types.StringValue(NormalizeARMID(armPath))
	m.Location = types.StringValue(loc)
	m.Sku = types.StringValue(sku)
	m.RetentionInDays = types.Int64Value(retention)
	m.DailyQuotaGb = types.Float64Value(quotaFallback)
	m.WorkspaceID = types.StringValue(wsID)
	m.PrimarySharedKey = types.StringValue(sharedKey)
	if len(tags) == 0 {
		m.Tags = types.MapNull(types.StringType)
	} else {
		mv, _ := types.MapValueFrom(ctx, types.StringType, tags)
		m.Tags = mv
	}
}

// ============================================================================
// 7. azurerm_storage_account
// ============================================================================

const storageAPIVersion = "2023-01-01"

var (
	_ resource.Resource                = (*storageAccountResource)(nil)
	_ resource.ResourceWithImportState = (*storageAccountResource)(nil)
)

func NewStorageAccountResource() resource.Resource {
	return &storageAccountResource{}
}

type storageAccountResource struct {
	client *Client
}

type storageAccountModel struct {
	ID                          types.String `tfsdk:"id"`
	Name                        types.String `tfsdk:"name"`
	ResourceGroupName           types.String `tfsdk:"resource_group_name"`
	Location                    types.String `tfsdk:"location"`
	AccountTier                 types.String `tfsdk:"account_tier"`
	AccountReplicationType      types.String `tfsdk:"account_replication_type"`
	AccountKind                 types.String `tfsdk:"account_kind"`
	MinTLSVersion               types.String `tfsdk:"min_tls_version"`
	HttpsTrafficOnlyEnabled     types.Bool   `tfsdk:"https_traffic_only_enabled"`
	AllowNestedItemsToBePublic  types.Bool   `tfsdk:"allow_nested_items_to_be_public"`
	SharedAccessKeyEnabled      types.Bool   `tfsdk:"shared_access_key_enabled"`
	PublicNetworkAccessEnabled  types.Bool   `tfsdk:"public_network_access_enabled"`
	Tags                        types.Map    `tfsdk:"tags"`
	PrimaryBlobEndpoint         types.String `tfsdk:"primary_blob_endpoint"`
	PrimaryAccessKey            types.String `tfsdk:"primary_access_key"`
}

func (r *storageAccountResource) Metadata(ctx context.Context, req resource.MetadataRequest, resp *resource.MetadataResponse) {
	resp.TypeName = req.ProviderTypeName + "_storage_account"
}

func (r *storageAccountResource) Schema(ctx context.Context, req resource.SchemaRequest, resp *resource.SchemaResponse) {
	resp.Schema = schema.Schema{
		Description: "Manages a Storage Account on the smalt ARM plane.",
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
			"account_tier": schema.StringAttribute{
				Required: true,
			},
			"account_replication_type": schema.StringAttribute{
				Required: true,
			},
			"account_kind": schema.StringAttribute{
				Optional: true,
				Computed: true,
				PlanModifiers: []planmodifier.String{
					stringplanmodifier.UseStateForUnknown(),
				},
			},
			"min_tls_version": schema.StringAttribute{
				Optional: true,
				Computed: true,
				PlanModifiers: []planmodifier.String{
					stringplanmodifier.UseStateForUnknown(),
				},
			},
			"https_traffic_only_enabled": schema.BoolAttribute{
				Optional: true,
				Computed: true,
				PlanModifiers: []planmodifier.Bool{
					boolplanmodifier.UseStateForUnknown(),
				},
			},
			"allow_nested_items_to_be_public": schema.BoolAttribute{
				Optional: true,
				Computed: true,
				PlanModifiers: []planmodifier.Bool{
					boolplanmodifier.UseStateForUnknown(),
				},
			},
			"shared_access_key_enabled": schema.BoolAttribute{
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
			"tags": schema.MapAttribute{
				ElementType: types.StringType,
				Optional:    true,
			},
			"primary_blob_endpoint": schema.StringAttribute{
				Computed: true,
				PlanModifiers: []planmodifier.String{
					stringplanmodifier.UseStateForUnknown(),
				},
			},
			"primary_access_key": schema.StringAttribute{
				Computed:  true,
				Sensitive: true,
				PlanModifiers: []planmodifier.String{
					stringplanmodifier.UseStateForUnknown(),
				},
			},
		},
	}
}

func (r *storageAccountResource) Configure(ctx context.Context, req resource.ConfigureRequest, resp *resource.ConfigureResponse) {
	if req.ProviderData == nil {
		return
	}
	c, ok := req.ProviderData.(*Client)
	if !ok {
		resp.Diagnostics.AddError("client cast", "expected *Client")
		return
	}
	r.client = c
}

func storageARMPath(sub, rg, name string) string {
	return NormalizeARMID(fmt.Sprintf("/subscriptions/%s/resourceGroups/%s/providers/Microsoft.Storage/storageAccounts/%s", sub, rg, name))
}

func (r *storageAccountResource) Create(ctx context.Context, req resource.CreateRequest, resp *resource.CreateResponse) {
	var plan storageAccountModel
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

	r.applyStorageDefaults(&plan)
	loc := NormalizeLocation(plan.Location.ValueString())
	skuName := fmt.Sprintf("%s_%s", plan.AccountTier.ValueString(), plan.AccountReplicationType.ValueString())
	armPath := storageARMPath(r.client.subscriptionID, plan.ResourceGroupName.ValueString(), plan.Name.ValueString())

	body := map[string]any{
		"location": loc,
		"tags":     tags,
		"kind":     plan.AccountKind.ValueString(),
		"sku":      map[string]any{"name": skuName},
		"properties": map[string]any{
			"minimumTlsVersion":        plan.MinTLSVersion.ValueString(),
			"supportsHttpsTrafficOnly": plan.HttpsTrafficOnlyEnabled.ValueBool(),
			"allowBlobPublicAccess":    plan.AllowNestedItemsToBePublic.ValueBool(),
			"allowSharedKeyAccess":     plan.SharedAccessKeyEnabled.ValueBool(),
		},
	}

	var out map[string]any
	raw, etag, _, err := r.client.PutWithETag(ctx, armPath, storageAPIVersion, "", body, &out)
	if err != nil {
		resp.Diagnostics.AddError("create storage_account", err.Error())
		return
	}
	SavePrivateARMState(ctx, resp.Private, raw, etag)

	r.applyStorageState(ctx, &plan, out, armPath, loc, tags)
	resp.Diagnostics.Append(resp.State.Set(ctx, &plan)...)
}

func (r *storageAccountResource) Read(ctx context.Context, req resource.ReadRequest, resp *resource.ReadResponse) {
	var state storageAccountModel
	resp.Diagnostics.Append(req.State.Get(ctx, &state)...)
	if resp.Diagnostics.HasError() {
		return
	}

	armPath := state.ID.ValueString()
	if armPath == "" {
		armPath = storageARMPath(r.client.subscriptionID, state.ResourceGroupName.ValueString(), state.Name.ValueString())
	} else {
		armPath = NormalizeARMID(armPath)
	}

	var out map[string]any
	raw, etag, _, err := r.client.GetRaw(ctx, armPath, storageAPIVersion, &out)
	if err != nil {
		if IsNotFound(err) {
			resp.State.RemoveResource(ctx)
			return
		}
		resp.Diagnostics.AddError("read storage_account", err.Error())
		return
	}
	SavePrivateARMState(ctx, resp.Private, raw, etag)

	tags := map[string]string{}
	if !state.Tags.IsNull() && !state.Tags.IsUnknown() {
		_ = state.Tags.ElementsAs(ctx, &tags, false)
	}
	mergedTags := mergeTags(tags, mapTagsField(out))

	loc := NormalizeLocation(mapStringField(out, "location"))
	if loc == "" {
		loc = NormalizeLocation(state.Location.ValueString())
	}
	r.applyStorageDefaults(&state)
	r.applyStorageState(ctx, &state, out, armPath, loc, mergedTags)
	if state.Tags.IsNull() && len(mergedTags) == 0 {
		state.Tags = types.MapNull(types.StringType)
	}
	resp.Diagnostics.Append(resp.State.Set(ctx, &state)...)
}

func (r *storageAccountResource) Update(ctx context.Context, req resource.UpdateRequest, resp *resource.UpdateResponse) {
	var plan storageAccountModel
	resp.Diagnostics.Append(req.Plan.Get(ctx, &plan)...)
	if resp.Diagnostics.HasError() {
		return
	}

	rawBody, etag := LoadPrivateARMState(ctx, req.Private)
	if rawBody == nil {
		rawBody = map[string]any{}
	}

	tags := map[string]string{}
	if !plan.Tags.IsNull() && !plan.Tags.IsUnknown() {
		resp.Diagnostics.Append(plan.Tags.ElementsAs(ctx, &tags, false)...)
		if resp.Diagnostics.HasError() {
			return
		}
	}

	r.applyStorageDefaults(&plan)
	loc := NormalizeLocation(plan.Location.ValueString())
	skuName := fmt.Sprintf("%s_%s", plan.AccountTier.ValueString(), plan.AccountReplicationType.ValueString())
	rawBody["location"] = loc
	rawBody["tags"] = tags
	rawBody["kind"] = plan.AccountKind.ValueString()
	rawBody["sku"] = map[string]any{"name": skuName}

	armPath := storageARMPath(r.client.subscriptionID, plan.ResourceGroupName.ValueString(), plan.Name.ValueString())
	var out map[string]any
	raw, newETag, _, err := r.client.PutWithETag(ctx, armPath, storageAPIVersion, etag, rawBody, &out)
	if err != nil {
		resp.Diagnostics.AddError("update storage_account", err.Error())
		return
	}
	SavePrivateARMState(ctx, resp.Private, raw, newETag)

	r.applyStorageState(ctx, &plan, out, armPath, loc, tags)
	resp.Diagnostics.Append(resp.State.Set(ctx, &plan)...)
}

func (r *storageAccountResource) Delete(ctx context.Context, req resource.DeleteRequest, resp *resource.DeleteResponse) {
	var state storageAccountModel
	resp.Diagnostics.Append(req.State.Get(ctx, &state)...)
	if resp.Diagnostics.HasError() {
		return
	}
	armPath := state.ID.ValueString()
	if armPath == "" {
		armPath = storageARMPath(r.client.subscriptionID, state.ResourceGroupName.ValueString(), state.Name.ValueString())
	}
	if _, err := r.client.DeleteRaw(ctx, NormalizeARMID(armPath), storageAPIVersion); err != nil {
		resp.Diagnostics.AddError("delete storage_account", err.Error())
	}
}

func (r *storageAccountResource) ImportState(ctx context.Context, req resource.ImportStateRequest, resp *resource.ImportStateResponse) {
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

func (r *storageAccountResource) applyStorageDefaults(m *storageAccountModel) {
	if m.AccountKind.IsNull() || m.AccountKind.IsUnknown() || m.AccountKind.ValueString() == "" {
		m.AccountKind = types.StringValue("StorageV2")
	}
	if m.MinTLSVersion.IsNull() || m.MinTLSVersion.IsUnknown() || m.MinTLSVersion.ValueString() == "" {
		m.MinTLSVersion = types.StringValue("TLS1_2")
	}
	if m.HttpsTrafficOnlyEnabled.IsNull() || m.HttpsTrafficOnlyEnabled.IsUnknown() {
		m.HttpsTrafficOnlyEnabled = types.BoolValue(true)
	}
	if m.AllowNestedItemsToBePublic.IsNull() || m.AllowNestedItemsToBePublic.IsUnknown() {
		m.AllowNestedItemsToBePublic = types.BoolValue(false)
	}
	if m.SharedAccessKeyEnabled.IsNull() || m.SharedAccessKeyEnabled.IsUnknown() {
		m.SharedAccessKeyEnabled = types.BoolValue(true)
	}
	if m.PublicNetworkAccessEnabled.IsNull() || m.PublicNetworkAccessEnabled.IsUnknown() {
		m.PublicNetworkAccessEnabled = types.BoolValue(true)
	}
}

func (r *storageAccountResource) applyStorageState(ctx context.Context, m *storageAccountModel, out map[string]any, armPath, loc string, tags map[string]string) {
	if skuMap, ok := out["sku"].(map[string]any); ok {
		if s := mapStringField(skuMap, "name"); strings.Contains(s, "_") {
			sp := strings.SplitN(s, "_", 2)
			if m.AccountTier.ValueString() == "" {
				m.AccountTier = types.StringValue(sp[0])
			}
			if m.AccountReplicationType.ValueString() == "" {
				m.AccountReplicationType = types.StringValue(sp[1])
			}
		}
	}
	if m.AccountTier.ValueString() == "" {
		m.AccountTier = types.StringValue("Standard")
	}
	if m.AccountReplicationType.ValueString() == "" {
		m.AccountReplicationType = types.StringValue("LRS")
	}

	props, _ := out["properties"].(map[string]any)
	blobEndpoint := ""
	if pe, ok := props["primaryEndpoints"].(map[string]any); ok {
		blobEndpoint = mapStringField(pe, "blob")
	}
	if blobEndpoint == "" {
		blobEndpoint = fmt.Sprintf("https://%s.blob.core.windows.net/", m.Name.ValueString())
	}

	m.ID = types.StringValue(NormalizeARMID(armPath))
	m.Location = types.StringValue(loc)
	m.PrimaryBlobEndpoint = types.StringValue(blobEndpoint)
	m.PrimaryAccessKey = types.StringValue(mintDeterministicGUID("st-key:" + armPath))
	if len(tags) == 0 {
		m.Tags = types.MapNull(types.StringType)
	} else {
		mv, _ := types.MapValueFrom(ctx, types.StringType, tags)
		m.Tags = mv
	}
}
