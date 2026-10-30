package server

import (
	"bufio"
	"bytes"
	"encoding/binary"
	"errors"
	"io"
	"testing"
)

// chunkReader feeds an underlying byte slice in tiny chunks (or 1 byte at a time)
// to simulate Slowloris byte-fragmented network streams across UDS / TCP buffers.
type chunkReader struct {
	data      []byte
	pos       int
	chunkSize int
}

func (cr *chunkReader) Read(p []byte) (n int, err error) {
	if cr.pos >= len(cr.data) {
		return 0, io.EOF
	}
	available := len(cr.data) - cr.pos
	toRead := cr.chunkSize
	if toRead <= 0 {
		toRead = 1
	}
	if toRead > available {
		toRead = available
	}
	if toRead > len(p) {
		toRead = len(p)
	}
	copy(p, cr.data[cr.pos:cr.pos+toRead])
	cr.pos += toRead
	return toRead, nil
}

// FuzzFrameParser tests both readFrame and readFramePooled against arbitrary byte streams.
// It verifies resistance against oversized frame lengths (>64 KiB and >MaxFrameBytes),
// truncated payloads, integer overflows/wrap-arounds, and garbage streams.
func FuzzFrameParser(f *testing.F) {
	// Seed with valid small frame
	var b1 bytes.Buffer
	binary.Write(&b1, binary.BigEndian, uint32(5))
	b1.WriteString("hello")
	f.Add(b1.Bytes())

	// Seed with empty stream
	f.Add([]byte{})

	// Seed with partial header (1 to 3 bytes)
	f.Add([]byte{0x00, 0x00})

	// Seed with oversized frame header (> MaxFrameBytes: 4MB + 1)
	var bOversized [4]byte
	binary.BigEndian.PutUint32(bOversized[:], MaxFrameBytes+10)
	f.Add(bOversized[:])

	// Seed with 0 frame length
	var bZero [4]byte
	binary.BigEndian.PutUint32(bZero[:], 0)
	f.Add(bZero[:])

	// Seed with MaxUint32 wrap-around length
	var bMax [4]byte
	binary.BigEndian.PutUint32(bMax[:], 0xffffffff)
	f.Add(bMax[:])

	// Seed with 64 KiB boundary (maxPooledFrameBytes)
	var bPooledBound bytes.Buffer
	binary.Write(&bPooledBound, binary.BigEndian, uint32(maxPooledFrameBytes))
	bPooledBound.Write(make([]byte, 64)) // truncated payload
	f.Add(bPooledBound.Bytes())

	f.Fuzz(func(t *testing.T, stream []byte) {
		// 1. Test standard readFrame
		br1 := bufio.NewReader(bytes.NewReader(stream))
		payload1, err1 := readFrame(br1)
		if err1 == nil {
			if len(payload1) == 0 {
				t.Fatalf("readFrame returned empty payload with nil error")
			}
			if len(payload1) > MaxFrameBytes {
				t.Fatalf("readFrame returned payload exceeding MaxFrameBytes: %d", len(payload1))
			}
		}

		// 2. Test pooled readFramePooled
		cs := &connState{
			br:   bufio.NewReader(bytes.NewReader(stream)),
			bufs: make([]netBuffersStub, 0, 2),
		}
		payload2, fb, err2 := readFramePooled(cs)
		if err2 == nil {
			if len(payload2) == 0 {
				putFrameBuf(fb)
				t.Fatalf("readFramePooled returned empty payload with nil error")
			}
			if len(payload2) > MaxFrameBytes {
				putFrameBuf(fb)
				t.Fatalf("readFramePooled returned payload exceeding MaxFrameBytes: %d", len(payload2))
			}
			// Invariant: frame lengths <= maxPooledFrameBytes must be pool-backed
			if uint32(len(payload2)) <= maxPooledFrameBytes && fb == nil {
				t.Fatalf("frame of size %d should have non-nil frameBuf", len(payload2))
			}
			// Invariant: frame lengths > maxPooledFrameBytes must bypass pool
			if uint32(len(payload2)) > maxPooledFrameBytes && fb != nil {
				t.Fatalf("frame of size %d exceeded pool threshold but returned non-nil frameBuf", len(payload2))
			}
			putFrameBuf(fb)
		} else {
			if fb != nil {
				t.Fatalf("readFramePooled returned non-nil fb on error")
			}
		}

		// Parity invariant: both parsers must agree on success/failure on identical streams
		if (err1 == nil) != (err2 == nil) {
			t.Fatalf("parser divergence: readFrame err=%v, readFramePooled err=%v", err1, err2)
		}
		if err1 == nil && !bytes.Equal(payload1, payload2) {
			t.Fatalf("payload mismatch between readFrame and readFramePooled")
		}
	})
}

