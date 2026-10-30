package dev

import (
	"path/filepath"
	"testing"

	"github.com/fsnotify/fsnotify"
)

// TestShouldHandleGeneratedPaths (CC-GM5-3): real fsnotify events replayed
// against the real watcher config — generated (regen-check-owned) paths are
// filtered, owned paths still fire.
func TestShouldHandleGeneratedPaths(t *testing.T) {
	cfg := DefaultWatcherConfig()
	w := &Watcher{cfg: cfg}

	cases := []struct {
		name string
		path string
		want bool
	}{
		{"generated adapter go", filepath.Join("internal", "adapter", "generated_adapters.go"), false},
		{"generated adapter nested", filepath.Join("posh", "internal", "adapter", "generated_x.go"), false},
		{"generated config yaml", filepath.Join("config", "egress_allowlist.generated.yaml"), false},
		{"generated config nested", filepath.Join("posh", "config", "egress_allowlist.generated.yaml"), false},
		{"owned dev source", filepath.Join("internal", "dev", "watcher.go"), true},
		{"owned cmd source", filepath.Join("cmd", "posh", "main.go"), true},
		{"owned root config", filepath.Join("posh.yaml"), true},
	}
	for _, tc := range cases {
		ev := fsnotify.Event{Name: tc.path, Op: fsnotify.Write}
		if got := w.shouldHandle(ev); got != tc.want {
			t.Errorf("%s: shouldHandle(%s) = %v, want %v", tc.name, tc.path, got, tc.want)
		}
	}
}

// TestIgnoredDir pins the addRoots SkipDir behavior: generated dirs are not
// watched at all, plain-name ignores keep segment semantics.
func TestIgnoredDir(t *testing.T) {
	ignore := DefaultWatcherConfig().IgnorePrefix
	if !ignoredDir(".", filepath.Join("internal", "adapter"), ignore) {
		t.Error("internal/adapter must be skipped")
	}
	if !ignoredDir(".", filepath.Join("config"), ignore) {
		t.Error("config must be skipped")
	}
	if ignoredDir(".", filepath.Join("internal", "dev"), ignore) {
		t.Error("internal/dev must stay watched")
	}
	if ignoredDir(".", filepath.Join("cmd", "posh"), ignore) {
		t.Error("cmd/posh must stay watched")
	}
	if !ignoredDir(".", filepath.Join(".git"), ignore) {
		t.Error(".git must stay skipped")
	}
}
