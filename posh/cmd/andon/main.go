// Command andon is the POSH Andon composite publisher driver
// (docs/jira/posh/v26.10.30/dfcharter/andon.md).
//
// It reads gate results as JSON lines on stdin:
//
//	{"gate":"build","pass":true,"sla_met":true,"subject_sha":"<sha256>","reason":"..."}
//
// or, with the explicit outcome channel (G28 §3):
//
//	{"gate":"build","outcome":"skip","subject_sha":"<sha256>","reason":"..."}
//
// applies the per-gate signal state machine (prev_signal read from the
// receipt chain, never memory), appends one receipt per gate to the
// JSONL chain (default posh/var/andon.jsonl — a durable location that
// posh-clean does NOT sweep; -receipts to override, the old tmp/posh path
// still honored when passed explicitly),
// prints the composite, and exits with the typed code:
//
//	0 GREEN (YELLOW proceeds with signal carried on the receipt)
//	1 RED — halt the line
//	2 reserved BLOCKED (infra failure; produced on driver errors)
package main

import (
	"bufio"
	"encoding/json"
	"flag"
	"fmt"
	"os"
	"strings"

	"smalt.dev/posh/internal/andon"
)

type gateInput struct {
	Gate       string `json:"gate"`
	Pass       bool   `json:"pass"`
	SLAMet     bool   `json:"sla_met"`
	SubjectSHA string `json:"subject_sha"`
	Reason     string `json:"reason"`
	// Outcome is the optional explicit outcome channel (G28 §3 driver
	// delta): pass|warn|fail|timeout|skip|blocked. skip/blocked HOLD the
	// gate's current signal and are still receipted (machine.go
	// stateForOutcome). Empty = legacy derivation from pass/sla_met.
	Outcome string `json:"outcome"`
}

// mapOutcome resolves the effective outcome for a stdin gate line.
// Explicit outcome wins when present and must be a known Outcome string
// (unknown → typed driver error, rc 2). Legacy lines (no outcome field)
// keep the original derivation: !pass → fail; pass && !sla_met → timeout;
// else pass. Backward compatible.
func mapOutcome(line int, in gateInput) (andon.Outcome, error) {
	if in.Outcome != "" {
		switch andon.Outcome(in.Outcome) {
		case andon.OutcomePass, andon.OutcomeWarn, andon.OutcomeFail,
			andon.OutcomeTimeout, andon.OutcomeSkip, andon.OutcomeBlocked:
			return andon.Outcome(in.Outcome), nil
		default:
			return "", fmt.Errorf("stdin line %d: unknown outcome %q (want pass|warn|fail|timeout|skip|blocked)", line, in.Outcome)
		}
	}
	if !in.Pass {
		return andon.OutcomeFail, nil
	}
	if !in.SLAMet {
		return andon.OutcomeTimeout, nil
	}
	return andon.OutcomePass, nil
}

// defaultReceiptsPath is the DEFAULT andon receipt chain location:
// posh/var/ is durable state — gitignored, and swept by neither
// `make clean` (posh/bin, run) nor `just posh-clean` (rm -rf tmp/posh).
// The old tmp/posh/andon.jsonl path is still honored when passed
// explicitly via -receipts.
const defaultReceiptsPath = "posh/var/andon.jsonl"

func main() {
	receipts := flag.String("receipts", defaultReceiptsPath, "andon receipt chain (JSONL; durable across posh-clean)")
	flag.Parse()

	app, err := andon.NewAppender(*receipts)
	if err != nil {
		fmt.Fprintf(os.Stderr, "andon: %v\n", err)
		os.Exit(2)
	}

	sc := bufio.NewScanner(os.Stdin)
	sc.Buffer(make([]byte, 0, 64*1024), 1024*1024)
	var runs []andon.GateRun
	line := 0
	for sc.Scan() {
		line++
		raw := strings.TrimSpace(sc.Text())
		if raw == "" {
			continue
		}
		var in gateInput
		if err := json.Unmarshal([]byte(raw), &in); err != nil {
			fmt.Fprintf(os.Stderr, "andon: stdin line %d: %v\n", line, err)
			os.Exit(2)
		}
		outcome, err := mapOutcome(line, in)
		if err != nil {
			fmt.Fprintf(os.Stderr, "andon: %v\n", err)
			os.Exit(2)
		}
		runs = append(runs, andon.GateRun{
			Gate:       in.Gate,
			Outcome:    outcome,
			SubjectSHA: in.SubjectSHA,
			Reason:     in.Reason,
		})
	}
	if err := sc.Err(); err != nil {
		fmt.Fprintf(os.Stderr, "andon: stdin: %v\n", err)
		os.Exit(2)
	}

	machine := &andon.Machine{App: app}
	recs, composite, err := machine.Run(runs)
	if err != nil {
		fmt.Fprintf(os.Stderr, "andon: %v\n", err)
		os.Exit(2)
	}
	for _, r := range recs {
		fmt.Printf("%s %s -> %s (prev %s, hysteresis %d)\n",
			r.Gate, r.Outcome, r.Signal, r.PrevSignal, r.HysteresisCount)
	}
	fmt.Printf("composite %s\n", composite)
	os.Exit(andon.ExitCode(composite))
}
