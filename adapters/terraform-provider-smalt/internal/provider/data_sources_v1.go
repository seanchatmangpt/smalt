package provider

import (
	"context"
	"fmt"
	"strings"

	"github.com/hashicorp/terraform-plugin-framework/datasource"
	"github.com/hashicorp/terraform-plugin-framework/datasource/schema"
	"github.com/hashicorp/terraform-plugin-framework/types"
)

func init() {
	RegisterDataSource(NewResourceGroupDataSource)
	RegisterDataSource(NewKeyVaultDataSource)
	RegisterDataSource(NewContainerRegistryDataSource)
	RegisterDataSource(NewStorageAccountDataSource)
	RegisterDataSource(NewUserAssignedIdentityDataSource)
	RegisterDataSource(NewSmaltHealthDataSource)
}

// ============================================================================
// 1. data "azurerm_resource_group"
// ============================================================================

var _ datasource.DataSource = (*resourceGroupDataSource)(nil)

func NewResourceGroupDataSource() datasource.DataSource {
	return &resourceGroupDataSource{}
}

type resourceGroupDataSource struct {
	client *Client
}

type resourceGroupDataSourceModel struct {
	ID       types.String `tfsdk:"id"`
	Name     types.String `tfsdk:"name"`
	Location types.String `tfsdk:"location"`
	Tags     types.Map    `tfsdk:"tags"`
}

func (d *resourceGroupDataSource) Metadata(ctx context.Context, req datasource.MetadataRequest, resp *datasource.MetadataResponse) {
	resp.TypeName = req.ProviderTypeName + "_resource_group"
}

func (d *resourceGroupDataSource) Schema(ctx context.Context, req datasource.SchemaRequest, resp *datasource.SchemaResponse) {
	resp.Schema = schema.Schema{
		Description: "Reads an existing Resource Group from the smalt ARM plane.",
		Attributes: map[string]schema.Attribute{
			"name":     schema.StringAttribute{Required: true},
			"id":       schema.StringAttribute{Computed: true},
			"location": schema.StringAttribute{Computed: true},
			"tags":     schema.MapAttribute{ElementType: types.StringType, Computed: true},
		},
	}
}

func (d *resourceGroupDataSource) Configure(ctx context.Context, req datasource.ConfigureRequest, resp *datasource.ConfigureResponse) {
	if req.ProviderData == nil {
		return
	}
	c, ok := req.ProviderData.(*Client)
	if !ok {
		resp.Diagnostics.AddError("client cast", "expected *Client")
		return
	}
	d.client = c
}

func (d *resourceGroupDataSource) Read(ctx context.Context, req datasource.ReadRequest, resp *datasource.ReadResponse) {
	var state resourceGroupDataSourceModel
	resp.Diagnostics.Append(req.Config.Get(ctx, &state)...)
	if resp.Diagnostics.HasError() {
		return
	}

	rg, err := d.client.GetResourceGroup(ctx, state.Name.ValueString())
	if err != nil {
		resp.Diagnostics.AddError("read data.azurerm_resource_group", err.Error())
		return
	}
	if rg == nil {
		resp.Diagnostics.AddError("resource group not found", fmt.Sprintf("resource group %q does not exist", state.Name.ValueString()))
		return
	}

	state.ID = types.StringValue(NormalizeARMID(rgID(d.client.subscriptionID, state.Name.ValueString())))
	state.Location = types.StringValue(NormalizeLocation(rg.Location))
	state.Tags = tagsValue(ctx, &resp.Diagnostics, rg.Tags)

	resp.Diagnostics.Append(resp.State.Set(ctx, &state)...)
}

// ============================================================================
// 2. data "azurerm_key_vault"
// ============================================================================

var _ datasource.DataSource = (*keyVaultDataSource)(nil)

func NewKeyVaultDataSource() datasource.DataSource {
	return &keyVaultDataSource{}
}

type keyVaultDataSource struct {
	client *Client
}

