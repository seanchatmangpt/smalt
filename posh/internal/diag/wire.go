// Wire types for the neutral-core diagnostic vocabulary (GAP-04,
// docs/jira/posh/v26.10.31/gaps/04-diagnostic-vocabulary.md).
package diag

import (
	"errors"
	"fmt"
	"sort"
	"strings"

	"smalt.dev/posh/internal/api"
)

// Class is a neutral-core diagnostic class: the only dispatchable field on a
// core refusal. Dialects may not mint new class values — new behavior is a
// new class in the core, not a new dialect code.
type Class string

// The six neutral classes. Wire strings are stable once published: dialects,
// harnesses and courts grep them, so they never re-shape.
const (
	ClassAdmissionRefused Class = "ADMISSION_REFUSED"
	ClassVersionCeiling   Class = "VERSION_CEILING"
	ClassShapeViolation   Class = "SHAPE_VIOLATION"
	ClassUnsupportedFace  Class = "UNSUPPORTED_FACE"
	ClassEnrichmentGap    Class = "ENRICHMENT_GAP"
	ClassDialectDrift     Class = "DIALECT_DRIFT"
)

// classes is the closed set in canonical order.
var classes = []Class{
	ClassAdmissionRefused,
	ClassVersionCeiling,
	ClassShapeViolation,
	ClassUnsupportedFace,
	ClassEnrichmentGap,
	ClassDialectDrift,
}

// AllClasses returns the closed class set in canonical order.
func AllClasses() []Class {
	out := make([]Class, len(classes))
	copy(out, classes)
	return out
}

// IsValid reports whether c is one of the six neutral classes. Anything else
// is a mint-attempt from a dialect and refuses.
func (c Class) IsValid() bool {
	for _, k := range classes {
		if c == k {
			return true
		}
	}
	return false
}

// String returns the stable wire string of the class.
func (c Class) String() string { return string(c) }

// Refuses reports whether the class is a refusal-tier class (wire refusal:
// 400/501-tier, never renders as 2xx). ENRICHMENT_GAP is admissible-and-served
// but fail-closed on a required absent input; DIALECT_DRIFT is the coverage
// compiler's cell class (its "wire" is the coverage report), so it is
// gate-tier here and never wire-refuses.
func (c Class) Refuses() bool {
	switch c {
	case ClassAdmissionRefused, ClassVersionCeiling, ClassShapeViolation, ClassUnsupportedFace:
		return true
	case ClassEnrichmentGap, ClassDialectDrift:
		return false
	default:
		// An unknown class is not wire-lawful: refuse loudly rather than
		// defaulting to a permissive classification.
		return false
	}
}

// WireCode maps the class onto the EXISTING api error currency. No new wire
// codes are minted: refusal-tier classes carry CodeRefusedEgress (a policy
// denial, terminal — matching api.NewRefusedEgress semantics); ENRICHMENT_GAP
// carries CodeUpstream (a downstream/input absence, not a policy denial);
// DIALECT_DRIFT has no wire code (it lives in the coverage report).
func (c Class) WireCode() api.ErrorCode {
	switch c {
	case ClassAdmissionRefused, ClassVersionCeiling, ClassShapeViolation, ClassUnsupportedFace:
		return api.CodeRefusedEgress
	case ClassEnrichmentGap:
		return api.CodeUpstream
	default:
		return ""
	}
}

// ParseClass parses a wire string into a Class, refusing any value outside
// the closed set (a dialect mint-attempt, a mutated byte, a future class the
// consumer predates). Byte-exact: whitespace, case or punctuation mutations
// refuse.
func ParseClass(s string) (Class, error) {
	c := Class(s)
	if !c.IsValid() {
		return "", fmt.Errorf("diag: unknown diagnostic class %q (must be exactly one of %s)", s, joinClasses())
	}
	return c, nil
}

func joinClasses() string {
	parts := make([]string, len(classes))
	for i, c := range classes {
		parts[i] = string(c)
	}
	sort.Strings(parts)
	return strings.Join(parts, "|")
}

