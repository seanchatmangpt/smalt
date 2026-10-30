// Package chaos provides an in-memory adversarial fault injection harness for
// the POSH membrane listener, upstream HTTP ARM client, and wire-level UDS framing.
//
// Capabilities:
//   - Network jitter & latency distribution (Pareto / Uniform).
//   - Dropped UDS frames (silent drop, half-close, connection reset).
//   - Cryptographic turnstile signature corruption (bit-flip, truncation, invalid hex).
//   - Upstream ARM 503 Service Unavailable / 429 Too Many Requests storms.
//   - Deterministic replay via seeded pseudo-random number generator.
package chaos

import (
	"bytes"
	"context"
	"encoding/binary"
	"io"
	"math/rand"
	"net"
	"net/http"
	"strconv"
	"sync"
	"time"

	"smalt.dev/posh/internal/api"
	"smalt.dev/posh/internal/receipt"
	"smalt.dev/posh/internal/server"
)

// FaultProfile defines the probabilistic and deterministic faults to inject.
type FaultProfile struct {
	// Seed sets the PRNG seed for deterministic failure sequences. 0 uses wall clock.
	Seed int64

	// JitterMin and JitterMax define the range of injected artificial delay.
	JitterMin time.Duration
	JitterMax time.Duration

	// DropFrameRate is the probability [0.0, 1.0] of dropping a UDS framed message.
	DropFrameRate float64

	// CorruptTurnstileRate is the probability [0.0, 1.0] of corrupting the BLAKE3 receipt.
	CorruptTurnstileRate float64

	// Upstream503Rate is the probability [0.0, 1.0] of injecting an upstream 503 storm.
	Upstream503Rate float64

	// Upstream429Rate is the probability [0.0, 1.0] of injecting an upstream 429 storm.
	Upstream429Rate float64

	// RetryAfterSeconds is the retry-after duration echoed in 429 responses.
	RetryAfterSeconds int

	// TruncateFrameRate is the probability [0.0, 1.0] of truncating a wire-level frame.
	TruncateFrameRate float64
}

// Engine coordinates fault decisions with thread-safe pseudo-randomness.
type Engine struct {
	mu      sync.Mutex
	rng     *rand.Rand
	profile FaultProfile
	stats   Stats
}

// Stats tracks injected fault metrics for audit and assertions.
type Stats struct {
	TotalRequests     int64
	InjectedJitters   int64
	DroppedFrames     int64
	CorruptedReceipts int64
	Injected503Storms int64
	Injected429Storms int64
	TruncatedFrames   int64
}

// NewEngine creates a new Chaos Engine with the specified fault profile.
func NewEngine(profile FaultProfile) *Engine {
	seed := profile.Seed
	if seed == 0 {
		seed = time.Now().UnixNano()
	}
	if profile.RetryAfterSeconds == 0 {
		profile.RetryAfterSeconds = 5
	}
	return &Engine{
		rng:     rand.New(rand.NewSource(seed)),
		profile: profile,
	}
}

// Stats returns a snapshot of injected fault metrics.
func (e *Engine) Stats() Stats {
	e.mu.Lock()
	defer e.mu.Unlock()
	return e.stats
}

func (e *Engine) coinFlip(p float64) bool {
	if p <= 0 {
		return false
	}
	if p >= 1.0 {
		return true
	}
	return e.rng.Float64() < p
}

