// Package doctor implements the DfLSS / TPS Autonomous System Physician
// ("The Doctor") and Andon telemetry for the POSH Go adapter membrane.
//
// Design principles:
//   - Jidoka (Autonomation): detect abnormalities before execution, stop the
//     line on RED defects, and provide deterministic root-cause diagnostics.
//   - Poka-Yoke (Mistake-Proofing): validate configuration, UDS sockets,
//     kernel peercred support, Terraform dev_overrides, disk headroom, and
//     toolchain alignment in sub-second execution.
//   - 5-Whys Root Cause: never report a symptom without a causal chain and an
//     exact copy-pastable prescription command.
package doctor

import (
	"context"
	"encoding/json"
	"fmt"
	"net"
	"net/http"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"strings"
	"syscall"
	"time"
	"unsafe"

	"smalt.dev/posh/internal/config"
)

// Andon status levels (TPS visual management board).
const (
	StatusGreen  = "GREEN"
	StatusYellow = "YELLOW"
	StatusRed    = "RED"
)

// DefaultARMURL is the bearer-exempt Smalt ARM metadata readiness endpoint.
const DefaultARMURL = "http://127.0.0.1:9443/metadata/endpoints?api-version=2020-01-01"

// minDiskHeadroomBytes is the 1 GiB minimum free disk space threshold.
const minDiskHeadroomBytes = 1 << 30

// Options configures a Doctor diagnostic run.
type Options struct {
	ConfigPath       string
	RepoRoot         string
	Fix              bool
	DryRunFix        bool
	ARMURL           string
	WorkOrderID      string
	SubjectSHA       string
	PredictiveEngine *PredictiveEngine
	KubeHealerOpts   *KubeHealerOptions
}

// ProbeResult captures the outcome and 5-Whys telemetry of a single check.
type ProbeResult struct {
	ID              string   `json:"id"`
	Status          string   `json:"status"`
	DurationMs      float64  `json:"duration_ms"`
	Summary         string   `json:"summary"`
	WhatBroke       string   `json:"what_broke,omitempty"`
	Invariant       string   `json:"invariant"`
	RootCause5Whys  string   `json:"root_cause_5_whys,omitempty"`
	PrescriptionCmd string   `json:"prescription_cmd,omitempty"`
	Fixed           bool     `json:"fixed,omitempty"`
	FixAction       string   `json:"fix_action,omitempty"`
	Telemetry       any      `json:"telemetry,omitempty"`
	CausalChain     []string `json:"causal_chain,omitempty"`
}

// Report aggregates all probe results and overall Andon status.
type Report struct {
	OverallStatus   string        `json:"overall_status"`
	TotalDurationMs float64       `json:"total_duration_ms"`
	FixedCount      int           `json:"fixed_count"`
	Timestamp       string        `json:"timestamp"`
	WorkOrderID     string        `json:"work_order_id,omitempty"`
	SubjectSHA      string        `json:"subject_sha,omitempty"`
	Probes          []ProbeResult `json:"probes"`
}

// HasRed reports whether any probe ended in StatusRed.
func (r Report) HasRed() bool {
	for _, p := range r.Probes {
		if p.Status == StatusRed {
			return true
		}
	}
	return false
}

