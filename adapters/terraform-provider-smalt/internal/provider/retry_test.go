package provider

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync"
	"sync/atomic"
	"testing"
	"time"
)

// stsWithServer wires a Client whose ARM endpoint AND tenant STS both point
// at a test server.
func stsWithServer(ts *httptest.Server) *Client {
	return &Client{
		endpoint:       ts.URL,
		http:           &http.Client{},
		tenantID:       defaultTenant,
		clientID:       defaultTenant,
		subscriptionID: "sub-test",
	}
}

// tokenResponseJSON returns a fixed STS body whose JWT exp is far in the future.
func tokenResponseJSON() string {
	jwt := "e30.eyJleHAiOjQxMDI0NDQ4MDB9.sig" // exp = 2100-01-01
	return `{"access_token":"` + jwt + `","expires_in":0}`
}

// TestDoWithRetryFlakyThenSuccess: 429 (Retry-After: 0) then 500 then 200.
// Real HTTP over httptest; assert final state and the exact request count.
func TestDoWithRetryFlakyThenSuccess(t *testing.T) {
	var hits atomic.Int64
	ts := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if strings.HasSuffix(r.URL.Path, "/oauth2/v2.0/token") {
			fmt.Fprint(w, tokenResponseJSON())
			return
		}
		n := int(hits.Add(1))
		switch n {
		case 1:
			w.Header().Set("Retry-After", "0")
			w.WriteHeader(http.StatusTooManyRequests)
			fmt.Fprint(w, `{"error":"throttled"}`)
		case 2:
			w.WriteHeader(http.StatusInternalServerError)
			fmt.Fprint(w, `{"error":"boom"}`)
		default:
			w.WriteHeader(http.StatusOK)
			fmt.Fprint(w, `{"name":"rg-x","location":"eastus"}`)
		}
	}))
	defer ts.Close()

	c := stsWithServer(ts)
	body, status, err := c.do(context.Background(), http.MethodGet, "/subscriptions/s/resourcegroups/rg-x?api-version="+rgAPIVersion, nil, "")
	if err != nil {
		t.Fatalf("do: %v", err)
	}
	if status != http.StatusOK {
		t.Fatalf("status = %d, want 200", status)
	}
	var rg map[string]any
	if err := json.Unmarshal(body, &rg); err != nil {
		t.Fatalf("body parse: %v", err)
	}
	if rg["name"] != "rg-x" {
		t.Fatalf("name = %v, want rg-x", rg["name"])
	}
	if got := hits.Load(); got != 3 {
		t.Fatalf("requests = %d, want 3 (429 + 500 + 200)", got)
	}
}

// TestDoWithRetryExhaustion: server always 503 -> after maxAttempts the client
// surfaces a typed ApiError, and the request count equals the retry budget.
func TestDoWithRetryExhaustion(t *testing.T) {
	var hits atomic.Int64
	ts := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if strings.HasSuffix(r.URL.Path, "/oauth2/v2.0/token") {
			fmt.Fprint(w, tokenResponseJSON())
			return
		}
		hits.Add(1)
		w.WriteHeader(http.StatusServiceUnavailable)
		fmt.Fprint(w, `{"error":"down"}`)
	}))
	defer ts.Close()

	c := stsWithServer(ts)
	_, _, err := c.do(context.Background(), http.MethodGet, "/subscriptions/s/resourcegroups/rg-x?api-version="+rgAPIVersion, nil, "")
	var apiErr *ApiError
	if !errors.As(err, &apiErr) {
		t.Fatalf("want *ApiError, got %T: %v", err, err)
	}
	if apiErr.Status != http.StatusServiceUnavailable {
		t.Fatalf("Status = %d, want 503", apiErr.Status)
	}
	if apiErr.Method != http.MethodGet {
		t.Fatalf("Method = %q, want GET", apiErr.Method)
	}
	if got := hits.Load(); got != int64(maxAttempts) {
		t.Fatalf("hits = %d, want %d", got, int64(maxAttempts))
	}
}

// TestApiErrorMessage renders a readable message with method/path/status/body.
func TestApiErrorMessage(t *testing.T) {
	e := &ApiError{Status: 429, Body: `{"error":"throttled"}`, Method: "PUT", Path: "/subscriptions/s/resourcegroups/rg"}
	msg := e.Error()
	for _, want := range []string{"PUT", "/subscriptions/s/resourcegroups/rg", "429", "throttled"} {
		if !strings.Contains(msg, want) {
			t.Fatalf("Error() = %q, missing %q", msg, want)
		}
	}
}

// TestBackoffHonorsRetryAfter: a server-advised Retry-After overrides
// exponential backoff exactly.
func TestBackoffHonorsRetryAfter(t *testing.T) {
	h := http.Header{}
	h.Set("Retry-After", "1")
	if d := backoffDelay(1, h); d != time.Second {
		t.Fatalf("backoffDelay with Retry-After=1 = %v, want 1s", d)
	}
}

