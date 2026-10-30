package armclient

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

	"smalt.dev/posh/internal/receipt"
)

// fakePlane is a real in-process collaborator: a combined STS + ARM plane
// (Chicago style — no mocks). It counts STS hits so token-cache behavior is
// observable in request counts, and signs turnstile headers over the exact
// request body the client sends.
type fakePlane struct {
	srv      *httptest.Server
	stsHits  atomic.Int64
	armHits  atomic.Int64
	mu       sync.Mutex
	armCode  int // ARM response status
	armBody  string
	armHeads map[string]string // extra response headers (turnstile pair)
}

func newFakePlane(t *testing.T) *fakePlane {
	t.Helper()
	fp := &fakePlane{armCode: http.StatusOK, armBody: `{"value":[]}`}
	mux := http.NewServeMux()

	// STS: {tenant}/oauth2/v2.0/token
	mux.HandleFunc("/tenant/oauth2/v2.0/token", func(w http.ResponseWriter, r *http.Request) {
		fp.stsHits.Add(1)
		if err := r.ParseForm(); err != nil {
			w.WriteHeader(http.StatusBadRequest)
			return
		}
		if r.FormValue("grant_type") != "client_credentials" {
			w.WriteHeader(http.StatusBadRequest)
			return
		}
		ttl := 3600
		if v := r.Header.Get("X-Test-Ttl"); v != "" {
			fmt.Sscanf(v, "%d", &ttl)
		}
		w.Header().Set("Content-Type", "application/json")
		_ = json.NewEncoder(w).Encode(map[string]any{
			"access_token": fmt.Sprintf("tok-%d", fp.stsHits.Load()),
			"expires_in":   ttl,
		})
	})

	// ARM: resourcegroups — echoes request body back so the turnstile is
	// signed over exactly what the client sent.
	mux.HandleFunc("/subscriptions/sub/resourcegroups", func(w http.ResponseWriter, r *http.Request) {
		fp.armHits.Add(1)
		body, _ := readAll(r)
		if got := r.Header.Get("Authorization"); !strings.HasPrefix(got, "Bearer tok-") {
			w.WriteHeader(http.StatusUnauthorized)
			return
		}
		fp.mu.Lock()
		code, respBody, heads := fp.armCode, fp.armBody, fp.armHeads
		fp.mu.Unlock()

		if heads != nil {
			ts := heads["X-Smalt-Receipt-Timestamp"]
			tsNs := parseUint(t, ts)
			sum := heads["X-Smalt-Receipt-Turnstile"]
			if sum == "" {
				sum = receipt.Hex(receipt.TurnstileReceipt(TurnstileOp, tsNs, body))
			}
			w.Header().Set("X-Smalt-Receipt-Turnstile", sum)
			w.Header().Set("X-Smalt-Receipt-Timestamp", ts)
		}
		w.WriteHeader(code)
		_, _ = w.Write([]byte(respBody))
	})

	fp.srv = httptest.NewServer(mux)
	t.Cleanup(fp.srv.Close)
	return fp
}

func (fp *fakePlane) client() *Client {
	return NewClient(Config{
		ARMEndpoint:  fp.srv.URL,
		Tenant:       "tenant",
		Subscription: "sub",
		ClientID:     "cid",
		ClientSecret: "secret",
	})
}

func readAll(r *http.Request) ([]byte, error) {
	defer r.Body.Close()
	buf := make([]byte, 1<<16)
	n, _ := r.Body.Read(buf)
	return buf[:n], nil
}

func parseUint(t *testing.T, s string) uint64 {
	t.Helper()
	var v uint64
	_, err := fmt.Sscanf(s, "%d", &v)
	if err != nil {
		t.Fatalf("bad timestamp header %q: %v", s, err)
	}
	return v
}

// TestTokenMintAndCacheHit: two calls within expiry produce exactly ONE STS
// hit — the cache collapses the second mint.
func TestTokenMintAndCacheHit(t *testing.T) {
	fp := newFakePlane(t)
	c := fp.client()
	ctx := context.Background()

	body, status, err := c.Do(ctx, http.MethodGet, "/subscriptions/sub/resourcegroups?api-version=2021-04-01", nil)
	if err != nil {
		t.Fatalf("first Do: %v", err)
	}
	if status != http.StatusOK || string(body) != `{"value":[]}` {
		t.Fatalf("first Do: status=%d body=%s", status, body)
	}

	_, _, err = c.Do(ctx, http.MethodGet, "/subscriptions/sub/resourcegroups?api-version=2021-04-01", nil)
	if err != nil {
		t.Fatalf("second Do: %v", err)
	}

	if got := fp.stsHits.Load(); got != 1 {
		t.Fatalf("STS hits = %d, want 1 (cache must reuse token within expiry)", got)
	}
	if got := fp.armHits.Load(); got != 2 {
		t.Fatalf("ARM hits = %d, want 2", got)
	}
}

