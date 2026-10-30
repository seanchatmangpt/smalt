// Package mock implements a zero-dependency Local Mock ARM Provider for POSH
// (SPAF Tier 2, v26.10.30).
//
// The Mock ARM Provider enables Terraform developers to run `terraform plan`
// and `terraform apply` locally against POSH without requiring BEAM/Elixir to
// be booted. It implements standard ARM metadata discovery (/metadata/endpoints),
// OAuth2 client-credential token minting, subscription discovery, resource
// provider registrations, and full CRUD lifecycle for resource groups and
// child resources backed by an in-memory thread-safe state store.
//
// Every response emits cryptographic BLAKE3 turnstile headers
// (X-Smalt-Receipt-Turnstile, X-Smalt-Receipt-Timestamp) maintaining byte-for-byte
// protocol fidelity with the production Smalt ARM Gateway.
package mock

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net"
	"net/http"
	"strconv"
	"strings"
	"sync"
	"time"

	"smalt.dev/posh/internal/receipt"
)

// DefaultSubscriptionID is the fallback subscription ID for local development.
const DefaultSubscriptionID = "00000000-0000-0000-0000-000000000000"

// DefaultTenantID is the default sovereign tenant ID.
const DefaultTenantID = "smalt-tenant-local"

// HeaderTurnstile is the canonical turnstile receipt header.
const HeaderTurnstile = "X-Smalt-Receipt-Turnstile"

// HeaderTimestamp is the canonical turnstile timestamp header.
const HeaderTimestamp = "X-Smalt-Receipt-Timestamp"

// TurnstileOp is the operation name bound to incoming ARM requests.
const TurnstileOp = "arm.request"

// ResourceGroup represents an in-memory ARM Resource Group record.
type ResourceGroup struct {
	ID         string            `json:"id"`
	Name       string            `json:"name"`
	Type       string            `json:"type"`
	Location   string            `json:"location"`
	Tags       map[string]string `json:"tags"`
	Properties map[string]any    `json:"properties"`
}

// GenericResource represents an in-memory ARM resource instance.
type GenericResource struct {
	ID         string            `json:"id"`
	Name       string            `json:"name"`
	Type       string            `json:"type"`
	Location   string            `json:"location,omitempty"`
	Tags       map[string]string `json:"tags,omitempty"`
	Properties map[string]any    `json:"properties,omitempty"`
}

// Subscription represents an ARM Subscription record.
type Subscription struct {
	ID             string `json:"id"`
	SubscriptionID string `json:"subscriptionId"`
	DisplayName    string `json:"displayName"`
	State          string `json:"state"`
}

// State holds the in-memory state store for ARM resources.
type State struct {
	mu             sync.RWMutex
	subscriptions  map[string]*Subscription
	resourceGroups map[string]*ResourceGroup
	resources      map[string]*GenericResource
	providers      map[string]string // provider namespace -> registrationState
}

// NewState creates a fresh in-memory state store seeded with default subscriptions
// and standard registered resource providers.
func NewState(defaultSubID string) *State {
	if defaultSubID == "" {
		defaultSubID = DefaultSubscriptionID
	}
	s := &State{
		subscriptions:  make(map[string]*Subscription),
		resourceGroups: make(map[string]*ResourceGroup),
		resources:      make(map[string]*GenericResource),
		providers:      make(map[string]string),
	}

	// Seed default subscription
	sub := &Subscription{
		ID:             "/subscriptions/" + defaultSubID,
		SubscriptionID: defaultSubID,
		DisplayName:    "Local Mock Sovereign Subscription",
		State:          "Enabled",
	}
	s.subscriptions[defaultSubID] = sub

	// Pre-register standard Azure resource providers
	commonProviders := []string{
		"Microsoft.Resources",
		"Microsoft.Compute",
		"Microsoft.Storage",
		"Microsoft.Network",
		"Microsoft.KeyVault",
		"Microsoft.App",
		"Microsoft.OperationalInsights",
		"Microsoft.Authorization",
		"Microsoft.Insights",
	}
	for _, p := range commonProviders {
		s.providers[strings.ToLower(p)] = "Registered"
	}

	return s
}

// Server provides the HTTP ARM mock provider.
type Server struct {
	addr       string
	listener   net.Listener
	httpServer *http.Server
	state      *State
	defaultSub string
	mu         sync.Mutex
	running    bool
}

// ServerOption configures the mock Server.
type ServerOption func(*Server)

