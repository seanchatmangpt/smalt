package dev

import (
	"context"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"time"

	"github.com/fsnotify/fsnotify"
)

// WatcherConfig controls file-watching behavior.
type WatcherConfig struct {
	Roots        []string
	Debounce     time.Duration
	Extensions   []string
	IgnorePrefix []string
}

// DefaultWatcherConfig provides standard Go watch parameters for POSH.
func DefaultWatcherConfig(roots ...string) WatcherConfig {
	if len(roots) == 0 {
		roots = []string{".", "cmd", "internal"}
	}
	return WatcherConfig{
		Roots:        roots,
		Debounce:     75 * time.Millisecond,
		Extensions:   []string{".go", ".yaml", ".yml", ".toml"},
		IgnorePrefix: []string{".git", "bin", "run", "var", "tmp", ".hypothesis", "_build", "deps",
			// generated (regen-check-owned) paths: a regen during `posh dev`
			// must not fire a reload (gap 07 GM5 reload-storm fix)
			"internal/adapter", "config"},
	}
}

// Watcher listens for file change events and yields debounced triggers.
type Watcher struct {
	cfg     WatcherConfig
	fsw     *fsnotify.Watcher
	events  chan string
	errors  chan error
	mu      sync.Mutex
	stopped bool
}

// NewWatcher creates and initializes an fsnotify-backed recursive watcher.
func NewWatcher(cfg WatcherConfig) (*Watcher, error) {
	fsw, err := fsnotify.NewWatcher()
	if err != nil {
		return nil, err
	}

	w := &Watcher{
		cfg:    cfg,
		fsw:    fsw,
		events: make(chan string, 16),
		errors: make(chan error, 16),
	}

	if err := w.addRoots(); err != nil {
		fsw.Close()
		return nil, err
	}

	return w, nil
}

// Events returns the channel of debounced change paths.
func (w *Watcher) Events() <-chan string {
	return w.events
}

// Errors returns the error channel.
func (w *Watcher) Errors() <-chan error {
	return w.errors
}

// Close terminates the watcher.
func (w *Watcher) Close() error {
	w.mu.Lock()
	defer w.mu.Unlock()
	if w.stopped {
		return nil
	}
	w.stopped = true
	return w.fsw.Close()
}

func (w *Watcher) addRoots() error {
	for _, root := range w.cfg.Roots {
		if _, err := os.Stat(root); os.IsNotExist(err) {
			continue
		}
		err := filepath.Walk(root, func(path string, info os.FileInfo, err error) error {
			if err != nil {
				return nil
			}
			if !info.IsDir() {
				return nil
			}
			base := filepath.Base(path)
			for _, ig := range w.cfg.IgnorePrefix {
				if base == ig || strings.HasPrefix(base, ".") {
					return filepath.SkipDir
				}
			}
			if ignoredDir(root, path, w.cfg.IgnorePrefix) {
				return filepath.SkipDir
			}
			return w.fsw.Add(path)
		})
		if err != nil {
			return err
		}
	}
	return nil
}

// Start runs the event aggregation and debounce loop until ctx is canceled.
func (w *Watcher) Start(ctx context.Context) {
	var (
		timer   *time.Timer
		pending string
		mu      sync.Mutex
	)

	trigger := func() {
		mu.Lock()
		p := pending
		pending = ""
		mu.Unlock()
		if p != "" {
			select {
			case w.events <- p:
			default:
			}
		}
	}

	for {
		select {
		case <-ctx.Done():
			w.Close()
			return
		case err, ok := <-w.fsw.Errors:
			if !ok {
				return
			}
			select {
			case w.errors <- err:
			default:
			}
		case ev, ok := <-w.fsw.Events:
			if !ok {
				return
			}
			if !w.shouldHandle(ev) {
				continue
			}

			// If a new directory was created, watch it too
			if ev.Op&fsnotify.Create != 0 {
				if fi, err := os.Stat(ev.Name); err == nil && fi.IsDir() {
					_ = w.fsw.Add(ev.Name)
				}
			}

			mu.Lock()
			pending = ev.Name
			if timer != nil {
				timer.Stop()
			}
			timer = time.AfterFunc(w.cfg.Debounce, trigger)
			mu.Unlock()
		}
	}
}

func (w *Watcher) shouldHandle(ev fsnotify.Event) bool {
	// Only write, create, remove, rename
	if ev.Op&(fsnotify.Write|fsnotify.Create|fsnotify.Remove|fsnotify.Rename) == 0 {
		return false
	}
	ext := filepath.Ext(ev.Name)
	matchExt := false
	for _, e := range w.cfg.Extensions {
		if ext == e {
			matchExt = true
			break
		}
	}
	if !matchExt {
		return false
	}

	for _, ig := range w.cfg.IgnorePrefix {
		if strings.Contains(ig, "/") {
			// path-qualified entry: match as relative path prefix anywhere
			if strings.HasPrefix(ev.Name, ig+"/") ||
				strings.Contains(ev.Name, "/"+ig+"/") {
				return false
			}
			continue
		}
		if strings.Contains(ev.Name, "/"+ig+"/") || strings.HasPrefix(ev.Name, ig+"/") {
			return false
		}
	}
	return true
}

// ignoredDir reports whether a walked directory should be skipped (not watched
// at all), so fsnotify never buffers events for generated paths.
func ignoredDir(root, path string, ignore []string) bool {
	base := filepath.Base(path)
	for _, ig := range ignore {
		if strings.Contains(ig, "/") {
			rel, err := filepath.Rel(root, path)
			if err == nil && (strings.HasPrefix(rel, ig+"/") || rel == ig) {
				return true
			}
			continue
		}
		if base == ig || strings.HasPrefix(base, ".") {
			return true
		}
	}
	return strings.HasPrefix(base, ".")
}
