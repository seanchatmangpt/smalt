package chaos

import (
	"context"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"smalt.dev/posh/internal/api"
	"smalt.dev/posh/internal/receipt"
)

func dummyHandler(ctx context.Context, req *api.Request) *api.Response {
	resp := api.NewOK(req.ID, map[string]string{"status": "echoed", "op": req.Op})
	ts := uint64(1700000000000000000)
	raw := []byte(`{"id":"` + req.ID + `","op":"` + req.Op + `"}`)
	resp.Receipt = receipt.Hex(receipt.TurnstileReceipt(req.Op, ts, raw))
	return resp
}

func TestDeterministicChaosSequence(t *testing.T) {
	t.Parallel()

	profile := FaultProfile{
		Seed:                 42,
		Upstream503Rate:      0.5,
		CorruptTurnstileRate: 0.5,
	}

	e1 := NewEngine(profile)
	e2 := NewEngine(profile)

	h1 := e1.InterceptHandler(dummyHandler)
	h2 := e2.InterceptHandler(dummyHandler)

	for i := 0; i < 20; i++ {
		req := &api.Request{ID: "req-1", Op: "echo"}
		ctx := context.Background()

		r1 := h1(ctx, req)
		r2 := h2(ctx, req)

		if (r1.Error != nil) != (r2.Error != nil) {
			t.Fatalf("step %d: divergence in 503 error injection: r1=%v, r2=%v", i, r1.Error, r2.Error)
		}
		if r1.Receipt != r2.Receipt {
			t.Fatalf("step %d: divergence in receipt corruption: r1=%q, r2=%q", i, r1.Receipt, r2.Receipt)
		}
	}
}

func TestUpstreamStormInjection(t *testing.T) {
	t.Parallel()

	t.Run("503 storm short-circuits handler", func(t *testing.T) {
		e := NewEngine(FaultProfile{Upstream503Rate: 1.0})
		h := e.InterceptHandler(dummyHandler)

		resp := h(context.Background(), &api.Request{ID: "req-503", Op: "arm.create"})
		if resp.Error == nil {
			t.Fatalf("expected 503 error response, got ok: %+v", resp)
		}
		if resp.Error.Code != api.CodeUpstream {
			t.Errorf("error code = %s, want UPSTREAM", resp.Error.Code)
		}
		if !strings.Contains(resp.Error.Message, "503") {
			t.Errorf("error message does not contain 503: %s", resp.Error.Message)
		}
		if e.Stats().Injected503Storms != 1 {
			t.Errorf("stats: 503 storms = %d, want 1", e.Stats().Injected503Storms)
		}
	})

	t.Run("429 rate limit storm includes retry-after", func(t *testing.T) {
		e := NewEngine(FaultProfile{
			Upstream429Rate:   1.0,
			RetryAfterSeconds: 15,
		})
		h := e.InterceptHandler(dummyHandler)

		resp := h(context.Background(), &api.Request{ID: "req-429", Op: "arm.get"})
		if resp.Error == nil {
			t.Fatalf("expected 429 error response, got ok: %+v", resp)
		}
		if resp.Error.Code != api.CodeUpstream {
			t.Errorf("error code = %s, want UPSTREAM", resp.Error.Code)
		}
		if !strings.Contains(resp.Error.Message, "429") || !strings.Contains(resp.Error.Message, "15s") {
			t.Errorf("error message does not mention 429 and 15s: %s", resp.Error.Message)
		}
	})
}

func TestTurnstileCorruptionDetection(t *testing.T) {
	t.Parallel()

	e := NewEngine(FaultProfile{CorruptTurnstileRate: 1.0})
	h := e.InterceptHandler(dummyHandler)

	req := &api.Request{ID: "req-sig", Op: "echo"}
	resp := h(context.Background(), req)

	if resp.Error != nil {
		t.Fatalf("handler returned unexpected error: %+v", resp.Error)
	}

	ts := uint64(1700000000000000000)
	raw := []byte(`{"id":"req-sig","op":"echo"}`)

	valid, _ := receipt.VerifyTurnstile(resp.Receipt, req.Op, ts, raw)
	if valid {
		t.Fatalf("expected corrupted receipt to FAIL verification, but it passed: receipt=%q", resp.Receipt)
	}
}

func TestJitterDeadlineExceeded(t *testing.T) {
	t.Parallel()

	e := NewEngine(FaultProfile{
		JitterMin: 50 * time.Millisecond,
		JitterMax: 100 * time.Millisecond,
	})
	h := e.InterceptHandler(dummyHandler)

	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Millisecond)
	defer cancel()

	resp := h(ctx, &api.Request{ID: "req-timeout", Op: "echo"})
	if resp.Error == nil {
		t.Fatalf("expected deadline error, got ok: %+v", resp)
	}
	if resp.Error.Code != api.CodeDeadline {
		t.Errorf("got error code %s, want DEADLINE", resp.Error.Code)
	}
}

func TestChaosRoundTripper(t *testing.T) {
	t.Parallel()

	ts := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusOK)
		w.Write([]byte(`{"status":"ok"}`))
	}))
	defer ts.Close()

	t.Run("inject 503 round-trip", func(t *testing.T) {
		e := NewEngine(FaultProfile{Upstream503Rate: 1.0})
		client := &http.Client{Transport: NewChaosRoundTripper(e, nil)}

		resp, err := client.Get(ts.URL)
		if err != nil {
			t.Fatalf("unexpected transport err: %v", err)
		}
		defer resp.Body.Close()

		if resp.StatusCode != http.StatusServiceUnavailable {
			t.Errorf("status code = %d, want 503", resp.StatusCode)
		}
	})

	t.Run("inject 429 round-trip with retry header", func(t *testing.T) {
		e := NewEngine(FaultProfile{Upstream429Rate: 1.0, RetryAfterSeconds: 30})
		client := &http.Client{Transport: NewChaosRoundTripper(e, nil)}

		resp, err := client.Get(ts.URL)
		if err != nil {
			t.Fatalf("unexpected transport err: %v", err)
		}
		defer resp.Body.Close()

		if resp.StatusCode != http.StatusTooManyRequests {
			t.Errorf("status code = %d, want 429", resp.StatusCode)
		}
		if retry := resp.Header.Get("Retry-After"); retry != "30" {
			t.Errorf("Retry-After header = %q, want 30", retry)
		}
	})
}

func TestMakeCorruptedFrame(t *testing.T) {
	t.Parallel()

	payload := []byte(`{"id":"1","op":"echo"}`)

	f0 := MakeCorruptedFrame(payload, 0)
	if len(f0) != len(payload)+4 {
		t.Errorf("f0 len = %d, want %d", len(f0), len(payload)+4)
	}

	f1 := MakeCorruptedFrame(payload, 1)
	if f1[5] != 0xff {
		t.Errorf("f1 did not inject bit flip")
	}

	f2 := MakeCorruptedFrame(payload, 2)
	if len(f2) != len(payload)+4 {
		t.Errorf("f2 len mismatch")
	}
}
