// Package azure — LRO envelope vocabulary (WO-19, wave-2 lane 14).
//
// The posh-owned port of the envelope half of
// Smalt.ArmGateway.Engine.Lro (lib/smalt/arm_gateway/engine/lro.ex):
//
//	lro_type?/1 + lro_async_update_type?/1 -> LroType / LroAsyncUpdateType
//	lro_wire_body/1 (KD-T5-F3 azurerm shim) -> LroCompactBody/LroWireBody
//	4 duplicated BEAM minters -> AsyncEnvelope (one function, per-face params)
//
// Per-face law preserved verbatim (wave-1 L3 MED row — do NOT unify):
// deletes mint location + retry-after ONLY (no azure-asyncoperation); creates
// mint the full azure-asyncoperation trio. The Elixir minters these collapse
// (engine/lro.ex async_put_response = create face; acr_router async_response =
// create face; container_groups / container_apps / subscription_router
// deletes = location+retry-after face) are BEAM faces pre-cutover; the
// dialect function is the collapsed form both stacks agree on by byte-parity
// court.
package azure

import (
	"bytes"
	"encoding/json"
	"sort"
	"strings"
)

// FaceKind selects which of the two registered 202 faces an envelope mint
// uses. The per-face table IS the registered divergence: do NOT unify.
type FaceKind int

const (
	// FaceCreate: PUT create -> 202 + full azure-asyncoperation trio + JSON
	// op body (engine/lro.ex async_put_response / acr_router async_response).
	FaceCreate FaceKind = iota
	// FaceDelete: DELETE -> 202 + location + retry-after ONLY, empty body
	// (subscription_router / container_groups_router / container_apps_router
	// delete minters).
	FaceDelete
)

// lroTypes is the KD-111 widened LRO-async set (azurerm polls these via
// Azure-AsyncOperation). Mirrors lro_type?/1 verbatim.
var lroTypes = map[string]bool{
	"Microsoft.Storage/storageAccounts":     true,
	"Microsoft.Compute/virtualMachines":     true,
	"Microsoft.ServiceBus/namespaces":       true,
	"Microsoft.EventHub/namespaces":         true,
	"Microsoft.KeyVault/vaults":             true,
	"Microsoft.DocumentDB/databaseAccounts": true,
}

// lroAsyncUpdateTypes is the original azurerm witness set whose PUT UPDATE is
// also async (the KD-111 widening deliberately keeps update sync per ARM /
// AZB-25b). Mirrors lro_async_update_type?/1 verbatim.
var lroAsyncUpdateTypes = map[string]bool{
	"Microsoft.Storage/storageAccounts": true,
	"Microsoft.Compute/virtualMachines": true,
}

// LroType reports whether the resource type is LRO-async on create.
func LroType(resourceType string) bool { return lroTypes[resourceType] }

// LroAsyncUpdateType reports whether the resource type is async on PUT update.
func LroAsyncUpdateType(resourceType string) bool { return lroAsyncUpdateTypes[resourceType] }

// OpRecord is the BEAM operation record wire shape (Jason-encoded by
// async_put_response). Field order is irrelevant — the parity court pins the
// sorted-key compact rendering.
type OpRecord struct {
	DelayMs     int64          `json:"delayMs"`
	EndTime     *string        `json:"endTime"`
	ID          string         `json:"id"`
	Name        string         `json:"name"`
	ResourceID  string         `json:"resourceId"`
	StartTime   *string        `json:"startTime"`
	StartedAtMs int64          `json:"startedAtMs"`
	Status      string         `json:"status"`
	Extra       map[string]any `json:"-"`
}

// Envelope is one 202 envelope half: headers to set plus the body bytes.
type Envelope struct {
	// Headers is ordered: header name -> value. Names are canonical wire
	// spellings (lowercase, as BEAM put_resp_header emits them).
	Headers [][2]string
	// Body is the exact response-body bytes ([]byte{} = empty, never nil).
	Body []byte
	// Status is the response status code (202 for both registered faces).
	Status int
}

