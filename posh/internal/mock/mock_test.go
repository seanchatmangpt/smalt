package mock_test

import (
	"bytes"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"net/http/httptest"
	"strconv"
	"sync"
	"testing"
	"time"

	"smalt.dev/posh/internal/mock"
	"smalt.dev/posh/internal/receipt"
)

func TestMetadataEndpoints(t *testing.T) {
	t.Parallel()

	srv := mock.NewServer()
	ts := httptest.NewServer(srv)
	defer ts.Close()

	resp, err := http.Get(ts.URL + "/metadata/endpoints?api-version=2020-01-01")
	if err != nil {
		t.Fatalf("GET /metadata/endpoints: %v", err)
	}
	defer resp.Body.Close()

	if resp.StatusCode != http.StatusOK {
		t.Fatalf("status = %d, want 200", resp.StatusCode)
	}

	var doc map[string]any
	if err := json.NewDecoder(resp.Body).Decode(&doc); err != nil {
		t.Fatalf("decode metadata doc: %v", err)
	}

	if doc["name"] != "smalt-sovereign" {
		t.Errorf("name = %v, want smalt-sovereign", doc["name"])
	}
	if doc["resourceManagerEndpoint"] == nil || doc["resourceManager"] == nil {
		t.Errorf("missing resourceManagerEndpoint: %+v", doc)
	}
	suffixes, ok := doc["suffixes"].(map[string]any)
	if !ok || suffixes["keyVaultDns"] != "vault.smalt.local" {
		t.Errorf("suffixes missing or malformed: %+v", suffixes)
	}
	auth, ok := doc["authentication"].(map[string]any)
	if !ok || auth["identityProvider"] != "AAD" || auth["tenant"] != "common" {
		t.Errorf("authentication missing or invalid: %+v", auth)
	}
}

func TestOAuth2TokenMinting(t *testing.T) {
	t.Parallel()

	srv := mock.NewServer()
	ts := httptest.NewServer(srv)
	defer ts.Close()

	endpoints := []string{
		"/tenant/oauth2/v2.0/token",
		"/oauth2/token",
		"/metadata/identity/oauth2/token",
	}

	for _, ep := range endpoints {
		resp, err := http.Post(ts.URL+ep, "application/x-www-form-urlencoded", stringsReader("grant_type=client_credentials"))
		if err != nil {
			t.Fatalf("POST %s: %v", ep, err)
		}
		if resp.StatusCode != http.StatusOK {
			t.Fatalf("POST %s status = %d, want 200", ep, resp.StatusCode)
		}
		var tokenResp map[string]any
		_ = json.NewDecoder(resp.Body).Decode(&tokenResp)
		resp.Body.Close()

		if tokenResp["token_type"] != "Bearer" || tokenResp["access_token"] == "" {
			t.Errorf("POST %s invalid token response: %+v", ep, tokenResp)
		}
	}
}

func TestSubscriptionsAndProviders(t *testing.T) {
	t.Parallel()

	srv := mock.NewServer(mock.WithDefaultSubscription("test-sub-123"))
	ts := httptest.NewServer(srv)
	defer ts.Close()

	// 1. List Subscriptions
	resp, err := http.Get(ts.URL + "/subscriptions")
	if err != nil {
		t.Fatalf("GET /subscriptions: %v", err)
	}
	if resp.StatusCode != http.StatusOK {
		t.Fatalf("status = %d, want 200", resp.StatusCode)
	}
	var subs map[string][]map[string]any
	_ = json.NewDecoder(resp.Body).Decode(&subs)
	resp.Body.Close()
	if len(subs["value"]) == 0 || subs["value"][0]["subscriptionId"] != "test-sub-123" {
		t.Fatalf("unexpected subscriptions: %+v", subs)
	}

	// 2. Locations
	resp, err = http.Get(ts.URL + "/subscriptions/test-sub-123/locations")
	if err != nil {
		t.Fatalf("GET locations: %v", err)
	}
	if resp.StatusCode != http.StatusOK {
		t.Fatalf("locations status = %d", resp.StatusCode)
	}
	resp.Body.Close()

	// 3. Providers listing & registration
	resp, err = http.Get(ts.URL + "/subscriptions/test-sub-123/providers")
	if err != nil {
		t.Fatalf("GET providers: %v", err)
	}
	var provs map[string][]map[string]any
	_ = json.NewDecoder(resp.Body).Decode(&provs)
	resp.Body.Close()
	if len(provs["value"]) == 0 {
		t.Fatal("expected registered providers list")
	}

	// Register a new provider
	resp, err = http.Post(ts.URL+"/subscriptions/test-sub-123/providers/Custom.Provider/register", "application/json", nil)
	if err != nil {
		t.Fatalf("POST register: %v", err)
	}
	if resp.StatusCode != http.StatusOK {
		t.Fatalf("register status = %d", resp.StatusCode)
	}
	resp.Body.Close()
}

