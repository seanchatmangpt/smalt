// Package receipt implements the pure-Go, zero-allocation, branchless BLAKE3
// cryptographic turnstile digest (SPAF Tier 2/3 contract, CGO_ENABLED=0).
//
// Formula (working-backwards.md & design.md §5.1, v26.10.30 contract — must
// match the Elixir lane byte-for-byte):
//
//	R_turnstile = BLAKE3(op_utf8 || u64BE(timestamp_ns) || payload_body)
//
// Compiler & runtime invariants:
//   - Zero heap allocations on the hot path (verified by testing.AllocsPerRun == 0).
//   - math/bits.RotateLeft32 compiles directly to single-cycle ROR/ROL hardware
//     instructions on arm64 and amd64.
//   - Map canonicalization for <= 16 keys sorts keys in a fixed stack array
//     [16]string via branch-minimal insertion sort, avoiding reflection,
//     json.Marshal, and heap slice escapes.
package provider

import (
	"encoding/binary"
	"encoding/hex"
	"math/bits"
)

// BLAKE3 IV and domain separation flags (official specification).
const (
	iv0 = 0x6A09E667
	iv1 = 0xBB67AE85
	iv2 = 0x3C6EF372
	iv3 = 0xA54FF53A
	iv4 = 0x510E527F
	iv5 = 0x9B05688C
	iv6 = 0x1F83D9AB
	iv7 = 0x5BE0CD19

	flagChunkStart = 1 << 0
	flagChunkEnd   = 1 << 1
	flagParent     = 1 << 2
	flagRoot       = 1 << 3
)

// g performs one BLAKE3 quarter-round on state words a, b, c, d with message
// words mx, my. Inlined by the Go compiler; bits.RotateLeft32 lowers to ROR.
func g(s *[16]uint32, a, b, c, d int, mx, my uint32) {
	s[a] = s[a] + s[b] + mx
	s[d] = bits.RotateLeft32(s[d]^s[a], -16)
	s[c] = s[c] + s[d]
	s[b] = bits.RotateLeft32(s[b]^s[c], -12)
	s[a] = s[a] + s[b] + my
	s[d] = bits.RotateLeft32(s[d]^s[a], -8)
	s[c] = s[c] + s[d]
	s[b] = bits.RotateLeft32(s[b]^s[c], -7)
}

// round executes one full BLAKE3 mixing round (column step + diagonal step).
func round(s *[16]uint32, m *[16]uint32) {
	// Columns
	g(s, 0, 4, 8, 12, m[0], m[1])
	g(s, 1, 5, 9, 13, m[2], m[3])
	g(s, 2, 6, 10, 14, m[4], m[5])
	g(s, 3, 7, 11, 15, m[6], m[7])
	// Diagonals
	g(s, 0, 5, 10, 15, m[8], m[9])
	g(s, 1, 6, 11, 12, m[10], m[11])
	g(s, 2, 7, 8, 13, m[12], m[13])
	g(s, 3, 4, 9, 14, m[14], m[15])
}

// permute applies the fixed BLAKE3 message-word permutation in place on stack.
func permute(m *[16]uint32) {
	*m = [16]uint32{
		m[2], m[6], m[3], m[10], m[7], m[0], m[4], m[13],
		m[1], m[11], m[12], m[5], m[9], m[14], m[15], m[8],
	}
}

// compress runs the 7-round branchless BLAKE3 compression function on a 64-byte
// block (decoded into 16 little-endian uint32 words).
func compress(cv *[8]uint32, block *[64]byte, blockLen uint32, counter uint64, flags uint32) [8]uint32 {
	var m [16]uint32
	for i := 0; i < 16; i++ {
		m[i] = binary.LittleEndian.Uint32(block[i*4 : i*4+4])
	}
	s := [16]uint32{
		cv[0], cv[1], cv[2], cv[3],
		cv[4], cv[5], cv[6], cv[7],
		iv0, iv1, iv2, iv3,
		uint32(counter), uint32(counter >> 32), blockLen, flags,
	}

	round(&s, &m)
	permute(&m)
	round(&s, &m)
	permute(&m)
	round(&s, &m)
	permute(&m)
	round(&s, &m)
	permute(&m)
	round(&s, &m)
	permute(&m)
	round(&s, &m)
	permute(&m)
	round(&s, &m)

	return [8]uint32{
		s[0] ^ s[8],
		s[1] ^ s[9],
		s[2] ^ s[10],
		s[3] ^ s[11],
		s[4] ^ s[12],
		s[5] ^ s[13],
		s[6] ^ s[14],
		s[7] ^ s[15],
	}
}

// chunkHasher is a stack-allocatable single-chunk (<= 1024 byte) or streaming
// BLAKE3 hasher.
type chunkHasher struct {
	cv         [8]uint32
	buf        [64]byte
	bufLen     uint8
	blocksDone uint8
	chunkIdx   uint64
	parentCVs  [16][8]uint32
	numParents uint8
}

func newChunkHasher() chunkHasher {
	return chunkHasher{
		cv: [8]uint32{iv0, iv1, iv2, iv3, iv4, iv5, iv6, iv7},
	}
}

func (h *chunkHasher) writeByte(b byte) {
	var one [1]byte
	one[0] = b
	h.writeBytes(one[:])
}

func (h *chunkHasher) writeUint32LE(v uint32) {
	var b [4]byte
	binary.LittleEndian.PutUint32(b[:], v)
	h.writeBytes(b[:])
}

func (h *chunkHasher) writeUint64BE(v uint64) {
	var b [8]byte
	binary.BigEndian.PutUint64(b[:], v)
	h.writeBytes(b[:])
}

