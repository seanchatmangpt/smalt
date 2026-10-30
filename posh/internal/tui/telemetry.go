package tui

import (
	"context"
	"time"

	"smalt.dev/posh/internal/doctor"
	"smalt.dev/posh/internal/metrics"
)

// TelemetrySnapshot aggregates live health, latency, and throughput metrics.
type TelemetrySnapshot struct {
	AndonStatus         string
	ThroughputReqPerSec float64
	TotalRequests       uint64
	P50Latency          time.Duration
	P95Latency          time.Duration
	P99Latency          time.Duration
	ActiveConnections   int64
	Uptime              time.Duration
	LastReloadTime      time.Time
	LastReloadDuration  time.Duration
	RecentLogs          []string
	DoctorProbes        []doctor.ProbeResult

	// PoshSections carries (section, verdict, detail) rows from the
	// membrane-owned status surface (scripts/posh_status.sh --json). Empty
	// until a ScriptStatusSource has produced a good snapshot.
	PoshSections []PoshSection
	// DxRows carries per-gate SPC rows from scripts/dx_report.py --json.
	DxRows []DxRow
}

// PoshSection is one typed verdict line from posh_status.sh --json.
type PoshSection struct {
	Section string `json:"section"`
	Verdict string `json:"verdict"` // OK | WARN | FAIL | SKIP
	Detail  string `json:"detail"`
}

// DxRow is one per-gate SPC row from dx_report.py --json.
type DxRow struct {
	Gate    string   `json:"gate"`
	N       int      `json:"n"`
	PassPct float64  `json:"pass_pct"`
	Fail    int      `json:"fail"`
	Skip    int      `json:"skip"`
	P50Ms   *float64 `json:"p50_ms"`
	P99Ms   *float64 `json:"p99_ms"`
	BF      int      `json:"bf"`
}

// TelemetrySource provides telemetry snapshots to the TUI.
type TelemetrySource interface {
	Snapshot(ctx context.Context) TelemetrySnapshot
}

// DirectMetricsSource derives telemetry directly from in-memory metrics and doctor.
type DirectMetricsSource struct {
	Registry  *metrics.Registry
	DoctorOpt doctor.Options
	StartTime time.Time

	lastDoctorRun time.Time
	cachedProbes  []doctor.ProbeResult
	cachedAndon   string
}

// NewDirectMetricsSource returns a live poller attached to a metrics registry.
func NewDirectMetricsSource(reg *metrics.Registry, docOpt doctor.Options) *DirectMetricsSource {
	return &DirectMetricsSource{
		Registry:      reg,
		DoctorOpt:     docOpt,
		StartTime:     time.Now(),
		lastDoctorRun: time.Time{},
	}
}

// Snapshot captures the current metrics and throttles Doctor execution to every 3 seconds.
func (s *DirectMetricsSource) Snapshot(ctx context.Context) TelemetrySnapshot {
	now := time.Now()
	var (
		reqSec float64
		tot    uint64
		p50    time.Duration
		p95    time.Duration
		p99    time.Duration
		conns  int64
	)

	if s.Registry != nil {
		reqSec, tot = s.Registry.Throughput()
		p50, p95, p99 = s.Registry.Quantiles()
		conns = s.Registry.ActiveConns()
	}

	// Throttle doctor probe runs to avoid heavy disk statfs/binary checks on every tick
	if now.Sub(s.lastDoctorRun) > 3*time.Second {
		rep := doctor.Run(ctx, s.DoctorOpt)
		s.cachedProbes = rep.Probes
		s.cachedAndon = rep.OverallStatus
		s.lastDoctorRun = now
	}

	return TelemetrySnapshot{
		AndonStatus:         s.cachedAndon,
		ThroughputReqPerSec: reqSec,
		TotalRequests:       tot,
		P50Latency:          p50,
		P95Latency:          p95,
		P99Latency:          p99,
		ActiveConnections:   conns,
		Uptime:              now.Sub(s.StartTime),
		DoctorProbes:        s.cachedProbes,
	}
}

// CompositeSource merges multiple TelemetrySources. Sources are applied in
// order; a later source's non-zero fields win. This composes the in-process
// DirectMetricsSource (throughput/quantiles/conns) with the membrane-owned
// ScriptStatusSource (andon + section verdicts) — the TUI is a renderer over
// posh_status.sh, never a second source of truth (gap 07, seam 3).
type CompositeSource struct {
	sources []TelemetrySource
}

// NewCompositeSource builds a composite over the given sources, in priority
// order (later sources override earlier non-zero fields).
func NewCompositeSource(sources ...TelemetrySource) *CompositeSource {
	return &CompositeSource{sources: sources}
}

// Snapshot folds every source's snapshot into one, later-wins per field.
func (c *CompositeSource) Snapshot(ctx context.Context) TelemetrySnapshot {
	var out TelemetrySnapshot
	for _, src := range c.sources {
		if src == nil {
			continue
		}
		s := src.Snapshot(ctx)
		if s.AndonStatus != "" {
			out.AndonStatus = s.AndonStatus
		}
		if s.ThroughputReqPerSec != 0 {
			out.ThroughputReqPerSec = s.ThroughputReqPerSec
		}
		if s.TotalRequests != 0 {
			out.TotalRequests = s.TotalRequests
		}
		if s.P50Latency != 0 {
			out.P50Latency = s.P50Latency
		}
		if s.P95Latency != 0 {
			out.P95Latency = s.P95Latency
		}
		if s.P99Latency != 0 {
			out.P99Latency = s.P99Latency
		}
		if s.ActiveConnections != 0 {
			out.ActiveConnections = s.ActiveConnections
		}
		if s.Uptime != 0 {
			out.Uptime = s.Uptime
		}
		if len(s.DoctorProbes) != 0 {
			out.DoctorProbes = s.DoctorProbes
		}
		if len(s.PoshSections) != 0 {
			out.PoshSections = s.PoshSections
		}
		if len(s.DxRows) != 0 {
			out.DxRows = s.DxRows
		}
		if len(s.RecentLogs) != 0 {
			out.RecentLogs = s.RecentLogs
		}
	}
	return out
}