// WithAddr configures the bind address (e.g. "127.0.0.1:9443").
func WithAddr(addr string) ServerOption {
	return func(s *Server) {
		s.addr = addr
	}
}

// WithDefaultSubscription sets the default subscription ID.
func WithDefaultSubscription(subID string) ServerOption {
	return func(s *Server) {
		s.defaultSub = subID
	}
}

// WithListener sets a pre-configured net.Listener.
func WithListener(ln net.Listener) ServerOption {
	return func(s *Server) {
		s.listener = ln
	}
}

// NewServer instantiates a new Local Mock ARM Provider server.
func NewServer(opts ...ServerOption) *Server {
	s := &Server{
		addr:       "127.0.0.1:9443",
		defaultSub: DefaultSubscriptionID,
	}
	for _, opt := range opts {
		opt(s)
	}
	s.state = NewState(s.defaultSub)

	mux := http.NewServeMux()
	mux.HandleFunc("/", s.dispatch)

	s.httpServer = &http.Server{
		Handler: s.turnstileMiddleware(mux),
	}
	return s
}

// turnstileMiddleware wraps requests, captures the body, and attaches cryptographic
// BLAKE3 turnstile headers to the response.
func (s *Server) turnstileMiddleware(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		var bodyBytes []byte
		if r.Body != nil {
			var err error
			bodyBytes, err = io.ReadAll(r.Body)
			if err == nil {
				r.Body = io.NopCloser(bytes.NewReader(bodyBytes))
			}
		}

		// Compute turnstile timestamp
		tsNs := uint64(time.Now().UnixNano())
		if customTs := r.Header.Get(HeaderTimestamp); customTs != "" {
			if parsed, err := strconv.ParseUint(customTs, 10, 64); err == nil {
				tsNs = parsed
			}
		}

		// Compute turnstile receipt
		receiptDigest := receipt.TurnstileReceipt(TurnstileOp, tsNs, bodyBytes)
		receiptHex := receipt.Hex(receiptDigest)

		w.Header().Set(HeaderTurnstile, receiptHex)
		w.Header().Set(HeaderTimestamp, strconv.FormatUint(tsNs, 10))

		next.ServeHTTP(w, r)
	})
}

// Start begins serving requests on the configured listener or address.
func (s *Server) Start() error {
	s.mu.Lock()
	defer s.mu.Unlock()

	if s.running {
		return nil
	}

	if s.listener == nil {
		ln, err := net.Listen("tcp", s.addr)
		if err != nil {
			return fmt.Errorf("mock: listen %s: %w", s.addr, err)
		}
		s.listener = ln
	}
	s.addr = s.listener.Addr().String()
	s.running = true

	go func() {
		_ = s.httpServer.Serve(s.listener)
	}()
	return nil
}

// Close stops the mock server.
func (s *Server) Close() error {
	s.mu.Lock()
	defer s.mu.Unlock()

	if !s.running {
		return nil
	}
	s.running = false
	ctx, cancel := context.WithTimeout(context.Background(), 2*time.Second)
	defer cancel()
	return s.httpServer.Shutdown(ctx)
}

// Addr returns the network address the server is listening on.
func (s *Server) Addr() string {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.addr
}

// URL returns the base HTTP URL of the running server.
func (s *Server) URL() string {
	return "http://" + s.Addr()
}

// Reset clears and reinitializes the in-memory state store.
func (s *Server) Reset() {
	s.state = NewState(s.defaultSub)
}

// ServeHTTP implements http.Handler for direct in-process testing.
func (s *Server) ServeHTTP(w http.ResponseWriter, r *http.Request) {
	s.turnstileMiddleware(http.HandlerFunc(s.dispatch)).ServeHTTP(w, r)
}