// netBuffersStub allows compilation without circular type issues
type netBuffersStub = []byte

// FuzzSlowlorisChunking exercises reading framed payloads when delivered 1 byte at a time
// to ensure no buffer deadlock, out-of-bounds index, or corruption occurs under fragmented I/O.
func FuzzSlowlorisChunking(f *testing.F) {
	f.Add([]byte(`{"id":"c-1","op":"echo"}`), 1)
	f.Add([]byte(`{"id":"c-2","op":"echo","params":{"k":"v"}}`), 2)
	f.Add([]byte(`truncated`), 1)

	f.Fuzz(func(t *testing.T, payload []byte, chunkSize int) {
		if chunkSize <= 0 {
			chunkSize = 1
		}
		if chunkSize > 16 {
			chunkSize = 16
		}
		if len(payload) > 65536 {
			return
		}

		// Form a valid frame
		var frame bytes.Buffer
		binary.Write(&frame, binary.BigEndian, uint32(len(payload)))
		frame.Write(payload)

		cr := &chunkReader{data: frame.Bytes(), chunkSize: chunkSize}
		br := bufio.NewReader(cr)

		got, err := readFrame(br)
		if len(payload) == 0 {
			// Zero-length payloads are rejected by POSH framing
			if err == nil {
				t.Fatalf("expected error on 0-length payload, got nil")
			}
			return
		}

		if err != nil {
			t.Fatalf("unexpected error reading chunked valid frame: %v", err)
		}

		if !bytes.Equal(got, payload) {
			t.Fatalf("payload mismatch under slowloris chunking: got %q, want %q", got, payload)
		}
	})
}

// FuzzFrameBoundaryInjection tests arbitrary bytes injected immediately following
// a valid frame to ensure subsequent frame parsing detects corruption or clean EOF.
func FuzzFrameBoundaryInjection(f *testing.F) {
	f.Add([]byte(`{"id":"1","op":"echo"}`), []byte{0x00, 0x00, 0x00, 0x04, 't', 'e', 's', 't'})
	f.Add([]byte(`{"id":"2","op":"echo"}`), []byte{0xff, 0xff, 0xff, 0xff})
	f.Add([]byte(`{"id":"3","op":"echo"}`), []byte{})

	f.Fuzz(func(t *testing.T, frame1Payload, tailBytes []byte) {
		if len(frame1Payload) == 0 || len(frame1Payload) > 1024 {
			return
		}
		var stream bytes.Buffer
		binary.Write(&stream, binary.BigEndian, uint32(len(frame1Payload)))
		stream.Write(frame1Payload)
		stream.Write(tailBytes)

		br := bufio.NewReader(&stream)

		// First frame must succeed
		p1, err := readFrame(br)
		if err != nil {
			t.Fatalf("first frame failed: %v", err)
		}
		if !bytes.Equal(p1, frame1Payload) {
			t.Fatalf("first frame corrupted")
		}

		// Second read: either succeeds (if tail is valid frame), returns EOF (if empty),
		// or returns an error. It MUST NEVER panic or hang.
		p2, err2 := readFrame(br)
		if err2 == nil {
			if len(p2) == 0 || len(p2) > MaxFrameBytes {
				t.Fatalf("invalid second frame length admitted: %d", len(p2))
			}
		} else {
			if errors.Is(err2, io.EOF) || errors.Is(err2, io.ErrUnexpectedEOF) || err2 != nil {
				// Expected behavior on arbitrary tail
			}
		}
	})
}
