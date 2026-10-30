package doctor_test

import (
	"math"
	"strings"
	"sync"
	"testing"
	"time"

	"smalt.dev/posh/internal/doctor"
)

func TestCalculateEWMADerivativeLinearSequence(t *testing.T) {
	// Baseline linear growth: 10 units per second
	// t=0: v=100
	// t=1: v=110 (rate = 10)
	// t=2: v=120 (rate = 10)
	// t=3: v=130 (rate = 10)
	t0 := time.Now()
	samples := []doctor.ResourceSample{
		{Timestamp: t0, Value: 100, Ceiling: 1000},
		{Timestamp: t0.Add(1 * time.Second), Value: 110, Ceiling: 1000},
		{Timestamp: t0.Add(2 * time.Second), Value: 120, Ceiling: 1000},
		{Timestamp: t0.Add(3 * time.Second), Value: 130, Ceiling: 1000},
	}

	ewma, lastRate, ok := doctor.CalculateEWMADerivative(samples, 0.4)
	if !ok {
		t.Fatalf("expected CalculateEWMADerivative ok=true")
	}
	if math.Abs(ewma-10.0) > 0.001 {
		t.Fatalf("expected EWMA derivative = 10.0, got %f", ewma)
	}
	if math.Abs(lastRate-10.0) > 0.001 {
		t.Fatalf("expected lastRate = 10.0, got %f", lastRate)
	}
}

func TestCalculateEWMADerivativeStepChange(t *testing.T) {
	// Step change: starts at 0, sudden surge to 50 units/sec
	t0 := time.Now()
	samples := []doctor.ResourceSample{
		{Timestamp: t0, Value: 100, Ceiling: 1000},
		{Timestamp: t0.Add(1 * time.Second), Value: 100, Ceiling: 1000}, // rate = 0
		{Timestamp: t0.Add(2 * time.Second), Value: 150, Ceiling: 1000}, // rate = 50
	}

	// alpha = 0.5: first valid rate=0, second step: 0.5*50 + 0.5*0 = 25
	ewma, lastRate, ok := doctor.CalculateEWMADerivative(samples, 0.5)
	if !ok {
		t.Fatalf("expected ok=true")
	}
	if math.Abs(ewma-25.0) > 0.001 {
		t.Fatalf("expected EWMA derivative = 25.0, got %f", ewma)
	}
	if math.Abs(lastRate-50.0) > 0.001 {
		t.Fatalf("expected lastRate = 50.0, got %f", lastRate)
	}
}

func TestPredictiveFDExhaustionYellowWarning(t *testing.T) {
	cfg := doctor.PredictiveConfig{
		SampleWindow:       1 * time.Minute,
		Alpha:              0.5,
		WarningHorizonSec:  60.0, // 60s Jidoka warning
		CriticalHorizonSec: 15.0,
		MinSamples:         2,
	}
	engine := doctor.NewPredictiveEngine(cfg)

	// Ceiling = 1024 FDs.
	// Current = 600 FDs. Headroom = 424 FDs.
	// Growth rate: 10 FDs/sec.
	// Projected TTE = 424 / 10 = 42.4 seconds (< 60s, > 15s) -> YELLOW!
	t0 := time.Now()
	engine.RecordFDSample(580, 1024, t0)
	engine.RecordFDSample(590, 1024, t0.Add(1*time.Second))
	engine.RecordFDSample(600, 1024, t0.Add(2*time.Second))

	telemetry := engine.Evaluate(t0.Add(2 * time.Second))

	if telemetry.OverallStatus != doctor.StatusYellow {
		t.Fatalf("expected overall status YELLOW, got %s (summary: %s)", telemetry.OverallStatus, telemetry.Summary)
	}
	if telemetry.FD.Status != doctor.StatusYellow {
		t.Fatalf("expected FD status YELLOW, got %s", telemetry.FD.Status)
	}
	if telemetry.FD.TimeToExhaustionSec > 60.0 || telemetry.FD.TimeToExhaustionSec < 35.0 {
		t.Fatalf("expected TTE around 42.4s, got %f", telemetry.FD.TimeToExhaustionSec)
	}
	// Verify Elm/Rust diagnostic output in WhatBroke
	if !strings.Contains(telemetry.WhatBroke, "error[E0501]") && !strings.Contains(telemetry.WhatBroke, "E0501") {
		t.Fatalf("expected WhatBroke to contain Elm/Rust diagnostic E0501, got:\n%s", telemetry.WhatBroke)
	}
	if !strings.Contains(telemetry.WhatBroke, "Predictive Resource Exhaustion") {
		t.Fatalf("expected diagnostic title in WhatBroke, got:\n%s", telemetry.WhatBroke)
	}
}

