package receipt

import (
	"math/rand"
	"testing"
)

func TestSIMDCompressEquivalence(t *testing.T) {
	rng := rand.New(rand.NewSource(1337))

	// Test 100 random blocks and parameters
	for i := 0; i < 100; i++ {
		var cv [8]uint32
		for j := 0; j < 8; j++ {
			cv[j] = rng.Uint32()
		}

		var block [64]byte
		for j := 0; j < 64; j++ {
			block[j] = byte(rng.Intn(256))
		}

		blockLen := uint32(rng.Intn(65))
		counter := rng.Uint64()
		flags := rng.Uint32()

		scalarOut := compress(&cv, &block, blockLen, counter, flags)
		simdOut := CompressSIMD(&cv, &block, blockLen, counter, flags)

		if scalarOut != simdOut {
			t.Fatalf("iteration %d: mismatch between scalar compress and CompressSIMD:\nscalar: %x\nsimd:   %x",
				i, scalarOut, simdOut)
		}
	}
}

func TestTurnstileReceiptSIMDEquivalence(t *testing.T) {
	testCases := []struct {
		op        string
		timestamp uint64
		payload   []byte
	}{
		{"echo", 1730000000000000000, []byte(`{"hello":"world"}`)},
		{"arm.request", 1730000000000000000, []byte(`{"k":"v"}`)},
		{"arm.resource_group", 1234567890, []byte(``)},
		{"custom.heavy", 9999999999, patternInput(2048)},
	}

	for _, tc := range testCases {
		expected := TurnstileReceipt(tc.op, tc.timestamp, tc.payload)
		simd := TurnstileReceiptSIMD(tc.op, tc.timestamp, tc.payload)

		if expected != simd {
			t.Errorf("op=%s mismatch:\nexpected: %x\nsimd:     %x", tc.op, expected, simd)
		}
	}
}

func TestSIMDZeroAllocations(t *testing.T) {
	var cv [8]uint32
	var block [64]byte
	var sink [8]uint32

	allocsCompress := testing.AllocsPerRun(100, func() {
		sink = CompressSIMD(&cv, &block, 64, 0, flagRoot)
	})
	if allocsCompress != 0 {
		t.Fatalf("CompressSIMD allocated %.1f times; want 0", allocsCompress)
	}
	_ = sink

	payload := []byte(`{"simd":"zeroalloc"}`)
	var sinkReceipt [32]byte
	allocsReceipt := testing.AllocsPerRun(100, func() {
		sinkReceipt = TurnstileReceiptSIMD("arm.request", 1730000000000000000, payload)
	})
	if allocsReceipt != 0 {
		t.Fatalf("TurnstileReceiptSIMD allocated %.1f times; want 0", allocsReceipt)
	}
	_ = sinkReceipt
}

func BenchmarkScalarCompress(b *testing.B) {
	cv := [8]uint32{iv0, iv1, iv2, iv3, iv4, iv5, iv6, iv7}
	var block [64]byte
	for i := range block {
		block[i] = byte(i)
	}

	b.ResetTimer()
	b.ReportAllocs()
	for i := 0; i < b.N; i++ {
		_ = compress(&cv, &block, 64, 0, flagRoot)
	}
}

func BenchmarkSIMDCompress(b *testing.B) {
	cv := [8]uint32{iv0, iv1, iv2, iv3, iv4, iv5, iv6, iv7}
	var block [64]byte
	for i := range block {
		block[i] = byte(i)
	}

	b.ResetTimer()
	b.ReportAllocs()
	for i := 0; i < b.N; i++ {
		_ = CompressSIMD(&cv, &block, 64, 0, flagRoot)
	}
}

func BenchmarkScalarTurnstileReceipt(b *testing.B) {
	payload := []byte(`{"subscription_id":"00000000-0000-0000-0000-000000000000","resource":"test"}`)
	b.ResetTimer()
	b.ReportAllocs()
	for i := 0; i < b.N; i++ {
		_ = TurnstileReceipt("arm.request", 1730000000000000000, payload)
	}
}

func BenchmarkSIMDTurnstileReceipt(b *testing.B) {
	payload := []byte(`{"subscription_id":"00000000-0000-0000-0000-000000000000","resource":"test"}`)
	b.ResetTimer()
	b.ReportAllocs()
	for i := 0; i < b.N; i++ {
		_ = TurnstileReceiptSIMD("arm.request", 1730000000000000000, payload)
	}
}
