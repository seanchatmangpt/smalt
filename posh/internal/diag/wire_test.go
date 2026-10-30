package diag

import (
	"encoding/json"
	"errors"
	"strings"
	"testing"

	"smalt.dev/posh/internal/api"
)

// Falsifier (GAP-04): every neutral class serializes to a DISTINCT, stable
// wire string, and a mutated/unknown class refuses.
func TestClassesDistinctStableWireStrings(t *testing.T) {
	want := map[Class]string{
		ClassAdmissionRefused: "ADMISSION_REFUSED",
		ClassVersionCeiling:   "VERSION_CEILING",
		ClassShapeViolation:   "SHAPE_VIOLATION",
		ClassUnsupportedFace:  "UNSUPPORTED_FACE",
		ClassEnrichmentGap:    "ENRICHMENT_GAP",
		ClassDialectDrift:     "DIALECT_DRIFT",
	}
	seen := map[string]bool{}
	for _, c := range AllClasses() {
		got := c.String()
		if got != want[c] {
			t.Errorf("class %v wire string drifted: got %q want %q", c, got, want[c])
		}
		if seen[got] {
			t.Errorf("wire string %q is not distinct", got)
		}
		seen[got] = true
		// JSON round-trip must preserve the exact string.
		b, err := json.Marshal(Envelope{Class: c, Dialect: "core"})
		if err != nil {
			t.Fatalf("marshal %v: %v", c, err)
		}
		var env Envelope
		if err := json.Unmarshal(b, &env); err != nil {
			t.Fatalf("unmarshal %v: %v", c, err)
		}
		if env.Class != c {
			t.Errorf("round-trip broke class %v -> %v", c, env.Class)
		}
	}
	if len(seen) != 6 {
		t.Errorf("expected 6 classes, got %d", len(seen))
	}
}

func TestUnknownClassRefuses(t *testing.T) {
	// ParseClass refuses a mutated/unknown string.
	for _, bad := range []string{"ADMISSION_REFUSED ", "admission", "UNSUPPORTED_FACE\n", "TLS_VARIANT", ""} {
		if _, err := ParseClass(bad); err == nil {
			t.Errorf("ParseClass(%q) accepted an unknown class", bad)
		}
	}
	// Lowercase mutation refuses too — byte-exact wire strings.
	if _, err := ParseClass("admission_refused"); err == nil {
		t.Error(`ParseClass("admission_refused") accepted a case mutation`)
	}
	// IsValid rejects the mutated class.
	if (Class("SHAPE_VIOLATIONS")).IsValid() {
		t.Error("mutated class SHAPE_VIOLATIONS passed IsValid")
	}
	// A constructor minting an unknown class returns a refusal error.
	err := NewRefused(Class("NEW_DIALECT_CLASS"), "mint attempt")
	if !errors.Is(err, api.ErrRefusedEgress) {
		t.Errorf("unknown-class mint did not refuse via ErrRefusedEgress: %v", err)
	}
	// The mint refusal itself carries no lawful class.
	if c, ok := ClassOf(err); ok {
		t.Errorf("ClassOf(mint refusal) = %q, want not-ok", c)
	}
}

func TestNewRefusedMapsIntoExistingApiCurrency(t *testing.T) {
	// UNSUPPORTED(tls-variant-absent) — the promoted doc register.
	err := NewRefused(ClassUnsupportedFace, "UNSUPPORTED(tls-variant-absent)")
	if !errors.Is(err, api.ErrRefusedEgress) {
		t.Errorf("UNSUPPORTED_FACE must unwrap to ErrRefusedEgress, got %v", err)
	}
	if got := api.Mapping(err); got != api.CodeRefusedEgress {
		t.Errorf("Mapping = %q, want REFUSED_EGRESS (no new wire codes)", got)
	}
	if c, ok := ClassOf(err); !ok || c != ClassUnsupportedFace {
		t.Errorf("ClassOf = %q,%v", c, ok)
	}

	// Version ceiling: same refusal currency, distinct class recovered.
	verr := NewRefused(ClassVersionCeiling, "InvalidApiVersionParameter: latest supported version is 2099-01-01")
	if api.Mapping(verr) != api.CodeRefusedEgress {
		t.Errorf("VERSION_CEILING mapping = %q", api.Mapping(verr))
	}
	if c, _ := ClassOf(verr); c != ClassVersionCeiling {
		t.Errorf("class recovered = %q", c)
	}

	// ENRICHMENT_GAP rides CodeUpstream (input absence, not policy denial).
	gerr := NewGap("missing secret: kv/alpha")
	if api.Mapping(gerr) != api.CodeUpstream {
		t.Errorf("ENRICHMENT_GAP mapping = %q, want UPSTREAM", api.Mapping(gerr))
	}
	if !errors.Is(gerr, api.ErrUpstream) {
		t.Errorf("ENRICHMENT_GAP must unwrap to ErrUpstream")
	}

	// DIALECT_DRIFT is gate-tier: no wire code, never wire-refuses.
	if ClassDialectDrift.Refuses() {
		t.Error("DIALECT_DRIFT must not wire-refuse")
	}
	if ClassDialectDrift.WireCode() != "" {
		t.Error("DIALECT_DRIFT must have no wire code")
	}
}

func TestEnvelopeCompatFace(t *testing.T) {
	// The dialect `code` keeps its literal (fence court greps
	// AdmissionRefused; SmaltVersionError.fromResponse parses the 400).
	env := EnvelopeOf(ClassAdmissionRefused, "azure-arm", "AdmissionRefused",
		"payload violates the arm.request shape: target/... — re-render with: just posh-generate",
		"a1b2c3")
	b, err := json.Marshal(env)
	if err != nil {
		t.Fatal(err)
	}
	var raw map[string]any
	if err := json.Unmarshal(b, &raw); err != nil {
		t.Fatal(err)
	}
	if raw["code"] != "AdmissionRefused" {
		t.Errorf("compat literal lost: %v", raw["code"])
	}
	if raw["class"] != "ADMISSION_REFUSED" {
		t.Errorf("class missing: %v", raw["class"])
	}
	if raw["dialect"] != "azure-arm" {
		t.Errorf("dialect missing: %v", raw["dialect"])
	}
	if raw["receipt"] != "a1b2c3" {
		t.Errorf("receipt missing: %v", raw["receipt"])
	}

	// Unstamped path: receipt is loud absence (omitempty), never a fake hex.
	env2 := EnvelopeOf(ClassUnsupportedFace, "azure-arm", "UNSUPPORTED(tls-variant-absent)", "no implementation for this face variant", "")
	b2, _ := json.Marshal(env2)
	if strings.Contains(string(b2), `"receipt":`) {
		t.Errorf("unstamped envelope rendered a receipt: %s", b2)
	}
}

func TestUnknownDialectRefuses(t *testing.T) {
	if DialectIsKnown("gcp-arm") {
		t.Error("unknown dialect accepted")
	}
	for _, d := range []string{"core", "azure-arm", "identity", "smalt-cli", "harness-ts"} {
		if !DialectIsKnown(d) {
			t.Errorf("lawful dialect %s refused", d)
		}
	}
}
