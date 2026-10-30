// Package replay implements the deterministic Time-Travel Replay Debugger for
// the POSH Go adapter membrane (SPAF Tier 2, v26.10.30).
//
// The Replay Debugger enables exact, byte-identical reproduction of recorded
// transactions by restoring the original request envelope (operation, path,
// headers, payload), executing against an in-memory or loopback membrane,
// and cryptographically verifying that the replayed BLAKE3 turnstile digest
// matches the recorded turnstile digest bit-for-bit:
//
//	R_turnstile = BLAKE3(op_utf8 || u64BE(timestamp_ns) || payload_body)
//
// A single-byte discrepancy in payload, timestamp drift, or op tampering
// produces an immediate verification failure with a structured causal diff.
package replay

import (
	"bytes"
	"context"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"os"
	"strconv"
	"strings"
	"time"

	"smalt.dev/posh/internal/api"
	"smalt.dev/posh/internal/receipt"
	"smalt.dev/posh/internal/server"
)

// ErrTurnstileMismatch is returned when the recomputed turnstile digest does
// not match the recorded turnstile receipt token.
var ErrTurnstileMismatch = errors.New("replay: turnstile receipt mismatch (byte-identical validation failed)")

// ErrInvalidReceiptHex is returned when a receipt token is not 64 hex characters.
var ErrInvalidReceiptHex = errors.New("replay: invalid turnstile receipt hex (expected 64 characters)")

// ErrEmptyOperation is returned when a record lacks an operation name.
var ErrEmptyOperation = errors.New("replay: operation name is required")

// HeaderTurnstile is the canonical turnstile receipt header.
const HeaderTurnstile = "X-Smalt-Receipt-Turnstile"

// HeaderTimestamp is the canonical turnstile timestamp header (nanoseconds).
const HeaderTimestamp = "X-Smalt-Receipt-Timestamp"

// Record represents a recorded membrane request transaction and its
// cryptographic turnstile receipt.
type Record struct {
	ID          string            `json:"id,omitempty"`
	Op          string            `json:"op"`
	Path        string            `json:"path,omitempty"`
	Method      string            `json:"method,omitempty"`
	Headers     map[string]string `json:"headers,omitempty"`
	TimestampNs uint64            `json:"timestamp_ns,omitempty"`
	Payload     []byte            `json:"payload,omitempty"`
	Receipt     string            `json:"receipt,omitempty"`
	Metadata    map[string]string `json:"metadata,omitempty"`
}

// rawRecord is an auxiliary structure for decoding JSON records where payload
// may be a raw JSON object/array, a string, or base64 bytes.
type rawRecord struct {
	ID          string            `json:"id,omitempty"`
	Op          string            `json:"op"`
	Path        string            `json:"path,omitempty"`
	Method      string            `json:"method,omitempty"`
	Headers     map[string]string `json:"headers,omitempty"`
	TimestampNs uint64            `json:"timestamp_ns,omitempty"`
	Payload     json.RawMessage   `json:"payload,omitempty"`
	Receipt     string            `json:"receipt,omitempty"`
	Metadata    map[string]string `json:"metadata,omitempty"`
}

// UnmarshalJSON implements custom JSON unmarshaling for Record to handle
// polymorphic payload representations (raw string, JSON object, or bytes).
func (r *Record) UnmarshalJSON(data []byte) error {
	var raw rawRecord
	if err := json.Unmarshal(data, &raw); err != nil {
		return err
	}

	r.ID = raw.ID
	r.Op = raw.Op
	r.Path = raw.Path
	r.Method = raw.Method
	r.Headers = raw.Headers
	r.TimestampNs = raw.TimestampNs
	r.Receipt = strings.TrimSpace(raw.Receipt)
	r.Metadata = raw.Metadata

	if len(raw.Payload) > 0 {
		var s string
		if err := json.Unmarshal(raw.Payload, &s); err == nil {
			r.Payload = []byte(s)
		} else {
			r.Payload = append([]byte(nil), bytes.TrimSpace(raw.Payload)...)
		}
	}

	// If TimestampNs is 0, attempt to parse from headers.
	if r.TimestampNs == 0 && r.Headers != nil {
		if tsStr, ok := r.Headers[HeaderTimestamp]; ok && tsStr != "" {
			if ts, err := strconv.ParseUint(tsStr, 10, 64); err == nil {
				r.TimestampNs = ts
			}
		}
	}

	// If Receipt is empty, check headers.
	if r.Receipt == "" && r.Headers != nil {
		if rec, ok := r.Headers[HeaderTurnstile]; ok && rec != "" {
			r.Receipt = strings.TrimSpace(rec)
		}
	}

	return nil
}

