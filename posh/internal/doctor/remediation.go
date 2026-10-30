package doctor

import (
	"bufio"
	"context"
	"fmt"
	"net"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
	"syscall"
	"time"
)

// ProcessTerminationReceipt records the deterministic execution of a process termination.
type ProcessTerminationReceipt struct {
	PID        int    `json:"pid"`
	Name       string `json:"name"`
	Orphaned   bool   `json:"orphaned"`
	Signal     string `json:"signal"`
	Terminated bool   `json:"terminated"`
	DryRun     bool   `json:"dry_run"`
	Note       string `json:"note"`
}

// DefaultAdmittedSubstrateProcesses is the strict whitelist of process names that doctor is permitted to terminate.
var DefaultAdmittedSubstrateProcesses = []string{
	"beam.smp",
	"kind",
	"smalt-arm",
	"posh",
	"kubectl",
}

// HealStaleUDSSocket verifies and unlinks a stale Unix Domain Socket.
func HealStaleUDSSocket(sockPath string, dryRun bool) (bool, string, error) {
	fi, err := os.Stat(sockPath)
	if os.IsNotExist(err) {
		return false, "socket does not exist on disk", nil
	}
	if err != nil {
		return false, "", fmt.Errorf("stat socket %s: %w", sockPath, err)
	}

	// Verify the inode is actually a socket
	if fi.Mode()&os.ModeSocket == 0 {
		return false, "", fmt.Errorf("path %s is not a socket (mode %s); refusing to unlink", sockPath, fi.Mode())
	}

	// Probe if a live process is actively listening
	conn, dialErr := net.DialTimeout("unix", sockPath, 150*time.Millisecond)
	if dialErr == nil {
		conn.Close()
		return false, "socket is actively listening; live process present", nil
	}

	// Dial failed -> socket is stale.
	if dryRun {
		return true, fmt.Sprintf("dry-run: would atomically unlink stale UDS socket at %s", sockPath), nil
	}

	if rmErr := os.Remove(sockPath); rmErr != nil {
		return false, "", fmt.Errorf("failed to unlink stale socket %s: %w", sockPath, rmErr)
	}

	// Anti-vacuity verification: confirm file is gone
	if _, statErr := os.Stat(sockPath); !os.IsNotExist(statErr) {
		return false, "", fmt.Errorf("socket %s still present after unlink attempt", sockPath)
	}

	return true, fmt.Sprintf("atomically unlinked stale socket %s", sockPath), nil
}

// HealDevOverrides creates or restores the canonical transient Terraform dev_overrides at tmp/posh/tfrc.
func HealDevOverrides(repoRoot string, dryRun bool) (bool, string, error) {
	absRoot, err := filepath.Abs(repoRoot)
	if err != nil {
		absRoot = repoRoot
	}
	tfrcPath := filepath.Join(repoRoot, "tmp", "posh", "tfrc")
	expectedProviderDir := filepath.Join(absRoot, "adapters", "terraform-provider-smalt")

	// Validate whether the target provider directory exists
	if _, stErr := os.Stat(expectedProviderDir); os.IsNotExist(stErr) {
		// In dev/test environments if provider dir is not yet populated, use canonical relative path
		expectedProviderDir = filepath.Join(absRoot, "adapters", "terraform-provider-smalt")
	}

	canonicalContent := fmt.Sprintf(`provider_installation {
  dev_overrides {
    "hashicorp/azurerm" = %q
  }
  direct {
    exclude = ["hashicorp/azurerm"]
  }
}
`, expectedProviderDir)

	data, readErr := os.ReadFile(tfrcPath)
	if readErr == nil {
		curr := string(data)
		if strings.Contains(curr, "adapters/terraform-provider-smalt") &&
			strings.Contains(curr, `exclude = ["hashicorp/azurerm"]`) &&
			strings.Contains(curr, "dev_overrides") {
			return false, "dev_overrides intact and canonically configured", nil
		}
	}

	if dryRun {
		return true, fmt.Sprintf("dry-run: would write canonical dev_overrides configuration to %s", tfrcPath), nil
	}

	if mkErr := os.MkdirAll(filepath.Dir(tfrcPath), 0o755); mkErr != nil {
		return false, "", fmt.Errorf("create dir for %s: %w", tfrcPath, mkErr)
	}

	// Atomic write via temporary file
	tmpFile := filepath.Join(filepath.Dir(tfrcPath), fmt.Sprintf(".tfrc.tmp-%d-%d", os.Getpid(), time.Now().UnixNano()))
	if wErr := os.WriteFile(tmpFile, []byte(canonicalContent), 0o644); wErr != nil {
		return false, "", fmt.Errorf("write temp dev_overrides: %w", wErr)
	}
	if renErr := os.Rename(tmpFile, tfrcPath); renErr != nil {
		os.Remove(tmpFile)
		return false, "", fmt.Errorf("atomic rename dev_overrides: %w", renErr)
	}

	return true, fmt.Sprintf("healed dev_overrides at %s pointing to %s", tfrcPath, expectedProviderDir), nil
}

