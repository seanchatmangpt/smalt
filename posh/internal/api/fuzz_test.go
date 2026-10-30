package api

import (
	"bytes"
	"encoding/json"
	"testing"
)

// FuzzDecodeRequest tests the membrane request JSON deserializer against arbitrary byte sequences.
// It exercises malformed UTF-8, null bytes, oversized keys/values, deeply nested structures,
// and boundary conditions around required fields (id, op).
func FuzzDecodeRequest(f *testing.F) {
	// Seed corpus with representative valid, boundary, and edge inputs
	f.Add([]byte(`{"id":"req-1","op":"echo","params":{"msg":"hello"}}`))
	f.Add([]byte(`{"id":"req-2","op":"arm.get","params":{},"deadline":"2026-10-30T15:04:05Z"}`))
	f.Add([]byte(`{"id":"","op":"echo"}`))
	f.Add([]byte(`{"id":"req-3","op":""}`))
	f.Add([]byte(`{}`))
	f.Add([]byte(`null`))
	f.Add([]byte(`{"id":"\u0000","op":"\u0000"}`))
	f.Add([]byte(`{"id":"` + string(bytes.Repeat([]byte("A"), 10000)) + `","op":"bench"}`))
	f.Add([]byte(`{"id":"1","op":"echo","params":{"a":"` + string([]byte{0xff, 0xfe, 0xfd}) + `"}}`))

	f.Fuzz(func(t *testing.T, data []byte) {
		req, err := DecodeRequest(data)
		if err != nil {
			if req != nil {
				t.Fatalf("DecodeRequest returned non-nil request on error: %+v", req)
			}
			return
		}

		// Invariant: Non-nil request MUST satisfy contract
		if req.ID == "" {
			t.Fatalf("DecodeRequest returned request with empty ID")
		}
		if req.Op == "" {
			t.Fatalf("DecodeRequest returned request with empty Op")
		}

		// Invariant: Re-marshaling an admitted request should succeed
		marshaled, err := json.Marshal(req)
		if err != nil {
			t.Fatalf("failed to marshal admitted request: %v", err)
		}

		// Invariant: Decoding the re-marshaled bytes must succeed
		redecoded, err := DecodeRequest(marshaled)
		if err != nil {
			t.Fatalf("failed to re-decode marshaled request: %v", err)
		}
		if redecoded.ID != req.ID || redecoded.Op != req.Op {
			t.Fatalf("round-trip mismatch: got (ID=%q, Op=%q), want (ID=%q, Op=%q)",
				redecoded.ID, redecoded.Op, req.ID, req.Op)
		}
	})
}

// FuzzDecodeResponse tests the membrane response JSON deserializer against arbitrary byte sequences.
// Invariants enforced: exactly one of ok or error must be set, id must be non-empty, no panics.
func FuzzDecodeResponse(f *testing.F) {
	f.Add([]byte(`{"id":"res-1","ok":{"result":{"status":"ready"}}}`))
	f.Add([]byte(`{"id":"res-2","error":{"code":"UPSTREAM","message":"service down"}}`))
	f.Add([]byte(`{"id":"res-3","ok":{},"error":{"code":"DEADLINE"}}`))
	f.Add([]byte(`{"id":"res-4"}`))
	f.Add([]byte(`{"id":"res-5","receipt":"` + string(bytes.Repeat([]byte("a"), 64)) + `"}`))
	f.Add([]byte(`{"id":"res-6","ok":{"result":null}}`))
	f.Add([]byte(`{"id":"","ok":{"result":{}}}`))

	f.Fuzz(func(t *testing.T, data []byte) {
		resp, err := DecodeResponse(data)
		if err != nil {
			if resp != nil {
				t.Fatalf("DecodeResponse returned non-nil response on error: %+v", resp)
			}
			return
		}

		// Invariant: Non-nil response must have an ID
		if resp.ID == "" {
			t.Fatalf("DecodeResponse returned response with empty ID")
		}

		// Invariant: Exactly one of Ok or Error must be non-nil
		if (resp.Ok == nil) == (resp.Error == nil) {
			t.Fatalf("DecodeResponse allowed violation of exactly-one(ok, error): ok=%v, error=%v",
				resp.Ok != nil, resp.Error != nil)
		}

		// Invariant: Encode helper round-trip
		encoded, err := Encode(resp)
		if err != nil {
			t.Fatalf("Encode failed on admitted response: %v", err)
		}
		redecoded, err := DecodeResponse(encoded)
		if err != nil {
			t.Fatalf("re-decode failed on encoded response: %v", err)
		}
		if redecoded.ID != resp.ID {
			t.Fatalf("ID mismatch after round-trip: got %q, want %q", redecoded.ID, resp.ID)
		}
	})
}

// FuzzResponseRoundTrip verifies that arbitrary valid inputs to NewOK and NewError
// survive serialization and deserialization without corruption or panics.
func FuzzResponseRoundTrip(f *testing.F) {
	f.Add("req-1", "key1", "val1", "op1", "msg1", uint8(0))
	f.Add("req-2", "", "", "", "", uint8(1))
	f.Add(string([]byte{0x00, 0x01, 0x02}), "key", "val", "op", "msg", uint8(2))

	f.Fuzz(func(t *testing.T, id, key, val, op, msg string, mode uint8) {
		if id == "" {
			return
		}

		var resp *Response
		switch mode % 2 {
		case 0:
			resp = NewOK(id, map[string]string{key: val})
		case 1:
			resp = NewError(id, CodeUpstream, "%s: %s", op, msg)
		}

		encoded, err := Encode(resp)
		if err != nil {
			t.Fatalf("Encode failed: %v", err)
		}

		decoded, err := DecodeResponse(encoded)
		if err != nil {
			t.Fatalf("DecodeResponse failed on valid encoded response: %v", err)
		}

		if decoded.ID != resp.ID {
			t.Errorf("ID mismatch: got %q, want %q", decoded.ID, resp.ID)
		}
		if (decoded.Ok != nil) != (resp.Ok != nil) {
			t.Errorf("Ok presence mismatch")
		}
		if (decoded.Error != nil) != (resp.Error != nil) {
			t.Errorf("Error presence mismatch")
		}
	})
}
