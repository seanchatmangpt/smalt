# posh PGO capture

The Makefile `build` target passes `posh/default.pgo` explicitly via
`-pgo=default.pgo` (note: `-pgo=auto` does NOT apply here — it only looks
for default.pgo in the main package dir `cmd/posh/`, not the module root).
`make pgo` recaptures the profile and rebuilds; `make pgo-bench` A/Bs PGO
vs non-PGO (non-PGO leg pinned with `-pgo=off`).

## Protocol

1. `make pgo` stages the load benchmark below into
   `internal/server/pgo_load_tmp_test.go`, runs
   `go test ./internal/server -run '^$' -bench BenchmarkMembraneLoad -benchtime 3s
   -cpuprofile default.pgo.tmp`, removes the temp file, and rebuilds via
   `make build` (-pgo=default.pgo explicit; see note above).
2. The benchmark drives the REAL unix-socket membrane listener
   (`server.New(...).Listen()/Serve()`) with per-goroutine connections doing
   full length-prefixed echo round trips: 4-byte big-endian length prefix +
   JSON envelope. Hot path: `readFramePooled`, `api` JSON decode/encode,
   dispatch, `receipt.TurnstileReceipt` (BLAKE3 turnstile over
   op || timestamp || payloadBody), `writeFrameWithHdr`.
   Real collaborators, no mocks (Chicago doctrine).
3. Payload note: the committed default.pgo merges two capture passes — the
   small-envelope load bench plus a 64 KiB-payload pass so the BLAKE3
   turnstile (`receipt.compress`/`round`) carries profile weight, not just
   the syscall/kevent I/O path. Top-of-profile: runtime.kevent /
   syscall.syscall / syscallX dominate; receipt.compress + receipt.round +
   encoding/json are the representative user-space nodes.
4. `make pgo-bench` pins the non-PGO leg to `-pgo=off` so the A/B is real
   even with default.pgo present.

## Honesty note

The profile is I/O-dominated (a unix-socket echo server is mostly
syscalls), so PGO deltas are expected to be modest; `make pgo-bench`
measures rather than assumes.

<!-- BENCH-SOURCE
package server

// Temporary PGO capture benchmark (lane W-H). Staged by `make pgo` into
// internal/server at capture time and removed afterwards. Exercises the real
// UDS listener with concurrent full-frame round trips (frame write/read +
// JSON envelope + dispatch + BLAKE3 turnstile) — real collaborators, no
// mocks (Chicago doctrine).

import (
	"bufio"
	"context"
	"encoding/binary"
	"encoding/json"
	"net"
	"os"
	"path/filepath"
	"sync"
	"testing"
	"time"

	"smalt.dev/posh/internal/api"
)

func pgoDial(b *testing.B, sock string) *bufioReadConn {
	c, err := net.Dial("unix", sock)
	if err != nil {
		b.Fatalf("dial: %v", err)
	}
	return &bufioReadConn{c: c, br: bufio.NewReader(c)}
}

type bufioReadConn struct {
	c  net.Conn
	br *bufio.Reader
}

func pgoWaitSocket(b *testing.B, sock string) {
	deadline := time.Now().Add(5 * time.Second)
	for time.Now().Before(deadline) {
		if fi, err := os.Stat(sock); err == nil && fi.Mode()&os.ModeSocket != 0 {
			return
		}
		time.Sleep(2 * time.Millisecond)
	}
	b.Fatal("socket never appeared")
}

// BenchmarkMembraneLoad drives the REAL unix-socket membrane listener with
// per-goroutine connections doing full length-prefixed echo round trips.
// Hot path: readFramePooled, api decode/encode, dispatch, BLAKE3 turnstile
// receipt, writeFrameWithHdr.
func BenchmarkMembraneLoad(b *testing.B) {
	s := New(filepath.Join(b.TempDir(), "posh.bin.sock"), "", echoHandler)
	if err := s.Listen(); err != nil {
		b.Fatalf("Listen: %v", err)
	}
	go func() { _ = s.Serve(context.Background()) }()
	pgoWaitSocket(b, s.SocketPath())
	defer s.shutdown()

	req := &api.Request{ID: "pgo", Op: "echo", Params: map[string]string{"payload": "pgo-capture-0123456789-REPEAT-64KiB-pgo-capture-0123456789-REPEAT-64KiB-pgo-capture-0123456789-REPEAT-64KiB-pgo-capture-0123456789-REPEAT-64KiB-pgo-capture-0123456789-REPEAT-64KiB-pgo-capture-0123456789-REPEAT-64KiB-pgo-capture-0123456789-REPEAT-64KiB-pgo-capture-0123456789-REPEAT-64KiB-pgo-capture-0123456789-REPEAT-64KiB-pgo-capture-0123456789-REPEAT-64KiB-pgo-capture-0123456789-REPEAT-64KiB-pgo-capture-0123456789-REPEAT-64KiB-pgo-capture-0123456789-REPEAT-64KiB-pgo-capture-0123456789-REPEAT-64KiB-pgo-capture-0123456789-REPEAT-64KiB-pgo-capture-0123456789"}}
	body, err := json.Marshal(req)
	if err != nil {
		b.Fatal(err)
	}
	hdr := make([]byte, 4)
	binary.BigEndian.PutUint32(hdr, uint32(len(body)))
	frame := append(append(make([]byte, 0, 4+len(body)), hdr...), body...)

	var mu sync.Mutex
	var fcs []*bufioReadConn
	b.ResetTimer()
	b.RunParallel(func(pb *testing.PB) {
		fc := pgoDial(b, s.SocketPath())
		mu.Lock()
		fcs = append(fcs, fc)
		mu.Unlock()
		for pb.Next() {
			if _, err := fc.c.Write(frame); err != nil {
				b.Fatal(err)
			}
			var hdrBuf [4]byte
			if err := pgoReadFull(fc.br, hdrBuf[:]); err != nil {
				b.Fatal(err)
			}
			n := binary.BigEndian.Uint32(hdrBuf[:])
			respBuf := make([]byte, n)
			if err := pgoReadFull(fc.br, respBuf); err != nil {
				b.Fatal(err)
			}
		}
	})
	b.StopTimer()
	for _, fc := range fcs {
		fc.c.Close()
	}
}

func pgoReadFull(br *bufio.Reader, p []byte) error {
	n := 0
	for n < len(p) {
		m, err := br.Read(p[n:])
		n += m
		if err != nil {
			return err
		}
	}
	return nil
}
BENCH-SOURCE -->
