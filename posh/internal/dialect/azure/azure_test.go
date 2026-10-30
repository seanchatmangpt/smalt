package azure

import (
	"errors"
	"testing"

	"smalt.dev/posh/internal/api"
	"smalt.dev/posh/internal/dialect"
)

// TestLookupOpRefusesUnknownOp proves the allowlist is closed: an op
// absent from the registry is a typed egress refusal, never a miss that
// reads as admission.
func TestLookupOpRefusesUnknownOp(t *testing.T) {
	if _, ok := Default.LookupOp("no-such-op"); ok {
		t.Fatal("unknown op admitted: registry allowlist is open")
	}

	// The call-site refusal contract lanes 11/12 will wire:
	spec, ok := Default.LookupOp("echo")
	if !ok {
		t.Fatal("echo op missing from default registry")
	}
	err := api.NewRefusedEgress("no-such-op", nil, "op %q not admitted by the graph", "no-such-op")
	if !errors.Is(err, api.ErrRefusedEgress) {
		t.Fatalf("refusal not typed as ErrRefusedEgress: %v", err)
	}
	if api.Mapping(err) != api.CodeRefusedEgress {
		t.Fatalf("refusal maps to %q, want CodeRefusedEgress", api.Mapping(err))
	}
	_ = spec // echo spec is the admitted shape lanes 11/12 bind against
}

// TestEchoOpSpecIsFailClosed pins the POS-008 receipt rule on the seeded
// op: non-empty turnstile receipt, declared shape, at least one sink.
func TestEchoOpSpecIsFailClosed(t *testing.T) {
	spec, ok := Default.LookupOp("echo")
	if !ok {
		t.Fatal("echo op missing from default registry")
	}
	if spec.TurnstileReceipt == "" {
		t.Fatal("echo op has empty turnstile receipt (POS-008 violation)")
	}
	if len(spec.AllowHosts) == 0 {
		t.Fatal("echo op declares no sink host")
	}
	if spec.Shape == "" {
		t.Fatal("echo op declares no payload shape")
	}
}

// TestShapeViolation pins the shape fence: a payload shape mismatch is a
// typed refusal, the declared shape or a waived (empty) spec shape passes.
func TestShapeViolation(t *testing.T) {
	spec, _ := Default.LookupOp("echo")
	if err := dialect.ShapeViolation(spec, "echo.v1"); err != nil {
		t.Fatalf("declared shape refused: %v", err)
	}
	err := dialect.ShapeViolation(spec, "other.v9")
	if !errors.Is(err, api.ErrRefusedEgress) {
		t.Fatalf("shape violation not typed as ErrRefusedEgress: %v", err)
	}
	waived := dialect.OpSpec{Op: "open"}
	if err := dialect.ShapeViolation(waived, "anything"); err != nil {
		t.Fatalf("empty spec shape should waive the check: %v", err)
	}
}

// TestParseRefMatchesRouterSemantics restates the ingress.ParseARMResourceID
// cases dialect.ParseRef must honor without importing ingress.
func TestParseRefMatchesRouterSemantics(t *testing.T) {
	ref, err := dialect.ParseRef("/subscriptions/s1/resourceGroups/rg1/providers/Microsoft.KeyVault/vaults/v1")
	if err != nil {
		t.Fatalf("plain resource path refused: %v", err)
	}
	if ref.SubscriptionID != "s1" || ref.ResourceGroupName != "rg1" ||
		ref.ProviderNamespace != "Microsoft.KeyVault" || ref.ResourceType != "vaults" ||
		ref.ResourceName != "v1" || ref.IsOperation {
		t.Fatalf("plain resource parse drift: %+v", ref)
	}

	ref, err = dialect.ParseRef("/subscriptions/s1/resourceGroups/rg1/providers/Microsoft.KeyVault/vaults/v1/secrets/s2")
	if err != nil {
		t.Fatalf("sub-resource path refused: %v", err)
	}
	if ref.SubResourceType != "secrets" || ref.SubResourceName != "s2" {
		t.Fatalf("sub-resource parse drift: %+v", ref)
	}

	ref, err = dialect.ParseRef("/subscriptions/s1/resourceGroups/rg1/providers/Microsoft.KeyVault/vaults/v1/purge")
	if err != nil {
		t.Fatalf("action path refused: %v", err)
	}
	if !ref.IsOperation || ref.Action != "purge" {
		t.Fatalf("action parse drift: %+v", ref)
	}

	if _, err = dialect.ParseRef(""); err == nil {
		t.Fatal("empty path admitted")
	}
}
