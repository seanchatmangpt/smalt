package andon

import (
	"bufio"
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"time"
)

// Receipt is one JSONL line in the andon receipt chain
// (spec §5). prev_signal is always read back from the chain, never
// from memory.
type Receipt struct {
	TS              string  `json:"ts"`
	SubjectSHA256   string  `json:"subject_sha256"`
	Gate            string  `json:"gate"`
	PrevSignal      string  `json:"prev_signal"`
	Signal          string  `json:"signal"`
	Outcome         string  `json:"outcome"`
	Exit            int     `json:"exit"`
	ElapsedMS       int64   `json:"elapsed_ms"`
	SLAMS           int64   `json:"sla_ms"`
	HysteresisCount int     `json:"hysteresis_count"`
	Composite       string  `json:"composite"`
	Arrested        bool    `json:"arrested"`
	SkipReason      *string `json:"skip_reason"`
	Reason          string  `json:"reason"`
}

// HysteresisN is the number of consecutive GREEN runs over DISTINCT
// subject SHAs required to demote YELLOW back to GREEN (spec §1, N=2).
const HysteresisN = 2

// Appender appends receipts to a JSONL file and reads prior state back
// from that file. The file is the register of truth.
type Appender struct {
	Path string
}

// NewAppender returns an Appender writing to path, created if absent.
func NewAppender(path string) (*Appender, error) {
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		return nil, err
	}
	return &Appender{Path: path}, nil
}

// Append writes one receipt line, flushed to disk.
func (a *Appender) Append(r Receipt) error {
	if r.TS == "" {
		r.TS = time.Now().UTC().Format(time.RFC3339)
	}
	b, err := json.Marshal(r)
	if err != nil {
		return err
	}
	f, err := os.OpenFile(a.Path, os.O_APPEND|os.O_CREATE|os.O_WRONLY, 0o644)
	if err != nil {
		return err
	}
	defer f.Close()
	if _, err := f.Write(append(b, '\n')); err != nil {
		return err
	}
	return f.Sync()
}

// LastGate returns the most recent receipt for gate in the chain.
// Missing file or no line for the gate yields ok=false.
func (a *Appender) LastGate(gate string) (Receipt, bool, error) {
	f, err := os.Open(a.Path)
	if os.IsNotExist(err) {
		return Receipt{}, false, nil
	}
	if err != nil {
		return Receipt{}, false, err
	}
	defer f.Close()
	var last Receipt
	found := false
	sc := bufio.NewScanner(f)
	sc.Buffer(make([]byte, 0, 64*1024), 1024*1024)
	for sc.Scan() {
		line := sc.Bytes()
		if len(line) == 0 {
			continue
		}
		var r Receipt
		if err := json.Unmarshal(line, &r); err != nil {
			return Receipt{}, false, fmt.Errorf("andon: corrupt receipt line: %w", err)
		}
		if r.Gate == gate {
			last = r
			found = true
		}
	}
	if err := sc.Err(); err != nil {
		return Receipt{}, false, err
	}
	return last, found, nil
}