// AsyncEnvelope is THE collapsed minter: one function over the per-face
// parameters (face, authority, operation). Replaces the 4 duplicated BEAM
// minters at the dialect tier.
//
//	authority: the request-authority origin (e.g. "http://www.example.com"),
//	           resolved from the client's seat — never hardcoded.
//	op:        the operation record (FaceCreate). The BEAM face emits
//	           Jason.encode!(op); the dialect emits the byte-identical
//	           sorted-key compact JSON rendering (parity-court pinned).
func AsyncEnvelope(face FaceKind, authority string, op *OpRecord) Envelope {
	pollURL := authority + op.ID

	switch face {
	case FaceCreate:
		return Envelope{
			Status: 202,
			Headers: [][2]string{
				{"azure-asyncoperation", pollURL},
				{"location", pollURL},
				{"retry-after", "1"},
			},
			Body: CompactJSON(op),
		}
	case FaceDelete:
		return Envelope{
			Status: 202,
			Headers: [][2]string{
				{"location", pollURL},
				{"retry-after", "1"},
			},
			// The BEAM delete minters emit send_json(202, "") -> empty body.
			Body: []byte{},
		}
	}

	panic("azure: unregistered FaceKind")
}

// LroWireBody is the KD-T5-F3 azurerm terminal-body shim: real ARM async
// terminal bodies carry only operation fields, but azurerm 4.54's storage LRO
// poller synthesizes the Terraform resource identity from the FINAL poll
// body, so the terminal wire body is enriched with the target resource's
// id/name/type plus its stored properties/location. Render-time transform
// only: the STORED operation record is untouched (KD-81).
//
// stored is the stored resource record lookup result
// (Store.get(:smalt_resources, downcased resourceId)); nil = not found, the
// enrichment halves degrade exactly like the BEAM version's fallback %{}.
func LroWireBody(op map[string]any, stored map[string]any) map[string]any {
	if s, ok := op["status"].(string); ok && s == "InProgress" {
		return op
	}

	out := map[string]any{}
	for k, v := range op {
		out[k] = v
	}

	if resID, ok := op["resourceId"].(string); ok && resID != "" {
		if stored != nil {
			if props, ok := stored["properties"].(map[string]any); ok {
				out["properties"] = props
			}
			if loc, ok := stored["location"].(string); ok {
				out["location"] = loc
			}
		}

		// identity enrichment: /subscriptions/<sub>/resourceGroups/<rg>/
		// providers/<ns>/<leaf>/<name> -> id/name/type; id/name/type win.
		if id, name, typ, ok := splitARMID(resID); ok {
			out["id"] = id
			out["name"] = name
			out["type"] = typ
		}
	}

	return out
}

// splitARMID mirrors the BEAM String.split case
// ["", "subscriptions", sub, "resourceGroups", rg, "providers", ns, leaf, name]
// — String.split keeps the leading empty segment, so routing.go's splitPath
// (empty-dropping, BEAM normalize law) is NOT used here.
func splitARMID(resID string) (id, name, typ string, ok bool) {
	parts := strings.Split(resID, "/")
	if len(parts) == 9 &&
		parts[0] == "" && parts[1] == "subscriptions" && parts[3] == "resourceGroups" &&
		parts[5] == "providers" {
		return resID, parts[8], parts[6] + "/" + parts[7], true
	}
	return "", "", "", false
}

// CompactJSON renders v as compact sorted-key JSON matching Jason.encode!/1
// byte-for-byte: no HTML escaping, no trailing newline, keys sorted (Jason
// emits maps in key order; encoding/json sorts map keys identically).
func CompactJSON(v any) []byte {
	var buf bytes.Buffer
	enc := json.NewEncoder(&buf)
	enc.SetEscapeHTML(false)
	if err := enc.Encode(v); err != nil {
		panic("azure: CompactJSON: " + err.Error())
	}
	// json.Encoder appends '\n'; Jason does not.
	return bytes.TrimSuffix(buf.Bytes(), []byte("\n"))
}

// sortedKeys is retained for dialect-table deterministic rendering helpers.
func sortedKeys(m map[string]bool) []string {
	keys := make([]string, 0, len(m))
	for k := range m {
		keys = append(keys, k)
	}
	sort.Strings(keys)
	return keys
}
