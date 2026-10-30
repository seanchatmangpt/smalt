package doctor

import (
	"bufio"
	"fmt"
	"net"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"syscall"
	"time"

	"smalt.dev/posh/internal/config"
)

// SocketBufferTelemetry captures kernel UDS queue depth and capacity telemetry.
type SocketBufferTelemetry struct {
	RcvBufBytes   int     `json:"rcv_buf_bytes"`
	SndBufBytes   int     `json:"snd_buf_bytes"`
	RcvQueueDepth int     `json:"rcv_queue_depth"`
	SndQueueDepth int     `json:"snd_queue_depth"`
	BloatRatio    float64 `json:"bloat_ratio"`
	Status        string  `json:"status"`
	Note          string  `json:"note,omitempty"`
}

// FDTelemetry captures OS file descriptor limits and current allocation pressure.
type FDTelemetry struct {
	OpenFDs    uint64  `json:"open_fds"`
	SoftLimit  uint64  `json:"soft_limit"`
	HardLimit  uint64  `json:"hard_limit"`
	UsageRatio float64 `json:"usage_ratio"`
	Status     string  `json:"status"`
	Note       string  `json:"note,omitempty"`
}

// CGroupV2Telemetry captures cgroup v2 memory and CPU throttling telemetry.
type CGroupV2Telemetry struct {
	Mounted        bool    `json:"mounted"`
	MemoryCurrent  uint64  `json:"memory_current,omitempty"`
	MemoryHigh     uint64  `json:"memory_high,omitempty"`
	MemoryMax      uint64  `json:"memory_max,omitempty"`
	MemoryRatio    float64 `json:"memory_ratio,omitempty"`
	CPUPeriods     uint64  `json:"cpu_periods,omitempty"`
	CPUThrottled   uint64  `json:"cpu_throttled,omitempty"`
	ThrottledUsec  uint64  `json:"throttled_usec,omitempty"`
	ThrottledRatio float64 `json:"throttled_ratio,omitempty"`
	Status         string  `json:"status"`
	Note           string  `json:"note,omitempty"`
}

// InspectSocketBuffers extracts kernel socket buffer capacities and queue depth via getsockopt/ioctl.
func InspectSocketBuffers(c net.Conn) (SocketBufferTelemetry, error) {
	uc, ok := c.(*net.UnixConn)
	if !ok {
		return SocketBufferTelemetry{}, fmt.Errorf("expected *net.UnixConn, got %T", c)
	}
	rc, err := uc.SyscallConn()
	if err != nil {
		return SocketBufferTelemetry{}, fmt.Errorf("SyscallConn: %w", err)
	}

	var rcv, snd, rDepth, sDepth int
	var sockErr error
	ctrlErr := rc.Control(func(fd uintptr) {
		rcv, snd, rDepth, sDepth, sockErr = getSocketBufferStats(fd)
	})
	if ctrlErr != nil {
		return SocketBufferTelemetry{}, ctrlErr
	}
	if sockErr != nil {
		return SocketBufferTelemetry{}, sockErr
	}

	bloat := 0.0
	if rcv > 0 {
		bloat = float64(rDepth) / float64(rcv)
	}

	status := StatusGreen
	note := "buffer queue within safe bounds"
	if bloat >= 0.90 {
		status = StatusRed
		note = fmt.Sprintf("CRITICAL buffer bloat: receive queue depth %d bytes near %d buffer capacity (%.1f%%)", rDepth, rcv, bloat*100)
	} else if bloat >= 0.70 {
		status = StatusYellow
		note = fmt.Sprintf("WARNING buffer bloat: receive queue depth %d bytes approaching %d buffer capacity (%.1f%%)", rDepth, rcv, bloat*100)
	}

	return SocketBufferTelemetry{
		RcvBufBytes:   rcv,
		SndBufBytes:   snd,
		RcvQueueDepth: rDepth,
		SndQueueDepth: sDepth,
		BloatRatio:    bloat,
		Status:        status,
		Note:          note,
	}, nil
}

