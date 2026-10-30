package provider

import (
	"context"
	"fmt"
	"net/http"
	"strings"

	"github.com/hashicorp/terraform-plugin-framework/diag"
	"github.com/hashicorp/terraform-plugin-framework/resource"
	"github.com/hashicorp/terraform-plugin-framework/path"
	"github.com/hashicorp/terraform-plugin-framework/resource/schema"
	"github.com/hashicorp/terraform-plugin-framework/resource/schema/planmodifier"
	"github.com/hashicorp/terraform-plugin-framework/resource/schema/stringplanmodifier"
	"github.com/hashicorp/terraform-plugin-framework/schema/validator"
	"github.com/hashicorp/terraform-plugin-framework/types"

	"github.com/hashicorp/terraform-plugin-framework-validators/stringvalidator"
)

var (
	_ resource.Resource                = (*resourceGroupResource)(nil)
	_ resource.ResourceWithImportState = (*resourceGroupResource)(nil)
)

func NewResourceGroupResource() resource.Resource {
	return &resourceGroupResource{}
}

type resourceGroupResource struct {
	client *Client
}

type resourceGroupModel struct {
	ID       types.String `tfsdk:"id"`
	Name     types.String `tfsdk:"name"`
	Location types.String `tfsdk:"location"`
	Tags     types.Map    `tfsdk:"tags"`
}

func (r *resourceGroupResource) Metadata(ctx context.Context, req resource.MetadataRequest, resp *resource.MetadataResponse) {
	resp.TypeName = req.ProviderTypeName + "_resource_group"
}

func (r *resourceGroupResource) Schema(ctx context.Context, req resource.SchemaRequest, resp *resource.SchemaResponse) {
	resp.Schema = schema.Schema{
		Description:         "Manages a resource group on the smalt ARM plane (azurerm azurerm_resource_group parity).",
		MarkdownDescription: "Manages a resource group on the smalt ARM plane (azurerm `azurerm_resource_group` parity).",
		Attributes: map[string]schema.Attribute{
			"name": schema.StringAttribute{
				Required:            true,
				Description:         "Resource group name (1-90 characters).",
				MarkdownDescription: "Resource group name (1-90 characters). Changing the name forces creation of a new resource group.",
				Validators: []validator.String{
					stringvalidator.LengthBetween(1, 90),
				},
				PlanModifiers: []planmodifier.String{
					stringplanmodifier.RequiresReplace(),
				},
			},
			"location": schema.StringAttribute{
				Required:            true,
				Description:         "Azure region for the resource group (e.g. `westus2`).",
				MarkdownDescription: "Azure region for the resource group (e.g. `westus2`).",
				Validators: []validator.String{
					stringvalidator.LengthAtLeast(1),
				},
				PlanModifiers: []planmodifier.String{
					stringplanmodifier.RequiresReplace(),
				},
			},
			"tags": schema.MapAttribute{
				ElementType:         types.StringType,
				Optional:            true,
				Description:         "Mapping of tags to assign to the resource group.",
				MarkdownDescription: "Mapping of tags to assign to the resource group.",
			},
			"id": schema.StringAttribute{
				Computed:            true,
				Description:         "Azure resource ID: `/subscriptions/{sub}/resourceGroups/{name}`.",
				MarkdownDescription: "Azure resource ID: `/subscriptions/{subscription_id}/resourceGroups/{name}`.",
				PlanModifiers: []planmodifier.String{
					stringplanmodifier.UseStateForUnknown(),
				},
			},
		},
	}
}

