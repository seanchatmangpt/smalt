// Package armclient is a minimal, CGO-free, stdlib-only ARM client for the
// posh membrane. Auth is OAuth2 client_credentials against the smalt STS
// (enforce mode accepts any client_id/secret). Tokens are cached behind a
// mutex and refreshed 60s before real expiry. Every ARM response carrying
// the X-Smalt-Receipt-Turnstile / X-Smalt-Receipt-Timestamp header pair is
// verified against receipt.VerifyTurnstile("arm.request", ts, requestBody);
// a mismatch is a typed failure — Gate 4 proven end-to-end from Go.
package armclient

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"strconv"
	"strings"
	"sync"
	"time"

	"smalt.dev/posh/internal/receipt"
)

// Headers carrying the smalt receipt turnstile (Elixir lane contract).
const (
	HeaderTurnstile = "X-Smalt-Receipt-Turnstile"
	HeaderTimestamp = "X-Smalt-Receipt-Timestamp"
)

// TurnstileOp is the canonical op string bound into every ARM turnstile.
const TurnstileOp = "arm.request"

// Typed sentinel errors — callers branch on errors.Is, not string matching.
var (
	// ErrUnauthorized is returned when the ARM plane answers 401.
	ErrUnauthorized = errors.New("armclient: 401 unauthorized")
	// ErrServer is returned when the ARM plane answers 5xx.
	ErrServer = errors.New("armclient: 5xx server error")
	// ErrTransport is returned when the request never completes (dial,
	// timeout, refused).
	ErrTransport = errors.New("armclient: transport failure")
	// ErrTurnstile is returned (wrapped) when a turnstile header pair is
	// present but fails verification against the request body. A tampered
	// receipt is distinguishable from a missing one (absent pair = no
	// verification performed, no error).
	ErrTurnstile = errors.New("armclient: receipt turnstile verification failed")
	// ErrUnexpectedStatus is returned for non-2xx, non-401, non-5xx statuses.
	ErrUnexpectedStatus = errors.New("armclient: unexpected status")
)

// Config carries everything the client needs. ClientID/ClientSecret may be
// empty in smalt anonymous mode.
type Config struct {
	ARMEndpoint  string // e.g. http://127.0.0.1:9443
	Tenant       string
	Subscription string
	ClientID     string
	ClientSecret string
	HTTPClient   *http.Client
}

// Client is a minimal ARM client with a mutex-protected token cache.
// Construct with NewClient; the zero value is not usable.
type Client struct {
	cfg  Config
	http *http.Client

	mu    sync.Mutex
	token string
	exp   time.Time
}

// NewClient builds a client from cfg.
func NewClient(cfg Config) *Client {
	hc := cfg.HTTPClient
	if hc == nil {
		hc = http.DefaultClient
	}
	return &Client{cfg: cfg, http: hc}
}

// tokenResp is the OAuth2 client_credentials token response subset we bind.
type tokenResp struct {
	AccessToken string `json:"access_token"`
	ExpiresIn   int64  `json:"expires_in"`
}

// mintToken exchanges client credentials at {arm}/{tenant}/oauth2/v2.0/token.
// Returns (token, refreshAt) where refreshAt is 60s before real expiry.
func (c *Client) mintToken(ctx context.Context) (string, time.Time, error) {
	tokURL := strings.TrimSuffix(c.cfg.ARMEndpoint, "/") + "/" + c.cfg.Tenant + "/oauth2/v2.0/token"
	form := url.Values{}
	form.Set("grant_type", "client_credentials")
	form.Set("client_id", c.cfg.ClientID)
	form.Set("client_secret", c.cfg.ClientSecret)

	req, err := http.NewRequestWithContext(ctx, http.MethodPost, tokURL, strings.NewReader(form.Encode()))
	if err != nil {
		return "", time.Time{}, fmt.Errorf("%w: build token request: %v", ErrTransport, err)
	}
	req.Header.Set("Content-Type", "application/x-www-form-urlencoded")

	resp, err := c.http.Do(req)
	if err != nil {
		return "", time.Time{}, fmt.Errorf("%w: token POST: %v", ErrTransport, err)
	}
	defer resp.Body.Close()

	body, err := io.ReadAll(io.LimitReader(resp.Body, 1<<20))
	if err != nil {
		return "", time.Time{}, fmt.Errorf("%w: read token body: %v", ErrTransport, err)
	}

	if resp.StatusCode == http.StatusUnauthorized {
		return "", time.Time{}, fmt.Errorf("%w: STS 401", ErrUnauthorized)
	}
	if resp.StatusCode >= 500 {
		return "", time.Time{}, fmt.Errorf("%w: STS %d", ErrServer, resp.StatusCode)
	}
	if resp.StatusCode != http.StatusOK {
		return "", time.Time{}, fmt.Errorf("%w: STS status %d", ErrUnexpectedStatus, resp.StatusCode)
	}

	var tr tokenResp
	if err := json.Unmarshal(body, &tr); err != nil || tr.AccessToken == "" {
		return "", time.Time{}, fmt.Errorf("%w: STS token response malformed", ErrUnexpectedStatus)
	}

	ttl := time.Duration(tr.ExpiresIn) * time.Second
	if ttl <= 0 {
		ttl = time.Minute
	}
	// Refresh 60s before real expiry so an in-flight call never rides an
	// expired bearer.
	return tr.AccessToken, time.Now().Add(ttl - 60*time.Second), nil
}

