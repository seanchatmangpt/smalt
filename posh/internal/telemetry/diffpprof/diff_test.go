package diffpprof

import (
	"bytes"
	"os"
	"path/filepath"
	"runtime"
	"runtime/pprof"
	"strings"
	"testing"
)

// Helper to construct a synthetic pprof profile
func makeTestProfile(symbols []struct {
	name       string
	allocB     int64
	allocCount int64
	cpuSamples int64
}) *Profile {
	p := &Profile{
		SampleType: []*ValueType{
			{Type: "alloc_objects", Unit: "count"},
			{Type: "alloc_space", Unit: "bytes"},
			{Type: "inuse_objects", Unit: "count"},
			{Type: "inuse_space", Unit: "bytes"},
			{Type: "samples", Unit: "count"},
			{Type: "cpu", Unit: "nanoseconds"},
		},
	}

	for i, s := range symbols {
		fnID := uint64(i + 1)
		locID := uint64(i + 1)

		fn := &Function{
			ID:       fnID,
			Name:     s.name,
			Filename: "membrane.go",
		}
		p.Function = append(p.Function, fn)

		loc := &Location{
			ID: locID,
			Lines: []Line{
				{
					Function:   fn,
					FunctionID: fnID,
					LineNumber: int64(100 + i),
				},
			},
		}
		p.Location = append(p.Location, loc)

		sample := &Sample{
			LocationIDs: []uint64{locID},
			Locations:   []*Location{loc},
			Values: []int64{
				s.allocCount,
				s.allocB,
				0,
				0,
				s.cpuSamples,
				s.cpuSamples * 1000000,
			},
		}
		p.Sample = append(p.Sample, sample)
	}

	p.linkReferences()
	return p
}

func TestDiff_RoundtripEncodeParse(t *testing.T) {
	orig := makeTestProfile([]struct {
		name       string
		allocB     int64
		allocCount int64
		cpuSamples int64
	}{
		{"echoHandler", 0, 0, 10},
		{"armClientGet", 2048, 4, 25},
	})

	var buf bytes.Buffer
	if err := orig.Encode(&buf); err != nil {
		t.Fatalf("Encode failed: %v", err)
	}

	parsed, err := ParseProfile(&buf)
	if err != nil {
		t.Fatalf("ParseProfile failed: %v", err)
	}

	if len(parsed.Function) != len(orig.Function) {
		t.Fatalf("Function count mismatch: got %d, want %d", len(parsed.Function), len(orig.Function))
	}
	if len(parsed.Sample) != len(orig.Sample) {
		t.Fatalf("Sample count mismatch: got %d, want %d", len(parsed.Sample), len(orig.Sample))
	}

	metrics := parsed.ExtractSymbolMetrics()
	if sm, ok := metrics["echoHandler"]; !ok || sm.FlatCPUSamples != 10 {
		t.Fatalf("echoHandler metrics mismatch: %+v", sm)
	}
	if sm, ok := metrics["armClientGet"]; !ok || sm.FlatAllocBytes != 2048 || sm.FlatAllocCount != 4 {
		t.Fatalf("armClientGet metrics mismatch: %+v", sm)
	}
}

func TestDiff_ZeroAllocRegressionDetection(t *testing.T) {
	// Baseline: pure zero-alloc membrane hot path
	baseline := makeTestProfile([]struct {
		name       string
		allocB     int64
		allocCount int64
		cpuSamples int64
	}{
		{"posh/internal/telemetry/fastmetrics.Record", 0, 0, 50},
		{"posh/internal/server.handleEcho", 0, 0, 40},
	})

	// Candidate: regression introduced in handleEcho (allocates 512 bytes on heap)
	candidate := makeTestProfile([]struct {
		name       string
		allocB     int64
		allocCount int64
		cpuSamples int64
	}{
		{"posh/internal/telemetry/fastmetrics.Record", 0, 0, 50},
		{"posh/internal/server.handleEcho", 512, 1, 45},
	})

	diff := CompareProfiles(baseline, candidate, WithStrictZeroAlloc(true))

	if diff.ZeroAllocPassed {
		t.Fatalf("Expected ZeroAllocPassed to be false, got true")
	}
	if !diff.HasRegression() {
		t.Fatalf("Expected HasRegression to be true, got false")
	}
	if len(diff.Regressions) != 1 {
		t.Fatalf("Expected exactly 1 regression, got %d", len(diff.Regressions))
	}

	reg := diff.Regressions[0]
	if reg.Symbol != "posh/internal/server.handleEcho" {
		t.Fatalf("Expected regressed symbol to be handleEcho, got %s", reg.Symbol)
	}
	if reg.DeltaAllocB != 512 || reg.DeltaAllocs != 1 {
		t.Fatalf("Delta mismatch: +%d B, +%d allocs", reg.DeltaAllocB, reg.DeltaAllocs)
	}

	table := diff.FormatTable(false)
	if !strings.Contains(table, "[FAIL]") {
		t.Fatalf("Expected table to contain [FAIL], got:\n%s", table)
	}
	if !strings.Contains(table, "FAILED (1 regressions detected") {
		t.Fatalf("Expected table to report verdict FAILED, got:\n%s", table)
	}
}