type keyVaultDataSourceModel struct {
	ID                types.String `tfsdk:"id"`
	Name              types.String `tfsdk:"name"`
	ResourceGroupName types.String `tfsdk:"resource_group_name"`
	Location          types.String `tfsdk:"location"`
	TenantID          types.String `tfsdk:"tenant_id"`
	SkuName           types.String `tfsdk:"sku_name"`
	VaultURI          types.String `tfsdk:"vault_uri"`
	Tags              types.Map    `tfsdk:"tags"`
}

func (d *keyVaultDataSource) Metadata(ctx context.Context, req datasource.MetadataRequest, resp *datasource.MetadataResponse) {
	resp.TypeName = req.ProviderTypeName + "_key_vault"
}

func (d *keyVaultDataSource) Schema(ctx context.Context, req datasource.SchemaRequest, resp *datasource.SchemaResponse) {
	resp.Schema = schema.Schema{
		Description: "Reads an existing Key Vault from the smalt ARM plane.",
		Attributes: map[string]schema.Attribute{
			"name":                schema.StringAttribute{Required: true},
			"resource_group_name": schema.StringAttribute{Required: true},
			"id":                  schema.StringAttribute{Computed: true},
			"location":            schema.StringAttribute{Computed: true},
			"tenant_id":           schema.StringAttribute{Computed: true},
			"sku_name":            schema.StringAttribute{Computed: true},
			"vault_uri":           schema.StringAttribute{Computed: true},
			"tags":                schema.MapAttribute{ElementType: types.StringType, Computed: true},
		},
	}
}

func (d *keyVaultDataSource) Configure(ctx context.Context, req datasource.ConfigureRequest, resp *datasource.ConfigureResponse) {
	if req.ProviderData == nil {
		return
	}
	c, ok := req.ProviderData.(*Client)
	if !ok {
		resp.Diagnostics.AddError("client cast", "expected *Client")
		return
	}
	d.client = c
}

func (d *keyVaultDataSource) Read(ctx context.Context, req datasource.ReadRequest, resp *datasource.ReadResponse) {
	var state keyVaultDataSourceModel
	resp.Diagnostics.Append(req.Config.Get(ctx, &state)...)
	if resp.Diagnostics.HasError() {
		return
	}

	armPath := NormalizeARMID(fmt.Sprintf("/subscriptions/%s/resourceGroups/%s/providers/Microsoft.KeyVault/vaults/%s",
		d.client.subscriptionID, state.ResourceGroupName.ValueString(), state.Name.ValueString()))

	var out map[string]any
	_, _, _, err := d.client.GetRaw(ctx, armPath, "2023-07-01", &out)
	if err != nil {
		resp.Diagnostics.AddError("read data.azurerm_key_vault", err.Error())
		return
	}

	props, _ := out["properties"].(map[string]any)
	tenantID := mapStringField(props, "tenantId")
	if tenantID == "" {
		tenantID = d.client.tenantID
	}
	skuName := "standard"
	if skuMap, ok := props["sku"].(map[string]any); ok {
		if s := mapStringField(skuMap, "name"); s != "" {
			skuName = s
		}
	}
	vaultURI := mapStringField(props, "vaultUri")
	if vaultURI == "" {
		vaultURI = fmt.Sprintf("https://%s.vault.azure.net/", state.Name.ValueString())
	}

	state.ID = types.StringValue(armPath)
	state.Location = types.StringValue(NormalizeLocation(mapStringField(out, "location")))
	state.TenantID = types.StringValue(tenantID)
	state.SkuName = types.StringValue(skuName)
	state.VaultURI = types.StringValue(vaultURI)
	state.Tags = tagsValue(ctx, &resp.Diagnostics, mapTagsField(out))

	resp.Diagnostics.Append(resp.State.Set(ctx, &state)...)
}

// ============================================================================
// 3. data "azurerm_container_registry"
// ============================================================================

var _ datasource.DataSource = (*containerRegistryDataSource)(nil)

