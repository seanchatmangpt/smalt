package provider

import (
	"context"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
)

// Turnstile courts (gaps/26 close, wave-2 gap lane 2026-10-30). Chicago-style:
// real httptest servers, real client round-trips, assertions on final state.
// A court that cannot flip is vacuous (see TestTurnstileGateIsNonVacuous).

// turnstileStub is a real HTTP stub that stamps (or withholds / tampers) the
// turnstile header pair like the smalt gateway would.
type turnstileStub struct {
	stamp    string // "valid", "omit", "tamper", "shorthex", "badts"
	lastBody []byte
}

func (s *turnstileStub) handler(t *testing.T) http.Handler {
	mux := http.NewServeMux()
	mux.HandleFunc("/", func(w http.ResponseWriter, r *http.Request) {
		body, _ := readAllLimit(r.Body)
		s.lastBody = body
		tsNs := uint64(1730000000000000000)
		w.Header().Set("Content-Type", "application/json")
		switch s.stamp {
		case "valid":
			w.Header().Set(turnstileHeader, Hex(TurnstileReceipt(turnstileOp, tsNs, body)))
			w.Header().Set(turnstileTSHeader, "1730000000000000000")
		case "tamper":
			d := Hex(TurnstileReceipt(turnstileOp, tsNs, body))
			w.Header().Set(turnstileHeader, flipHexChar(d))
			w.Header().Set(turnstileTSHeader, "1730000000000000000")
		case "shorthex":
			w.Header().Set(turnstileHeader, "abcd")
			w.Header().Set(turnstileTSHeader, "1730000000000000000")
		case "badts":
			w.Header().Set(turnstileHeader, Hex(TurnstileReceipt(turnstileOp, tsNs, body)))
			w.Header().Set(turnstileTSHeader, "not-a-number")
		case "omit":
			// headers withheld entirely — must fail closed
		}
		w.WriteHeader(http.StatusOK)
		_, _ = w.Write([]byte(`{"ok":true}`))
	})
	// STS token endpoint (POST /{tenant}/oauth2/v2.0/token) — outside the
	// /subscriptions fence, unstamped, and NOT verified (token mint is not a
	// resource delta).
	mux.HandleFunc("/00000000-0000-0000-0000-000000000000/oauth2/v2.0/token", func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		_, _ = w.Write([]byte(`{"access_token":"stub-token","expires_in":3600}`))
	})
	return mux
}

func flipHexChar(s string) string {
	if s[0] == '0' {
		return "1" + s[1:]
	}
	return "0" + s[1:]
}

func readAllLimit(r interface{ Read([]byte) (int, error) }) ([]byte, error) {
	buf := make([]byte, 0, 4096)
	tmp := make([]byte, 1024)
	for {
		n, err := r.Read(tmp)
		buf = append(buf, tmp[:n]...)
		if err != nil {
			return buf, nil //nolint:errcheck // EOF ends the body
		}
	}
}

func newTurnstileClient(t *testing.T, stub *turnstileStub) *Client {
	t.Helper()
	srv := httptest.NewServer(stub.handler(t))
	t.Cleanup(srv.Close)
	c, err := NewClient(context.Background(), srv.URL, "sub-1", "00000000-0000-0000-0000-000000000000", "client-1", "")
	if err != nil {
		t.Fatalf("NewClient: %v", err)
	}
	return c
}

const turnstileProbeBody = `{"location":"westus2"}`

func TestTurnstileValidPairPasses(t *testing.T) {
	stub := &turnstileStub{stamp: "valid"}
	c := newTurnstileClient(t, stub)
	_, status, err := c.do(nil2ctx(), http.MethodPut, "/subscriptions/s/resourcegroups/rg1", []byte(turnstileProbeBody), "application/json")
	if err != nil {
		t.Fatalf("valid pair must pass, got %v", err)
	}
	if status != http.StatusOK {
		t.Fatalf("status = %d, want 200", status)
	}
	if string(stub.lastBody) != turnstileProbeBody {
		t.Fatalf("stub saw different body: %q", stub.lastBody)
	}
}

func TestTurnstileMissingHeadersRefused(t *testing.T) {
	stub := &turnstileStub{stamp: "omit"}
	c := newTurnstileClient(t, stub)
	_, _, err := c.do(nil2ctx(), http.MethodPut, "/subscriptions/s/resourcegroups/rg1", []byte(turnstileProbeBody), "application/json")
	if err == nil {
		t.Fatalf("missing headers must be a fail-closed refusal, got nil error")
	}
	if !strings.Contains(err.Error(), "turnstile missing") {
		t.Fatalf("refusal must be typed (turnstile missing), got %q", err.Error())
	}
}