func TestResourceGroupCRUDLifecycle(t *testing.T) {
	t.Parallel()

	srv := mock.NewServer(mock.WithDefaultSubscription("sub-crud"))
	ts := httptest.NewServer(srv)
	defer ts.Close()

	rgURL := ts.URL + "/subscriptions/sub-crud/resourcegroups/rg-alpha"

	// 1. GET before creation -> 404
	resp, err := http.Get(rgURL)
	if err != nil {
		t.Fatalf("GET: %v", err)
	}
	if resp.StatusCode != http.StatusNotFound {
		t.Fatalf("expected 404, got %d", resp.StatusCode)
	}
	resp.Body.Close()

	// 2. PUT create -> 201 Created
	createBody := []byte(`{"location":"westus2","tags":{"env":"dev","owner":"dx"}}`)
	req, _ := http.NewRequest(http.MethodPut, rgURL, bytes.NewReader(createBody))
	req.Header.Set("Content-Type", "application/json")
	resp, err = http.DefaultClient.Do(req)
	if err != nil {
		t.Fatalf("PUT create: %v", err)
	}
	if resp.StatusCode != http.StatusCreated {
		t.Fatalf("PUT expected 201 Created, got %d", resp.StatusCode)
	}
	var created mock.ResourceGroup
	_ = json.NewDecoder(resp.Body).Decode(&created)
	resp.Body.Close()
	if created.Name != "rg-alpha" || created.Location != "westus2" || created.Tags["env"] != "dev" {
		t.Fatalf("unexpected created RG: %+v", created)
	}

	// 3. GET after creation -> 200 OK
	resp, err = http.Get(rgURL)
	if err != nil {
		t.Fatalf("GET: %v", err)
	}
	if resp.StatusCode != http.StatusOK {
		t.Fatalf("GET expected 200 OK, got %d", resp.StatusCode)
	}
	resp.Body.Close()

	// 4. PATCH tags -> 200 OK
	patchBody := []byte(`{"tags":{"tier":"gold"}}`)
	req, _ = http.NewRequest(http.MethodPatch, rgURL, bytes.NewReader(patchBody))
	req.Header.Set("Content-Type", "application/json")
	resp, err = http.DefaultClient.Do(req)
	if err != nil {
		t.Fatalf("PATCH: %v", err)
	}
	if resp.StatusCode != http.StatusOK {
		t.Fatalf("PATCH expected 200 OK, got %d", resp.StatusCode)
	}
	var patched mock.ResourceGroup
	_ = json.NewDecoder(resp.Body).Decode(&patched)
	resp.Body.Close()
	if patched.Tags["tier"] != "gold" || patched.Tags["env"] != "dev" {
		t.Fatalf("expected merged tags, got: %+v", patched.Tags)
	}

	// 5. Case-insensitivity verification (/resourceGroups vs /resourcegroups)
	upperURL := ts.URL + "/subscriptions/sub-crud/resourceGroups/rg-alpha"
	resp, err = http.Get(upperURL)
	if err != nil {
		t.Fatalf("GET upper: %v", err)
	}
	if resp.StatusCode != http.StatusOK {
		t.Fatalf("GET upper expected 200 OK, got %d", resp.StatusCode)
	}
	resp.Body.Close()

	// 6. DELETE -> 204 No Content
	req, _ = http.NewRequest(http.MethodDelete, rgURL, nil)
	resp, err = http.DefaultClient.Do(req)
	if err != nil {
		t.Fatalf("DELETE: %v", err)
	}
	if resp.StatusCode != http.StatusNoContent {
		t.Fatalf("DELETE expected 204, got %d", resp.StatusCode)
	}
	resp.Body.Close()

	// 7. GET after delete -> 404 Not Found
	resp, err = http.Get(rgURL)
	if err != nil {
		t.Fatalf("GET after delete: %v", err)
	}
	if resp.StatusCode != http.StatusNotFound {
		t.Fatalf("GET after delete expected 404, got %d", resp.StatusCode)
	}
	resp.Body.Close()
}

