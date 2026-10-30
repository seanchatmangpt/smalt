package api

import (
	"testing"
	"time"
)

func TestEnvelopeRoundTrip(t *testing.T) {
	t.Parallel()
	cases := []struct {
		name string
		req  *Request
	}{
		{name: "full params and deadline", req: &Request{
			ID:       "r1",
			Op:       "echo",
			Params:   map[string]string{"k": "v"},
			Deadline: time.Now().Add(time.Second).UTC().Round(0),
		}},
		{name: "empty params, zero deadline", req: &Request{ID: "r2", Op: "echo"}},
	}
	for _, tc := range cases {
		tc := tc
		t.Run(tc.name, func(t *testing.T) {
			t.Parallel()
			raw, err := Encode(NewOK(tc.req.ID, tc.req.Params))
			if err != nil {
				t.Fatalf("encode: %v", err)
			}
			resp, err := DecodeResponse(raw)
			if err != nil {
				t.Fatalf("decode: %v (raw=%s)", err, raw)
			}
			if resp.ID != tc.req.ID {
				t.Errorf("id = %q, want %q", resp.ID, tc.req.ID)
			}
			if len(resp.Ok.Result) != len(tc.req.Params) {
				t.Errorf("result = %v, want %v", resp.Ok.Result, tc.req.Params)
			}
			for k, want := range tc.req.Params {
				if got := resp.Ok.Result[k]; got != want {
					t.Errorf("result[%q] = %q, want %q", k, got, want)
				}
			}
		})
	}
}

func TestDecodeResponseRejectsInvalidShapes(t *testing.T) {
	t.Parallel()
	cases := []struct {
		name string
		body string
	}{
		{name: "both ok and error", body: `{"id":"x","ok":{},"error":{"code":"TRANSPORT","message":"m"}}`},
		{name: "neither ok nor error", body: `{"id":"x"}`},
		{name: "missing id", body: `{"ok":{}}`},
		{name: "malformed json", body: `not json`},
	}
	for _, tc := range cases {
		tc := tc
		t.Run(tc.name, func(t *testing.T) {
			t.Parallel()
			if _, err := DecodeResponse([]byte(tc.body)); err == nil {
				t.Fatalf("DecodeResponse(%s) must be rejected", tc.body)
			}
		})
	}
}

func TestDecodeRequestRequiresIDAndOp(t *testing.T) {
	t.Parallel()
	cases := []struct {
		name string
		body string
	}{
		{name: "missing id", body: `{"op":"echo"}`},
		{name: "missing op", body: `{"id":"r"}`},
		{name: "malformed json", body: `not json`},
	}
	for _, tc := range cases {
		tc := tc
		t.Run(tc.name, func(t *testing.T) {
			t.Parallel()
			if _, err := DecodeRequest([]byte(tc.body)); err == nil {
				t.Fatalf("DecodeRequest(%s) must be rejected", tc.body)
			}
		})
	}
}

func TestDecodeRequestAdmitsEmptyParams(t *testing.T) {
	t.Parallel()
	req, err := DecodeRequest([]byte(`{"id":"r","op":"echo"}`))
	if err != nil {
		t.Fatalf("empty params must decode: %v", err)
	}
	if req.ID != "r" || req.Op != "echo" || len(req.Params) != 0 {
		t.Errorf("got %+v, want id=r op=echo empty params", req)
	}
}

func TestTypedErrorCodes(t *testing.T) {
	t.Parallel()
	cases := map[string]ErrorCode{
		"TRANSPORT":      CodeTransport,
		"UPSTREAM":       CodeUpstream,
		"DEADLINE":       CodeDeadline,
		"REFUSED_EGRESS": CodeRefusedEgress,
	}
	for want, code := range cases {
		if string(code) != want {
			t.Errorf("code %q != %q", code, want)
		}
	}
}
