// Package andon implements the POSH Andon Signal Protocol
// (docs/jira/posh/v26.10.30/dfcharter/andon.md): per-gate signal state
// machine with RED latch and N=2 distinct-SHA hysteresis, JSONL receipt
// chain as the register of truth, and MAX composite evaluation.
package andon

import "fmt"

// State is the published andon signal for a gate or the composite.
type State int

const (
	GREEN State = iota
	YELLOW
	RED
)

func (s State) String() string {
	switch s {
	case GREEN:
		return "GREEN"
	case YELLOW:
		return "YELLOW"
	case RED:
		return "RED"
	default:
		return fmt.Sprintf("State(%d)", int(s))
	}
}

// Max returns the strict composite MAX over the ordered signals
// GREEN < YELLOW < RED (charter-master.md §6).
func Max(states ...State) State {
	m := GREEN
	for _, s := range states {
		if s > m {
			m = s
		}
	}
	return m
}

// ParseState parses a signal name; ok is false for unknown names.
func ParseState(name string) (State, bool) {
	switch name {
	case "GREEN":
		return GREEN, true
	case "YELLOW":
		return YELLOW, true
	case "RED":
		return RED, true
	default:
		return GREEN, false
	}
}

// Outcome is a gate-run observed outcome (spec §5 field rules).
type Outcome string

const (
	OutcomePass    Outcome = "pass"
	OutcomeWarn    Outcome = "warn"
	OutcomeFail    Outcome = "fail"
	OutcomeTimeout Outcome = "timeout"
	OutcomeSkip    Outcome = "skip"
	OutcomeBlocked Outcome = "blocked"
)

// stateForOutcome maps an observed outcome to a published signal per the
// transition table (spec §1): pass -> GREEN, warn -> YELLOW,
// fail/timeout -> RED (latched). skip/blocked hold the current signal.
func stateForOutcome(o Outcome) (State, bool) {
	switch o {
	case OutcomePass:
		return GREEN, true
	case OutcomeWarn:
		return YELLOW, true
	case OutcomeFail, OutcomeTimeout:
		return RED, true
	default:
		return GREEN, false
	}
}