func NewContainerRegistryDataSource() datasource.DataSource {
	return &containerRegistryDataSource{}
}

type containerRegistryDataSource struct {
	client *Client
}

type containerRegistryDataSourceModel struct {
	ID                types.String `tfsdk:"id"`
	Name              types.String `tfsdk:"name"`
	ResourceGroupName types.String `tfsdk:"resource_group_name"`
	Location          types.String `tfsdk:"location"`
	Sku               types.String `tfsdk:"sku"`
	LoginServer       types.String `tfsdk:"login_server"`
	AdminEnabled      types.Bool   `tfsdk:"admin_enabled"`
	Tags              types.Map    `tfsdk:"tags"`
}

func (d *containerRegistryDataSource) Metadata(ctx context.Context, req datasource.MetadataRequest, resp *datasource.MetadataResponse) {
	resp.TypeName = req.ProviderTypeName + "_container_registry"
}

func (d *containerRegistryDataSource) Schema(ctx context.Context, req datasource.SchemaRequest, resp *datasource.SchemaResponse) {
	resp.Schema = schema.Schema{
		Description: "Reads an existing Container Registry from the smalt ARM plane.",
		Attributes: map[string]schema.Attribute{
			"name":                schema.StringAttribute{Required: true},
			"resource_group_name": schema.StringAttribute{Required: true},
			"id":                  schema.StringAttribute{Computed: true},
			"location":            schema.StringAttribute{Computed: true},
			"sku":                 schema.StringAttribute{Computed: true},
			"login_server":        schema.StringAttribute{Computed: true},
			"admin_enabled":       schema.BoolAttribute{Computed: true},
			"tags":                schema.MapAttribute{ElementType: types.StringType, Computed: true},
		},
	}
}

func (d *containerRegistryDataSource) Configure(ctx context.Context, req datasource.ConfigureRequest, resp *datasource.ConfigureResponse) {
	if req.ProviderData == nil {
		return
	}
	c, ok := req.ProviderData.(*Client)
	if !ok {
		resp.Diagnostics.AddError("client cast", "expected *Client")
		return
	}
	d.client = c
}

func (d *containerRegistryDataSource) Read(ctx context.Context, req datasource.ReadRequest, resp *datasource.ReadResponse) {
	var state containerRegistryDataSourceModel
	resp.Diagnostics.Append(req.Config.Get(ctx, &state)...)
	if resp.Diagnostics.HasError() {
		return
	}

	armPath := acrARMPath(d.client.subscriptionID, state.ResourceGroupName.ValueString(), state.Name.ValueString())
	var out map[string]any
	_, _, _, err := d.client.GetRaw(ctx, armPath, acrAPIVersion, &out)
	if err != nil {
		resp.Diagnostics.AddError("read data.azurerm_container_registry", err.Error())
		return
	}

	props, _ := out["properties"].(map[string]any)
	sku := "Basic"
	if skuMap, ok := out["sku"].(map[string]any); ok {
		if s := mapStringField(skuMap, "name"); s != "" {
			sku = s
		}
	}
	loginServer := mapStringField(props, "loginServer")
	if loginServer == "" {
		loginServer = fmt.Sprintf("%s.azurecr.io", state.Name.ValueString())
	}
	adminEnabled, _ := mapBoolField(props, "adminUserEnabled")

	state.ID = types.StringValue(armPath)
	state.Location = types.StringValue(NormalizeLocation(mapStringField(out, "location")))
	state.Sku = types.StringValue(sku)
	state.LoginServer = types.StringValue(loginServer)
	state.AdminEnabled = types.BoolValue(adminEnabled)
	state.Tags = tagsValue(ctx, &resp.Diagnostics, mapTagsField(out))

	resp.Diagnostics.Append(resp.State.Set(ctx, &state)...)
}

// ============================================================================
// 4. data "azurerm_storage_account"
// ============================================================================

var _ datasource.DataSource = (*storageAccountDataSource)(nil)

func NewStorageAccountDataSource() datasource.DataSource {
	return &storageAccountDataSource{}
}