func TestTurnstileReceiptHeaderEmission(t *testing.T) {
	t.Parallel()

	srv := mock.NewServer()
	ts := httptest.NewServer(srv)
	defer ts.Close()

	payload := []byte(`{"location":"eastus"}`)
	req, _ := http.NewRequest(http.MethodPut, ts.URL+"/subscriptions/00000000-0000-0000-0000-000000000000/resourcegroups/rg-receipt", bytes.NewReader(payload))
	req.Header.Set("Content-Type", "application/json")

	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatalf("PUT request: %v", err)
	}
	defer resp.Body.Close()

	turnstileHeader := resp.Header.Get(mock.HeaderTurnstile)
	timestampHeader := resp.Header.Get(mock.HeaderTimestamp)

	if turnstileHeader == "" || timestampHeader == "" {
		t.Fatalf("missing turnstile headers: turnstile=%q, timestamp=%q", turnstileHeader, timestampHeader)
	}

	tsNs, err := strconv.ParseUint(timestampHeader, 10, 64)
	if err != nil {
		t.Fatalf("parse timestamp header: %v", err)
	}

	ok, err := receipt.VerifyTurnstile(turnstileHeader, mock.TurnstileOp, tsNs, payload)
	if err != nil {
		t.Fatalf("VerifyTurnstile error: %v", err)
	}
	if !ok {
		t.Fatalf("turnstile validation failed against server header %q", turnstileHeader)
	}
}

func TestSimulatedTerraformWorkflow(t *testing.T) {
	t.Parallel()

	srv := mock.NewServer()
	ts := httptest.NewServer(srv)
	defer ts.Close()

	client := http.DefaultClient
	subID := mock.DefaultSubscriptionID

	// Step 1: Terraform Provider Initialization (read metadata)
	res1, err := client.Get(ts.URL + "/metadata/endpoints?api-version=2020-01-01")
	if err != nil || res1.StatusCode != http.StatusOK {
		t.Fatalf("TF step 1 (metadata): %v", err)
	}
	res1.Body.Close()

	// Step 2: Mint OAuth token
	res2, err := client.Post(ts.URL+"/tenant/oauth2/v2.0/token", "application/x-www-form-urlencoded", stringsReader("grant_type=client_credentials"))
	if err != nil || res2.StatusCode != http.StatusOK {
		t.Fatalf("TF step 2 (token): %v", err)
	}
	res2.Body.Close()

	// Step 3: Validate Subscription
	res3, err := client.Get(ts.URL + "/subscriptions/" + subID)
	if err != nil || res3.StatusCode != http.StatusOK {
		t.Fatalf("TF step 3 (sub): %v", err)
	}
	res3.Body.Close()

	// Step 4: Register Provider
	res4, err := client.Get(ts.URL + "/subscriptions/" + subID + "/providers/Microsoft.Resources")
	if err != nil || res4.StatusCode != http.StatusOK {
		t.Fatalf("TF step 4 (providers): %v", err)
	}
	res4.Body.Close()

	// Step 5: Terraform Plan (Resource Group check - 404 expected initially)
	rgPath := fmt.Sprintf("/subscriptions/%s/resourceGroups/tf-app-rg", subID)
	res5, err := client.Get(ts.URL + rgPath)
	if err != nil {
		t.Fatalf("TF step 5: %v", err)
	}
	if res5.StatusCode != http.StatusNotFound {
		t.Fatalf("TF step 5 expected 404, got %d", res5.StatusCode)
	}
	res5.Body.Close()

	// Step 6: Terraform Apply (Create Resource Group)
	applyPayload := []byte(`{"location":"eastus","tags":{"provisioner":"terraform"}}`)
	putReq, _ := http.NewRequest(http.MethodPut, ts.URL+rgPath, bytes.NewReader(applyPayload))
	putReq.Header.Set("Content-Type", "application/json")
	res6, err := client.Do(putReq)
	if err != nil || res6.StatusCode != http.StatusCreated {
		t.Fatalf("TF step 6 (apply): %v, status=%d", err, res6.StatusCode)
	}
	res6.Body.Close()

	// Step 7: Terraform Refresh (Read Resource Group)
	res7, err := client.Get(ts.URL + rgPath)
	if err != nil || res7.StatusCode != http.StatusOK {
		t.Fatalf("TF step 7 (refresh): %v, status=%d", err, res7.StatusCode)
	}
	res7.Body.Close()

	// Step 8: Terraform Destroy (Delete Resource Group)
	delReq, _ := http.NewRequest(http.MethodDelete, ts.URL+rgPath, nil)
	res8, err := client.Do(delReq)
	if err != nil || res8.StatusCode != http.StatusNoContent {
		t.Fatalf("TF step 8 (destroy): %v, status=%d", err, res8.StatusCode)
	}
	res8.Body.Close()
}

