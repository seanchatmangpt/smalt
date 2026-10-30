package doctor

import (
	"context"
	"fmt"
	"net"
	"net/http"
	"os/exec"
	"path/filepath"
	"strings"
	"time"

	"smalt.dev/posh/internal/diag"
)

// DefaultNodePort is the canonical Kubernetes NodePort bridging SPAF ARM backend in Kind.
const DefaultNodePort = 30943

// DefaultHostPort is the host loopback port mapped to DefaultNodePort.
const DefaultHostPort = 9443

// KubeHealerOptions configures the cluster NodePort reachability and port-forwarding self-healing engine.
type KubeHealerOptions struct {
	NodePort       int
	HostPort       int
	ARMURL         string
	RepoRoot       string
	Fix            bool
	DryRunFix      bool
	Timeout        time.Duration
	Dialer         func(network, address string, timeout time.Duration) (net.Conn, error)
	HTTPGetter     func(ctx context.Context, url string) (*http.Response, error)
	CommandRunner  func(ctx context.Context, name string, args ...string) ([]byte, error)
	CommandSpawner func(name string, args ...string) (*exec.Cmd, error)
	ProcessChecker func(name string) bool
}

// DefaultKubeHealerOptions creates standard production options for Kubernetes healing.
func DefaultKubeHealerOptions(opts Options) KubeHealerOptions {
	nodePort := DefaultNodePort
	hostPort := DefaultHostPort
	armURL := opts.ARMURL
	if armURL == "" {
		armURL = DefaultARMURL
	}
	timeout := 300 * time.Millisecond

	return KubeHealerOptions{
		NodePort:  nodePort,
		HostPort:  hostPort,
		ARMURL:    armURL,
		RepoRoot:  opts.RepoRoot,
		Fix:       opts.Fix,
		DryRunFix: opts.DryRunFix,
		Timeout:   timeout,
		Dialer: func(network, address string, t time.Duration) (net.Conn, error) {
			return net.DialTimeout(network, address, t)
		},
		HTTPGetter: func(ctx context.Context, u string) (*http.Response, error) {
			req, err := http.NewRequestWithContext(ctx, http.MethodGet, u, nil)
			if err != nil {
				return nil, err
			}
			client := &http.Client{Timeout: timeout}
			return client.Do(req)
		},
		CommandRunner: func(ctx context.Context, name string, args ...string) ([]byte, error) {
			cmd := exec.CommandContext(ctx, name, args...)
			return cmd.CombinedOutput()
		},
		CommandSpawner: func(name string, args ...string) (*exec.Cmd, error) {
			cmd := exec.Command(name, args...)
			if err := cmd.Start(); err != nil {
				return nil, err
			}
			return cmd, nil
		},
		ProcessChecker: isProcessAlive,
	}
}

// KubeReconciliationReceipt captures the deterministic audit trail of cluster healing.
type KubeReconciliationReceipt struct {
	Target            string `json:"target"`
	NodePort          int    `json:"node_port"`
	HostPort          int    `json:"host_port"`
	Reconciled        bool   `json:"reconciled"`
	DryRun            bool   `json:"dry_run"`
	Method            string `json:"method"`
	ActionTaken       string `json:"action_taken"`
	DiagnosticEmitted string `json:"diagnostic_emitted,omitempty"`
}

