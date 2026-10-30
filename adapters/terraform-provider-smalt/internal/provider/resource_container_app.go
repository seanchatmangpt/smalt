package provider

import (
	"context"
	"errors"
	"fmt"
	"net/http"
	"strconv"
	"strings"

	"github.com/hashicorp/terraform-plugin-framework/attr"
	"github.com/hashicorp/terraform-plugin-framework/diag"
	"github.com/hashicorp/terraform-plugin-framework/path"
	"github.com/hashicorp/terraform-plugin-framework/resource"
	"github.com/hashicorp/terraform-plugin-framework/resource/schema"
	"github.com/hashicorp/terraform-plugin-framework/resource/schema/boolplanmodifier"
	"github.com/hashicorp/terraform-plugin-framework/resource/schema/int64planmodifier"
	"github.com/hashicorp/terraform-plugin-framework/resource/schema/listplanmodifier"
	"github.com/hashicorp/terraform-plugin-framework/resource/schema/planmodifier"
	"github.com/hashicorp/terraform-plugin-framework/resource/schema/stringplanmodifier"
	"github.com/hashicorp/terraform-plugin-framework/types"
)

func init() {
	RegisterResource(NewContainerAppResource)
}

const (
	containerAppAPIVersion         = "2024-03-01"
	containerAppFallbackAPIVersion = "2023-05-01"
)

var (
	_ resource.Resource                = (*containerAppResource)(nil)
	_ resource.ResourceWithImportState = (*containerAppResource)(nil)
)

func NewContainerAppResource() resource.Resource {
	return &containerAppResource{}
}

type containerAppResource struct {
	client *Client
}

type containerAppSecretModel struct {
	Name             types.String `tfsdk:"name"`
	Value            types.String `tfsdk:"value"`
	Identity         types.String `tfsdk:"identity"`
	KeyVaultSecretID types.String `tfsdk:"key_vault_secret_id"`
}

type containerAppIdentityModel struct {
	Type        types.String `tfsdk:"type"`
	IdentityIDs types.List   `tfsdk:"identity_ids"`
	PrincipalID types.String `tfsdk:"principal_id"`
	TenantID    types.String `tfsdk:"tenant_id"`
}

type containerAppRegistryModel struct {
	Server             types.String `tfsdk:"server"`
	Identity           types.String `tfsdk:"identity"`
	Username           types.String `tfsdk:"username"`
	PasswordSecretName types.String `tfsdk:"password_secret_name"`
}

type containerAppTrafficWeightModel struct {
	Percentage     types.Int64  `tfsdk:"percentage"`
	LatestRevision types.Bool   `tfsdk:"latest_revision"`
	RevisionSuffix types.String `tfsdk:"revision_suffix"`
	Label          types.String `tfsdk:"label"`
}

type containerAppIPRestrictionModel struct {
	Action         types.String `tfsdk:"action"`
	IPAddressRange types.String `tfsdk:"ip_address_range"`
	Name           types.String `tfsdk:"name"`
	Description    types.String `tfsdk:"description"`
}

type containerAppIngressModel struct {
	ExternalEnabled          types.Bool                       `tfsdk:"external_enabled"`
	TargetPort               types.Int64                      `tfsdk:"target_port"`
	ExposedPort              types.Int64                      `tfsdk:"exposed_port"`
	Transport                types.String                     `tfsdk:"transport"`
	AllowInsecureConnections types.Bool                       `tfsdk:"allow_insecure_connections"`
	ClientCertificateMode    types.String                     `tfsdk:"client_certificate_mode"`
	Fqdn                     types.String                     `tfsdk:"fqdn"`
	TrafficWeight            []containerAppTrafficWeightModel `tfsdk:"traffic_weight"`
	IPSecurityRestriction    []containerAppIPRestrictionModel `tfsdk:"ip_security_restriction"`
}

type containerAppDaprModel struct {
	AppID       types.String `tfsdk:"app_id"`
	AppPort     types.Int64  `tfsdk:"app_port"`
	AppProtocol types.String `tfsdk:"app_protocol"`
}

type containerAppEnvModel struct {
	Name       types.String `tfsdk:"name"`
	Value      types.String `tfsdk:"value"`
	SecretName types.String `tfsdk:"secret_name"`
}

type containerAppProbeHeaderModel struct {
	Name  types.String `tfsdk:"name"`
	Value types.String `tfsdk:"value"`
}

type containerAppProbeModel struct {
	Transport                     types.String                   `tfsdk:"transport"`
	Port                          types.Int64                    `tfsdk:"port"`
	Path                          types.String                   `tfsdk:"path"`
	Host                          types.String                   `tfsdk:"host"`
	InitialDelay                  types.Int64                    `tfsdk:"initial_delay"`
	IntervalSeconds               types.Int64                    `tfsdk:"interval_seconds"`
	Timeout                       types.Int64                    `tfsdk:"timeout"`
	FailureCountThreshold         types.Int64                    `tfsdk:"failure_count_threshold"`
	SuccessCountThreshold         types.Int64                    `tfsdk:"success_count_threshold"`
	TerminationGracePeriodSeconds types.Int64                    `tfsdk:"termination_grace_period_seconds"`
	Header                        []containerAppProbeHeaderModel `tfsdk:"header"`
}

type containerAppContainerModel struct {
	Name             types.String             `tfsdk:"name"`
	Image            types.String             `tfsdk:"image"`
	CPU              types.Float64            `tfsdk:"cpu"`
	Memory           types.String             `tfsdk:"memory"`
	Args             types.List               `tfsdk:"args"`
	Command          types.List               `tfsdk:"command"`
	EphemeralStorage types.String             `tfsdk:"ephemeral_storage"`
	Env              []containerAppEnvModel   `tfsdk:"env"`
	LivenessProbe    []containerAppProbeModel `tfsdk:"liveness_probe"`
	ReadinessProbe   []containerAppProbeModel `tfsdk:"readiness_probe"`
	StartupProbe     []containerAppProbeModel `tfsdk:"startup_probe"`
}

type containerAppTemplateModel struct {
	MinReplicas    types.Int64                  `tfsdk:"min_replicas"`
	MaxReplicas    types.Int64                  `tfsdk:"max_replicas"`
	RevisionSuffix types.String                 `tfsdk:"revision_suffix"`
	Container      []containerAppContainerModel `tfsdk:"container"`
}

