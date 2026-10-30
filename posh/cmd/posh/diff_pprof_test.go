package main

import (
	"bytes"
	"os"
	"path/filepath"
	"testing"

	"smalt.dev/posh/internal/telemetry/diffpprof"
)

func makeTestPProfFile(t *testing.T, dir string, name string, allocB int64) string {
	t.Helper()
	p := &diffpprof.Profile{
		SampleType: []*diffpprof.ValueType{
			{Type: "alloc_objects", Unit: "count"},
			{Type: "alloc_space", Unit: "bytes"},
			{Type: "inuse_objects", Unit: "count"},
			{Type: "inuse_space", Unit: "bytes"},
			{Type: "samples", Unit: "count"},
			{Type: "cpu", Unit: "nanoseconds"},
		},
	}

	fn := &diffpprof.Function{
		ID:       1,
		Name:     "membrane.Serve",
		Filename: "server.go",
	}
	p.Function = append(p.Function, fn)

	loc := &diffpprof.Location{
		ID: 1,
		Lines: []diffpprof.Line{
			{
				Function:   fn,
				FunctionID: 1,
				LineNumber: 42,
			},
		},
	}
	p.Location = append(p.Location, loc)

	allocCount := int64(0)
	if allocB > 0 {
		allocCount = 1
	}

	p.Sample = append(p.Sample, &diffpprof.Sample{
		LocationIDs: []uint64{1},
		Locations:   []*diffpprof.Location{loc},
		Values:      []int64{allocCount, allocB, 0, 0, 10, 1000000},
	})

	var buf bytes.Buffer
	if err := p.Encode(&buf); err != nil {
		t.Fatalf("Encode: %v", err)
	}

	filePath := filepath.Join(dir, name)
	if err := os.WriteFile(filePath, buf.Bytes(), 0o644); err != nil {
		t.Fatalf("WriteFile: %v", err)
	}
	return filePath
}

func TestRunDiffPprof_MissingArgs(t *testing.T) {
	code := runDiffPprof([]string{})
	if code != 2 {
		t.Fatalf("Expected exit code 2 on missing args, got %d", code)
	}
}

func TestRunDiffPprof_ZeroAllocPass(t *testing.T) {
	dir := t.TempDir()
	basePath := makeTestPProfFile(t, dir, "base.pprof", 0)
	candPath := makeTestPProfFile(t, dir, "cand.pprof", 0)

	code := runDiffPprof([]string{"-strict=true", "-no-color", basePath, candPath})
	if code != 0 {
		t.Fatalf("Expected exit code 0 on zero-alloc pass, got %d", code)
	}
}

func TestRunDiffPprof_RegressionFail(t *testing.T) {
	dir := t.TempDir()
	basePath := makeTestPProfFile(t, dir, "base.pprof", 0)
	candPath := makeTestPProfFile(t, dir, "cand.pprof", 1024)

	code := runDiffPprof([]string{"-strict=true", "-no-color", basePath, candPath})
	if code != 1 {
		t.Fatalf("Expected exit code 1 on zero-alloc regression, got %d", code)
	}
}

func TestRunDiffPprof_JSONOutput(t *testing.T) {
	dir := t.TempDir()
	basePath := makeTestPProfFile(t, dir, "base.pprof", 0)
	candPath := makeTestPProfFile(t, dir, "cand.pprof", 0)

	code := runDiffPprof([]string{"-json", basePath, candPath})
	if code != 0 {
		t.Fatalf("Expected exit code 0 on json output, got %d", code)
	}
}
