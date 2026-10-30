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
	"sync"
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

// TestRemediationHealDevOverrides verifies repairing corrupted or missing Terraform dev_overrides.
func TestRemediationHealDevOverrides(t *testing.T) {
	repoRoot := t.TempDir()
	tfrcPath := filepath.Join(repoRoot, "tmp", "posh", "tfrc")

	// Corrupt file first
	if err := os.MkdirAll(filepath.Dir(tfrcPath), 0o755); err != nil {
		t.Fatalf("mkdir: %v", err)
	}
	if err := os.WriteFile(tfrcPath, []byte("corrupt content without exclusions"), 0o644); err != nil {
		t.Fatalf("write: %v", err)
	}

	// 1. Dry run should report would-heal without modifying the file
	healed, action, err := doctor.HealDevOverrides(repoRoot, true)
	if err != nil {
		t.Fatalf("dry run error: %v", err)
	}
	if !healed || !strings.Contains(action, "dry-run") {
		t.Fatalf("expected dry-run would heal, got healed=%v action=%s", healed, action)
	}
	curBytes, _ := os.ReadFile(tfrcPath)
	if string(curBytes) != "corrupt content without exclusions" {
		t.Fatalf("dry run must not mutate disk, got %s", string(curBytes))
	}

	// 2. Real heal should write canonical content atomically
	healed, action, err = doctor.HealDevOverrides(repoRoot, false)
	if err != nil {
		t.Fatalf("real heal error: %v", err)
	}
	if !healed || !strings.Contains(action, "healed dev_overrides") {
		t.Fatalf("expected real heal, got healed=%v action=%s", healed, action)
	}

	newBytes, err := os.ReadFile(tfrcPath)
	if err != nil {
		t.Fatalf("read healed tfrc: %v", err)
	}
	text := string(newBytes)
	if !strings.Contains(text, "provider_installation") ||
		!strings.Contains(text, `exclude = ["hashicorp/azurerm"]`) ||
		!strings.Contains(text, "adapters/terraform-provider-smalt") {
		t.Fatalf("healed content does not meet canonical invariant:\n%s", text)
	}

	// 3. Second run should be a no-op (idempotent)
	healed, action, err = doctor.HealDevOverrides(repoRoot, false)
	if err != nil {
		t.Fatalf("idempotent check error: %v", err)
	}
	if healed {
		t.Fatalf("expected no-op on already healed file, got action=%s", action)
	}
}

// TestDeepKernelSocketTelemetry verifies getsockopt and ioctl queue depth inspection.
func TestDeepKernelSocketTelemetry(t *testing.T) {
	tmpDir := t.TempDir()
	sockPath := filepath.Join(tmpDir, "telemetry-test.sock")

	ln, err := net.Listen("unix", sockPath)
	if err != nil {
		t.Fatalf("listen: %v", err)
	}
	defer ln.Close()

	done := make(chan struct{})
	go func() {
		defer close(done)
		srvConn, aErr := ln.Accept()
		if aErr != nil {
			return
		}
		defer srvConn.Close()

		tel, tErr := doctor.InspectSocketBuffers(srvConn)
		if tErr != nil {
			t.Errorf("InspectSocketBuffers server: %v", tErr)
			return
		}
		if tel.RcvBufBytes <= 0 || tel.SndBufBytes <= 0 {
			t.Errorf("expected positive buffer sizes, got rcv=%d snd=%d", tel.RcvBufBytes, tel.SndBufBytes)
		}
		if tel.Status != doctor.StatusGreen {
			t.Errorf("expected GREEN status on clean socket, got %s", tel.Status)
		}
	}()

	cliConn, err := net.Dial("unix", sockPath)
	if err != nil {
		t.Fatalf("dial: %v", err)
	}
	defer cliConn.Close()

	tel, err := doctor.InspectSocketBuffers(cliConn)
	if err != nil {
		t.Fatalf("InspectSocketBuffers client: %v", err)
	}
	if tel.RcvBufBytes <= 0 || tel.SndBufBytes <= 0 {
		t.Fatalf("expected positive buffer sizes, got rcv=%d snd=%d", tel.RcvBufBytes, tel.SndBufBytes)
	}
	<-done
}

