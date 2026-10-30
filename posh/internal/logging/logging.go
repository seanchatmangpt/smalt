// Package logging provides structured stderr logging for posh via log/slog.
//
// Design constraints (POSH charter):
//   - stderr only: stdout is the handshake channel in provider contexts, so
//     the logger writes exclusively to os.Stderr and posh keeps stdout clean.
//   - JSON handler: one machine-parseable line per event.
//   - Level from POSH_LOG_LEVEL (debug|info|warn|error, case-insensitive;
//     default info; unknown values fall back to info).
//   - Request lifecycle logs are emitted at debug level, so at warn+ no
//     per-request work happens on the hot path (level check short-circuits
//     before any attribute is built).
package logging

import (
	"context"
	"log/slog"
	"os"
	"strings"
)

// ctxKey carries the request id through the dispatch path.
type ctxKey int

const requestIDKey ctxKey = 1

// L is the process logger. It is nil until Init is called; server code
// treats nil as "log at debug to a discard logger" via the From accessor.
var L *slog.Logger

// Init installs the process logger: JSON handler on stderr at the level
// named by POSH_LOG_LEVEL (default info). Safe to call once at boot.
func Init() {
	L = slog.New(slog.NewJSONHandler(os.Stderr, &slog.HandlerOptions{
		Level: parseLevel(os.Getenv("POSH_LOG_LEVEL")),
	}))
}

// parseLevel maps a POSH_LOG_LEVEL value to a slog level. Unknown or empty
// values default to info.
func parseLevel(v string) slog.Level {
	switch strings.ToLower(strings.TrimSpace(v)) {
	case "debug":
		return slog.LevelDebug
	case "warn", "warning":
		return slog.LevelWarn
	case "error":
		return slog.LevelError
	default:
		return slog.LevelInfo
	}
}

// From returns the process logger, falling back to a debug-level discard
// logger so callers never need a nil check.
func From() *slog.Logger {
	if L != nil {
		return L
	}
	return slog.New(slog.NewJSONHandler(discard{}, &slog.HandlerOptions{Level: slog.LevelDebug}))
}

// WithRequestID returns a child context carrying id, for request-scoped
// logging via RequestID(ctx).
func WithRequestID(ctx context.Context, id string) context.Context {
	return context.WithValue(ctx, requestIDKey, id)
}

// RequestID extracts the request id from ctx ("" if absent).
func RequestID(ctx context.Context) string {
	if v, ok := ctx.Value(requestIDKey).(string); ok {
		return v
	}
	return ""
}

// discard is a no-op io.Writer used for the off hot path.
type discard struct{}

func (discard) Write(p []byte) (int, error) { return len(p), nil }
