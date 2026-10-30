package provider

import (
	"bytes"
	"context"
	"crypto/tls"
	"crypto/x509"
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"log/slog"
	"net/http"
	"net/url"
	"os"
	"strings"
	"sync"
	"sync/atomic"
	"time"

	"github.com/hashicorp/terraform-plugin-framework/diag"
)

const (
	defaultARMEndpoint = "http://127.0.0.1:9443"
	defaultTenant      = "00000000-0000-0000-0000-000000000000"
	mockClientSecret   = "smalt-sovereign-mock-secret"
	rgAPIVersion       = "2023-07-01"
)

type tokenSnapshot struct {
	token string
	exp   time.Time
}

// Client talks to the smalt ARM plane over plain HTTP (localhost allowance)
// with an optional TLS twin via ca_cert.
type Client struct {
	endpoint       string
	subscriptionID string
	tenantID       string
	clientID       string
	http           *http.Client

	cached     atomic.Pointer[tokenSnapshot]
	mu         sync.Mutex
	refreshing chan struct{} // non-nil while a token mint is in flight (singleflight)
}

type tokenResponse struct {
	AccessToken string `json:"access_token"`
	ExpiresIn   int    `json:"expires_in"`
}

// NewClient builds an ARM client. armEndpoint empty falls back to
// SMALT_ARM_ENDPOINT then the localhost default.
func NewClient(ctx context.Context, armEndpoint, subscriptionID, tenantID, clientID, caCert string) (*Client, error) {
	if armEndpoint == "" {
		armEndpoint = os.Getenv("SMALT_ARM_ENDPOINT")
	}
	if armEndpoint == "" {
		armEndpoint = defaultARMEndpoint
	}
	if tenantID == "" {
		tenantID = defaultTenant
	}
	if clientID == "" {
		clientID = defaultTenant
	}

	transport := http.DefaultTransport.(*http.Transport).Clone()
	transport.MaxIdleConns = 128
	transport.MaxIdleConnsPerHost = 64
	transport.IdleConnTimeout = 90 * time.Second
	transport.DisableCompression = true
	if caCert != "" && (strings.HasPrefix(armEndpoint, "https://") || caCert != "") {
		pool := x509.NewCertPool()
		if ok := pool.AppendCertsFromPEM([]byte(caCert)); !ok {
			return nil, fmt.Errorf("ca_cert: no PEM certificates found")
		}
		transport.TLSClientConfig = &tls.Config{RootCAs: pool}
	}

	return &Client{
		endpoint:       strings.TrimSuffix(armEndpoint, "/"),
		subscriptionID: subscriptionID,
		tenantID:       tenantID,
		clientID:       clientID,
		http:           &http.Client{Transport: transport, Timeout: defaultRequestTimeout},
	}, nil
}

// Token mints a bearer via the smalt STS (client_credentials, v2.0 endpoint)
// and caches until expiry minus 60s.
//
// Fast path: 100% lock-free atomic.Pointer[tokenSnapshot] load, avoiding mutex
// contention across parallel Terraform resource workers.
//
// Slow path: singleflight channel coalescing with context.WithoutCancel(ctx)
// bounded by requestTimeout(), so a cancelled caller does not abort the
// shared STS mint for sibling goroutines waiting on the same token.
func (c *Client) Token(ctx context.Context) (string, error) {
	if snap := c.cached.Load(); snap != nil && snap.token != "" && time.Now().Before(snap.exp.Add(-60*time.Second)) {
		return snap.token, nil
	}

	for {
		c.mu.Lock()
		if snap := c.cached.Load(); snap != nil && snap.token != "" && time.Now().Before(snap.exp.Add(-60*time.Second)) {
			c.mu.Unlock()
			return snap.token, nil
		}
		if ch := c.refreshing; ch != nil {
			c.mu.Unlock()
			slog.Debug("token refresh already in flight, waiting")
			select {
			case <-ch:
			case <-ctx.Done():
				return "", ctx.Err()
			}
			continue // double-check: cache may now be valid
		}
		ch := make(chan struct{})
		c.refreshing = ch
		c.mu.Unlock()

		mintCtx, cancel := context.WithTimeout(context.WithoutCancel(ctx), requestTimeout())
		tok, exp, err := c.mintToken(mintCtx)
		cancel()

		c.mu.Lock()
		c.refreshing = nil
		if err == nil {
			c.cached.Store(&tokenSnapshot{token: tok, exp: exp})
		}
		c.mu.Unlock()
		close(ch) // wake waiters AFTER atomic cache store so their re-check sees it

		if err != nil {
			if ctx.Err() != nil {
				return "", ctx.Err()
			}
			return "", err
		}
		if ctx.Err() != nil {
			return "", ctx.Err()
		}
		return tok, nil
	}
}