// TestFileDescriptorTelemetry verifies rlimit_nofile and open FD inspection.
func TestFileDescriptorTelemetry(t *testing.T) {
	tel, err := doctor.InspectFileDescriptors()
	if err != nil {
		t.Fatalf("InspectFileDescriptors failed: %v", err)
	}
	if tel.OpenFDs == 0 {
		t.Fatalf("expected OpenFDs > 0, got 0")
	}
	if tel.SoftLimit == 0 {
		t.Fatalf("expected SoftLimit > 0, got 0")
	}
	if tel.UsageRatio <= 0.0 || tel.UsageRatio > 1.0 {
		t.Fatalf("unexpected UsageRatio %f", tel.UsageRatio)
	}
	if tel.Status != doctor.StatusGreen && tel.Status != doctor.StatusYellow {
		t.Fatalf("unexpected status %s", tel.Status)
	}
}

// TestCGroupV2Telemetry verifies cgroup v2 controller file parsing and throttling logic.
func TestCGroupV2Telemetry(t *testing.T) {
	mockCGroup := t.TempDir()

	// Write mock cgroup v2 controller files
	// 500 MB current, 1 GB high, 2 GB max
	_ = os.WriteFile(filepath.Join(mockCGroup, "memory.current"), []byte("524288000\n"), 0o644)
	_ = os.WriteFile(filepath.Join(mockCGroup, "memory.high"), []byte("1073741824\n"), 0o644)
	_ = os.WriteFile(filepath.Join(mockCGroup, "memory.max"), []byte("2147483648\n"), 0o644)

	// CPU stat: 1000 periods, 50 throttled (5% throttle ratio -> GREEN)
	cpuStatNominal := "nr_periods 1000\nnr_throttled 50\nthrottled_usec 250000\n"
	_ = os.WriteFile(filepath.Join(mockCGroup, "cpu.stat"), []byte(cpuStatNominal), 0o644)

	telNominal, err := doctor.InspectCGroupV2(mockCGroup)
	if err != nil {
		t.Fatalf("InspectCGroupV2 nominal: %v", err)
	}
	if !telNominal.Mounted {
		t.Fatalf("expected mounted=true")
	}
	if telNominal.Status != doctor.StatusGreen {
		t.Fatalf("expected GREEN for 5%% throttling and 50%% memory, got %s", telNominal.Status)
	}

	// Now simulate severe CPU throttling: 1000 periods, 400 throttled (40% throttle ratio -> RED)
	cpuStatSevere := "nr_periods 1000\nnr_throttled 400\nthrottled_usec 2500000\n"
	_ = os.WriteFile(filepath.Join(mockCGroup, "cpu.stat"), []byte(cpuStatSevere), 0o644)

	telSevere, err := doctor.InspectCGroupV2(mockCGroup)
	if err != nil {
		t.Fatalf("InspectCGroupV2 severe: %v", err)
	}
	if telSevere.Status != doctor.StatusRed {
		t.Fatalf("expected RED for 40%% CPU throttling, got %s", telSevere.Status)
	}
}