func TestConcurrentStateOperations(t *testing.T) {
	t.Parallel()

	srv := mock.NewServer()
	ts := httptest.NewServer(srv)
	defer ts.Close()

	const workers = 8
	const iterations = 50
	var wg sync.WaitGroup
	wg.Add(workers)

	for w := 0; w < workers; w++ {
		go func(workerID int) {
			defer wg.Done()
			client := &http.Client{Timeout: 5 * time.Second}
			for i := 0; i < iterations; i++ {
				rgName := fmt.Sprintf("rg-worker-%d-%d", workerID, i)
				u := fmt.Sprintf("%s/subscriptions/00000000-0000-0000-0000-000000000000/resourcegroups/%s", ts.URL, rgName)

				// Create
				req, _ := http.NewRequest(http.MethodPut, u, bytes.NewReader([]byte(`{"location":"eastus"}`)))
				resp, err := client.Do(req)
				if err != nil {
					t.Errorf("worker %d put failed: %v", workerID, err)
					return
				}
				resp.Body.Close()

				// Read
				resp, err = client.Get(u)
				if err != nil || resp.StatusCode != http.StatusOK {
					t.Errorf("worker %d get failed: %v", workerID, err)
					return
				}
				resp.Body.Close()

				// Delete
				delReq, _ := http.NewRequest(http.MethodDelete, u, nil)
				resp, err = client.Do(delReq)
				if err != nil || resp.StatusCode != http.StatusNoContent {
					t.Errorf("worker %d delete failed: %v", workerID, err)
					return
				}
				resp.Body.Close()
			}
		}(w)
	}

	wg.Wait()
}

func BenchmarkMockARMServerThroughput(b *testing.B) {
	srv := mock.NewServer()
	ts := httptest.NewServer(srv)
	defer ts.Close()

	client := &http.Client{
		Transport: &http.Transport{
			MaxIdleConns:        100,
			MaxIdleConnsPerHost: 100,
		},
		Timeout: 5 * time.Second,
	}

	url := ts.URL + "/metadata/endpoints"

	b.ResetTimer()
	b.ReportAllocs()
	for i := 0; i < b.N; i++ {
		resp, err := client.Get(url)
		if err != nil {
			b.Fatalf("benchmark request: %v", err)
		}
		_, _ = io.Copy(io.Discard, resp.Body)
		resp.Body.Close()
	}
}

func stringsReader(s string) io.Reader {
	return bytes.NewReader([]byte(s))
}
