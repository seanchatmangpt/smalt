package doctor_test

import (
	"context"
	"errors"
	"fmt"
	"net"
	"net/http"
	"os/exec"
	"strings"
	"testing"
	"time"

	"smalt.dev/posh/internal/doctor"
)

// mockConn implements net.Conn for testing
type mockConn struct {
	closed bool
}

func (m *mockConn) Read(b []byte) (n int, err error)   { return 0, nil }
func (m *mockConn) Write(b []byte) (n int, err error)  { return len(b), nil }
func (m *mockConn) Close() error                       { m.closed = true; return nil }
func (m *mockConn) LocalAddr() net.Addr                { return &net.TCPAddr{Port: 12345} }
func (m *mockConn) RemoteAddr() net.Addr               { return &net.TCPAddr{Port: 30943} }
func (m *mockConn) SetDeadline(t time.Time) error      { return nil }
func (m *mockConn) SetReadDeadline(t time.Time) error  { return nil }
func (m *mockConn) SetWriteDeadline(t time.Time) error { return nil }

func TestKubeHealerHealthyNodePort(t *testing.T) {
	opts := doctor.KubeHealerOptions{
		NodePort:  30943,
		HostPort:  9443,
		ARMURL:    "http://127.0.0.1:9443/metadata/endpoints",
		Dialer: func(network, address string, timeout time.Duration) (net.Conn, error) {
			if strings.Contains(address, "30943") {
				return &mockConn{}, nil
			}
			return nil, errors.New("connection refused")
		},
		ProcessChecker: func(name string) bool { return true },
	}

	res, rcpt := doctor.CheckAndHealClusterEndpoint(context.Background(), opts)
	if res.Status != doctor.StatusGreen {
		t.Fatalf("expected Status GREEN for healthy NodePort 30943, got %s (summary: %s)", res.Status, res.Summary)
	}
	if !strings.Contains(res.Summary, "NodePort 30943 alive") {
		t.Fatalf("expected summary to mention NodePort 30943 alive, got: %s", res.Summary)
	}
	if rcpt.Method != "noop_already_healthy" {
		t.Fatalf("expected noop_already_healthy receipt, got: %s", rcpt.Method)
	}
}

func TestKubeHealerPrebootClean(t *testing.T) {
	opts := doctor.KubeHealerOptions{
		NodePort: 30943,
		HostPort: 9443,
		ARMURL:   "http://127.0.0.1:9443/metadata/endpoints",
		Dialer: func(network, address string, timeout time.Duration) (net.Conn, error) {
			return nil, errors.New("connection refused")
		},
		HTTPGetter: func(ctx context.Context, u string) (*http.Response, error) {
			return nil, errors.New("connection refused")
		},
		ProcessChecker: func(name string) bool {
			// No substrate processes active
			return false
		},
	}

	res, rcpt := doctor.CheckAndHealClusterEndpoint(context.Background(), opts)
	if res.Status != doctor.StatusGreen {
		t.Fatalf("expected Status GREEN in pre-boot clean state, got %s", res.Status)
	}
	if !strings.Contains(res.Summary, "pre-boot") {
		t.Fatalf("expected summary to mention pre-boot, got: %s", res.Summary)
	}
	if rcpt.Method != "noop_preboot" {
		t.Fatalf("expected receipt noop_preboot, got: %s", rcpt.Method)
	}
}

func TestKubeHealerEmitsElmRustDiagnosticWhenUnreachable(t *testing.T) {
	opts := doctor.KubeHealerOptions{
		NodePort: 30943,
		HostPort: 9443,
		ARMURL:   "http://127.0.0.1:9443/metadata/endpoints",
		RepoRoot: t.TempDir(),
		Fix:      false,
		Dialer: func(network, address string, timeout time.Duration) (net.Conn, error) {
			return nil, errors.New("connection refused")
		},
		HTTPGetter: func(ctx context.Context, u string) (*http.Response, error) {
			return nil, errors.New("connection refused")
		},
		ProcessChecker: func(name string) bool {
			return name == "kind" // kind is active, but port forward/nodeport is down!
		},
	}

	res, rcpt := doctor.CheckAndHealClusterEndpoint(context.Background(), opts)
	if res.Status != doctor.StatusYellow {
		t.Fatalf("expected Status YELLOW for unreachable endpoint with active cluster, got %s", res.Status)
	}

	// Verify Elm/Rust diagnostic syntax in WhatBroke
	rendered := res.WhatBroke
	if !strings.Contains(rendered, "error[E0401]") && !strings.Contains(rendered, "E0401") {
		t.Fatalf("expected error[E0401] in WhatBroke, got:\n%s", rendered)
	}
	if !strings.Contains(rendered, "invariant: SPAF-K8S-30943") {
		t.Fatalf("expected invariant in diagnostic, got:\n%s", rendered)
	}
	if !strings.Contains(rendered, "5-whys:") {
		t.Fatalf("expected 5-whys in diagnostic, got:\n%s", rendered)
	}
	if !strings.Contains(rendered, "remediation:") {
		t.Fatalf("expected remediation command in diagnostic, got:\n%s", rendered)
	}
	if rcpt.Method != "diagnostic_emitted" {
		t.Fatalf("expected receipt method diagnostic_emitted, got: %s", rcpt.Method)
	}
}