// TestJidokaCircuitBreakerLatchingAndHysteresis verifies SLA fence tripping, latching RED, and N=2 hysteresis.
func TestJidokaCircuitBreakerLatchingAndHysteresis(t *testing.T) {
	transitions := make(map[string]int)
	var mu sync.Mutex

	cb := doctor.NewCircuitBreaker(doctor.CircuitBreakerConfig{
		Name:             "arm-downstream-breaker",
		SLALatency:       30 * time.Millisecond,
		ErrorThreshold:   3,
		CooldownDuration: 60 * time.Millisecond,
		RequiredCanaries: 2,
		Alpha:            0.5,
		OnTransition: func(name string, from, to doctor.CircuitState, reason string) {
			mu.Lock()
			transitions[fmt.Sprintf("%s->%s", from, to)]++
			mu.Unlock()
		},
	})

	if cb.State() != doctor.CircuitClosed {
		t.Fatalf("initial state must be CLOSED (GREEN), got %s", cb.State())
	}

	// 1. Nominal requests within SLA (< 30ms) keep circuit GREEN
	for i := 0; i < 5; i++ {
		if err := cb.Allow(); err != nil {
			t.Fatalf("expected Allow()=nil, got %v", err)
		}
		cb.RecordSuccess(10 * time.Millisecond)
	}
	if cb.State() != doctor.CircuitClosed {
		t.Fatalf("state should remain CLOSED, got %s", cb.State())
	}

	// 2. 3 consecutive SLA breaches trip circuit to OPEN (RED)
	cb.RecordSuccess(45 * time.Millisecond) // breach 1
	cb.RecordSuccess(50 * time.Millisecond) // breach 2
	cb.RecordSuccess(60 * time.Millisecond) // breach 3 -> trips to OPEN
	if cb.State() != doctor.CircuitOpen {
		t.Fatalf("expected circuit tripped to OPEN (RED), got %s", cb.State())
	}

	// 3. Fast-fail while latched RED: ingress must be halted
	if err := cb.Allow(); err != doctor.ErrCircuitOpen {
		t.Fatalf("expected ErrCircuitOpen, got %v", err)
	}

	// 4. Wait for cooldown to expire
	time.Sleep(80 * time.Millisecond)

	// 5. First Allow() after cooldown enters HALF-OPEN (YELLOW)
	if err := cb.Allow(); err != nil {
		t.Fatalf("expected canary probe allowed in HALF-OPEN, got %v", err)
	}
	if cb.State() != doctor.CircuitHalfOpen {
		t.Fatalf("expected state HALF-OPEN (YELLOW), got %s", cb.State())
	}

	// 6. Canary 1 passes within SLA -> remains HALF-OPEN (N=2 hysteresis requires 2 passes)
	cb.RecordSuccess(15 * time.Millisecond)
	if cb.State() != doctor.CircuitHalfOpen {
		t.Fatalf("expected state still HALF-OPEN after 1 pass (hysteresis N=2), got %s", cb.State())
	}

	// 7. Canary 2 passes within SLA -> demotes back to CLOSED (GREEN)
	cb.RecordSuccess(12 * time.Millisecond)
	if cb.State() != doctor.CircuitClosed {
		t.Fatalf("expected state restored to CLOSED (GREEN) after 2 passes, got %s", cb.State())
	}

	// 8. Test immediate re-latch to RED on canary failure in HALF-OPEN
	cb.RecordFailure("simulated error 1")
	cb.RecordFailure("simulated error 2")
	cb.RecordFailure("simulated error 3") // trip to RED again
	if cb.State() != doctor.CircuitOpen {
		t.Fatalf("expected circuit OPEN, got %s", cb.State())
	}
	time.Sleep(80 * time.Millisecond)
	_ = cb.Allow() // enter HALF-OPEN
	if cb.State() != doctor.CircuitHalfOpen {
		t.Fatalf("expected HALF-OPEN, got %s", cb.State())
	}
	// Canary fails in HALF-OPEN -> must immediately re-latch to OPEN (RED)
	cb.RecordFailure("canary network timeout")
	if cb.State() != doctor.CircuitOpen {
		t.Fatalf("canary failure in HALF-OPEN must re-latch to OPEN, got %s", cb.State())
	}
}

// TestJSONLDDiagnosticExport verifies formatting JSON-LD / RDF schema diagnostic audit reports.
func TestJSONLDDiagnosticExport(t *testing.T) {
	repoRoot := t.TempDir()
	cfgPath := filepath.Join(repoRoot, "posh.yaml")
	_ = os.WriteFile(cfgPath, []byte("socket: /tmp/test.sock\ntcp_addr: \"\"\negress_allowlist: []\n"), 0o644)

	rep := doctor.Run(context.Background(), doctor.Options{
		ConfigPath:  cfgPath,
		RepoRoot:    repoRoot,
		WorkOrderID: "WO-261030-TPS-DOCTOR",
		SubjectSHA:  "35bd36d021928f083f42d484ffdd2676adb89e82",
	})

	b, err := doctor.FormatJSONLD(rep, "WO-261030-TPS-DOCTOR", "35bd36d021928f083f42d484ffdd2676adb89e82")
	if err != nil {
		t.Fatalf("FormatJSONLD failed: %v", err)
	}

	var doc map[string]any
	if err := json.Unmarshal(b, &doc); err != nil {
		t.Fatalf("unmarshal JSON-LD: %v", err)
	}

	// Verify JSON-LD top-level structure and bindings
	if doc["@context"] == nil {
		t.Fatalf("missing @context in JSON-LD output")
	}
	types, ok := doc["@type"].([]any)
	if !ok || len(types) < 2 {
		t.Fatalf("expected @type array with >=2 types, got %v", doc["@type"])
	}
	if doc["sj:workOrderId"] != "WO-261030-TPS-DOCTOR" {
		t.Fatalf("expected sj:workOrderId='WO-261030-TPS-DOCTOR', got %v", doc["sj:workOrderId"])
	}
	if doc["chatman:subjectSha"] != "35bd36d021928f083f42d484ffdd2676adb89e82" {
		t.Fatalf("expected chatman:subjectSha to match, got %v", doc["chatman:subjectSha"])
	}

	probes, ok := doc["dflss:probes"].([]any)
	if !ok || len(probes) < 7 {
		t.Fatalf("expected dflss:probes array with >= 7 probes, got %d", len(probes))
	}
}

