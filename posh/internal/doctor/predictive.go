package doctor

import (
	"fmt"
	"sort"
	"sync"
	"time"

	"smalt.dev/posh/internal/diag"
)

// ResourceSample records an observed metric value at an exact wall-clock timestamp.
type ResourceSample struct {
	Timestamp time.Time `json:"timestamp"`
	Value     float64   `json:"value"`
	Ceiling   float64   `json:"ceiling"`
}

// PredictiveConfig defines operational parameters for the EWMA derivative forecast engine.
type PredictiveConfig struct {
	SampleWindow       time.Duration `json:"sample_window"`         // History window retained for trend analysis (default 5m)
	Alpha              float64       `json:"alpha"`                 // EWMA smoothing factor for derivative (0 < alpha <= 1.0, default 0.35)
	WarningHorizonSec  float64       `json:"warning_horizon_sec"`   // Jidoka YELLOW warning threshold in seconds (default 60.0s)
	CriticalHorizonSec float64       `json:"critical_horizon_sec"`  // Jidoka RED line-stop threshold in seconds (default 15.0s)
	MinSamples         int           `json:"min_samples"`           // Minimum samples required to compute derivative (default 2)
}

// DefaultPredictiveConfig returns standard TPS Jidoka thresholds.
func DefaultPredictiveConfig() PredictiveConfig {
	return PredictiveConfig{
		SampleWindow:       5 * time.Minute,
		Alpha:              0.35,
		WarningHorizonSec:  60.0,
		CriticalHorizonSec: 15.0,
		MinSamples:         2,
	}
}

// TrendAssessment captures the detailed rate-of-change and exhaustion forecast for a specific resource.
type TrendAssessment struct {
	MetricName          string        `json:"metric_name"`
	CurrentValue        float64       `json:"current_value"`
	Ceiling             float64       `json:"ceiling"`
	Headroom            float64       `json:"headroom"`
	HeadroomRatio       float64       `json:"headroom_ratio"`
	EWMADerivative      float64       `json:"ewma_derivative"`      // Units consumed per second (smoothed)
	InstantaneousRate   float64       `json:"instantaneous_rate"`  // Raw rate between last two samples (units/sec)
	ProjectedExhaustion time.Duration `json:"projected_exhaustion"` // Estimated time until exhaustion
	TimeToExhaustionSec float64       `json:"time_to_exhaustion_sec"`
	Status              string        `json:"status"` // GREEN, YELLOW, RED
	SampleCount         int           `json:"sample_count"`
	WarningMessage      string        `json:"warning_message,omitempty"`
}

// PredictiveTelemetry aggregates multi-resource trend assessments and diagnostic summaries.
type PredictiveTelemetry struct {
	EvaluatedAt    time.Time       `json:"evaluated_at"`
	OverallStatus  string          `json:"overall_status"`
	FD             TrendAssessment `json:"fd"`
	SocketBuffer   TrendAssessment `json:"socket_buffer"`
	Summary        string          `json:"summary"`
	WhatBroke      string          `json:"what_broke,omitempty"`
	Invariant      string          `json:"invariant"`
	RootCause5Whys string          `json:"root_cause_5_whys,omitempty"`
	Prescription   string          `json:"prescription,omitempty"`
}

// PredictiveEngine provides concurrent-safe telemetry ingestion and EWMA trend evaluation.
type PredictiveEngine struct {
	mu         sync.RWMutex
	config     PredictiveConfig
	fdSeries   []ResourceSample
	sockSeries []ResourceSample
}

// NewPredictiveEngine initializes a PredictiveEngine with the specified configuration.
func NewPredictiveEngine(cfg PredictiveConfig) *PredictiveEngine {
	if cfg.Alpha <= 0 || cfg.Alpha > 1.0 {
		cfg.Alpha = 0.35
	}
	if cfg.SampleWindow <= 0 {
		cfg.SampleWindow = 5 * time.Minute
	}
	if cfg.WarningHorizonSec <= 0 {
		cfg.WarningHorizonSec = 60.0
	}
	if cfg.CriticalHorizonSec <= 0 {
		cfg.CriticalHorizonSec = 15.0
	}
	if cfg.MinSamples < 2 {
		cfg.MinSamples = 2
	}
	return &PredictiveEngine{
		config:     cfg,
		fdSeries:   make([]ResourceSample, 0, 64),
		sockSeries: make([]ResourceSample, 0, 64),
	}
}

