// context.go centralizes POSH context/timeout discipline: the drain window
// for graceful shutdown and per-connection context derivation (server.go
// deadline fence unchanged in semantics).
package server

import (
	"context"
	"os"
	"strconv"
	"time"
)

// DefaultDrainTimeout is the graceful-shutdown drain window used when
// POSH_DRAIN_TIMEOUT is unset or unparseable.
const DefaultDrainTimeout = 5 * time.Second

// DrainTimeout returns the bounded drain window for graceful shutdown,
// overridable via POSH_DRAIN_TIMEOUT (Go duration like "2s" or plain
// seconds like "10"). Falls back to DefaultDrainTimeout on any parse
// failure (fail-closed to the known-good default, never a zero window).
func DrainTimeout() time.Duration {
	v := os.Getenv("POSH_DRAIN_TIMEOUT")
	if v == "" {
		return DefaultDrainTimeout
	}
	if d, err := time.ParseDuration(v); err == nil {
		return d
	}
	if secs, err := strconv.Atoi(v); err == nil {
		return time.Duration(secs) * time.Second
	}
	return DefaultDrainTimeout
}

// connContext derives a connection-scoped context from the server's base
// context, so connection goroutines unwind when shutdown begins.
func connContext(base context.Context) (context.Context, context.CancelFunc) {
	return context.WithCancel(base)
}

// requestContext layers the envelope deadline onto a parent context
// (same fence as dispatch, extracted so every transport derives
// request contexts identically).
func requestContext(parent context.Context, deadline time.Time) (context.Context, context.CancelFunc) {
	if deadline.IsZero() {
		return context.WithCancel(parent)
	}
	return context.WithDeadline(parent, deadline)
}