func (c *Client) mintToken(ctx context.Context) (string, time.Time, error) {
	tokURL := fmt.Sprintf("%s/%s/oauth2/v2.0/token", c.endpoint, c.tenantID)
	form := url.Values{
		"grant_type":    {"client_credentials"},
		"client_id":     {c.clientID},
		"client_secret": {mockClientSecret},
		"scope":         {"https://management.azure.com/.default"},
	}
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, tokURL, strings.NewReader(form.Encode()))
	if err != nil {
		return "", time.Time{}, err
	}
	req.Header.Set("Content-Type", "application/x-www-form-urlencoded")

	slog.Debug("STS token request", "method", http.MethodPost, "path", "/"+c.tenantID+"/oauth2/v2.0/token")
	resp, err := c.http.Do(req)
	if err != nil {
		return "", time.Time{}, fmt.Errorf("STS token request: %w", err)
	}
	body, err := closeAndRead(resp)
	if err != nil {
		return "", time.Time{}, err
	}
	if resp.StatusCode != http.StatusOK {
		return "", time.Time{}, &ApiError{
			Status: resp.StatusCode,
			Body:   truncate(body),
			Method: http.MethodPost,
			Path:   "/" + c.tenantID + "/oauth2/v2.0/token",
		}
	}

	var tr tokenResponse
	if err := json.Unmarshal(body, &tr); err != nil {
		return "", time.Time{}, fmt.Errorf("STS token parse: %w", err)
	}
	if tr.AccessToken == "" {
		return "", time.Time{}, fmt.Errorf("STS token response missing access_token")
	}
	expiry := time.Now().Add(time.Duration(tr.ExpiresIn) * time.Second)
	if tr.ExpiresIn == 0 {
		expiry = parseJWTExpiry(tr.AccessToken)
	}
	return tr.AccessToken, expiry, nil
}

// parseJWTExpiry extracts exp from an unverified JWT (the smalt STS is the
// authority; the signature is not checked by the client).
func parseJWTExpiry(jwt string) time.Time {
	parts := strings.Split(jwt, ".")
	if len(parts) != 3 {
		return time.Now().Add(5 * time.Minute)
	}
	payload, err := base64RawURLDecode(parts[1])
	if err != nil {
		return time.Now().Add(5 * time.Minute)
	}
	var claims struct {
		Exp int64 `json:"exp"`
	}
	if json.Unmarshal(payload, &claims) != nil || claims.Exp == 0 {
		return time.Now().Add(5 * time.Minute)
	}
	return time.Unix(claims.Exp, 0)
}

func base64RawURLDecode(s string) ([]byte, error) {
	return base64.RawURLEncoding.DecodeString(strings.TrimRight(s, "="))
}