// CheckAndHealClusterEndpoint checks Kind NodePort 30943 and ARM loopback reachability,
// reconciling offline port-forwards or emitting an Elm/Rust diagnostic block.
func CheckAndHealClusterEndpoint(ctx context.Context, opts KubeHealerOptions) (ProbeResult, KubeReconciliationReceipt) {
	t0 := time.Now()
	res := ProbeResult{
		ID:        "kube-nodeport-healer",
		Invariant: "SPAF-K8S-30943 NodePort & Port-Forward Resilience",
	}
	receipt := KubeReconciliationReceipt{
		Target:   fmt.Sprintf("127.0.0.1:%d / %s", opts.NodePort, opts.ARMURL),
		NodePort: opts.NodePort,
		HostPort: opts.HostPort,
		DryRun:   opts.DryRunFix,
	}

	timeout := opts.Timeout
	if timeout <= 0 {
		timeout = 250 * time.Millisecond
	}

	// 1. Probe reachability of NodePort 30943 directly
	nodePortAddr := fmt.Sprintf("127.0.0.1:%d", opts.NodePort)
	conn, dialErr := opts.Dialer("tcp", nodePortAddr, timeout)
	nodePortReachable := false
	if dialErr == nil {
		conn.Close()
		nodePortReachable = true
	}

	// 2. Probe reachability of Host ARM endpoint (port 9443)
	armReachable := false
	if opts.HTTPGetter != nil && opts.ARMURL != "" {
		reqCtx, cancel := context.WithTimeout(ctx, timeout)
		resp, httpErr := opts.HTTPGetter(reqCtx, opts.ARMURL)
		cancel()
		if httpErr == nil && resp != nil {
			resp.Body.Close()
			if resp.StatusCode < 500 {
				armReachable = true
			}
		}
	} else {
		// Fallback TCP probe on HostPort 9443
		hostAddr := fmt.Sprintf("127.0.0.1:%d", opts.HostPort)
		if hConn, hErr := opts.Dialer("tcp", hostAddr, timeout); hErr == nil {
			hConn.Close()
			armReachable = true
		}
	}

	// If either NodePort 30943 or ARM host port 9443 is alive, the cluster transport is operational
	if nodePortReachable || armReachable {
		res.Status = StatusGreen
		res.DurationMs = msSince(t0)
		summaryParts := []string{}
		if nodePortReachable {
			summaryParts = append(summaryParts, fmt.Sprintf("NodePort %d alive", opts.NodePort))
		}
		if armReachable {
			summaryParts = append(summaryParts, fmt.Sprintf("ARM endpoint %s alive", opts.ARMURL))
		}
		res.Summary = fmt.Sprintf("cluster transport healthy: %s", strings.Join(summaryParts, ", "))
		receipt.Reconciled = false
		receipt.Method = "noop_already_healthy"
		receipt.ActionTaken = res.Summary
		return res, receipt
	}

	// Cluster transport is unreachable.
	// Check if Kind or Kubernetes cluster / BEAM substrate is running.
	kindAlive := opts.ProcessChecker != nil && opts.ProcessChecker("kind")
	beamAlive := opts.ProcessChecker != nil && opts.ProcessChecker("beam.smp")
	kubectlAlive := opts.ProcessChecker != nil && opts.ProcessChecker("kubectl")

	// Pre-boot clean state: if no local cluster or substrate process is active
	if !kindAlive && !beamAlive && !kubectlAlive {
		res.Status = StatusGreen
		res.Summary = fmt.Sprintf("cluster transport idle / NodePort %d clean (pre-boot)", opts.NodePort)
		res.DurationMs = msSince(t0)
		receipt.Method = "noop_preboot"
		receipt.ActionTaken = res.Summary
		return res, receipt
	}

	// Active cluster / substrate detected, but port 30943 / 9443 is unreachable.
	// Check if port-forward process died or needs automated non-destructive reconciliation.
	if opts.Fix {
		if opts.DryRunFix {
			res.Status = StatusGreen
			res.Fixed = true
			res.FixAction = fmt.Sprintf("dry-run: would reconcile port-forward for svc/smalt-backend (127.0.0.1:%d -> %d)", opts.HostPort, opts.HostPort)
			res.Summary = fmt.Sprintf("dry-run healed cluster port-forwarding on port %d", opts.HostPort)
			res.DurationMs = msSince(t0)
			receipt.Reconciled = true
			receipt.Method = "dry_run"
			receipt.ActionTaken = res.FixAction
			return res, receipt
		}

		// Non-destructive reconciliation actuation:
		// Attempt to spawn or restart port-forward via kubectl
		if opts.CommandSpawner != nil {
			cmd, spawnErr := opts.CommandSpawner("kubectl", "port-forward", "--address", "127.0.0.1", "svc/smalt-backend", fmt.Sprintf("%d:%d", opts.HostPort, opts.HostPort))
			if spawnErr == nil && cmd != nil {
				// Anti-vacuity poll: wait up to 400ms for listener to bind
				time.Sleep(100 * time.Millisecond)
				hostAddr := fmt.Sprintf("127.0.0.1:%d", opts.HostPort)
				for attempt := 0; attempt < 3; attempt++ {
					if c, err := opts.Dialer("tcp", hostAddr, 100*time.Millisecond); err == nil {
						c.Close()
						res.Status = StatusGreen
						res.Fixed = true
						res.FixAction = fmt.Sprintf("reconciled cluster port-forwarding: spawned 'kubectl port-forward --address 127.0.0.1 svc/smalt-backend %d:%d' (PID %d)",
							opts.HostPort, opts.HostPort, cmd.Process.Pid)
						res.Summary = fmt.Sprintf("healed cluster port-forward on %s", hostAddr)
						res.DurationMs = msSince(t0)
						receipt.Reconciled = true
						receipt.Method = "kubectl_port_forward_spawn"
						receipt.ActionTaken = res.FixAction
						return res, receipt
					}
					time.Sleep(100 * time.Millisecond)
				}
			}
		}
	}

	// Could not reconcile or Fix=false -> Emit precise Elm/Rust diagnostic block
	configFile := "k8s/kind-config.yaml"
	if opts.RepoRoot != "" {
		configFile = filepath.Join(opts.RepoRoot, "k8s", "kind-config.yaml")
	}

	d := diag.KubeNodePortUnreachable(
		opts.RepoRoot,
		opts.NodePort,
		fmt.Sprintf("Local Kind/Kubernetes port %d and loopback ARM endpoint %s are unreachable; port-forwarding process died or cluster nodeport mapping is inactive.", opts.NodePort, opts.ARMURL),
	)

	renderedDiag := d.Render(diag.ColorConfig{NoColor: true})

	res.Status = StatusYellow
	res.DurationMs = msSince(t0)
	res.Summary = fmt.Sprintf("Kind NodePort %d or ARM endpoint %s unreachable", opts.NodePort, opts.ARMURL)
	res.WhatBroke = renderedDiag
	res.RootCause5Whys = d.RootCause5Whys
	res.PrescriptionCmd = d.FixCommand
	res.Telemetry = map[string]any{
		"node_port":        opts.NodePort,
		"host_port":        opts.HostPort,
		"arm_url":          opts.ARMURL,
		"kind_alive":       kindAlive,
		"beam_alive":       beamAlive,
		"kubectl_alive":    kubectlAlive,
		"diagnostic_code":  d.Code,
		"diagnostic_title": d.Title,
		"config_span":      configFile,
	}

	receipt.Reconciled = false
	receipt.Method = "diagnostic_emitted"
	receipt.ActionTaken = "emitted Elm/Rust diagnostic block " + d.Code
	receipt.DiagnosticEmitted = renderedDiag

	return res, receipt
}
