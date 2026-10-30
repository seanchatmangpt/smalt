package config

import (
	"errors"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// writeConfig writes yaml to a per-test temp file (parallel-safe).
func writeConfig(t *testing.T, yaml string) string {
	t.Helper()
	path := filepath.Join(t.TempDir(), "posh.yaml")
	if err := os.WriteFile(path, []byte(yaml), 0o644); err != nil {
		t.Fatalf("write config: %v", err)
	}
	return path
}

func TestLoadMissingFileFailsClosed(t *testing.T) {
	t.Parallel()
	// POSH-008 falsifier: missing posh.yaml must refuse to boot.
	_, err := Load(filepath.Join(t.TempDir(), "nope.yaml"))
	if err == nil {
		t.Fatal("Load on missing file must fail-closed, got nil error")
	}
}

func TestLoadParsesAllowlistAndAdmits(t *testing.T) {
	t.Parallel()
	path := writeConfig(t, `
socket: run/posh.sock
tcp_addr: 127.0.0.1:7443
egress_allowlist:
  - smalt.internal
  - kind.local
`)
	cfg, err := Load(path)
	if err != nil {
		t.Fatalf("Load: %v", err)
	}
	if cfg.Socket != "run/posh.sock" {
		t.Errorf("socket = %q", cfg.Socket)
	}
	if cfg.TCPAddr != "127.0.0.1:7443" {
		t.Errorf("tcp_addr = %q", cfg.TCPAddr)
	}
	if !cfg.Admits("kind.local") {
		t.Error("allowlist must admit kind.local")
	}
	if cfg.Admits("evil.example.com") {
		t.Error("default-deny violated: un-admitted host admitted")
	}
}

func TestLoadMalformedYAMLErrors(t *testing.T) {
	t.Parallel()
	if _, err := Load(writeConfig(t, "socket: [unclosed")); err == nil {
		t.Fatal("malformed YAML must error, not boot with partial config")
	}
}

func TestAdmitsEdgeCases(t *testing.T) {
	t.Parallel()
	path := writeConfig(t, "socket: run/posh.sock\negress_allowlist:\n  - kind.local\n")
	cfg, err := Load(path)
	if err != nil {
		t.Fatalf("Load: %v", err)
	}

	cases := []struct {
		host string
		want bool
	}{
		{host: "kind.local", want: true},
		{host: "", want: false},               // empty host never admitted
		{host: "sub.kind.local", want: false}, // suffix match is not admission
		{host: "kind.local.evil.com", want: false},
	}
	for _, tc := range cases {
		if got := cfg.Admits(tc.host); got != tc.want {
			t.Errorf("Admits(%q) = %v, want %v", tc.host, got, tc.want)
		}
	}
}

func TestValidationErrorNamesFileFieldAndExpectedType(t *testing.T) {
	cases := []struct {
		name   string
		yaml   string
		field  string
		expect string
	}{
		{"bad tcp addr", "tcp_addr: 7443\n", "tcp_addr", "host:port address"},
		{"empty tcp host", `tcp_addr: ":7443"` + "\n", "tcp_addr", "explicit interface"},
		{"empty allowlist entry", "egress_allowlist:\n  - \"\"\n", "egress_allowlist", "list of hostnames"},
		{"schemed allowlist entry", "egress_allowlist:\n  - http://x.example\n", "egress_allowlist", "bare hostname"},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			path := filepath.Join(t.TempDir(), "posh.yaml")
			if err := os.WriteFile(path, []byte(tc.yaml), 0o644); err != nil {
				t.Fatal(err)
			}
			_, err := Load(path)
			if err == nil {
				t.Fatal("expected validation refusal, got nil error")
			}
			var fe *FieldError
			if !errors.As(err, &fe) {
				t.Fatalf("error %v is not a *FieldError", err)
			}
			if fe.File != path || fe.Field != tc.field || !strings.Contains(fe.Error(), tc.expect) {
				t.Errorf("error %q: want file=%s field=%s containing %q", err, path, tc.field, tc.expect)
			}
		})
	}
}

func TestValidConfigStillBoots(t *testing.T) {
	path := filepath.Join(t.TempDir(), "posh.yaml")
	yaml := "socket: run/posh.sock\ntcp_addr: 127.0.0.1:7443\negress_allowlist:\n  - kind.local\n"
	if err := os.WriteFile(path, []byte(yaml), 0o644); err != nil {
		t.Fatal(err)
	}
	if _, err := Load(path); err != nil {
		t.Fatalf("valid config refused: %v", err)
	}
}