// do issues an authenticated ARM request with a hard per-request context
// timeout (TFPOSH_TIMEOUT, default 30s) and bounded retry with exponential
// backoff + jitter for 429/5xx/transport errors, honoring Retry-After.
// Non-retryable non-2xx responses come back as a typed *ApiError.
func (c *Client) do(ctx context.Context, method, path string, body []byte, contentType string) ([]byte, int, error) {
	rctx, cancel := context.WithTimeout(ctx, requestTimeout())
	defer cancel()

	tok, err := c.Token(rctx)
	if err != nil {
		return nil, 0, err
	}

	send := func(ac context.Context) (*http.Response, []byte, error) {
		req, err := http.NewRequestWithContext(ac, method, c.endpoint+path, bytes.NewReader(body))
		if err != nil {
			return nil, nil, err
		}
		req.Header.Set("Authorization", "Bearer "+tok)
		if contentType != "" {
			req.Header.Set("Content-Type", contentType)
		}
		slog.Debug("ARM request", "method", method, "path", path)
		resp, err := c.http.Do(req)
		if err != nil {
			return nil, nil, err
		}
		b, readErr := closeAndRead(resp)
		slog.Debug("ARM response", "method", method, "path", path, "status", resp.StatusCode)
		return resp, b, readErr
	}

	status, _, respBody, err := doWithRetry(rctx, method+" "+path, send)
	if err != nil {
		return nil, status, err
	}
	if retryable(status) {
		// exhausted the retry budget on 429/5xx
		return nil, status, &ApiError{Status: status, Body: truncate(respBody), Method: method, Path: path}
	}
	if status < 200 || status >= 300 {
		return nil, status, &ApiError{Status: status, Body: truncate(respBody), Method: method, Path: path}
	}
	return respBody, status, nil
}

func truncate(b []byte) string {
	s := string(b)
	if len(s) > 300 {
		s = s[:300]
	}
	return s
}

func withAPIVersion(path, apiVersion string) string {
	if apiVersion == "" || strings.Contains(path, "api-version=") {
		return path
	}
	if strings.Contains(path, "?") {
		return path + "&api-version=" + url.QueryEscape(apiVersion)
	}
	return path + "?api-version=" + url.QueryEscape(apiVersion)
}

func (c *Client) doWithHeaders(ctx context.Context, method, path string, reqHeaders map[string]string, body []byte, contentType string) ([]byte, http.Header, int, error) {
	rctx, cancel := context.WithTimeout(ctx, requestTimeout())
	defer cancel()

	tok, err := c.Token(rctx)
	if err != nil {
		return nil, nil, 0, err
	}

	send := func(ac context.Context) (*http.Response, []byte, error) {
		var bodyReader *bytes.Reader
		if body != nil {
			bodyReader = bytes.NewReader(body)
		} else {
			bodyReader = bytes.NewReader(nil)
		}
		req, err := http.NewRequestWithContext(ac, method, c.endpoint+path, bodyReader)
		if err != nil {
			return nil, nil, err
		}
		req.Header.Set("Authorization", "Bearer "+tok)
		if contentType != "" {
			req.Header.Set("Content-Type", contentType)
		}
		for k, v := range reqHeaders {
			if v != "" {
				req.Header.Set(k, v)
			}
		}
		slog.Debug("ARM request", "method", method, "path", path)
		resp, err := c.http.Do(req)
		if err != nil {
			return nil, nil, err
		}
		b, readErr := closeAndRead(resp)
		slog.Debug("ARM response", "method", method, "path", path, "status", resp.StatusCode)
		return resp, b, readErr
	}

	status, hdr, respBody, err := doWithRetry(rctx, method+" "+path, send)
	if err != nil {
		return nil, hdr, status, err
	}
	if retryable(status) {
		return respBody, hdr, status, &ApiError{Status: status, Body: truncate(respBody), Method: method, Path: path}
	}
	if status < 200 || status >= 300 {
		return respBody, hdr, status, &ApiError{Status: status, Body: truncate(respBody), Method: method, Path: path}
	}
	return respBody, hdr, status, nil
}