// InspectFileDescriptors inspects rlimit_nofile against actual open file descriptors.
func InspectFileDescriptors() (FDTelemetry, error) {
	var rlim syscall.Rlimit
	if err := syscall.Getrlimit(syscall.RLIMIT_NOFILE, &rlim); err != nil {
		return FDTelemetry{}, fmt.Errorf("getrlimit(RLIMIT_NOFILE): %w", err)
	}

	openFDs, err := countOpenFileDescriptors()
	if err != nil {
		return FDTelemetry{}, fmt.Errorf("countOpenFileDescriptors: %w", err)
	}

	soft := uint64(rlim.Cur)
	hard := uint64(rlim.Max)
	usageRatio := 0.0
	if soft > 0 {
		usageRatio = float64(openFDs) / float64(soft)
	}

	status := StatusGreen
	note := fmt.Sprintf("%d/%d FDs in use (%.1f%% of soft limit)", openFDs, soft, usageRatio*100)
	if usageRatio >= 0.85 {
		status = StatusRed
		note = fmt.Sprintf("CRITICAL FD pressure: %d/%d FDs allocated (%.1f%% of soft limit)", openFDs, soft, usageRatio*100)
	} else if usageRatio >= 0.70 {
		status = StatusYellow
		note = fmt.Sprintf("WARNING elevated FD pressure: %d/%d FDs allocated (%.1f%% of soft limit)", openFDs, soft, usageRatio*100)
	}

	return FDTelemetry{
		OpenFDs:    openFDs,
		SoftLimit:  soft,
		HardLimit:  hard,
		UsageRatio: usageRatio,
		Status:     status,
		Note:       note,
	}, nil
}

// InspectCGroupV2 inspects cgroup v2 memory and CPU throttling metrics under cgroupRoot.
func InspectCGroupV2(cgroupRoot string) (*CGroupV2Telemetry, error) {
	if cgroupRoot == "" {
		cgroupRoot = "/sys/fs/cgroup"
	}

	// Verify cgroup root presence
	st, err := os.Stat(cgroupRoot)
	if err != nil || !st.IsDir() {
		return &CGroupV2Telemetry{
			Mounted: false,
			Status:  StatusGreen,
			Note:    "cgroup v2 not mounted (host/darwin platform)",
		}, nil
	}

	memCurPath := filepath.Join(cgroupRoot, "memory.current")
	if _, err := os.Stat(memCurPath); os.IsNotExist(err) {
		return &CGroupV2Telemetry{
			Mounted: false,
			Status:  StatusGreen,
			Note:    "cgroup v2 controllers absent (host/darwin platform)",
		}, nil
	}

	res := &CGroupV2Telemetry{
		Mounted: true,
		Status:  StatusGreen,
	}

	// 1. Read memory.current
	if b, err := os.ReadFile(memCurPath); err == nil {
		if val, err := strconv.ParseUint(strings.TrimSpace(string(b)), 10, 64); err == nil {
			res.MemoryCurrent = val
		}
	}

	// 2. Read memory.high
	if b, err := os.ReadFile(filepath.Join(cgroupRoot, "memory.high")); err == nil {
		text := strings.TrimSpace(string(b))
		if text != "max" {
			if val, err := strconv.ParseUint(text, 10, 64); err == nil {
				res.MemoryHigh = val
			}
		}
	}

	// 3. Read memory.max
	if b, err := os.ReadFile(filepath.Join(cgroupRoot, "memory.max")); err == nil {
		text := strings.TrimSpace(string(b))
		if text != "max" {
			if val, err := strconv.ParseUint(text, 10, 64); err == nil {
				res.MemoryMax = val
			}
		}
	}

	if res.MemoryHigh > 0 && res.MemoryCurrent > 0 {
		res.MemoryRatio = float64(res.MemoryCurrent) / float64(res.MemoryHigh)
	}

	// 4. Read cpu.stat
	if b, err := os.ReadFile(filepath.Join(cgroupRoot, "cpu.stat")); err == nil {
		sc := bufio.NewScanner(strings.NewReader(string(b)))
		for sc.Scan() {
			fields := strings.Fields(sc.Text())
			if len(fields) == 2 {
				switch fields[0] {
				case "nr_periods":
					res.CPUPeriods, _ = strconv.ParseUint(fields[1], 10, 64)
				case "nr_throttled":
					res.CPUThrottled, _ = strconv.ParseUint(fields[1], 10, 64)
				case "throttled_usec":
					res.ThrottledUsec, _ = strconv.ParseUint(fields[1], 10, 64)
				}
			}
		}
	}

	if res.CPUPeriods > 0 {
		res.ThrottledRatio = float64(res.CPUThrottled) / float64(res.CPUPeriods)
	}

	// Compute status
	if res.ThrottledRatio > 0.30 || res.MemoryRatio > 0.95 {
		res.Status = StatusRed
		res.Note = fmt.Sprintf("CRITICAL cgroup throttling: cpu_throttled=%.1f%%, mem_usage=%.1f%%",
			res.ThrottledRatio*100, res.MemoryRatio*100)
	} else if res.ThrottledRatio > 0.10 || res.MemoryRatio > 0.85 {
		res.Status = StatusYellow
		res.Note = fmt.Sprintf("WARNING elevated cgroup pressure: cpu_throttled=%.1f%%, mem_usage=%.1f%%",
			res.ThrottledRatio*100, res.MemoryRatio*100)
	} else {
		res.Note = "cgroup v2 resources within nominal limits"
	}

	return res, nil
}

