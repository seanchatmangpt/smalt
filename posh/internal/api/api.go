// Package api defines the typed membrane request/response envelopes for the
// POSH Go adapter (Tier 2 of the SPAF tri-tier architecture).
//
// Wire format: length-prefixed JSON over the membrane listener (UDS or TCP).
// Every request carries an id, an op name, a params map, and a deadline.
// Every response is exactly one of: ok (with result) or error (with a typed
// error code: TRANSPORT | UPSTREAM | DEADLINE | REFUSED_EGRESS). The BEAM
// core never sees a raw vendor exception — only this envelope.
package api

import (
	"encoding/json"
	"fmt"
	"time"
)

// ErrorCode is the typed error code carried on an error response.
type ErrorCode string

const (
	CodeTransport     ErrorCode = "TRANSPORT"
	CodeUpstream      ErrorCode = "UPSTREAM"
	CodeDeadline      ErrorCode = "DEADLINE"
	CodeRefusedEgress ErrorCode = "REFUSED_EGRESS"
)

// Request is the membrane request envelope.
type Request struct {
	ID       string            `json:"id"`
	Op       string            `json:"op"`
	Params   map[string]string `json:"params,omitempty"`
	Deadline time.Time         `json:"deadline,omitempty"`
}

// Response is the membrane response envelope. Exactly one of Ok or Error is
// non-nil for any well-formed response. Receipt carries the 64-hex-char
// 32-byte BLAKE3 turnstile token (working-backwards.md & design.md §5.1).
type Response struct {
	ID      string `json:"id"`
	Ok      *Ok    `json:"ok,omitempty"`
	Error   *Error `json:"error,omitempty"`
	Receipt string `json:"receipt,omitempty"`
}

// Ok is the success payload.
type Ok struct {
	Result map[string]string `json:"result,omitempty"`
}

// Error is the typed failure payload.
type Error struct {
	Code    ErrorCode `json:"code"`
	Op      string    `json:"op,omitempty"`
	Message string    `json:"message"`
}

// NewOK builds a success response for the given request id.
func NewOK(id string, result map[string]string) *Response {
	return &Response{ID: id, Ok: &Ok{Result: result}}
}

// NewError builds a typed error response for the given request id.
func NewError(id string, code ErrorCode, format string, args ...any) *Response {
	return &Response{ID: id, Error: &Error{Code: code, Message: fmt.Sprintf(format, args...)}}
}

// Encode marshals a Response to JSON bytes.
func Encode(r *Response) ([]byte, error) {
	return json.Marshal(r)
}

// DecodeRequest parses a Request from JSON bytes.
func DecodeRequest(b []byte) (*Request, error) {
	var req Request
	if err := json.Unmarshal(b, &req); err != nil {
		return nil, fmt.Errorf("decode request: %w", err)
	}
	if req.ID == "" {
		return nil, fmt.Errorf("decode request: missing id")
	}
	if req.Op == "" {
		return nil, fmt.Errorf("decode request: missing op")
	}
	return &req, nil
}

// DecodeResponse parses a Response from JSON bytes.
func DecodeResponse(b []byte) (*Response, error) {
	var resp Response
	if err := json.Unmarshal(b, &resp); err != nil {
		return nil, fmt.Errorf("decode response: %w", err)
	}
	if resp.ID == "" {
		return nil, fmt.Errorf("decode response: missing id")
	}
	if (resp.Ok == nil) == (resp.Error == nil) {
		return nil, fmt.Errorf("decode response: exactly one of ok/error required")
	}
	return &resp, nil
}
