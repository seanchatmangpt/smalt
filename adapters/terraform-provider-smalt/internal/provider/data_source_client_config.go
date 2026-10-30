package provider

import (
	"context"

	"github.com/hashicorp/terraform-plugin-framework/datasource"
	"github.com/hashicorp/terraform-plugin-framework/datasource/schema"
	"github.com/hashicorp/terraform-plugin-framework/types"
)

var _ datasource.DataSource = (*clientConfigDataSource)(nil)

func NewClientConfigDataSource() datasource.DataSource {
	return &clientConfigDataSource{}
}

type clientConfigDataSource struct {
	client *Client
}

type clientConfigModel struct {
	TenantID       types.String `tfsdk:"tenant_id"`
	SubscriptionID types.String `tfsdk:"subscription_id"`
	ClientID       types.String `tfsdk:"client_id"`
	ObjectID       types.String `tfsdk:"object_id"`
}

func (d *clientConfigDataSource) Metadata(ctx context.Context, req datasource.MetadataRequest, resp *datasource.MetadataResponse) {
	resp.TypeName = req.ProviderTypeName + "_client_config"
}

func (d *clientConfigDataSource) Schema(ctx context.Context, req datasource.SchemaRequest, resp *datasource.SchemaResponse) {
	resp.Schema = schema.Schema{
		Attributes: map[string]schema.Attribute{
			"tenant_id":       schema.StringAttribute{Computed: true},
			"subscription_id": schema.StringAttribute{Computed: true},
			"client_id":       schema.StringAttribute{Computed: true},
			"object_id":       schema.StringAttribute{Computed: true},
		},
	}
}

func (d *clientConfigDataSource) Configure(ctx context.Context, req datasource.ConfigureRequest, resp *datasource.ConfigureResponse) {
	if req.ProviderData == nil {
		return
	}
	client, ok := req.ProviderData.(*Client)
	if !ok {
		resp.Diagnostics.AddError("client cast", "expected *Client")
		return
	}
	d.client = client
}

func (d *clientConfigDataSource) Read(ctx context.Context, req datasource.ReadRequest, resp *datasource.ReadResponse) {
	var state clientConfigModel
	resp.Diagnostics.Append(req.Config.Get(ctx, &state)...)
	if resp.Diagnostics.HasError() {
		return
	}
	state.TenantID = types.StringValue(d.client.tenantID)
	state.SubscriptionID = types.StringValue(d.client.subscriptionID)
	state.ClientID = types.StringValue(d.client.clientID)
	state.ObjectID = types.StringValue(d.client.clientID)
	resp.Diagnostics.Append(resp.State.Set(ctx, &state)...)
}
