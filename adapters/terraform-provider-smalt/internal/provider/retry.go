package provider

import (
	"context"
	"errors"
	"fmt"
	"io"
	"log/slog"
	"math/rand"
	"net/http"
	"os"
	"strconv"
	"strings"
	"time"
)

const (
	defaultRequestTimeout = 30 * time.Second
	timeoutEnvVar         = "TFPOSH_TIMEOUT"

	maxAttempts   = 4
	baseBackoff   = 250 * time.Millisecond
	maxBackoff    = 5 * time.Second
	maxRetryAfter = 30 * time.Second
)

// ApiError is a typed non-2xx ARM plane response.
type ApiError struct {
	Status int    // HTTP status code
	Body   string // truncated response body
	Method string
	Path   string
}

func (e *ApiError) Error() string {
	return fmt.Sprintf("%s %s: status %d: %s", e.Method, e.Path, e.Status, e.Body)
}

// retryable reports whether a status code is worth retrying (429 and 5xx).
func retryable(status int) bool {
	return status == http.StatusTooManyRequests || status >= 500
}

// requestTimeout returns the hard per-request context timeout, overridable
// via TFPOSH_TIMEOUT (Go duration string like "45s", or bare seconds "45").
func requestTimeout() time.Duration {
	v := strings.TrimSpace(os.Getenv(timeoutEnvVar))
	if v == "" {
		return defaultRequestTimeout
	}
	if d, err := time.ParseDuration(v); err == nil && d > 0 {
		return d
	}
	if secs, err := strconv.Atoi(v); err == nil && secs > 0 {
		return time.Duration(secs) * time.Second
	}
	slog.Warn("invalid TFPOSH_TIMEOUT, using default", "value", v, "default", defaultRequestTimeout)
	return defaultRequestTimeout
}

// retryAfter extracts the server-advised wait from a Retry-After header
// (delta-seconds form; HTTP-date form falls back to base backoff).
func retryAfter(h http.Header) (time.Duration, bool) {
	v := strings.TrimSpace(h.Get("Retry-After"))
	if v == "" {
		return 0, false
	}
	if secs, err := strconv.Atoi(v); err == nil && secs >= 0 {
		d := time.Duration(secs) * time.Second
		if d > maxRetryAfter {
			d = maxRetryAfter
		}
		return d, true
	}
	return 0, false
}

// backoffDelay computes the wait before attempt n (1-based): exponential
// with full jitter, capped at maxBackoff. A server-provided Retry-After wins.
func backoffDelay(attempt int, h http.Header) time.Duration {
	if d, ok := retryAfter(h); ok {
		return d
	}
	d := baseBackoff << (attempt - 1) // 250ms, 500ms, 1s, ...
	if d > maxBackoff {
		d = maxBackoff
	}
	return time.Duration(rand.Int63n(int64(d) + 1)) // full jitter in [0, d)
}

// doWithRetry runs send until it succeeds, the retry budget is exhausted
// (maxAttempts), or the context is cancelled. Retries 429/5xx responses and
// transport errors, honoring Retry-After. It returns the last response's
// status/header/body on exhaustion. On a retryable failure the response body
// has already been drained and closed before sleeping.
func doWithRetry(ctx context.Context, op string, send func(ctx context.Context) (*http.Response, []byte, error)) (status int, hdr http.Header, body []byte, err error) {
	var lastErr error
	for attempt := 1; attempt <= maxAttempts; attempt++ {
		resp, b, sendErr := send(ctx)
		if sendErr == nil && !retryable(resp.StatusCode) {
			return resp.StatusCode, resp.Header, b, nil
		}
		if resp != nil {
			status, hdr, body = resp.StatusCode, resp.Header, b
		}
		lastErr = sendErr

		if attempt == maxAttempts {
			break
		}
		var hdrForDelay http.Header
		if resp != nil {
			hdrForDelay = resp.Header
		}
		delay := backoffDelay(attempt, hdrForDelay)
		slog.Debug("retrying request", "op", op, "attempt", attempt,
			"delay", delay.String(), "err", errString(sendErr))

		select {
		case <-ctx.Done():
			return status, hdr, body, ctx.Err()
		case <-time.After(delay):
		}
	}
	if lastErr != nil {
		return status, hdr, body, lastErr
	}
	return status, hdr, body, nil
}

func errString(err error) string {
	if err == nil {
		return ""
	}
	return err.Error()
}

// closeAndRead drains and closes a response body, truncating to 1MiB.
func closeAndRead(resp *http.Response) ([]byte, error) {
	defer resp.Body.Close()
	return io.ReadAll(io.LimitReader(resp.Body, 1<<20))
}

// errIsContext reports whether err is a context cancellation/deadline error.
func errIsContext(err error) bool {
	return errors.Is(err, context.Canceled) || errors.Is(err, context.DeadlineExceeded)
}