type containerAppModel struct {
	ID                         types.String                 `tfsdk:"id"`
	Name                       types.String                 `tfsdk:"name"`
	ResourceGroupName          types.String                 `tfsdk:"resource_group_name"`
	ContainerAppEnvironmentID  types.String                 `tfsdk:"container_app_environment_id"`
	RevisionMode               types.String                 `tfsdk:"revision_mode"`
	WorkloadProfileName        types.String                 `tfsdk:"workload_profile_name"`
	MaxInactiveRevisions       types.Int64                  `tfsdk:"max_inactive_revisions"`
	Location                   types.String                 `tfsdk:"location"`
	Tags                       types.Map                    `tfsdk:"tags"`
	LatestRevisionName         types.String                 `tfsdk:"latest_revision_name"`
	LatestRevisionFqdn         types.String                 `tfsdk:"latest_revision_fqdn"`
	OutboundIPAddresses        types.List                   `tfsdk:"outbound_ip_addresses"`
	CustomDomainVerificationID types.String                 `tfsdk:"custom_domain_verification_id"`
	Secret                     []containerAppSecretModel    `tfsdk:"secret"`
	Identity                   []containerAppIdentityModel  `tfsdk:"identity"`
	Registry                   []containerAppRegistryModel  `tfsdk:"registry"`
	Ingress                    []containerAppIngressModel   `tfsdk:"ingress"`
	Dapr                       []containerAppDaprModel      `tfsdk:"dapr"`
	Template                   []containerAppTemplateModel  `tfsdk:"template"`
}

func probeNestedBlockSchema(includeSuccessThreshold bool) schema.ListNestedBlock {
	attrs := map[string]schema.Attribute{
		"transport": schema.StringAttribute{
			Required: true,
		},
		"port": schema.Int64Attribute{
			Required: true,
		},
		"path": schema.StringAttribute{
			Optional: true,
			Computed: true,
			PlanModifiers: []planmodifier.String{
				stringplanmodifier.UseStateForUnknown(),
			},
		},
		"host": schema.StringAttribute{
			Optional: true,
		},
		"initial_delay": schema.Int64Attribute{
			Optional: true,
			Computed: true,
			PlanModifiers: []planmodifier.Int64{
				int64planmodifier.UseStateForUnknown(),
			},
		},
		"interval_seconds": schema.Int64Attribute{
			Optional: true,
			Computed: true,
			PlanModifiers: []planmodifier.Int64{
				int64planmodifier.UseStateForUnknown(),
			},
		},
		"timeout": schema.Int64Attribute{
			Optional: true,
			Computed: true,
			PlanModifiers: []planmodifier.Int64{
				int64planmodifier.UseStateForUnknown(),
			},
		},
		"failure_count_threshold": schema.Int64Attribute{
			Optional: true,
			Computed: true,
			PlanModifiers: []planmodifier.Int64{
				int64planmodifier.UseStateForUnknown(),
			},
		},
		"success_count_threshold": schema.Int64Attribute{
			Optional: true,
			Computed: true,
			PlanModifiers: []planmodifier.Int64{
				int64planmodifier.UseStateForUnknown(),
			},
		},
		"termination_grace_period_seconds": schema.Int64Attribute{
			Computed: true,
			PlanModifiers: []planmodifier.Int64{
				int64planmodifier.UseStateForUnknown(),
			},
		},
	}
	_ = includeSuccessThreshold
	return schema.ListNestedBlock{
		NestedObject: schema.NestedBlockObject{
			Attributes: attrs,
			Blocks: map[string]schema.Block{
				"header": schema.ListNestedBlock{
					NestedObject: schema.NestedBlockObject{
						Attributes: map[string]schema.Attribute{
							"name": schema.StringAttribute{
								Required: true,
							},
							"value": schema.StringAttribute{
								Required: true,
							},
						},
					},
				},
			},
		},
	}
}

func (r *containerAppResource) Metadata(ctx context.Context, req resource.MetadataRequest, resp *resource.MetadataResponse) {
	resp.TypeName = req.ProviderTypeName + "_container_app"
}