// Global ambient default engine.
var DefaultPredictiveEngine = NewPredictiveEngine(DefaultPredictiveConfig())

// Reset clears all historical series in the engine.
func (pe *PredictiveEngine) Reset() {
	pe.mu.Lock()
	defer pe.mu.Unlock()
	pe.fdSeries = pe.fdSeries[:0]
	pe.sockSeries = pe.sockSeries[:0]
}

// SampleCount returns the total number of recorded samples across all metrics.
func (pe *PredictiveEngine) SampleCount() int {
	pe.mu.RLock()
	defer pe.mu.RUnlock()
	return len(pe.fdSeries) + len(pe.sockSeries)
}

// RecordFDSample records an open file descriptor observation.
func (pe *PredictiveEngine) RecordFDSample(val, ceiling float64, t time.Time) {
	pe.mu.Lock()
	defer pe.mu.Unlock()
	pe.fdSeries = append(pe.fdSeries, ResourceSample{
		Timestamp: t,
		Value:     val,
		Ceiling:   ceiling,
	})
	pe.pruneLocked(&pe.fdSeries, t)
}

// RecordSocketBufferSample records a socket buffer queue depth observation.
func (pe *PredictiveEngine) RecordSocketBufferSample(val, ceiling float64, t time.Time) {
	pe.mu.Lock()
	defer pe.mu.Unlock()
	pe.sockSeries = append(pe.sockSeries, ResourceSample{
		Timestamp: t,
		Value:     val,
		Ceiling:   ceiling,
	})
	pe.pruneLocked(&pe.sockSeries, t)
}

func (pe *PredictiveEngine) pruneLocked(series *[]ResourceSample, now time.Time) {
	if len(*series) == 0 {
		return
	}
	cutoff := now.Add(-pe.config.SampleWindow)
	idx := 0
	for idx < len(*series) && (*series)[idx].Timestamp.Before(cutoff) {
		idx++
	}
	if idx > 0 {
		copy(*series, (*series)[idx:])
		*series = (*series)[:len(*series)-idx]
	}
}

// CalculateEWMADerivative computes the EWMA of instantaneous derivatives across chronological samples.
// Returns ewmaDerivative, instantaneousRate, and ok.
func CalculateEWMADerivative(samples []ResourceSample, alpha float64) (float64, float64, bool) {
	if len(samples) < 2 {
		return 0, 0, false
	}

	// Sort samples chronologically if not already strictly ordered
	ordered := make([]ResourceSample, len(samples))
	copy(ordered, samples)
	sort.Slice(ordered, func(i, j int) bool {
		return ordered[i].Timestamp.Before(ordered[j].Timestamp)
	})

	var ewma float64
	var lastRate float64
	hasRate := false

	for i := 1; i < len(ordered); i++ {
		prev := ordered[i-1]
		curr := ordered[i]
		dt := curr.Timestamp.Sub(prev.Timestamp).Seconds()
		if dt <= 0 {
			continue
		}
		dy := curr.Value - prev.Value
		rate := dy / dt
		lastRate = rate

		if !hasRate {
			ewma = rate
			hasRate = true
		} else {
			ewma = alpha*rate + (1.0-alpha)*ewma
		}
	}

	return ewma, lastRate, hasRate
}

