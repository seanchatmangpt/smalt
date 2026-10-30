// Package metrics implements the minimal Prometheus-text metrics registry
// for the POSH membrane: counters keyed by (name, sorted label set),
// rendered on scrape. Collection is mutex-guarded increments; the /metrics
// *endpoint* is never default-on (gated behind POSH_METRICS_ADDR in cmd/posh).
package metrics

import (
	"fmt"
	"net/http"
	"sort"
	"strings"
	"sync"
	"sync/atomic"
	"time"
)

// Registry holds counters by (metric name, label set), plus active connection
// tracking and rolling latency percentiles.
type Registry struct {
	mu       sync.Mutex
	counters map[string]map[string]*uint64

	activeConns atomic.Int64
	totalReqs   atomic.Uint64

	// Sliding window reservoir for latency percentiles (p50, p95, p99)
	resMu      sync.RWMutex
	samples    []time.Duration
	sampleIdx  int
	maxSamples int

	lastThroughputCalc time.Time
	lastTotalReqs      uint64
	currentReqPerSec   float64
}

// New returns an empty registry.
func New() *Registry {
	return &Registry{
		counters:           map[string]map[string]*uint64{},
		samples:            make([]time.Duration, 0, 2048),
		maxSamples:         2048,
		lastThroughputCalc: time.Now(),
	}
}

// IncConn increments the active connection gauge.
func (r *Registry) IncConn() {
	r.activeConns.Add(1)
}

// DecConn decrements the active connection gauge.
func (r *Registry) DecConn() {
	r.activeConns.Add(-1)
}

// ActiveConns returns the instantaneous active connection count.
func (r *Registry) ActiveConns() int64 {
	c := r.activeConns.Load()
	if c < 0 {
		return 0
	}
	return c
}

// RecordDuration records a request duration sample in the sliding reservoir.
func (r *Registry) RecordDuration(d time.Duration) {
	r.totalReqs.Add(1)

	r.resMu.Lock()
	defer r.resMu.Unlock()

	if len(r.samples) < r.maxSamples {
		r.samples = append(r.samples, d)
	} else {
		r.samples[r.sampleIdx] = d
		r.sampleIdx = (r.sampleIdx + 1) % r.maxSamples
	}
}

// Quantiles calculates p50, p95, and p99 percentiles from the current reservoir.
func (r *Registry) Quantiles() (p50, p95, p99 time.Duration) {
	r.resMu.RLock()
	n := len(r.samples)
	if n == 0 {
		r.resMu.RUnlock()
		return 0, 0, 0
	}
	cpy := make([]time.Duration, n)
	copy(cpy, r.samples)
	r.resMu.RUnlock()

	sort.Slice(cpy, func(i, j int) bool { return cpy[i] < cpy[j] })

	idxP50 := int(float64(n) * 0.50)
	idxP95 := int(float64(n) * 0.95)
	idxP99 := int(float64(n) * 0.99)

	if idxP50 >= n {
		idxP50 = n - 1
	}
	if idxP95 >= n {
		idxP95 = n - 1
	}
	if idxP99 >= n {
		idxP99 = n - 1
	}

	return cpy[idxP50], cpy[idxP95], cpy[idxP99]
}

// Throughput computes the current requests/sec throughput rate.
func (r *Registry) Throughput() (reqPerSec float64, total uint64) {
	r.mu.Lock()
	defer r.mu.Unlock()

	now := time.Now()
	elapsed := now.Sub(r.lastThroughputCalc)
	curTotal := r.totalReqs.Load()

	if elapsed >= 500*time.Millisecond {
		delta := curTotal - r.lastTotalReqs
		r.currentReqPerSec = float64(delta) / elapsed.Seconds()
		r.lastTotalReqs = curTotal
		r.lastThroughputCalc = now
	}

	return r.currentReqPerSec, curTotal
}

// Inc increments the counter `name` with the given real label set by one.
// The registry owns all storage; the labels map is not retained.
func (r *Registry) Inc(name string, labels map[string]string) {
	key := labelKey(labels)
	r.mu.Lock()
	defer r.mu.Unlock()
	byLabels, ok := r.counters[name]
	if !ok {
		byLabels = map[string]*uint64{}
		r.counters[name] = byLabels
	}
	p, ok := byLabels[key]
	if !ok {
		var v uint64
		p = &v
		byLabels[key] = p
	}
	*p++
}

// Render emits the registry in Prometheus text format (0.0.4): one
// "# TYPE <name> counter" line per metric name, followed by one sample per
// label set, both sorted for deterministic output.
func (r *Registry) Render() string {
	r.mu.Lock()
	defer r.mu.Unlock()
	names := make([]string, 0, len(r.counters))
	for name := range r.counters {
		names = append(names, name)
	}
	sort.Strings(names)
	var b strings.Builder
	for _, name := range names {
		fmt.Fprintf(&b, "# TYPE %s counter\n", name)
		keys := make([]string, 0, len(r.counters[name]))
		for k := range r.counters[name] {
			keys = append(keys, k)
		}
		sort.Strings(keys)
		for _, k := range keys {
			if k == "" {
				fmt.Fprintf(&b, "%s %d\n", name, *r.counters[name][k])
			} else {
				fmt.Fprintf(&b, "%s{%s} %d\n", name, k, *r.counters[name][k])
			}
		}
	}
	return b.String()
}

// labelKey builds the canonical string key for a label set: labels sorted
// by key, rendered as key="value" pairs joined by commas. Empty label sets
// render as "" so a bare sample line has no braces appended (see Render —
// callers pass only non-empty label sets today).
func labelKey(labels map[string]string) string {
	if len(labels) == 0 {
		return ""
	}
	keys := make([]string, 0, len(labels))
	for k := range labels {
		keys = append(keys, k)
	}
	sort.Strings(keys)
	pairs := make([]string, 0, len(keys))
	for _, k := range keys {
		pairs = append(pairs, fmt.Sprintf(`%s=%q`, k, labels[k]))
	}
	return strings.Join(pairs, ",")
}

// ServeHTTP renders the registry as Prometheus text, Content-Type per the
// text-format spec.
func (r *Registry) ServeHTTP(w http.ResponseWriter, _ *http.Request) {
	w.Header().Set("Content-Type", "text/plain; version=0.0.4; charset=utf-8")
	fmt.Fprint(w, r.Render())
}
