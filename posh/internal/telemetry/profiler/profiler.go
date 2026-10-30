// Package profiler implements production-safe continuous profiling,
// dynamic threshold profiling (goroutine/memory watermark watchdog),
// and on-demand execution tracing for POSH and the Smalt ecosystem.
package profiler

import (
	"context"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"runtime"
	"runtime/pprof"
	"runtime/trace"
	"sort"
	"sync"
	"sync/atomic"
	"time"
)

// ContinuousOptions configures continuous sampling profiling.
type ContinuousOptions struct {
	OutputDir      string        // Directory where periodic profiles are written
	SampleInterval time.Duration // How often to capture a profile (e.g., 60s)
	SampleDuration time.Duration // Duration of each CPU profile window (e.g., 10s)
	ProfileRateHz  int           // CPU profile sampling rate in Hz (default 49 Hz to avoid harmonic lockstep)
	MaxProfiles    int           // Max retained profile files before FIFO rotation (default 10)
}

// DefaultContinuousOptions returns safe production defaults (<0.5% overhead).
func DefaultContinuousOptions() ContinuousOptions {
	return ContinuousOptions{
		OutputDir:      "run/profiles",
		SampleInterval: 60 * time.Second,
		SampleDuration: 10 * time.Second,
		ProfileRateHz:  49,
		MaxProfiles:    10,
	}
}

// ContinuousProfiler manages periodic background sampling of CPU and heap.
type ContinuousProfiler struct {
	opts   ContinuousOptions
	ctx    context.Context
	cancel context.CancelFunc
	wg     sync.WaitGroup
	active atomic.Bool
}

// NewContinuousProfiler creates a new ContinuousProfiler.
func NewContinuousProfiler(opts ContinuousOptions) *ContinuousProfiler {
	if opts.SampleInterval <= 0 {
		opts.SampleInterval = 60 * time.Second
	}
	if opts.SampleDuration <= 0 {
		opts.SampleDuration = 10 * time.Second
	}
	if opts.ProfileRateHz <= 0 {
		opts.ProfileRateHz = 49
	}
	if opts.MaxProfiles <= 0 {
		opts.MaxProfiles = 10
	}
	return &ContinuousProfiler{opts: opts}
}

// Start begins the continuous sampling loop in the background.
func (cp *ContinuousProfiler) Start(parent context.Context) error {
	if cp.active.Swap(true) {
		return fmt.Errorf("continuous profiler already running")
	}

	if err := os.MkdirAll(cp.opts.OutputDir, 0o755); err != nil {
		cp.active.Store(false)
		return fmt.Errorf("create profile dir: %w", err)
	}

	cp.ctx, cp.cancel = context.WithCancel(parent)
	cp.wg.Add(1)
	go cp.loop()
	return nil
}

// Stop gracefully stops the continuous profiler.
func (cp *ContinuousProfiler) Stop() {
	if !cp.active.Swap(false) {
		return
	}
	if cp.cancel != nil {
		cp.cancel()
	}
	cp.wg.Wait()
}

func (cp *ContinuousProfiler) loop() {
	defer cp.wg.Done()
	ticker := time.NewTicker(cp.opts.SampleInterval)
	defer ticker.Stop()

	for {
		select {
		case <-cp.ctx.Done():
			return
		case <-ticker.C:
			cp.captureWindow()
		}
	}
}

func (cp *ContinuousProfiler) captureWindow() {
	ts := time.Now().UTC().Format("20060102_150405")
	cpuPath := filepath.Join(cp.opts.OutputDir, fmt.Sprintf("cpu_%s.pprof", ts))
	heapPath := filepath.Join(cp.opts.OutputDir, fmt.Sprintf("heap_%s.pprof", ts))

	// 1. Capture CPU profile window
	if f, err := os.Create(cpuPath); err == nil {
		runtime.SetCPUProfileRate(cp.opts.ProfileRateHz)
		if err := pprof.StartCPUProfile(f); err == nil {
			select {
			case <-time.After(cp.opts.SampleDuration):
			case <-cp.ctx.Done():
			}
			pprof.StopCPUProfile()
		}
		f.Close()
	}

	// 2. Capture Heap snapshot
	if f, err := os.Create(heapPath); err == nil {
		runtime.GC() // Clean sweep before snapshot
		_ = pprof.Lookup("heap").WriteTo(f, 0)
		f.Close()
	}

	// 3. Rotate old profiles
	pruneOldFiles(cp.opts.OutputDir, cp.opts.MaxProfiles*2)
}