// TestRetryAfterCap: Retry-After=120 is capped at maxRetryAfter (30s).
func TestRetryAfterCap(t *testing.T) {
	h := http.Header{}
	h.Set("Retry-After", "120")
	if d := backoffDelay(1, h); d != maxRetryAfter {
		t.Fatalf("Retry-After=120 gave %v, want cap %v", d, maxRetryAfter)
	}
}

// TestBackoffJitterBounds: without Retry-After, delay is within
// [0, min(2^(n-1)*base, maxBackoff)].
func TestBackoffJitterBounds(t *testing.T) {
	h := http.Header{}
	for attempt := 1; attempt <= 5; attempt++ {
		capAt := baseBackoff << (attempt - 1)
		if capAt > maxBackoff {
			capAt = maxBackoff
		}
		for i := 0; i < 50; i++ {
			d := backoffDelay(attempt, h)
			if d < 0 || d > capAt {
				t.Fatalf("attempt %d: delay %v outside [0, %v]", attempt, d, capAt)
			}
		}
	}
}

// TestRequestTimeoutEnvOverride: TFPOSH_TIMEOUT accepts durations and bare
// seconds; garbage falls back to the 30s default.
func TestRequestTimeoutEnvOverride(t *testing.T) {
	cases := []struct {
		val  string
		want time.Duration
	}{
		{"", 30 * time.Second},
		{"45s", 45 * time.Second},
		{"90", 90 * time.Second},
		{"banana", 30 * time.Second},
		{"-5s", 30 * time.Second},
	}
	for _, tc := range cases {
		t.Run(tc.val, func(t *testing.T) {
			t.Setenv(timeoutEnvVar, tc.val)
			if got := requestTimeout(); got != tc.want {
				t.Fatalf("requestTimeout(%q) = %v, want %v", tc.val, got, tc.want)
			}
		})
	}
}

// TestTokenSingleflightReal: N concurrent Token() calls against a counting
// STS mint exactly one token; all N callers receive the same token.
func TestTokenSingleflightReal(t *testing.T) {
	var stsHits atomic.Int64
	ts := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if strings.HasSuffix(r.URL.Path, "/oauth2/v2.0/token") {
			time.Sleep(30 * time.Millisecond) // widen the refresh window
			stsHits.Add(1)
			fmt.Fprint(w, tokenResponseJSON())
			return
		}
		http.Error(w, "not found", http.StatusNotFound)
	}))
	defer ts.Close()

	c := stsWithServer(ts)
	var wg sync.WaitGroup
	const n = 20
	toks := make([]string, n)
	var firstErr atomic.Value
	for i := 0; i < n; i++ {
		wg.Add(1)
		go func(i int) {
			defer wg.Done()
			tok, err := c.Token(context.Background())
			if err != nil && firstErr.Load() == nil {
				firstErr.Store(err)
			}
			toks[i] = tok
		}(i)
	}
	wg.Wait()
	if firstErr.Load() != nil {
		t.Fatalf("token error: %v", firstErr.Load())
	}
	for i, tok := range toks {
		if tok == "" {
			t.Fatalf("caller %d got empty token", i)
		}
		if tok != toks[0] {
			t.Fatalf("caller %d got a different token than caller 0", i)
		}
	}
	if got := stsHits.Load(); got != 1 {
		t.Fatalf("STS mints = %d, want 1 (singleflight)", got)
	}
}

// TestTransportErrorRetried: against a closed server the request eventually
// surfaces a raw transport error (not an ApiError) after the budget is spent.
func TestTransportErrorRetried(t *testing.T) {
	ts := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		fmt.Fprint(w, tokenResponseJSON())
	}))
	url := ts.URL
	ts.Close() // now closed -> connection-refused class errors

	c := stsWithServer(&httptest.Server{URL: url})
	_, _, err := c.do(context.Background(), http.MethodGet, "/subscriptions/s/resourcegroups/rg?api-version="+rgAPIVersion, nil, "")
	if err == nil {
		t.Fatalf("want transport error, got nil")
	}
	var apiErr *ApiError
	if errors.As(err, &apiErr) {
		t.Fatalf("transport error wrongly typed as ApiError: %v", err)
	}
}

// TestPerRequestTimeout: a handler that sleeps longer than TFPOSH_TIMEOUT is
// cut off by the per-request deadline (surface as a context error).
func TestPerRequestTimeout(t *testing.T) {
	ts := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if strings.HasSuffix(r.URL.Path, "/oauth2/v2.0/token") {
			fmt.Fprint(w, tokenResponseJSON())
			return
		}
		time.Sleep(2 * time.Second)
		fmt.Fprint(w, "{}")
	}))
	defer ts.Close()

	t.Setenv(timeoutEnvVar, "150ms")
	c := stsWithServer(ts)
	_, _, err := c.do(context.Background(), http.MethodGet, "/subscriptions/s/resourcegroups/rg?api-version="+rgAPIVersion, nil, "")
	if err == nil {
		t.Fatalf("want timeout error, got nil")
	}
	if !errIsContext(err) {
		t.Fatalf("err = %v, want context deadline error", err)
	}
}