// GetRaw performs an authenticated GET, returning raw body bytes, response ETag, HTTP status, and error.
// If out is non-nil and the response is 2xx with a non-empty body, the JSON body is unmarshaled into out.
func (c *Client) GetRaw(ctx context.Context, path, apiVersion string, out any) (raw []byte, etag string, status int, err error) {
	fullPath := withAPIVersion(path, apiVersion)
	raw, hdr, status, err := c.doWithHeaders(ctx, http.MethodGet, fullPath, nil, nil, "")
	if hdr != nil {
		etag = hdr.Get("ETag")
	}
	if err != nil {
		return raw, etag, status, err
	}
	if out != nil && len(raw) > 0 {
		if uerr := json.Unmarshal(raw, out); uerr != nil {
			return raw, etag, status, fmt.Errorf("GET %s decode: %w", path, uerr)
		}
	}
	return raw, etag, status, nil
}

// PutWithETag performs an authenticated PUT with an optional If-Match header, returning raw body bytes, ETag, HTTP status, and error.
// If body is []byte it is sent verbatim; otherwise it is JSON-marshaled.
// If out is non-nil and the response is 2xx with a non-empty body, the JSON body is unmarshaled into out.
func (c *Client) PutWithETag(ctx context.Context, path, apiVersion, ifMatch string, body any, out any) (raw []byte, etag string, status int, err error) {
	fullPath := withAPIVersion(path, apiVersion)
	var payload []byte
	if body != nil {
		switch v := body.(type) {
		case []byte:
			payload = v
		case json.RawMessage:
			payload = []byte(v)
		default:
			payload, err = json.Marshal(body)
			if err != nil {
				return nil, "", 0, fmt.Errorf("PUT %s encode: %w", path, err)
			}
		}
	}
	var hdrs map[string]string
	if ifMatch != "" {
		hdrs = map[string]string{"If-Match": ifMatch}
	}
	raw, hdr, status, err := c.doWithHeaders(ctx, http.MethodPut, fullPath, hdrs, payload, "application/json")
	if hdr != nil {
		etag = hdr.Get("ETag")
	}
	if err != nil {
		return raw, etag, status, err
	}
	if out != nil && len(raw) > 0 {
		if uerr := json.Unmarshal(raw, out); uerr != nil {
			return raw, etag, status, fmt.Errorf("PUT %s decode: %w", path, uerr)
		}
	}
	return raw, etag, status, nil
}

// DeleteRaw performs an authenticated DELETE, returning HTTP status and error (404 is treated as nil error).
func (c *Client) DeleteRaw(ctx context.Context, path, apiVersion string) (int, error) {
	fullPath := withAPIVersion(path, apiVersion)
	_, _, status, err := c.doWithHeaders(ctx, http.MethodDelete, fullPath, nil, nil, "")
	if err != nil {
		if IsNotFound(err) {
			return http.StatusNotFound, nil
		}
		return status, err
	}
	return status, nil
}

// IsNotFound reports whether err is an *ApiError with HTTP 404.
func IsNotFound(err error) bool {
	var apiErr *ApiError
	return errors.As(err, &apiErr) && apiErr.Status == http.StatusNotFound
}

// SavePrivateARMState stores the raw ARM JSON payload and ETag into Terraform Private State (ARD-TF-02).
func SavePrivateARMState(ctx context.Context, priv interface {
	SetKey(context.Context, string, []byte) diag.Diagnostics
}, raw []byte, etag string) {
	if priv == nil {
		return
	}
	if len(raw) > 0 {
		priv.SetKey(ctx, "arm_raw_body", raw)
	}
	if etag != "" {
		priv.SetKey(ctx, "arm_etag", []byte(etag))
	}
}

// LoadPrivateARMState loads the raw ARM JSON payload as a map[string]any and ETag from Terraform Private State (ARD-TF-02).
func LoadPrivateARMState(ctx context.Context, priv interface {
	GetKey(context.Context, string) ([]byte, diag.Diagnostics)
}) (map[string]any, string) {
	if priv == nil {
		return nil, ""
	}
	var rawMap map[string]any
	if b, d := priv.GetKey(ctx, "arm_raw_body"); !d.HasError() && len(b) > 0 {
		_ = json.Unmarshal(b, &rawMap)
	}
	var etag string
	if b, d := priv.GetKey(ctx, "arm_etag"); !d.HasError() && len(b) > 0 {
		etag = string(b)
	}
	return rawMap, etag
}

