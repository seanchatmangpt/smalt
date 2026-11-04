package azure

import (
	"reflect"
	"testing"

	"smalt.dev/posh/internal/dialect/azure/kv7"
)

// fixtureStoreRow is the shape-court fixture: the store row shape the BEAM
// PUT mints (KvRoutes.ex put /secrets/:name — value, id, attributes, plus
// KD-S3 bookkeeping members).
func fixtureStoreRow() map[string]any {
	return map[string]any{
		"value":          "s3cr3t",
		"id":             "https://v.vault.azure.net/secrets/s/uuid-v4",
		"attributes":     map[string]any{"enabled": true, "created": 1700000000, "updated": 1700000000},
		"contentType":    "text/plain",
		"version":        "uuid-v4",
		"versions":       []string{"uuid-v4"},
		"created_seq":    int64(7),
		"is_version_row": true,
	}
}

// TestKv7BundleShapePerFace is the shape-level court (P-h step 3): the
// translate must produce the BEAM-compatible SecretBundle shape per face —
// value present on point-get, absent on list, present on versions-list
// (registered divergence the face's own law records), bookkeeping keys
// never on any face.
func TestKv7BundleShapePerFace(t *testing.T) {
	row := fixtureStoreRow()
	bookkeeping := []string{"versions", "created_seq", "is_version_row", "version_rows"}

	// point-get face: value PRESENT.
	pt, err := RenderSecretBundle(kv7.FacePointGetPatch, row)
	if err != nil {
		t.Fatalf("point-get: %v", err)
	}
	if pt["value"] != "s3cr3t" {
		t.Fatalf("point-get face dropped the value (KD-03 split-brain regression): %v", pt)
	}
	for _, k := range []string{"version", "versions", "created_seq", "is_version_row"} {
		if _, ok := pt[k]; ok {
			t.Fatalf("point-get face leaked %q", k)
		}
	}

	// list face: value ABSENT.
	ls, err := RenderSecretBundle(kv7.FaceList, row)
	if err != nil {
		t.Fatalf("list face: %v", err)
	}
	if _, ok := ls["value"]; ok {
		t.Fatalf("list face leaked the value (KD-03): %v", ls)
	}

	// versions-list face: value present (registered divergence).
	vl, err := RenderSecretBundle(kv7.FaceVersionsList, row)
	if err != nil {
		t.Fatalf("versions-list: %v", err)
	}
	if vl["value"] != "s3cr3t" {
		t.Fatalf("versions-list face dropped the value (its face law keeps it): %v", vl)
	}

	// engine soft-delete face: value ABSENT.
	sd, err := RenderSecretBundle(kv7.FaceEngineSoftDel, row)
	if err != nil {
		t.Fatalf("soft-delete: %v", err)
	}
	if _, ok := sd["value"]; ok {
		t.Fatalf("soft-delete face leaked the value: %v", sd)
	}

	// bookkeeping keys never on ANY face.
	for face, bundle := range map[string]map[string]any{
		kv7.FacePointGetPatch: pt,
		kv7.FaceList:          ls,
		kv7.FaceVersionsList:  vl,
		kv7.FaceEngineSoftDel: sd,
	} {
		for _, k := range bookkeeping {
			if _, ok := bundle[k]; ok {
				t.Fatalf("face %s leaked bookkeeping key %q", face, k)
			}
		}
	}

	// the store row was never mutated (projection, not in-place).
	if row["value"] != "s3cr3t" || len(row["versions"].([]string)) != 1 {
		t.Fatalf("fixture row mutated by translate: %v", row)
	}
}

// TestKv7RouteOpsBoundToFamiliesRows pins the binding: every kv7 route row
// in families.go resolves a translate handler; and the wire shape per op
// agrees with the BEAM oracle (value present on point/version faces,
// absent on list/delete faces).
func TestKv7RouteOpsBoundToFamiliesRows(t *testing.T) {
	row := fixtureStoreRow()

	pointOps := []string{
		"azure.kv7.secrets.put", "azure.kv7.secrets.get", "azure.kv7.secrets.patch",
		"azure.kv7.secrets.version.get", "azure.kv7.deletedsecrets.recover",
	}
	for _, op := range pointOps {
		h, ok := Kv7TranslateFor(op)
		if !ok {
			t.Fatalf("kv7 route op %q has no translate handler (unwired face)", op)
		}
		_, body, err := h(map[string]string{"name": "s"}, row)
		if err != nil {
			t.Fatalf("%s: %v", op, err)
		}
		if body["value"] != "s3cr3t" {
			t.Fatalf("%s: point face dropped the value (BEAM oracle KvRoutes.ex: value on point faces)", op)
		}
	}

	listOps := []string{
		"azure.kv7.secrets.list", "azure.kv7.deletedsecrets.list",
		"azure.kv7.secrets.delete", "azure.kv7.deletedsecrets.get", "azure.kv7.deletedsecrets.purge",
	}
	for _, op := range listOps {
		h, ok := Kv7TranslateFor(op)
		if !ok {
			t.Fatalf("kv7 route op %q has no translate handler (unwired face)", op)
		}
		_, body, err := h(map[string]string{"name": "s"}, row)
		if err != nil {
			t.Fatalf("%s: %v", op, err)
		}
		if op == "azure.kv7.secrets.list" || op == "azure.kv7.deletedsecrets.list" {
			env, ok := body["value"].([]any)
			if !ok || len(env) == 0 {
				t.Fatalf("%s: missing list envelope", op)
			}
			body = env[0].(map[string]any)
		}
		if _, ok := body["value"]; ok {
			t.Fatalf("%s: leaked the value on a no-value face (BEAM oracle)", op)
		}
	}

	// versions list: envelope + value present.
	h, _ := Kv7TranslateFor("azure.kv7.secrets.versions")
	_, body, err := h(map[string]string{"name": "s"}, row)
	if err != nil {
		t.Fatalf("versions: %v", err)
	}
	env := body["value"].([]any)
	b0 := env[0].(map[string]any)
	if b0["value"] != "s3cr3t" {
		t.Fatalf("versions face dropped the value (its face law keeps it)")
	}

	// version.get with a mismatched path version fails loudly.
	h, _ = Kv7TranslateFor("azure.kv7.secrets.version.get")
	if _, _, err := h(map[string]string{"name": "s", "version": "other"}, row); err == nil {
		t.Fatalf("version.get accepted a mismatched path version silently")
	}
}