func TestKubeHealerDryRunReconciliation(t *testing.T) {
	opts := doctor.KubeHealerOptions{
		NodePort:  30943,
		HostPort:  9443,
		ARMURL:    "http://127.0.0.1:9443/metadata/endpoints",
		Fix:       true,
		DryRunFix: true,
		Dialer: func(network, address string, timeout time.Duration) (net.Conn, error) {
			return nil, errors.New("connection refused")
		},
		HTTPGetter: func(ctx context.Context, u string) (*http.Response, error) {
			return nil, errors.New("connection refused")
		},
		ProcessChecker: func(name string) bool {
			return name == "kubectl"
		},
	}

	res, rcpt := doctor.CheckAndHealClusterEndpoint(context.Background(), opts)
	if res.Status != doctor.StatusGreen {
		t.Fatalf("expected Status GREEN for dry-run heal, got %s", res.Status)
	}
	if !res.Fixed || !strings.Contains(res.FixAction, "dry-run: would reconcile") {
		t.Fatalf("expected Fixed=true with dry-run action, got %+v", res)
	}
	if rcpt.Method != "dry_run" || !rcpt.Reconciled {
		t.Fatalf("expected receipt dry_run reconciled=true, got %+v", rcpt)
	}
}

func TestKubeHealerActiveReconciliation(t *testing.T) {
	portBound := false
	spawned := false

	opts := doctor.KubeHealerOptions{
		NodePort:  30943,
		HostPort:  9443,
		ARMURL:    "http://127.0.0.1:9443/metadata/endpoints",
		Fix:       true,
		DryRunFix: false,
		Dialer: func(network, address string, timeout time.Duration) (net.Conn, error) {
			if portBound && strings.Contains(address, "9443") {
				return &mockConn{}, nil
			}
			return nil, errors.New("connection refused")
		},
		HTTPGetter: func(ctx context.Context, u string) (*http.Response, error) {
			if portBound {
				return &http.Response{
					StatusCode: 200,
					Body:       http.NoBody,
				}, nil
			}
			return nil, errors.New("connection refused")
		},
		ProcessChecker: func(name string) bool {
			return name == "kind"
		},
		CommandSpawner: func(name string, args ...string) (*exec.Cmd, error) {
			spawned = true
			portBound = true // Port becomes reachable after spawn!
			cmd := exec.Command("true")
			_ = cmd.Start()
			return cmd, nil
		},
	}

	res, rcpt := doctor.CheckAndHealClusterEndpoint(context.Background(), opts)
	if !spawned {
		t.Fatalf("expected CommandSpawner to be invoked")
	}
	if res.Status != doctor.StatusGreen || !res.Fixed {
		t.Fatalf("expected Status GREEN and Fixed=true, got Status=%s Fixed=%v", res.Status, res.Fixed)
	}
	if !strings.Contains(res.FixAction, "reconciled cluster port-forwarding") {
		t.Fatalf("expected FixAction to describe reconciliation, got: %s", res.FixAction)
	}
	if rcpt.Method != "kubectl_port_forward_spawn" || !rcpt.Reconciled {
		t.Fatalf("expected kubectl_port_forward_spawn receipt, got %+v", rcpt)
	}
}

func TestKubeHealerSpawnerFailureFallsBackToDiagnostic(t *testing.T) {
	opts := doctor.KubeHealerOptions{
		NodePort:  30943,
		HostPort:  9443,
		ARMURL:    "http://127.0.0.1:9443/metadata/endpoints",
		Fix:       true,
		DryRunFix: false,
		Dialer: func(network, address string, timeout time.Duration) (net.Conn, error) {
			return nil, errors.New("connection refused")
		},
		HTTPGetter: func(ctx context.Context, u string) (*http.Response, error) {
			return nil, errors.New("connection refused")
		},
		ProcessChecker: func(name string) bool {
			return name == "kind"
		},
		CommandSpawner: func(name string, args ...string) (*exec.Cmd, error) {
			return nil, fmt.Errorf("kubectl not found on PATH")
		},
	}

	res, rcpt := doctor.CheckAndHealClusterEndpoint(context.Background(), opts)
	if res.Status != doctor.StatusYellow {
		t.Fatalf("expected Status YELLOW when reconciliation spawner fails, got %s", res.Status)
	}
	if !strings.Contains(res.WhatBroke, "E0401") {
		t.Fatalf("expected diagnostic E0401, got: %s", res.WhatBroke)
	}
	if rcpt.Reconciled {
		t.Fatalf("expected Reconciled=false, got true")
	}
}
