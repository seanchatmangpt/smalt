package andon

import (
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"testing"
)

// Chicago-style: real temp JSONL receipt files as the collaborator,
// assertions on final on-disk state. No mocks.

func newAppender(t *testing.T) *Appender {
	t.Helper()
	app, err := NewAppender(filepath.Join(t.TempDir(), "tmp", "posh", "andon.jsonl"))
	if err != nil {
		t.Fatalf("NewAppender: %v", err)
	}
	return app
}

// runOne applies a single-gate run through Machine.Run (which persists
// receipts) and returns the transition receipt from the chain.
func runOne(t *testing.T, m *Machine, gate string, o Outcome, sha, reason string) Receipt {
	t.Helper()
	recs, _, err := m.Run([]GateRun{{Gate: gate, Outcome: o, SubjectSHA: sha, Reason: reason}})
	if err != nil {
		t.Fatalf("Run %s %s: %v", gate, o, err)
	}
	if len(recs) != 1 {
		t.Fatalf("want 1 receipt, got %d", len(recs))
	}
	return recs[0]
}

func readLines(t *testing.T, path string) []Receipt {
	t.Helper()
	b, err := os.ReadFile(path)
	if err != nil {
		t.Fatalf("read receipts: %v", err)
	}
	var out []Receipt
	for _, line := range strings.Split(strings.TrimSpace(string(b)), "\n") {
		if line == "" {
			continue
		}
		var r Receipt
		if err := json.Unmarshal([]byte(line), &r); err != nil {
			t.Fatalf("corrupt receipt line %q: %v", line, err)
		}
		out = append(out, r)
	}
	return out
}

func TestMaxOrdering(t *testing.T) {
	cases := []struct {
		in   []State
		want State
	}{
		{[]State{GREEN, GREEN}, GREEN},
		{[]State{GREEN, YELLOW, GREEN}, YELLOW},
		{[]State{GREEN, YELLOW, RED}, RED},
		{[]State{}, GREEN},
	}
	for _, c := range cases {
		if got := Max(c.in...); got != c.want {
			t.Errorf("Max(%v) = %s, want %s", c.in, got, c.want)
		}
	}
	if Max(GREEN, YELLOW, RED) <= YELLOW {
		t.Error("ordering law GREEN<YELLOW<RED violated")
	}
}

func TestEvaluateCompositeMax(t *testing.T) {
	gates := []GateResult{
		{"build", GREEN}, {"test", GREEN}, {"lint", YELLOW}, {"invariant", GREEN},
	}
	if got := Evaluate(gates); got != YELLOW {
		t.Errorf("one YELLOW anywhere must demote composite to YELLOW, got %s", got)
	}
	gates[2] = GateResult{"lint", RED}
	if got := Evaluate(gates); got != RED {
		t.Errorf("composite with RED = %s, want RED", got)
	}
	if ExitCode(YELLOW) != 0 {
		t.Error("YELLOW composite proceeds: exit must be 0")
	}
	if ExitCode(RED) != 1 {
		t.Error("RED composite halts: exit must be 1")
	}
}

func TestGreenToRedToLatchedRerun(t *testing.T) {
	app := newAppender(t)
	m := &Machine{App: app}

	if r := runOne(t, m, "build", OutcomePass, "aaa", ""); r.Signal != "GREEN" {
		t.Fatalf("pass -> %s, want GREEN", r.Signal)
	}
	r := runOne(t, m, "build", OutcomeFail, "aaa", "boom")
	if r.Signal != "RED" || r.PrevSignal != "GREEN" {
		t.Fatalf("fail -> %s prev %s, want RED from GREEN", r.Signal, r.PrevSignal)
	}
	// Latch: rerun same subject, even passing, cannot clear RED.
	if r := runOne(t, m, "build", OutcomePass, "aaa", "rerun"); r.Signal != "RED" {
		t.Fatalf("same-SHA pass after RED -> %s, want latched RED", r.Signal)
	}
	// Warn band after RED also stays latched RED.
	if r := runOne(t, m, "build", OutcomeWarn, "aaa", ""); r.Signal != "RED" {
		t.Fatalf("same-SHA warn after RED -> %s, want latched RED", r.Signal)
	}

	rec := readLines(t, app.Path)
	if len(rec) != 4 {
		t.Fatalf("want 4 receipt lines, got %d", len(rec))
	}
	last := rec[3]
	if last.PrevSignal != "RED" || last.Signal != "RED" || last.Gate != "build" {
		t.Errorf("last receipt = %+v, want prev RED -> RED", last)
	}
	if rec[1].PrevSignal != "GREEN" || rec[1].Signal != "RED" {
		t.Errorf("RED transition receipt = %+v", rec[1])
	}
}

