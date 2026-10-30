package azure

import (
	"reflect"
	"testing"
)

// --- KD-05 memory coercion ---------------------------------------------------

func TestParseMemoryGiB(t *testing.T) {
	cases := []struct {
		in   string
		want float64
	}{{"1.0Gi", 1.0}, {"1.5Gi", 1.5}, {"2G", 2}, {"512Mi", 512}, {"512M", 512},
		{"", 0.5}, {"garbage", 0.5}, {"0", 0.5}, {"-1Gi", 0.5}}
	for _, c := range cases {
		if got := ParseMemoryGiB(c.in); got != c.want {
			t.Fatalf("ParseMemoryGiB(%q)=%v want %v", c.in, got, c.want)
		}
	}
}

func TestCoerceNumericMemoryInBodyTable(t *testing.T) {
	mk := func(mem any, typed bool) map[string]any {
		if typed {
			return map[string]any{"properties": map[string]any{"template": map[string]any{
				"containers": []map[string]any{{"resources": map[string]any{"memory": mem}}}}}}
		}
		return map[string]any{"properties": map[string]any{"template": map[string]any{
			"containers": []any{map[string]any{"resources": map[string]any{"memory": mem}}}}}}
	}
	cases := []struct {
		name string
		body map[string]any
		want any
	}{
		{"1.5Gi typed slice", mk("1.5Gi", true), 1536},
		{"1.0Gi any slice", mk("1.0Gi", false), 1024},
		{"0.5Gi", mk("0.5Gi", true), 512},
		{"unparseable falls back 0.5GiB", mk("garbage", true), 512},
	}
	for _, c := range cases {
		body := c.body
		CoerceNumericMemoryInBody(body)
		var got any
		if typedBody, ok := body["properties"].(map[string]any)["template"].(map[string]any)["containers"].([]map[string]any); ok {
			got = typedBody[0]["resources"].(map[string]any)["memory"]
		} else {
			got = body["properties"].(map[string]any)["template"].(map[string]any)["containers"].([]any)[0].(map[string]any)["resources"].(map[string]any)["memory"]
		}
		if got != c.want {
			t.Fatalf("%s: got %v want %v", c.name, got, c.want)
		}
	}
}

// Mutation probe KD-05: a wrong translation (string passthrough or a
// bytes-scale error) must FAIL the expectation — the probe is live only if
// the correct output differs from every plausible wrong translation.
func TestMutationKD05WrongTranslationFails(t *testing.T) {
	body := mkContainerBody("1.5Gi")
	CoerceNumericMemoryInBody(body)
	got := extractMemory(body)
	if got != any(1536) {
		t.Fatalf("correct translation wrong: %v", got)
	}
	wrongs := []any{"1.5Gi", 1610612736, 1.5, 1536.0}
	for _, w := range wrongs {
		if got == w {
			t.Fatalf("mutation probe dead: correct output %v equals wrong translation %v", got, w)
		}
	}
}

// --- KD-04 traffic strip -------------------------------------------------------

func TestStripCreateTraffic(t *testing.T) {
	mk := func(withTraffic bool) map[string]any {
		ing := map[string]any{"targetPort": 80}
		if withTraffic {
			ing["traffic"] = []any{map[string]any{"latestRevision": true, "weight": 100}}
		}
		return map[string]any{"properties": map[string]any{
			"configuration": map[string]any{"ingress": ing}}}
	}
	b := mk(true)
	if !StripCreateTraffic(b) {
		t.Fatal("traffic block not stripped")
	}
	ing := b["properties"].(map[string]any)["configuration"].(map[string]any)["ingress"].(map[string]any)
	if _, present := ing["traffic"]; present {
		t.Fatal("traffic key still present after strip")
	}
	if StripCreateTraffic(mk(false)) {
		t.Fatal("stripped when no traffic present")
	}
	if StripCreateTraffic(map[string]any{}) {
		t.Fatal("stripped on empty body")
	}
}

// Mutation probe KD-04: a no-strip translation must FAIL.
func TestMutationKD04NoStripFails(t *testing.T) {
	body := mkContainerBodyTraffic()
	if !StripCreateTraffic(body) {
		t.Fatal("strip did not fire on a traffic-bearing create body")
	}
	if _, present := body["properties"].(map[string]any)["configuration"].(map[string]any)["ingress"].(map[string]any)["traffic"]; present {
		t.Fatal("traffic survived the strip — a no-strip mutation would pass this suite")
	}
}

// --- dual-key (#6) ---------------------------------------------------------------

func TestEnvIDDualKey(t *testing.T) {
	props := map[string]any{}
	WriteEnvIDDualKey(props, "/subscriptions/s1/resourceGroups/rg1/providers/Microsoft.App/managedEnvironments/env1")
	if props["managedEnvironmentId"] != props["environmentId"] {
		t.Fatal("dual-key not written symmetric")
	}
	p2 := map[string]any{"managedEnvironmentId": "A", "environmentId": "B"}
	if got := ReadEnvIDDualKey(p2); got != "A" {
		t.Fatalf("read preference wrong: %q", got)
	}
	p3 := map[string]any{"environmentId": "B"}
	if got := ReadEnvIDDualKey(p3); got != "B" {
		t.Fatalf("fallback failed: %q", got)
	}
	if got := ReadEnvIDDualKey(map[string]any{}); got != "" {
		t.Fatal("empty when absent")
	}
}

// --- KV secret geometry (#2) -----------------------------------------------------