// TestKv7TranslateSeamOnFamilies pins the admission-path seam: TranslateFor
// answers kv7 family rows and misses loudly for every other family.
func TestKv7TranslateSeamOnFamilies(t *testing.T) {
	reg := NewRegistry()
	RegisterFirstFamilies(reg)
	fam, err := NewFamilies(reg, FirstFamilyRoutes())
	if err != nil {
		t.Fatalf("families: %v", err)
	}
	route, ok := fam.ResolveRoute("GET", "/secrets/s")
	if !ok || route.Family != "kv7" {
		t.Fatalf("kv7 route not resolved: %+v ok=%v", route, ok)
	}
	h, ok := fam.TranslateFor(route)
	if !ok {
		t.Fatalf("kv7 route %q has no translate handler", route.RouteOp)
	}
	_, body, err := h(map[string]string{"name": "s"}, fixtureStoreRow())
	if err != nil {
		t.Fatalf("translate: %v", err)
	}
	if body["value"] != "s3cr3t" {
		t.Fatalf("admission-path translate dropped the value: %v", body)
	}

	nonKv7, ok := fam.ResolveRoute("GET", "/subscriptions/sub/resourcegroups/rg/providers/Microsoft.Network/dnsZones/z")
	if !ok || nonKv7.Family == "kv7" {
		t.Fatalf("expected a non-kv7 route, got %+v", nonKv7)
	}
	if _, ok := fam.TranslateFor(nonKv7); ok {
		t.Fatalf("non-kv7 family %q answered a kv7 translate handler", nonKv7.Family)
	}
}

// TestKv7DelegationBindings pins the delegation law: the translate-level
// functions answer exactly what the kv7 law answers (one law, delegation
// bindings — no re-stated drop-lists, latest law, lifecycle, or id grammar).
func TestKv7DelegationBindings(t *testing.T) {
	// latest-by-last-write: NOT lexical order (KD-S4).
	index := []kv7.VersionRow{
		{Version: "aaa", CreatedSeq: 1},
		{Version: "zzz", CreatedSeq: 3},
		{Version: "mmm", CreatedSeq: 2},
	}
	if got := Kv7LatestByLastWrite(index); got != "zzz" {
		t.Fatalf("latest resolved lexically, not by last write: %q", got)
	}
	if got := Kv7LatestByLastWrite(nil); got != "" {
		t.Fatalf("empty history: got %q", got)
	}

	// lifecycle refusals (KD-102) + typed statuses.
	s, err := Kv7LifecycleStep("", "delete", false)
	if err != nil || s != kv7.StateDeleted {
		t.Fatalf("delete: %v %v", s, err)
	}
	if _, err := Kv7LifecycleStep(kv7.StateAlive, "recover", false); err == nil {
		t.Fatalf("recover of alive refused silently")
	}
	if _, err := Kv7LifecycleStep(kv7.StateDeleted, "purge", true); err == nil {
		t.Fatalf("purge-protected purge admitted silently")
	} else if got := Kv7RefusalStatus(kv7.ErrConflictPurgeProt); got != 409 {
		t.Fatalf("purge-protection status = %d, want 409", got)
	}
	if got := Kv7RefusalStatus(kv7.ErrNotFound); got != 404 {
		t.Fatalf("SecretNotFound status = %d, want 404", got)
	}

	// id grammar delegation.
	vault, name, ver, err := ParseKv7DataPlaneID("https://myvault.vault.azure.net/secrets/s1")
	if err != nil || vault != "myvault" || name != "s1" || ver != "" {
		t.Fatalf("parse versionless: %q %q %q %v", vault, name, ver, err)
	}
	if _, _, _, err := ParseKv7DataPlaneID("/subscriptions/x/resourceGroups/y"); err == nil {
		t.Fatalf("ARM id accepted by the kv7 data-plane grammar")
	}

	// unknown face is a loud error, never a silent pass.
	if _, err := RenderSecretBundle("made-up-face", fixtureStoreRow()); err == nil {
		t.Fatalf("unknown face admitted silently")
	}
	if !reflect.DeepEqual(kv7.Bundles[kv7.FaceARM].DropKeys, []string{}) {
		t.Fatalf("ARM face law drifted")
	}
}
