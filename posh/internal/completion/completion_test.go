package completion

import (
	"bytes"
	"strings"
	"testing"
)

func TestSupportedShells(t *testing.T) {
	shells := SupportedShells()
	if len(shells) != 3 {
		t.Fatalf("expected 3 shells, got %d", len(shells))
	}
}

func TestGenerateBash(t *testing.T) {
	var buf bytes.Buffer
	if err := Generate("bash", &buf); err != nil {
		t.Fatalf("Generate(bash): %v", err)
	}
	s := buf.String()
	if !strings.Contains(s, "_posh_completions()") {
		t.Errorf("bash completion missing function declaration")
	}
	if !strings.Contains(s, "complete -F _posh_completions posh") {
		t.Errorf("bash completion missing complete directive")
	}
}

func TestGenerateZsh(t *testing.T) {
	var buf bytes.Buffer
	if err := Generate("zsh", &buf); err != nil {
		t.Fatalf("Generate(zsh): %v", err)
	}
	s := buf.String()
	if !strings.Contains(s, "#compdef posh") {
		t.Errorf("zsh completion missing #compdef tag")
	}
	if !strings.Contains(s, "_describe -t commands") {
		t.Errorf("zsh completion missing commands describe")
	}
}

func TestGenerateFish(t *testing.T) {
	var buf bytes.Buffer
	if err := Generate("fish", &buf); err != nil {
		t.Fatalf("Generate(fish): %v", err)
	}
	s := buf.String()
	if !strings.Contains(s, "complete -c posh") {
		t.Errorf("fish completion missing complete directives")
	}
}

func TestUnsupportedShell(t *testing.T) {
	var buf bytes.Buffer
	if err := Generate("powershell", &buf); err == nil {
		t.Fatalf("expected error on unsupported shell, got nil")
	}
}