// pruneOldFiles keeps at most maxFiles newest files in dir.
func pruneOldFiles(dir string, maxFiles int) {
	entries, err := os.ReadDir(dir)
	if err != nil || len(entries) <= maxFiles {
		return
	}

	type fileInfo struct {
		path    string
		modTime time.Time
	}
	var files []fileInfo
	for _, e := range entries {
		if e.IsDir() {
			continue
		}
		info, err := e.Info()
		if err != nil {
			continue
		}
		files = append(files, fileInfo{path: filepath.Join(dir, e.Name()), modTime: info.ModTime()})
	}

	sort.Slice(files, func(i, j int) bool {
		return files[i].modTime.Before(files[j].modTime)
	})

	toDelete := len(files) - maxFiles
	for i := 0; i < toDelete; i++ {
		_ = os.Remove(files[i].path)
	}
}

// WatchdogOptions configures dynamic threshold auto-profiling.
type WatchdogOptions struct {
	OutputDir           string        // Destination for emergency dumps
	CheckInterval       time.Duration // Sampling interval for watermark check (e.g., 500ms)
	GoroutineWatermark  int           // Goroutine count trigger bound (e.g., 2000)
	HeapBytesWatermark  uint64        // HeapAlloc bytes trigger bound (e.g., 256 MiB)
	GCPauseNsWatermark  uint64        // Longest GC pause trigger bound (e.g., 25ms = 25000000)
	CooldownDuration    time.Duration // Minimum cooldown between dumps to prevent flapping (e.g., 30s)
	MaxDumpsRetained    int           // Max dump files retained (default 10)
	CaptureTraceSeconds int           // If > 0, capture execution trace for N seconds on trigger
}

// DefaultWatchdogOptions provides production baseline thresholds.
func DefaultWatchdogOptions() WatchdogOptions {
	return WatchdogOptions{
		OutputDir:           "run/dumps",
		CheckInterval:       1 * time.Second,
		GoroutineWatermark:  2000,
		HeapBytesWatermark:  256 << 20,  // 256 MiB
		GCPauseNsWatermark:  20_000_000, // 20 ms
		CooldownDuration:    30 * time.Second,
		MaxDumpsRetained:    10,
		CaptureTraceSeconds: 2,
	}
}

// Watchdog monitors runtime watermarks and captures diagnostics when exceeded.
type Watchdog struct {
	opts      WatchdogOptions
	ctx       context.Context
	cancel    context.CancelFunc
	wg        sync.WaitGroup
	active    atomic.Bool
	lastDump  time.Time
	dumpLock  sync.Mutex
	dumpCount atomic.Uint64
}

// NewWatchdog creates a new threshold Watchdog.
func NewWatchdog(opts WatchdogOptions) *Watchdog {
	if opts.CheckInterval <= 0 {
		opts.CheckInterval = 1 * time.Second
	}
	if opts.CooldownDuration <= 0 {
		opts.CooldownDuration = 30 * time.Second
	}
	if opts.MaxDumpsRetained <= 0 {
		opts.MaxDumpsRetained = 10
	}
	return &Watchdog{opts: opts}
}

// Start begins watermark monitoring.
func (w *Watchdog) Start(parent context.Context) error {
	if w.active.Swap(true) {
		return fmt.Errorf("watchdog already running")
	}

	if err := os.MkdirAll(w.opts.OutputDir, 0o755); err != nil {
		w.active.Store(false)
		return fmt.Errorf("create dump dir: %w", err)
	}

	w.ctx, w.cancel = context.WithCancel(parent)
	w.wg.Add(1)
	go w.loop()
	return nil
}

// Stop terminates the watchdog.
func (w *Watchdog) Stop() {
	if !w.active.Swap(false) {
		return
	}
	if w.cancel != nil {
		w.cancel()
	}
	w.wg.Wait()
}