func TestPredictiveSocketBufferCriticalRed(t *testing.T) {
	cfg := doctor.PredictiveConfig{
		SampleWindow:       1 * time.Minute,
		Alpha:              0.5,
		WarningHorizonSec:  60.0,
		CriticalHorizonSec: 15.0, // < 15s -> RED
		MinSamples:         2,
	}
	engine := doctor.NewPredictiveEngine(cfg)

	// Buffer capacity = 100,000 bytes.
	// Current queue depth = 80,000 bytes. Headroom = 20,000 bytes.
	// Growth rate: 4,000 bytes / sec.
	// Projected TTE = 20,000 / 4,000 = 5.0 seconds (< 15s) -> RED!
	t0 := time.Now()
	engine.RecordSocketBufferSample(72000, 100000, t0)
	engine.RecordSocketBufferSample(76000, 100000, t0.Add(1*time.Second))
	engine.RecordSocketBufferSample(80000, 100000, t0.Add(2*time.Second))

	telemetry := engine.Evaluate(t0.Add(2 * time.Second))

	if telemetry.OverallStatus != doctor.StatusRed {
		t.Fatalf("expected overall status RED, got %s (summary: %s)", telemetry.OverallStatus, telemetry.Summary)
	}
	if telemetry.SocketBuffer.Status != doctor.StatusRed {
		t.Fatalf("expected SocketBuffer status RED, got %s", telemetry.SocketBuffer.Status)
	}
	if telemetry.SocketBuffer.TimeToExhaustionSec > 15.0 {
		t.Fatalf("expected TTE <= 15s, got %f", telemetry.SocketBuffer.TimeToExhaustionSec)
	}
}

func TestPredictiveFlatOrDecreasingGreen(t *testing.T) {
	engine := doctor.NewPredictiveEngine(doctor.DefaultPredictiveConfig())

	t0 := time.Now()
	// Decreasing FD count
	engine.RecordFDSample(200, 1024, t0)
	engine.RecordFDSample(190, 1024, t0.Add(1*time.Second))
	engine.RecordFDSample(180, 1024, t0.Add(2*time.Second))

	// Flat socket buffer
	engine.RecordSocketBufferSample(500, 65536, t0)
	engine.RecordSocketBufferSample(500, 65536, t0.Add(1*time.Second))
	engine.RecordSocketBufferSample(500, 65536, t0.Add(2*time.Second))

	telemetry := engine.Evaluate(t0.Add(2 * time.Second))

	if telemetry.OverallStatus != doctor.StatusGreen {
		t.Fatalf("expected GREEN status for non-increasing resources, got %s", telemetry.OverallStatus)
	}
	if telemetry.FD.TimeToExhaustionSec != -1.0 && telemetry.FD.TimeToExhaustionSec < 10000 {
		t.Fatalf("expected infinite/unbounded (-1.0) or large TTE, got %f", telemetry.FD.TimeToExhaustionSec)
	}
}

func TestPredictiveEngineWindowPruning(t *testing.T) {
	cfg := doctor.PredictiveConfig{
		SampleWindow: 10 * time.Second,
		Alpha:        0.5,
		MinSamples:   2,
	}
	engine := doctor.NewPredictiveEngine(cfg)

	t0 := time.Now()
	// Add 5 samples spaced 3 seconds apart
	for i := 0; i < 5; i++ {
		engine.RecordFDSample(float64(100+i*5), 1000, t0.Add(time.Duration(i*3)*time.Second))
	}

	// At t0 + 12s, samples older than t0 + 2s (t0 and t0+3s) should be pruned
	assessment := engine.EvaluateFD(t0.Add(12 * time.Second))
	if assessment.SampleCount > 4 {
		t.Fatalf("expected pruning to retain <= 4 samples within 10s window, got %d", assessment.SampleCount)
	}
}

func TestPredictiveEngineConcurrentRace(t *testing.T) {
	engine := doctor.NewPredictiveEngine(doctor.DefaultPredictiveConfig())
	var wg sync.WaitGroup

	stop := make(chan struct{})
	t0 := time.Now()

	// 5 writers recording FD samples
	for w := 0; w < 5; w++ {
		wg.Add(1)
		go func(id int) {
			defer wg.Done()
			step := 0
			for {
				select {
				case <-stop:
					return
				default:
					engine.RecordFDSample(float64(50+id*10+step), 2048, t0.Add(time.Duration(step)*time.Millisecond))
					engine.RecordSocketBufferSample(float64(100+id*5), 65536, t0.Add(time.Duration(step)*time.Millisecond))
					step++
					time.Sleep(1 * time.Millisecond)
				}
			}
		}(w)
	}

	// 5 readers evaluating trends concurrently
	for r := 0; r < 5; r++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			for {
				select {
				case <-stop:
					return
				default:
					_ = engine.Evaluate(time.Now())
					time.Sleep(2 * time.Millisecond)
				}
			}
		}()
	}

	time.Sleep(50 * time.Millisecond)
	close(stop)
	wg.Wait()
}

func BenchmarkCalculateEWMADerivative(b *testing.B) {
	t0 := time.Now()
	samples := make([]doctor.ResourceSample, 50)
	for i := range samples {
		samples[i] = doctor.ResourceSample{
			Timestamp: t0.Add(time.Duration(i) * time.Second),
			Value:     float64(100 + i*5),
			Ceiling:   1000,
		}
	}
	b.ResetTimer()
	b.ReportAllocs()
	for i := 0; i < b.N; i++ {
		_, _, _ = doctor.CalculateEWMADerivative(samples, 0.35)
	}
}

func BenchmarkPredictiveEngineEvaluate(b *testing.B) {
	engine := doctor.NewPredictiveEngine(doctor.DefaultPredictiveConfig())
	t0 := time.Now()
	for i := 0; i < 30; i++ {
		engine.RecordFDSample(float64(200+i*2), 1024, t0.Add(time.Duration(i)*time.Second))
		engine.RecordSocketBufferSample(float64(1000+i*50), 65536, t0.Add(time.Duration(i)*time.Second))
	}
	now := t0.Add(31 * time.Second)
	b.ResetTimer()
	b.ReportAllocs()
	for i := 0; i < b.N; i++ {
		_ = engine.Evaluate(now)
	}
}