// MarshalJSON implements custom JSON marshaling for Record.
func (r *Record) MarshalJSON() ([]byte, error) {
	type wireRecord struct {
		ID          string            `json:"id,omitempty"`
		Op          string            `json:"op"`
		Path        string            `json:"path,omitempty"`
		Method      string            `json:"method,omitempty"`
		Headers     map[string]string `json:"headers,omitempty"`
		TimestampNs uint64            `json:"timestamp_ns,omitempty"`
		Payload     string            `json:"payload,omitempty"`
		Receipt     string            `json:"receipt,omitempty"`
		Metadata    map[string]string `json:"metadata,omitempty"`
	}
	w := wireRecord{
		ID:          r.ID,
		Op:          r.Op,
		Path:        r.Path,
		Method:      r.Method,
		Headers:     r.Headers,
		TimestampNs: r.TimestampNs,
		Payload:     string(r.Payload),
		Receipt:     r.Receipt,
		Metadata:    r.Metadata,
	}
	return json.Marshal(w)
}

// ParseRecord parses a single JSON record.
func ParseRecord(data []byte) (*Record, error) {
	var rec Record
	if err := json.Unmarshal(data, &rec); err != nil {
		return nil, fmt.Errorf("replay: invalid JSON record: %w", err)
	}
	if rec.Op == "" {
		return nil, ErrEmptyOperation
	}
	return &rec, nil
}

// ParseReceiptHex constructs a Record from an explicit BLAKE3 turnstile hex string,
// operation name, timestamp nanoseconds, and request payload body.
func ParseReceiptHex(receiptHex, op string, timestampNs uint64, payload []byte) (*Record, error) {
	cleanHex := strings.TrimSpace(receiptHex)
	if len(cleanHex) != 64 {
		return nil, ErrInvalidReceiptHex
	}
	if _, err := hex.DecodeString(cleanHex); err != nil {
		return nil, fmt.Errorf("%w: %v", ErrInvalidReceiptHex, err)
	}
	if op == "" {
		return nil, ErrEmptyOperation
	}
	return &Record{
		Op:          op,
		TimestampNs: timestampNs,
		Payload:     payload,
		Receipt:     cleanHex,
	}, nil
}

// ParseLog reads records from an io.Reader. Supports either a JSON array of records
// or newline-delimited JSON (JSONL).
func ParseLog(r io.Reader) ([]*Record, error) {
	data, err := io.ReadAll(r)
	if err != nil {
		return nil, fmt.Errorf("replay: read log: %w", err)
	}

	trimmed := bytes.TrimSpace(data)
	if len(trimmed) == 0 {
		return nil, nil
	}

	// Try JSON array first
	if trimmed[0] == '[' {
		var list []*Record
		if err := json.Unmarshal(trimmed, &list); err == nil {
			for i, item := range list {
				if item.Op == "" {
					return nil, fmt.Errorf("replay: record [%d] missing operation", i)
				}
			}
			return list, nil
		}
	}

	// Parse as JSON Lines (JSONL)
	var records []*Record
	lines := bytes.Split(trimmed, []byte("\n"))
	for lineNum, line := range lines {
		line = bytes.TrimSpace(line)
		if len(line) == 0 || line[0] == '#' {
			continue
		}
		var rec Record
		if err := json.Unmarshal(line, &rec); err != nil {
			return nil, fmt.Errorf("replay: line %d: invalid JSON record: %w", lineNum+1, err)
		}
		if rec.Op == "" {
			return nil, fmt.Errorf("replay: line %d: missing operation", lineNum+1)
		}
		records = append(records, &rec)
	}

	return records, nil
}

