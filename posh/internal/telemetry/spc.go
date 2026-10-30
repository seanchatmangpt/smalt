package telemetry

import (
	"math"
	"sync"
)

// SPCState maintains streaming statistical process control metrics using Welford's algorithm.
type SPCState struct {
	mu           sync.RWMutex
	count        uint64
	mean         float64
	m2           float64 // sum of squared differences from the mean
	ewma         float64
	alpha        float64
	lastValues   []float64 // sliding window for pattern detection (e.g. 9 consecutive)
	windowSize   int
	threeSigma   float64
	outOfControl bool
}

// NewSPCState constructs a streaming SPC accumulator.
func NewSPCState(alpha float64, windowSize int) *SPCState {
	if alpha <= 0 || alpha > 1 {
		alpha = 0.35
	}
	if windowSize <= 0 {
		windowSize = 20
	}
	return &SPCState{
		alpha:      alpha,
		windowSize: windowSize,
		lastValues: make([]float64, 0, windowSize),
	}
}

// Observe incorporates a new data point x in O(1) time and O(1) memory.
func (s *SPCState) Observe(x float64) (mean, stdDev, ewma float64, outOfControl bool) {
	s.mu.Lock()
	defer s.mu.Unlock()

	s.count++
	if s.count == 1 {
		s.mean = x
		s.m2 = 0
		s.ewma = x
	} else {
		delta := x - s.mean
		s.mean += delta / float64(s.count)
		delta2 := x - s.mean
		s.m2 += delta * delta2
		s.ewma = s.alpha*x + (1-s.alpha)*s.ewma
	}

	var variance float64
	if s.count > 1 {
		variance = s.m2 / float64(s.count-1)
	}
	stdDev = math.Sqrt(variance)
	s.threeSigma = 3.0 * stdDev

	// Manage sliding window for Shewhart rules
	if len(s.lastValues) >= s.windowSize {
		s.lastValues = s.lastValues[1:]
	}
	s.lastValues = append(s.lastValues, x)

	// Shewhart Rule 1: Point outside 3-sigma control limits
	s.outOfControl = false
	if s.count >= 10 && stdDev > 0 {
		z := math.Abs(x-s.mean) / stdDev
		if z >= 3.0 {
			s.outOfControl = true
		}
	}

	// Shewhart Rule 2: 9 points in a row on the same side of the mean
	if len(s.lastValues) >= 9 && s.count >= 10 {
		allAbove := true
		allBelow := true
		for _, v := range s.lastValues[len(s.lastValues)-9:] {
			if v <= s.mean {
				allAbove = false
			}
			if v >= s.mean {
				allBelow = false
			}
		}
		if allAbove || allBelow {
			s.outOfControl = true
		}
	}

	return s.mean, stdDev, s.ewma, s.outOfControl
}

// Summary returns current snapshot statistics.
func (s *SPCState) Summary() (count uint64, mean, stdDev, ewma float64, outOfControl bool) {
	s.mu.RLock()
	defer s.mu.RUnlock()

	var variance float64
	if s.count > 1 {
		variance = s.m2 / float64(s.count-1)
	}
	return s.count, s.mean, math.Sqrt(variance), s.ewma, s.outOfControl
}
