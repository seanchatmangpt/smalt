#!/usr/bin/env python3
"""Vendored pure-Python BLAKE3 (keyless hash, 32-byte output) for the gates.

Faithful transliteration of the BLAKE3 reference implementation (spec-appendix
algorithm: 1 KiB full chunks, 7-round compression with the message word
permutation, feed-forward state[i] ^= state[i+8]; state[i+8] ^= cv[i]).
Stdlib only -- hermetic by construction.

KAT-FENCED AT IMPORT (decorative-verifier tripwire): the module asserts
published BLAKE3 known-answer vectors the moment it is imported. A mismatch
raises Blake3KatError, which propagates out of the import (exit nonzero for
every consumer -- gate, court, vector generator) rather than letting a broken
hash law look healthy.

Cross-language identity: byte-identical with the repo's Smalt.Posh.Blake3
(Elixir) and posh/internal/receipt.Sum256 (Go); the shared golden vectors in
verification/chain_link_vectors.json are generated THROUGH this module and
asserted by all three languages.

Usage:
    from blake3_ref import blake3_hex
    blake3_hex(b"")  # 64-char lowercase hex
"""
import struct

OUT_LEN = 32
BLOCK_LEN = 64
CHUNK_LEN = 1024

CHUNK_START = 1 << 0
CHUNK_END = 1 << 1
PARENT = 1 << 2
ROOT = 1 << 3

IV = [
    0x6A09E667, 0xBB67AE85, 0x3C6EF372, 0xA54FF53A,
    0x510E527F, 0x9B05688C, 0x1F83D9AB, 0x5BE0CD19,
]

MSG_PERMUTATION = [2, 6, 3, 10, 7, 0, 4, 13, 1, 11, 12, 5, 9, 14, 15, 8]


class Blake3KatError(RuntimeError):
    """Import-time KAT mismatch -- the vendored hash law is broken."""


def _rotr32(x, n):
    return ((x >> n) | (x << (32 - n))) & 0xFFFFFFFF


def _g(s, a, b, c, d, mx, my):
    s[a] = (s[a] + s[b] + mx) & 0xFFFFFFFF
    s[d] = _rotr32(s[d] ^ s[a], 16)
    s[c] = (s[c] + s[d]) & 0xFFFFFFFF
    s[b] = _rotr32(s[b] ^ s[c], 12)
    s[a] = (s[a] + s[b] + my) & 0xFFFFFFFF
    s[d] = _rotr32(s[d] ^ s[a], 8)
    s[c] = (s[c] + s[d]) & 0xFFFFFFFF
    s[b] = _rotr32(s[b] ^ s[c], 7)


def _round(s, m):
    _g(s, 0, 4, 8, 12, m[0], m[1])
    _g(s, 1, 5, 9, 13, m[2], m[3])
    _g(s, 2, 6, 10, 14, m[4], m[5])
    _g(s, 3, 7, 11, 15, m[6], m[7])
    _g(s, 0, 5, 10, 15, m[8], m[9])
    _g(s, 1, 6, 11, 12, m[10], m[11])
    _g(s, 2, 7, 8, 13, m[12], m[13])
    _g(s, 3, 4, 9, 14, m[14], m[15])


def _permute(m):
    return [m[p] for p in MSG_PERMUTATION]


def _compress(cv, block_words, counter, block_len, flags):
    state = list(cv) + IV[:4] + [
        counter & 0xFFFFFFFF,
        (counter >> 32) & 0xFFFFFFFF,
        block_len,
        flags,
    ]
    m = list(block_words)
    for i in range(7):
        _round(state, m)
        if i < 6:
            m = _permute(m)
    # BLAKE3 feed-forward (NOT BLAKE2s's three-way XOR): the 8 output words
    # v[i] ^ v[i+8] serve BOTH as the new chaining value and (with the ROOT
    # flag set) as the root output words. The cv input participates via the
    # initial state only.
    for i in range(8):
        state[i] ^= state[i + 8]
    return state[:8]


def _words(block):
    return list(struct.unpack("<16I", bytes(block)))


class _Output:
    __slots__ = ("cv", "block", "counter", "block_len", "flags")

    def __init__(self, cv, block, counter, block_len, flags):
        self.cv = cv
        self.block = block
        self.counter = counter
        self.block_len = block_len
        self.flags = flags

    def chaining_value(self):
        return _compress(self.cv, _words(self.block), self.counter,
                         self.block_len, self.flags)


