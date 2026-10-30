package poshvet

import (
	"os"
	"path/filepath"
	"testing"
)

func TestParseOntologyTurnstiles(t *testing.T) {
	// Write a mock turtle file
	tmpDir := t.TempDir()
	ttlFile := filepath.Join(tmpDir, "routes.ttl")
	content := `@prefix posh: <https://smalt.dev/posh/ns#> .

posh:routeResourceGroup a posh:IngressRoute ;
  posh:admittedBy posh:turnstileResourceGroup ;
  posh:membraneOp "arm.resource_group" ;
  posh:sink posh:sinkStarboard9443 .

posh:turnstileResourceGroup a posh:Turnstile ;
  posh:emits posh:receiptResourceGroup .

posh:routeOrphan a posh:IngressRoute ;
  posh:membraneOp "orphan.op" .
`
	if err := os.WriteFile(ttlFile, []byte(content), 0644); err != nil {
		t.Fatalf("failed to write mock ttl: %v", err)
	}

	ops, err := ParseOntologyTurnstiles(ttlFile)
	if err != nil {
		t.Fatalf("ParseOntologyTurnstiles failed: %v", err)
	}

	rg, ok := ops["arm.resource_group"]
	if !ok {
		t.Fatalf("expected arm.resource_group in ops")
	}
	if rg.TurnstileURI != "posh:turnstileResourceGroup" {
		t.Errorf("turnstile = %q, want posh:turnstileResourceGroup", rg.TurnstileURI)
	}
	if !rg.HasReceipt {
		t.Errorf("expected HasReceipt = true")
	}

	orphan, ok := ops["orphan.op"]
	if !ok {
		t.Fatalf("expected orphan.op in ops")
	}
	if orphan.TurnstileURI != "" {
		t.Errorf("orphan should have empty TurnstileURI, got %q", orphan.TurnstileURI)
	}
}

func TestAnalyzersBuildAndRegister(t *testing.T) {
	if ConvTSliceAnalyzer.Name != "convtslice" {
		t.Errorf("ConvTSliceAnalyzer name = %q, want convtslice", ConvTSliceAnalyzer.Name)
	}
	if FencedNetAnalyzer.Name != "fencednet" {
		t.Errorf("FencedNetAnalyzer name = %q, want fencednet", FencedNetAnalyzer.Name)
	}
	if OpTurnstileAnalyzer.Name != "opturnstile" {
		t.Errorf("OpTurnstileAnalyzer name = %q, want opturnstile", OpTurnstileAnalyzer.Name)
	}
}
