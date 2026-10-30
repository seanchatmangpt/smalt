// Package armkv is the ARM Key Vault sub-dialect (v26.10.31 inversion,
// WO-20): the 9443 ARM-face KV knowledge — value-echo polarity, id grammar
// minting, api-version gate, and the uuid5 roleDefinition GUID namespace —
// moves here from the BEAM core. The 8443 data plane is a DISTINCT
// sub-dialect (package kv7) and is NOT deleted (KD-184/185/186 law
// survives; digest L5/L6 convergence 6).
package armkv

import (
	"crypto/sha1"
	"encoding/hex"
	"fmt"
	"sort"
	"strings"
)

// BookkeepingKeys are dropped on every face: internal version-history
// bookkeeping (KD-S3/KD-S4) never leaves the vault on the wire.
var BookkeepingKeys = []string{"versions", "created_seq", "is_version_row"}

// FacePolarity is the per-face value-echo law (posh KD-03): whether a KV
// face echoes the secret value on the wire, and the exact drop-list applied
// to internal store rows before anything leaves the vault.
type FacePolarity struct {
	// Face names the wire face (matching the BEAM per-face table).
	Face string
	// EchoesValue is the polarity: point GET/PATCH and the ARM face echo
	// the value verbatim; list faces and engine soft-delete never do.
	EchoesValue bool
	// DropKeys is the explicit per-face drop-list applied to a store row
	// before it leaves the vault.
	DropKeys []string
}

// Polarities is the per-face polarity table, mirroring the BEAM drop-lists
// (lib/smalt/egress/AppConfigRoutes.ex public_secret_record/list_secret_record
// and lib/smalt/data_plane/key_vault/secrets.ex — KD-03 split-brain fix,
// v26.10.31).
var Polarities = []FacePolarity{
	{
		Face:        "8443-point-get-patch",
		EchoesValue: true,
		// Router point face + engine PATCH face (aligned by the KD-03
		// split-brain fix): value echoes; the bare-row "version" marker
		// drops with the bookkeeping.
		DropKeys: []string{"version", "versions", "created_seq", "is_version_row"},
	},
	{
		Face: "8443-list",
		// list_secret_record/1: public record minus value.
		EchoesValue: false,
		DropKeys:    []string{"version", "versions", "created_seq", "is_version_row", "value"},
	},
	{
		Face: "engine-soft-delete",
		// public_deleted_secret/1: deleted bundle carries recoveryId /
		// deletedDate / scheduledPurgeDate but never the value.
		EchoesValue: false,
		DropKeys:    []string{"value", "is_deleted_secret", "versions", "version_rows", "created_seq"},
	},
	{
		Face:        "arm-face",
		EchoesValue: true,
		// ARM face echoes verbatim (posh KD-03 law): the ARM-side record
		// is served as stored — no value drop, no re-render.
		DropKeys: []string{},
	},
}

// PolarityFor returns the polarity row for a face name.
func PolarityFor(face string) (FacePolarity, bool) {
	for _, p := range Polarities {
		if p.Face == face {
			return p, true
		}
	}
	return FacePolarity{}, false
}

// ApplyPolarity drops the face's keys from a store row rendered as a JSON
// object. It is the Go mirror of the BEAM Map.drop/2 drop-lists. Bookkeeping
// keys are dropped regardless of the face's own list (defense in depth).
func ApplyPolarity(face string, row map[string]any) (map[string]any, error) {
	p, ok := PolarityFor(face)
	if !ok {
		return nil, fmt.Errorf("armkv: unknown KV face %q", face)
	}
	out := make(map[string]any, len(row))
	for k, v := range row {
		out[k] = v
	}
	for _, k := range p.DropKeys {
		delete(out, k)
	}
	for _, k := range BookkeepingKeys {
		delete(out, k)
	}
	return out, nil
}

// ---------------------------------------------------------------------------
// id grammar minting
// ---------------------------------------------------------------------------

// MintDataPlaneID mints the ARM-face data-plane secret id grammar:
// https://{vault}.vault.azure.net/secrets/{name}[/{version}].
func MintDataPlaneID(vault, name, version string) string {
	var b strings.Builder
	b.WriteString("https://")
	b.WriteString(vault)
	b.WriteString(".vault.azure.net/secrets/")
	b.WriteString(name)
	if version != "" {
		b.WriteString("/")
		b.WriteString(version)
	}
	return b.String()
}

// MintARMID mints the ARM resource id for a vault:
// /subscriptions/{sub}/resourceGroups/{rg}/providers/Microsoft.KeyVault/vaults/{vault}
// (ARM casing of resourceGroups is canonical in the minted form).
func MintARMID(sub, rg, vault string) string {
	return strings.Join([]string{
		"", "subscriptions", sub, "resourceGroups", rg,
		"providers", "Microsoft.KeyVault", "vaults", vault,
	}, "/")
}

// ---------------------------------------------------------------------------
// api-version gate (KD-78 lattice, AKV ladder — L2)
// ---------------------------------------------------------------------------

// AdmittedAPIVersion is the AKV face pin (KV REST 7.4).
const AdmittedAPIVersion = "7.4"

// APIVersionAdmitted is the AKV api-version gate: absent stays admitted
// (KD-151 relaxed gate — legacy probes omit it), 7.x admitted, anything else
// (future 2099-01-01, bad formats) refused.
func APIVersionAdmitted(v string) bool {
	if v == "" {
		return true
	}
	if !strings.HasPrefix(v, "7.") {
		return false
	}
	minor := strings.TrimPrefix(v, "7.")
	if minor == "" {
		return false
	}
	for _, c := range minor {
		if c < '0' || c > '9' {
			return false
		}
	}
	return true
}

// ---------------------------------------------------------------------------
// uuid5 roleDefinition GUID namespace (KD-09 tf-state load-bearing)
// ---------------------------------------------------------------------------

// RoleDefUUIDNamespace is the FROZEN uuid5 namespace byte table lifted
// verbatim from the tf provider (resource_remaining_v1.go:36). The bytes are
// load-bearing for KD-09 tf state: a renamed/re-derived namespace mints
// different GUIDs for the same scope and silently invalidates tf state.
var RoleDefUUIDNamespace = []byte{106, 167, 184, 16, 157, 173, 17, 209, 128, 180, 0, 192, 79, 212, 48, 200}

// MintDeterministicGUID is the uuid5-style minter: sha1(namespace || input),
// version-5 / RFC-4122 variant bits set, dashed lowercase. Byte-identical to
// the tf provider's mintDeterministicGUID (resource_remaining_v1.go:38-51).
func MintDeterministicGUID(input string) string {
	h := sha1.New()
	h.Write(RoleDefUUIDNamespace)
	h.Write([]byte(input))
	digest := h.Sum(nil)
	digest[6] = (digest[6] & 0x0f) | 0x50
	digest[8] = (digest[8] & 0x3f) | 0x80
	hx := hex.EncodeToString(digest[:16])
	return fmt.Sprintf("%s-%s-%s-%s-%s", hx[0:8], hx[8:12], hx[12:16], hx[16:20], hx[20:32])
}

// SortKeys is a deterministic key sort for projections (used by tests and
// future generated renderers).
func SortKeys(m map[string]any) []string {
	ks := make([]string, 0, len(m))
	for k := range m {
		ks = append(ks, k)
	}
	sort.Strings(ks)
	return ks
}
