package fastmetrics

import (
	"sync"
)

// DenseRequestVector provides guaranteed zero-allocation recording on the hot path
// by using direct array indexing across [opIndex][transportIndex][codeIndex].
type DenseRequestVector struct {
	vec        *Vector
	opIndexMap map[string]int
	table      [][2][6]*Series // [op][uds=0,tcp=1][code(0..5)]
	fallbackMu sync.RWMutex
	fallback   map[string]*Series
}

var standardCodes = [...]string{
	"OK",
	"TRANSPORT",
	"UPSTREAM",
	"DEADLINE",
	"REFUSED_EGRESS",
	"OTHER",
}

func codeToIndex(code string) int {
	switch code {
	case "OK":
		return 0
	case "TRANSPORT":
		return 1
	case "UPSTREAM":
		return 2
	case "DEADLINE":
		return 3
	case "REFUSED_EGRESS":
		return 4
	default:
		return 5
	}
}

func transportToIndex(transport string) int {
	if transport == "uds" {
		return 0
	}
	return 1
}

// NewDenseRequestVector pre-warms a complete 3D array of Series for zero-alloc hot path increments.
func NewDenseRequestVector(knownOps []string) *DenseRequestVector {
	vec := NewVector("posh_requests_total", "Total completed membrane requests")
	opMap := make(map[string]int, len(knownOps))
	for i, op := range knownOps {
		opMap[op] = i
	}

	table := make([][2][6]*Series, len(knownOps))
	transports := [2]string{"uds", "tcp"}

	for opIdx, op := range knownOps {
		for trIdx, tr := range transports {
			for cdIdx, cd := range standardCodes {
				s := vec.RegisterSeries(
					Label{Key: "code", Value: cd},
					Label{Key: "op", Value: op},
					Label{Key: "transport", Value: tr},
				)
				table[opIdx][trIdx][cdIdx] = s
			}
		}
	}

	return &DenseRequestVector{
		vec:        vec,
		opIndexMap: opMap,
		table:      table,
		fallback:   make(map[string]*Series),
	}
}

// Record increments the counter with absolute ZERO heap allocations and ZERO locks
// for all pre-registered ops and standard transports/codes.
func (dv *DenseRequestVector) Record(op, transport, code string) {
	opIdx, ok := dv.opIndexMap[op]
	if ok {
		trIdx := transportToIndex(transport)
		cdIdx := codeToIndex(code)
		dv.table[opIdx][trIdx][cdIdx].Inc()
		return
	}

	// Dynamic fallback for unknown ops
	k := op + "|" + transport + "|" + code
	dv.fallbackMu.RLock()
	s, exists := dv.fallback[k]
	dv.fallbackMu.RUnlock()
	if exists {
		s.Inc()
		return
	}

	dv.fallbackMu.Lock()
	defer dv.fallbackMu.Unlock()
	if s, exists = dv.fallback[k]; exists {
		s.Inc()
		return
	}
	s = dv.vec.RegisterSeries(
		Label{Key: "code", Value: code},
		Label{Key: "op", Value: op},
		Label{Key: "transport", Value: transport},
	)
	dv.fallback[k] = s
	s.Inc()
}

// Vector returns the underlying Vector.
func (dv *DenseRequestVector) Vector() *Vector {
	return dv.vec
}
