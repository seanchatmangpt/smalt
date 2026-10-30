package andon

// Machine evaluates per-gate signal transitions. prev_signal is read
// from the receipt chain (the register of truth), never from memory.
type Machine struct {
	App *Appender
}

// GateTransition is the result of applying one gate outcome.
type GateTransition struct {
	Gate       string
	Prev       State
	Signal     State
	Outcome    Outcome
	Reason     string
	Hysteresis int
}

// Apply runs the state machine for one gate run.
//
// Transitions (spec §1):
//
//	pass    (within SLA)   : any state -> GREEN, subject to hysteresis
//	warn    (within SLA)   : any state -> YELLOW
//	fail/timeout           : any state -> RED (latched)
//	skip/blocked           : hold current signal
//
// Latch and hysteresis:
//
//   - RED is latched for the subject's lifetime: a rerun over the SAME
//     subject SHA cannot clear it (even a pass holds RED).
//   - RED clears only via a changed subject SHA + a full GREEN run.
//   - YELLOW demotes to GREEN only after HysteresisN=2 consecutive
//     GREEN runs over DISTINCT subject SHAs; the GREEN signal is held
//     back (published YELLOW) until the second distinct-SHA GREEN.
func (m *Machine) Apply(gate string, outcome Outcome, subjectSHA, reason string) (GateTransition, error) {
	prev := GREEN
	if r, ok, err := m.App.LastGate(gate); err != nil {
		return GateTransition{}, err
	} else if ok {
		s, known := ParseState(r.Signal)
		if !known {
			return GateTransition{}, &CorruptSignalError{Gate: gate, Signal: r.Signal}
		}
		prev = s
	}

	tr := GateTransition{Gate: gate, Prev: prev, Outcome: outcome, Reason: reason}

	target, stateful := stateForOutcome(outcome)
	if !stateful {
		// skip/blocked: hold current signal, still receipted.
		tr.Signal = prev
		tr.Hysteresis = 0
		return tr, nil
	}

	switch prev {
	case RED:
		// Latched. Same-SHA rerun stays RED regardless of outcome.
		// Clear only via changed subject + full GREEN run.
		if target == GREEN && changedFromLastRed(m.App, gate, subjectSHA) {
			tr.Signal = GREEN
		} else {
			tr.Signal = RED
		}
		tr.Hysteresis = 0
	case YELLOW:
		if target == GREEN {
			// N=2 distinct-SHA hysteresis: count consecutive GREEN
			// runs over distinct SHAs while holding YELLOW.
			n, err := m.distinctGreenRunCount(gate, subjectSHA)
			if err != nil {
				return GateTransition{}, err
			}
			tr.Hysteresis = n
			if n >= HysteresisN {
				tr.Signal = GREEN
			} else {
				tr.Signal = YELLOW
			}
		} else {
			tr.Signal = target
			tr.Hysteresis = 0
		}
	default: // GREEN
		tr.Signal = target
		tr.Hysteresis = 0
	}
	return tr, nil
}

// changedFromLastRed reports whether sha differs from the subject SHA
// bound to the latch: the most recent RED receipt for gate. Rerunning
// the same subject that went RED cannot clear it (spec §1 anti-vacuity
// law); held-RED reruns must not move the latch's reference subject.
func changedFromLastRed(a *Appender, gate, sha string) bool {
	if sha == "" {
		return false
	}
	f, err := openIfExists(a.Path)
	if err != nil || f == nil {
		return true
	}
	defer f.Close()
	redSHA := ""
	sc := newLineScanner(f)
	for sc.Scan() {
		var r Receipt
		if err := jsonUnmarshal(sc.Bytes(), &r); err != nil {
			return true
		}
		if r.Gate == gate && r.Signal == "RED" && r.SubjectSHA256 != "" {
			redSHA = r.SubjectSHA256
		}
	}
	return redSHA == "" || redSHA != sha
}

