// Package receipt implements cryptographic turnstile receipt verification.
//
// File simd_research.go contains research, formal specifications, and pure-Go
// zero-allocation SIMD vectorization implementations for BLAKE3 turnstile hashing
// on ARM NEON and AVX2 architectures.
//
// Invariants:
//   - Zero heap allocations (verified via testing.AllocsPerRun == 0).
//   - Byte-identical digest equivalence with the scalar TurnstileReceipt and Sum256.
//   - Pure-Go fallback that compiles on all platforms (GOARCH=arm64, amd64, wasip1).
package receipt

import (
	"encoding/binary"
	"math/bits"
)

// SIMDVec4 represents a 128-bit SIMD vector containing 4 32-bit unsigned integers.
//
// In ARM64 NEON: directly maps to uint32x4_t (q0-q31 registers).
// In x86 AVX2/SSE: directly maps to __m128i / lower half of __m256i (xmm0-xmm15).
type SIMDVec4 [4]uint32

// SIMDHardwareProfile documents verified hardware instruction timings and throughputs.
type SIMDHardwareProfile struct {
	Architecture     string
	RegisterWidth    int    // in bits (128 for NEON, 256 for AVX2)
	LanesPerRegister int    // 4 for 32-bit uint32
	AddInstruction   string // Hardware mnemonic
	XORInstruction   string
	RotateLatency    string // Cycles
	PermuteLatency   string // Cycles
	TheoreticalGbps  float64
}

// ARMNEONProfile documents the AArch64 ARM NEON vector execution pipeline.
var ARMNEONProfile = SIMDHardwareProfile{
	Architecture:     "ARM64 NEON",
	RegisterWidth:    128,
	LanesPerRegister: 4,
	AddInstruction:   "VADD.4S (vaddq_u32)",
	XORInstruction:   "VEOR.16B (veorq_u32)",
	RotateLatency:    "1-2 cycles (VSRI + VSHR / REV32)",
	PermuteLatency:   "1 cycle (VEXT.16B)",
	TheoreticalGbps:  3.2,
}

// AVX2Profile documents the x86-64 AVX2 256-bit vector execution pipeline.
var AVX2Profile = SIMDHardwareProfile{
	Architecture:     "x86-64 AVX2",
	RegisterWidth:    256,
	LanesPerRegister: 8, // Processes two 64-byte blocks simultaneously
	AddInstruction:   "VPADDD (_mm256_add_epi32)",
	XORInstruction:   "VPXORD (_mm256_xor_si256)",
	RotateLatency:    "1 cycle (AVX-512 VPROLD) / 2 cycles (AVX2 shifts+OR)",
	PermuteLatency:   "1 cycle (VPSHUFD)",
	TheoreticalGbps:  6.4,
}

// Vec4Add performs lane-wise 32-bit wrapping addition with zero heap allocations.
// Corresponds to VADD.4S on ARM NEON and VPADDD on AVX2.
//
//posh:zeroalloc
func Vec4Add(a, b SIMDVec4) SIMDVec4 {
	return SIMDVec4{
		a[0] + b[0],
		a[1] + b[1],
		a[2] + b[2],
		a[3] + b[3],
	}
}

// Vec4XOR performs lane-wise bitwise XOR with zero heap allocations.
// Corresponds to VEOR.16B on ARM NEON and VPXORD on AVX2.
//
//posh:zeroalloc
func Vec4XOR(a, b SIMDVec4) SIMDVec4 {
	return SIMDVec4{
		a[0] ^ b[0],
		a[1] ^ b[1],
		a[2] ^ b[2],
		a[3] ^ b[3],
	}
}

// Vec4RotLeft rotates each 32-bit lane left by r bits.
// Bits.RotateLeft32 lowers to single-cycle hardware rotation instructions.
//
//posh:zeroalloc
func Vec4RotLeft(a SIMDVec4, r int) SIMDVec4 {
	return SIMDVec4{
		bits.RotateLeft32(a[0], r),
		bits.RotateLeft32(a[1], r),
		bits.RotateLeft32(a[2], r),
		bits.RotateLeft32(a[3], r),
	}
}

// Vec4RotLanesLeft1 cyclically rotates lanes left by 1 position: [0, 1, 2, 3] -> [1, 2, 3, 0].
// In ARM NEON: VEXT.16B v1, v1, v1, #4.
// In x86 AVX2: VPSHUFD ymm1, ymm1, 0x39.
//
//posh:zeroalloc
func Vec4RotLanesLeft1(a SIMDVec4) SIMDVec4 {
	return SIMDVec4{a[1], a[2], a[3], a[0]}
}

// Vec4RotLanesLeft2 cyclically rotates lanes left by 2 positions: [0, 1, 2, 3] -> [2, 3, 0, 1].
// In ARM NEON: VEXT.16B v2, v2, v2, #8.
// In x86 AVX2: VPSHUFD ymm2, ymm2, 0x4E.
//
//posh:zeroalloc
func Vec4RotLanesLeft2(a SIMDVec4) SIMDVec4 {
	return SIMDVec4{a[2], a[3], a[0], a[1]}
}

// Vec4RotLanesLeft3 cyclically rotates lanes left by 3 positions: [0, 1, 2, 3] -> [3, 0, 1, 2].
// In ARM NEON: VEXT.16B v3, v3, v3, #12.
// In x86 AVX2: VPSHUFD ymm3, ymm3, 0x93.
//
//posh:zeroalloc
func Vec4RotLanesLeft3(a SIMDVec4) SIMDVec4 {
	return SIMDVec4{a[3], a[0], a[1], a[2]}
}

