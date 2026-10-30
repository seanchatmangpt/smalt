package telemetry

import (
	"bufio"
	"encoding/json"
	"errors"
	"io"
	"sync"
	"time"
)

// OCELEvent represents an Object-Centric Event Log (OCEL 2.0) event.
type OCELEvent struct {
	ID            string            `json:"ocel:id"`
	Type          string            `json:"ocel:type"`
	Timestamp     time.Time         `json:"ocel:time"`
	Attributes    map[string]any    `json:"ocel:attributes,omitempty"`
	Relationships []OCELRelation    `json:"ocel:relationships,omitempty"`
}

// OCELRelation represents an event-to-object or object-to-object edge.
type OCELRelation struct {
	ObjectID  string `json:"ocel:objectId"`
	Qualifier string `json:"ocel:qualifier"`
}

// OCELWriter buffers and asynchronously writes OCEL events in NDJSON format.
type OCELWriter struct {
	mu      sync.Mutex
	writer  *bufio.Writer
	closed  bool
	written uint64
}

// NewOCELWriter constructs an NDJSON writer with a 64KB page buffer.
func NewOCELWriter(w io.Writer) *OCELWriter {
	return &OCELWriter{
		writer: bufio.NewWriterSize(w, 64*1024),
	}
}

// WriteEvent serializes and buffers a single OCEL event followed by a newline.
func (ow *OCELWriter) WriteEvent(evt *OCELEvent) error {
	ow.mu.Lock()
	defer ow.mu.Unlock()

	if ow.closed {
		return errors.New("cannot write to closed OCELWriter")
	}

	data, err := json.Marshal(evt)
	if err != nil {
		return err
	}

	if _, err := ow.writer.Write(data); err != nil {
		return err
	}
	if err := ow.writer.WriteByte('\n'); err != nil {
		return err
	}

	ow.written++
	return nil
}

// Flush flushes buffered NDJSON bytes to underlying writer.
func (ow *OCELWriter) Flush() error {
	ow.mu.Lock()
	defer ow.mu.Unlock()
	return ow.writer.Flush()
}

// Close flushes and seals the writer.
func (ow *OCELWriter) Close() error {
	ow.mu.Lock()
	defer ow.mu.Unlock()
	if ow.closed {
		return nil
	}
	err := ow.writer.Flush()
	ow.closed = true
	return err
}

// Count returns total events written.
func (ow *OCELWriter) Count() uint64 {
	ow.mu.Lock()
	defer ow.mu.Unlock()
	return ow.written
}
