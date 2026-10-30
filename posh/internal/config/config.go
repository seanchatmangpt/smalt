// Package config loads the posh.yaml egress allowlist (POSH-008).
//
// Fail-closed law: a missing or empty posh.yaml is a boot refusal, never an
// open floodgate. The allowlist is the only admitted egress surface; hosts
// outside it get a typed REFUSED_EGRESS refusal.
//
// Validation errors name the file, field, and expected type so a bad config
// is diagnosable from the boot refusal alone.
package config

import (
	"fmt"
	"net"
	"os"
	"strings"

	"gopkg.in/yaml.v3"
)

// DefaultSocket is used when posh.yaml omits the socket field.
const DefaultSocket = "run/posh.sock"

// Config is the parsed posh.yaml.
type Config struct {
	// Socket is the unix socket path the membrane listener binds.
	// Default: run/posh.sock (see DefaultSocket). Relative paths resolve
	// against the process working directory.
	Socket string `yaml:"socket"`
	// TCPAddr is an optional TCP listen address "host:port"
	// (e.g. "127.0.0.1:7443"). Empty/omitted means TCP listener disabled.
	TCPAddr string `yaml:"tcp_addr"`
	// EgressAllowlist is the set of admitted egress hostnames. Default-deny:
	// an empty/omitted list refuses all egress (the process still boots and
	// serves local membrane traffic).
	EgressAllowlist []string `yaml:"egress_allowlist"`
}

// FieldError is a validation failure naming the file, field, and expected
// type. Text is human-readable; the fields are machine-readable.
type FieldError struct {
	File     string // config file the error came from
	Field    string // yaml key, e.g. "tcp_addr"
	Expected string // expected type/shape, e.g. "host:port address"
	Problem  string // what was wrong with the actual value
}

// Error renders the FieldError as a single human-readable line.
func (e *FieldError) Error() string {
	return fmt.Sprintf("%s: field %q: %s: %s", e.File, e.Field, e.Expected, e.Problem)
}

func fieldErr(file, field, expected, problem string) error {
	return &FieldError{File: file, Field: field, Expected: expected, Problem: problem}
}

// Load reads, parses, and validates posh.yaml. Fail-closed: a missing file is
// an error. Every validation error names the file, field, and expected type.
func Load(path string) (*Config, error) {
	data, err := os.ReadFile(path)
	if err != nil {
		return nil, fmt.Errorf("%s: file missing or unreadable (fail-closed, POSH-008): %w", path, err)
	}
	var cfg Config
	if err := yaml.Unmarshal(data, &cfg); err != nil {
		return nil, fmt.Errorf("%s: invalid YAML: %w", path, err)
	}
	if err := cfg.validate(path); err != nil {
		return nil, err
	}
	if cfg.Socket == "" {
		cfg.Socket = DefaultSocket
	}
	return &cfg, nil
}

// validate enforces per-field shape, producing FieldErrors keyed by file.
func (c *Config) validate(file string) error {
	for _, h := range c.EgressAllowlist {
		h = strings.TrimSpace(h)
		if h == "" {
			return fieldErr(file, "egress_allowlist", "list of hostnames",
				"empty entry (expected a hostname like \"smalt.internal\")")
		}
		if strings.ContainsAny(h, "/: @") {
			return fieldErr(file, "egress_allowlist", "bare hostname",
				fmt.Sprintf("%q contains a scheme, port, path, or space; use a bare hostname like %q", h, "smalt.internal"))
		}
	}
	if c.TCPAddr != "" {
		if _, _, err := net.SplitHostPort(c.TCPAddr); err != nil {
			return fieldErr(file, "tcp_addr", "host:port address",
				fmt.Sprintf("%q does not parse as host:port (e.g. \"127.0.0.1:7443\")", c.TCPAddr))
		}
		if host, _, _ := net.SplitHostPort(c.TCPAddr); host == "" {
			return fieldErr(file, "tcp_addr", "host:port address",
				"empty host; bind an explicit interface (e.g. \"127.0.0.1:7443\"), never wildcard-listen by accident")
		}
	}
	return nil
}

// Admits reports whether host is on the egress allowlist.
func (c *Config) Admits(host string) bool {
	for _, h := range c.EgressAllowlist {
		if h == host {
			return true
		}
	}
	return false
}