// InterceptHandler decorates a server.Handler with in-memory faults:
// artificial jitter, upstream 503/429 storms, and turnstile signature corruption.
func (e *Engine) InterceptHandler(next server.Handler) server.Handler {
	return func(ctx context.Context, req *api.Request) *api.Response {
		e.mu.Lock()
		e.stats.TotalRequests++
		jitter := time.Duration(0)
		if e.profile.JitterMax > e.profile.JitterMin {
			delta := e.profile.JitterMax - e.profile.JitterMin
			jitter = e.profile.JitterMin + time.Duration(e.rng.Int63n(int64(delta)))
		} else if e.profile.JitterMin > 0 {
			jitter = e.profile.JitterMin
		}

		inject503 := e.coinFlip(e.profile.Upstream503Rate)
		inject429 := !inject503 && e.coinFlip(e.profile.Upstream429Rate)
		corruptSig := e.coinFlip(e.profile.CorruptTurnstileRate)
		dropFrame := e.coinFlip(e.profile.DropFrameRate)

		if jitter > 0 {
			e.stats.InjectedJitters++
		}
		if inject503 {
			e.stats.Injected503Storms++
		} else if inject429 {
			e.stats.Injected429Storms++
		}
		if corruptSig {
			e.stats.CorruptedReceipts++
		}
		if dropFrame {
			e.stats.DroppedFrames++
		}
		e.mu.Unlock()

		if jitter > 0 {
			select {
			case <-ctx.Done():
				return api.NewError(req.ID, api.CodeDeadline, "deadline exceeded during chaos jitter: %v", ctx.Err())
			case <-time.After(jitter):
			}
		}

		if inject503 {
			return api.NewError(req.ID, api.CodeUpstream,
				"upstream HTTP 503 Service Unavailable: cloud control plane storm injected by chaos engine")
		}

		if inject429 {
			return api.NewError(req.ID, api.CodeUpstream,
				"upstream HTTP 429 Too Many Requests (retry-after: %ds): rate limit burst injected by chaos engine",
				e.profile.RetryAfterSeconds)
		}

		if dropFrame {
			// Simulates handler dropping request completely (returns nil)
			return nil
		}

		// Delegate to underlying handler
		resp := next(ctx, req)
		if resp == nil {
			return nil
		}

		// Adversarial signature corruption: mutate turnstile token if requested
		if corruptSig && resp.Receipt != "" {
			resp.Receipt = CorruptReceiptString(resp.Receipt)
		}

		return resp
	}
}

// CorruptReceiptString introduces an adversarial bit-flip or invalid hex character
// into a 64-hex-char BLAKE3 receipt string to verify client detection.
func CorruptReceiptString(token string) string {
	if len(token) != 64 {
		return "invalid-hex-receipt"
	}
	b := []byte(token)
	// Invert the first character between '0' and 'f'
	if b[0] == '0' {
		b[0] = '1'
	} else if b[0] == 'f' {
		b[0] = 'e'
	} else {
		b[0] = '0'
	}
	return string(b)
}

// ChaosRoundTripper wraps an http.RoundTripper (e.g. for armclient) to simulate
// cloud API outages, 503/429 storms, and HTTP latency.
type ChaosRoundTripper struct {
	engine *Engine
	base   http.RoundTripper
}

// NewChaosRoundTripper wraps an existing HTTP transport with fault injection.
func NewChaosRoundTripper(engine *Engine, base http.RoundTripper) *ChaosRoundTripper {
	if base == nil {
		base = http.DefaultTransport
	}
	return &ChaosRoundTripper{engine: engine, base: base}
}

// RoundTrip executes outbound HTTP requests with probabilistic fault injection.
func (rt *ChaosRoundTripper) RoundTrip(req *http.Request) (*http.Response, error) {
	e := rt.engine

	e.mu.Lock()
	inject503 := e.coinFlip(e.profile.Upstream503Rate)
	inject429 := !inject503 && e.coinFlip(e.profile.Upstream429Rate)
	if inject503 {
		e.stats.Injected503Storms++
	} else if inject429 {
		e.stats.Injected429Storms++
	}
	e.mu.Unlock()

	if inject503 {
		return &http.Response{
			StatusCode: http.StatusServiceUnavailable,
			Status:     "503 Service Unavailable",
			Proto:      "HTTP/1.1",
			ProtoMajor: 1,
			ProtoMinor: 1,
			Body:       io.NopCloser(bytes.NewBufferString(`{"error":{"code":"ServiceUnavailable","message":"Backend saturated"}}`)),
			Header:     make(http.Header),
			Request:    req,
		}, nil
	}

	if inject429 {
		h := make(http.Header)
		h.Set("Retry-After", strconv.Itoa(e.profile.RetryAfterSeconds))
		h.Set("x-ms-ratelimit-remaining-subscription-reads", "0")
		return &http.Response{
			StatusCode: http.StatusTooManyRequests,
			Status:     "429 Too Many Requests",
			Proto:      "HTTP/1.1",
			ProtoMajor: 1,
			ProtoMinor: 1,
			Body:       io.NopCloser(bytes.NewBufferString(`{"error":{"code":"TooManyRequests","message":"Subscription rate limit exceeded"}}`)),
			Header:     h,
			Request:    req,
		}, nil
	}

	return rt.base.RoundTrip(req)
}