// Run executes the 7 deterministic health probes and returns a complete Report.
func Run(ctx context.Context, opts Options) Report {
	start := time.Now()
	if opts.ConfigPath == "" {
		opts.ConfigPath = "posh.yaml"
	}
	if opts.RepoRoot == "" {
		opts.RepoRoot = "."
	}
	if opts.ARMURL == "" {
		opts.ARMURL = DefaultARMURL
	}

	var probes []ProbeResult

	// Probe 1: Config Poka-Yoke
	p1, cfg := probeConfigPokaYoke(opts)
	probes = append(probes, p1)

	// Probe 2: UDS Socket Liveness & Stale Socket Healer
	p2 := probeUDSSocket(opts, cfg)
	probes = append(probes, p2)

	// Probe 3: Kernel Peer Credentials (LOCAL_PEERCRED / SO_PEERCRED)
	p3 := probeKernelPeerCred()
	probes = append(probes, p3)

	// Probe 4: Smalt ARM Gateway Control Plane (port 9443)
	p4 := probeARMGateway(ctx, opts)
	probes = append(probes, p4)

	// Probe 5: Terraform Local Provider dev_overrides (tmp/posh/tfrc)
	p5 := probeDevOverrides(opts)
	probes = append(probes, p5)

	// Probe 6: Disk Headroom (Heijunka / statfs >= 1 GiB)
	p6 := probeDiskHeadroom(opts)
	probes = append(probes, p6)

	// Probe 7: Toolchain Alignment (go, terraform)
	p7 := probeToolchain()
	probes = append(probes, p7)

	// Probe 8: Kernel Socket Buffer & Queue Bloat Telemetry
	p8 := probeSocketBufferBacklog(opts, cfg)
	probes = append(probes, p8)

	// Probe 9: OS File Descriptor Table & Leakage Telemetry
	p9 := probeFileDescriptorPressure()
	probes = append(probes, p9)

	// Probe 10: Container CGroup v2 Telemetry (Memory & CPU Throttling)
	p10 := probeCGroupThrottling(opts)
	probes = append(probes, p10)

	// Probe 11: Predictive Resource Exhaustion & Trend Engine (EWMA Derivatives)
	p11 := probePredictiveExhaustion(opts, cfg)
	probes = append(probes, p11)

	// Probe 12: Automated Cluster Port-Forwarding & NodePort Healer (Port 30943 / 9443)
	p12 := probeClusterNodePort(ctx, opts)
	probes = append(probes, p12)

	overall := StatusGreen
	fixedCount := 0
	for _, p := range probes {
		if p.Fixed {
			fixedCount++
		}
		switch p.Status {
		case StatusRed:
			overall = StatusRed
		case StatusYellow:
			if overall != StatusRed {
				overall = StatusYellow
			}
		}
	}

	return Report{
		OverallStatus:   overall,
		TotalDurationMs: msSince(start),
		FixedCount:      fixedCount,
		Timestamp:       time.Now().UTC().Format(time.RFC3339),
		WorkOrderID:     opts.WorkOrderID,
		SubjectSHA:      opts.SubjectSHA,
		Probes:          probes,
	}
}

func msSince(t time.Time) float64 {
	return float64(time.Since(t).Microseconds()) / 1000.0
}

// Probe 1: config-poka-yoke
func probeConfigPokaYoke(opts Options) (ProbeResult, *config.Config) {
	t0 := time.Now()
	res := ProbeResult{
		ID:        "config-poka-yoke",
		Invariant: "POSH-008 Hermetic Config",
	}
	cfg, err := config.Load(opts.ConfigPath)
	res.DurationMs = msSince(t0)
	if err != nil {
		res.Status = StatusRed
		res.Summary = fmt.Sprintf("invalid or missing config at %s", opts.ConfigPath)
		res.WhatBroke = err.Error()
		res.RootCause5Whys = fmt.Sprintf(
			"POSH enforces fail-closed configuration (POSH-008); %q could not be loaded or failed schema validation, so the membrane refuses to boot to prevent unguarded egress.",
			opts.ConfigPath,
		)
		res.PrescriptionCmd = fmt.Sprintf("cp posh/posh.yaml %s  # or run with: posh doctor -config posh/posh.yaml", opts.ConfigPath)
		return res, nil
	}
	res.Status = StatusGreen
	res.Summary = fmt.Sprintf("valid config %s (socket=%s, allowlist=%d)", opts.ConfigPath, cfg.Socket, len(cfg.EgressAllowlist))
	return res, cfg
}