func TestRedClearsOnlyViaNewSubjectFullGreen(t *testing.T) {
	app := newAppender(t)
	m := &Machine{App: app}
	if r := runOne(t, m, "lint", OutcomeFail, "aaa", ""); r.Signal != "RED" {
		t.Fatalf("setup RED failed: %s", r.Signal)
	}
	// New subject but warn band: not a full GREEN run -> stays RED.
	if r := runOne(t, m, "lint", OutcomeWarn, "bbb", ""); r.Signal != "RED" {
		t.Fatalf("new-SHA warn after RED -> %s, want RED", r.Signal)
	}
	// New subject + full GREEN run -> clears.
	r := runOne(t, m, "lint", OutcomePass, "bbb", "")
	if r.Signal != "GREEN" {
		t.Fatalf("new-SHA pass after RED -> %s, want GREEN", r.Signal)
	}
	last := readLines(t, app.Path)[2]
	if last.PrevSignal != "RED" || last.Signal != "GREEN" || last.SubjectSHA256 != "bbb" {
		t.Errorf("clear receipt = %+v", last)
	}
}

func TestYellowHysteresisN2DistinctSHAs(t *testing.T) {
	app := newAppender(t)
	m := &Machine{App: app}
	if r := runOne(t, m, "test", OutcomeWarn, "aaa", "coverage band"); r.Signal != "YELLOW" {
		t.Fatalf("warn -> %s, want YELLOW", r.Signal)
	}
	// One GREEN over a new SHA: holds YELLOW (hysteresis 1).
	r := runOne(t, m, "test", OutcomePass, "bbb", "")
	if r.Signal != "YELLOW" || r.HysteresisCount != 1 {
		t.Fatalf("first distinct-SHA green -> %s hyst %d, want YELLOW/1", r.Signal, r.HysteresisCount)
	}
	// Same-SHA green rerun does not advance the count.
	r = runOne(t, m, "test", OutcomePass, "bbb", "")
	if r.Signal != "YELLOW" || r.HysteresisCount != 1 {
		t.Fatalf("same-SHA green -> %s hyst %d, want YELLOW/1", r.Signal, r.HysteresisCount)
	}
	// Second distinct-SHA GREEN -> demotes to GREEN.
	r = runOne(t, m, "test", OutcomePass, "ccc", "")
	if r.Signal != "GREEN" || r.HysteresisCount != 2 {
		t.Fatalf("second distinct-SHA green -> %s hyst %d, want GREEN/2", r.Signal, r.HysteresisCount)
	}
}

func TestYellowResetByWarnAndByRed(t *testing.T) {
	app := newAppender(t)
	m := &Machine{App: app}
	runOne(t, m, "test", OutcomeWarn, "aaa", "")
	runOne(t, m, "test", OutcomePass, "bbb", "") // hyst 1
	// A warn re-publishes YELLOW and resets the hysteresis counter.
	if r := runOne(t, m, "test", OutcomeWarn, "ccc", ""); r.Signal != "YELLOW" || r.HysteresisCount != 0 {
		t.Fatalf("warn mid-hysteresis -> %s hyst %d, want YELLOW/0", r.Signal, r.HysteresisCount)
	}
	runOne(t, m, "test", OutcomePass, "ddd", "") // hyst 1 again
	runOne(t, m, "test", OutcomeFail, "ddd", "") // RED latches
	if r := runOne(t, m, "test", OutcomePass, "eee", ""); r.Signal != "GREEN" {
		t.Fatalf("RED cleared via new subject+green -> %s, want GREEN", r.Signal)
	}
	if r := readLines(t, app.Path); len(r) != 6 {
		t.Fatalf("want 6 receipts, got %d", len(r))
	}
}