func (r *resourceGroupResource) Configure(ctx context.Context, req resource.ConfigureRequest, resp *resource.ConfigureResponse) {
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

func rgID(subscriptionID, name string) string {
	return NormalizeARMID(fmt.Sprintf("/subscriptions/%s/resourceGroups/%s", subscriptionID, name))
}

func (r *resourceGroupResource) Create(ctx context.Context, req resource.CreateRequest, resp *resource.CreateResponse) {
	var plan resourceGroupModel
	resp.Diagnostics.Append(req.Plan.Get(ctx, &plan)...)
	if resp.Diagnostics.HasError() {
		return
	}
	tags := map[string]string{}
	resp.Diagnostics.Append(plan.Tags.ElementsAs(ctx, &tags, false)...)
	if resp.Diagnostics.HasError() {
		return
	}

	loc := NormalizeLocation(plan.Location.ValueString())
	path := fmt.Sprintf("/subscriptions/%s/resourcegroups/%s", r.client.subscriptionID, plan.Name.ValueString())
	body := resourceGroupBody{Name: plan.Name.ValueString(), Location: loc, Tags: tags}
	var rg resourceGroupBody
	raw, etag, _, err := r.client.PutWithETag(ctx, path, rgAPIVersion, "", body, &rg)
	if err != nil {
		resp.Diagnostics.AddError("create resource group", err.Error())
		return
	}
	SavePrivateARMState(ctx, resp.Private, raw, etag)

	plan.ID = types.StringValue(rgID(r.client.subscriptionID, plan.Name.ValueString()))
	normLoc := NormalizeLocation(rg.Location)
	if normLoc != "" && (plan.Location.IsNull() || plan.Location.IsUnknown() || NormalizeLocation(plan.Location.ValueString()) != normLoc || plan.Location.ValueString() == normLoc) {
		plan.Location = types.StringValue(normLoc)
	}
	plan.Tags = tagsValue(ctx, &resp.Diagnostics, tags)
	resp.Diagnostics.Append(resp.State.Set(ctx, &plan)...)
}

func (r *resourceGroupResource) Read(ctx context.Context, req resource.ReadRequest, resp *resource.ReadResponse) {
	var state resourceGroupModel
	resp.Diagnostics.Append(req.State.Get(ctx, &state)...)
	if resp.Diagnostics.HasError() {
		return
	}
	path := fmt.Sprintf("/subscriptions/%s/resourcegroups/%s", r.client.subscriptionID, state.Name.ValueString())
	var rg resourceGroupBody
	raw, etag, status, err := r.client.GetRaw(ctx, path, rgAPIVersion, &rg)
	if err != nil {
		if status == http.StatusNotFound || IsNotFound(err) {
			resp.State.RemoveResource(ctx)
			return
		}
		resp.Diagnostics.AddError("read resource group", err.Error())
		return
	}
	SavePrivateARMState(ctx, resp.Private, raw, etag)

	state.ID = types.StringValue(rgID(r.client.subscriptionID, state.Name.ValueString()))
	normLoc := NormalizeLocation(rg.Location)
	if normLoc != "" && (state.Location.IsNull() || state.Location.IsUnknown() || NormalizeLocation(state.Location.ValueString()) != normLoc || state.Location.ValueString() == normLoc) {
		state.Location = types.StringValue(normLoc)
	}
	tags := map[string]string{}
	if state.Tags.IsNull() {
		state.Tags = types.MapNull(types.StringType)
	} else {
		state.Tags.ElementsAs(ctx, &tags, false)
	}
	merged := mergeTags(tags, rg.Tags)
	state.Tags = tagsValue(ctx, &resp.Diagnostics, merged)
	resp.Diagnostics.Append(resp.State.Set(ctx, &state)...)
}

func (r *resourceGroupResource) Update(ctx context.Context, req resource.UpdateRequest, resp *resource.UpdateResponse) {
	var plan resourceGroupModel
	resp.Diagnostics.Append(req.Plan.Get(ctx, &plan)...)
	if resp.Diagnostics.HasError() {
		return
	}
	tags := map[string]string{}
	resp.Diagnostics.Append(plan.Tags.ElementsAs(ctx, &tags, false)...)
	if resp.Diagnostics.HasError() {
		return
	}

	rawMap, etag := LoadPrivateARMState(ctx, req.Private)
	if rawMap == nil {
		rawMap = map[string]any{}
	}
	loc := NormalizeLocation(plan.Location.ValueString())
	rawMap["name"] = plan.Name.ValueString()
	rawMap["location"] = loc
	if len(tags) > 0 {
		rawMap["tags"] = tags
	} else {
		delete(rawMap, "tags")
	}

	path := fmt.Sprintf("/subscriptions/%s/resourcegroups/%s", r.client.subscriptionID, plan.Name.ValueString())
	var rg resourceGroupBody
	raw, newETag, _, err := r.client.PutWithETag(ctx, path, rgAPIVersion, etag, rawMap, &rg)
	if err != nil {
		resp.Diagnostics.AddError("update resource group", err.Error())
		return
	}
	SavePrivateARMState(ctx, resp.Private, raw, newETag)

	plan.ID = types.StringValue(rgID(r.client.subscriptionID, plan.Name.ValueString()))
	normLoc := NormalizeLocation(rg.Location)
	if normLoc != "" && (plan.Location.IsNull() || plan.Location.IsUnknown() || NormalizeLocation(plan.Location.ValueString()) != normLoc || plan.Location.ValueString() == normLoc) {
		plan.Location = types.StringValue(normLoc)
	}
	plan.Tags = tagsValue(ctx, &resp.Diagnostics, tags)
	resp.Diagnostics.Append(resp.State.Set(ctx, &plan)...)
}

func (r *resourceGroupResource) Delete(ctx context.Context, req resource.DeleteRequest, resp *resource.DeleteResponse) {
	var state resourceGroupModel
	resp.Diagnostics.Append(req.State.Get(ctx, &state)...)
	if resp.Diagnostics.HasError() {
		return
	}
	if err := r.client.DeleteResourceGroup(ctx, state.Name.ValueString()); err != nil {
		resp.Diagnostics.AddError("delete resource group", err.Error())
		return
	}
}

// ImportState (GAP22-1) accepts either a bare resource group name or a full
// ARM id /subscriptions/{sub}/resourceGroups/{name} (NormalizeARMID-tolerant
// for casing). RG ids never carry a "providers/" segment — a resource-in-group
// id is refused with a typed error (GAP22-3), never silently adopted.
func (r *resourceGroupResource) ImportState(ctx context.Context, req resource.ImportStateRequest, resp *resource.ImportStateResponse) {
	id := NormalizeARMID(req.ID)
	if !strings.HasPrefix(id, "/") {
		// Bare resource group name: build the canonical id from the
		// configured subscription.
		sub := ""
		if r.client != nil {
			sub = r.client.subscriptionID
		}
		if sub == "" {
			resp.Diagnostics.AddError(
				"Invalid Resource Import ID",
				fmt.Sprintf("Import ID %q is a bare resource group name; the provider "+
					"subscription is not configured, so the full ARM id cannot be built. "+
					"Import with the full /subscriptions/{sub}/resourceGroups/{name} id instead.", req.ID),
			)
			return
		}
		id = rgID(sub, id)
	}
	if !forbidImportSegment(&resp.Diagnostics, id, "/providers/", "azurerm_resource_group") {
		return
	}
	if !requireImportSegment(&resp.Diagnostics, id, "/resourceGroups/", "azurerm_resource_group") {
		return
	}
	resp.Diagnostics.Append(resp.State.SetAttribute(ctx, path.Root("id"), id)...)
	parts := strings.Split(id, "/")
	if len(parts) > 0 {
		resp.Diagnostics.Append(resp.State.SetAttribute(ctx, path.Root("name"), parts[len(parts)-1])...)
	}
}

func tagsValue(ctx context.Context, diags *diag.Diagnostics, tags map[string]string) types.Map {
	if len(tags) == 0 {
		return types.MapNull(types.StringType)
	}
	m, d := types.MapValueFrom(ctx, types.StringType, tags)
	diags.Append(d...)
	return m
}

func mergeTags(base, remote map[string]string) map[string]string {
	out := map[string]string{}
	for k, v := range base {
		out[k] = v
	}
	for k, v := range remote {
		out[k] = v
	}
	return out
}