// probeSocketBufferBacklog inspects kernel socket buffers and backlog bloat.
func probeSocketBufferBacklog(opts Options, cfg *config.Config) ProbeResult {
	t0 := time.Now()
	res := ProbeResult{
		ID:        "socket-buffer-bloat",
		Invariant: "POSH-008 Bounded Kernel Socket Buffers",
	}

	sockPath := filepath.Join(opts.RepoRoot, "posh", "run", "posh.sock")
	if cfg != nil && cfg.Socket != "" {
		sockPath = cfg.Socket
	}

	// Dial socket if live, otherwise create ephemeral loopback socket pair for probing kernel buffers
	conn, err := net.DialTimeout("unix", sockPath, 150*time.Millisecond)
	if err != nil {
		// Membrane not running: perform probe on temporary socket pair to verify OS kernel buffer sizing
		tmpDir := os.TempDir()
		probeSock := filepath.Join(tmpDir, fmt.Sprintf("posh-bufprobe-%d-%d.sock", os.Getpid(), time.Now().UnixNano()))
		ln, lnErr := net.Listen("unix", probeSock)
		if lnErr != nil {
			res.Status = StatusYellow
			res.Summary = "kernel socket buffer probe skipped (listener offline, temp bind failed)"
			res.DurationMs = msSince(t0)
			return res
		}
		defer func() {
			ln.Close()
			os.Remove(probeSock)
		}()

		dialedCh := make(chan net.Conn, 1)
		go func() {
			c, dErr := net.DialTimeout("unix", probeSock, 200*time.Millisecond)
			if dErr == nil {
				dialedCh <- c
			} else {
				dialedCh <- nil
			}
		}()

		srvConn, aErr := ln.Accept()
		clientConn := <-dialedCh
		if aErr != nil || clientConn == nil {
			if srvConn != nil {
				srvConn.Close()
			}
			if clientConn != nil {
				clientConn.Close()
			}
			res.Status = StatusYellow
			res.Summary = "kernel socket buffer probe skipped (loopback pair failed)"
			res.DurationMs = msSince(t0)
			return res
		}
		defer clientConn.Close()
		defer srvConn.Close()
		conn = srvConn
	} else {
		defer conn.Close()
	}

	tel, inspectErr := InspectSocketBuffers(conn)
	res.DurationMs = msSince(t0)
	if inspectErr != nil {
		res.Status = StatusYellow
		res.Summary = fmt.Sprintf("getsockopt/ioctl buffer inspection failed: %v", inspectErr)
		res.WhatBroke = inspectErr.Error()
		res.RootCause5Whys = "Kernel rejected getsockopt or ioctl inspection on Unix Domain Socket descriptor."
		res.PrescriptionCmd = "posh doctor"
		return res
	}

	res.Telemetry = tel
	res.Status = tel.Status
	res.Summary = fmt.Sprintf("rcvbuf=%d bytes, sndbuf=%d bytes, queue_depth=%d (bloat=%.2f%%)",
		tel.RcvBufBytes, tel.SndBufBytes, tel.RcvQueueDepth, tel.BloatRatio*100)

	if tel.Status == StatusRed {
		res.WhatBroke = fmt.Sprintf("UDS receive queue backlog bloat is %.1f%%, exceeding 90%% critical threshold", tel.BloatRatio*100)
		res.RootCause5Whys = "Membrane consumer process is blocked, starved of CPU cycles, or experiencing lock contention while upstream BEAM producer continuously streams requests without backpressure."
		res.PrescriptionCmd = "posh doctor --fix  # check for hung processes or restart membrane with 'just posh-restart'"
	} else if tel.Status == StatusYellow {
		res.WhatBroke = fmt.Sprintf("UDS receive queue backlog bloat is %.1f%%, exceeding 70%% advisory threshold", tel.BloatRatio*100)
		res.RootCause5Whys = "Incoming request throughput temporarily exceeds membrane dispatch capacity; socket buffer accumulation detected."
		res.PrescriptionCmd = "posh doctor"
	}

	return res
}