// distinctGreenRunCount counts the consecutive GREEN-band runs for gate
// ending at the in-flight run, over DISTINCT subject SHAs. During a
// held-YELLOW demotion the published signal stays YELLOW, so the count
// is taken over observed outcomes (pass), not published signals: walk
// back through receipts until the first non-pass outcome, deduping
// SHAs. An empty subject SHA cannot be proven distinct and yields 0.
func (m *Machine) distinctGreenRunCount(gate, sha string) (int, error) {
	f, err := openIfExists(m.App.Path)
	if err != nil {
		return 0, err
	}
	type run struct {
		outcome string
		sha     string
	}
	var runs []run
	if f != nil {
		defer f.Close()
		sc := newLineScanner(f)
		for sc.Scan() {
			var r Receipt
			if err := jsonUnmarshal(sc.Bytes(), &r); err != nil {
				return 0, err
			}
			if r.Gate != gate {
				continue
			}
			runs = append(runs, run{r.Outcome, r.SubjectSHA256})
		}
		if err := sc.Err(); err != nil {
			return 0, err
		}
	}
	runs = append(runs, run{string(OutcomePass), sha}) // in-flight run

	count := 0
	seen := map[string]bool{}
	for i := len(runs) - 1; i >= 0; i-- {
		r := runs[i]
		if r.outcome != string(OutcomePass) {
			break
		}
		if r.sha == "" || seen[r.sha] {
			break // not a provably distinct-SHA GREEN
		}
		seen[r.sha] = true
		count++
	}
	return count, nil
}

// GateRun is one gate's observed outcome for a subject run.
type GateRun struct {
	Gate       string
	Outcome    Outcome
	SubjectSHA string
	Reason     string
}

// Run applies the state machine to each gate, computes the composite
// MAX over the resulting signals, and appends one receipt per gate to
// the chain with prev_signal read from the chain (never memory).
// Every signal transition is receipted, holds included.
func (m *Machine) Run(gates []GateRun) ([]Receipt, State, error) {
	trs := make([]GateTransition, 0, len(gates))
	results := make([]GateResult, 0, len(gates))
	for _, g := range gates {
		tr, err := m.Apply(g.Gate, g.Outcome, g.SubjectSHA, g.Reason)
		if err != nil {
			return nil, GREEN, err
		}
		trs = append(trs, tr)
		results = append(results, GateResult{Gate: tr.Gate, Signal: tr.Signal})
	}
	composite := Evaluate(results)
	receipts := make([]Receipt, 0, len(trs))
	for _, tr := range trs {
		r := Receipt{
			SubjectSHA256:   subjectOf(gates, tr.Gate),
			Gate:            tr.Gate,
			PrevSignal:      tr.Prev.String(),
			Signal:          tr.Signal.String(),
			Outcome:         string(tr.Outcome),
			Exit:            ExitCode(composite),
			HysteresisCount: tr.Hysteresis,
			Composite:       composite.String(),
			Arrested:        composite == RED,
			Reason:          tr.Reason,
		}
		if err := m.App.Append(r); err != nil {
			return nil, composite, err
		}
		receipts = append(receipts, r)
	}
	return receipts, composite, nil
}

func subjectOf(gates []GateRun, gate string) string {
	for _, g := range gates {
		if g.Gate == gate {
			return g.SubjectSHA
		}
	}
	return ""
}

// Evaluate returns the composite MAX over the gate signals
// (spec §1/§2). An empty gate list is GREEN (nothing demotes it).
func Evaluate(gates []GateResult) State {
	states := make([]State, 0, len(gates))
	for _, g := range gates {
		states = append(states, g.Signal)
	}
	return Max(states...)
}

// GateResult is one gate's published signal for composite evaluation.
type GateResult struct {
	Gate   string
	Signal State
}

// ExitCode maps a composite to the typed exit code (spec §2):
// 0 GREEN / 1 RED; 2 BLOCKED is reserved for infra failure and is not
// produced by composite evaluation.
func ExitCode(composite State) int {
	if composite == RED {
		return 1
	}
	return 0
}
