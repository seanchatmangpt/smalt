// Package tracing implements W3C Trace Context (traceparent/tracestate)
// propagation and unified cross-runtime distributed trace DAG generation
// for the POSH membrane, correlating BEAM OTP actor PIDs and BLAKE3 receipts.
package tracing

import (
	"crypto/rand"
	"encoding/hex"
	"errors"
	"fmt"
	"strings"
)

var (
	ErrInvalidTraceparent = errors.New("invalid w3c traceparent header")
	ErrAllZeroTraceID     = errors.New("w3c traceparent trace-id cannot be all zeros")
	ErrAllZeroSpanID      = errors.New("w3c traceparent span-id cannot be all zeros")
)

// TraceContext represents the parsed W3C Trace Context state.
type TraceContext struct {
	Version    byte
	TraceID    [16]byte
	SpanID     [8]byte
	TraceFlags byte
}

// NewRootContext creates a new root trace context with randomly generated
// TraceID and SpanID, flagged as sampled (0x01).
func NewRootContext() TraceContext {
	var tc TraceContext
	tc.Version = 0
	tc.TraceFlags = 0x01 // Sampled
	_, _ = rand.Read(tc.TraceID[:])
	_, _ = rand.Read(tc.SpanID[:])
	return tc
}

func fromHexChar(c byte) (byte, bool) {
	switch {
	case '0' <= c && c <= '9':
		return c - '0', true
	case 'a' <= c && c <= 'f':
		return c - 'a' + 10, true
	case 'A' <= c && c <= 'F':
		return c - 'A' + 10, true
	default:
		return 0, false
	}
}

func decodeHexByte(c1, c2 byte) (byte, bool) {
	h1, ok1 := fromHexChar(c1)
	h2, ok2 := fromHexChar(c2)
	if !ok1 || !ok2 {
		return 0, false
	}
	return (h1 << 4) | h2, true
}

func decodeHexFixed(dst, src []byte) bool {
	if len(src)%2 != 0 || len(dst) != len(src)/2 {
		return false
	}
	for i := 0; i < len(dst); i++ {
		b, ok := decodeHexByte(src[i*2], src[i*2+1])
		if !ok {
			return false
		}
		dst[i] = b
	}
	return true
}

// ParseTraceparent parses a W3C traceparent string conforming to W3C Recommendation.
// Format: 00-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-01 (55 characters)
// Zero heap allocations.
func ParseTraceparent(s string) (TraceContext, error) {
	var tc TraceContext
	if len(s) < 55 {
		return tc, ErrInvalidTraceparent
	}
	if s[2] != '-' || s[35] != '-' || s[52] != '-' {
		return tc, ErrInvalidTraceparent
	}

	// Parse version (2 hex chars)
	ver, ok := decodeHexByte(s[0], s[1])
	if !ok {
		return tc, fmt.Errorf("%w: version hex invalid", ErrInvalidTraceparent)
	}
	tc.Version = ver
	if tc.Version == 0xff {
		return tc, fmt.Errorf("%w: version ff is forbidden", ErrInvalidTraceparent)
	}

	// Parse TraceID (32 hex chars -> 16 bytes)
	if !decodeHexFixed(tc.TraceID[:], []byte(s[3:35])) {
		return tc, fmt.Errorf("%w: trace-id hex invalid", ErrInvalidTraceparent)
	}
	if isAllZero(tc.TraceID[:]) {
		return tc, ErrAllZeroTraceID
	}

	// Parse SpanID (16 hex chars -> 8 bytes)
	if !decodeHexFixed(tc.SpanID[:], []byte(s[36:52])) {
		return tc, fmt.Errorf("%w: span-id hex invalid", ErrInvalidTraceparent)
	}
	if isAllZero(tc.SpanID[:]) {
		return tc, ErrAllZeroSpanID
	}

	// Parse TraceFlags (2 hex chars -> 1 byte)
	flags, ok := decodeHexByte(s[53], s[54])
	if !ok {
		return tc, fmt.Errorf("%w: flags hex invalid", ErrInvalidTraceparent)
	}
	tc.TraceFlags = flags

	return tc, nil
}

func isAllZero(b []byte) bool {
	for _, v := range b {
		if v != 0 {
			return false
		}
	}
	return true
}

// String renders the W3C traceparent string: 00-traceid-spanid-flags (55 chars).
func (tc TraceContext) String() string {
	var buf [55]byte
	hex.Encode(buf[0:2], []byte{tc.Version})
	buf[2] = '-'
	hex.Encode(buf[3:35], tc.TraceID[:])
	buf[35] = '-'
	hex.Encode(buf[36:52], tc.SpanID[:])
	buf[52] = '-'
	hex.Encode(buf[53:55], []byte{tc.TraceFlags})
	return string(buf[:])
}

// TraceIDHex returns the 32-character lowercase hex string of TraceID.
func (tc TraceContext) TraceIDHex() string {
	return hex.EncodeToString(tc.TraceID[:])
}

// SpanIDHex returns the 16-character lowercase hex string of SpanID.
func (tc TraceContext) SpanIDHex() string {
	return hex.EncodeToString(tc.SpanID[:])
}

// IsSampled reports whether the recorded bit in trace flags is set.
func (tc TraceContext) IsSampled() bool {
	return (tc.TraceFlags & 0x01) == 0x01
}

// SmaltTracestate holds parsed BEAM actor and node metadata carried in W3C tracestate.
type SmaltTracestate struct {
	ActorPID string // e.g. "<0.152.0>"
	Node     string // e.g. "smalt@prod-host"
	Raw      string
}

// ParseTracestate extracts Smalt-specific correlation tokens from a W3C tracestate header.
// Example: "congo=t61rcWkgMzE,smalt=pid:<0.152.0>;node:smalt@host"
func ParseTracestate(ts string) SmaltTracestate {
	res := SmaltTracestate{Raw: ts}
	if ts == "" {
		return res
	}

	entries := strings.Split(ts, ",")
	for _, entry := range entries {
		entry = strings.TrimSpace(entry)
		if strings.HasPrefix(entry, "smalt=") {
			val := strings.TrimPrefix(entry, "smalt=")
			parts := strings.Split(val, ";")
			for _, p := range parts {
				kv := strings.SplitN(p, ":", 2)
				if len(kv) == 2 {
					k := strings.TrimSpace(kv[0])
					v := strings.TrimSpace(kv[1])
					switch k {
					case "pid":
						res.ActorPID = v
					case "node":
						res.Node = v
					}
				}
			}
			break
		}
	}
	return res
}

// FormatSmaltTracestate builds the W3C tracestate value for Smalt BEAM actor correlation.
func FormatSmaltTracestate(actorPID, node string) string {
	var sb strings.Builder
	sb.WriteString("smalt=")
	if actorPID != "" {
		sb.WriteString("pid:")
		sb.WriteString(actorPID)
	}
	if node != "" {
		if actorPID != "" {
			sb.WriteByte(';')
		}
		sb.WriteString("node:")
		sb.WriteString(node)
	}
	return sb.String()
}