// probeFileDescriptorPressure inspects rlimit_nofile and open file descriptors.
func probeFileDescriptorPressure() ProbeResult {
	t0 := time.Now()
	res := ProbeResult{
		ID:        "file-descriptor-table",
		Invariant: "TPS-POKA-YOKE FD Leakage Prevention",
	}

	tel, err := InspectFileDescriptors()
	res.DurationMs = msSince(t0)
	if err != nil {
		res.Status = StatusYellow
		res.Summary = fmt.Sprintf("FD table inspection unavailable: %v", err)
		res.WhatBroke = err.Error()
		res.RootCause5Whys = "Operating system prevented reading file descriptor directory (/dev/fd or /proc/self/fd) or querying getrlimit(2)."
		res.PrescriptionCmd = "ulimit -n"
		return res
	}

	res.Telemetry = tel
	res.Status = tel.Status
	res.Summary = tel.Note

	if tel.Status == StatusRed {
		res.WhatBroke = fmt.Sprintf("Process open file descriptors (%d) reached %.1f%% of soft limit (%d)", tel.OpenFDs, tel.UsageRatio*100, tel.SoftLimit)
		res.RootCause5Whys = "File descriptor leak detected in adapter, HTTP client connections unclosed, or ulimit is configured excessively low, risking imminent EMFILE crashes."
		res.PrescriptionCmd = "ulimit -n 4096  # or inspect lsof -p $(pgrep posh)"
	} else if tel.Status == StatusYellow {
		res.WhatBroke = fmt.Sprintf("Process open file descriptors (%d) reached %.1f%% of soft limit (%d)", tel.OpenFDs, tel.UsageRatio*100, tel.SoftLimit)
		res.RootCause5Whys = "File descriptor consumption elevated above 70% threshold; connection pooling or file handle reuse should be inspected."
		res.PrescriptionCmd = "posh doctor"
	}

	return res
}

// probeCGroupThrottling inspects cgroup v2 memory and CPU limits.
func probeCGroupThrottling(opts Options) ProbeResult {
	t0 := time.Now()
	res := ProbeResult{
		ID:        "cgroup-throttling",
		Invariant: "TPS-HEIJUNKA CGroup v2 Resource Headroom",
	}

	cgroupRoot := ""
	if opts.RepoRoot != "" {
		// Allow fixture override in tests
		cand := filepath.Join(opts.RepoRoot, "testdata", "cgroup")
		if st, err := os.Stat(cand); err == nil && st.IsDir() {
			cgroupRoot = cand
		}
	}

	tel, err := InspectCGroupV2(cgroupRoot)
	res.DurationMs = msSince(t0)
	if err != nil {
		res.Status = StatusYellow
		res.Summary = fmt.Sprintf("cgroup v2 inspection error: %v", err)
		res.WhatBroke = err.Error()
		res.RootCause5Whys = "Failed reading cgroup v2 controller interface files."
		res.PrescriptionCmd = "cat /sys/fs/cgroup/cgroup.controllers"
		return res
	}

	res.Telemetry = tel
	res.Status = tel.Status
	if !tel.Mounted {
		res.Summary = tel.Note
		return res
	}

	res.Summary = fmt.Sprintf("cpu_throttled=%.2f%%, mem_current=%d bytes (mem_high=%d)",
		tel.ThrottledRatio*100, tel.MemoryCurrent, tel.MemoryHigh)

	if tel.Status == StatusRed {
		res.WhatBroke = fmt.Sprintf("Container CPU throttling (%.1f%%) or memory usage (%.1f%%) breached critical threshold",
			tel.ThrottledRatio*100, tel.MemoryRatio*100)
		res.RootCause5Whys = "Kubernetes or Docker CPU quota is undersized for current adapter load, causing CFS scheduler throttling and latency spikes breaching SLA."
		res.PrescriptionCmd = "kubectl edit deployment posh-sidecar  # increase cpu.limits and memory.limits"
	} else if tel.Status == StatusYellow {
		res.WhatBroke = fmt.Sprintf("Container CPU throttling (%.1f%%) or memory usage (%.1f%%) elevated",
			tel.ThrottledRatio*100, tel.MemoryRatio*100)
		res.RootCause5Whys = "Sidecar container is experiencing periodic CPU quota exhaustion or memory pressure near memory.high threshold."
		res.PrescriptionCmd = "kubectl top pod"
	}

	return res
}