func TestTurnstileTamperedDigestRefused(t *testing.T) {
	stub := &turnstileStub{stamp: "tamper"}
	c := newTurnstileClient(t, stub)
	_, _, err := c.do(nil2ctx(), http.MethodPut, "/subscriptions/s/resourcegroups/rg1", []byte(turnstileProbeBody), "application/json")
	if err == nil {
		t.Fatalf("tampered digest must be refused")
	}
	if !strings.Contains(err.Error(), "digest mismatch") {
		t.Fatalf("refusal must name digest mismatch, got %q", err.Error())
	}
}

func TestTurnstileShortHexRefused(t *testing.T) {
	stub := &turnstileStub{stamp: "shorthex"}
	c := newTurnstileClient(t, stub)
	if _, _, err := c.do(nil2ctx(), http.MethodPut, "/subscriptions/s/resourcegroups/rg1", []byte(turnstileProbeBody), "application/json"); err == nil {
		t.Fatalf("short hex header must be refused")
	}
}

func TestTurnstileBadTimestampRefused(t *testing.T) {
	stub := &turnstileStub{stamp: "badts"}
	c := newTurnstileClient(t, stub)
	if _, _, err := c.do(nil2ctx(), http.MethodPut, "/subscriptions/s/resourcegroups/rg1", []byte(turnstileProbeBody), "application/json"); err == nil {
		t.Fatalf("bad timestamp header must be refused")
	}
}

func TestTurnstileGetExemptNoWireChange(t *testing.T) {
	// GETs are stamp-only (gaps/14 clause 1): an unstamped GET response must
	// still pass — proving the verification adds NO wire requirement on reads
	// and the provider's zero-code-change wire behavior on reads is intact.
	stub := &turnstileStub{stamp: "omit"}
	c := newTurnstileClient(t, stub)
	_, status, err := c.do(nil2ctx(), http.MethodGet, "/subscriptions/s/resourcegroups/rg1", nil, "")
	if err != nil {
		t.Fatalf("unstamped GET must pass (stamp-only), got %v", err)
	}
	if status != http.StatusOK {
		t.Fatalf("status = %d, want 200", status)
	}
}

func TestTurnstileDeleteEmptyBodyStillVerified(t *testing.T) {
	// DELETE carries an empty request body; the digest binds (op, ts, empty).
	stub := &turnstileStub{stamp: "valid"}
	c := newTurnstileClient(t, stub)
	if _, _, err := c.do(nil2ctx(), http.MethodDelete, "/subscriptions/s/resourcegroups/rg1", nil, ""); err != nil {
		t.Fatalf("valid DELETE pair must pass, got %v", err)
	}
	stub2 := &turnstileStub{stamp: "omit"}
	c2 := newTurnstileClient(t, stub2)
	if _, _, err := c2.do(nil2ctx(), http.MethodDelete, "/subscriptions/s/resourcegroups/rg1", nil, ""); err == nil {
		t.Fatalf("unstamped DELETE must fail closed")
	}
}

// TestTurnstileGateIsNonVacuous is the honesty_law_test-style mirror unit:
// the verification helper itself must refuse a mutated (header-stripped)
// response — a gate that cannot flip is vacuous.
func TestTurnstileGateIsNonVacuous(t *testing.T) {
	hdr := http.Header{}
	hdr.Set(turnstileHeader, Hex(TurnstileReceipt(turnstileOp, 42, []byte(turnstileProbeBody))))
	hdr.Set(turnstileTSHeader, "42")
	if err := verifyTurnstileResponse(http.MethodPut, hdr, []byte(turnstileProbeBody)); err != nil {
		t.Fatalf("valid pair must verify: %v", err)
	}
	stripped := http.Header{}
	if err := verifyTurnstileResponse(http.MethodPut, stripped, []byte(turnstileProbeBody)); err == nil {
		t.Fatalf("stripped-header mutation must flip the gate (non-vacuity)")
	}
	tampered := http.Header{}
	tampered.Set(turnstileHeader, flipHexChar(Hex(TurnstileReceipt(turnstileOp, 42, []byte(turnstileProbeBody)))))
	tampered.Set(turnstileTSHeader, "42")
	if err := verifyTurnstileResponse(http.MethodPut, tampered, []byte(turnstileProbeBody)); err == nil {
		t.Fatalf("tampered digest must flip the gate")
	}
	if err := verifyTurnstileResponse(http.MethodGet, stripped, nil); err != nil {
		t.Fatalf("GET must be exempt: %v", err)
	}
}

func nil2ctx() context.Context { return context.Background() }
