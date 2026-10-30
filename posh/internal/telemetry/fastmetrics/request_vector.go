package fastmetrics

import (
	"sync"
)

// RequestVector provides specialized, zero-allocation recording for
// the membrane request counter: `posh_requests_total{code=...,op=...,transport=...}`.
type RequestVector struct {
	vec   *Vector
	mu    sync.RWMutex
	cache map[string]*Series
}

// NewRequestVector creates and pre-warms a RequestVector for standard membrane ops.
func NewRequestVector(knownOps []string) *RequestVector {
	vec := NewVector("posh_requests_total", "Total completed membrane requests")
	rv := &RequestVector{
		vec:   vec,
		cache: make(map[string]*Series),
	}

	transports := []string{"uds", "tcp"}
	codes := []string{"OK", "TRANSPORT", "UPSTREAM", "DEADLINE", "REFUSED_EGRESS"}

	// Pre-register and cache all standard permutations so hot path is zero-alloc
	for _, op := range knownOps {
		for _, tr := range transports {
			for _, cd := range codes {
				s := vec.RegisterSeries(
					Label{Key: "code", Value: cd},
					Label{Key: "op", Value: op},
					Label{Key: "transport", Value: tr},
				)
				key := reqKey(op, tr, cd)
				rv.cache[key] = s
			}
		}
	}
	return rv
}

func reqKey(op, transport, code string) string {
	return op + "|" + transport + "|" + code
}

// Record increments the counter for the given (op, transport, code).
// If the tuple is pre-warmed, this is guaranteed zero heap allocations.
func (rv *RequestVector) Record(op, transport, code string) {
	key := reqKey(op, transport, code)
	rv.mu.RLock()
	s, ok := rv.cache[key]
	rv.mu.RUnlock()

	if ok {
		s.Inc()
		return
	}

	// Cold path: dynamic registration
	rv.mu.Lock()
	defer rv.mu.Unlock()
	if s, ok = rv.cache[key]; ok {
		s.Inc()
		return
	}

	s = rv.vec.RegisterSeries(
		Label{Key: "code", Value: code},
		Label{Key: "op", Value: op},
		Label{Key: "transport", Value: transport},
	)
	rv.cache[key] = s
	s.Inc()
}

// Vector returns the underlying Vector.
func (rv *RequestVector) Vector() *Vector {
	return rv.vec
}
