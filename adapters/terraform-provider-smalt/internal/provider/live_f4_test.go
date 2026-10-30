package provider

import (
	"context"
	"fmt"
	"math/big"
	"os"
	"testing"

	"github.com/hashicorp/terraform-plugin-framework/diag"
	"github.com/hashicorp/terraform-plugin-framework/resource"
	"github.com/hashicorp/terraform-plugin-framework/resource/schema"
	"github.com/hashicorp/terraform-plugin-framework/tfsdk"
	"github.com/hashicorp/terraform-plugin-go/tftypes"
)

// Lane F4 live roundtrips against the real smalt substrate (real
// collaborators, real state assertions — Chicago discipline). Guarded by
// TFPOSHT_LIVE=1. Each test proves the wire contracts pinned by the Elixir
// spike: numeric container-app memory, write-only secrets (secret-value echo
// is disjunctive: the ARM face omits properties.value or echoes it exactly —
// prior state kept when omitted; gap lane 23, 2026-10-30), key vault 202-LRO
// readiness, top-level location in secret PUT bodies.

const f4Sub = "00000000-0000-0000-0000-000000000000"

func f4Live(t *testing.T) (*Client, context.Context) {
	t.Helper()
	if os.Getenv("TFPOSHT_LIVE") != "1" {
		t.Skip("live test: set TFPOSHT_LIVE=1")
	}
	ctx := context.Background()
	c, err := NewClient(ctx, f4Endpoint(), f4Sub, "", "", "")
	if err != nil {
		t.Fatalf("NewClient: %v", err)
	}
	return c, ctx
}

func f4Endpoint() string {
	if e := os.Getenv("SMALT_ARM_ENDPOINT"); e != "" {
		return e
	}
	return "http://127.0.0.1:9443"
}

func f4RequireRG(ctx context.Context, t *testing.T, c *Client) {
	t.Helper()
	if _, err := c.GetResourceGroup(ctx, "f4-rg"); err != nil {
		if _, err := c.PutResourceGroup(ctx, "f4-rg", "eastus", map[string]string{"f4": "1"}); err != nil {
			t.Fatalf("ensure f4-rg: %v", err)
		}
	}
}

// f4U is the unknown-value sentinel for plan construction.
type f4U struct{}

func f4Value(ctx context.Context, t *testing.T, typ tftypes.Type, v any) tftypes.Value {
	t.Helper()
	if _, ok := v.(f4U); ok {
		return tftypes.NewValue(typ, tftypes.UnknownValue)
	}
	switch {
	case typ.Equal(tftypes.String):
		s, _ := v.(string)
		return tftypes.NewValue(typ, s)
	case typ.Equal(tftypes.Number):
		switch n := v.(type) {
		case int64:
			return tftypes.NewValue(typ, new(big.Float).SetInt64(n))
		case float64:
			return tftypes.NewValue(typ, big.NewFloat(n))
		default:
			t.Fatalf("f4Value: unsupported number %T", v)
			return tftypes.Value{}
		}
	case typ.Equal(tftypes.Bool):
		b, _ := v.(bool)
		return tftypes.NewValue(typ, b)
	case typ.Equal(tftypes.Map{ElementType: tftypes.String}):
		m, ok := v.(map[string]string)
		if !ok {
			t.Fatalf("f4Value: want map[string]string for Map, got %T", v)
		}
		elems := map[string]tftypes.Value{}
		for k, e := range m {
			elems[k] = f4Value(ctx, t, tftypes.String, e)
		}
		return tftypes.NewValue(typ, elems)
	default:
		// List or Object (composite): dispatch on the concrete struct.
		switch tt := typ.(type) {
		case tftypes.List:
			raws, ok := v.([]any)
			if !ok {
				t.Fatalf("f4Value: want []any for List, got %T", v)
			}
			elems := make([]tftypes.Value, 0, len(raws))
			for _, e := range raws {
				elems = append(elems, f4Value(ctx, t, tt.ElementType, e))
			}
			return tftypes.NewValue(typ, elems)
		case tftypes.Object:
			obj, ok := v.(map[string]any)
			if !ok {
				t.Fatalf("f4Value: want map[string]any for Object, got %T", v)
			}
			attrs := map[string]tftypes.Value{}
			for name, at := range tt.AttributeTypes {
				rv, present := obj[name]
				if !present {
					attrs[name] = tftypes.NewValue(at, nil) // null
					continue
				}
				attrs[name] = f4Value(ctx, t, at, rv)
			}
			return tftypes.NewValue(typ, attrs)
		default:
			t.Fatalf("f4Value: unsupported type %s", typ)
			return tftypes.Value{}
		}
	}
}