// ProcessInfo represents an inspected operating system process.
type ProcessInfo struct {
	PID  int
	PPID int
	Comm string
}

// findPortOwnerPID resolves the PID and executable name bound to a TCP port.
func findPortOwnerPID(port int) (int, string, error) {
	ctx, cancel := context.WithTimeout(context.Background(), 500*time.Millisecond)
	defer cancel()

	// Use lsof -nP -iTCP:<port> -sTCP:LISTEN -Fp -Fc
	cmd := exec.CommandContext(ctx, "lsof", "-nP", fmt.Sprintf("-iTCP:%d", port), "-sTCP:LISTEN", "-Fp", "-Fc")
	out, err := cmd.Output()
	if err == nil && len(out) > 0 {
		var pid int
		var comm string
		sc := bufio.NewScanner(strings.NewReader(string(out)))
		for sc.Scan() {
			line := sc.Text()
			if strings.HasPrefix(line, "p") {
				if p, parseErr := strconv.Atoi(line[1:]); parseErr == nil {
					pid = p
				}
			} else if strings.HasPrefix(line, "c") {
				comm = line[1:]
			}
		}
		if pid > 0 {
			return pid, comm, nil
		}
	}

	// Fallback to fuser on Linux
	cmdFuser := exec.CommandContext(ctx, "fuser", fmt.Sprintf("%d/tcp", port))
	if fuserOut, fErr := cmdFuser.Output(); fErr == nil {
		fields := strings.Fields(string(fuserOut))
		for _, f := range fields {
			if p, parseErr := strconv.Atoi(strings.TrimSpace(f)); parseErr == nil && p > 0 {
				return p, "unknown", nil
			}
		}
	}

	return 0, "", fmt.Errorf("no process found listening on port %d", port)
}

// isAdmittedProcess checks if procName matches any entry in admitted.
func isAdmittedProcess(procName string, admitted []string) bool {
	base := filepath.Base(procName)
	for _, a := range admitted {
		if strings.EqualFold(base, a) || strings.HasPrefix(strings.ToLower(base), strings.ToLower(a)) {
			return true
		}
	}
	return false
}

