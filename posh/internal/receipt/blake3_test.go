package receipt

import (
	"encoding/hex"
	"strings"
	"testing"
)

// Official BLAKE3 test vectors (input is bytes 0, 1, 2, ... mod 251).
func patternInput(n int) []byte {
	out := make([]byte, n)
	for i := 0; i < n; i++ {
		out[i] = byte(i % 251)
	}
	return out
}

func TestOfficialBLAKE3Vectors(t *testing.T) {
	cases := []struct {
		length int
		want   string
	}{
		{0, "af1349b9f5f9a1a6a0404dea36dcc9499bcb25c9adc112b7cc9a93cae41f3262"},
		{1, "2d3adedff11b61f14c886e35afa036736dcd87a74d27b5c1510225d0f592e213"},
		{63, "e9bc37a594daad83be9470df7f7b3798297c3d834ce80ba85d6e207627b7db7b"},
		{64, "4eed7141ea4a5cd4b788606bd23f46e212af9cacebacdc7d1f4c6dc7f2511b98"},
		{65, "de1e5fa0be70df6d2be8fffd0e99ceaa8eb6e8c93a63f2d8d1c30ecb6b263dee"},
		{1024, "42214739f095a406f3fc83deb889744ac00df831c10daa55189b5d121c855af7"},
		{1025, "d00278ae47eb27b34faecf67b4fe263f82d5412916c1ffd97c8cb7fb814b8444"},
		// Multi-chunk tree vectors (official input_type 0 pattern, computed
		// with python-blake3 over the same bytes 0..n-1 mod 251 pattern):
		{2049, "5f4d72f40d7a5f82b15ca2b2e44b1de3c2ef86c426c95c1af0b6879522563030"},
		{4096, "015094013f57a5277b59d8475c0501042c0b642e531b0a1c8f58d2163229e969"},
	}

	// Verify exact official specification hashes for all pinned lengths.
	for _, tc := range cases {
		got := Sum256(patternInput(tc.length))
		gotHex := hex.EncodeToString(got[:])
		if gotHex != tc.want {
			t.Errorf("Sum256(len=%d) = %s, want %s", tc.length, gotHex, tc.want)
		}
	}
}

// Pinned cross-lane vector (matches the Elixir lane byte-for-byte):
// op="arm.request", ts=1730000000000000000, payload=`{"k":"v"}`.
// Independently computed with python-blake3 1.0.8 over
// "arm.request" || u64BE(1730000000000000000) || `{"k":"v"}` (28 bytes).
func TestTurnstileReceiptFixedVector(t *testing.T) {
	const want = "0c39d201b2fc87a2171046f1e76f8afc5398263d888381ee9f24cae4cabdb834"
	got := TurnstileReceipt("arm.request", 1730000000000000000, []byte(`{"k":"v"}`))
	if gotHex := hex.EncodeToString(got[:]); gotHex != want {
		t.Fatalf("TurnstileReceipt fixed vector = %s, want %s", gotHex, want)
	}
}

func TestTurnstileReceiptDeterminismAndSensitivity(t *testing.T) {
	payload := []byte(`{"subscription_id":"00000000-0000-0000-0000-000000000000"}`)

	r1 := TurnstileReceipt("echo", 1730280000000000000, payload)
	for i := 0; i < 50; i++ {
		r2 := TurnstileReceipt("echo", 1730280000000000000, payload)
		if r1 != r2 {
			t.Fatalf("iteration %d: non-deterministic receipt: %x != %x", i, r1, r2)
		}
	}

	// Mutating payload must change the receipt (non-vacuity).
	rDiffPayload := TurnstileReceipt("echo", 1730280000000000000, []byte(`{"subscription_id":"ff"}`))
	if r1 == rDiffPayload {
		t.Fatal("different payload produced identical receipt")
	}

	// Mutating op or timestamp must change the receipt (non-vacuity).
	if rDiffOp := TurnstileReceipt("arm.request", 1730280000000000000, payload); r1 == rDiffOp {
		t.Fatal("different op produced identical receipt")
	}
	if rDiffTs := TurnstileReceipt("echo", 1730280000000000001, payload); r1 == rDiffTs {
		t.Fatal("different timestamp produced identical receipt")
	}
}

func bytes64(b byte) []byte {
	out := make([]byte, 64)
	for i := range out {
		out[i] = b
	}
	return out
}

func TestMerkleRootKnownAnswer(t *testing.T) {
	// Independent reference: children = python-blake3 digests of 'x'*64 and
	// 'y'*64; root = parent-node compress(IV, left||right, 64, 0, parent|root)
	// computed by a from-spec Python reimplementation of the BLAKE3
	// compression function (sanity-checked against the official test vectors).
	left := Sum256(bytes64('x'))
	right := Sum256(bytes64('y'))
	if got := hex.EncodeToString(left[:]); got != "84421676fe0d5a2229f1e3bbf7b84cf541c8a3bad9f0606a96ecbcba941c2380" {
		t.Fatalf("left child vector drifted: %s", got)
	}
	if got := hex.EncodeToString(right[:]); got != "ae6b82314d7d931b55ffefbe2f81ecf4ed5827f208a4d27b1b1953ec4fd533f4" {
		t.Fatalf("right child vector drifted: %s", got)
	}
	const wantRoot = "1e5a2a0a753ed536808aec5ff749d9c365f2ddbf999f27131009460ab39b3678"
	root := MerkleRoot(left, right)
	if got := hex.EncodeToString(root[:]); got != wantRoot {
		t.Fatalf("MerkleRoot = %s, want %s", got, wantRoot)
	}
}