func f4Schema(t *testing.T, r resource.Resource) schema.Schema {
	t.Helper()
	var sr resource.SchemaResponse
	r.Schema(context.Background(), resource.SchemaRequest{}, &sr)
	if sr.Diagnostics.HasError() {
		t.Fatalf("schema diags: %+v", sr.Diagnostics)
	}
	return sr.Schema
}

func f4Configure(t *testing.T, r resource.Resource, c *Client) {
	t.Helper()
	rc, ok := r.(resource.ResourceWithConfigure)
	if !ok {
		t.Fatal("resource does not implement ResourceWithConfigure")
	}
	var cr resource.ConfigureResponse
	rc.Configure(context.Background(), resource.ConfigureRequest{ProviderData: c}, &cr)
	if cr.Diagnostics.HasError() {
		t.Fatalf("configure diags: %+v", cr.Diagnostics)
	}
}

func f4Raw(t *testing.T, s schema.Schema, m map[string]any) tftypes.Value {
	t.Helper()
	ctx := context.Background()
	return f4Value(ctx, t, s.Type().TerraformType(ctx), m)
}

func f4Config(t *testing.T, s schema.Schema, m map[string]any) tfsdk.Config {
	t.Helper()
	return tfsdk.Config{Schema: s, Raw: f4Raw(t, s, m)}
}

func f4Plan(t *testing.T, s schema.Schema, m map[string]any) tfsdk.Plan {
	t.Helper()
	return tfsdk.Plan{Schema: s, Raw: f4Raw(t, s, m)}
}

func f4Diags(t *testing.T, stage string, d diag.Diagnostics) {
	t.Helper()
	if d.HasError() {
		t.Fatalf("%s diags: %+v", stage, d)
	}
}

func f4RawGET(t *testing.T, c *Client, path, apiVersion string) (map[string]any, int) {
	t.Helper()
	var out map[string]any
	_, _, status, err := c.GetRaw(context.Background(), path, apiVersion, &out)
	if err != nil && status != 404 {
		t.Fatalf("raw GET %s: %v", path, err)
	}
	return out, status
}

// f4State returns an empty state carrying the schema (Create responses need
// a non-nil schema to Set into).
func f4State(s schema.Schema) tfsdk.State {
	ctx := context.Background()
	objType := s.Type().TerraformType(ctx)
	return tfsdk.State{Schema: s, Raw: tftypes.NewValue(objType, nil)}
}

// TestLiveKeyVaultRoundtrip proves azurerm_key_vault create/read/update/
// delete against the live substrate, including the 202-LRO readiness path.
func TestLiveKeyVaultRoundtrip(t *testing.T) {
	c, ctx := f4Live(t)
	f4RequireRG(ctx, t, c)
	name := "f4-kv"
	armPath := keyVaultARMPath(f4Sub, "f4-rg", name)
	_, _ = c.DeleteRaw(ctx, armPath, keyVaultAPIVersion)

	r := &keyVaultResource{}
	f4Configure(t, r, c)
	s := f4Schema(t, r)

	mkCfg := func(tags map[string]string) map[string]any {
		return map[string]any{
			"name":                name,
			"resource_group_name": "f4-rg",
			"location":            "eastus",
			"tenant_id":           f4Sub,
			"sku_name":            "standard",
			"tags":                tags,
		}
	}

	var createResp resource.CreateResponse
	createResp.State = f4State(s)
	r.Create(ctx, resource.CreateRequest{
		Config: f4Config(t, s, mkCfg(map[string]string{"f4": "1"})),
		Plan:   f4Plan(t, s, mkCfg(map[string]string{"f4": "1"})),
	}, &createResp)
	f4Diags(t, "create", createResp.Diagnostics)

	var kv keyVaultModel
	f4Diags(t, "create state", createResp.State.Get(ctx, &kv))
	if kv.Name.ValueString() != name || kv.Location.ValueString() != "eastus" {
		t.Fatalf("create: name=%q location=%q", kv.Name.ValueString(), kv.Location.ValueString())
	}
	if kv.VaultURI.ValueString() == "" {
		t.Fatal("create: vault_uri empty")
	}

	// Read must find it and keep it.
	var readResp resource.ReadResponse
	readResp.State = createResp.State
	r.Read(ctx, resource.ReadRequest{State: createResp.State}, &readResp)
	f4Diags(t, "read", readResp.Diagnostics)
	var kv2 keyVaultModel
	f4Diags(t, "read state", readResp.State.Get(ctx, &kv2))
	if kv2.ID.ValueString() == "" {
		t.Fatal("read: state removed unexpectedly")
	}

	// Update tags (ETag from private state -> ARM If-Match).
	var updResp resource.UpdateResponse
	updResp.Private = createResp.Private
	updResp.State = createResp.State
	r.Update(ctx, resource.UpdateRequest{
		Config:  f4Config(t, s, mkCfg(map[string]string{"f4": "2"})),
		Plan:    f4Plan(t, s, mkCfg(map[string]string{"f4": "2"})),
		State:   createResp.State,
		Private: createResp.Private,
	}, &updResp)
	f4Diags(t, "update", updResp.Diagnostics)

	out, status := f4RawGET(t, c, armPath, keyVaultFallbackAPIVersion)
	if status != 200 {
		t.Fatalf("raw GET after update: %d", status)
	}
	if fmt.Sprint(out["tags"]) != "map[f4:2]" {
		t.Fatalf("raw tags after update: %v", out["tags"])
	}

	// Delete, then confirm 404 on the wire.
	var delResp resource.DeleteResponse
	r.Delete(ctx, resource.DeleteRequest{State: updResp.State, Private: updResp.Private}, &delResp)
	f4Diags(t, "delete", delResp.Diagnostics)
	if _, status := f4RawGET(t, c, armPath, keyVaultFallbackAPIVersion); status != 404 {
		t.Fatalf("vault %s still present after DELETE (status %d)", name, status)
	}
}

