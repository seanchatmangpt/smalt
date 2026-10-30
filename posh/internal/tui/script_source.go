package tui

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"os/exec"
	"strings"
	"sync"
	"time"
)

// ScriptStatusSource consumes the membrane-owned status surfaces —
// scripts/posh_status.sh --json (typed section verdicts) and
// scripts/dx_report.py --json (SPC rows) — via read-only exec.
//
// The scripts are report-only by contract (posh_status.sh header: "Report-only:
// never builds, never applies"; dx_report.py: "Exit 0 always"), so exec cannot
// mutate membrane state; routing reads through the supervisor UDS would be
// unlawful under the stateless law (gap 07 ruling).
//
// Timestamp-gated throttling (no-sleep doctrine): posh_status.sh at most once
// per 10s (kubectl + gates make it ~5-20s), dx_report.py once per 3s. On exec
// failure the last good snapshot is kept; fields render absent/UNKNOWN — never
// a synthesized default GREEN.
type ScriptStatusSource struct {
	StatusScript string
	DxReport     string

	MinInterval time.Duration
	DxInterval  time.Duration

	mu           sync.Mutex
	lastStatus   time.Time
	lastDx       time.Time
	lastSections []PoshSection
	lastDxRows   []DxRow
	lastErr      error
}

// ScriptNotFoundError reports that a configured status script could not be
// execed (missing, non-executable, or unexpected exit).
type ScriptNotFoundError struct {
	Path string
	Err  error
}

func (e *ScriptNotFoundError) Error() string {
	return fmt.Sprintf("status script %q not usable: %v", e.Path, e.Err)
}

func (e *ScriptNotFoundError) Unwrap() error { return e.Err }

// NewScriptStatusSource builds a source over the given repo-root-relative
// script paths, resolving candidates at construction time.
func NewScriptStatusSource(statusScript, dxReport string) *ScriptStatusSource {
	return &ScriptStatusSource{
		StatusScript: resolveScriptPath(statusScript),
		DxReport:     resolveScriptPath(dxReport),
		MinInterval:  10 * time.Second,
		DxInterval:   3 * time.Second,
	}
}

// resolveScriptPath returns the first existing candidate for a repo-root
// relative script path: as-given, then ../-prefixed (posh/ cwd), then
// SMALT_ROOT-relative when the env var is set.
func resolveScriptPath(p string) string {
	candidates := []string{p, "../" + p}
	if root := os.Getenv("SMALT_ROOT"); root != "" {
		candidates = append(candidates, root+"/"+p)
	}
	for _, c := range candidates {
		if st, err := os.Stat(c); err == nil && !st.IsDir() {
			return c
		}
	}
	return p
}

// LastError surfaces the most recent exec/parse failure for loud rendering.
func (s *ScriptStatusSource) LastError() error {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.lastErr
}

// Snapshot runs (throttled) the report-only scripts and merges their parsed
// output into a snapshot. Exec or parse failure keeps the last good data and is
// recorded via LastError — no telemetry value is ever synthesized.
func (s *ScriptStatusSource) Snapshot(ctx context.Context) TelemetrySnapshot {
	now := time.Now()
	s.mu.Lock()
	defer s.mu.Unlock()

	snap := TelemetrySnapshot{}
	runStatus := now.Sub(s.lastStatus) > s.MinInterval
	runDx := now.Sub(s.lastDx) > s.DxInterval

	if runStatus && s.StatusScript != "" {
		sections, overall, err := runPoshStatus(ctx, s.StatusScript)
		if err != nil {
			s.lastErr = err
			// keep last good sections; no fabricated verdicts
		} else {
			s.lastSections = sections
			s.lastStatus = now
			s.lastErr = nil
			snap.AndonStatus = overall
		}
	}
	if snap.AndonStatus == "" {
		snap.AndonStatus = andonFromSections(s.lastSections)
	}

	if runDx && s.DxReport != "" {
		rows, err := runDxReport(ctx, s.DxReport)
		if err != nil {
			s.lastErr = err
		} else {
			s.lastDxRows = rows
			s.lastDx = now
		}
	}
	snap.PoshSections = s.lastSections
	snap.DxRows = s.lastDxRows
	return snap
}