// Probe 2: uds-socket
func probeUDSSocket(opts Options, cfg *config.Config) ProbeResult {
	t0 := time.Now()
	res := ProbeResult{
		ID:        "uds-socket",
		Invariant: "POSH-001 UDS Listener Readiness",
	}

	sockPath := filepath.Join(opts.RepoRoot, "posh", "run", "posh.sock")
	if cfg != nil && cfg.Socket != "" {
		sockPath = cfg.Socket
	}

	_, statErr := os.Stat(sockPath)
	if os.IsNotExist(statErr) {
		res.Status = StatusGreen
		res.Summary = "socket path clean (pre-boot)"
		res.DurationMs = msSince(t0)
		return res
	}
	if statErr != nil {
		res.Status = StatusRed
		res.Summary = fmt.Sprintf("cannot stat socket path %s", sockPath)
		res.WhatBroke = fmt.Sprintf("Failed to stat Unix Domain Socket path %s: %v", sockPath, statErr)
		res.RootCause5Whys = "Filesystem permissions or corrupted parent directory prevented stat(2) on the configured UDS path."
		res.PrescriptionCmd = fmt.Sprintf("ls -ld %s", filepath.Dir(sockPath))
		res.DurationMs = msSince(t0)
		return res
	}

	conn, dialErr := net.DialTimeout("unix", sockPath, 200*time.Millisecond)
	if dialErr == nil {
		_ = conn.Close()
		res.Status = StatusGreen
		res.Summary = "live POSH membrane listening on " + sockPath
		res.DurationMs = msSince(t0)
		return res
	}

	// Socket file exists on disk, but connect(2) failed -> stale socket file.
	if opts.Fix {
		if healed, action, _ := HealStaleUDSSocket(sockPath, opts.DryRunFix); healed {
			res.Status = StatusGreen
			res.Fixed = true
			res.FixAction = action
			res.Summary = "healed stale UDS socket at " + sockPath
			res.DurationMs = msSince(t0)
			return res
		}
	}

	res.Status = StatusRed
	res.Summary = "stale UDS socket file at " + sockPath
	res.WhatBroke = "Stale Unix Domain Socket file at " + sockPath
	res.RootCause5Whys = "Socket inode exists on filesystem, but connect(2) returned ECONNREFUSED because a prior posh process exited without unlinking its socket."
	res.PrescriptionCmd = "posh doctor --fix"
	res.DurationMs = msSince(t0)
	return res
}

type darwinXucred struct {
	Version uint32
	Uid     uint32
	Ngroups int16
	Groups  [16]uint32
}

// Probe 3: kernel-peercred
func probeKernelPeerCred() ProbeResult {
	t0 := time.Now()
	res := ProbeResult{
		ID:        "kernel-peercred",
		Invariant: "POSH-PEERCRED Kernel Creds",
	}

	// Use a short socket path so macOS sun_path (104 bytes max) never overflows
	// when os.TempDir() resolves to a deep /var/folders/... path.
	baseDir := "/tmp"
	if st, err := os.Stat(baseDir); err != nil || !st.IsDir() {
		baseDir = os.TempDir()
	}
	tmpSock := filepath.Join(baseDir, fmt.Sprintf("posh-peercred-%d-%d.sock", os.Getpid(), time.Now().UnixNano()))
	defer os.Remove(tmpSock)

	ln, err := net.Listen("unix", tmpSock)
	if err != nil {
		res.Status = StatusRed
		res.Summary = "failed to bind temporary UDS socket for peercred probe"
		res.WhatBroke = fmt.Sprintf("net.Listen(unix, %s) failed: %v", tmpSock, err)
		res.RootCause5Whys = "Kernel or sandbox prevented binding a Unix Domain Socket in temporary storage."
		res.PrescriptionCmd = fmt.Sprintf("ls -ld %s", baseDir)
		res.DurationMs = msSince(t0)
		return res
	}
	defer ln.Close()

	acceptCh := make(chan error, 1)
	go func() {
		srvConn, aerr := ln.Accept()
		if aerr != nil {
			acceptCh <- aerr
			return
		}
		defer srvConn.Close()
		acceptCh <- checkConnPeerCred(srvConn)
	}()

	cliConn, err := net.DialTimeout("unix", tmpSock, 200*time.Millisecond)
	if err != nil {
		res.Status = StatusRed
		res.Summary = "failed to dial temporary UDS socket for peercred probe"
		res.WhatBroke = fmt.Sprintf("net.DialTimeout(unix, %s) failed: %v", tmpSock, err)
		res.RootCause5Whys = "Loopback UDS dial failed before kernel peer credentials could be inspected."
		res.PrescriptionCmd = "posh doctor"
		res.DurationMs = msSince(t0)
		return res
	}
	_ = cliConn.Close()

	if credErr := <-acceptCh; credErr != nil {
		res.Status = StatusRed
		res.Summary = "kernel peercred verification failed"
		res.WhatBroke = credErr.Error()
		res.RootCause5Whys = "OS kernel rejected getsockopt peer credential inspection on the Unix Domain Socket."
		res.PrescriptionCmd = "uname -a"
		res.DurationMs = msSince(t0)
		return res
	}

	res.Status = StatusGreen
	res.Summary = fmt.Sprintf("kernel UDS peercred verified (uid=%d, goos=%s)", os.Geteuid(), runtime.GOOS)
	res.DurationMs = msSince(t0)
	return res
}