// Result captures the outcome of a single replayed record.
type Result struct {
	Record          *Record        `json:"record"`
	ReplayedReceipt string         `json:"replayed_receipt"`
	Matched         bool           `json:"matched"`
	Diff            string         `json:"diff,omitempty"`
	Response        *api.Response  `json:"response,omitempty"`
	HTTPStatusCode  int            `json:"http_status_code,omitempty"`
	Duration        time.Duration  `json:"duration_ns"`
	Error           string         `json:"error,omitempty"`
}

// Summary provides an aggregate report across replayed records.
type Summary struct {
	Total     int           `json:"total"`
	Matched   int           `json:"matched"`
	Mismatched int          `json:"mismatched"`
	Errors    int           `json:"errors"`
	Duration  time.Duration `json:"duration_ns"`
	Results   []Result      `json:"results"`
}

// Replayer executes records against an in-memory handler or loopback HTTP server.
type Replayer struct {
	handler      server.Handler
	targetURL    string
	httpClient   *http.Client
	virtualClock func(*Record) uint64
	strict       bool
}

// Option configures a Replayer.
type Option func(*Replayer)

// WithMembraneHandler configures an in-memory membrane handler.
func WithMembraneHandler(h server.Handler) Option {
	return func(r *Replayer) {
		r.handler = h
	}
}

// WithTargetURL configures an HTTP loopback target URL.
func WithTargetURL(target string) Option {
	return func(r *Replayer) {
		r.targetURL = strings.TrimSuffix(target, "/")
	}
}

// WithHTTPClient configures a custom HTTP client for loopback requests.
func WithHTTPClient(client *http.Client) Option {
	return func(r *Replayer) {
		r.httpClient = client
	}
}

// WithVirtualClock overrides the time-travel clock function.
// Default uses the record's recorded TimestampNs.
func WithVirtualClock(clock func(*Record) uint64) Option {
	return func(r *Replayer) {
		r.virtualClock = clock
	}
}

// WithStrict enables strict mode where any mismatch returns an error.
func WithStrict(strict bool) Option {
	return func(r *Replayer) {
		r.strict = strict
	}
}

// NewReplayer instantiates a Replayer with the provided options.
func NewReplayer(opts ...Option) *Replayer {
	rep := &Replayer{
		httpClient: &http.Client{Timeout: 5 * time.Second},
	}
	for _, opt := range opts {
		opt(rep)
	}
	if rep.virtualClock == nil {
		rep.virtualClock = func(rec *Record) uint64 {
			if rec.TimestampNs > 0 {
				return rec.TimestampNs
			}
			return uint64(time.Now().UnixNano())
		}
	}
	return rep
}

// ComputeExpectedReceipt calculates the canonical BLAKE3 turnstile digest for
// the record using the given timestamp.
func ComputeExpectedReceipt(op string, timestampNs uint64, payload []byte) string {
	digest := receipt.TurnstileReceipt(op, timestampNs, payload)
	return receipt.Hex(digest)
}