// TestDoctorPredictiveAndKubeHealerIntegration verifies that doctor.Run() integrates
// Probe 11 (predictive-exhaustion) and Probe 12 (kube-nodeport-healer).
func TestDoctorPredictiveAndKubeHealerIntegration(t *testing.T) {
	armSrv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusOK)
		_, _ = w.Write([]byte(`{"cloudEndpoint":"smalt.local"}`))
	}))
	defer armSrv.Close()

	repoRoot := t.TempDir()
	cfgPath := filepath.Join(repoRoot, "posh.yaml")
	_ = os.WriteFile(cfgPath, []byte("socket: /tmp/posh-test-int.sock\ntcp_addr: \"\"\negress_allowlist: []\n"), 0o644)

	// 1. Nominal Run: verify both probes exist and default to GREEN
	rep := doctor.Run(context.Background(), doctor.Options{
		ConfigPath: cfgPath,
		RepoRoot:   repoRoot,
		ARMURL:     armSrv.URL,
	})

	predProbe := findProbe(t, rep, "predictive-exhaustion")
	if predProbe.Status != doctor.StatusGreen {
		t.Fatalf("expected nominal predictive-exhaustion GREEN, got %s", predProbe.Status)
	}

	kubeProbe := findProbe(t, rep, "kube-nodeport-healer")
	if kubeProbe.Status != doctor.StatusGreen {
		t.Fatalf("expected nominal kube-nodeport-healer GREEN, got %s", kubeProbe.Status)
	}

	// 2. Predictive Exhaustion Injection: rapid FD allocation projecting exhaustion in 30s (< 60s)
	predEngine := doctor.NewPredictiveEngine(doctor.DefaultPredictiveConfig())
	t0 := time.Now()
	// Ceiling = 1000, current = 700 (headroom = 300), growth rate = 10 FDs/sec -> TTE = 30s (YELLOW)
	predEngine.RecordFDSample(680, 1000, t0.Add(-2*time.Second))
	predEngine.RecordFDSample(690, 1000, t0.Add(-1*time.Second))
	predEngine.RecordFDSample(700, 1000, t0)

	repPredYellow := doctor.Run(context.Background(), doctor.Options{
		ConfigPath:       cfgPath,
		RepoRoot:         repoRoot,
		ARMURL:           armSrv.URL,
		PredictiveEngine: predEngine,
	})

	pYellow := findProbe(t, repPredYellow, "predictive-exhaustion")
	if pYellow.Status != doctor.StatusYellow {
		t.Fatalf("expected predictive probe Status=YELLOW for 30s exhaustion projection, got %s", pYellow.Status)
	}
	if !strings.Contains(pYellow.Summary, "Jidoka [YELLOW]") {
		t.Fatalf("expected Jidoka warning in summary, got: %s", pYellow.Summary)
	}

	// 3. KubeHealer Fix Injection: simulated unreachable NodePort with Fix=true
	kOpts := doctor.KubeHealerOptions{
		NodePort:  30943,
		HostPort:  9443,
		ARMURL:    "http://127.0.0.1:9443/unreachable",
		Fix:       true,
		DryRunFix: true,
		Dialer: func(network, address string, timeout time.Duration) (net.Conn, error) {
			return nil, fmt.Errorf("connection refused")
		},
		HTTPGetter: func(ctx context.Context, u string) (*http.Response, error) {
			return nil, fmt.Errorf("connection refused")
		},
		ProcessChecker: func(name string) bool { return name == "kind" },
	}

	repKubeHealed := doctor.Run(context.Background(), doctor.Options{
		ConfigPath:     cfgPath,
		RepoRoot:       repoRoot,
		ARMURL:         armSrv.URL,
		Fix:            true,
		DryRunFix:      true,
		KubeHealerOpts: &kOpts,
	})

	pKubeHealed := findProbe(t, repKubeHealed, "kube-nodeport-healer")
	if !pKubeHealed.Fixed || pKubeHealed.Status != doctor.StatusGreen {
		t.Fatalf("expected kube-nodeport-healer Fixed=true Status=GREEN, got %+v", pKubeHealed)
	}
}


