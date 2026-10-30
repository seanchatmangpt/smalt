package main

import (
	"testing"

	"smalt.dev/posh/internal/andon"
)

// G28 §3 driver delta: explicit outcome channel on stdin gates.
// skip/blocked HOLD the gate signal and still receipt (machine.go
// stateForOutcome); legacy lines (no outcome field) keep the
// !pass→fail / pass&&!sla_met→timeout derivation.

func TestMapOutcomeLegacyBackwardCompat(t *testing.T) {
	cases := []struct {
		in   gateInput
		want andon.Outcome
	}{
		{gateInput{Pass: true, SLAMet: true}, andon.OutcomePass},
		{gateInput{Pass: false, SLAMet: true}, andon.OutcomeFail},
		{gateInput{Pass: true, SLAMet: false}, andon.OutcomeTimeout},
	}
	for _, c := range cases {
		got, err := mapOutcome(1, c.in)
		if err != nil {
			t.Fatalf("mapOutcome(%+v): %v", c.in, err)
		}
		if got != c.want {
			t.Fatalf("mapOutcome(%+v) = %q, want %q", c.in, got, c.want)
		}
	}
}

func TestMapOutcomeExplicitWinsOverFlags(t *testing.T) {
	// pass=true/sla_met=true but outcome=fail → fail (explicit wins).
	got, err := mapOutcome(1, gateInput{Pass: true, SLAMet: true, Outcome: "fail"})
	if err != nil || got != andon.OutcomeFail {
		t.Fatalf("explicit fail over green flags = %q, %v; want fail, nil", got, err)
	}
}

func TestMapOutcomeSkipAndBlockedHold(t *testing.T) {
	for _, oc := range []string{"skip", "blocked"} {
		got, err := mapOutcome(1, gateInput{Pass: false, Outcome: oc})
		if err != nil {
			t.Fatalf("outcome %q: %v", oc, err)
		}
		if andon.Outcome(oc) != got {
			t.Fatalf("outcome %q resolved to %q", oc, got)
		}
	}
}

func TestMapOutcomeRejectsUnknown(t *testing.T) {
	if _, err := mapOutcome(7, gateInput{Outcome: "purple"}); err == nil {
		t.Fatal("unknown outcome accepted; want typed driver error (rc 2)")
	}
}

// Hold semantics end-to-end through the real machine: a skip at a RED
// gate holds RED (never fabricates GREEN); a skip at a GREEN gate stays
// GREEN. Uses a temp chain file — real Appender, real state machine.
func TestHoldOutcomesReceiptedThroughMachine(t *testing.T) {
	dir := t.TempDir()
	chain := dir + "/andon.jsonl"

	app, err := andon.NewAppender(chain)
	if err != nil {
		t.Fatalf("NewAppender: %v", err)
	}
	m := &andon.Machine{App: app}

	// RED first.
	if _, comp, err := m.Run([]andon.GateRun{{Gate: "vet", Outcome: andon.OutcomeFail, SubjectSHA: "a"}}); err != nil || comp != andon.RED {
		t.Fatalf("fail run: composite %v, %v; want RED", comp, err)
	}
	// skip holds RED and is receipted.
	recs, comp, err := m.Run([]andon.GateRun{{Gate: "vet", Outcome: andon.OutcomeSkip, SubjectSHA: "a"}})
	if err != nil {
		t.Fatalf("skip run: %v", err)
	}
	if comp != andon.RED {
		t.Fatalf("skip after RED composite %v, want held RED", comp)
	}
	if len(recs) != 1 || recs[0].Outcome != string(andon.OutcomeSkip) || recs[0].Signal != "RED" {
		t.Fatalf("skip receipt = %+v, want outcome skip signal RED", recs[0])
	}
	// blocked holds GREEN on a fresh gate and is receipted.
	recs, comp, err = m.Run([]andon.GateRun{{Gate: "fence", Outcome: andon.OutcomeBlocked, SubjectSHA: "a"}})
	if err != nil || comp != andon.GREEN {
		t.Fatalf("blocked fresh gate: composite %v, %v; want GREEN", comp, err)
	}
	if len(recs) != 1 || recs[0].Outcome != string(andon.OutcomeBlocked) || recs[0].Signal != "GREEN" {
		t.Fatalf("blocked receipt = %+v, want outcome blocked signal GREEN", recs[0])
	}
}
