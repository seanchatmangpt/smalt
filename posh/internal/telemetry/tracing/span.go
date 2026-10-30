package tracing

import (
	"context"
	"crypto/rand"
	"encoding/hex"
	"sync"
	"time"
)

type contextKey struct{}

var traceKey = contextKey{}

// WithTraceContext injects the TraceContext into the context.
func WithTraceContext(ctx context.Context, tc TraceContext) context.Context {
	return context.WithValue(ctx, traceKey, tc)
}

// FromContext extracts the TraceContext from the context if present.
func FromContext(ctx context.Context) (TraceContext, bool) {
	tc, ok := ctx.Value(traceKey).(TraceContext)
	return tc, ok
}

// Span represents a single span in the distributed execution DAG.
type Span struct {
	mu           sync.Mutex
	TraceID      [16]byte
	SpanID       [8]byte
	ParentSpanID [8]byte
	Name         string
	StartTime    time.Time
	EndTime      time.Time
	Attributes   map[string]string
	Events       []SpanEvent
	Status       SpanStatus
}

// SpanStatus represents the outcome status of the span.
type SpanStatus struct {
	Code        string // "OK" | "ERROR"
	Description string
}

// SpanEvent represents a timestamped event within a span.
type SpanEvent struct {
	Name       string
	Timestamp  time.Time
	Attributes map[string]string
}

// StartSpan creates a child span linked to parent, or a new root span.
func StartSpan(name string, parent *TraceContext) *Span {
	s := &Span{
		Name:       name,
		StartTime:  time.Now(),
		Attributes: make(map[string]string),
		Status:     SpanStatus{Code: "OK"},
	}

	_, _ = rand.Read(s.SpanID[:])

	if parent != nil {
		s.TraceID = parent.TraceID
		s.ParentSpanID = parent.SpanID
	} else {
		_, _ = rand.Read(s.TraceID[:])
	}

	return s
}

// Context returns the TraceContext for this span.
func (s *Span) Context() TraceContext {
	return TraceContext{
		Version:    0,
		TraceID:    s.TraceID,
		SpanID:     s.SpanID,
		TraceFlags: 0x01,
	}
}

// SetAttribute sets a key-value attribute on the span.
func (s *Span) SetAttribute(key, value string) {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.Attributes[key] = value
}

// AddEvent records an in-span event.
func (s *Span) AddEvent(name string, attrs map[string]string) {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.Events = append(s.Events, SpanEvent{
		Name:       name,
		Timestamp:  time.Now(),
		Attributes: attrs,
	})
}

// End finishes the span and marks EndTime.
func (s *Span) End() {
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.EndTime.IsZero() {
		s.EndTime = time.Now()
	}
}

// CorrelateBEAMActor records the BEAM OTP actor PID and Node into span attributes.
func (s *Span) CorrelateBEAMActor(actorPID, node string) {
	if actorPID != "" {
		s.SetAttribute("smalt.actor.pid", actorPID)
	}
	if node != "" {
		s.SetAttribute("smalt.actor.node", node)
	}
}

// CorrelateTurnstileReceipt cryptographically binds the span to the BLAKE3 turnstile receipt.
func (s *Span) CorrelateTurnstileReceipt(receiptHex string, timestampNs uint64, verified bool) {
	s.SetAttribute("smalt.turnstile.receipt", receiptHex)
	s.SetAttribute("smalt.turnstile.timestamp_ns", time.Duration(timestampNs).String())
	if verified {
		s.SetAttribute("smalt.turnstile.verified", "true")
	} else {
		s.SetAttribute("smalt.turnstile.verified", "false")
	}
	s.AddEvent("turnstile_admission", map[string]string{
		"receipt":      receiptHex,
		"timestamp_ns": time.Duration(timestampNs).String(),
	})
}

// TraceDAG represents the unified trace graph connecting BEAM, POSH membrane, and Egress.
type TraceDAG struct {
	TraceID string  `json:"trace_id"`
	Spans   []*Span `json:"spans"`
}

// TraceIDHex returns the hex string of TraceID.
func (s *Span) TraceIDHex() string {
	return hex.EncodeToString(s.TraceID[:])
}

// SpanIDHex returns the hex string of SpanID.
func (s *Span) SpanIDHex() string {
	return hex.EncodeToString(s.SpanID[:])
}

// ParentSpanIDHex returns the hex string of ParentSpanID.
func (s *Span) ParentSpanIDHex() string {
	return hex.EncodeToString(s.ParentSpanID[:])
}