// TestLiveKeyVaultSecretRoundtrip proves azurerm_key_vault_secret CRUD and
// the write-only value contract: the substrate never echoes
// properties.value, so Read keeps the prior state value (zero plan drift).
func TestLiveKeyVaultSecretRoundtrip(t *testing.T) {
	c, ctx := f4Live(t)
	f4RequireRG(ctx, t, c)
	vaultName := "f4-kvs-vault"
	secretName := "f4-s"
	kvPath := keyVaultARMPath(f4Sub, "f4-rg", vaultName)
	secPath := keyVaultSecretARMPath(f4Sub, "f4-rg", vaultName, secretName)
	// Pre-clean + provision the vault directly on the wire (fixture).
	_, _ = c.DeleteRaw(ctx, secPath, keyVaultSecretAPIVersion)
	_, _ = c.DeleteRaw(ctx, kvPath, keyVaultAPIVersion)
	kvBody := map[string]any{
		"location": "eastus",
		"properties": map[string]any{
			"tenantId": f4Sub,
			"sku":      map[string]any{"family": "A", "name": "standard"},
		},
	}
	if _, _, _, err := c.PutWithETag(ctx, kvPath, keyVaultAPIVersion, "", kvBody, new(map[string]any)); err != nil {
		t.Fatalf("provision vault: %v", err)
	}
	defer c.DeleteRaw(ctx, kvPath, keyVaultAPIVersion)

	r := &keyVaultSecretResource{}
	f4Configure(t, r, c)
	s := f4Schema(t, r)

	mkCfg := func(value string) map[string]any {
		return map[string]any{
			"name":         secretName,
			"value":        value,
			"key_vault_id": kvPath,
			"content_type": "text/plain",
			"tags":         map[string]string{"f4": "1"},
		}
	}

	var createResp resource.CreateResponse
	createResp.State = f4State(s)
	r.Create(ctx, resource.CreateRequest{Config: f4Config(t, s, mkCfg("f4-v1")), Plan: f4Plan(t, s, mkCfg("f4-v1"))}, &createResp)
	f4Diags(t, "create", createResp.Diagnostics)

	var sec keyVaultSecretModel
	f4Diags(t, "create state", createResp.State.Get(ctx, &sec))
	if sec.Value.ValueString() != "f4-v1" {
		t.Fatalf("create: value=%q", sec.Value.ValueString())
	}
	if sec.Version.ValueString() == "" {
		t.Fatal("create: version empty")
	}

	// Substrate contract (disjunctive law, SDK-parity register): the plane
	// either omits properties.value on GET (write-only; provider keeps prior
	// state value) or echoes it exactly. Both are typed, neither may diverge.
	rawOut, status := f4RawGET(t, c, secPath, keyVaultSecretAPIVersion)
	if status != 200 {
		t.Fatalf("raw GET secret: %d", status)
	}
	props, _ := rawOut["properties"].(map[string]any)
	if echoed, ok := props["value"]; ok && echoed != "f4-v1" {
		t.Fatalf("substrate echoed wrong value: %v", echoed)
	}

	// Read keeps (or replays) f4-v1 either way — zero plan drift.
	var readResp resource.ReadResponse
	readResp.State = createResp.State
	r.Read(ctx, resource.ReadRequest{State: createResp.State}, &readResp)
	f4Diags(t, "read", readResp.Diagnostics)
	var sec2 keyVaultSecretModel
	f4Diags(t, "read keep-prior", readResp.State.Get(ctx, &sec2))
	if sec2.Value.ValueString() != "f4-v1" {
		t.Fatalf("read: prior value not kept: %q", sec2.Value.ValueString())
	}

	// Update value -> new deterministic version.
	var updResp resource.UpdateResponse
	updResp.Private = createResp.Private
	updResp.State = createResp.State
	r.Update(ctx, resource.UpdateRequest{
		Config:  f4Config(t, s, mkCfg("f4-v2")),
		Plan:    f4Plan(t, s, mkCfg("f4-v2")),
		State:   createResp.State,
		Private: createResp.Private,
	}, &updResp)
	f4Diags(t, "update", updResp.Diagnostics)
	var sec3 keyVaultSecretModel
	f4Diags(t, "update state", updResp.State.Get(ctx, &sec3))
	if sec3.Value.ValueString() != "f4-v2" {
		t.Fatalf("update: value=%q", sec3.Value.ValueString())
	}
	if sec3.Version.ValueString() == sec.Version.ValueString() {
		t.Fatalf("update: version unchanged (%s)", sec3.Version.ValueString())
	}

	// Delete + wire 404.
	var delResp resource.DeleteResponse
	r.Delete(ctx, resource.DeleteRequest{State: updResp.State, Private: updResp.Private}, &delResp)
	f4Diags(t, "delete", delResp.Diagnostics)
	if _, status := f4RawGET(t, c, secPath, keyVaultSecretAPIVersion); status != 404 {
		t.Fatalf("secret %s still present after DELETE (status %d)", secretName, status)
	}
}

