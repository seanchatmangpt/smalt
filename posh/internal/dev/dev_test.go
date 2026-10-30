package dev

import (
	"context"
	"net"
	"os"
	"path/filepath"
	"testing"
	"time"

	"github.com/fsnotify/fsnotify"
)

func TestWatcherFilterRules(t *testing.T) {
	cfg := DefaultWatcherConfig(".")
	w := &Watcher{cfg: cfg}

	// Should handle .go modifications
	evGo := fsnotify.Event{Name: "internal/server/server.go", Op: fsnotify.Write}
	if !w.shouldHandle(evGo) {
		t.Errorf("expected shouldHandle to accept .go write")
	}

	// Should handle .yaml modifications
	evYaml := fsnotify.Event{Name: "posh.yaml", Op: fsnotify.Write}
	if !w.shouldHandle(evYaml) {
		t.Errorf("expected shouldHandle to accept .yaml write")
	}

	// Should ignore git directory changes
	evGit := fsnotify.Event{Name: ".git/index", Op: fsnotify.Write}
	if w.shouldHandle(evGit) {
		t.Errorf("expected shouldHandle to ignore .git files")
	}

	// Should ignore temporary files
	evTmp := fsnotify.Event{Name: "tmp/scratch.go", Op: fsnotify.Write}
	if w.shouldHandle(evTmp) {
		t.Errorf("expected shouldHandle to ignore tmp/ files")
	}

	// Should ignore chmod events
	evChmod := fsnotify.Event{Name: "cmd/posh/main.go", Op: fsnotify.Chmod}
	if w.shouldHandle(evChmod) {
		t.Errorf("expected shouldHandle to ignore chmod")
	}
}

func TestSupervisorSocketInheritance(t *testing.T) {
	tmpDir := t.TempDir()
	sockPath := filepath.Join(tmpDir, "dev.sock")

	sup, err := NewSupervisor(SupervisorOptions{
		SocketPath: sockPath,
	})
	if err != nil {
		t.Fatalf("NewSupervisor: %v", err)
	}
	defer sup.Close()

	// Verify socket was created and is connectable
	c, err := net.Dial("unix", sockPath)
	if err != nil {
		t.Fatalf("failed to dial supervisor socket: %v", err)
	}
	c.Close()

	if sup.socketFile == nil {
		t.Fatalf("expected socketFile to be non-nil")
	}

	// Ensure second supervisor fails with collision
	_, err2 := NewSupervisor(SupervisorOptions{
		SocketPath: sockPath,
	})
	if err2 == nil {
		t.Fatalf("expected error on duplicate bind, got nil")
	}
}

func TestWatcherDebounce(t *testing.T) {
	tmpDir := t.TempDir()
	cfg := WatcherConfig{
		Roots:        []string{tmpDir},
		Debounce:     30 * time.Millisecond,
		Extensions:   []string{".go"},
		IgnorePrefix: []string{".git"},
	}

	w, err := NewWatcher(cfg)
	if err != nil {
		t.Fatalf("NewWatcher: %v", err)
	}
	defer w.Close()

	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	go w.Start(ctx)

	// Rapidly write multiple times
	testFile := filepath.Join(tmpDir, "test.go")
	for i := 0; i < 5; i++ {
		_ = os.WriteFile(testFile, []byte("package main"), 0o644)
		time.Sleep(5 * time.Millisecond)
	}

	select {
	case p := <-w.Events():
		if p != testFile {
			t.Errorf("event path = %s, want %s", p, testFile)
		}
	case <-time.After(500 * time.Millisecond):
		t.Fatalf("timed out waiting for debounced event")
	}
}
