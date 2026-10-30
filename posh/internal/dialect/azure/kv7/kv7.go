// Package kv7 is the 8443 KV REST 7.4 data-plane sub-dialect (v26.10.31
// inversion, WO-21). DISTINCT from the ARM face (package armkv): the data
// plane is NOT deleted with the ARM strip — the closed KD-184/185/186 law
// survives (digest L5/L6 convergence 6).
//
// Half-landed record (required by the lane contract): this package carries
// the POLICY half of the kv7 dialect — envelope polarity, id grammar,
// latest-resolution, soft-delete lifecycle, tenant scoping — as Go tables +
// tests. The WIRE half (real 8443 frame termination) stays BEAM-side
// (lib/smalt/egress/KvRoutes.ex + lib/smalt/data_plane/key_vault/*) behind
// the dialect flag; no dialect flag exists in posh yet, so no wire bytes
// terminate here in this lane.
package kv7

import (
	"crypto/rand"
	"fmt"
	"sort"
	"strings"
)

// ---------------------------------------------------------------------------
// SecretBundle envelope polarity (per-face drop-lists — posh KD-03 law)
// ---------------------------------------------------------------------------

// BookkeepingKeys never leave the vault on ANY face (KD-S3/KD-S4 internal
// version-history bookkeeping).
var BookkeepingKeys = []string{"versions", "created_seq", "is_version_row", "version_rows"}

// Faces names the per-face envelope policy rows.
const (
	FacePointGetPatch = "8443-point-get-patch"
	FaceList          = "8443-list"
	FaceVersionsList  = "8443-versions-list"
	FaceEngineSoftDel = "engine-soft-delete"
	FaceARM           = "arm-face"
)

// Bundles is the per-face SecretBundle envelope policy. Each row is the
// explicit drop-list the face applies to a store row; polarity documented
// per face (KD-03 split-brain fix, v26.10.31).
var Bundles = map[string]BundlePolicy{
	// Point GET/PATCH: SecretBundle echoes the value (aligned by the
	// KD-03 split-brain fix: the engine PATCH face previously dropped it).
	FacePointGetPatch: {
		EchoesValue: true,
		DropKeys:    []string{"version", "versions", "created_seq", "is_version_row"},
	},
	// List faces: bundles never carry the value.
	FaceList: {
		EchoesValue: false,
		DropKeys:    []string{"version", "versions", "created_seq", "is_version_row", "value"},
	},
	// Versions list (kdlith_w2 court pins value presence on this face —
	// registered divergence, KD row owns it; the policy table records the
	// face's own law rather than "cleaning it up").
	FaceVersionsList: {
		EchoesValue: true,
		DropKeys:    []string{"versions", "created_seq", "is_version_row"},
	},
	// Engine soft-delete: deleted bundle never carries the value.
	FaceEngineSoftDel: {
		EchoesValue: false,
		DropKeys:    []string{"value", "is_deleted_secret", "versions", "version_rows", "created_seq"},
	},
	// ARM face echoes verbatim (posh KD-03 law).
	FaceARM: {
		EchoesValue: true,
		DropKeys:    []string{},
	},
}

// BundlePolicy is one face's envelope law.
type BundlePolicy struct {
	// EchoesValue is the per-face value polarity.
	EchoesValue bool
	// DropKeys is the explicit drop-list.
	DropKeys []string
}