func TestBuildSecretIDGeometry(t *testing.T) {
	g := BuildSecretIDGeometry("Vault1", "sec1", "v9",
		"/subscriptions/s1/resourceGroups/rg1/providers/Microsoft.KeyVault/vaults/Vault1")
	want := SecretIDGeometry{
		Version:               "v9",
		VersionlessID:         "https://vault1.vault.azure.net/secrets/sec1",
		ID:                    "https://vault1.vault.azure.net/secrets/sec1/v9",
		ResourceVersionlessID: "/subscriptions/s1/resourceGroups/rg1/providers/Microsoft.KeyVault/vaults/Vault1/secrets/sec1",
		ResourceID:            "/subscriptions/s1/resourceGroups/rg1/providers/Microsoft.KeyVault/vaults/Vault1/secrets/sec1/versions/v9",
	}
	if !reflect.DeepEqual(g, want) {
		t.Fatalf("geometry mismatch:\n got %#v\nwant %#v", g, want)
	}
}

func TestDeterministicSecretVersion(t *testing.T) {
	v1 := DeterministicSecretVersion("V", "s", "x")
	v2 := DeterministicSecretVersion("v", "s", "x")
	if v1 != v2 {
		t.Fatal("vault-name casing must not change the version (ToLower law)")
	}
	if len(v1) != 32 {
		t.Fatalf("version length %d want 32 hex chars", len(v1))
	}
	if DeterministicSecretVersion("v", "s", "x") == DeterministicSecretVersion("v", "s", "y") {
		t.Fatal("digest insensitive to value — probe would pass under a broken mint")
	}
}

// --- mints (#3/#3a) ---------------------------------------------------------------

func TestMintDeterministicGUIDShape(t *testing.T) {
	g := MintDeterministicGUID("Contributor|/subscriptions/s1")
	if len(g) != 36 || g[8] != '-' || g[13] != '-' || g[18] != '-' || g[23] != '-' {
		t.Fatalf("GUID shape wrong: %q", g)
	}
	if g[14] != '5' {
		t.Fatalf("uuid5 version nibble wrong: %q", g[14])
	}
	if g[19] != '8' && g[19] != '9' && g[19] != 'a' && g[19] != 'b' {
		t.Fatalf("variant nibble not RFC4122: %q", g[19])
	}
	if MintDeterministicGUID("a") == MintDeterministicGUID("b") {
		t.Fatal("mint not input-sensitive")
	}
}

// Mutation probe KD-09: roleDef mint input is name|scope — a transposed
// assembly (scope|name) must produce a different GUID and FAIL.
func TestMutationKD09RoleDefMintOrder(t *testing.T) {
	got := MintRoleDefinitionGUID("Contributor", "/subscriptions/s1")
	want := MintDeterministicGUID("Contributor|/subscriptions/s1")
	if got != want {
		t.Fatalf("roleDef mint input assembly wrong: %q != %q", got, want)
	}
	if MintDeterministicGUID("/subscriptions/s1|Contributor") == want {
		t.Fatal("transposed mint collides with correct mint — probe dead")
	}
}

// Mutation probe: prefix law — each mint family must carry its exact
// provider prefix; a wrong prefix yields a different GUID and FAILs.
func TestMutationMintPrefixes(t *testing.T) {
	p := "/subscriptions/s1/resourceGroups/rg1/providers/Microsoft.X/y/z"
	cases := []struct {
		name, got, wrong string
	}{
		{"acr-pwd", MintAcrPassword(p), MintDeterministicGUID("acr-pwd2:" + p)},
		{"law-ws", MintLawWorkspaceID(p), MintDeterministicGUID("law-key:" + p)},
		{"law-key", MintLawSharedKey(p), MintDeterministicGUID("law-ws:" + p)},
		{"st-key", MintStorageKey(p), MintDeterministicGUID("st-keyX:" + p)},
	}
	for _, c := range cases {
		if c.got == c.wrong {
			t.Fatalf("%s: prefix mutation collides — probe dead", c.name)
		}
	}
}

// --- NormalizeARMID (#5) -----------------------------------------------------------

func TestNormalizeARMID(t *testing.T) {
	cases := []struct{ in, want string }{
		{"/subscriptions/S1/resourcegroups/RG1/providers/microsoft.keyvault/vaults/V1",
			"/subscriptions/S1/resourceGroups/RG1/providers/Microsoft.KeyVault/vaults/V1"},
		{"/subscriptions/s1/resourceGroups/rg1/providers/MICROSOFT.APP/containerapps/app1",
			"/subscriptions/s1/resourceGroups/rg1/providers/Microsoft.App/containerApps/app1"},
	}
	for _, c := range cases {
		if got := NormalizeARMID(c.in); got != c.want {
			t.Fatalf("NormalizeARMID(%q)=%q want %q", c.in, got, c.want)
		}
	}
}

// helpers ----------------------------------------------------------------------

func mkContainerBody(mem string) map[string]any {
	inner := map[string]any{"memory": mem}
	container := map[string]any{"resources": inner}
	containers := []any{container}
	template := map[string]any{"containers": containers}
	props := map[string]any{"template": template}
	return map[string]any{"properties": props}
}

func extractMemory(body map[string]any) any {
	return body["properties"].(map[string]any)["template"].(map[string]any)["containers"].([]any)[0].(map[string]any)["resources"].(map[string]any)["memory"]
}

func mkContainerBodyTraffic() map[string]any {
	entry := map[string]any{"weight": 100, "latestRevision": true}
	traffic := []any{entry}
	ing := map[string]any{"targetPort": 80, "traffic": traffic}
	cfg := map[string]any{"ingress": ing}
	props := map[string]any{"configuration": cfg}
	return map[string]any{"properties": props}
}