// dispatch routes incoming ARM and OAuth requests.
func (s *Server) dispatch(w http.ResponseWriter, r *http.Request) {
	path := r.URL.Path
	normPath := strings.ToLower(path)

	// Health and readiness probes
	if normPath == "/.well-known/health/live" || normPath == "/healthz" {
		writeJSON(w, http.StatusOK, map[string]string{"status": "alive"})
		return
	}
	if normPath == "/.well-known/health/ready" {
		writeJSON(w, http.StatusOK, map[string]string{"status": "ready"})
		return
	}

	// Discovery: /metadata/endpoints
	if normPath == "/metadata/endpoints" {
		s.handleMetadataEndpoints(w, r)
		return
	}

	// OAuth2 STS token minting: /{tenant}/oauth2/v2.0/token or /metadata/identity/oauth2/token
	if strings.HasSuffix(normPath, "/oauth2/v2.0/token") ||
		strings.HasSuffix(normPath, "/oauth2/token") ||
		normPath == "/metadata/identity/oauth2/token" {
		s.handleOAuthToken(w, r)
		return
	}

	// Subscriptions
	if normPath == "/subscriptions" {
		s.handleSubscriptionsList(w, r)
		return
	}
	if strings.HasPrefix(normPath, "/subscriptions/") {
		s.handleSubscriptionRoutes(w, r, path)
		return
	}

	// Tenant discovery
	if normPath == "/tenants" || normPath == "/tenant" {
		s.handleTenants(w, r)
		return
	}

	// Default fallback 404
	sendARMError(w, http.StatusNotFound, "NotFound", fmt.Sprintf("Path %q not found", path), path)
}

// handleMetadataEndpoints returns the ARM environment metadata document
// matching go-azure-sdk / azurerm specifications.
func (s *Server) handleMetadataEndpoints(w http.ResponseWriter, r *http.Request) {
	authority := r.Host
	if authority == "" {
		authority = s.Addr()
	}
	scheme := "http"
	if r.TLS != nil {
		scheme = "https"
	}
	endpointURL := fmt.Sprintf("%s://%s", scheme, authority)

	doc := map[string]any{
		"name":                     "smalt-sovereign",
		"resourceManagerEndpoint": StringTrimRight(endpointURL, "/"),
		"resourceManager":         StringTrimRight(endpointURL, "/"),
		"managementEndpoint":      StringTrimRight(endpointURL, "/"),
		"activeDirectoryEndpoint": endpointURL + "/",
		"microsoftGraphResourceId": "https://graph.smalt.local/",
		"resourceIdentifiers": map[string]string{
			"microsoftGraphResourceId": "https://graph.smalt.local/",
		},
		"suffixes": map[string]string{
			"keyVaultDns":                  "vault.smalt.local",
			"storage":                      "smalt.local",
			"sqlServerHostname":            "database.smalt.local",
			"acrLoginServer":               "registry.smalt.local",
			"mhsmDns":                      "managedhsm.smalt.local",
			"attestationEndpoint":          "attest.smalt.local",
			"azureFrontDoorEndpointSuffix": "afd.smalt.local",
			"storageSyncEndpointSuffix":    "afshare.smalt.local",
			"synapseAnalytics":             "dev.smalt.local",
			"mysqlServerEndpoint":          "mysql.smalt.local",
			"postgresqlServerEndpoint":     "postgres.smalt.local",
			"mariadbServerEndpoint":        "mariadb.smalt.local",
			"azureDataLakeStoreFileSystem": "azuredatalakestore.smalt.local",
		},
		"dnsSuffixes": map[string]string{
			"keyVault":          "vault.smalt.local",
			"storage":           "smalt.local",
			"sqlServer":         "database.smalt.local",
			"containerRegistry": "registry.smalt.local",
			"attestation":       "attest.smalt.local",
			"frontDoor":         "afd.smalt.local",
			"managedHSM":        "managedhsm.smalt.local",
			"storageSync":       "afshare.smalt.local",
			"synapse":           "dev.smalt.local",
			"dataLakeStore":     "azuredatalakestore.smalt.local",
			"mariaDb":           "mariadb.smalt.local",
			"mySql":             "mysql.smalt.local",
			"postgresql":        "postgres.smalt.local",
		},
		"authentication": map[string]any{
			"loginEndpoint":    endpointURL + "/",
			"audiences":        []string{"https://management.azure.com"},
			"identityProvider": "AAD",
			"tenant":           "common",
		},
		"graphEndpoint":             "https://graph.smalt.local/",
		"graph":                     "https://graph.smalt.local/",
		"sqlManagement":             "https://management.core.smalt.local/",
		"galleryEndpoint":           "https://gallery.smalt.local/",
		"activeDirectoryResourceId": "https://management.azure.com/",
	}

	writeJSON(w, http.StatusOK, doc)
}

// handleOAuthToken returns a valid mock OAuth2 bearer token.
func (s *Server) handleOAuthToken(w http.ResponseWriter, r *http.Request) {
	resp := map[string]any{
		"token_type":     "Bearer",
		"expires_in":     86400,
		"ext_expires_in": 86400,
		"access_token":   "mock-posh-bearer-token-" + strconv.FormatInt(time.Now().Unix(), 10),
	}
	writeJSON(w, http.StatusOK, resp)
}

