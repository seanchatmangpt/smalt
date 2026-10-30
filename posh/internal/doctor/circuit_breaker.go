package doctor

import (
	"errors"
	"fmt"
	"sync"
	"time"
)

// CircuitState represents the TPS Andon operational state of a circuit breaker.
type CircuitState int

const (
	// CircuitClosed represents nominal operation (Andon GREEN).
	CircuitClosed CircuitState = iota
	// CircuitHalfOpen represents canary recovery testing (Andon YELLOW).
	CircuitHalfOpen
	// CircuitOpen represents line arrest / halted ingress (Andon RED).
	CircuitOpen
)

func (s CircuitState) String() string {
	switch s {
	case CircuitClosed:
		return "GREEN"
	case CircuitHalfOpen:
		return "YELLOW"
	case CircuitOpen:
		return "RED"
	default:
		return fmt.Sprintf("CircuitState(%d)", int(s))
	}
}

// ErrCircuitOpen is returned when the circuit breaker is latched RED, halting ingress traffic.
var ErrCircuitOpen = errors.New("circuit breaker latched RED: downstream substrate SLA breached, ingress halted")

// CircuitBreakerConfig configures a Jidoka circuit breaker.
type CircuitBreakerConfig struct {
	Name             string
	SLALatency       time.Duration // Maximum permitted latency per downstream call (e.g. 50ms)
	ErrorThreshold   int           // Consecutive failures or SLA breaches required to trip (e.g. 3)
	CooldownDuration time.Duration // Duration to stay latched RED before attempting HALF-OPEN canary (e.g. 5s)
	RequiredCanaries int           // Consecutive successful canary runs required to demote YELLOW to GREEN (N=2 hysteresis)
	Alpha            float64       // EWMA smoothing factor (e.g. 0.2)
	OnTransition     func(name string, from, to CircuitState, reason string)
}

// CircuitStats holds observable telemetry metrics of the circuit breaker.
type CircuitStats struct {
	Name            string  `json:"name"`
	State           string  `json:"state"`
	EWMALatencyMs   float64 `json:"ewma_latency_ms"`
	SLALatencyMs    float64 `json:"sla_latency_ms"`
	ConsecutiveErr  int     `json:"consecutive_err"`
	CanaryPassCount int     `json:"canary_pass_count"`
	TripCount       int     `json:"trip_count"`
	LastTransition  string  `json:"last_transition"`
	LastFailureMsg  string  `json:"last_failure_msg,omitempty"`
}

// CircuitBreaker implements the Jidoka Downstream Latency Fence.
type CircuitBreaker struct {
	mu sync.RWMutex

	name             string
	state            CircuitState
	slaLatency       time.Duration
	errorThreshold   int
	cooldownDuration time.Duration
	requiredCanaries int
	alpha            float64
	onTransition     func(name string, from, to CircuitState, reason string)

	ewmaLatency     time.Duration
	consecutiveErr  int
	canaryPasses    int
	tripCount       int
	lastStateChange time.Time
	lastFailureMsg  string
}

// NewCircuitBreaker constructs a new Jidoka CircuitBreaker.
func NewCircuitBreaker(cfg CircuitBreakerConfig) *CircuitBreaker {
	if cfg.Name == "" {
		cfg.Name = "downstream-substrate"
	}
	if cfg.SLALatency <= 0 {
		cfg.SLALatency = 50 * time.Millisecond
	}
	if cfg.ErrorThreshold <= 0 {
		cfg.ErrorThreshold = 3
	}
	if cfg.CooldownDuration <= 0 {
		cfg.CooldownDuration = 5 * time.Second
	}
	if cfg.RequiredCanaries <= 0 {
		cfg.RequiredCanaries = 2 // N=2 distinct-SHA hysteresis
	}
	if cfg.Alpha <= 0 || cfg.Alpha > 1.0 {
		cfg.Alpha = 0.2
	}

	return &CircuitBreaker{
		name:             cfg.Name,
		state:            CircuitClosed,
		slaLatency:       cfg.SLALatency,
		errorThreshold:   cfg.ErrorThreshold,
		cooldownDuration: cfg.CooldownDuration,
		requiredCanaries: cfg.RequiredCanaries,
		alpha:            cfg.Alpha,
		onTransition:     cfg.OnTransition,
		lastStateChange:  time.Now(),
	}
}

