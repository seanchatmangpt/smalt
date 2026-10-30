package andon

import (
	"bufio"
	"encoding/json"
	"fmt"
	"os"
)

// CorruptSignalError is returned when the receipt chain carries an
// unknown signal name for a gate.
type CorruptSignalError struct {
	Gate   string
	Signal string
}

func (e *CorruptSignalError) Error() string {
	return fmt.Sprintf("andon: gate %q has unknown signal %q in receipt chain", e.Gate, e.Signal)
}

func openIfExists(path string) (*os.File, error) {
	f, err := os.Open(path)
	if os.IsNotExist(err) {
		return nil, nil
	}
	return f, err
}

func newLineScanner(f *os.File) *bufio.Scanner {
	sc := bufio.NewScanner(f)
	sc.Buffer(make([]byte, 0, 64*1024), 1024*1024)
	return sc
}

func jsonUnmarshal(b []byte, v any) error {
	if err := json.Unmarshal(b, v); err != nil {
		return fmt.Errorf("andon: corrupt receipt line: %w", err)
	}
	return nil
}