func TestZeroAllocHotPath(t *testing.T) {
	payload := []byte(`{"k":"v"}`)
	var sink [32]byte

	allocs := testing.AllocsPerRun(100, func() {
		sink = TurnstileReceipt("arm.request", 123456789, payload)
	})
	if sink == ([32]byte{}) {
		t.Fatal("zero receipt")
	}
	if allocs != 0 {
		t.Fatalf("TurnstileReceipt allocated %.1f times per run; SPAF Rule 3 requires 0 heap allocs", allocs)
	}
}

func TestHexZeroAlloc(t *testing.T) {
	r := TurnstileReceipt("arm.request", 1730000000000000000, []byte(`{"k":"v"}`))

	allocs := testing.AllocsPerRun(100, func() {
		if s := Hex(r); len(s) != 64 {
			t.Fatal("bad hex length")
		}
	})
	if allocs != 1 {
		t.Fatalf("Hex allocated %.1f times per run; contract pins exactly 1 alloc (the returned string)", allocs)
	}
}

func TestVerifyTurnstile(t *testing.T) {
	payload := []byte(`{"k":"v"}`)
	good := Hex(TurnstileReceipt("arm.request", 1730000000000000000, payload))

	ok, err := VerifyTurnstile(good, "arm.request", 1730000000000000000, payload)
	if !ok || err != nil {
		t.Fatalf("VerifyTurnstile(good) = %v, %v; want true, nil", ok, err)
	}

	// Tampered payload must fail.
	if ok, _ := VerifyTurnstile(good, "arm.request", 1730000000000000000, []byte(`{"k":"V"}`)); ok {
		t.Fatal("tampered payload accepted")
	}
	// Tampered op must fail.
	if ok, _ := VerifyTurnstile(good, "arm.REQUEST", 1730000000000000000, payload); ok {
		t.Fatal("tampered op accepted")
	}
	// Tampered timestamp must fail.
	if ok, _ := VerifyTurnstile(good, "arm.request", 1730000000000000001, payload); ok {
		t.Fatal("tampered timestamp accepted")
	}
	// Tampered digest must fail (single flipped hex digit).
	tampered := good
	if good[0] == '0' {
		tampered = "1" + good[1:]
	} else {
		tampered = "0" + good[1:]
	}
	if tampered == good {
		t.Fatal("tamper was a no-op")
	}
	if ok, _ := VerifyTurnstile(tampered, "arm.request", 1730000000000000000, payload); ok {
		t.Fatal("tampered digest accepted")
	}

	// Length rejections: 0, 63, 65 chars, and non-hex of correct length.
	for _, bad := range []string{"", good[:63], good + "a", strings.Repeat("z", 64)} {
		ok, err := VerifyTurnstile(bad, "arm.request", 1730000000000000000, payload)
		if ok {
			t.Fatalf("VerifyTurnstile(%q) accepted; want rejection", bad)
		}
		if err == nil {
			t.Fatalf("VerifyTurnstile(%q) returned nil error; want ErrBadTurnstileHex", bad)
		}
	}

	// Uppercase hex of the same digest must verify (hex.DecodeString accepts it).
	if ok, err := VerifyTurnstile(strings.ToUpper(good), "arm.request", 1730000000000000000, payload); !ok || err != nil {
		t.Fatalf("VerifyTurnstile(uppercase) = %v, %v; want true, nil", ok, err)
	}
}

// TestOversizedInputPanics pins the hard capacity bound: > 64 MiB of input
// (2^16 chunks) previously silently dropped a chunk CV and produced a wrong
// digest; the hasher must now panic (Sum256 returns no error) rather than
// corrupt output.
func TestOversizedInputPanics(t *testing.T) {
	// Drive pushChunkCV directly with a full 16-slot parent stack and no
	// merge available (odd totalChunks): the 17th CV must panic instead of
	// being silently dropped (the pre-fix behavior, which corrupted the
	// digest). First reachable at chunk 2^17-2 via streaming input.
	h := &chunkHasher{}
	h.numParents = 16
	defer func() {
		r := recover()
		if r == nil {
			t.Fatal("pushChunkCV on full parent stack did not panic; want capacity panic")
		}
		const want = "receipt: input exceeds hasher capacity (64 MiB)"
		if r != want {
			t.Fatalf("panic value = %v, want %q", r, want)
		}
	}()
	h.pushChunkCV([8]uint32{1, 2, 3, 4, 5, 6, 7, 8}, 3)
}