// EvaluateSeries performs EWMA trend and time-to-exhaustion analysis on a resource series.
func (pe *PredictiveEngine) EvaluateSeries(name string, series []ResourceSample, now time.Time) TrendAssessment {
	if len(series) == 0 {
		return TrendAssessment{
			MetricName:          name,
			Status:              StatusGreen,
			SampleCount:         0,
			TimeToExhaustionSec: -1.0,
			WarningMessage:      "no telemetry samples recorded",
		}
	}

	latest := series[len(series)-1]
	headroom := latest.Ceiling - latest.Value
	headroomRatio := 0.0
	if latest.Ceiling > 0 {
		headroomRatio = headroom / latest.Ceiling
	}

	assessment := TrendAssessment{
		MetricName:          name,
		CurrentValue:        latest.Value,
		Ceiling:             latest.Ceiling,
		Headroom:            headroom,
		HeadroomRatio:       headroomRatio,
		SampleCount:         len(series),
		Status:              StatusGreen,
		TimeToExhaustionSec: -1.0,
	}

	// Immediate ceiling breach -> RED
	if latest.Ceiling > 0 && latest.Value >= latest.Ceiling {
		assessment.Status = StatusRed
		assessment.TimeToExhaustionSec = 0
		assessment.ProjectedExhaustion = 0
		assessment.WarningMessage = fmt.Sprintf("CRITICAL: %s reached or exceeded ceiling (current=%.0f, ceiling=%.0f)",
			name, latest.Value, latest.Ceiling)
		return assessment
	}

	if len(series) < pe.config.MinSamples {
		assessment.WarningMessage = fmt.Sprintf("baseline established (%d sample)", len(series))
		return assessment
	}

	ewma, lastRate, ok := CalculateEWMADerivative(series, pe.config.Alpha)
	if !ok {
		assessment.WarningMessage = "insufficient time variance between samples"
		return assessment
	}

	assessment.EWMADerivative = ewma
	assessment.InstantaneousRate = lastRate

	// If rate is non-positive, consumption is flat or decreasing (nominal)
	if ewma <= 0.000001 {
		assessment.Status = StatusGreen
		assessment.TimeToExhaustionSec = -1.0
		assessment.WarningMessage = fmt.Sprintf("consumption rate non-increasing (ewma=%.2f/s)", ewma)
		return assessment
	}

	// Rate is positive: project time to exhaustion
	tteSec := headroom / ewma
	assessment.TimeToExhaustionSec = tteSec
	assessment.ProjectedExhaustion = time.Duration(tteSec * float64(time.Second))

	if tteSec <= pe.config.CriticalHorizonSec {
		assessment.Status = StatusRed
		assessment.WarningMessage = fmt.Sprintf("CRITICAL exhaustion imminent: %s growing at %.2f units/s, exhaustion in %.1fs (< %.0fs critical threshold)",
			name, ewma, tteSec, pe.config.CriticalHorizonSec)
	} else if tteSec <= pe.config.WarningHorizonSec {
		assessment.Status = StatusYellow
		assessment.WarningMessage = fmt.Sprintf("Jidoka early warning: %s growing at %.2f units/s, exhaustion projected in %.1fs (< %.0fs warning horizon)",
			name, ewma, tteSec, pe.config.WarningHorizonSec)
	} else {
		assessment.Status = StatusGreen
		assessment.WarningMessage = fmt.Sprintf("growth rate nominal (ewma=%.2f/s, tte=%.1fs)", ewma, tteSec)
	}

	return assessment
}

// EvaluateFD evaluates the file descriptor trend.
func (pe *PredictiveEngine) EvaluateFD(now time.Time) TrendAssessment {
	pe.mu.RLock()
	defer pe.mu.RUnlock()
	return pe.EvaluateSeries("open_file_descriptors", pe.fdSeries, now)
}

// EvaluateSocketBuffer evaluates the socket buffer backlog trend.
func (pe *PredictiveEngine) EvaluateSocketBuffer(now time.Time) TrendAssessment {
	pe.mu.RLock()
	defer pe.mu.RUnlock()
	return pe.EvaluateSeries("socket_buffer_queue_depth", pe.sockSeries, now)
}