func (h *chunkHasher) writeString(s string) {
	for len(s) > 0 {
		if h.bufLen == 64 {
			h.flushFullBlock()
		}
		space := int(64 - h.bufLen)
		n := len(s)
		if n > space {
			n = space
		}
		copy(h.buf[h.bufLen:], s[:n])
		h.bufLen += uint8(n)
		s = s[n:]
	}
}

func (h *chunkHasher) writeBytes(p []byte) {
	for len(p) > 0 {
		if h.bufLen == 64 {
			h.flushFullBlock()
		}
		space := int(64 - h.bufLen)
		n := len(p)
		if n > space {
			n = space
		}
		copy(h.buf[h.bufLen:], p[:n])
		h.bufLen += uint8(n)
		p = p[n:]
	}
}

func (h *chunkHasher) flushFullBlock() {
	var flags uint32
	if h.blocksDone == 0 {
		flags |= flagChunkStart
	}
	if h.blocksDone == 15 {
		flags |= flagChunkEnd
		chunkCV := compress(&h.cv, &h.buf, 64, h.chunkIdx, flags)
		h.pushChunkCV(chunkCV, h.chunkIdx+1)
		h.cv = [8]uint32{iv0, iv1, iv2, iv3, iv4, iv5, iv6, iv7}
		h.blocksDone = 0
		h.bufLen = 0
		h.chunkIdx++
		return
	}
	h.cv = compress(&h.cv, &h.buf, 64, h.chunkIdx, flags)
	h.blocksDone++
	h.bufLen = 0
}

func (h *chunkHasher) pushChunkCV(newCV [8]uint32, totalChunks uint64) {
	for totalChunks&1 == 0 && h.numParents > 0 {
		h.numParents--
		left := h.parentCVs[h.numParents]
		var block [64]byte
		for i := 0; i < 8; i++ {
			binary.LittleEndian.PutUint32(block[i*4:], left[i])
			binary.LittleEndian.PutUint32(block[32+i*4:], newCV[i])
		}
		iv := [8]uint32{iv0, iv1, iv2, iv3, iv4, iv5, iv6, iv7}
		newCV = compress(&iv, &block, 64, 0, flagParent)
		totalChunks >>= 1
	}
	// SHIM-COURT-audited hard bound: 16 buffered parent CVs cap the Merkle
	// tree at 2^16 chunks = 64 MiB of input. The previous code silently
	// dropped the CV when full, corrupting the digest without any signal;
	// now we fail loudly. Sum256 returns no error, so a panic is the only
	// way to surface this — an input that large is a caller contract
	// violation, not a runtime condition.
	if int(h.numParents) == len(h.parentCVs) {
		panic("receipt: input exceeds hasher capacity (64 MiB)")
	}
	h.parentCVs[h.numParents] = newCV
	h.numParents++
}

func (h *chunkHasher) finalize() [32]byte {
	// Pad remaining bytes in final block with zeroes.
	for i := int(h.bufLen); i < 64; i++ {
		h.buf[i] = 0
	}
	var flags uint32 = flagChunkEnd
	if h.blocksDone == 0 {
		flags |= flagChunkStart
	}
	if h.numParents == 0 {
		flags |= flagRoot
		outWords := compress(&h.cv, &h.buf, uint32(h.bufLen), h.chunkIdx, flags)
		return wordsToBytes(outWords)
	}
	// Multi-chunk Merkle root reduction.
	right := compress(&h.cv, &h.buf, uint32(h.bufLen), h.chunkIdx, flags)
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
		right = compress(&iv, &block, 64, 0, pflags)
	}
	return wordsToBytes(right)
}

func wordsToBytes(w [8]uint32) [32]byte {
	var out [32]byte
	for i := 0; i < 8; i++ {
		binary.LittleEndian.PutUint32(out[i*4:], w[i])
	}
	return out
}

// Sum256 computes the 32-byte BLAKE3 digest of data with zero heap allocations.
func Sum256(data []byte) [32]byte {
	h := newChunkHasher()
	h.writeBytes(data)
	return h.finalize()
}

// MerkleRoot computes the 32-byte BLAKE3 Merkle root over two 32-byte child
// digests using the BLAKE3 parent/root domain separation flags.
func MerkleRoot(left, right [32]byte) [32]byte {
	var block [64]byte
	copy(block[:32], left[:])
	copy(block[32:], right[:])
	iv := [8]uint32{iv0, iv1, iv2, iv3, iv4, iv5, iv6, iv7}
	return wordsToBytes(compress(&iv, &block, 64, 0, flagParent|flagRoot))
}

// TurnstileReceipt computes the canonical 32-byte BLAKE3 turnstile receipt:
//
//	R_turnstile = BLAKE3(op_utf8 || u64BE(timestamp_ns) || payload_body)
//
// No length prefixes, no separators — the three fields are streamed
// back-to-back so the digest matches the Elixir lane byte-for-byte
// (cross-lane contract, v26.10.30). Zero heap allocations on the hot path.
func TurnstileReceipt(op string, timestampNs uint64, payloadBody []byte) [32]byte {
	h := newChunkHasher()
	h.writeString(op)
	h.writeUint64BE(timestampNs)
	h.writeBytes(payloadBody)
	return h.finalize()
}

// Hex encodes a 32-byte receipt token into a 64-byte lowercase hexadecimal string.
func Hex(r [32]byte) string {
	var buf [64]byte
	hex.Encode(buf[:], r[:])
	return string(buf[:])
}
