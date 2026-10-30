package server

import (
	"bufio"
	"context"
	"encoding/binary"
	"encoding/json"
	"net"
	"os"
	"path/filepath"
	"testing"
	"time"

	"smalt.dev/posh/internal/api"
)

// Shared test fixtures for the server package. Every helper is
// parallel-safe: sockets live in per-test t.TempDir() directories and
// listeners are real (no mocks, Chicago doctrine).

// tempSockPath returns a unique unix socket path inside a per-test temp dir.
func tempSockPath(t *testing.T) string {
	t.Helper()
	return filepath.Join(t.TempDir(), "posh.sock")
}

// startRealListener boots a real Server over a unique temp-dir unix socket —
// real collaborator, no mocks (Chicago). Cleanup (graceful shutdown + socket
// removal) is registered via t.Cleanup; each caller gets an isolated
// listener, so tests may run t.Parallel().
func startRealListener(t *testing.T, handler Handler) *Server {
	t.Helper()
	s := New(tempSockPath(t), "", handler)
	if err := s.Listen(); err != nil {
		t.Fatalf("Listen: %v", err)
	}
	go func() { _ = s.Serve(context.Background()) }()
	waitForSocket(t, s.SocketPath())
	t.Cleanup(s.shutdown)
	return s
}

// waitForSocket polls until the socket file exists and is a real socket —
// bounded poll on a real observable, never a fixed sleep.
func waitForSocket(t *testing.T, sock string) {
	t.Helper()
	deadline := time.Now().Add(5 * time.Second)
	for time.Now().Before(deadline) {
		if fi, err := os.Stat(sock); err == nil && fi.Mode()&os.ModeSocket != 0 {
			return
		}
		time.Sleep(5 * time.Millisecond)
	}
	t.Fatalf("socket %s never appeared", sock)
}

// frameConn is a real client connection speaking membrane framing.
type frameConn struct {
	t  *testing.T
	c  net.Conn
	br *bufio.Reader
}

// dialFrame connects to the server's unix socket.
func dialFrame(t *testing.T, sock string) *frameConn {
	t.Helper()
	c, err := net.Dial("unix", sock)
	if err != nil {
		t.Fatalf("dial %s: %v", sock, err)
	}
	t.Cleanup(func() { c.Close() })
	return &frameConn{t: t, c: c, br: bufio.NewReader(c)}
}

// sendFrame writes one length-prefixed frame with the given body.
func (f *frameConn) sendFrame(body []byte) {
	f.t.Helper()
	if err := writeRawFrame(f.c, body); err != nil {
		f.t.Fatalf("write frame: %v", err)
	}
}

// sendRaw writes arbitrary bytes without framing (for framing-fault cases).
func (f *frameConn) sendRaw(b []byte) {
	f.t.Helper()
	if _, err := f.c.Write(b); err != nil {
		f.t.Fatalf("write raw: %v", err)
	}
}

// readFrame reads one framed response. ok=false means the connection was
// closed (EOF/framing error) — an observable outcome, not a test failure.
func (f *frameConn) readFrame() (payload []byte, ok bool) {
	f.t.Helper()
	fr, err := ReadFrame(f.br)
	if err != nil {
		return nil, false
	}
	return fr, true
}

// roundTrip sends one request envelope and returns the decoded response.
func (f *frameConn) roundTrip(req *api.Request) *api.Response {
	f.t.Helper()
	raw, err := json.Marshal(req)
	if err != nil {
		f.t.Fatalf("marshal request: %v", err)
	}
	f.sendFrame(raw)
	payload, ok := f.readFrame()
	if !ok {
		f.t.Fatal("connection closed before response")
	}
	resp, err := api.DecodeResponse(payload)
	if err != nil {
		f.t.Fatalf("decode response: %v (raw=%s)", err, payload)
	}
	return resp
}

// writeRawFrame writes a 4-byte big-endian length prefix followed by body.
func writeRawFrame(w interface{ Write([]byte) (int, error) }, body []byte) error {
	var hdr [4]byte
	binary.BigEndian.PutUint32(hdr[:], uint32(len(body)))
	if _, err := w.Write(hdr[:]); err != nil {
		return err
	}
	_, err := w.Write(body)
	return err
}

// echoHandler admits the "echo" op (round-trips params verbatim) and answers
// every other op with a typed UPSTREAM error.
func echoHandler(ctx context.Context, req *api.Request) *api.Response {
	if req.Op == "echo" {
		return api.NewOK(req.ID, req.Params)
	}
	return api.NewError(req.ID, api.CodeUpstream, "unknown op %q", req.Op)
}