func (r *containerAppResource) Schema(ctx context.Context, req resource.SchemaRequest, resp *resource.SchemaResponse) {
	resp.Schema = schema.Schema{
		Description:         "Manages a Container App on the smalt ARM plane (azurerm_container_app parity, ARD-AZ-03 & ARD-TF-02).",
		MarkdownDescription: "Manages a Container App on the smalt ARM plane (`azurerm_container_app` parity, ARD-AZ-03 & ARD-TF-02).",
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
			"container_app_environment_id": schema.StringAttribute{
				Required: true,
				PlanModifiers: []planmodifier.String{
					stringplanmodifier.RequiresReplace(),
				},
			},
			"revision_mode": schema.StringAttribute{
				Required: true,
			},
			"workload_profile_name": schema.StringAttribute{
				Optional: true,
			},
			"max_inactive_revisions": schema.Int64Attribute{
				Optional: true,
			},
			"location": schema.StringAttribute{
				Optional: true,
				Computed: true,
				PlanModifiers: []planmodifier.String{
					stringplanmodifier.UseStateForUnknown(),
				},
			},
			"tags": schema.MapAttribute{
				ElementType: types.StringType,
				Optional:    true,
			},
			"latest_revision_name": schema.StringAttribute{
				Computed: true,
				PlanModifiers: []planmodifier.String{
					stringplanmodifier.UseStateForUnknown(),
				},
			},
			"latest_revision_fqdn": schema.StringAttribute{
				Computed: true,
				PlanModifiers: []planmodifier.String{
					stringplanmodifier.UseStateForUnknown(),
				},
			},
			"outbound_ip_addresses": schema.ListAttribute{
				ElementType: types.StringType,
				Computed:    true,
				PlanModifiers: []planmodifier.List{
					listplanmodifier.UseStateForUnknown(),
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
			"secret": schema.ListNestedBlock{
				NestedObject: schema.NestedBlockObject{
					Attributes: map[string]schema.Attribute{
						"name": schema.StringAttribute{
							Required: true,
						},
						"value": schema.StringAttribute{
							Optional:  true,
							Sensitive: true,
						},
						"identity": schema.StringAttribute{
							Optional: true,
						},
						"key_vault_secret_id": schema.StringAttribute{
							Optional: true,
						},
					},
				},
			},
			"identity": schema.ListNestedBlock{
				NestedObject: schema.NestedBlockObject{
					Attributes: map[string]schema.Attribute{
						"type": schema.StringAttribute{
							Required: true,
						},
						"identity_ids": schema.ListAttribute{
							ElementType: types.StringType,
							Optional:    true,
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
				},
			},
			"registry": schema.ListNestedBlock{
				NestedObject: schema.NestedBlockObject{
					Attributes: map[string]schema.Attribute{
						"server": schema.StringAttribute{
							Required: true,
						},
						"identity": schema.StringAttribute{
							Optional: true,
						},
						"username": schema.StringAttribute{
							Optional: true,
						},
						"password_secret_name": schema.StringAttribute{
							Optional: true,
						},
					},
				},
			},
			"ingress": schema.ListNestedBlock{
				NestedObject: schema.NestedBlockObject{
					Attributes: map[string]schema.Attribute{
						"external_enabled": schema.BoolAttribute{
							Optional: true,
							Computed: true,
							PlanModifiers: []planmodifier.Bool{
								boolplanmodifier.UseStateForUnknown(),
							},
						},
						"target_port": schema.Int64Attribute{
							Required: true,
						},
						"exposed_port": schema.Int64Attribute{
							Optional: true,
						},
						"transport": schema.StringAttribute{
							Optional: true,
							Computed: true,
							PlanModifiers: []planmodifier.String{
								stringplanmodifier.UseStateForUnknown(),
							},
						},
						"allow_insecure_connections": schema.BoolAttribute{
							Optional: true,
							Computed: true,
							PlanModifiers: []planmodifier.Bool{
								boolplanmodifier.UseStateForUnknown(),
							},
						},
						"client_certificate_mode": schema.StringAttribute{
							Optional: true,
						},
						"fqdn": schema.StringAttribute{
							Computed: true,
							PlanModifiers: []planmodifier.String{
								stringplanmodifier.UseStateForUnknown(),
							},
						},
					},
					Blocks: map[string]schema.Block{
						"traffic_weight": schema.ListNestedBlock{
							NestedObject: schema.NestedBlockObject{
								Attributes: map[string]schema.Attribute{
									"percentage": schema.Int64Attribute{
										Required: true,
									},
									"latest_revision": schema.BoolAttribute{
										Optional: true,
										Computed: true,
										PlanModifiers: []planmodifier.Bool{
											boolplanmodifier.UseStateForUnknown(),
										},
									},
									"revision_suffix": schema.StringAttribute{
										Optional: true,
									},
									"label": schema.StringAttribute{
										Optional: true,
									},
								},
							},
						},
						"ip_security_restriction": schema.ListNestedBlock{
							NestedObject: schema.NestedBlockObject{
								Attributes: map[string]schema.Attribute{
									"action": schema.StringAttribute{
										Required: true,
									},
									"ip_address_range": schema.StringAttribute{
										Required: true,
									},
									"name": schema.StringAttribute{
										Required: true,
									},
									"description": schema.StringAttribute{
										Optional: true,
									},
								},
							},
						},
					},
				},
			},
			"dapr": schema.ListNestedBlock{
				NestedObject: schema.NestedBlockObject{
					Attributes: map[string]schema.Attribute{
						"app_id": schema.StringAttribute{
							Required: true,
						},
						"app_port": schema.Int64Attribute{
							Required: true,
						},
						"app_protocol": schema.StringAttribute{
							Optional: true,
							Computed: true,
							PlanModifiers: []planmodifier.String{
								stringplanmodifier.UseStateForUnknown(),
							},
						},
					},
				},
			},
			"template": schema.ListNestedBlock{
				NestedObject: schema.NestedBlockObject{
					Attributes: map[string]schema.Attribute{
						"min_replicas": schema.Int64Attribute{
							Optional: true,
							Computed: true,
							PlanModifiers: []planmodifier.Int64{
								int64planmodifier.UseStateForUnknown(),
							},
						},
						"max_replicas": schema.Int64Attribute{
							Optional: true,
							Computed: true,
							PlanModifiers: []planmodifier.Int64{
								int64planmodifier.UseStateForUnknown(),
							},
						},
						"revision_suffix": schema.StringAttribute{
							Optional: true,
						},
					},
					Blocks: map[string]schema.Block{
						"container": schema.ListNestedBlock{
							NestedObject: schema.NestedBlockObject{
								Attributes: map[string]schema.Attribute{
									"name": schema.StringAttribute{
										Required: true,
									},
									"image": schema.StringAttribute{
										Required: true,
									},
									"cpu": schema.Float64Attribute{
										Required: true,
									},
									"memory": schema.StringAttribute{
										Required: true,
									},
									"args": schema.ListAttribute{
										ElementType: types.StringType,
										Optional:    true,
									},
									"command": schema.ListAttribute{
										ElementType: types.StringType,
										Optional:    true,
									},
									"ephemeral_storage": schema.StringAttribute{
										Computed: true,
										PlanModifiers: []planmodifier.String{
											stringplanmodifier.UseStateForUnknown(),
										},
									},
								},
								Blocks: map[string]schema.Block{
									"env": schema.ListNestedBlock{
										NestedObject: schema.NestedBlockObject{
											Attributes: map[string]schema.Attribute{
												"name": schema.StringAttribute{
													Required: true,
												},
												"value": schema.StringAttribute{
													Optional: true,
												},
												"secret_name": schema.StringAttribute{
													Optional: true,
												},
											},
										},
									},
									"liveness_probe":  probeNestedBlockSchema(false),
									"readiness_probe": probeNestedBlockSchema(true),
									"startup_probe":   probeNestedBlockSchema(false),
								},
							},
						},
					},
				},
			},
		},
	}
}

func (r *containerAppResource) Configure(ctx context.Context, req resource.ConfigureRequest, resp *resource.ConfigureResponse) {
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

func containerAppARMPath(subscriptionID, rg, name string) string {
	return NormalizeARMID(fmt.Sprintf("/subscriptions/%s/resourceGroups/%s/providers/Microsoft.App/containerApps/%s", subscriptionID, rg, name))
}

func parseMemoryGiB(mem string) float64 {
	s := strings.TrimSpace(mem)
	s = strings.TrimSuffix(s, "Gi")
	s = strings.TrimSuffix(s, "G")
	s = strings.TrimSuffix(s, "Mi")
	s = strings.TrimSuffix(s, "M")
	if v, err := strconv.ParseFloat(strings.TrimSpace(s), 64); err == nil && v > 0 {
		return v
	}
	return 0.5
}

func isMemoryNumberValidationError(err error) bool {
	var apiErr *ApiError
	if errors.As(err, &apiErr) {
		return apiErr.Status == http.StatusBadRequest && strings.Contains(apiErr.Body, "resources.memory")
	}
	return false
}

func coerceNumericMemoryInBody(body map[string]any) {
	props, ok := body["properties"].(map[string]any)
	if !ok {
		return
	}
	tmpl, ok := props["template"].(map[string]any)
	if !ok {
		return
	}
	containers, ok := tmpl["containers"].([]map[string]any)
	if ok {
		for i := range containers {
			if res, ok := containers[i]["resources"].(map[string]any); ok {
				if memStr, ok := res["memory"].(string); ok {
					res["memory"] = parseMemoryGiB(memStr)
				}
			}
		}
		return
	}
	if anyContainers, ok := tmpl["containers"].([]any); ok {
		for _, item := range anyContainers {
			if cm, ok := item.(map[string]any); ok {
				if res, ok := cm["resources"].(map[string]any); ok {
					if memStr, ok := res["memory"].(string); ok {
						res["memory"] = parseMemoryGiB(memStr)
					}
				}
			}
		}
	}
}

func (r *containerAppResource) putContainerApp(ctx context.Context, armPath, ifMatch string, body map[string]any, out *map[string]any) ([]byte, string, int, error) {
	apiVer := containerAppAPIVersion
	raw, etag, status, err := r.client.PutWithETag(ctx, armPath, apiVer, ifMatch, body, out)
	if err != nil && isInvalidAPIVersionError(err) {
		apiVer = containerAppFallbackAPIVersion
		raw, etag, status, err = r.client.PutWithETag(ctx, armPath, apiVer, ifMatch, body, out)
	}
	if err != nil && isMemoryNumberValidationError(err) {
		coerceNumericMemoryInBody(body)
		raw, etag, status, err = r.client.PutWithETag(ctx, armPath, apiVer, ifMatch, body, out)
	}
	return raw, etag, status, err
}

func (r *containerAppResource) getContainerApp(ctx context.Context, armPath string, out *map[string]any) ([]byte, string, int, error) {
	raw, etag, status, err := r.client.GetRaw(ctx, armPath, containerAppAPIVersion, out)
	if err != nil && isInvalidAPIVersionError(err) {
		raw, etag, status, err = r.client.GetRaw(ctx, armPath, containerAppFallbackAPIVersion, out)
	}
	return raw, etag, status, err
}

func (r *containerAppResource) deleteContainerApp(ctx context.Context, armPath string) (int, error) {
	status, err := r.client.DeleteRaw(ctx, armPath, containerAppAPIVersion)
	if err != nil && isInvalidAPIVersionError(err) {
		status, err = r.client.DeleteRaw(ctx, armPath, containerAppFallbackAPIVersion)
	}
	return status, err
}

func (r *containerAppResource) Create(ctx context.Context, req resource.CreateRequest, resp *resource.CreateResponse) {
	var plan containerAppModel
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

	r.applyDefaults(ctx, &plan)
	loc := NormalizeLocation(plan.Location.ValueString())
	if loc == "" {
		loc = "eastus"
	}
	armPath := containerAppARMPath(r.client.subscriptionID, plan.ResourceGroupName.ValueString(), plan.Name.ValueString())

	body := map[string]any{
		"location":   loc,
		"properties": r.buildProperties(ctx, &plan, nil),
	}
	if idMap := r.buildIdentityMap(ctx, &plan); idMap != nil {
		body["identity"] = idMap
	}
	if len(tags) > 0 {
		body["tags"] = tags
	}

	var out map[string]any
	raw, etag, _, err := r.putContainerApp(ctx, armPath, "", body, &out)
	if err != nil {
		resp.Diagnostics.AddError("create azurerm_container_app", err.Error())
		return
	}
	SavePrivateARMState(ctx, resp.Private, raw, etag)

	r.applyResponseToModel(ctx, &resp.Diagnostics, &plan, out, armPath, loc, tags, plan.Secret)
	resp.Diagnostics.Append(resp.State.Set(ctx, &plan)...)
}

func (r *containerAppResource) Read(ctx context.Context, req resource.ReadRequest, resp *resource.ReadResponse) {
	var state containerAppModel
	resp.Diagnostics.Append(req.State.Get(ctx, &state)...)
	if resp.Diagnostics.HasError() {
		return
	}

	// ARD-AZ-03: Capture priorState.Secret before calling ARM GET because ARM GET returns
	// properties.configuration.secrets with value: nil (write-only secret contract).
	priorSecrets := make([]containerAppSecretModel, len(state.Secret))
	copy(priorSecrets, state.Secret)

	armPath := state.ID.ValueString()
	if armPath == "" {
		armPath = containerAppARMPath(r.client.subscriptionID, state.ResourceGroupName.ValueString(), state.Name.ValueString())
	} else {
		armPath = NormalizeARMID(armPath)
	}

	var out map[string]any
	raw, etag, status, err := r.getContainerApp(ctx, armPath, &out)
	if err != nil {
		if status == http.StatusNotFound || IsNotFound(err) {
			resp.State.RemoveResource(ctx)
			return
		}
		resp.Diagnostics.AddError("read azurerm_container_app", err.Error())
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

	r.applyDefaults(ctx, &state)
	loc := NormalizeLocation(mapStringField(out, "location"))
	if loc == "" {
		loc = NormalizeLocation(state.Location.ValueString())
	}
	if loc == "" {
		loc = "eastus"
	}

	r.applyResponseToModel(ctx, &resp.Diagnostics, &state, out, armPath, loc, mergedTags, priorSecrets)
	resp.Diagnostics.Append(resp.State.Set(ctx, &state)...)
}

func (r *containerAppResource) Update(ctx context.Context, req resource.UpdateRequest, resp *resource.UpdateResponse) {
	var plan containerAppModel
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

	armPath := containerAppARMPath(r.client.subscriptionID, plan.ResourceGroupName.ValueString(), plan.Name.ValueString())

	// ARD-TF-02: Load cached private ARM state (arm_raw_body + arm_etag) and also merge
	// any server-side properties from GetRaw if available so server-injected fields like
	// properties.customDomainVerificationId survive Update PUT.
	rawMap, etag := LoadPrivateARMState(ctx, req.Private)
	if rawMap == nil {
		rawMap = map[string]any{}
	}

	var latestServerDoc map[string]any
	if _, latestETag, _, getErr := r.getContainerApp(ctx, armPath, &latestServerDoc); getErr == nil && latestServerDoc != nil {
		for k, v := range latestServerDoc {
			if k == "properties" {
				continue
			}
			if _, exists := rawMap[k]; !exists {
				rawMap[k] = v
			}
		}
		if latestProps, ok := latestServerDoc["properties"].(map[string]any); ok {
			curProps, _ := rawMap["properties"].(map[string]any)
			if curProps == nil {
				curProps = map[string]any{}
			}
			for k, v := range latestProps {
				curProps[k] = v
			}
			rawMap["properties"] = curProps
		}
		if latestETag != "" {
			etag = latestETag
		}
	}

	existingProps, _ := rawMap["properties"].(map[string]any)

	r.applyDefaults(ctx, &plan)
	loc := NormalizeLocation(plan.Location.ValueString())
	if loc == "" {
		loc = NormalizeLocation(mapStringField(rawMap, "location"))
	}
	if loc == "" {
		loc = "eastus"
	}

	rawMap["location"] = loc
	rawMap["properties"] = r.buildProperties(ctx, &plan, existingProps)
	if idMap := r.buildIdentityMap(ctx, &plan); idMap != nil {
		rawMap["identity"] = idMap
	}
	if len(tags) > 0 {
		rawMap["tags"] = tags
	} else {
		delete(rawMap, "tags")
	}

	var out map[string]any
	raw, newETag, _, err := r.putContainerApp(ctx, armPath, etag, rawMap, &out)
	if err != nil {
		resp.Diagnostics.AddError("update azurerm_container_app", err.Error())
		return
	}
	SavePrivateARMState(ctx, resp.Private, raw, newETag)

	// Ensure any preserved customDomainVerificationId in rawMap is carried to out if omitted.
	if outProps, ok := out["properties"].(map[string]any); ok {
		if reqProps, ok := rawMap["properties"].(map[string]any); ok {
			if cdv := mapStringField(reqProps, "customDomainVerificationId"); cdv != "" && mapStringField(outProps, "customDomainVerificationId") == "" {
				outProps["customDomainVerificationId"] = cdv
			}
		}
	}

	r.applyResponseToModel(ctx, &resp.Diagnostics, &plan, out, armPath, loc, tags, plan.Secret)
	resp.Diagnostics.Append(resp.State.Set(ctx, &plan)...)
}

func (r *containerAppResource) Delete(ctx context.Context, req resource.DeleteRequest, resp *resource.DeleteResponse) {
	var state containerAppModel
	resp.Diagnostics.Append(req.State.Get(ctx, &state)...)
	if resp.Diagnostics.HasError() {
		return
	}

	armPath := state.ID.ValueString()
	if armPath == "" {
		armPath = containerAppARMPath(r.client.subscriptionID, state.ResourceGroupName.ValueString(), state.Name.ValueString())
	} else {
		armPath = NormalizeARMID(armPath)
	}
	status, err := r.deleteContainerApp(ctx, armPath)
	if err != nil && status != http.StatusNotFound && !IsNotFound(err) {
		resp.Diagnostics.AddError("delete azurerm_container_app", err.Error())
	}
}

func (r *containerAppResource) ImportState(ctx context.Context, req resource.ImportStateRequest, resp *resource.ImportStateResponse) {
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

func (r *containerAppResource) applyDefaults(ctx context.Context, m *containerAppModel) {
	if m.Location.IsNull() || m.Location.IsUnknown() || m.Location.ValueString() == "" {
		m.Location = types.StringValue("eastus")
	} else {
		m.Location = types.StringValue(NormalizeLocation(m.Location.ValueString()))
	}

	for i := range m.Identity {
		if m.Identity[i].PrincipalID.IsNull() || m.Identity[i].PrincipalID.IsUnknown() {
			m.Identity[i].PrincipalID = types.StringValue(mintDeterministicGUID("ca-principal:" + m.Name.ValueString()))
		}
		if m.Identity[i].TenantID.IsNull() || m.Identity[i].TenantID.IsUnknown() {
			tid := defaultTenant
			if r.client != nil && r.client.tenantID != "" {
				tid = r.client.tenantID
			}
			m.Identity[i].TenantID = types.StringValue(tid)
		}
	}

	for i := range m.Ingress {
		if m.Ingress[i].ExternalEnabled.IsNull() || m.Ingress[i].ExternalEnabled.IsUnknown() {
			m.Ingress[i].ExternalEnabled = types.BoolValue(false)
		}
		if m.Ingress[i].Transport.IsNull() || m.Ingress[i].Transport.IsUnknown() || m.Ingress[i].Transport.ValueString() == "" {
			m.Ingress[i].Transport = types.StringValue("auto")
		}
		if m.Ingress[i].AllowInsecureConnections.IsNull() || m.Ingress[i].AllowInsecureConnections.IsUnknown() {
			m.Ingress[i].AllowInsecureConnections = types.BoolValue(false)
		}
		for j := range m.Ingress[i].TrafficWeight {
			if m.Ingress[i].TrafficWeight[j].LatestRevision.IsNull() || m.Ingress[i].TrafficWeight[j].LatestRevision.IsUnknown() {
				m.Ingress[i].TrafficWeight[j].LatestRevision = types.BoolValue(false)
			}
		}
	}

	for i := range m.Dapr {
		if m.Dapr[i].AppProtocol.IsNull() || m.Dapr[i].AppProtocol.IsUnknown() || m.Dapr[i].AppProtocol.ValueString() == "" {
			m.Dapr[i].AppProtocol = types.StringValue("http")
		}
	}

	for i := range m.Template {
		if m.Template[i].MinReplicas.IsNull() || m.Template[i].MinReplicas.IsUnknown() {
			m.Template[i].MinReplicas = types.Int64Value(0)
		}
		if m.Template[i].MaxReplicas.IsNull() || m.Template[i].MaxReplicas.IsUnknown() {
			m.Template[i].MaxReplicas = types.Int64Value(10)
		}
		for j := range m.Template[i].Container {
			if m.Template[i].Container[j].EphemeralStorage.IsNull() || m.Template[i].Container[j].EphemeralStorage.IsUnknown() {
				m.Template[i].Container[j].EphemeralStorage = types.StringValue("1Gi")
			}
			applyProbeDefaults(m.Template[i].Container[j].LivenessProbe)
			applyProbeDefaults(m.Template[i].Container[j].ReadinessProbe)
			applyProbeDefaults(m.Template[i].Container[j].StartupProbe)
		}
	}
	_ = ctx
}

func applyProbeDefaults(probes []containerAppProbeModel) {
	for i := range probes {
		if probes[i].Path.IsNull() || probes[i].Path.IsUnknown() {
			probes[i].Path = types.StringValue("/")
		}
		if probes[i].InitialDelay.IsNull() || probes[i].InitialDelay.IsUnknown() {
			probes[i].InitialDelay = types.Int64Value(1)
		}
		if probes[i].IntervalSeconds.IsNull() || probes[i].IntervalSeconds.IsUnknown() {
			probes[i].IntervalSeconds = types.Int64Value(10)
		}
		if probes[i].Timeout.IsNull() || probes[i].Timeout.IsUnknown() {
			probes[i].Timeout = types.Int64Value(1)
		}
		if probes[i].FailureCountThreshold.IsNull() || probes[i].FailureCountThreshold.IsUnknown() {
			probes[i].FailureCountThreshold = types.Int64Value(3)
		}
		if probes[i].SuccessCountThreshold.IsNull() || probes[i].SuccessCountThreshold.IsUnknown() {
			probes[i].SuccessCountThreshold = types.Int64Value(3)
		}
		if probes[i].TerminationGracePeriodSeconds.IsNull() || probes[i].TerminationGracePeriodSeconds.IsUnknown() {
			probes[i].TerminationGracePeriodSeconds = types.Int64Value(30)
		}
	}
}

func (r *containerAppResource) buildIdentityMap(ctx context.Context, m *containerAppModel) map[string]any {
	if len(m.Identity) == 0 {
		return nil
	}
	idBlock := m.Identity[0]
	out := map[string]any{
		"type": idBlock.Type.ValueString(),
	}
	if !idBlock.IdentityIDs.IsNull() && !idBlock.IdentityIDs.IsUnknown() {
		var ids []string
		idBlock.IdentityIDs.ElementsAs(ctx, &ids, false)
		if len(ids) > 0 {
			uam := make(map[string]any, len(ids))
			for _, id := range ids {
				uam[id] = map[string]any{}
			}
			out["userAssignedIdentities"] = uam
		}
	}
	return out
}

func (r *containerAppResource) buildProperties(ctx context.Context, m *containerAppModel, existing map[string]any) map[string]any {
	props := map[string]any{}
	for k, v := range existing {
		props[k] = v
	}

	envID := m.ContainerAppEnvironmentID.ValueString()
	props["managedEnvironmentId"] = envID
	props["environmentId"] = envID

	if !m.WorkloadProfileName.IsNull() && !m.WorkloadProfileName.IsUnknown() && m.WorkloadProfileName.ValueString() != "" {
		props["workloadProfileName"] = m.WorkloadProfileName.ValueString()
	}

	revMode := m.RevisionMode.ValueString()
	if revMode == "" {
		revMode = "Single"
	}

	config := map[string]any{
		"activeRevisionsMode": revMode,
	}
	if existingCfg, ok := existing["configuration"].(map[string]any); ok {
		for k, v := range existingCfg {
			config[k] = v
		}
		config["activeRevisionsMode"] = revMode
	}

	if !m.MaxInactiveRevisions.IsNull() && !m.MaxInactiveRevisions.IsUnknown() {
		config["maxInactiveRevisions"] = m.MaxInactiveRevisions.ValueInt64()
	}

	if len(m.Secret) > 0 {
		secrets := make([]map[string]any, 0, len(m.Secret))
		for _, s := range m.Secret {
			val := ""
			if !s.Value.IsNull() && !s.Value.IsUnknown() {
				val = s.Value.ValueString()
			} else if !s.KeyVaultSecretID.IsNull() && !s.KeyVaultSecretID.IsUnknown() {
				val = s.KeyVaultSecretID.ValueString()
			}
			entry := map[string]any{
				"name":  s.Name.ValueString(),
				"value": val,
			}
			if !s.Identity.IsNull() && !s.Identity.IsUnknown() && s.Identity.ValueString() != "" {
				entry["identity"] = s.Identity.ValueString()
			}
			if !s.KeyVaultSecretID.IsNull() && !s.KeyVaultSecretID.IsUnknown() && s.KeyVaultSecretID.ValueString() != "" {
				entry["keyVaultUrl"] = s.KeyVaultSecretID.ValueString()
			}
			secrets = append(secrets, entry)
		}
		config["secrets"] = secrets
	}

	if len(m.Registry) > 0 {
		regs := make([]map[string]any, 0, len(m.Registry))
		for _, reg := range m.Registry {
			entry := map[string]any{
				"server": reg.Server.ValueString(),
			}
			if !reg.Identity.IsNull() && !reg.Identity.IsUnknown() && reg.Identity.ValueString() != "" {
				entry["identity"] = reg.Identity.ValueString()
			}
			if !reg.Username.IsNull() && !reg.Username.IsUnknown() && reg.Username.ValueString() != "" {
				entry["username"] = reg.Username.ValueString()
			}
			if !reg.PasswordSecretName.IsNull() && !reg.PasswordSecretName.IsUnknown() && reg.PasswordSecretName.ValueString() != "" {
				entry["passwordSecretRef"] = reg.PasswordSecretName.ValueString()
			}
			regs = append(regs, entry)
		}
		config["registries"] = regs
	}

	if len(m.Ingress) > 0 {
		ing := m.Ingress[0]
		transport := strings.ToLower(ing.Transport.ValueString())
		if transport == "" {
			transport = "auto"
		}
		if transport == "http" {
			transport = "http1"
		}
		ingMap := map[string]any{
			"external":      ing.ExternalEnabled.ValueBool(),
			"targetPort":    ing.TargetPort.ValueInt64(),
			"transport":     transport,
			"allowInsecure": ing.AllowInsecureConnections.ValueBool(),
		}
		if !ing.ExposedPort.IsNull() && !ing.ExposedPort.IsUnknown() && ing.ExposedPort.ValueInt64() > 0 {
			ingMap["exposedPort"] = ing.ExposedPort.ValueInt64()
		}
		if len(ing.TrafficWeight) > 0 {
			tws := make([]map[string]any, 0, len(ing.TrafficWeight))
			for _, tw := range ing.TrafficWeight {
				latestRev := tw.LatestRevision.ValueBool()
				entry := map[string]any{
					"weight":             tw.Percentage.ValueInt64(),
					"latestRevision":     latestRev,
					"latestRevisionName": latestRev,
				}
				if !tw.RevisionSuffix.IsNull() && !tw.RevisionSuffix.IsUnknown() && tw.RevisionSuffix.ValueString() != "" {
					entry["revisionName"] = fmt.Sprintf("%s--%s", m.Name.ValueString(), tw.RevisionSuffix.ValueString())
				}
				if !tw.Label.IsNull() && !tw.Label.IsUnknown() && tw.Label.ValueString() != "" {
					entry["label"] = tw.Label.ValueString()
				}
				tws = append(tws, entry)
			}
			ingMap["traffic"] = tws
		}
		if len(ing.IPSecurityRestriction) > 0 {
			ips := make([]map[string]any, 0, len(ing.IPSecurityRestriction))
			for _, ipr := range ing.IPSecurityRestriction {
				entry := map[string]any{
					"name":           ipr.Name.ValueString(),
					"action":         ipr.Action.ValueString(),
					"ipAddressRange": ipr.IPAddressRange.ValueString(),
				}
				if !ipr.Description.IsNull() && !ipr.Description.IsUnknown() && ipr.Description.ValueString() != "" {
					entry["description"] = ipr.Description.ValueString()
				}
				ips = append(ips, entry)
			}
			ingMap["ipSecurityRestrictions"] = ips
		}
		config["ingress"] = ingMap
	}

	if len(m.Dapr) > 0 {
		d := m.Dapr[0]
		config["dapr"] = map[string]any{
			"enabled":     true,
			"appId":       d.AppID.ValueString(),
			"appPort":     d.AppPort.ValueInt64(),
			"appProtocol": d.AppProtocol.ValueString(),
		}
	}

	props["configuration"] = config

	if len(m.Template) > 0 {
		t := m.Template[0]
		containers := make([]map[string]any, 0, len(t.Container))
		for _, c := range t.Container {
			cMap := map[string]any{
				"name":  c.Name.ValueString(),
				"image": c.Image.ValueString(),
				"resources": map[string]any{
					"cpu":    c.CPU.ValueFloat64(),
					"memory": c.Memory.ValueString(),
				},
			}
			if !c.Command.IsNull() && !c.Command.IsUnknown() {
				var cmd []string
				c.Command.ElementsAs(ctx, &cmd, false)
				if len(cmd) > 0 {
					cMap["command"] = cmd
				}
			}
			if !c.Args.IsNull() && !c.Args.IsUnknown() {
				var args []string
				c.Args.ElementsAs(ctx, &args, false)
				if len(args) > 0 {
					cMap["args"] = args
				}
			}
			if len(c.Env) > 0 {
				envs := make([]map[string]any, 0, len(c.Env))
				for _, e := range c.Env {
					em := map[string]any{
						"name": e.Name.ValueString(),
					}
					if !e.SecretName.IsNull() && !e.SecretName.IsUnknown() && e.SecretName.ValueString() != "" {
						em["secretRef"] = e.SecretName.ValueString()
					} else if !e.Value.IsNull() && !e.Value.IsUnknown() {
						em["value"] = e.Value.ValueString()
					} else {
						em["value"] = ""
					}
					envs = append(envs, em)
				}
				cMap["env"] = envs
			}
			var probes []map[string]any
			probes = append(probes, buildWireProbes("Liveness", c.LivenessProbe)...)
			probes = append(probes, buildWireProbes("Readiness", c.ReadinessProbe)...)
			probes = append(probes, buildWireProbes("Startup", c.StartupProbe)...)
			if len(probes) > 0 {
				cMap["probes"] = probes
			}
			containers = append(containers, cMap)
		}
		tmplMap := map[string]any{
			"containers": containers,
			"scale": map[string]any{
				"minReplicas": t.MinReplicas.ValueInt64(),
				"maxReplicas": t.MaxReplicas.ValueInt64(),
			},
		}
		if !t.RevisionSuffix.IsNull() && !t.RevisionSuffix.IsUnknown() && t.RevisionSuffix.ValueString() != "" {
			tmplMap["revisionSuffix"] = t.RevisionSuffix.ValueString()
		}
		props["template"] = tmplMap
	}

	return props
}

func buildWireProbes(probeType string, probes []containerAppProbeModel) []map[string]any {
	out := make([]map[string]any, 0, len(probes))
	for _, p := range probes {
		tr := strings.ToUpper(p.Transport.ValueString())
		pm := map[string]any{
			"type":                probeType,
			"initialDelaySeconds": p.InitialDelay.ValueInt64(),
			"periodSeconds":       p.IntervalSeconds.ValueInt64(),
			"timeoutSeconds":      p.Timeout.ValueInt64(),
			"failureThreshold":    p.FailureCountThreshold.ValueInt64(),
			"successThreshold":    p.SuccessCountThreshold.ValueInt64(),
		}
		if tr == "TCP" {
			pm["tcpSocket"] = map[string]any{
				"port": p.Port.ValueInt64(),
			}
		} else {
			pathVal := p.Path.ValueString()
			if pathVal == "" {
				pathVal = "/"
			}
			httpGet := map[string]any{
				"port":   p.Port.ValueInt64(),
				"path":   pathVal,
				"scheme": tr,
			}
			if !p.Host.IsNull() && !p.Host.IsUnknown() && p.Host.ValueString() != "" {
				httpGet["host"] = p.Host.ValueString()
			}
			if len(p.Header) > 0 {
				hdrs := make([]map[string]any, 0, len(p.Header))
				for _, h := range p.Header {
					hdrs = append(hdrs, map[string]any{
						"name":  h.Name.ValueString(),
						"value": h.Value.ValueString(),
					})
				}
				httpGet["httpHeaders"] = hdrs
			}
			pm["httpGet"] = httpGet
		}
		out = append(out, pm)
	}
	return out
}

func (r *containerAppResource) applyResponseToModel(
	ctx context.Context,
	diags *diag.Diagnostics,
	m *containerAppModel,
	out map[string]any,
	armPath, loc string,
	tags map[string]string,
	priorSecrets []containerAppSecretModel,
) {
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
	cfg, _ := props["configuration"].(map[string]any)
	ingCfg, _ := cfg["ingress"].(map[string]any)

	if envID := mapStringField(props, "managedEnvironmentId"); envID != "" && (m.ContainerAppEnvironmentID.IsNull() || m.ContainerAppEnvironmentID.IsUnknown() || m.ContainerAppEnvironmentID.ValueString() == "") {
		m.ContainerAppEnvironmentID = types.StringValue(NormalizeARMID(envID))
	}
	if revMode := mapStringField(cfg, "activeRevisionsMode"); revMode != "" && (m.RevisionMode.IsNull() || m.RevisionMode.IsUnknown() || m.RevisionMode.ValueString() == "") {
		m.RevisionMode = types.StringValue(revMode)
	}

	latestRevName := mapStringField(props, "latestRevisionName")
	if latestRevName == "" {
		latestRevName = fmt.Sprintf("%s--v1", m.Name.ValueString())
	}
	latestRevFqdn := mapStringField(props, "latestRevisionFqdn")
	if latestRevFqdn == "" {
		latestRevFqdn = mapStringField(ingCfg, "fqdn")
	}
	if latestRevFqdn == "" {
		latestRevFqdn = fmt.Sprintf("%s.internal.%s.azurecontainerapps.io", m.Name.ValueString(), m.Location.ValueString())
	}

	customDomainID := mapStringField(props, "customDomainVerificationId")
	if customDomainID == "" {
		customDomainID = "smalt-verification-id"
	}

	var outboundIPs []attr.Value
	if rawIPs, ok := props["outboundIpAddresses"].([]any); ok && len(rawIPs) > 0 {
		for _, ip := range rawIPs {
			if s, ok := ip.(string); ok {
				outboundIPs = append(outboundIPs, types.StringValue(s))
			}
		}
	}
	if len(outboundIPs) == 0 {
		outboundIPs = []attr.Value{types.StringValue("10.0.0.100")}
	}
	ipList, d := types.ListValue(types.StringType, outboundIPs)
	diags.Append(d...)

	m.LatestRevisionName = types.StringValue(latestRevName)
	m.LatestRevisionFqdn = types.StringValue(latestRevFqdn)
	m.OutboundIPAddresses = ipList
	m.CustomDomainVerificationID = types.StringValue(customDomainID)

	for i := range m.Ingress {
		fqdn := mapStringField(ingCfg, "fqdn")
		if fqdn == "" {
			fqdn = latestRevFqdn
		}
		m.Ingress[i].Fqdn = types.StringValue(fqdn)
	}

	// ARD-AZ-03: Reconcile secrets, preserving priorState.Secret values when ARM GET omits value.
	m.Secret = reconcileContainerAppSecrets(priorSecrets, cfg)

	m.Tags = tagsValue(ctx, diags, tags)
}

func reconcileContainerAppSecrets(priorSecrets []containerAppSecretModel, cfg map[string]any) []containerAppSecretModel {
	rawSecrets, hasRemote := cfg["secrets"].([]any)
	if len(priorSecrets) > 0 {
		remoteByName := map[string]map[string]any{}
		if hasRemote {
			for _, item := range rawSecrets {
				if sm, ok := item.(map[string]any); ok {
					if name := mapStringField(sm, "name"); name != "" {
						remoteByName[name] = sm
					}
				}
			}
		}
		out := make([]containerAppSecretModel, len(priorSecrets))
		for i, ps := range priorSecrets {
			out[i] = ps
			if rm, ok := remoteByName[ps.Name.ValueString()]; ok {
				// Only overwrite Value if ARM returned a non-empty string value;
				// when ARM returns value: nil, preserve prior state's Value!
				if v, ok := rm["value"].(string); ok && v != "" && (ps.Value.IsNull() || ps.Value.IsUnknown()) {
					out[i].Value = types.StringValue(v)
				}
				if kv := mapStringField(rm, "keyVaultUrl"); kv != "" && (ps.KeyVaultSecretID.IsNull() || ps.KeyVaultSecretID.IsUnknown()) {
					out[i].KeyVaultSecretID = types.StringValue(kv)
				}
				if id := mapStringField(rm, "identity"); id != "" && (ps.Identity.IsNull() || ps.Identity.IsUnknown()) {
					out[i].Identity = types.StringValue(id)
				}
			}
		}
		return out
	}

	if !hasRemote || len(rawSecrets) == 0 {
		return priorSecrets
	}

	out := make([]containerAppSecretModel, 0, len(rawSecrets))
	for _, item := range rawSecrets {
		sm, ok := item.(map[string]any)
		if !ok {
			continue
		}
		name := mapStringField(sm, "name")
		if name == "" {
			continue
		}
		entry := containerAppSecretModel{
			Name:             types.StringValue(name),
			Value:            types.StringNull(),
			Identity:         types.StringNull(),
			KeyVaultSecretID: types.StringNull(),
		}
		if v, ok := sm["value"].(string); ok && v != "" {
			entry.Value = types.StringValue(v)
		}
		if kv := mapStringField(sm, "keyVaultUrl"); kv != "" {
			entry.KeyVaultSecretID = types.StringValue(kv)
		}
		if id := mapStringField(sm, "identity"); id != "" {
			entry.Identity = types.StringValue(id)
		}
		out = append(out, entry)
	}
	return out
}