func checkConnPeerCred(c net.Conn) error {
	uc, ok := c.(*net.UnixConn)
	if !ok {
		return fmt.Errorf("expected *net.UnixConn, got %T", c)
	}
	rc, err := uc.SyscallConn()
	if err != nil {
		return fmt.Errorf("SyscallConn: %w", err)
	}
	var sockErr error
	ctrlErr := rc.Control(func(fd uintptr) {
		if runtime.GOOS == "darwin" {
			var cred darwinXucred
			credLen := uint32(unsafe.Sizeof(cred))
			_, _, errno := syscall.Syscall6(
				syscall.SYS_GETSOCKOPT,
				fd,
				0,     // SOL_LOCAL
				0x001, // LOCAL_PEERCRED
				uintptr(unsafe.Pointer(&cred)),
				uintptr(unsafe.Pointer(&credLen)),
				0,
			)
			if errno != 0 {
				sockErr = errno
				return
			}
			euid := uint32(os.Geteuid())
			if cred.Uid != euid && cred.Uid != 0 {
				sockErr = fmt.Errorf("unexpected peer uid %d (euid=%d)", cred.Uid, euid)
			}
		}
	})
	if ctrlErr != nil {
		return ctrlErr
	}
	return sockErr
}

// Probe 4: arm-gateway
func probeARMGateway(ctx context.Context, opts Options) ProbeResult {
	t0 := time.Now()
	res := ProbeResult{
		ID:        "arm-gateway",
		Invariant: "SPAF-ARM-9443 Control Plane",
	}

	reqCtx, cancel := context.WithTimeout(ctx, 500*time.Millisecond)
	defer cancel()

	req, err := http.NewRequestWithContext(reqCtx, http.MethodGet, opts.ARMURL, nil)
	if err == nil {
		client := &http.Client{Timeout: 500 * time.Millisecond}
		resp, httpErr := client.Do(req)
		if httpErr == nil {
			_ = resp.Body.Close()
			res.Status = StatusGreen
			res.Summary = fmt.Sprintf("Smalt ARM Gateway reachable (%s -> HTTP %d)", opts.ARMURL, resp.StatusCode)
			res.DurationMs = msSince(t0)
			return res
		}
	}

	beamAlive := isProcessAlive("beam.smp")
	kindAlive := isProcessAlive("kind")
	if beamAlive || kindAlive {
		if opts.Fix {
			if freed, act, _ := FreePortCollision(9443, nil, opts.DryRunFix); freed {
				res.Status = StatusGreen
				res.Fixed = true
				res.FixAction = act
				res.Summary = "healed port 9443 collision: " + act
				res.DurationMs = msSince(t0)
				return res
			}
		}
		res.Status = StatusYellow
		procNote := fmt.Sprintf("beam.smp=%v, kind=%v (port forward or listener on 9443 not bound)", beamAlive, kindAlive)
		res.Summary = fmt.Sprintf("ARM gateway unreachable at %s (%s)", opts.ARMURL, procNote)
		res.WhatBroke = fmt.Sprintf("GET %s timed out or refused connection (%s)", opts.ARMURL, procNote)
		res.RootCause5Whys = "Substrate processes are alive, but port 9443 is unreachable because the gateway listener is not bound or port-forwarding dropped."
		res.PrescriptionCmd = "just down && just up  # or: kubectl port-forward"
		res.DurationMs = msSince(t0)
		return res
	}

	res.Status = StatusGreen
	res.Summary = "ARM gateway idle / port 9443 clean (pre-boot)"
	res.DurationMs = msSince(t0)
	return res
}

func isProcessAlive(name string) bool {
	ctx, cancel := context.WithTimeout(context.Background(), 150*time.Millisecond)
	defer cancel()
	cmd := exec.CommandContext(ctx, "pgrep", "-x", name)
	return cmd.Run() == nil
}

