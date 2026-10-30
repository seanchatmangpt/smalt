package diag

import (
	"strings"
	"testing"
)

func TestDiagnosticRenderNoColor(t *testing.T) {
	d := RefusedEgress("evil.example.com", "posh.yaml", 10)
	d.WithCustomSnippet("socket: run/posh.sock\negress_allowlist:\n  - smalt.internal\n")

	out := d.Render(ColorConfig{NoColor: true})

	if !strings.Contains(out, "error[E0101]") {
		t.Errorf("expected code E0101, got: %s", out)
	}
	if !strings.Contains(out, "--> posh.yaml:10:1") {
		t.Errorf("expected location pointer, got: %s", out)
	}
	if !strings.Contains(out, "invariant: Charter Law 2") {
		t.Errorf("expected invariant line, got: %s", out)
	}
	if !strings.Contains(out, "5-whys: Membrane received request") {
		t.Errorf("expected 5-whys line, got: %s", out)
	}
	if !strings.Contains(out, "remediation: printf '  - evil.example.com") {
		t.Errorf("expected remediation line, got: %s", out)
	}
}

func TestDiagnosticColorCodes(t *testing.T) {
	d := SocketCollision("run/posh.sock", 1234)
	out := d.Render(ColorConfig{ForceColor: true})

	if !strings.Contains(out, ansiRed) {
		t.Errorf("expected ANSI red styling in color mode, got: %s", out)
	}
	if !strings.Contains(out, "E0102") {
		t.Errorf("expected code E0102, got: %s", out)
	}
}

func TestDiagnosticErrorInterface(t *testing.T) {
	d := FrameOverflow(5000000, 4194304)
	if !strings.Contains(d.Error(), "error[E0103]") {
		t.Errorf("unexpected Error() output: %s", d.Error())
	}
}