type storageAccountDataSource struct {
	client *Client
}

type storageAccountDataSourceModel struct {
	ID                     types.String `tfsdk:"id"`
	Name                   types.String `tfsdk:"name"`
	ResourceGroupName      types.String `tfsdk:"resource_group_name"`
	Location               types.String `tfsdk:"location"`
	AccountTier            types.String `tfsdk:"account_tier"`
	AccountReplicationType types.String `tfsdk:"account_replication_type"`
	PrimaryBlobEndpoint    types.String `tfsdk:"primary_blob_endpoint"`
	PrimaryAccessKey       types.String `tfsdk:"primary_access_key"`
	Tags                   types.Map    `tfsdk:"tags"`
}

func (d *storageAccountDataSource) Metadata(ctx context.Context, req datasource.MetadataRequest, resp *datasource.MetadataResponse) {
	resp.TypeName = req.ProviderTypeName + "_storage_account"
}

func (d *storageAccountDataSource) Schema(ctx context.Context, req datasource.SchemaRequest, resp *datasource.SchemaResponse) {
	resp.Schema = schema.Schema{
		Description: "Reads an existing Storage Account from the smalt ARM plane.",
		Attributes: map[string]schema.Attribute{
			"name":                     schema.StringAttribute{Required: true},
			"resource_group_name":      schema.StringAttribute{Required: true},
			"id":                       schema.StringAttribute{Computed: true},
			"location":                 schema.StringAttribute{Computed: true},
			"account_tier":             schema.StringAttribute{Computed: true},
			"account_replication_type": schema.StringAttribute{Computed: true},
			"primary_blob_endpoint":    schema.StringAttribute{Computed: true},
			"primary_access_key":       schema.StringAttribute{Computed: true, Sensitive: true},
			"tags":                     schema.MapAttribute{ElementType: types.StringType, Computed: true},
		},
	}
}

func (d *storageAccountDataSource) Configure(ctx context.Context, req datasource.ConfigureRequest, resp *datasource.ConfigureResponse) {
	if req.ProviderData == nil {
		return
	}
	c, ok := req.ProviderData.(*Client)
	if !ok {
		resp.Diagnostics.AddError("client cast", "expected *Client")
		return
	}
	d.client = c
}

func (d *storageAccountDataSource) Read(ctx context.Context, req datasource.ReadRequest, resp *datasource.ReadResponse) {
	var state storageAccountDataSourceModel
	resp.Diagnostics.Append(req.Config.Get(ctx, &state)...)
	if resp.Diagnostics.HasError() {
		return
	}

	armPath := storageARMPath(d.client.subscriptionID, state.ResourceGroupName.ValueString(), state.Name.ValueString())
	var out map[string]any
	_, _, _, err := d.client.GetRaw(ctx, armPath, storageAPIVersion, &out)
	if err != nil {
		resp.Diagnostics.AddError("read data.azurerm_storage_account", err.Error())
		return
	}

	tier := "Standard"
	repl := "LRS"
	if skuMap, ok := out["sku"].(map[string]any); ok {
		if s := mapStringField(skuMap, "name"); strings.Contains(s, "_") {
			sp := strings.SplitN(s, "_", 2)
			tier = sp[0]
			repl = sp[1]
		}
	}

	props, _ := out["properties"].(map[string]any)
	blobEndpoint := ""
	if pe, ok := props["primaryEndpoints"].(map[string]any); ok {
		blobEndpoint = mapStringField(pe, "blob")
	}
	if blobEndpoint == "" {
		blobEndpoint = fmt.Sprintf("https://%s.blob.core.windows.net/", state.Name.ValueString())
	}

	state.ID = types.StringValue(armPath)
	state.Location = types.StringValue(NormalizeLocation(mapStringField(out, "location")))
	state.AccountTier = types.StringValue(tier)
	state.AccountReplicationType = types.StringValue(repl)
	state.PrimaryBlobEndpoint = types.StringValue(blobEndpoint)
	state.PrimaryAccessKey = types.StringValue(mintDeterministicGUID("st-key:" + armPath))
	state.Tags = tagsValue(ctx, &resp.Diagnostics, mapTagsField(out))

	resp.Diagnostics.Append(resp.State.Set(ctx, &state)...)
}