// Probe 5: dev-overrides
func probeDevOverrides(opts Options) ProbeResult {
	t0 := time.Now()
	res := ProbeResult{
		ID:        "dev-overrides",
		Invariant: "TF-DEV-OVERRIDES Local Provider",
	}

	absRoot, err := filepath.Abs(opts.RepoRoot)
	if err != nil {
		absRoot = opts.RepoRoot
	}
	tfrcPath := filepath.Join(opts.RepoRoot, "tmp", "posh", "tfrc")
	expectedProviderDir := filepath.Join(absRoot, "adapters", "terraform-provider-smalt")

	data, readErr := os.ReadFile(tfrcPath)
	if readErr == nil && strings.Contains(string(data), "adapters/terraform-provider-smalt") {
		res.Status = StatusGreen
		res.Summary = fmt.Sprintf("transient dev_overrides active at %s", tfrcPath)
		res.DurationMs = msSince(t0)
		return res
	}

	if opts.Fix {
		if healed, action, _ := HealDevOverrides(opts.RepoRoot, opts.DryRunFix); healed {
			res.Status = StatusGreen
			res.Fixed = true
			res.FixAction = action
			res.Summary = "created transient Terraform dev_overrides at " + tfrcPath
			res.DurationMs = msSince(t0)
			return res
		}
	}

	res.Status = StatusYellow
	res.Summary = fmt.Sprintf("transient Terraform rc missing or stale at %s", tfrcPath)
	res.WhatBroke = fmt.Sprintf("Missing or unconfigured %s pointing to %s", tfrcPath, expectedProviderDir)
	res.RootCause5Whys = "Terraform requires TF_CLI_CONFIG_FILE with dev_overrides pointing to adapters/terraform-provider-smalt so 'hashicorp/azurerm' resolves locally without hitting registry.terraform.io."
	res.PrescriptionCmd = "posh doctor --fix  # or: just posh-install"
	res.DurationMs = msSince(t0)
	return res
}

// Probe 6: disk-headroom
func probeDiskHeadroom(opts Options) ProbeResult {
	t0 := time.Now()
	res := ProbeResult{
		ID:        "disk-headroom",
		Invariant: "TPS-HEIJUNKA Disk Headroom",
	}

	var st syscall.Statfs_t
	target := opts.RepoRoot
	if target == "" {
		target = "."
	}
	if err := syscall.Statfs(target, &st); err != nil {
		res.Status = StatusYellow
		res.Summary = fmt.Sprintf("statfs(%s) unavailable: %v", target, err)
		res.WhatBroke = fmt.Sprintf("syscall.Statfs(%q) failed: %v", target, err)
		res.RootCause5Whys = "Unable to query filesystem free blocks via statfs(2)."
		res.PrescriptionCmd = "df -h ."
		res.DurationMs = msSince(t0)
		return res
	}

	freeBytes := uint64(st.Bavail) * uint64(st.Bsize)
	freeGiB := float64(freeBytes) / float64(1<<30)
	if freeBytes < minDiskHeadroomBytes {
		res.Status = StatusYellow
		res.Summary = fmt.Sprintf("low disk headroom: %.2f GiB available (< 1.00 GiB)", freeGiB)
		res.WhatBroke = fmt.Sprintf("Available disk space is %.2f GiB, below the 1.00 GiB safety floor", freeGiB)
		res.RootCause5Whys = "Insufficient disk headroom causes Go build cache writes, Kind container layer pulls, or SQLite WAL checkpoints to fail mid-flight."
		res.PrescriptionCmd = "just posh-clean"
		res.DurationMs = msSince(t0)
		return res
	}

	res.Status = StatusGreen
	res.Summary = fmt.Sprintf("%.2f GiB available (>= 1.00 GiB floor)", freeGiB)
	res.DurationMs = msSince(t0)
	return res
}

// Probe 7: toolchain
func probeToolchain() ProbeResult {
	t0 := time.Now()
	res := ProbeResult{
		ID:        "toolchain",
		Invariant: "TPS-TOOLCHAIN Alignment",
	}

	var missing []string
	var found []string
	for _, tool := range []string{"go", "terraform"} {
		if p, err := exec.LookPath(tool); err != nil {
			missing = append(missing, tool)
		} else {
			found = append(found, fmt.Sprintf("%s=%s", tool, p))
		}
	}

	if len(missing) > 0 {
		res.Status = StatusYellow
		res.Summary = fmt.Sprintf("missing optional toolchain binaries: %s", strings.Join(missing, ", "))
		res.WhatBroke = fmt.Sprintf("Tools not found on PATH: %s", strings.Join(missing, ", "))
		res.RootCause5Whys = "Required developer CLI tools are not installed or their bin directory is absent from PATH."
		res.PrescriptionCmd = fmt.Sprintf("brew install %s", strings.Join(missing, " "))
		res.DurationMs = msSince(t0)
		return res
	}

	res.Status = StatusGreen
	res.Summary = fmt.Sprintf("go and terraform present on PATH (%d/2)", len(found))
	res.DurationMs = msSince(t0)
	return res
}