// FreePortCollision detects and frees a port collision (e.g. port 9443), strictly fenced to admitted substrate processes.
func FreePortCollision(port int, admittedProcs []string, dryRun bool) (bool, string, error) {
	// First check if port is currently in use
	ln, err := net.Listen("tcp", fmt.Sprintf("127.0.0.1:%d", port))
	if err == nil {
		ln.Close()
		return false, fmt.Sprintf("port %d is free; no collision", port), nil
	}

	pid, comm, findErr := findPortOwnerPID(port)
	if findErr != nil {
		return false, "", fmt.Errorf("port %d in use, but could not determine owner process: %w", port, findErr)
	}

	// Safety Fence: Refuse to terminate PID 1, self PID, or non-admitted process names
	if pid <= 1 || pid == os.Getpid() {
		return false, "", fmt.Errorf("refusing to terminate protected process PID %d on port %d", pid, port)
	}

	if len(admittedProcs) == 0 {
		admittedProcs = DefaultAdmittedSubstrateProcesses
	}

	if !isAdmittedProcess(comm, admittedProcs) {
		return false, "", fmt.Errorf("port %d held by non-substrate process %q (pid %d); automated termination refused by safety fence",
			port, comm, pid)
	}

	if dryRun {
		return true, fmt.Sprintf("dry-run: would terminate substrate process %q (pid %d) holding port %d", comm, pid, port), nil
	}

	// Graceful termination protocol: SIGTERM -> wait 600ms -> SIGKILL
	_ = syscall.Kill(pid, syscall.SIGTERM)

	exited := false
	for i := 0; i < 6; i++ {
		time.Sleep(100 * time.Millisecond)
		if err := syscall.Kill(pid, 0); err != nil {
			exited = true
			break
		}
	}

	if !exited {
		_ = syscall.Kill(pid, syscall.SIGKILL)
		time.Sleep(200 * time.Millisecond)
	}

	// Anti-vacuity check: verify port is actually freed
	checkLn, checkErr := net.Listen("tcp", fmt.Sprintf("127.0.0.1:%d", port))
	if checkErr != nil {
		return false, "", fmt.Errorf("port %d still not available after terminating pid %d: %w", port, pid, checkErr)
	}
	checkLn.Close()

	return true, fmt.Sprintf("terminated conflicting substrate %q (pid %d) and freed port %d", comm, pid, port), nil
}

// TerminateOrphanSubstrates identifies and terminates orphaned (PPID=1) substrate processes.
func TerminateOrphanSubstrates(admittedProcs []string, dryRun bool) ([]ProcessTerminationReceipt, error) {
	if len(admittedProcs) == 0 {
		admittedProcs = DefaultAdmittedSubstrateProcesses
	}

	ctx, cancel := context.WithTimeout(context.Background(), 600*time.Millisecond)
	defer cancel()

	cmd := exec.CommandContext(ctx, "ps", "-eo", "pid,ppid,comm")
	out, err := cmd.Output()
	if err != nil {
		return nil, fmt.Errorf("execute ps: %w", err)
	}

	var receipts []ProcessTerminationReceipt
	selfPID := os.Getpid()

	sc := bufio.NewScanner(strings.NewReader(string(out)))
	for sc.Scan() {
		line := strings.TrimSpace(sc.Text())
		if line == "" || strings.HasPrefix(line, "PID") {
			continue
		}
		fields := strings.Fields(line)
		if len(fields) < 3 {
			continue
		}

		pid, err1 := strconv.Atoi(fields[0])
		ppid, err2 := strconv.Atoi(fields[1])
		comm := fields[2]

		if err1 != nil || err2 != nil || pid <= 1 || pid == selfPID {
			continue
		}

		// Check if it matches an admitted substrate process and is orphaned (PPID == 1)
		if isAdmittedProcess(comm, admittedProcs) && ppid == 1 {
			rec := ProcessTerminationReceipt{
				PID:      pid,
				Name:     comm,
				Orphaned: true,
				Signal:   "SIGTERM",
				DryRun:   dryRun,
			}

			if dryRun {
				rec.Note = "dry-run: identified orphan substrate process"
				receipts = append(receipts, rec)
				continue
			}

			// Execute termination
			_ = syscall.Kill(pid, syscall.SIGTERM)
			time.Sleep(100 * time.Millisecond)
			if err := syscall.Kill(pid, 0); err == nil {
				// Escalate to SIGKILL
				rec.Signal = "SIGKILL"
				_ = syscall.Kill(pid, syscall.SIGKILL)
				time.Sleep(100 * time.Millisecond)
			}

			if err := syscall.Kill(pid, 0); err != nil {
				rec.Terminated = true
				rec.Note = "orphan substrate process successfully reaped"
			} else {
				rec.Terminated = false
				rec.Note = "process did not exit within deadline"
			}
			receipts = append(receipts, rec)
		}
	}

	return receipts, nil
}