func TestCompositeInReceipts(t *testing.T) {
	app := newAppender(t)
	m := &Machine{App: app}
	recs, composite, err := m.Run([]GateRun{
		{Gate: "build", Outcome: OutcomePass, SubjectSHA: "s1"},
		{Gate: "test", Outcome: OutcomeWarn, SubjectSHA: "s1"},
		{Gate: "lint", Outcome: OutcomePass, SubjectSHA: "s1"},
		{Gate: "invariant", Outcome: OutcomePass, SubjectSHA: "s1"},
	})
	if err != nil {
		t.Fatalf("Run: %v", err)
	}
	if composite != YELLOW {
		t.Errorf("composite = %s, want YELLOW", composite)
	}
	for _, r := range recs {
		if r.Composite != "YELLOW" || r.Exit != 0 || r.Arrested {
			t.Errorf("receipt %+v: want composite YELLOW, exit 0, not arrested", r)
		}
	}
	recs, composite, err = m.Run([]GateRun{
		{Gate: "build", Outcome: OutcomeFail, SubjectSHA: "s1", Reason: "broken"},
	})
	if err != nil {
		t.Fatalf("Run: %v", err)
	}
	if composite != RED {
		t.Errorf("composite = %s, want RED", composite)
	}
	if recs[0].Exit != 1 || !recs[0].Arrested {
		t.Errorf("RED receipt exit=%d arrested=%v, want 1/true", recs[0].Exit, recs[0].Arrested)
	}
}

func TestPrevSignalReadFromReceiptChainNotMemory(t *testing.T) {
	// A fresh Machine over an existing chain must inherit state from
	// the file, proving the register of truth is the receipt chain.
	app := newAppender(t)
	if err := app.Append(Receipt{Gate: "build", Signal: "RED", Outcome: "fail", SubjectSHA256: "old"}); err != nil {
		t.Fatalf("seed chain: %v", err)
	}
	fresh := &Machine{App: app}
	r := runOne(t, fresh, "build", OutcomePass, "old", "rerun")
	if r.PrevSignal != "RED" || r.Signal != "RED" {
		t.Fatalf("fresh machine prev=%s signal=%s, want RED/RED (latched from chain)", r.PrevSignal, r.Signal)
	}
}

func TestHoldOnSkipAndBlocked(t *testing.T) {
	app := newAppender(t)
	m := &Machine{App: app}
	runOne(t, m, "build", OutcomeWarn, "aaa", "")
	if r := runOne(t, m, "build", OutcomeSkip, "aaa", "not run"); r.Signal != "YELLOW" {
		t.Fatalf("skip must hold YELLOW, got %s", r.Signal)
	}
	if r := runOne(t, m, "build", OutcomeBlocked, "aaa", "compile abort"); r.Signal != "YELLOW" {
		t.Fatalf("blocked must hold YELLOW (compile-abort is not a failure), got %s", r.Signal)
	}
	if rec := readLines(t, app.Path); len(rec) != 3 {
		t.Fatalf("hold transitions must still be receipted, got %d lines", len(rec))
	}
}

func TestAppenderCreatesDirsAndSyncs(t *testing.T) {
	app := newAppender(t)
	if err := app.Append(Receipt{Gate: "lint", Signal: "GREEN", Outcome: "pass", SubjectSHA256: "s"}); err != nil {
		t.Fatalf("Append: %v", err)
	}
	if _, err := os.Stat(app.Path); err != nil {
		t.Fatalf("receipt file missing after append: %v", err)
	}
	if r, ok, _ := app.LastGate("lint"); !ok || r.Signal != "GREEN" {
		t.Errorf("LastGate = %+v ok=%v, want GREEN", r, ok)
	}
	if _, ok, _ := app.LastGate("nope"); ok {
		t.Error("LastGate for unknown gate must report not-found")
	}
}