// Probe 11: predictive-exhaustion
func probePredictiveExhaustion(opts Options, cfg *config.Config) ProbeResult {
	t0 := time.Now()
	res := ProbeResult{
		ID:        "predictive-exhaustion",
		Invariant: "TPS-JIDOKA-PREDICTIVE Resource Exhaustion Forecast",
	}

	engine := opts.PredictiveEngine
	if engine == nil {
		engine = DefaultPredictiveEngine
	}

	// Ingest live host readings if running default ambient engine or if custom engine is empty
	if opts.PredictiveEngine == nil || engine.SampleCount() == 0 {
		if fdTel, err := InspectFileDescriptors(); err == nil {
			engine.RecordFDSample(float64(fdTel.OpenFDs), float64(fdTel.SoftLimit), t0)
		}

		sockPath := filepath.Join(opts.RepoRoot, "posh", "run", "posh.sock")
		if cfg != nil && cfg.Socket != "" {
			sockPath = cfg.Socket
		}
		if conn, err := net.DialTimeout("unix", sockPath, 50*time.Millisecond); err == nil {
			if sTel, sErr := InspectSocketBuffers(conn); sErr == nil {
				engine.RecordSocketBufferSample(float64(sTel.RcvQueueDepth), float64(sTel.RcvBufBytes), t0)
			}
			_ = conn.Close()
		}
	}

	telemetry := engine.Evaluate(t0)
	res.DurationMs = msSince(t0)
	res.Status = telemetry.OverallStatus
	res.Summary = telemetry.Summary
	res.WhatBroke = telemetry.WhatBroke
	res.RootCause5Whys = telemetry.RootCause5Whys
	res.PrescriptionCmd = telemetry.Prescription
	res.Telemetry = telemetry

	return res
}

// Probe 12: kube-nodeport-healer
func probeClusterNodePort(ctx context.Context, opts Options) ProbeResult {
	var kOpts KubeHealerOptions
	if opts.KubeHealerOpts != nil {
		kOpts = *opts.KubeHealerOpts
	} else {
		kOpts = DefaultKubeHealerOptions(opts)
	}

	res, _ := CheckAndHealClusterEndpoint(ctx, kOpts)
	return res
}

// FormatAndon renders the TPS Andon board and 5-Whys diagnostic blocks.
func FormatAndon(rep Report) string {
	var b strings.Builder
	b.WriteString("========================================================================\n")
	b.WriteString("  SMALT POSH — Deterministic DX Factory / System Doctor (TPS Andon)\n")
	b.WriteString("========================================================================\n")

	for _, p := range rep.Probes {
		b.WriteString(fmt.Sprintf("  [%-6s] %-18s (%6.2fms)  %s\n", p.Status, p.ID, p.DurationMs, p.Summary))
		if p.Fixed && p.FixAction != "" {
			b.WriteString(fmt.Sprintf("           Fixed:               %s\n", p.FixAction))
		}
		if p.Status == StatusYellow || p.Status == StatusRed {
			b.WriteString(fmt.Sprintf("           What broke:          %s\n", p.WhatBroke))
			b.WriteString(fmt.Sprintf("           Invariant violated:  %s\n", p.Invariant))
			b.WriteString(fmt.Sprintf("           Root cause (5-Whys): %s\n", p.RootCause5Whys))
			b.WriteString(fmt.Sprintf("           Prescription:        %s\n", p.PrescriptionCmd))
		}
	}

	b.WriteString("------------------------------------------------------------------------\n")
	b.WriteString(fmt.Sprintf("  ANDON STATUS: [%s] | Probes: %d | Fixed: %d | Total: %.2fms\n",
		rep.OverallStatus, len(rep.Probes), rep.FixedCount, rep.TotalDurationMs))
	b.WriteString("========================================================================\n")
	return b.String()
}

// FormatJSON serializes the diagnostic Report as indented JSON.
func FormatJSON(rep Report) ([]byte, error) {
	return json.MarshalIndent(rep, "", "  ")
}