// handleTenants returns the list of available tenants.
func (s *Server) handleTenants(w http.ResponseWriter, r *http.Request) {
	resp := map[string]any{
		"value": []map[string]any{
			{
				"id":             "/tenants/" + DefaultTenantID,
				"tenantId":       DefaultTenantID,
				"displayName":    "Sovereign Mock Tenant",
				"tenantCategory": "Home",
			},
		},
	}
	writeJSON(w, http.StatusOK, resp)
}

// handleSubscriptionsList returns the list of subscriptions.
func (s *Server) handleSubscriptionsList(w http.ResponseWriter, r *http.Request) {
	s.state.mu.RLock()
	defer s.state.mu.RUnlock()

	var list []*Subscription
	for _, sub := range s.state.subscriptions {
		list = append(list, sub)
	}
	writeJSON(w, http.StatusOK, map[string]any{"value": list})
}

// handleSubscriptionRoutes handles paths rooted at /subscriptions/{subID}/...
func (s *Server) handleSubscriptionRoutes(w http.ResponseWriter, r *http.Request, rawPath string) {
	// Segments: /subscriptions/{subID}/...
	parts := strings.Split(strings.Trim(rawPath, "/"), "/")
	if len(parts) < 2 {
		sendARMError(w, http.StatusBadRequest, "InvalidSubscriptionId", "Subscription ID missing", rawPath)
		return
	}
	subID := parts[1]

	// /subscriptions/{subID}
	if len(parts) == 2 {
		s.state.mu.RLock()
		sub, ok := s.state.subscriptions[subID]
		s.state.mu.RUnlock()
		if !ok {
			// Auto-register requested subscription on the fly in mock mode
			sub = &Subscription{
				ID:             "/subscriptions/" + subID,
				SubscriptionID: subID,
				DisplayName:    "Mock Subscription " + subID,
				State:          "Enabled",
			}
			s.state.mu.Lock()
			s.state.subscriptions[subID] = sub
			s.state.mu.Unlock()
		}
		writeJSON(w, http.StatusOK, sub)
		return
	}

	thirdSeg := strings.ToLower(parts[2])

	// /subscriptions/{subID}/locations
	if thirdSeg == "locations" && len(parts) == 3 {
		locations := []map[string]string{
			{
				"id":                  "/subscriptions/" + subID + "/locations/eastus",
				"name":                "eastus",
				"displayName":         "East US",
				"regionalDisplayName": "(US) East US",
			},
			{
				"id":                  "/subscriptions/" + subID + "/locations/westus2",
				"name":                "westus2",
				"displayName":         "West US 2",
				"regionalDisplayName": "(US) West US 2",
			},
		}
		writeJSON(w, http.StatusOK, map[string]any{"value": locations})
		return
	}

	// /subscriptions/{subID}/providers
	if thirdSeg == "providers" {
		s.handleProviders(w, r, subID, parts[3:])
		return
	}

	// /subscriptions/{subID}/resourcegroups or /resourceGroups
	if thirdSeg == "resourcegroups" {
		s.handleResourceGroups(w, r, subID, parts[3:])
		return
	}

	// Generic resource fallback under subscription
	s.handleGenericResource(w, r, rawPath)
}

// handleProviders manages /subscriptions/{subID}/providers and registration.
func (s *Server) handleProviders(w http.ResponseWriter, r *http.Request, subID string, rest []string) {
	s.state.mu.Lock()
	defer s.state.mu.Unlock()

	// List providers: /subscriptions/{subID}/providers
	if len(rest) == 0 {
		var list []map[string]any
		for ns, regState := range s.state.providers {
			list = append(list, map[string]any{
				"id":                "/subscriptions/" + subID + "/providers/" + ns,
				"namespace":         ns,
				"registrationState": regState,
			})
		}
		writeJSON(w, http.StatusOK, map[string]any{"value": list})
		return
	}

	ns := rest[0]
	nsKey := strings.ToLower(ns)

	// Provider detail: /subscriptions/{subID}/providers/{ns}
	if len(rest) == 1 {
		regState, ok := s.state.providers[nsKey]
		if !ok {
			regState = "Registered"
			s.state.providers[nsKey] = regState
		}
		writeJSON(w, http.StatusOK, map[string]any{
			"id":                "/subscriptions/" + subID + "/providers/" + ns,
			"namespace":         ns,
			"registrationState": regState,
		})
		return
	}

	// Register provider: POST /subscriptions/{subID}/providers/{ns}/register
	if len(rest) == 2 && strings.ToLower(rest[1]) == "register" && r.Method == http.MethodPost {
		s.state.providers[nsKey] = "Registered"
		writeJSON(w, http.StatusOK, map[string]any{
			"id":                "/subscriptions/" + subID + "/providers/" + ns,
			"namespace":         ns,
			"registrationState": "Registered",
		})
		return
	}

	sendARMError(w, http.StatusNotFound, "ResourceNotFound", fmt.Sprintf("Provider route %q not found", ns), r.URL.Path)
}