// ChaosConn wraps a net.Conn to inject wire-level framing anomalies:
// dropped frames, truncated frame reads, and slowloris byte delivery.
type ChaosConn struct {
	net.Conn
	engine *Engine
}

// WrapConn wraps an active network socket connection with chaos interceptors.
func WrapConn(c net.Conn, engine *Engine) *ChaosConn {
	return &ChaosConn{Conn: c, engine: engine}
}

// Read intercepts connection reads to inject truncation or dropped frames.
func (c *ChaosConn) Read(b []byte) (n int, err error) {
	e := c.engine

	e.mu.Lock()
	drop := e.coinFlip(e.profile.DropFrameRate)
	truncate := !drop && e.coinFlip(e.profile.TruncateFrameRate)
	if drop {
		e.stats.DroppedFrames++
	}
	if truncate {
		e.stats.TruncatedFrames++
	}
	e.mu.Unlock()

	if drop {
		// Simulates connection reset or immediate EOF
		return 0, io.EOF
	}

	n, err = c.Conn.Read(b)
	if err != nil {
		return n, err
	}

	if truncate && n > 4 {
		// Cut frame midway after the 4-byte header
		cut := 4 + (n-4)/2
		return cut, nil
	}

	return n, nil
}

// Write intercepts connection writes to inject partial writes or simulated drop.
func (c *ChaosConn) Write(b []byte) (n int, err error) {
	e := c.engine

	e.mu.Lock()
	drop := e.coinFlip(e.profile.DropFrameRate)
	if drop {
		e.stats.DroppedFrames++
	}
	e.mu.Unlock()

	if drop {
		// Silently consume bytes without sending them to peer
		return len(b), nil
	}

	return c.Conn.Write(b)
}

// VerifyOrDetectCorruption tests whether an admitted turnstile receipt is valid,
// returning true if intact and false if corrupted by chaos.
func VerifyOrDetectCorruption(receiptHex, op string, ts uint64, payload []byte) bool {
	valid, err := receipt.VerifyTurnstile(receiptHex, op, ts, payload)
	return err == nil && valid
}

// MakeCorruptedFrame constructs an intentionally corrupt frame for wire-level testing:
// mode: 0 = length mismatch, 1 = bit flip in JSON, 2 = oversized length prefix.
func MakeCorruptedFrame(payload []byte, mode int) []byte {
	var buf bytes.Buffer
	switch mode {
	case 0:
		// Length declared is larger than actual payload
		binary.Write(&buf, binary.BigEndian, uint32(len(payload)+128))
		buf.Write(payload)
	case 1:
		// Corrupted JSON body
		binary.Write(&buf, binary.BigEndian, uint32(len(payload)))
		corrupt := append([]byte(nil), payload...)
		if len(corrupt) > 2 {
			corrupt[1] = 0xff // invalidate JSON syntax
		}
		buf.Write(corrupt)
	case 2:
		// Oversized length (>4 MiB)
		binary.Write(&buf, binary.BigEndian, uint32(server.MaxFrameBytes+1024))
		buf.Write(payload)
	default:
		binary.Write(&buf, binary.BigEndian, uint32(len(payload)))
		buf.Write(payload)
	}
	return buf.Bytes()
}
