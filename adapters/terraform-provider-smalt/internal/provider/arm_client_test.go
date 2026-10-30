package provider

import (
	"context"
	"fmt"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync"
	"sync/atomic"
	"testing"
	"time"

	"github.com/hashicorp/terraform-plugin-framework/diag"
)

// TestF_TF_01_SingleflightContextCancellationIsolation verifies ARD-GO-04 / F-TF-01:
// 32 concurrent callers request Client.Token(ctx) against an STS with a 25ms latency.
// Caller #0 cancels its context after 1ms; the remaining 31 callers must still
// receive the minted bearer token from a single STS POST request without error.
func TestF_TF_01_SingleflightContextCancellationIsolation(t *testing.T) {
	var stsPosts atomic.Int64
	const wantToken = "e30.eyJleHAiOjQxMDI0NDQ4MDB9.sig"

	ts := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Method == http.MethodPost && strings.HasSuffix(r.URL.Path, "/oauth2/v2.0/token") {
			stsPosts.Add(1)
			time.Sleep(25 * time.Millisecond)
			w.Header().Set("Content-Type", "application/json")
			fmt.Fprintf(w, `{"access_token":%q,"expires_in":3600}`, wantToken)
			return
		}
		http.Error(w, "unexpected request", http.StatusNotFound)
	}))
	defer ts.Close()

	c, err := NewClient(context.Background(), ts.URL, "00000000-0000-0000-0000-000000000000", "", "", "")
	if err != nil {
		t.Fatalf("NewClient: %v", err)
	}

	const totalCallers = 32
	tokens := make([]string, totalCallers)
	errs := make([]error, totalCallers)

	startGate := make(chan struct{})
	var wg sync.WaitGroup
	for i := 0; i < totalCallers; i++ {
		wg.Add(1)
		go func(idx int) {
			defer wg.Done()
			<-startGate
			callCtx := context.Background()
			if idx == 0 {
				var cancel context.CancelFunc
				callCtx, cancel = context.WithTimeout(callCtx, 1*time.Millisecond)
				defer cancel()
			}
			tokens[idx], errs[idx] = c.Token(callCtx)
		}(i)
	}
	close(startGate)
	wg.Wait()

	if got := stsPosts.Load(); got != 1 {
		t.Fatalf("mock STS POST count = %d, want 1", got)
	}
	for i := 1; i < totalCallers; i++ {
		if errs[i] != nil {
			t.Fatalf("uncancelled goroutine %d failed: %v", i, errs[i])
		}
		if tokens[i] != wantToken {
			t.Fatalf("uncancelled goroutine %d token = %q, want %q", i, tokens[i], wantToken)
		}
	}
}

func TestNormalizeARMIDAndLocation(t *testing.T) {
	in := "/SUBSCRIPTIONS/ABCDEF01-2345-6789-ABCD-EF0123456789/resourcegroups/My-RG/providers/microsoft.keyvault/VAULTS/my-kv"
	want := "/subscriptions/abcdef01-2345-6789-abcd-ef0123456789/resourceGroups/My-RG/providers/Microsoft.KeyVault/vaults/my-kv"
	if got := NormalizeARMID(in); got != want {
		t.Fatalf("NormalizeARMID(%q)\n got: %q\nwant: %q", in, got, want)
	}

	nestedIn := "/SUBSCRIPTIONS/ABCDEF01-2345-6789-ABCD-EF0123456789/RESOURCEGROUPS/My-RG/PROVIDERS/microsoft.keyvault/VAULTS/my-kv/SECRETS/my-secret"
	nestedWant := "/subscriptions/abcdef01-2345-6789-abcd-ef0123456789/resourceGroups/My-RG/providers/Microsoft.KeyVault/vaults/my-kv/secrets/my-secret"
	if got := NormalizeARMID(nestedIn); got != nestedWant {
		t.Fatalf("NormalizeARMID(%q)\n got: %q\nwant: %q", nestedIn, got, nestedWant)
	}

	rgIn := "/SUBSCRIPTIONS/ABCDEF01-2345-6789-ABCD-EF0123456789/resourcegroups/My-RG"
	rgWant := "/subscriptions/abcdef01-2345-6789-abcd-ef0123456789/resourceGroups/My-RG"
	if got := NormalizeARMID(rgIn); got != rgWant {
		t.Fatalf("NormalizeARMID(%q)\n got: %q\nwant: %q", rgIn, got, rgWant)
	}

	if got := NormalizeLocation("East US"); got != "eastus" {
		t.Fatalf("NormalizeLocation(\"East US\") = %q, want \"eastus\"", got)
	}
	if got := NormalizeLocation("  West US 2 "); got != "westus2" {
		t.Fatalf("NormalizeLocation(\"  West US 2 \") = %q, want \"westus2\"", got)
	}
}

func TestNewClientTransportSettings(t *testing.T) {
	c, err := NewClient(context.Background(), "http://127.0.0.1:9443", "00000000-0000-0000-0000-000000000000", "", "", "")
	if err != nil {
		t.Fatalf("NewClient: %v", err)
	}
	tr, ok := c.http.Transport.(*http.Transport)
	if !ok {
		t.Fatalf("Transport type = %T, want *http.Transport", c.http.Transport)
	}
	if tr.MaxIdleConns != 128 {
		t.Fatalf("MaxIdleConns = %d, want 128", tr.MaxIdleConns)
	}
	if tr.MaxIdleConnsPerHost != 64 {
		t.Fatalf("MaxIdleConnsPerHost = %d, want 64", tr.MaxIdleConnsPerHost)
	}
	if tr.IdleConnTimeout != 90*time.Second {
		t.Fatalf("IdleConnTimeout = %v, want 90s", tr.IdleConnTimeout)
	}
	if !tr.DisableCompression {
		t.Fatalf("DisableCompression = false, want true")
	}
}

type mockPrivateState struct {
	data map[string][]byte
}

func (m *mockPrivateState) SetKey(_ context.Context, k string, v []byte) diag.Diagnostics {
	if m.data == nil {
		m.data = map[string][]byte{}
	}
	m.data[k] = append([]byte(nil), v...)
	return nil
}

func (m *mockPrivateState) GetKey(_ context.Context, k string) ([]byte, diag.Diagnostics) {
	return m.data[k], nil
}

func TestPrivateARMStateHelpers(t *testing.T) {
	ctx := context.Background()
	priv := &mockPrivateState{}
	raw := []byte(`{"name":"rg-1","location":"eastus","unknownServerField":"keep-me"}`)
	SavePrivateARMState(ctx, priv, raw, `W/"etag-1"`)

	gotMap, gotETag := LoadPrivateARMState(ctx, priv)
	if gotETag != `W/"etag-1"` {
		t.Fatalf("etag = %q, want W/\"etag-1\"", gotETag)
	}
	if gotMap["unknownServerField"] != "keep-me" {
		t.Fatalf("unknownServerField = %v, want keep-me", gotMap["unknownServerField"])
	}
}