// handleResourceGroups manages Resource Group CRUD lifecycle.
func (s *Server) handleResourceGroups(w http.ResponseWriter, r *http.Request, subID string, rest []string) {
	// List resource groups: GET /subscriptions/{subID}/resourcegroups
	if len(rest) == 0 {
		if r.Method != http.MethodGet {
			w.WriteHeader(http.StatusMethodNotAllowed)
			return
		}
		s.state.mu.RLock()
		defer s.state.mu.RUnlock()

		prefix := strings.ToLower("/subscriptions/" + subID + "/resourcegroups/")
		var list []*ResourceGroup
		for k, rg := range s.state.resourceGroups {
			if strings.HasPrefix(k, prefix) {
				list = append(list, rg)
			}
		}
		writeJSON(w, http.StatusOK, map[string]any{"value": list})
		return
	}

	rgName := rest[0]
	rgID := "/subscriptions/" + subID + "/resourceGroups/" + rgName
	rgKey := strings.ToLower(rgID)

	// Resource group direct routes: /subscriptions/{subID}/resourcegroups/{rgName}
	if len(rest) == 1 {
		switch r.Method {
		case http.MethodGet, http.MethodHead:
			s.state.mu.RLock()
			rg, ok := s.state.resourceGroups[rgKey]
			s.state.mu.RUnlock()
			if !ok {
				sendARMError(w, http.StatusNotFound, "ResourceGroupNotFound", fmt.Sprintf("Resource group '%s' could not be found.", rgName), rgID)
				return
			}
			if r.Method == http.MethodHead {
				w.WriteHeader(http.StatusOK)
				return
			}
			writeJSON(w, http.StatusOK, rg)

		case http.MethodPut:
			var reqBody struct {
				Location string            `json:"location"`
				Tags     map[string]string `json:"tags"`
			}
			_ = json.NewDecoder(r.Body).Decode(&reqBody)
			if reqBody.Location == "" {
				reqBody.Location = "eastus"
			}

			s.state.mu.Lock()
			existing, exists := s.state.resourceGroups[rgKey]
			rg := &ResourceGroup{
				ID:         rgID,
				Name:       rgName,
				Type:       "Microsoft.Resources/resourceGroups",
				Location:   reqBody.Location,
				Tags:       reqBody.Tags,
				Properties: map[string]any{"provisioningState": "Succeeded"},
			}
			s.state.resourceGroups[rgKey] = rg
			s.state.mu.Unlock()

			statusCode := http.StatusOK
			if !exists || existing == nil {
				statusCode = http.StatusCreated
			}
			writeJSON(w, statusCode, rg)

		case http.MethodPatch:
			var reqBody struct {
				Tags map[string]string `json:"tags"`
			}
			_ = json.NewDecoder(r.Body).Decode(&reqBody)

			s.state.mu.Lock()
			rg, ok := s.state.resourceGroups[rgKey]
			if !ok {
				s.state.mu.Unlock()
				sendARMError(w, http.StatusNotFound, "ResourceGroupNotFound", fmt.Sprintf("Resource group '%s' could not be found.", rgName), rgID)
				return
			}
			if reqBody.Tags != nil {
				if rg.Tags == nil {
					rg.Tags = make(map[string]string)
				}
				for k, v := range reqBody.Tags {
					rg.Tags[k] = v
				}
			}
			s.state.mu.Unlock()

			writeJSON(w, http.StatusOK, rg)

		case http.MethodDelete:
			s.state.mu.Lock()
			delete(s.state.resourceGroups, rgKey)

			// Cascade delete all child resources under this resource group
			prefix := rgKey + "/"
			for k := range s.state.resources {
				if strings.HasPrefix(k, prefix) {
					delete(s.state.resources, k)
				}
			}
			s.state.mu.Unlock()

			w.WriteHeader(http.StatusNoContent)

		default:
			w.WriteHeader(http.StatusMethodNotAllowed)
		}
		return
	}

	// Sub-routes under resource group:
	// /subscriptions/{subID}/resourcegroups/{rgName}/resources
	if len(rest) == 2 && strings.ToLower(rest[1]) == "resources" && r.Method == http.MethodGet {
		s.state.mu.RLock()
		defer s.state.mu.RUnlock()

		prefix := rgKey + "/"
		var list []*GenericResource
		for k, res := range s.state.resources {
			if strings.HasPrefix(k, prefix) {
				list = append(list, res)
			}
		}
		writeJSON(w, http.StatusOK, map[string]any{"value": list})
		return
	}

	// /subscriptions/{subID}/resourcegroups/{rgName}/providers/...
	s.handleGenericResource(w, r, r.URL.Path)
}