// andonFromSections returns the script's own OVERALL verdict, or "" when no
// good snapshot exists (rendered UNKNOWN; never fabricated).
func andonFromSections(sections []PoshSection) string {
	for _, sec := range sections {
		if sec.Section == "OVERALL" {
			return sec.Verdict
		}
	}
	return ""
}

// runPoshStatus execs `bash <script> --json` and parses the JSON lines. The
// script's exit contract (0 / 2) is honored: exit 2 still parses its output
// (RED overall) and is not an error.
func runPoshStatus(ctx context.Context, path string) ([]PoshSection, string, error) {
	cmd := exec.CommandContext(ctx, "bash", path, "--json")
	var stderr strings.Builder
	cmd.Stderr = &stderr
	out, err := cmd.Output()
	if err != nil && !isExitCode(err, 2) {
		return nil, "", &ScriptNotFoundError{Path: path, Err: fmt.Errorf("exec: %w (stderr: %s)", err, strings.TrimSpace(stderr.String()))}
	}
	sections, overall, perr := parsePoshStatusJSON(out)
	if perr != nil {
		return nil, "", fmt.Errorf("parse %s --json: %w", path, perr)
	}
	return sections, overall, nil
}

// runDxReport execs `python3 <script> --json` and parses the rows payload.
func runDxReport(ctx context.Context, path string) ([]DxRow, error) {
	cmd := exec.CommandContext(ctx, "python3", path, "--json")
	var stderr strings.Builder
	cmd.Stderr = &stderr
	out, err := cmd.Output()
	if err != nil {
		return nil, fmt.Errorf("exec %s --json: %w (stderr: %s)", path, err, strings.TrimSpace(stderr.String()))
	}
	rows, perr := parseDxJSON(out)
	if perr != nil {
		return nil, fmt.Errorf("parse %s --json: %w", path, perr)
	}
	return rows, nil
}

func isExitCode(err error, code int) bool {
	var ee *exec.ExitError
	if errors.As(err, &ee) {
		return ee.ExitCode() == code
	}
	return false
}

// parsePoshStatusJSON parses the per-line JSON emitted by posh_status.sh
// --json. A malformed line is a typed error, never a default verdict.
func parsePoshStatusJSON(data []byte) ([]PoshSection, string, error) {
	if len(bytes.TrimSpace(data)) == 0 {
		return nil, "", errors.New("posh_status: empty payload")
	}
	var sections []PoshSection
	overall := ""
	for i, line := range strings.Split(string(data), "\n") {
		line = strings.TrimSpace(line)
		if line == "" {
			continue
		}
		var sec PoshSection
		if err := json.Unmarshal([]byte(line), &sec); err != nil {
			return nil, "", fmt.Errorf("line %d: %w", i+1, err)
		}
		if sec.Section == "" {
			return nil, "", fmt.Errorf("line %d: section field empty", i+1)
		}
		if sec.Section == "OVERALL" {
			overall = sec.Verdict
		}
		sections = append(sections, sec)
	}
	return sections, overall, nil
}

// parseDxJSON parses dx_report.py --json output: {"rows":[...],"no_data":bool}.
// Empty or whitespace-only input is a typed error, never an empty pass.
func parseDxJSON(data []byte) ([]DxRow, error) {
	trimmed := bytes.TrimSpace(data)
	if len(trimmed) == 0 {
		return nil, errors.New("dx report: empty payload")
	}
	var payload struct {
		Rows   []DxRow `json:"rows"`
		NoData bool    `json:"no_data"`
	}
	if err := json.Unmarshal(trimmed, &payload); err != nil {
		return nil, fmt.Errorf("dx report payload: %w", err)
	}
	return payload.Rows, nil
}
