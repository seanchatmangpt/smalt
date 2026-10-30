package tui

import (
	"context"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"smalt.dev/posh/internal/doctor"
)

// scriptPresence skips loudly when the report-only scripts are not on disk —
// a skip is never a fake pass.
func requireScript(t *testing.T, path string) {
	t.Helper()
	st, err := os.Stat(path)
	if err != nil || st.IsDir() {
		t.Skipf("report-only script not present: %s", path)
	}
}

func repoScript(t *testing.T, name string) string {
	t.Helper()
	// tests run in posh/internal/tui; repo root is three levels up
	p := filepath.Join("..", "..", "..", "scripts", name)
	requireScript(t, p)
	abs, err := filepath.Abs(p)
	if err != nil {
		t.Fatalf("abs: %v", err)
	}
	return abs
}

// TestParsePoshStatusJSON_FixtureFromRealRun pins the parser against a fixture
// recorded from a real `bash scripts/posh_status.sh --json` run (CC-GM1-3).
func TestParsePoshStatusJSON_FixtureFromRealRun(t *testing.T) {
	fixture := strings.Join([]string{
		`{"section":"PLANE","verdict":"OK","detail":"PLANE=NATIVE (host beam owns :9443)"}`,
		`{"section":"PODS","verdict":"OK","detail":"all pods Running/Completed"}`,
		`{"section":"ENDPOINTS","verdict":"FAIL","detail":"metadata anchor HTTP 000"}`,
		`{"section":"OVERALL","verdict":"RED","exit":2}`,
		"",
	}, "\n")
	sections, overall, err := parsePoshStatusJSON([]byte(fixture))
	if err != nil {
		t.Fatalf("parse: %v", err)
	}
	if overall != "RED" {
		t.Errorf("overall = %q, want RED", overall)
	}
	if len(sections) != 4 {
		t.Fatalf("sections = %d, want 4", len(sections))
	}
	if sections[2].Verdict != "FAIL" || sections[2].Section != "ENDPOINTS" {
		t.Errorf("sections[2] = %+v", sections[2])
	}
}

// TestParsePoshStatusJSON_MalformedIsTypedError is the mutated-source probe: a
// malformed script report surfaces a typed error, never a default-green.
func TestParsePoshStatusJSON_MalformedIsTypedError(t *testing.T) {
	cases := map[string]string{
		"prose line":      "[POSH-STATUS] PLANE OK",
		"truncated json":  `{"section":"PLANE","verdict":`,
		"empty section":   `{"section":"","verdict":"OK"}`,
		"garbage bytes":   "\x00\x01not json",
		"empty payload":   "",
		"whitespace only": "  \n\t\n",
	}
	for name, in := range cases {
		_, overall, err := parsePoshStatusJSON([]byte(in))
		if err == nil {
			t.Errorf("%s: expected typed error, got overall=%q", name, overall)
		}
		if overall == "GREEN" {
			t.Errorf("%s: synthesized GREEN from malformed input", name)
		}
	}
}

// TestParseDxJSON_MalformedIsTypedError: empty payload is an error, no_data is
// a legitimate empty result set.
func TestParseDxJSON_MalformedIsTypedError(t *testing.T) {
	if _, err := parseDxJSON(nil); err == nil {
		t.Error("empty payload: expected error")
	}
	if _, err := parseDxJSON([]byte("NO DATA: not json")); err == nil {
		t.Error("prose payload: expected error")
	}
	rows, err := parseDxJSON([]byte(`{"rows":[],"no_data":true}`))
	if err != nil || len(rows) != 0 {
		t.Errorf("no_data payload: rows=%v err=%v", rows, err)
	}
}

// TestParseDxJSON_RealFixture parses a row shape emitted by dx_report.py --json.
func TestParseDxJSON_RealFixture(t *testing.T) {
	payload := `{"rows":[{"gate":"coverage","n":12,"pass_pct":100.0,"fail":0,"skip":0,"p50_ms":41,"p99_ms":88,"bf":0}],"no_data":false}`
	rows, err := parseDxJSON([]byte(payload))
	if err != nil {
		t.Fatalf("parse: %v", err)
	}
	if len(rows) != 1 || rows[0].Gate != "coverage" || rows[0].N != 12 {
		t.Fatalf("rows = %+v", rows)
	}
}

// TestRunPoshStatus_RealScript execs the real report-only script (Chicago: real
// collaborator) and asserts the parsed OVERALL matches the script's own exit
// contract (0 => GREEN, 2 => RED).
func TestRunPoshStatus_RealScript(t *testing.T) {
	path := repoScript(t, "posh_status.sh")
	sections, overall, err := runPoshStatus(context.Background(), path)
	if err != nil {
		t.Fatalf("real exec: %v", err)
	}
	if overall != "GREEN" && overall != "RED" {
		t.Errorf("overall = %q, want GREEN|RED", overall)
	}
	found := false
	for _, s := range sections {
		if s.Section == "OVERALL" && s.Verdict == overall {
			found = true
		}
	}
	if !found {
		t.Errorf("OVERALL line missing/mismatched in %+v", sections)
	}
}

// TestRunDxReport_RealScript execs the real dx_report.py --json.
func TestRunDxReport_RealScript(t *testing.T) {
	path := repoScript(t, "dx_report.py")
	if _, err := runDxReport(context.Background(), path); err != nil {
		t.Fatalf("real exec: %v", err)
	}
}

// TestScriptStatusSource_NeverSynthesizesGreen: a source whose scripts are
// missing returns empty (rendered UNKNOWN) verdicts — never a fabricated GREEN.
func TestScriptStatusSource_NeverSynthesizesGreen(t *testing.T) {
	src := NewScriptStatusSource("scripts/does-not-exist.sh", "scripts/also-missing.py")
	// resolveScriptPath falls back to the as-given path when nothing exists;
	// force paths that certainly do not exist
	if _, err := os.Stat(src.StatusScript); err == nil {
		t.Skipf("unexpected existing script %s", src.StatusScript)
	}
	snap := src.Snapshot(context.Background())
	if snap.AndonStatus == "GREEN" {
		t.Error("source synthesized GREEN with no successful probe")
	}
	if src.LastError() == nil {
		t.Error("expected LastError to record the exec failure")
	}
}

// TestAndonFromSections_SourceDriven: the only path to a non-empty AndonStatus
// is the script's own OVERALL verdict line.
func TestAndonFromSections_SourceDriven(t *testing.T) {
	if got := andonFromSections(nil); got != "" {
		t.Errorf("nil sections => %q, want empty", got)
	}
	if got := andonFromSections([]PoshSection{{Section: "PLANE", Verdict: "OK"}}); got != "" {
		t.Errorf("no OVERALL => %q, want empty", got)
	}
	if got := andonFromSections([]PoshSection{{Section: "OVERALL", Verdict: "RED"}}); got != "RED" {
		t.Errorf("OVERALL RED => %q, want RED", got)
	}
}

// TestDirectMetricsSource_NoInventedSeed pins the deletion of the invented
// cachedAndon = "GREEN" seed (GM1): before the first doctor run the snapshot's
// andon is empty (rendered UNKNOWN), never GREEN.
func TestDirectMetricsSource_NoInventedSeed(t *testing.T) {
	src := NewDirectMetricsSource(nil, doctor.Options{})
	snap := src.Snapshot(context.Background())
	if snap.AndonStatus == "GREEN" {
		t.Error("DirectMetricsSource synthesized GREEN before any probe evidence")
	}
}