class _ChunkState:
    def __init__(self, key, chunk_counter, flags):
        self.cv = list(key)
        self.chunk_counter = chunk_counter
        self.block = bytearray(BLOCK_LEN)
        self.block_len = 0
        self.blocks_compressed = 0
        self.flags = flags

    def length(self):
        return BLOCK_LEN * self.blocks_compressed + self.block_len

    def update(self, data):
        data = memoryview(bytes(data))
        while data:
            if self.block_len == BLOCK_LEN:
                # Official flag law: CHUNK_START rides the FIRST block of the
                # chunk (even when flushed as an intermediate), CHUNK_END the
                # last (16th flush or finalize).
                flags = CHUNK_START if self.blocks_compressed == 0 else 0
                self.cv = _compress(self.cv, _words(self.block),
                                    self.chunk_counter, BLOCK_LEN, flags)
                self.blocks_compressed += 1
                self.block = bytearray(BLOCK_LEN)
                self.block_len = 0
            take = min(BLOCK_LEN - self.block_len, len(data))
            self.block[self.block_len:self.block_len + take] = data[:take]
            self.block_len += take
            data = data[take:]

    def output(self):
        flags = self.flags | CHUNK_END
        if self.blocks_compressed == 0:
            flags |= CHUNK_START
        return _Output(self.cv, bytes(self.block), self.chunk_counter,
                       self.block_len, flags)


def _chunk_cv(key, chunk_counter, flags, chunk):
    cs = _ChunkState(key, chunk_counter, flags)
    cs.update(chunk)
    return cs.output().chaining_value()


def _tree_cv(data, flags, first_chunk_idx):
    """Chaining value of the subtree over `data` (ROOT flag NOT applied).

    `first_chunk_idx` is the global chunk counter of data's first chunk --
    every chunk compresses with its own index (BLAKE3 chunk counter law).
    """
    data = bytes(data)
    n_chunks = (len(data) + CHUNK_LEN - 1) // CHUNK_LEN
    if n_chunks == 1:
        return _chunk_cv(IV, first_chunk_idx, flags, data)
    # Tree split (spec): left subtree takes the largest power-of-two chunk
    # count strictly smaller than n; right subtree the remainder.
    k = 1
    while 2 * k < n_chunks:
        k *= 2
    split = k * CHUNK_LEN
    left_cv = _tree_cv(data[:split], flags, first_chunk_idx)
    right_cv = _tree_cv(data[split:], flags, first_chunk_idx + k)
    block = struct.pack("<8I", *left_cv) + struct.pack("<8I", *right_cv)
    return _compress(IV, _words(block), 0, BLOCK_LEN, flags | PARENT)


def _blake3(data, flags=0):
    data = bytes(data)
    if len(data) <= CHUNK_LEN:
        cs = _ChunkState(IV, 0, flags)
        cs.update(data)
        out = cs.output()
        words = _compress(out.cv, _words(out.block), out.counter,
                          out.block_len, out.flags | ROOT)
        return struct.pack("<8I", *words)
    n_chunks = (len(data) + CHUNK_LEN - 1) // CHUNK_LEN
    k = 1
    while 2 * k < n_chunks:
        k *= 2
    split = k * CHUNK_LEN
    left_cv = _tree_cv(data[:split], flags, 0)
    right_cv = _tree_cv(data[split:], flags, k)
    block = struct.pack("<8I", *left_cv) + struct.pack("<8I", *right_cv)
    words = _compress(IV, _words(block), 0, BLOCK_LEN, flags | PARENT | ROOT)
    return struct.pack("<8I", *words)


def blake3_bytes(data):
    """32-byte BLAKE3 digest of `data`."""
    return _blake3(data)


def blake3_hex(data):
    """64-char lowercase hex BLAKE3 digest of `data`."""
    return _blake3(data).hex()


# --- Published BLAKE3 known-answer tests, asserted at import -----------------
# The empty-input digest is the published constant (BLAKE3 official
# test_vectors.json). The remaining rows were generated through the repo's
# published-vector-verified Go twin (posh/internal/receipt.Sum256) —
# cross-language agreement python == go == (published KAT for empty) fences
# the vendored law against silent drift. b4096/b4097 exercise both tree
# paths (single full chunk vs parent join).
_KAT = [
    (b"", "af1349b9f5f9a1a6a0404dea36dcc9499bcb25c9adc112b7cc9a93cae41f3262"),
    (b"\x00",
     "2d3adedff11b61f14c886e35afa036736dcd87a74d27b5c1510225d0f592e213"),
    (b"\x00\x01",
     "7b7015bb92cf0b318037702a6cdd81dee41224f734684c2c122cd6359cb1ee63"),
    (b"abcd" * 256,
     "1913be5b8328ba32db70a3f5435e3103b5816b06491a36b948f1f7d29191b177"),
    (bytes([0x5A]) * 4096,
     "db7e3b25d50971860c8e4b4ed89fa5dfa2d393f23a4aae430c32f190438dae50"),
    (bytes([0x5A]) * 4096 + bytes([0x01]),
     "68ebf20f48ebd70901488c8ee170ba6bba50b51d5fcf1d65076010ac79849a43"),
]


def _run_kat():
    for data, expected in _KAT:
        got = blake3_hex(data)
        if got != expected:
            raise Blake3KatError(
                "BLAKE3 KAT mismatch for input %r: got %s, expected %s"
                % (data, got, expected))


_run_kat()
