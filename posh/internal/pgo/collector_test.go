package pgo

import (
	"bytes"
	"compress/gzip"
	"context"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"testing"
	"time"
)

// makeMockGzipProfile creates a minimal valid gzip stream.
func makeMockGzipProfile(payload []byte) []byte {
	var buf bytes.Buffer
	gw := gzip.NewWriter(&buf)
	_, _ = gw.Write(payload)
	_ = gw.Close()
	return buf.Bytes()
}

func TestCollectorFromReader(t *testing.T) {
	tmpDir := t.TempDir()
	cfg := CollectorConfig{
		OutputDir:           tmpDir,
		MaxProfileSizeBytes: 1024 * 1024,
	}
	c := NewCollector(cfg)

	// 1. Valid gzip profile
	mockData := makeMockGzipProfile([]byte("mock pprof cpu sample data"))
	meta, err := c.CollectFromReader(context.Background(), bytes.NewReader(mockData), "sample.pgo", "test")
	if err != nil {
		t.Fatalf("CollectFromReader failed: %v", err)
	}
	if meta.SizeBytes != int64(len(mockData)) {
		t.Errorf("got size %d, want %d", meta.SizeBytes, len(mockData))
	}
	if len(meta.SHA256Hex) != 64 {
		t.Errorf("invalid sha256: %s", meta.SHA256Hex)
	}

	// 2. Invalid non-gzip header
	_, err = c.CollectFromReader(context.Background(), bytes.NewReader([]byte("not gzip data at all")), "bad.pgo", "test")
	if err != ErrInvalidProfileHeader {
		t.Fatalf("expected ErrInvalidProfileHeader, got %v", err)
	}

	// 3. Oversized payload
	cfgSmall := CollectorConfig{
		OutputDir:           tmpDir,
		MaxProfileSizeBytes: 10,
	}
	cSmall := NewCollector(cfgSmall)
	_, err = cSmall.CollectFromReader(context.Background(), bytes.NewReader(mockData), "large.pgo", "test")
	if err != ErrProfileTooLarge {
		t.Fatalf("expected ErrProfileTooLarge, got %v", err)
	}
}

func TestCollectorFromHTTP(t *testing.T) {
	mockData := makeMockGzipProfile([]byte("pprof profile from sidecar"))
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/octet-stream")
		_, _ = w.Write(mockData)
	}))
	defer server.Close()

	tmpDir := t.TempDir()
	c := NewCollector(CollectorConfig{OutputDir: tmpDir})

	meta, err := c.CollectFromURL(context.Background(), server.URL, server.Client())
	if err != nil {
		t.Fatalf("CollectFromURL failed: %v", err)
	}
	if meta.SizeBytes != int64(len(mockData)) {
		t.Errorf("got size %d, want %d", meta.SizeBytes, len(mockData))
	}
}

func TestCollectorPruning(t *testing.T) {
	tmpDir := t.TempDir()
	cfg := CollectorConfig{
		OutputDir:             tmpDir,
		RetainedProfilesLimit: 3,
	}
	c := NewCollector(cfg)

	// Write 5 profiles sequentially
	for i := 0; i < 5; i++ {
		data := makeMockGzipProfile([]byte{byte(i)})
		_, err := c.CollectFromReader(context.Background(), bytes.NewReader(data), "", "test")
		if err != nil {
			t.Fatalf("iteration %d failed: %v", i, err)
		}
		time.Sleep(10 * time.Millisecond) // Ensure distinct timestamps
	}

	entries, err := os.ReadDir(tmpDir)
	if err != nil {
		t.Fatal(err)
	}
	if len(entries) != 3 {
		t.Errorf("expected 3 retained profiles, found %d", len(entries))
	}
}

func TestMergerValidationAndExecution(t *testing.T) {
	tmpDir := t.TempDir()

	// Locate repo's default.pgo if available, or generate mock profiles
	defaultPgoPath := filepath.Join("..", "..", "default.pgo")
	var profileBytes []byte
	if b, err := os.ReadFile(defaultPgoPath); err == nil && len(b) > 0 {
		profileBytes = b
	} else {
		profileBytes = makeMockGzipProfile(bytes.Repeat([]byte("call-graph-trace-node"), 50))
	}

	p1 := filepath.Join(tmpDir, "prof1.pgo")
	p2 := filepath.Join(tmpDir, "prof2.pgo")
	bad := filepath.Join(tmpDir, "corrupt.pgo")

	if err := os.WriteFile(p1, profileBytes, 0644); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(p2, profileBytes, 0644); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(bad, []byte("plain text corrupt"), 0644); err != nil {
		t.Fatal(err)
	}

	merger := NewMerger(DefaultMergerConfig())

	// 1. Single valid input profile merge (direct copy optimization)
	outSingle := filepath.Join(tmpDir, "merged_single.pgo")
	receiptSingle, err := merger.Merge(context.Background(), []string{p1}, outSingle)
	if err != nil {
		t.Fatalf("single merge failed: %v", err)
	}
	if receiptSingle.ValidInputCount != 1 {
		t.Errorf("valid inputs = %d, want 1", receiptSingle.ValidInputCount)
	}
	if receiptSingle.OutputSizeBytes <= 0 {
		t.Errorf("invalid output size: %d", receiptSingle.OutputSizeBytes)
	}

	// 2. Multi-profile merge with corrupt file filtered out
	outMulti := filepath.Join(tmpDir, "merged_multi.pgo")
	receiptMulti, err := merger.Merge(context.Background(), []string{p1, bad, p2}, outMulti)
	if err != nil {
		t.Fatalf("multi merge failed: %v", err)
	}
	if receiptMulti.ValidInputCount != 2 {
		t.Errorf("valid inputs = %d, want 2 (corrupt ignored)", receiptMulti.ValidInputCount)
	}
	if receiptMulti.SHA256Hex == "" {
		t.Errorf("empty sha256 receipt")
	}

	// 3. Merge directory
	outDir := filepath.Join(tmpDir, "merged_dir.pgo")
	receiptDir, err := merger.MergeDirectory(context.Background(), tmpDir, outDir)
	if err != nil {
		t.Fatalf("merge directory failed: %v", err)
	}
	if receiptDir.ValidInputCount < 2 {
		t.Errorf("expected at least 2 valid profiles from dir, got %d", receiptDir.ValidInputCount)
	}

	// 4. No valid inputs error check
	_, err = merger.Merge(context.Background(), []string{bad}, filepath.Join(tmpDir, "none.pgo"))
	if err != ErrNoValidProfiles {
		t.Fatalf("expected ErrNoValidProfiles, got %v", err)
	}
}
