package profiler

import (
	"context"
	"os"
	"path/filepath"
	"runtime"
	"testing"
	"time"
)

func TestWatchdog_WatermarkTriggerAndCooldown(t *testing.T) {
	tempDir := t.TempDir()

	opts := WatchdogOptions{
		OutputDir:           tempDir,
		CheckInterval:       10 * time.Millisecond,
		GoroutineWatermark:  runtime.NumGoroutine() - 1, // Guaranteed to trigger
		CooldownDuration:    500 * time.Millisecond,
		MaxDumpsRetained:    5,
		CaptureTraceSeconds: 0,
	}

	w := NewWatchdog(opts)
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()

	if err := w.Start(ctx); err != nil {
		t.Fatalf("Start watchdog: %v", err)
	}

	// Wait for trigger
	time.Sleep(100 * time.Millisecond)

	count := w.DumpCount()
	if count < 1 {
		t.Fatalf("Expected at least 1 dump, got %d", count)
	}

	// Verify dump files exist
	entries, err := os.ReadDir(tempDir)
	if err != nil {
		t.Fatalf("ReadDir: %v", err)
	}
	if len(entries) < 2 { // At least goroutine txt and heap pprof
		t.Fatalf("Expected at least 2 dump files, found %d", len(entries))
	}

	// Verify cooldown prevents immediate re-trigger
	time.Sleep(50 * time.Millisecond)
	if w.DumpCount() != count {
		t.Fatalf("Cooldown failed: dump count increased during cooldown period (%d != %d)", w.DumpCount(), count)
	}

	w.Stop()
}

func TestPruneOldFiles(t *testing.T) {
	tempDir := t.TempDir()

	// Create 10 files with staggered timestamps
	for i := 0; i < 10; i++ {
		path := filepath.Join(tempDir, filepath.Base(tempDir)+string(rune('a'+i))+".txt")
		_ = os.WriteFile(path, []byte("test"), 0o644)
		time.Sleep(5 * time.Millisecond)
	}

	pruneOldFiles(tempDir, 4)

	entries, _ := os.ReadDir(tempDir)
	if len(entries) != 4 {
		t.Fatalf("Expected 4 files remaining after prune, got %d", len(entries))
	}
}

func TestCaptureExecutionTrace(t *testing.T) {
	tempDir := t.TempDir()
	tracePath := filepath.Join(tempDir, "test_trace.out")

	err := CaptureExecutionTrace(tracePath, 50*time.Millisecond)
	if err != nil {
		t.Fatalf("CaptureExecutionTrace failed: %v", err)
	}

	info, err := os.Stat(tracePath)
	if err != nil {
		t.Fatalf("Stat trace file: %v", err)
	}
	if info.Size() == 0 {
		t.Fatalf("Trace file is empty")
	}
}