// Evaluate computes the full predictive assessment across all monitored resources.
func (pe *PredictiveEngine) Evaluate(now time.Time) PredictiveTelemetry {
	pe.mu.RLock()
	defer pe.mu.RUnlock()

	fdAssessment := pe.EvaluateSeries("open_file_descriptors", pe.fdSeries, now)
	sockAssessment := pe.EvaluateSeries("socket_buffer_queue_depth", pe.sockSeries, now)

	overall := StatusGreen
	var whatBroke string
	var why5 string
	var prescription string

	if fdAssessment.Status == StatusRed || sockAssessment.Status == StatusRed {
		overall = StatusRed
	} else if fdAssessment.Status == StatusYellow || sockAssessment.Status == StatusYellow {
		overall = StatusYellow
	}

	if overall == StatusRed {
		if fdAssessment.Status == StatusRed {
			whatBroke = fdAssessment.WarningMessage
			why5 = fmt.Sprintf("File descriptor consumption velocity (%.2f FDs/sec) breaches safety horizon; hard RLIMIT_NOFILE exhaustion imminent in %.1fs.",
				fdAssessment.EWMADerivative, fdAssessment.TimeToExhaustionSec)
			prescription = "lsof -p $(pgrep posh)  # identify leaked handles and increase limit with 'ulimit -n 65536'"
		} else {
			whatBroke = sockAssessment.WarningMessage
			why5 = fmt.Sprintf("Socket receive queue accumulation velocity (%.2f bytes/sec) breaches safety horizon; buffer overflow imminent in %.1fs.",
				sockAssessment.EWMADerivative, sockAssessment.TimeToExhaustionSec)
			prescription = "posh doctor --fix  # check for consumer stall and apply backpressure"
		}
	} else if overall == StatusYellow {
		if fdAssessment.Status == StatusYellow {
			d := diag.PredictiveExhaustion("open_file_descriptors", fdAssessment.EWMADerivative, fdAssessment.TimeToExhaustionSec, fdAssessment.Ceiling)
			whatBroke = d.Render(diag.ColorConfig{NoColor: true})
			why5 = fmt.Sprintf("EWMA derivative rate (%.2f FDs/sec) indicates sustained descriptor leak; RLIMIT_NOFILE (%0.f) projected to exhaust within %.1fs.",
				fdAssessment.EWMADerivative, fdAssessment.Ceiling, fdAssessment.TimeToExhaustionSec)
			prescription = "ulimit -n 65536  # or investigate unclosed HTTP/UDS connections in adapter"
		} else {
			d := diag.PredictiveExhaustion("socket_buffer_queue_depth", sockAssessment.EWMADerivative, sockAssessment.TimeToExhaustionSec, sockAssessment.Ceiling)
			whatBroke = d.Render(diag.ColorConfig{NoColor: true})
			why5 = fmt.Sprintf("EWMA derivative rate (%.2f bytes/sec) indicates producer outpacing consumer; kernel receive queue will saturate within %.1fs.",
				sockAssessment.EWMADerivative, sockAssessment.TimeToExhaustionSec)
			prescription = "posh doctor  # verify upstream BEAM flow control"
		}
	}

	summary := "resource consumption rates nominal (growth trajectory stable)"
	if overall == StatusYellow {
		if fdAssessment.Status == StatusYellow {
			summary = fmt.Sprintf("Jidoka [YELLOW]: FD exhaustion projected in %.1fs (rate=%.2f/s)",
				fdAssessment.TimeToExhaustionSec, fdAssessment.EWMADerivative)
		} else {
			summary = fmt.Sprintf("Jidoka [YELLOW]: socket buffer exhaustion projected in %.1fs (rate=%.2f/s)",
				sockAssessment.TimeToExhaustionSec, sockAssessment.EWMADerivative)
		}
	} else if overall == StatusRed {
		summary = "Jidoka [RED]: critical resource exhaustion projected within critical safety threshold"
	}

	return PredictiveTelemetry{
		EvaluatedAt:    now,
		OverallStatus:  overall,
		FD:             fdAssessment,
		SocketBuffer:   sockAssessment,
		Summary:        summary,
		WhatBroke:      whatBroke,
		Invariant:      "TPS-JIDOKA-PREDICTIVE Resource Exhaustion Forecast",
		RootCause5Whys: why5,
		Prescription:   prescription,
	}
}
