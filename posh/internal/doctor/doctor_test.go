package doctor_test

import (
	"context"
	"encoding/json"
	"fmt"
	"net"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"smalt.dev/posh/internal/doctor"
)

func findProbe(t *testing.T, rep doctor.Report, id string) doctor.ProbeResult {
	t.Helper()
	for _, p := range rep.Probes {
		if p.ID == id {
			return p
		}
	}
	t.Fatalf("probe %q not found in report", id)
	return doctor.ProbeResult{}
}

// TestDoctorHealthyWithFix verifies that a valid config, clean socket path,
// reachable ARM endpoint, and Fix=true auto-creates tmp/posh/tfrc and yields
// OverallStatus == "GREEN".
func TestDoctorHealthyWithFix(t *testing.T) {
	armSrv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusOK)
		_, _ = w.Write([]byte(`{"cloudEndpoint":"smalt.local"}`))
	}))
	defer armSrv.Close()

	repoRoot := t.TempDir()
	sockPath := filepath.Join("/tmp", fmt.Sprintf("posh-test-clean-%d-%d.sock", os.Getpid(), time.Now().UnixNano()))
	defer os.Remove(sockPath)

	cfgPath := filepath.Join(repoRoot, "posh.yaml")
	cfgContent := fmt.Sprintf("socket: %s\ntcp_addr: \"\"\negress_allowlist:\n  - smalt.internal\n", sockPath)
	if err := os.WriteFile(cfgPath, []byte(cfgContent), 0o644); err != nil {
		t.Fatalf("write config: %v", err)
	}

	rep := doctor.Run(context.Background(), doctor.Options{
		ConfigPath: cfgPath,
		RepoRoot:   repoRoot,
		Fix:        true,
		ARMURL:     armSrv.URL,
	})

	if rep.OverallStatus != doctor.StatusGreen {
		t.Fatalf("expected OverallStatus=%q, got %q:\n%s", doctor.StatusGreen, rep.OverallStatus, doctor.FormatAndon(rep))
	}

	tfrcPath := filepath.Join(repoRoot, "tmp", "posh", "tfrc")
	tfrcBytes, err := os.ReadFile(tfrcPath)
	if err != nil {
		t.Fatalf("expected --fix to create %s: %v", tfrcPath, err)
	}
	if !strings.Contains(string(tfrcBytes), "adapters/terraform-provider-smalt") {
		t.Fatalf("tfrc missing adapters/terraform-provider-smalt: %s", string(tfrcBytes))
	}

	devProbe := findProbe(t, rep, "dev-overrides")
	if !devProbe.Fixed || devProbe.Status != doctor.StatusGreen {
		t.Fatalf("expected dev-overrides Fixed=true Status=GREEN, got %+v", devProbe)
	}
}