// Allow evaluates if a request should be admitted or fast-rejected.
func (cb *CircuitBreaker) Allow() error {
	cb.mu.Lock()
	defer cb.mu.Unlock()

	now := time.Now()
	switch cb.state {
	case CircuitClosed:
		return nil

	case CircuitOpen:
		// Check if cooldown has elapsed to attempt canary probe in HALF-OPEN
		if now.Sub(cb.lastStateChange) >= cb.cooldownDuration {
			cb.transitionTo(CircuitHalfOpen, "cooldown window elapsed; testing downstream with canary probes")
			cb.canaryPasses = 0
			return nil
		}
		return ErrCircuitOpen

	case CircuitHalfOpen:
		// In HALF-OPEN, admit canary probe
		return nil

	default:
		return nil
	}
}

// RecordSuccess records a completed downstream operation with observed latency.
func (cb *CircuitBreaker) RecordSuccess(latency time.Duration) {
	cb.mu.Lock()
	defer cb.mu.Unlock()

	// Update Exponential Weighted Moving Average (EWMA)
	if cb.ewmaLatency == 0 {
		cb.ewmaLatency = latency
	} else {
		cb.ewmaLatency = time.Duration(cb.alpha*float64(latency) + (1.0-cb.alpha)*float64(cb.ewmaLatency))
	}

	// Check if observed latency breached SLA
	if latency > cb.slaLatency {
		cb.recordFailureLocked(fmt.Sprintf("SLA breach: latency %v exceeded SLA threshold %v", latency, cb.slaLatency))
		return
	}

	cb.consecutiveErr = 0

	// If in HALF-OPEN, test canary recovery hysteresis (N=2)
	if cb.state == CircuitHalfOpen {
		cb.canaryPasses++
		if cb.canaryPasses >= cb.requiredCanaries {
			cb.transitionTo(CircuitClosed, fmt.Sprintf("N=%d consecutive canaries passed within SLA; circuit restored to GREEN", cb.requiredCanaries))
		}
	}
}

// RecordFailure records a downstream execution failure or timeout.
func (cb *CircuitBreaker) RecordFailure(reason string) {
	cb.mu.Lock()
	defer cb.mu.Unlock()
	cb.recordFailureLocked(reason)
}

func (cb *CircuitBreaker) recordFailureLocked(reason string) {
	cb.lastFailureMsg = reason
	cb.consecutiveErr++

	switch cb.state {
	case CircuitClosed:
		if cb.consecutiveErr >= cb.errorThreshold {
			cb.tripCount++
			cb.transitionTo(CircuitOpen, fmt.Sprintf("consecutive errors/breaches (%d) reached threshold (%d): %s",
				cb.consecutiveErr, cb.errorThreshold, reason))
		}

	case CircuitHalfOpen:
		// Any failure in canary state immediately re-trips back to RED
		cb.tripCount++
		cb.transitionTo(CircuitOpen, fmt.Sprintf("canary probe failed: %s; re-latching RED", reason))

	case CircuitOpen:
		// Already latched RED; update failure note
	}
}

func (cb *CircuitBreaker) transitionTo(next CircuitState, reason string) {
	prev := cb.state
	cb.state = next
	cb.lastStateChange = time.Now()

	if cb.onTransition != nil && prev != next {
		// Run callback asynchronously or synchronously safely
		fn := cb.onTransition
		name := cb.name
		go fn(name, prev, next, reason)
	}
}

// State reports the current circuit breaker state.
func (cb *CircuitBreaker) State() CircuitState {
	cb.mu.RLock()
	defer cb.mu.RUnlock()
	return cb.state
}

// Stats returns a snapshot of circuit breaker telemetry.
func (cb *CircuitBreaker) Stats() CircuitStats {
	cb.mu.RLock()
	defer cb.mu.RUnlock()

	return CircuitStats{
		Name:            cb.name,
		State:           cb.state.String(),
		EWMALatencyMs:   float64(cb.ewmaLatency.Microseconds()) / 1000.0,
		SLALatencyMs:    float64(cb.slaLatency.Microseconds()) / 1000.0,
		ConsecutiveErr:  cb.consecutiveErr,
		CanaryPassCount: cb.canaryPasses,
		TripCount:       cb.tripCount,
		LastTransition:  cb.lastStateChange.UTC().Format(time.RFC3339),
		LastFailureMsg:  cb.lastFailureMsg,
	}
}