// handleGenericResource stores and retrieves arbitrary ARM resources.
func (s *Server) handleGenericResource(w http.ResponseWriter, r *http.Request, rawPath string) {
	normKey := strings.ToLower(rawPath)
	parts := strings.Split(strings.Trim(rawPath, "/"), "/")
	resName := parts[len(parts)-1]

	switch r.Method {
	case http.MethodGet, http.MethodHead:
		s.state.mu.RLock()
		res, ok := s.state.resources[normKey]
		s.state.mu.RUnlock()
		if !ok {
			sendARMError(w, http.StatusNotFound, "ResourceNotFound", fmt.Sprintf("Resource %q could not be found.", rawPath), rawPath)
			return
		}
		if r.Method == http.MethodHead {
			w.WriteHeader(http.StatusOK)
			return
		}
		writeJSON(w, http.StatusOK, res)

	case http.MethodPut:
		var body map[string]any
		_ = json.NewDecoder(r.Body).Decode(&body)

		loc, _ := body["location"].(string)
		if loc == "" {
			loc = "eastus"
		}
		var tags map[string]string
		if t, ok := body["tags"].(map[string]any); ok {
			tags = make(map[string]string)
			for k, v := range t {
				tags[k] = fmt.Sprint(v)
			}
		}

		props, _ := body["properties"].(map[string]any)
		if props == nil {
			props = make(map[string]any)
		}
		props["provisioningState"] = "Succeeded"

		res := &GenericResource{
			ID:         rawPath,
			Name:       resName,
			Type:       "Microsoft.Resources/resource",
			Location:   loc,
			Tags:       tags,
			Properties: props,
		}

		s.state.mu.Lock()
		_, exists := s.state.resources[normKey]
		s.state.resources[normKey] = res
		s.state.mu.Unlock()

		status := http.StatusOK
		if !exists {
			status = http.StatusCreated
		}
		writeJSON(w, status, res)

	case http.MethodPatch:
		s.state.mu.Lock()
		res, ok := s.state.resources[normKey]
		if !ok {
			s.state.mu.Unlock()
			sendARMError(w, http.StatusNotFound, "ResourceNotFound", fmt.Sprintf("Resource %q could not be found.", rawPath), rawPath)
			return
		}
		var body map[string]any
		_ = json.NewDecoder(r.Body).Decode(&body)
		if t, ok := body["tags"].(map[string]any); ok {
			if res.Tags == nil {
				res.Tags = make(map[string]string)
			}
			for k, v := range t {
				res.Tags[k] = fmt.Sprint(v)
			}
		}
		s.state.mu.Unlock()
		writeJSON(w, http.StatusOK, res)

	case http.MethodDelete:
		s.state.mu.Lock()
		delete(s.state.resources, normKey)
		s.state.mu.Unlock()
		w.WriteHeader(http.StatusNoContent)

	default:
		w.WriteHeader(http.StatusMethodNotAllowed)
	}
}

// writeJSON marshals v and writes JSON content headers and status code.
func writeJSON(w http.ResponseWriter, status int, v any) {
	w.Header().Set("Content-Type", "application/json; charset=utf-8")
	w.WriteHeader(status)
	_ = json.NewEncoder(w).Encode(v)
}

// sendARMError emits a compliant Azure Resource Manager error envelope.
func sendARMError(w http.ResponseWriter, status int, code, message, target string) {
	envelope := map[string]any{
		"error": map[string]string{
			"code":    code,
			"message": message,
			"target":  target,
		},
	}
	writeJSON(w, status, envelope)
}

// StringTrimRight trims trailing characters.
func StringTrimRight(s, cutset string) string {
	return strings.TrimRight(s, cutset)
}