// DumpCount returns the number of threshold dumps executed.
func (w *Watchdog) DumpCount() uint64 {
	return w.dumpCount.Load()
}

func (w *Watchdog) loop() {
	defer w.wg.Done()
	ticker := time.NewTicker(w.opts.CheckInterval)
	defer ticker.Stop()

	var memStats runtime.MemStats

	for {
		select {
		case <-w.ctx.Done():
			return
		case <-ticker.C:
			numG := runtime.NumGoroutine()
			runtime.ReadMemStats(&memStats)

			triggered := false
			reason := ""

			if w.opts.GoroutineWatermark > 0 && numG > w.opts.GoroutineWatermark {
				triggered = true
				reason = fmt.Sprintf("goroutines=%d > watermark=%d", numG, w.opts.GoroutineWatermark)
			} else if w.opts.HeapBytesWatermark > 0 && memStats.HeapAlloc > w.opts.HeapBytesWatermark {
				triggered = true
				reason = fmt.Sprintf("heap_alloc=%d > watermark=%d", memStats.HeapAlloc, w.opts.HeapBytesWatermark)
			} else if w.opts.GCPauseNsWatermark > 0 && memStats.PauseNs[(memStats.NumGC+255)%256] > w.opts.GCPauseNsWatermark {
				triggered = true
				reason = fmt.Sprintf("gc_pause=%d ns > watermark=%d ns", memStats.PauseNs[(memStats.NumGC+255)%256], w.opts.GCPauseNsWatermark)
			}

			if triggered {
				w.triggerDump(reason)
			}
		}
	}
}

func (w *Watchdog) triggerDump(reason string) {
	w.dumpLock.Lock()
	defer w.dumpLock.Unlock()

	now := time.Now()
	if now.Sub(w.lastDump) < w.opts.CooldownDuration {
		return // Anti-flapping hysteresis active
	}
	w.lastDump = now
	w.dumpCount.Add(1)

	ts := now.UTC().Format("20060102_150405.000")
	prefix := filepath.Join(w.opts.OutputDir, fmt.Sprintf("dump_%s", ts))

	// 1. Goroutine stack dump
	if f, err := os.Create(prefix + "_goroutines.txt"); err == nil {
		fmt.Fprintf(f, "# Trigger reason: %s\n# Timestamp: %s\n\n", reason, now.Format(time.RFC3339Nano))
		_ = pprof.Lookup("goroutine").WriteTo(f, 2)
		f.Close()
	}

	// 2. Heap profile dump
	if f, err := os.Create(prefix + "_heap.pprof"); err == nil {
		_ = pprof.Lookup("heap").WriteTo(f, 0)
		f.Close()
	}

	// 3. Optional short execution trace window
	if w.opts.CaptureTraceSeconds > 0 {
		tracePath := prefix + "_trace.out"
		go func(path string, dur time.Duration) {
			_ = CaptureExecutionTrace(path, dur)
		}(tracePath, time.Duration(w.opts.CaptureTraceSeconds)*time.Second)
	}

	// Prune old dumps to bound disk usage
	pruneOldFiles(w.opts.OutputDir, w.opts.MaxDumpsRetained*3)
}

var traceMu sync.Mutex

// CaptureExecutionTrace captures an execution trace for the specified duration and writes it to path.
// Thread-safe: only one execution trace can be active at any given time.
func CaptureExecutionTrace(path string, duration time.Duration) error {
	traceMu.Lock()
	defer traceMu.Unlock()

	f, err := os.Create(path)
	if err != nil {
		return fmt.Errorf("create trace file: %w", err)
	}
	defer f.Close()

	if err := trace.Start(f); err != nil {
		return fmt.Errorf("start trace: %w", err)
	}

	time.Sleep(duration)
	trace.Stop()
	return nil
}

// StreamExecutionTrace starts an execution trace streaming directly to w until stopCh is closed.
func StreamExecutionTrace(w io.Writer, stopCh <-chan struct{}) error {
	traceMu.Lock()
	defer traceMu.Unlock()

	if err := trace.Start(w); err != nil {
		return fmt.Errorf("start trace: %w", err)
	}
	defer trace.Stop()

	<-stopCh
	return nil
}
