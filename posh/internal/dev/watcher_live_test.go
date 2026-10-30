package dev

import (
	"context"
	"os"
	"path/filepath"
	"testing"
	"time"
)

// TestWatcherIgnoresGeneratedLive (CC-GM5-1/2, real execution): a real
// fsnotify watcher over a real temp tree — touching a generated-path file
// yields zero reload events within a bounded window, touching an owned file
// still fires (non-vacuity: the gate must flip for owned paths).
func TestWatcherIgnoresGeneratedLive(t *testing.T) {
	// t.TempDir() lives under /var/folders/... which the watcher's own
	// "var" ignore prefix would swallow — build the fixture inside the repo.
	root, err := os.MkdirTemp("..", "watcher-live-")
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { os.RemoveAll(root) })
	for _, d := range []string{"internal/adapter", "internal/dev", "config"} {
		if err := os.MkdirAll(filepath.Join(root, d), 0o755); err != nil {
			t.Fatal(err)
		}
	}
	for _, f := range []string{"internal/adapter/generated_adapters.go", "internal/dev/watcher.go", "config/egress_allowlist.generated.yaml"} {
		if err := os.WriteFile(filepath.Join(root, f), []byte("package x\n"), 0o644); err != nil {
			t.Fatal(err)
		}
	}

	w, err := NewWatcher(DefaultWatcherConfig(root))
	if err != nil {
		t.Fatal(err)
	}
	defer w.Close()

	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	go w.Start(ctx)

	// touch generated + generated-config paths: must produce no events
	touch := func(rel string) {
		p := filepath.Join(root, rel)
		f, err := os.OpenFile(p, os.O_WRONLY|os.O_APPEND, 0o644)
		if err != nil {
			t.Fatal(err)
		}
		f.WriteString("\n")
		f.Close()
	}
	touch("internal/adapter/generated_adapters.go")
	touch("config/egress_allowlist.generated.yaml")

	// bounded absence window: 10x debounce; select-based, no sleeps
	absenceWindow := time.After(10 * w.cfg.Debounce)
	select {
	case ev := <-w.Events():
		t.Fatalf("reload event fired for generated path: %s", ev)
	case <-absenceWindow:
	}

	// non-vacuity: owned path still fires, bounded poll on the real observable
	touch("internal/dev/watcher.go")
	deadline := time.After(10 * w.cfg.Debounce)
	for {
		select {
		case ev := <-w.Events():
			if filepath.Base(ev) == "watcher.go" {
				return // gate flips for owned paths — court satisfied
			}
		case <-deadline:
			t.Fatal("owned path touch produced no reload event within window")
		}
	}
}