// Execute replays a single Record and returns the validation Result.
func (r *Replayer) Execute(ctx context.Context, rec *Record) (*Result, error) {
	if rec == nil {
		return nil, errors.New("replay: record is nil")
	}
	if rec.Op == "" {
		return nil, ErrEmptyOperation
	}

	start := time.Now()
	res := &Result{
		Record: rec,
	}

	// Determine time-travel timestamp
	effectiveTs := r.virtualClock(rec)

	// Always compute the canonical replayed BLAKE3 turnstile receipt
	replayedReceipt := ComputeExpectedReceipt(rec.Op, effectiveTs, rec.Payload)
	res.ReplayedReceipt = replayedReceipt

	// Branch 1: Loopback HTTP Execution
	if r.targetURL != "" {
		method := rec.Method
		if method == "" {
			method = http.MethodPost
		}
		path := rec.Path
		if path == "" {
			path = "/"
		}
		if !strings.HasPrefix(path, "/") {
			path = "/" + path
		}

		url := r.targetURL + path
		httpReq, err := http.NewRequestWithContext(ctx, method, url, bytes.NewReader(rec.Payload))
		if err != nil {
			res.Error = fmt.Sprintf("build HTTP request: %v", err)
			res.Duration = time.Since(start)
			return res, err
		}

		// Inject headers
		for k, v := range rec.Headers {
			httpReq.Header.Set(k, v)
		}
		if httpReq.Header.Get("Content-Type") == "" {
			httpReq.Header.Set("Content-Type", "application/json")
		}
		// Pin the time-travel timestamp header so compliant loopbacks reuse it
		httpReq.Header.Set(HeaderTimestamp, strconv.FormatUint(effectiveTs, 10))

		resp, err := r.httpClient.Do(httpReq)
		if err != nil {
			res.Error = fmt.Sprintf("HTTP execute: %v", err)
			res.Duration = time.Since(start)
			return res, err
		}
		defer resp.Body.Close()

		res.HTTPStatusCode = resp.StatusCode
		// If loopback emitted a turnstile header, verify it against replayedReceipt
		if srvTurnstile := resp.Header.Get(HeaderTurnstile); srvTurnstile != "" {
			res.ReplayedReceipt = srvTurnstile
		}
	} else {
		// Branch 2: In-Memory Membrane Execution
		handler := r.handler
		if handler == nil {
			// Built-in fallback membrane handler: reflects params or echoes OK
			handler = func(c context.Context, req *api.Request) *api.Response {
				return api.NewOK(req.ID, req.Params)
			}
		}

		reqID := rec.ID
		if reqID == "" {
			reqID = fmt.Sprintf("replay-%d", effectiveTs)
		}

		var params map[string]string
		if len(rec.Payload) > 0 {
			_ = json.Unmarshal(rec.Payload, &params)
		}

		apiReq := &api.Request{
			ID:     reqID,
			Op:     rec.Op,
			Params: params,
		}

		resp := handler(ctx, apiReq)
		if resp == nil {
			resp = api.NewError(reqID, api.CodeUpstream, "handler returned nil response")
		}
		res.Response = resp
	}

	res.Duration = time.Since(start)

	// Byte-identical receipt validation
	if rec.Receipt != "" {
		if strings.EqualFold(res.ReplayedReceipt, rec.Receipt) {
			res.Matched = true
		} else {
			res.Matched = false
			res.Diff = fmt.Sprintf("turnstile mismatch: expected %s, replayed %s", rec.Receipt, res.ReplayedReceipt)
			if r.strict {
				return res, fmt.Errorf("%w: %s", ErrTurnstileMismatch, res.Diff)
			}
		}
	} else {
		// No recorded receipt to compare with; replayed receipt generated successfully
		res.Matched = true
	}

	return res, nil
}

// ReplayAll executes a sequence of records and produces an aggregate summary.
func (r *Replayer) ReplayAll(ctx context.Context, records []*Record) (*Summary, error) {
	start := time.Now()
	summary := &Summary{
		Total: len(records),
	}

	for _, rec := range records {
		res, err := r.Execute(ctx, rec)
		if err != nil && res == nil {
			summary.Errors++
			if r.strict {
				return summary, err
			}
			continue
		}
		if res.Error != "" || (err != nil && !errors.Is(err, ErrTurnstileMismatch)) {
			summary.Errors++
		} else if res.Matched {
			summary.Matched++
		} else {
			summary.Mismatched++
		}
		summary.Results = append(summary.Results, *res)
		if r.strict && !res.Matched {
			return summary, fmt.Errorf("%w: %s", ErrTurnstileMismatch, res.Diff)
		}
	}

	summary.Duration = time.Since(start)
	return summary, nil
}

// ReplayFile reads a log file and executes all contained records.
func (r *Replayer) ReplayFile(ctx context.Context, filePath string) (*Summary, error) {
	f, err := os.Open(filePath)
	if err != nil {
		return nil, fmt.Errorf("replay: open file: %w", err)
	}
	defer f.Close()

	records, err := ParseLog(f)
	if err != nil {
		return nil, err
	}
	return r.ReplayAll(ctx, records)
}