// ============================================================================
// 5. data "azurerm_user_assigned_identity"
// ============================================================================

var _ datasource.DataSource = (*userAssignedIdentityDataSource)(nil)

func NewUserAssignedIdentityDataSource() datasource.DataSource {
	return &userAssignedIdentityDataSource{}
}

type userAssignedIdentityDataSource struct {
	client *Client
}

type userAssignedIdentityDataSourceModel struct {
	ID                types.String `tfsdk:"id"`
	Name              types.String `tfsdk:"name"`
	ResourceGroupName types.String `tfsdk:"resource_group_name"`
	Location          types.String `tfsdk:"location"`
	ClientID          types.String `tfsdk:"client_id"`
	PrincipalID       types.String `tfsdk:"principal_id"`
	TenantID          types.String `tfsdk:"tenant_id"`
	Tags              types.Map    `tfsdk:"tags"`
}

func (d *userAssignedIdentityDataSource) Metadata(ctx context.Context, req datasource.MetadataRequest, resp *datasource.MetadataResponse) {
	resp.TypeName = req.ProviderTypeName + "_user_assigned_identity"
}

func (d *userAssignedIdentityDataSource) Schema(ctx context.Context, req datasource.SchemaRequest, resp *datasource.SchemaResponse) {
	resp.Schema = schema.Schema{
		Description: "Reads an existing User Assigned Identity from the smalt ARM plane.",
		Attributes: map[string]schema.Attribute{
			"name":                schema.StringAttribute{Required: true},
			"resource_group_name": schema.StringAttribute{Required: true},
			"id":                  schema.StringAttribute{Computed: true},
			"location":            schema.StringAttribute{Computed: true},
			"client_id":           schema.StringAttribute{Computed: true},
			"principal_id":        schema.StringAttribute{Computed: true},
			"tenant_id":           schema.StringAttribute{Computed: true},
			"tags":                schema.MapAttribute{ElementType: types.StringType, Computed: true},
		},
	}
}

func (d *userAssignedIdentityDataSource) Configure(ctx context.Context, req datasource.ConfigureRequest, resp *datasource.ConfigureResponse) {
	if req.ProviderData == nil {
		return
	}
	c, ok := req.ProviderData.(*Client)
	if !ok {
		resp.Diagnostics.AddError("client cast", "expected *Client")
		return
	}
	d.client = c
}

func (d *userAssignedIdentityDataSource) Read(ctx context.Context, req datasource.ReadRequest, resp *datasource.ReadResponse) {
	var state userAssignedIdentityDataSourceModel
	resp.Diagnostics.Append(req.Config.Get(ctx, &state)...)
	if resp.Diagnostics.HasError() {
		return
	}

	armPath := uaiARMPath(d.client.subscriptionID, state.ResourceGroupName.ValueString(), state.Name.ValueString())
	var out map[string]any
	_, _, _, err := d.client.GetRaw(ctx, armPath, uaiAPIVersion, &out)
	if err != nil {
		resp.Diagnostics.AddError("read data.azurerm_user_assigned_identity", err.Error())
		return
	}

	props, _ := out["properties"].(map[string]any)
	clientID := mapStringField(props, "clientId")
	if clientID == "" {
		// Honesty law: the smalt face carries no clientId; a minted GUID here
		// would not be the Entra object id. Refused by default; loud warning +
		// mint under TFPOSH_ALLOW_FABRICATED_IDS=1.
		clientID = carryOrMintIdentityAttr(&resp.Diagnostics, "", "uai-client:"+armPath, "client_id")
	}
	principalID := mapStringField(props, "principalId")
	if principalID == "" {
		principalID = carryOrMintIdentityAttr(&resp.Diagnostics, "", "uai-principal:"+armPath, "principal_id")
	}
	tenantID := mapStringField(props, "tenantId")
	if tenantID == "" {
		tenantID = d.client.tenantID
	}

	state.ID = types.StringValue(armPath)
	state.Location = types.StringValue(NormalizeLocation(mapStringField(out, "location")))
	state.ClientID = types.StringValue(clientID)
	state.PrincipalID = types.StringValue(principalID)
	state.TenantID = types.StringValue(tenantID)
	state.Tags = tagsValue(ctx, &resp.Diagnostics, mapTagsField(out))

	resp.Diagnostics.Append(resp.State.Set(ctx, &state)...)
}