// Envelope is the neutral wire envelope: a superset of the ARM error envelope
// (smalt lib/smalt/arm_gateway/plug/common.ex send_arm_error/5). `code` keeps
// the dialect's existing literal (AdmissionRefused, InvalidApiVersionParameter,
// ...) — that is the compatibility face courts grep. `class` is the neutral
// dispatchable field. `receipt` is null (absent) on unstamped paths, loud —
// never a fake hex. `skip` is non-null only on gate-tier diagnostics; a
// would-be wire skip is ClassUnsupportedFace, never a 2xx.
type Envelope struct {
	Class   Class  `json:"class"`
	Code    string `json:"code"`
	Message string `json:"message"`
	Target  string `json:"target,omitempty"`
	Dialect string `json:"dialect"`
	// Receipt is the turnstile receipt hex, empty = unstamped (loud absence).
	Receipt string   `json:"receipt,omitempty"`
	Skip    *SkipRef `json:"skip,omitempty"`
	// Inner and Details ride the ARM envelope's innererror/details slots.
	Inner   map[string]any `json:"innererror,omitempty"`
	Details []Detail       `json:"details,omitempty"`
}

// SkipRef carries a gate-tier loud-skip reason. Never wire-refuses.
type SkipRef struct {
	Reason string `json:"reason"`
}

// Detail is one entry in the envelope's details[] (e.g. shape violations
// promoted out of prose).
type Detail struct {
	Key   string `json:"key,omitempty"`
	Value string `json:"value"`
}

// dialects is the closed dialect set from the gap doc: core, azure-arm
// (dialect #1), identity (dialect #0 per gap-01), smalt-cli, harness-ts.
var dialects = map[string]bool{
	"core":       true,
	"azure-arm":  true,
	"identity":   true,
	"smalt-cli":  true,
	"harness-ts": true,
}

// DialectIsKnown reports whether d is in the closed dialect set.
func DialectIsKnown(d string) bool { return dialects[d] }

// NewRefused is the typed constructor for refusal-tier classes. It reuses
// api.NewRefusedEgress semantics exactly (sentinel ErrRefusedEgress, terminal,
// not retryable) — no new wire codes. op carries the neutral class so the
// class survives in-process classification (api.Mapping); code/message keep
// the dialect's existing literals.
//
//	err := diag.NewRefused(diag.ClassUnsupportedFace,
//	    "UNSUPPORTED(tls-variant-absent)")
//	errors.Is(err, api.ErrRefusedEgress) // true
func NewRefused(class Class, message string) *api.MembraneError {
	if !class.IsValid() {
		// A dialect minting an unknown class refuses at construction.
		return api.NewRefusedEgress("diag:"+string(class), nil,
			"unknown diagnostic class %q (must be one of %s)", class, joinClasses())
	}
	return api.NewRefusedEgress(string(class), nil, "%s", message)
}

// NewGap builds the ENRICHMENT_GAP error (CodeUpstream: the request was
// admissible and served, but a required enrichment is absent — fail-closed,
// kin of the harness MissingSecretError). Unknown classes refuse.
func NewGap(message string) *api.MembraneError {
	return api.NewUpstream(string(ClassEnrichmentGap), nil, "%s", message)
}

// ClassOf recovers the neutral class from a MembraneError built by
// NewRefused/NewGap (op = class). Returns ok=false for foreign errors.
func ClassOf(err error) (Class, bool) {
	var me *api.MembraneError
	if !errors.As(err, &me) {
		return "", false
	}
	c := Class(me.Op)
	return c, c.IsValid()
}

// EnvelopeOf projects a MembraneError built by NewRefused/NewError into the
// neutral wire envelope. op = class, Message = message; dialect/code are not
// carried by MembraneError, so they are supplied by the caller at the wire
// mount (the BEAM side owns the outer ARM envelope post-strip).
func EnvelopeOf(class Class, dialect, code, message string, receipt string) Envelope {
	return Envelope{
		Class:   class,
		Code:    code,
		Message: message,
		Dialect: dialect,
		Receipt: receipt,
	}
}