// TestDeleteThenReplayPrevFromNewChain (GAP10(e) court): a receipt chain
// wiped from disk and re-seeded MUST be the register of truth — Machine
// reads prev_signal from the NEW chain, never from any in-memory or stale
// on-disk state. Deletes are real os.Remove calls; the replay is real
// Machine.Run appends over the SAME path.
func TestDeleteThenReplayPrevFromNewChain(t *testing.T) {
	path := filepath.Join(t.TempDir(), "posh", "var", "andon.jsonl")
	newAppenderAt := func() *Appender {
		t.Helper()
		app, err := NewAppender(path)
		if err != nil {
			t.Fatalf("NewAppender: %v", err)
		}
		return app
	}
	m1 := &Machine{App: newAppenderAt()}

	// Seed the first chain: RED latch on gate "build" for subject S1.
	runOne(t, m1, "build", OutcomeFail, "S1", "boom")
	if _, err := os.Stat(path); err != nil {
		t.Fatalf("seeded chain missing: %v", err)
	}

	// WIPE: the file is gone from disk.
	if err := os.Remove(path); err != nil {
		t.Fatalf("remove: %v", err)
	}

	// Post-wipe, prev must default to GREEN (no chain on disk), proving
	// the machine truly reads the file and not memory.
	m2 := &Machine{App: newAppenderAt()}
	rec := runOne(t, m2, "build", OutcomePass, "S2", "clean run post-wipe")
	if rec.PrevSignal != "GREEN" {
		t.Fatalf("post-wipe prev = %s, want GREEN (chain deleted; prev must come from the file)", rec.PrevSignal)
	}

	// Replay the seeded chain at the SAME path: a fresh RED for S1.
	m3 := &Machine{App: newAppenderAt()}
	rec = runOne(t, m3, "build", OutcomeFail, "S1", "boom again")
	if rec.PrevSignal != "GREEN" {
		t.Fatalf("replay seed prev = %s, want GREEN", rec.PrevSignal)
	}
	if rec.Signal != "RED" {
		t.Fatalf("replay seed signal = %s, want RED", rec.Signal)
	}

	// The new chain now governs: same-SHA rerun stays latched RED with
	// prev read from the REPLAYED chain, not the wiped one.
	rec = runOne(t, m3, "build", OutcomePass, "S1", "same subject, still latched")
	if rec.PrevSignal != "RED" || rec.Signal != "RED" {
		t.Fatalf("prev=%s signal=%s, want RED/RED read from the new chain", rec.PrevSignal, rec.Signal)
	}

	// And a new subject's full GREEN clears — reading the NEW chain.
	rec = runOne(t, m3, "build", OutcomePass, "S9", "new subject")
	if rec.PrevSignal != "RED" {
		t.Fatalf("prev = %s, want RED from replayed chain", rec.PrevSignal)
	}
	if rec.Signal != "GREEN" {
		t.Fatalf("signal = %s, want GREEN (changed subject + pass clears latch)", rec.Signal)
	}

	// Final on-disk state: exactly 4 receipts, in order.
	lines := readLines(t, path)
	if len(lines) != 4 {
		t.Fatalf("chain has %d receipts, want 4", len(lines))
	}
	want := []struct{ prev, sig string }{{"GREEN", "GREEN"}, {"GREEN", "RED"}, {"RED", "RED"}, {"RED", "GREEN"}}
	for i, w := range want {
		if lines[i].PrevSignal != w.prev || lines[i].Signal != w.sig {
			t.Fatalf("receipt %d = %s->%s, want %s->%s", i, lines[i].PrevSignal, lines[i].Signal, w.prev, w.sig)
		}
	}
}

// TestTransitionHookFiresOnTransitionsAndHolds proves the OnTransition
// counter hook (GAP10(c) surface) fires on every receipted transition —
// changes and holds (from == to) alike — with real Machine.Run runs.
func TestTransitionHookFiresOnTransitionsAndHolds(t *testing.T) {
	app := newAppender(t)
	m := &Machine{App: app}

	type ev struct {
		gate string
		from State
		to   State
	}
	var mu sync.Mutex
	var got []ev
	prev := OnTransition
	OnTransition = func(gate string, from, to State) {
		mu.Lock()
		defer mu.Unlock()
		got = append(got, ev{gate, from, to})
	}
	t.Cleanup(func() { OnTransition = prev })

	runOne(t, m, "build", OutcomePass, "S1", "ok")
	runOne(t, m, "build", OutcomePass, "S2", "ok")
	runOne(t, m, "build", OutcomeFail, "S3", "boom")

	mu.Lock()
	defer mu.Unlock()
	if len(got) != 3 {
		t.Fatalf("hook fired %d times, want 3", len(got))
	}
	if got[0] != (ev{"build", GREEN, GREEN}) {
		t.Errorf("ev0 = %+v, want build GREEN->GREEN", got[0])
	}
	if got[1] != (ev{"build", GREEN, GREEN}) {
		t.Errorf("ev1 = %+v, want hold GREEN->GREEN", got[1])
	}
	if got[2] != (ev{"build", GREEN, RED}) {
		t.Errorf("ev2 = %+v, want GREEN->RED", got[2])
	}
}