// ============================================================================
// 6. data "azurerm_smalt_health"
// ============================================================================

var _ datasource.DataSource = (*smaltHealthDataSource)(nil)

func NewSmaltHealthDataSource() datasource.DataSource {
	return &smaltHealthDataSource{}
}

type smaltHealthDataSource struct {
	client *Client
}

type smaltHealthDataSourceModel struct {
	ID       types.String `tfsdk:"id"`
	Endpoint types.String `tfsdk:"endpoint"`
	Status   types.String `tfsdk:"status"`
	OK       types.Bool   `tfsdk:"ok"`
}

func (d *smaltHealthDataSource) Metadata(ctx context.Context, req datasource.MetadataRequest, resp *datasource.MetadataResponse) {
	resp.TypeName = req.ProviderTypeName + "_smalt_health"
}

func (d *smaltHealthDataSource) Schema(ctx context.Context, req datasource.SchemaRequest, resp *datasource.SchemaResponse) {
	resp.Schema = schema.Schema{
		Description: "Probes the smalt ARM plane metadata endpoints health.",
		Attributes: map[string]schema.Attribute{
			"endpoint": schema.StringAttribute{Optional: true},
			"id":       schema.StringAttribute{Computed: true},
			"status":   schema.StringAttribute{Computed: true},
			"ok":       schema.BoolAttribute{Computed: true},
		},
	}
}

func (d *smaltHealthDataSource) Configure(ctx context.Context, req datasource.ConfigureRequest, resp *datasource.ConfigureResponse) {
	if req.ProviderData == nil {
		return
	}
	c, ok := req.ProviderData.(*Client)
	if !ok {
		resp.Diagnostics.AddError("client cast", "expected *Client")
		return
	}
	d.client = c
}

func (d *smaltHealthDataSource) Read(ctx context.Context, req datasource.ReadRequest, resp *datasource.ReadResponse) {
	var state smaltHealthDataSourceModel
	resp.Diagnostics.Append(req.Config.Get(ctx, &state)...)
	if resp.Diagnostics.HasError() {
		return
	}

	probeClient := d.client
	if ep := state.Endpoint.ValueString(); ep != "" {
		c, err := NewClient(ctx, ep, d.client.subscriptionID, d.client.tenantID, d.client.clientID, "")
		if err != nil {
			resp.Diagnostics.AddError("smalt_health client", err.Error())
			return
		}
		probeClient = c
	}

	var out map[string]any
	_, _, status, err := probeClient.GetRaw(ctx, "/metadata/endpoints", "2020-01-01", &out)
	if err != nil {
		resp.Diagnostics.AddError("smalt_health probe", err.Error())
		return
	}

	ok := status >= 200 && status < 300
	statusStr := "healthy"
	if !ok {
		statusStr = fmt.Sprintf("status_%d", status)
	}

	state.ID = types.StringValue(probeClient.endpoint + "/metadata/endpoints")
	if state.Endpoint.IsNull() || state.Endpoint.ValueString() == "" {
		state.Endpoint = types.StringValue(probeClient.endpoint)
	}
	state.Status = types.StringValue(statusStr)
	state.OK = types.BoolValue(ok)

	resp.Diagnostics.Append(resp.State.Set(ctx, &state)...)
}
