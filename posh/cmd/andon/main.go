// Command andon is the POSH Andon composite publisher driver
// (docs/jira/posh/v26.10.30/dfcharter/andon.md).
//
// It reads gate results as JSON lines on stdin:
//
//	{"gate":"build","pass":true,"sla_met":true,"subject_sha":"<sha256>","reason":"..."}
//
// applies the per-gate signal state machine (prev_signal read from the
// receipt chain, never memory), appends one receipt per gate to the
// JSONL chain (default tmp/posh/andon.jsonl, -receipts to override),
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
}

func main() {
	receipts := flag.String("receipts", "tmp/posh/andon.jsonl", "andon receipt chain (JSONL)")
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
		outcome := andon.OutcomePass
		switch {
		case !in.Pass:
			outcome = andon.OutcomeFail
		case !in.SLAMet:
			outcome = andon.OutcomeTimeout
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