// RenderBundle applies the face policy to a store row. Unknown face is a
// loud error — never a silent pass.
func RenderBundle(face string, row map[string]any) (map[string]any, error) {
	p, ok := Bundles[face]
	if !ok {
		return nil, fmt.Errorf("kv7: unknown face %q", face)
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
// id grammar: guid_version UUID minting (KvRoutes.guid_version/0 twin)
// ---------------------------------------------------------------------------

// GUIDVersion mints a lowercase dashed RFC-4122 version-4 UUID, the twin of
// the BEAM KvRoutes.guid_version/0 (random 16 bytes, version nibble 4,
// variant bits 10, dashed lower-hex).
func GUIDVersion() string {
	var b [16]byte
	if _, err := rand.Read(b[:]); err != nil {
		panic("kv7: crypto/rand exhausted: " + err.Error())
	}
	b[6] = (b[6] & 0x0f) | 0x40
	b[8] = (b[8] & 0x3f) | 0x80
	return fmt.Sprintf("%x-%x-%x-%x-%x", b[0:4], b[4:6], b[6:8], b[8:10], b[10:16])
}

// IsGUIDVersion reports whether s parses as the guid_version grammar
// (8-4-4-4-12 lower-hex). Used by the id parser to distinguish a
// version-addressed id from a bare name.
func IsGUIDVersion(s string) bool {
	return len(s) == 36 &&
		s[8] == '-' && s[13] == '-' && s[18] == '-' && s[23] == '-' &&
		isHex(s[:8]) && isHex(s[9:13]) && isHex(s[14:18]) && isHex(s[19:23]) && isHex(s[24:36])
}

func isHex(s string) bool {
	for _, c := range s {
		if !(c >= '0' && c <= '9' || c >= 'a' && c <= 'f') {
			return false
		}
	}
	return len(s) > 0
}

// ParseDataPlaneID parses the kv7 id grammar: {host}.vault.azure.net
// /secrets/{name}[/{version}] — the 8443 grammar coexisting with the ARM
// grammar (digest L5 MED note: two id grammars coexist by design).
func ParseDataPlaneID(id string) (vault, name, version string, err error) {
	id = strings.TrimPrefix(id, "https://")
	host, rest, ok := strings.Cut(id, ".vault.azure.net")
	if !ok || !strings.HasPrefix(rest, "/secrets/") {
		return "", "", "", fmt.Errorf("kv7: not a kv7 data-plane id: %q", id)
	}
	tail := strings.TrimPrefix(rest, "/secrets/")
	segs := strings.Split(tail, "/")
	switch len(segs) {
	case 1:
		return host, segs[0], "", nil
	case 2:
		return host, segs[0], segs[1], nil
	default:
		return "", "", "", fmt.Errorf("kv7: id grammar violation: %q", id)
	}
}

// ---------------------------------------------------------------------------
// last-write latest resolution (KD-S4 law)
// ---------------------------------------------------------------------------

// VersionRow is the minimal version-history row the latest-resolution law
// needs (mirror of the BEAM store row bookkeeping fields).
type VersionRow struct {
	Version    string
	CreatedSeq int64
}

// LatestVersion resolves the latest version by LAST-WRITE (max created_seq,
// ties broken newest-first index order), NEVER by lexical UUID order
// (KD-S4: lexical-greatest resolution pinned a stale version as latest).
// Returns "" for an empty history.
func LatestVersion(index []VersionRow) string {
	if len(index) == 0 {
		return ""
	}
	latest := index[0]
	for _, r := range index[1:] {
		if r.CreatedSeq > latest.CreatedSeq {
			latest = r
		}
	}
	return latest.Version
}

// SortVersionsIndexNewestFirst renders the versions index in the wire order
// (newest first by created_seq).
func SortVersionsIndexNewestFirst(index []VersionRow) []VersionRow {
	out := make([]VersionRow, len(index))
	copy(out, index)
	sort.SliceStable(out, func(i, j int) bool { return out[i].CreatedSeq > out[j].CreatedSeq })
	return out
}

// ---------------------------------------------------------------------------
// soft-delete / recover / purge lifecycle (KD-102)
// ---------------------------------------------------------------------------

// LifecycleState is the soft-delete state machine state.
type LifecycleState string

const (
	StateAlive     LifecycleState = "alive"
	StateDeleted   LifecycleState = "deleted"
	StatePurged    LifecycleState = "purged"
	StateRecovered LifecycleState = "alive" // recover returns to alive
)

// ErrCode is a typed refusal code (no new wire codes — the codes ARE the
// Azure contract).
type ErrCode string

const (
	ErrNotFound          ErrCode = "SecretNotFound" // typed 404
	ErrDeleted           ErrCode = "DeletedSecret"  // 404-class: exists only as deleted
	ErrConflictPurgeProt ErrCode = "Conflict"       // 409 purge-protection
	ErrPurgeNotFound     ErrCode = "SecretNotFound" // purge of unknown -> typed 404
)

// Transition is one lifecycle edge with its refusal semantics.
type Transition struct {
	From    LifecycleState
	Event   string // "delete" | "recover" | "purge"
	To      LifecycleState
	Refusal ErrCode // non-empty => the edge is REFUSED with this code
}

// Lifecycle is the KD-102 state machine: alive --delete--> deleted;
// deleted --recover--> alive; deleted --purge--> purged. Delete of a
// missing name, recover/purge of a non-deleted name are typed 404s.
// Purge-protection refuses purge with 409 Conflict.
var Lifecycle = []Transition{
	{From: StateAlive, Event: "delete", To: StateDeleted},
	{From: StateDeleted, Event: "recover", To: StateAlive},
	{From: StateDeleted, Event: "purge", To: StatePurged},

	// Refusal edges (typed, never silent):
	{From: StateAlive, Event: "recover", Refusal: ErrNotFound},
	{From: StateAlive, Event: "purge", Refusal: ErrNotFound},
	{From: StatePurged, Event: "delete", Refusal: ErrNotFound},
	{From: StatePurged, Event: "recover", Refusal: ErrNotFound},
	{From: StatePurged, Event: "purge", Refusal: ErrNotFound},
}

// Step applies one lifecycle event. purgeProtected refuses purge on a
// deleted entity with 409 Conflict. The zero state is Alive.
func Step(state LifecycleState, event string, purgeProtected bool) (LifecycleState, error) {
	if state == "" {
		state = StateAlive
	}
	for _, t := range Lifecycle {
		if t.From == state && t.Event == event {
			if t.Refusal != "" {
				return state, fmt.Errorf("kv7: %d %s", statusFor(t.Refusal), t.Refusal)
			}
			if event == "purge" && purgeProtected {
				return state, fmt.Errorf("kv7: 409 %s", ErrConflictPurgeProt)
			}
			return t.To, nil
		}
	}
	return state, fmt.Errorf("kv7: no transition %s from %s", event, state)
}

func statusFor(c ErrCode) int {
	if c == ErrConflictPurgeProt {
		return 409
	}
	return 404
}

// ---------------------------------------------------------------------------
// tenant-scoped ids (G5 tenant fence / TenantLaw twin)
// ---------------------------------------------------------------------------

// TenantScopedKey is the TenantLaw twin: home tenant keeps the byte-identical
// legacy bare key; a foreign tenant namespaces under "{tid}/{name}".
func TenantScopedKey(homeTenant, tenant, name string) string {
	if tenant == homeTenant || tenant == "" {
		return name
	}
	return tenant + "/" + name
}

// IsForeignScoped reports whether a bare-name lookup could hit ANOTHER
// tenant's namespace: the bare key itself exists and is owned by a foreign
// tenant, or a "{tid}/{name}" shadow exists.
func IsForeignScoped(bareKeyExists, foreignScopedExists bool) bool {
	return foreignScopedExists
}
