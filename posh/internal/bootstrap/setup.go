package bootstrap

import (
	"context"
	"fmt"
	"io"
	"os"
	"path/filepath"

	"smalt.dev/posh/internal/doctor"
)

// SetupOptions controls the environment bootstrapping process.
type SetupOptions struct {
	RepoRoot   string
	ConfigPath string
	Force      bool
	DryRun     bool
	Out        io.Writer
}

// Result summarizes the actions taken by Setup.
type Result struct {
	DirsCreated   []string
	ConfigCreated bool
	DoctorReport  doctor.Report
}

const defaultPoshYAML = `# posh.yaml — POSH Sovereign Membrane Runtime Configuration (SPAF Tier 2)
# Protocol translation only — zero domain state (Charter Law 2).

socket: run/posh.sock
tcp_addr: ""            # optional, e.g. 127.0.0.1:7443

egress_allowlist:       # default-deny security boundary (POSH-008)
  - smalt.internal
`

// Run executes the self-healing bootstrap sequence.
func Run(ctx context.Context, opts SetupOptions) (*Result, error) {
	if opts.RepoRoot == "" {
		opts.RepoRoot = "."
	}
	if opts.ConfigPath == "" {
		opts.ConfigPath = filepath.Join(opts.RepoRoot, "posh.yaml")
		if _, err := os.Stat(opts.ConfigPath); os.IsNotExist(err) {
			nested := filepath.Join(opts.RepoRoot, "posh", "posh.yaml")
			if _, err2 := os.Stat(nested); err2 == nil {
				opts.ConfigPath = nested
			}
		}
	}
	if opts.Out == nil {
		opts.Out = os.Stdout
	}

	res := &Result{}

	fmt.Fprintf(opts.Out, "==> Initializing POSH sovereign developer runtime...\n")

	// 1. Ensure required runtime directories
	reqDirs := []string{
		filepath.Join(opts.RepoRoot, "run"),
		filepath.Join(opts.RepoRoot, "var"),
		filepath.Join(opts.RepoRoot, "bin"),
	}
	// Also check if running from repo root with a posh/ subfolder
	if fi, err := os.Stat(filepath.Join(opts.RepoRoot, "posh")); err == nil && fi.IsDir() {
		reqDirs = append(reqDirs,
			filepath.Join(opts.RepoRoot, "posh", "run"),
			filepath.Join(opts.RepoRoot, "posh", "var"),
			filepath.Join(opts.RepoRoot, "posh", "bin"),
		)
	}

	for _, d := range reqDirs {
		if _, err := os.Stat(d); os.IsNotExist(err) {
			if !opts.DryRun {
				if err := os.MkdirAll(d, 0o755); err != nil {
					return nil, fmt.Errorf("create dir %s: %w", d, err)
				}
			}
			res.DirsCreated = append(res.DirsCreated, d)
			fmt.Fprintf(opts.Out, "  [CREATED] Directory: %s\n", d)
		}
	}

	// 2. Ensure posh.yaml configuration exists
	if _, err := os.Stat(opts.ConfigPath); os.IsNotExist(err) || opts.Force {
		if !opts.DryRun {
			_ = os.MkdirAll(filepath.Dir(opts.ConfigPath), 0o755)
			if err := os.WriteFile(opts.ConfigPath, []byte(defaultPoshYAML), 0o644); err != nil {
				return nil, fmt.Errorf("write config %s: %w", opts.ConfigPath, err)
			}
		}
		res.ConfigCreated = true
		fmt.Fprintf(opts.Out, "  [CREATED] Configuration: %s\n", opts.ConfigPath)
	} else {
		fmt.Fprintf(opts.Out, "  [OK] Configuration present: %s\n", opts.ConfigPath)
	}

	// 3. Run Doctor with Auto-Fix (Jidoka healing for sockets, terraformrc)
	fmt.Fprintf(opts.Out, "==> Running Doctor with Jidoka automated healing...\n")
	docRep := doctor.Run(ctx, doctor.Options{
		ConfigPath: opts.ConfigPath,
		RepoRoot:   opts.RepoRoot,
		Fix:        !opts.DryRun,
	})
	res.DoctorReport = docRep

	for _, p := range docRep.Probes {
		if p.Fixed {
			fmt.Fprintf(opts.Out, "  [HEALED] %-18s -> %s\n", p.ID, p.FixAction)
		} else {
			fmt.Fprintf(opts.Out, "  [%-6s] %-18s -> %s\n", p.Status, p.ID, p.Summary)
		}
	}

	// 4. Shell completion guidance
	fmt.Fprintf(opts.Out, "\n==> Shell Completion Setup:\n")
	fmt.Fprintf(opts.Out, "  Zsh:   posh completion zsh > \"${fpath[1]}/_posh\"\n")
	fmt.Fprintf(opts.Out, "  Bash:  posh completion bash > /etc/bash_completion.d/posh\n")
	fmt.Fprintf(opts.Out, "  Fish:  posh completion fish > ~/.config/fish/completions/posh.fish\n\n")

	fmt.Fprintf(opts.Out, "Environment bootstrap complete. Overall Andon: [%s]\n", docRep.OverallStatus)
	return res, nil
}
