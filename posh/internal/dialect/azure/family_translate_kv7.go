// kv7 translate half (P-h step 3, v26.10.31 mount step 2): delegation-only
// consumers of the kv7 law. Every translate-level function here DELEGATES to
// the kv7 package — no drop-list, lifecycle edge, latest-resolution law, or
// id grammar is re-stated in this file (KD-03 split-brain law: one law, N
// delegation bindings; a second copy of the drop-lists here would be the
// split-brain defect KD-03 closed).
//
// BEAM oracle: lib/smalt/egress/KvRoutes.ex:647-918 (+475-505 tenant gate /
// list projection) — the translate output must be byte-compatible with the
// BEAM SecretBundle wire shape (value present on point-get / versions-list
// faces, absent on the list face; bookkeeping keys never leave the vault).
package azure

import (
	"fmt"

	"smalt.dev/posh/internal/dialect/azure/kv7"
)

// ---------------------------------------------------------------------------
// Delegation bindings (each is a one-call delegate; zero re-stated law)
// ---------------------------------------------------------------------------

// RenderSecretBundle applies the face's SecretBundle envelope policy to a
// store row. DELEGATES to kv7.RenderBundle — the per-face drop-lists live
// ONLY in kv7.Bundles (KD-03). The input row is never mutated (the BEAM face
// renders projections, never mutating Store rows).
func RenderSecretBundle(face string, row map[string]any) (map[string]any, error) {
	out := make(map[string]any, len(row))
	for k, v := range row {
		out[k] = v
	}
	return kv7.RenderBundle(face, out)
}

// Kv7LatestByLastWrite resolves the latest version by LAST-WRITE (max
// created_seq). DELEGATES to kv7.LatestVersion (KD-S4: never lexical UUID
// order).
func Kv7LatestByLastWrite(index []kv7.VersionRow) string {
	return kv7.LatestVersion(index)
}

// Kv7LifecycleStep applies one soft-delete lifecycle event. DELEGATES to
// kv7.Step (KD-102 state machine, typed refusals).
func Kv7LifecycleStep(state kv7.LifecycleState, event string, purgeProtected bool) (kv7.LifecycleState, error) {
	return kv7.Step(state, event, purgeProtected)
}

// Kv7RefusalStatus maps a typed kv7 refusal code to its HTTP status.
// DELEGATES to kv7.StatusFor — the codes ARE the Azure contract, no new
// wire codes minted here.
func Kv7RefusalStatus(c kv7.ErrCode) int {
	return kv7.StatusFor(c)
}

// ParseKv7DataPlaneID parses the 8443 data-plane id grammar
// {host}.vault.azure.net/secrets/{name}[/{version}]. DELEGATES to
// kv7.ParseDataPlaneID (the two id grammars coexist by design, digest L5).
func ParseKv7DataPlaneID(id string) (vault, name, version string, err error) {
	return kv7.ParseDataPlaneID(id)
}

// ---------------------------------------------------------------------------
// Route-op translate handlers (admission-path wiring; sbdata/cosmosdata
// precedent: route rows carry the RouteOp name, the family's translate
// table answers the wire shape)
// ---------------------------------------------------------------------------

// Kv7Translate is one route op's translate handler: given the request's
// route params and the store row, answer (httpStatus, wireBody, error).
type Kv7Translate func(params map[string]string, row map[string]any) (int, map[string]any, error)

// bundleFor renders one SecretBundle face (status 200, translated bundle).
func bundleFor(face string, row map[string]any) (int, map[string]any, error) {
	b, err := RenderSecretBundle(face, row)
	if err != nil {
		return 0, nil, err
	}
	return 200, b, nil
}

// listFor renders the list envelope {"value": [bundle...]} for a face.
func listFor(face string, row map[string]any) (int, map[string]any, error) {
	b, err := RenderSecretBundle(face, row)
	if err != nil {
		return 0, nil, err
	}
	return 200, map[string]any{"value": []any{b}}, nil
}

// Kv7TranslateFor resolves the translate handler for a kv7 route op. An
// unknown op is a loud miss (ok=false) — never a silent pass; the families
// resolver turns a miss into a typed refusal at the admission path.
func Kv7TranslateFor(routeOp string) (Kv7Translate, bool) {
	h, ok := kv7RouteTranslate[routeOp]
	return h, ok
}

// TranslateFor is the admission-path seam: the Families resolver consults it
// after Route+OpSpec admission to answer the wire shape. Only the kv7 family
// carries translate handlers in this lane; other families miss loudly.
func (f *Families) TranslateFor(r Route) (Kv7Translate, bool) {
	if r.Family != "kv7" {
		return nil, false
	}
	return Kv7TranslateFor(r.RouteOp)
}

// kv7RouteTranslate maps the kv7 route ops (V2 route rows, families.go) to
// their face policies. The face names are the ONLY wire law stated here, and
// they are kv7 constants — the drop-lists themselves stay in kv7.Bundles
// (KD-03). If a route row's op name drifts, the binding test
// (TestKv7RouteOpsBoundToFamiliesRows) fails loudly rather than silently
// unwiring a face.
var kv7RouteTranslate = map[string]Kv7Translate{
	// point faces echo the value (KD-03 split-brain fix: the PATCH face
	// previously dropped it).
	"azure.kv7.secrets.put":   faceHandler(kv7.FacePointGetPatch),
	"azure.kv7.secrets.get":   faceHandler(kv7.FacePointGetPatch),
	"azure.kv7.secrets.patch": faceHandler(kv7.FacePointGetPatch),
	"azure.kv7.secrets.version.get": func(p map[string]string, row map[string]any) (int, map[string]any, error) {
		// version-addressed read: same envelope as the point face, and the
		// version segment must agree with the row's "version" member — a
		// mismatch is the wrong-version bundle on the wire (loud error).
		if v, ok := p["version"]; ok && row["version"] != nil && row["version"] != v {
			return 0, nil, fmt.Errorf("kv7: version mismatch: row %v != path %q", row["version"], v)
		}
		return bundleFor(kv7.FacePointGetPatch, row)
	},
	// delete answers the deleted-secret bundle: never carries the value
	// (engine soft-delete face).
	"azure.kv7.secrets.delete": faceHandler(kv7.FaceEngineSoftDel),
	// list faces: bundles never carry the value.
	"azure.kv7.secrets.list":        listHandler(kv7.FaceList),
	"azure.kv7.deletedsecrets.list": listHandler(kv7.FaceList),
	// versions list keeps the value (registered divergence, KD row owns it;
	// the face's own law is recorded in kv7.Bundles, not cleaned up here).
	"azure.kv7.secrets.versions": listHandler(kv7.FaceVersionsList),
	// deleted-secrets plane: read/recover/purge (KD-102). Read answers the
	// deleted bundle (no value); recover answers the live bundle shape
	// (point face); purge answers the deleted bundle (no value).
	"azure.kv7.deletedsecrets.get":     faceHandler(kv7.FaceEngineSoftDel),
	"azure.kv7.deletedsecrets.recover": faceHandler(kv7.FacePointGetPatch),
	"azure.kv7.deletedsecrets.purge":   faceHandler(kv7.FaceEngineSoftDel),
}

// faceHandler answers one SecretBundle (200) under the face policy.
func faceHandler(face string) Kv7Translate {
	return func(_ map[string]string, row map[string]any) (int, map[string]any, error) {
		return bundleFor(face, row)
	}
}

// listHandler answers the {"value": [...]} list envelope under the face
// policy.
func listHandler(face string) Kv7Translate {
	return func(_ map[string]string, row map[string]any) (int, map[string]any, error) {
		return listFor(face, row)
	}
}