// TestDoctorStaleSocketDetectionAndHeal verifies that a stale Unix Domain
// Socket left on disk is detected as RED with a 5-Whys cause, and running with
// Fix=true atomically unlinks it and heals to GREEN.
func TestDoctorStaleSocketDetectionAndHeal(t *testing.T) {
	armSrv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusOK)
	}))
	defer armSrv.Close()

	repoRoot := t.TempDir()
	sockPath := filepath.Join("/tmp", fmt.Sprintf("posh-stale-%d-%d.sock", os.Getpid(), time.Now().UnixNano()))
	defer os.Remove(sockPath)

	ln, err := net.Listen("unix", sockPath)
	if err != nil {
		t.Fatalf("listen unix: %v", err)
	}
	if ul, ok := ln.(*net.UnixListener); ok {
		ul.SetUnlinkOnClose(false)
	}
	_ = ln.Close()

	if _, err := os.Stat(sockPath); err != nil {
		t.Fatalf("expected stale socket file to remain on disk: %v", err)
	}

	cfgPath := filepath.Join(repoRoot, "posh.yaml")
	cfgContent := fmt.Sprintf("socket: %s\ntcp_addr: \"\"\negress_allowlist: []\n", sockPath)
	if err := os.WriteFile(cfgPath, []byte(cfgContent), 0o644); err != nil {
		t.Fatalf("write config: %v", err)
	}

	// Step 1: Run without Fix -> must report RED on uds-socket with 5-Whys cause.
	repRed := doctor.Run(context.Background(), doctor.Options{
		ConfigPath: cfgPath,
		RepoRoot:   repoRoot,
		Fix:        false,
		ARMURL:     armSrv.URL,
	})
	if repRed.OverallStatus != doctor.StatusRed {
		t.Fatalf("expected OverallStatus=RED for stale socket, got %s", repRed.OverallStatus)
	}
	udsRed := findProbe(t, repRed, "uds-socket")
	if udsRed.Status != doctor.StatusRed {
		t.Fatalf("expected uds-socket Status=RED, got %s", udsRed.Status)
	}
	if !strings.Contains(udsRed.RootCause5Whys, "ECONNREFUSED") {
		t.Fatalf("expected 5-Whys to mention ECONNREFUSED, got %q", udsRed.RootCause5Whys)
	}
	if udsRed.PrescriptionCmd != "posh doctor --fix" {
		t.Fatalf("expected PrescriptionCmd='posh doctor --fix', got %q", udsRed.PrescriptionCmd)
	}

	// Step 2: Run with Fix=true -> must atomically unlink stale socket and heal to GREEN.
	repHealed := doctor.Run(context.Background(), doctor.Options{
		ConfigPath: cfgPath,
		RepoRoot:   repoRoot,
		Fix:        true,
		ARMURL:     armSrv.URL,
	})
	if repHealed.OverallStatus != doctor.StatusGreen {
		t.Fatalf("expected OverallStatus=GREEN after Fix=true, got %s:\n%s",
			repHealed.OverallStatus, doctor.FormatAndon(repHealed))
	}
	udsGreen := findProbe(t, repHealed, "uds-socket")
	if udsGreen.Status != doctor.StatusGreen || !udsGreen.Fixed {
		t.Fatalf("expected uds-socket healed to GREEN with Fixed=true, got %+v", udsGreen)
	}
	if _, err := os.Stat(sockPath); !os.IsNotExist(err) {
		t.Fatalf("expected stale socket %s to be unlinked from disk, stat err=%v", sockPath, err)
	}
}

// TestFormatAndonDiagnosticFields verifies that FormatAndon and FormatJSON
// emit structured 5-Whys diagnostic blocks when a defect is present.
func TestFormatAndonDiagnosticFields(t *testing.T) {
	repoRoot := t.TempDir()
	missingCfg := filepath.Join(repoRoot, "nonexistent-posh.yaml")

	rep := doctor.Run(context.Background(), doctor.Options{
		ConfigPath: missingCfg,
		RepoRoot:   repoRoot,
		Fix:        false,
		ARMURL:     "http://127.0.0.1:1/unreachable",
	})

	if !rep.HasRed() {
		t.Fatalf("expected report to have RED status when config is missing")
	}

	out := doctor.FormatAndon(rep)
	for _, needle := range []string{
		"What broke:",
		"Invariant violated:",
		"Root cause (5-Whys):",
		"Prescription:",
		"POSH-008 Hermetic Config",
	} {
		if !strings.Contains(out, needle) {
			t.Errorf("FormatAndon output missing required substring %q\nOutput:\n%s", needle, out)
		}
	}

	rawJSON, err := doctor.FormatJSON(rep)
	if err != nil {
		t.Fatalf("FormatJSON failed: %v", err)
	}
	var decoded doctor.Report
	if err := json.Unmarshal(rawJSON, &decoded); err != nil {
		t.Fatalf("unmarshal FormatJSON output: %v", err)
	}
	if decoded.OverallStatus != doctor.StatusRed {
		t.Fatalf("expected JSON overall_status=RED, got %s", decoded.OverallStatus)
	}
}