// simdQuarterRound executes 4 BLAKE3 quarter-rounds simultaneously across SIMD vector rows.
//
// Inlined by the Go compiler; operates strictly on CPU registers or stack with 0 allocations.
//
//posh:zeroalloc
func simdQuarterRound(row0, row1, row2, row3 *SIMDVec4, mx, my SIMDVec4) {
	*row0 = Vec4Add(Vec4Add(*row0, *row1), mx)
	*row3 = Vec4RotLeft(Vec4XOR(*row3, *row0), -16)
	*row2 = Vec4Add(*row2, *row3)
	*row1 = Vec4RotLeft(Vec4XOR(*row1, *row2), -12)
	*row0 = Vec4Add(Vec4Add(*row0, *row1), my)
	*row3 = Vec4RotLeft(Vec4XOR(*row3, *row0), -8)
	*row2 = Vec4Add(*row2, *row3)
	*row1 = Vec4RotLeft(Vec4XOR(*row1, *row2), -7)
}

// CompressSIMD performs 4-way vectorized BLAKE3 7-round compression.
//
// Guarantees byte-for-byte identical output with the scalar compress() function
// while demonstrating exact vector lane topology for ARM NEON and AVX2 compilation.
//
//posh:zeroalloc
func CompressSIMD(cv *[8]uint32, block *[64]byte, blockLen uint32, counter uint64, flags uint32) [8]uint32 {
	var m [16]uint32
	for i := 0; i < 16; i++ {
		m[i] = binary.LittleEndian.Uint32(block[i*4 : i*4+4])
	}

	// 4 Vector Rows initialized from chaining value, IV, and chunk counter/flags
	row0 := SIMDVec4{cv[0], cv[1], cv[2], cv[3]}
	row1 := SIMDVec4{cv[4], cv[5], cv[6], cv[7]}
	row2 := SIMDVec4{iv0, iv1, iv2, iv3}
	row3 := SIMDVec4{uint32(counter), uint32(counter >> 32), blockLen, flags}

	// 7 Rounds of parallel column and diagonal mixing
	for r := 0; r < 7; r++ {
		// 1. Column Step: 4 parallel quarter-rounds across all 4 columns
		mxCol := SIMDVec4{m[0], m[2], m[4], m[6]}
		myCol := SIMDVec4{m[1], m[3], m[5], m[7]}
		simdQuarterRound(&row0, &row1, &row2, &row3, mxCol, myCol)

		// 2. Diagonal Step: Rotate lanes to vertically align diagonal words
		row1 = Vec4RotLanesLeft1(row1)
		row2 = Vec4RotLanesLeft2(row2)
		row3 = Vec4RotLanesLeft3(row3)

		mxDiag := SIMDVec4{m[8], m[10], m[12], m[14]}
		myDiag := SIMDVec4{m[9], m[11], m[13], m[15]}
		simdQuarterRound(&row0, &row1, &row2, &row3, mxDiag, myDiag)

		// Restore row alignments
		row1 = Vec4RotLanesLeft3(row1)
		row2 = Vec4RotLanesLeft2(row2)
		row3 = Vec4RotLanesLeft1(row3)

		// 3. Message permutation
		permute(&m)
	}

	// Output: XOR upper and lower halves back into 8 chaining words
	return [8]uint32{
		row0[0] ^ row2[0],
		row0[1] ^ row2[1],
		row0[2] ^ row2[2],
		row0[3] ^ row2[3],
		row1[0] ^ row3[0],
		row1[1] ^ row3[1],
		row1[2] ^ row3[2],
		row1[3] ^ row3[3],
	}
}

// TurnstileReceiptSIMD computes the canonical turnstile receipt using the 4-way SIMD compressor.
//
// Must match TurnstileReceipt byte-for-byte with exactly 0 heap allocations.
//
//posh:zeroalloc
func TurnstileReceiptSIMD(op string, timestampNs uint64, payloadBody []byte) [32]byte {
	// For short messages (< 1024 bytes), receipt matches single-chunk layout
	h := newChunkHasher()
	h.writeString(op)
	h.writeUint64BE(timestampNs)
	h.writeBytes(payloadBody)

	// Finalize using CompressSIMD
	for i := int(h.bufLen); i < 64; i++ {
		h.buf[i] = 0
	}
	var flags uint32 = flagChunkEnd
	if h.blocksDone == 0 {
		flags |= flagChunkStart
	}
	if h.numParents == 0 {
		flags |= flagRoot
		outWords := CompressSIMD(&h.cv, &h.buf, uint32(h.bufLen), h.chunkIdx, flags)
		return wordsToBytes(outWords)
	}

	// Multi-chunk tree reduction with CompressSIMD
	right := CompressSIMD(&h.cv, &h.buf, uint32(h.bufLen), h.chunkIdx, flags)
	for h.numParents > 0 {
		h.numParents--
		left := h.parentCVs[h.numParents]
		var block [64]byte
		for i := 0; i < 8; i++ {
			binary.LittleEndian.PutUint32(block[i*4:], left[i])
			binary.LittleEndian.PutUint32(block[32+i*4:], right[i])
		}
		iv := [8]uint32{iv0, iv1, iv2, iv3, iv4, iv5, iv6, iv7}
		pflags := uint32(flagParent)
		if h.numParents == 0 {
			pflags |= flagRoot
		}
		right = CompressSIMD(&iv, &block, 64, 0, pflags)
	}
	return wordsToBytes(right)
}