func TestDiff_PassZeroAlloc(t *testing.T) {
	baseline := makeTestProfile([]struct {
		name       string
		allocB     int64
		allocCount int64
		cpuSamples int64
	}{
		{"posh/membrane.ServeUDS", 0, 0, 100},
	})

	candidate := makeTestProfile([]struct {
		name       string
		allocB     int64
		allocCount int64
		cpuSamples int64
	}{
		{"posh/membrane.ServeUDS", 0, 0, 95}, // CPU reduced, still 0 allocs
	})

	diff := CompareProfiles(baseline, candidate, WithStrictZeroAlloc(true))

	if !diff.ZeroAllocPassed {
		t.Fatalf("Expected ZeroAllocPassed=true, got false")
	}
	if diff.HasRegression() {
		t.Fatalf("Expected HasRegression=false, got true")
	}

	table := diff.FormatTable(false)
	if !strings.Contains(table, "ZERO-ALLOC INVARIANT VERDICT: PASSED") {
		t.Fatalf("Expected table to report PASSED, got:\n%s", table)
	}

	jsonBytes, err := diff.FormatJSON()
	if err != nil {
		t.Fatalf("FormatJSON failed: %v", err)
	}
	if !strings.Contains(string(jsonBytes), `"zero_alloc_passed": true`) {
		t.Fatalf("Expected JSON to have zero_alloc_passed: true, got:\n%s", string(jsonBytes))
	}
}

func TestDiff_RealRuntimeProfiles(t *testing.T) {
	tempDir := t.TempDir()
	basePath := filepath.Join(tempDir, "base_heap.pprof")
	candPath := filepath.Join(tempDir, "cand_heap.pprof")

	// 1. Capture baseline profile
	f1, err := os.Create(basePath)
	if err != nil {
		t.Fatalf("create base file: %v", err)
	}
	runtime.GC()
	if err := pprof.Lookup("heap").WriteTo(f1, 0); err != nil {
		t.Fatalf("write baseline heap: %v", err)
	}
	f1.Close()

	// 2. Perform some heap allocations
	var sink [][]byte
	for i := 0; i < 50; i++ {
		sink = append(sink, make([]byte, 1024))
	}
	_ = sink

	// 3. Capture candidate profile
	f2, err := os.Create(candPath)
	if err != nil {
		t.Fatalf("create cand file: %v", err)
	}
	runtime.GC()
	if err := pprof.Lookup("heap").WriteTo(f2, 0); err != nil {
		t.Fatalf("write cand heap: %v", err)
	}
	f2.Close()

	// 4. Compare profile streams
	r1, err := os.Open(basePath)
	if err != nil {
		t.Fatalf("open base: %v", err)
	}
	defer r1.Close()

	r2, err := os.Open(candPath)
	if err != nil {
		t.Fatalf("open cand: %v", err)
	}
	defer r2.Close()

	diff, err := Compare(r1, r2, WithStrictZeroAlloc(false), WithTolerance(0, 0, 10.0))
	if err != nil {
		t.Fatalf("Compare real profiles failed: %v", err)
	}

	if len(diff.Symbols) == 0 {
		t.Fatalf("Expected symbols extracted from real heap profiles, got 0")
	}

	table := diff.FormatTable(true)
	if len(table) == 0 {
		t.Fatalf("Expected formatted table output")
	}
}

func BenchmarkCompareProfiles(b *testing.B) {
	p1 := makeTestProfile([]struct {
		name       string
		allocB     int64
		allocCount int64
		cpuSamples int64
	}{
		{"func1", 0, 0, 100},
		{"func2", 1024, 2, 50},
		{"func3", 2048, 4, 30},
		{"func4", 0, 0, 20},
	})
	p2 := makeTestProfile([]struct {
		name       string
		allocB     int64
		allocCount int64
		cpuSamples int64
	}{
		{"func1", 0, 0, 110},
		{"func2", 2048, 4, 60},
		{"func3", 2048, 4, 30},
		{"func4", 512, 1, 25},
	})

	b.ResetTimer()
	for i := 0; i < b.N; i++ {
		_ = CompareProfiles(p1, p2, WithStrictZeroAlloc(true))
	}
}