// TestTokenExpiryRefresh: with a short TTL, the second call mints again.
func TestTokenExpiryRefresh(t *testing.T) {
	fp := newFakePlane(t)
	c := fp.client()
	ctx := context.Background()

	// Shrink the refresh window for the test: TTL 3600 normally minus the
	// 60s early-refresh leaves plenty; force expiry by directly winding the
	// cached expiry backwards through the exported surface (Do with a
	// client whose token expires immediately).
	c.mu.Lock()
	c.token = "stale"
	c.exp = time.Now().Add(-time.Second)
	c.mu.Unlock()

	if _, _, err := c.Do(ctx, http.MethodGet, "/subscriptions/sub/resourcegroups", nil); err != nil {
		t.Fatalf("Do after forced expiry: %v", err)
	}
	if got := fp.stsHits.Load(); got != 1 {
		t.Fatalf("STS hits = %d, want 1 after expiry", got)
	}

	// Real short-TTL path: STS returns expires_in=61 so refreshAt = now+1s;
	// sleep past it via the fake-plane TTL header would be a sleep-based
	// test — instead assert the mint math directly.
	_, refreshAt, err := c.mintToken(ctx)
	if err != nil {
		t.Fatalf("mintToken: %v", err)
	}
	horizon := time.Until(refreshAt)
	if horizon > 3540*time.Second || horizon <= 0 {
		t.Fatalf("refreshAt horizon = %v, want (0, 3540s]", horizon)
	}
}

// TestTurnstileHappy: the signed header pair verifies against the exact
// request body; Do returns no error.
func TestTurnstileHappy(t *testing.T) {
	fp := newFakePlane(t)
	fp.mu.Lock()
	fp.armHeads = map[string]string{
		"X-Smalt-Receipt-Turnstile": "",
		"X-Smalt-Receipt-Timestamp": "1730000000000000000",
	}
	fp.mu.Unlock()

	reqBody := []byte(`{"k":"v"}`)
	c := fp.client()
	if _, status, err := c.Do(context.Background(), http.MethodPut, "/subscriptions/sub/resourcegroups", reqBody); err != nil {
		t.Fatalf("Do with valid turnstile: %v", err)
	} else if status != http.StatusOK {
		t.Fatalf("status=%d", status)
	}
}

// TestTurnstileTamperedReject: a header signed over a different body fails
// with the typed ErrTurnstile.
func TestTurnstileTamperedReject(t *testing.T) {
	fp := newFakePlane(t)
	fp.mu.Lock()
	// Sign over the WRONG body: the plane signs a body the client did not send.
	fp.armHeads = map[string]string{
		"X-Smalt-Receipt-Turnstile": "",
		"X-Smalt-Receipt-Timestamp": "1730000000000000000",
	}
	fp.mu.Unlock()

	// Sabotage: make the plane sign over a different payload by pointing the
	// turnstile op at a different body via a wrapping handler is intrusive;
	// simplest tamper: valid-length hex that is not the digest.
	fp.mu.Lock()
	fp.armHeads["X-Smalt-Receipt-Turnstile"] = strings.Repeat("ab", 32)
	fp.mu.Unlock()

	c := fp.client()
	_, _, err := c.Do(context.Background(), http.MethodPut, "/subscriptions/sub/resourcegroups", []byte(`{"k":"v"}`))
	if err == nil {
		t.Fatal("tampered turnstile accepted")
	}
	if !errors.Is(err, ErrTurnstile) {
		t.Fatalf("err = %v, want ErrTurnstile", err)
	}
}

// TestUnauthorizedTyped: ARM 401 maps to ErrUnauthorized.
func TestUnauthorizedTyped(t *testing.T) {
	fp := newFakePlane(t)
	c := fp.client()
	// Poison the cached token so ARM sees an invalid bearer.
	c.mu.Lock()
	c.token = "bogus"
	c.exp = time.Now().Add(time.Hour)
	c.mu.Unlock()

	_, _, err := c.Do(context.Background(), http.MethodGet, "/subscriptions/sub/resourcegroups", nil)
	if !errors.Is(err, ErrUnauthorized) {
		t.Fatalf("err = %v, want ErrUnauthorized", err)
	}
}

// TestServerTyped: ARM 5xx maps to ErrServer.
func TestServerTyped(t *testing.T) {
	fp := newFakePlane(t)
	fp.mu.Lock()
	fp.armCode = http.StatusBadGateway
	fp.mu.Unlock()

	_, _, err := fp.client().Do(context.Background(), http.MethodGet, "/subscriptions/sub/resourcegroups", nil)
	if !errors.Is(err, ErrServer) {
		t.Fatalf("err = %v, want ErrServer", err)
	}
}