// getToken returns the cached bearer, minting a fresh one when absent or
// within the 60s early-refresh window. Mutex-protected: concurrent callers
// collapse onto one STS hit.
func (c *Client) getToken(ctx context.Context) (string, error) {
	c.mu.Lock()
	defer c.mu.Unlock()
	if c.token != "" && time.Now().Before(c.exp) {
		return c.token, nil
	}
	tok, exp, err := c.mintToken(ctx)
	if err != nil {
		return "", err
	}
	c.token, c.exp = tok, exp
	return tok, nil
}

// APIError carries the non-2xx status and a body summary for typed handling.
type APIError struct {
	Status   int
	BodyText string
}

func (e *APIError) Error() string {
	return fmt.Sprintf("armclient: ARM status %d: %s", e.Status, e.BodyText)
}

// Do performs a GET against the ARM plane at path (e.g.
// "/subscriptions/{sub}/resourcegroups"), with Bearer auth, and verifies the
// receipt turnstile when the response carries the header pair. Returns the
// raw body and final status. Typed errors for 401/5xx/transport; a
// tampered turnstile is ErrTurnstile.
func (c *Client) Do(ctx context.Context, method, path string, requestBody []byte) ([]byte, int, error) {
	tok, err := c.getToken(ctx)
	if err != nil {
		return nil, 0, err
	}

	u := strings.TrimSuffix(c.cfg.ARMEndpoint, "/") + path
	req, err := http.NewRequestWithContext(ctx, method, u, bytesReader(requestBody))
	if err != nil {
		return nil, 0, fmt.Errorf("%w: build request: %v", ErrTransport, err)
	}
	req.Header.Set("Authorization", "Bearer "+tok)
	if len(requestBody) > 0 {
		req.Header.Set("Content-Type", "application/json")
	}

	resp, err := c.http.Do(req)
	if err != nil {
		return nil, 0, fmt.Errorf("%w: %v", ErrTransport, err)
	}
	defer resp.Body.Close()

	body, err := io.ReadAll(io.LimitReader(resp.Body, 8<<20))
	if err != nil {
		return nil, resp.StatusCode, fmt.Errorf("%w: read body: %v", ErrTransport, err)
	}

	// Turnstile verification (Gate 4 consumer): only when the header pair
	// is present. Timestamp is nanoseconds; parse failure is a mismatch.
	if tsHeader := resp.Header.Get(HeaderTimestamp); tsHeader != "" || resp.Header.Get(HeaderTurnstile) != "" {
		if err := verifyTurnstileHeaders(resp.Header.Get(HeaderTurnstile), tsHeader, requestBody); err != nil {
			return body, resp.StatusCode, err
		}
	}

	switch {
	case resp.StatusCode == http.StatusUnauthorized:
		return body, resp.StatusCode, fmt.Errorf("%w: %s", ErrUnauthorized, "ARM 401")
	case resp.StatusCode >= 500:
		return body, resp.StatusCode, ErrServer
	case resp.StatusCode >= 300:
		return body, resp.StatusCode, &APIError{Status: resp.StatusCode, BodyText: summarize(body)}
	}
	return body, resp.StatusCode, nil
}

// ListResourceGroups GETs
// {arm_endpoint}/subscriptions/{sub}/resourcegroups?api-version=2021-04-01.
func (c *Client) ListResourceGroups(ctx context.Context) ([]byte, int, error) {
	return c.Do(ctx, http.MethodGet,
		"/subscriptions/"+c.cfg.Subscription+"/resourcegroups?api-version=2021-04-01", nil)
}

// verifyTurnstileHeaders recomputes the turnstile over (op, ts, requestBody)
// and compares to headerHex. Timestamp must be decimal nanoseconds.
func verifyTurnstileHeaders(headerHex, tsHeader string, requestBody []byte) error {
	ts, err := strconv.ParseUint(tsHeader, 10, 64)
	if err != nil {
		return fmt.Errorf("%w: bad timestamp header", ErrTurnstile)
	}
	ok, err := receipt.VerifyTurnstile(headerHex, TurnstileOp, ts, requestBody)
	if err != nil {
		return fmt.Errorf("%w: %v", ErrTurnstile, err)
	}
	if !ok {
		return ErrTurnstile
	}
	return nil
}

// summarize truncates a body for error text.
func summarize(body []byte) string {
	s := string(body)
	if len(s) > 256 {
		s = s[:256] + "..."
	}
	return s
}

// bytesReader avoids importing bytes for one call site.
func bytesReader(b []byte) io.Reader {
	if len(b) == 0 {
		return nil
	}
	return strings.NewReader(string(b))
}