// TestLiveContainerAppRoundtrip proves azurerm_container_app CRUD and the
// spike wire divergences: numeric memory on the wire (the provider coerces
// the "0.5Gi" schema string), write-only secrets kept from prior state on
// read, ingress honored on update.
func TestLiveContainerAppRoundtrip(t *testing.T) {
	c, ctx := f4Live(t)
	f4RequireRG(ctx, t, c)

	// Provision the managed environment fixture directly on the wire.
	envName := "f4-env"
	envPath := NormalizeARMID(fmt.Sprintf("/subscriptions/%s/resourceGroups/f4-rg/providers/Microsoft.App/managedEnvironments/%s", f4Sub, envName))
	_, _ = c.DeleteRaw(ctx, envPath, "2023-05-01")
	envBody := map[string]any{
		"location":   "eastus",
		"properties": map[string]any{},
	}
	if _, _, _, err := c.PutWithETag(ctx, envPath, "2023-05-01", "", envBody, new(map[string]any)); err != nil {
		t.Fatalf("provision managedEnvironment: %v", err)
	}
	defer c.DeleteRaw(ctx, envPath, "2023-05-01")

	caName := "f4-ca"
	caPath := containerAppARMPath(f4Sub, "f4-rg", caName)
	_, _ = c.DeleteRaw(ctx, caPath, containerAppFallbackAPIVersion)

	r := &containerAppResource{}
	f4Configure(t, r, c)
	s := f4Schema(t, r)

	mkCfg := func(image string, tags map[string]string) map[string]any {
		return map[string]any{
			"name":                         caName,
			"resource_group_name":          "f4-rg",
			"container_app_environment_id": envPath,
			"revision_mode":                "Single",
			"tags":                         tags,
			"secret": []any{
				map[string]any{"name": "s1", "value": "sv1"},
			},
			"ingress": []any{
				map[string]any{
					"external_enabled": true,
					"target_port":      int64(8080),
					"transport":        "auto",
				},
			},
			"template": []any{
				map[string]any{
					"min_replicas": int64(1),
					"max_replicas": int64(2),
					"container": []any{
						map[string]any{
							"name":   "c1",
							"image":  image,
							"cpu":    float64(0.5),
							"memory": "0.5Gi",
							"env": []any{
								map[string]any{"name": "E1", "value": "v1"},
							},
						},
					},
				},
			},
		}
	}

	var createResp resource.CreateResponse
	createResp.State = f4State(s)
	r.Create(ctx, resource.CreateRequest{
		Config: f4Config(t, s, mkCfg("nginx:1.25", map[string]string{"f4": "1"})),
		Plan:   f4Plan(t, s, mkCfg("nginx:1.25", map[string]string{"f4": "1"})),
	}, &createResp)
	f4Diags(t, "create", createResp.Diagnostics)

	var app containerAppModel
	f4Diags(t, "create state", createResp.State.Get(ctx, &app))
	if app.ID.ValueString() == "" || app.Location.ValueString() != "eastus" {
		t.Fatalf("create: id=%q location=%q", app.ID.ValueString(), app.Location.ValueString())
	}
	if len(app.Secret) != 1 || app.Secret[0].Value.ValueString() != "sv1" {
		t.Fatalf("create: secrets=%+v", app.Secret)
	}

	// Wire contract: memory NUMERIC on the wire (2023-05-01 plane rejects
	// "0.5Gi" strings; provider coerces).
	out, status := f4RawGET(t, c, caPath, containerAppFallbackAPIVersion)
	if status != 200 {
		t.Fatalf("raw GET after create: %d", status)
	}
	props, _ := out["properties"].(map[string]any)
	tmpl, _ := props["template"].(map[string]any)
	containers, _ := tmpl["containers"].([]any)
	if len(containers) == 0 {
		t.Fatalf("no containers on wire: %v", props["template"])
	}
	c1, _ := containers[0].(map[string]any)
	res, _ := c1["resources"].(map[string]any)
	if _, isStr := res["memory"].(string); isStr {
		t.Fatalf("wire memory is a string %v; numeric contract broken", res["memory"])
	}

	// Wire contract: secrets are write-only — GET must omit value.
	configuration, _ := props["configuration"].(map[string]any)
	wireSecrets, _ := configuration["secrets"].([]any)
	for _, ws := range wireSecrets {
		wsm, _ := ws.(map[string]any)
		if _, echoed := wsm["value"]; echoed {
			t.Fatalf("wire secret echoed value: %v", wsm)
		}
	}

	// Read keeps the prior secret value in state.
	var readResp resource.ReadResponse
	readResp.State = createResp.State
	r.Read(ctx, resource.ReadRequest{State: createResp.State}, &readResp)
	f4Diags(t, "read", readResp.Diagnostics)
	var app2 containerAppModel
	f4Diags(t, "read state", readResp.State.Get(ctx, &app2))
	if len(app2.Secret) != 1 || app2.Secret[0].Value.ValueString() != "sv1" {
		t.Fatalf("read: prior secret not kept: %+v", app2.Secret)
	}
	if got := app2.Template[0].Container[0].Memory.ValueString(); got != "0.5Gi" {
		t.Fatalf("read: memory roundtrip %q", got)
	}

	// Update: change image + tags; ingress honored on update.
	var updResp resource.UpdateResponse
	updResp.Private = createResp.Private
	updResp.State = createResp.State
	r.Update(ctx, resource.UpdateRequest{
		Config:  f4Config(t, s, mkCfg("nginx:1.27", map[string]string{"f4": "2"})),
		Plan:    f4Plan(t, s, mkCfg("nginx:1.27", map[string]string{"f4": "2"})),
		State:   createResp.State,
		Private: createResp.Private,
	}, &updResp)
	f4Diags(t, "update", updResp.Diagnostics)

	out2, status := f4RawGET(t, c, caPath, containerAppFallbackAPIVersion)
	if status != 200 {
		t.Fatalf("raw GET after update: %d", status)
	}
	if fmt.Sprint(out2["tags"]) != "map[f4:2]" {
		t.Fatalf("update: tags=%v", out2["tags"])
	}
	p2, _ := out2["properties"].(map[string]any)
	t2, _ := p2["template"].(map[string]any)
	c2list, _ := t2["containers"].([]any)
	var gotImage any
	if len(c2list) > 0 {
		c2w := c2list[0].(map[string]any)
		gotImage = c2w["image"]
	}
	if gotImage != "nginx:1.27" {
		t.Fatalf("update: image=%v", gotImage)
	}
	configuration2, _ := p2["configuration"].(map[string]any)
	ing, _ := configuration2["ingress"].(map[string]any)
	if ing == nil || ing["targetPort"] != float64(8080) {
		t.Fatalf("update: ingress=%v", configuration2["ingress"])
	}

	// Delete, then confirm 404 on the wire.
	var delResp resource.DeleteResponse
	r.Delete(ctx, resource.DeleteRequest{State: updResp.State, Private: updResp.Private}, &delResp)
	f4Diags(t, "delete", delResp.Diagnostics)
	if _, status := f4RawGET(t, c, caPath, containerAppFallbackAPIVersion); status != 404 {
		t.Fatalf("container app %s still present after DELETE (status %d)", caName, status)
	}
}
