package api

import (
	"context"
	"errors"
	"fmt"
)

// Sentinel errors, one per typed error code. Every *MembraneError built by the
// constructors below unwraps to its sentinel, so callers classify failures
// with errors.Is instead of comparing codes:
//
//	resp, err := call(ctx, req)
//	if err != nil && errors.Is(err, api.ErrDeadline) {
//		// retry with a longer deadline; the work may still be running
//	}
//	if err != nil && errors.Is(err, api.ErrRefusedEgress) {
//		// policy denial; retrying will not help
//	}
//
// The sentinels are also matched through wrapped chains: a constructor that
// wraps a cause (net.OpError, context.DeadlineExceeded, ...) still satisfies
// errors.Is(err, api.ErrTransport) because Unwrap walks both the cause and
// the sentinel.
var (
	// ErrTransport is the sentinel for CodeTransport failures: framing,
	// envelope decode, or socket-level I/O problems.
	ErrTransport = errors.New("transport")

	// ErrUpstream is the sentinel for CodeUpstream failures: the handler or
	// a downstream service failed for reasons outside this process's control.
	ErrUpstream = errors.New("upstream")

	// ErrDeadline is the sentinel for CodeDeadline failures: the request's
	// deadline fence fired before the handler completed.
	ErrDeadline = errors.New("deadline exceeded")

	// ErrRefusedEgress is the sentinel for CodeRefusedEgress: the egress
	// policy refused the operation. It is a policy denial, not a retryable
	// fault.
	ErrRefusedEgress = errors.New("egress refused")
)

// MembraneError is the typed failure payload carried on an error Response, and an
// error value in its own right. It carries the wire code, the operation that
// failed, a human message, and an optional wrapped cause.
//
// Usage:
//
//	err := api.NewTransport("decode", io.ErrUnexpectedEOF, "short frame")
//	errors.Is(err, api.ErrTransport) // true
//	errors.Unwrap(err)               // io.ErrUnexpectedEOF
//	err.Error()                      // "decode: transport: short frame: unexpected EOF"
//
// MembraneError is the typed in-process error: sentinel code, op, message, cause.
type MembraneError struct {
	// Code is the typed wire code (TRANSPORT | UPSTREAM | DEADLINE | REFUSED_EGRESS).
	Code ErrorCode `json:"code"`
	// Op names the operation that failed, e.g. "decode", "dispatch", "listen".
	Op string `json:"op,omitempty"`
	// Message is the human-readable failure description.
	Message string `json:"message"`
	// wrapped is the underlying cause, if any; never serialized.
	wrapped error
}

// Error implements the error interface.
func (e *MembraneError) Error() string {
	if e == nil {
		return "<nil>"
	}
	op := e.Op
	if op == "" {
		op = "api"
	}
	if e.wrapped != nil {
		return fmt.Sprintf("%s: %s: %s: %v", op, e.sentinel().Error(), e.Message, e.wrapped)
	}
	return fmt.Sprintf("%s: %s: %s", op, e.sentinel().Error(), e.Message)
}

// Is reports whether target is this error's sentinel (or its code's
// sentinel). It lets errors.Is match the sentinel even when a wrapped cause
// sits at the head of the chain, where Unwrap alone would stop at the cause.
func (e *MembraneError) Is(target error) bool {
	return target == e.sentinel()
}

// Unwrap supports errors.Is/As. It returns the wrapped cause when present,
// otherwise the code's sentinel — so any *MembraneError matches its sentinel even
// without a cause.
func (e *MembraneError) Unwrap() error {
	if e == nil {
		return nil
	}
	if e.wrapped != nil {
		return e.wrapped
	}
	return e.sentinel()
}

// sentinel maps the code back to its sentinel error.
func (e *MembraneError) sentinel() error {
	switch e.Code {
	case CodeTransport:
		return ErrTransport
	case CodeUpstream:
		return ErrUpstream
	case CodeDeadline:
		return ErrDeadline
	case CodeRefusedEgress:
		return ErrRefusedEgress
	default:
		return ErrUpstream
	}
}

// newTyped is the shared constructor. cause may be nil.
func newTyped(code ErrorCode, op string, cause error, format string, args ...any) *MembraneError {
	msg := format
	if len(args) > 0 {
		msg = fmt.Sprintf(format, args...)
	}
	if cause != nil && msg == "" {
		msg = cause.Error()
	}
	return &MembraneError{Code: code, Op: op, Message: msg, wrapped: cause}
}

// NewTransport builds a CodeTransport error. Pass a nil cause for a
// pure-message error.
//
//	return api.NewTransport("readFrame", err, "frame length out of bounds")
func NewTransport(op string, cause error, format string, args ...any) *MembraneError {
	return newTyped(CodeTransport, op, cause, format, args...)
}

// NewUpstream builds a CodeUpstream error.
//
//	return api.NewUpstream("dispatch", err, "handler %s failed", op)
func NewUpstream(op string, cause error, format string, args ...any) *MembraneError {
	return newTyped(CodeUpstream, op, cause, format, args...)
}

// NewDeadline builds a CodeDeadline error.
func NewDeadline(op string, cause error, format string, args ...any) *MembraneError {
	return newTyped(CodeDeadline, op, cause, format, args...)
}

// NewRefusedEgress builds a CodeRefusedEgress error. Use for policy denials;
// callers should treat it as terminal, not retryable.
func NewRefusedEgress(op string, cause error, format string, args ...any) *MembraneError {
	return newTyped(CodeRefusedEgress, op, cause, format, args...)
}

// Mapping classifies an arbitrary error into a wire ErrorCode. A typed *MembraneError
// maps to its own code; otherwise the wrapped chain is matched against the
// sentinels and context.DeadlineExceeded; anything else is CodeUpstream.
//
//	code := api.Mapping(err) // then api.NewError(id, code, ...)
func Mapping(err error) ErrorCode {
	if err == nil {
		return ""
	}
	var typed *MembraneError
	if errors.As(err, &typed) {
		return typed.Code
	}
	switch {
	case errors.Is(err, ErrTransport):
		return CodeTransport
	case errors.Is(err, ErrDeadline), errors.Is(err, context.DeadlineExceeded):
		return CodeDeadline
	case errors.Is(err, ErrRefusedEgress):
		return CodeRefusedEgress
	case errors.Is(err, ErrUpstream):
		return CodeUpstream
	default:
		return CodeUpstream
	}
}

// NewErrorResponse builds an error Response from any error, mapping it to a
// wire code via Mapping.
//
//	if err != nil {
//		return api.NewErrorResponse(req.ID, err)
//	}
func NewErrorResponse(id string, err error) *Response {
	if err == nil {
		return nil
	}
	var typed *MembraneError
	op := ""
	msg := err.Error()
	if errors.As(err, &typed) {
		op = typed.Op
		msg = typed.Message
	}
	return &Response{ID: id, Error: &Error{Code: Mapping(err), Op: op, Message: msg}}
}