var canonicalNamespaces = map[string]string{
	"microsoft.keyvault":            "Microsoft.KeyVault",
	"microsoft.app":                 "Microsoft.App",
	"microsoft.managedidentity":     "Microsoft.ManagedIdentity",
	"microsoft.authorization":       "Microsoft.Authorization",
	"microsoft.containerregistry":   "Microsoft.ContainerRegistry",
	"microsoft.operationalinsights": "Microsoft.OperationalInsights",
	"microsoft.storage":             "Microsoft.Storage",
	"microsoft.compute":             "Microsoft.Compute",
	"microsoft.network":             "Microsoft.Network",
	"microsoft.resources":           "Microsoft.Resources",
}

var canonicalResourceTypes = map[string]string{
	"vaults":                       "vaults",
	"secrets":                      "secrets",
	"keys":                         "keys",
	"certificates":                 "certificates",
	"managedenvironments":          "managedEnvironments",
	"containerapps":                "containerApps",
	"userassignedidentities":       "userAssignedIdentities",
	"federatedidentitycredentials": "federatedIdentityCredentials",
	"roledefinitions":              "roleDefinitions",
	"roleassignments":              "roleAssignments",
	"registries":                   "registries",
	"workspaces":                   "workspaces",
	"storageaccounts":              "storageAccounts",
	"blobservices":                 "blobServices",
	"containers":                   "containers",
	"virtualnetworks":              "virtualNetworks",
	"subnets":                      "subnets",
	"networksecuritygroups":        "networkSecurityGroups",
	"publicipaddresses":            "publicIPAddresses",
	"networkinterfaces":            "networkInterfaces",
	"virtualmachines":              "virtualMachines",
	"disks":                        "disks",
}

// NormalizeARMID canonicalizes an Azure Resource Manager ID per ARD-AZ-01:
// - "subscriptions" and subscription UUID lowercase
// - "resourceGroups" exact camelCase, preserving resource group name casing
// - "providers" lowercase, provider namespace canonical PascalCase
// - resource type and childType segments canonical camelCase, preserving resource names
func NormalizeARMID(id string) string {
	if id == "" || !strings.HasPrefix(id, "/") {
		return id
	}
	parts := strings.Split(id, "/")
	for i := 1; i < len(parts); {
		seg := parts[i]
		switch {
		case strings.EqualFold(seg, "subscriptions") && i+1 < len(parts):
			parts[i] = "subscriptions"
			parts[i+1] = strings.ToLower(parts[i+1])
			i += 2
		case strings.EqualFold(seg, "resourcegroups") && i+1 < len(parts):
			parts[i] = "resourceGroups"
			// preserve parts[i+1] (resource group name) exact casing
			i += 2
		case strings.EqualFold(seg, "providers") && i+1 < len(parts):
			parts[i] = "providers"
			if ns, ok := canonicalNamespaces[strings.ToLower(parts[i+1])]; ok {
				parts[i+1] = ns
			}
			i += 2
			for i < len(parts) {
				if strings.EqualFold(parts[i], "providers") && i+1 < len(parts) {
					break
				}
				if rt, ok := canonicalResourceTypes[strings.ToLower(parts[i])]; ok {
					parts[i] = rt
				}
				i += 2
			}
		default:
			i++
		}
	}
	return strings.Join(parts, "/")
}

// NormalizeLocation canonicalizes an Azure region string per ARD-AZ-03 (e.g. "East US" -> "eastus").
func NormalizeLocation(loc string) string {
	return strings.ToLower(strings.ReplaceAll(strings.TrimSpace(loc), " ", ""))
}
