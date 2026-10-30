// Package server implements the POSH membrane listener: unix socket at
// posh/run/posh.sock plus optional TCP, length-prefixed JSON framing,
// /healthz over the local listener, and graceful SIGTERM shutdown.
package server

import (
	"bufio"
	"context"
	"encoding/binary"
	"encoding/json"
	"fmt"
	"io"
	"log/slog"
	"net"
	"net/http"
	"os"
	"os/signal"
	"path/filepath"
	"strconv"
	"strings"
	"sync"
	"syscall"
	"time"

	"smalt.dev/posh/internal/api"
	"smalt.dev/posh/internal/logging"
	"smalt.dev/posh/internal/receipt"
)

// MaxFrameBytes bounds a single framed message (POSH-008 bounded buffers).
const MaxFrameBytes = 4 << 20

// maxPooledFrameBytes caps the maximum slice capacity returned to framePool
// (64 KiB) so anomalous multi-megabyte burst frames are reclaimed by GC
// instead of permanently pinning pool memory across P's.
const maxPooledFrameBytes = 64 << 10

// frameBuf wraps a reusable byte slice in a pointer struct so sync.Pool.Put
// stores a pointer directly in its interface slot without a 24-byte heap
// allocation (runtime.convTslice).
type frameBuf struct {
	b []byte
}

// connState holds per-UDS-connection framing scratch allocated once at
// connection accept time so per-frame reads and writes do not allocate
// 4-byte length header buffers on the heap. bufs is the scatter-gather write
// vector: net.Buffers.WriteTo CONSUMES the slice, so it is rebuilt in place
// per frame via append on the retained capacity (zero slice allocations).
type connState struct {
	hdr  [4]byte
	br   *bufio.Reader
	bufs net.Buffers
}

var framePool = sync.Pool{
	New: func() any {
		return &frameBuf{b: make([]byte, 4096)}
	},
}

func getFrameBuf(n uint32) ([]byte, *frameBuf) {
	if n <= maxPooledFrameBytes {
		fb := framePool.Get().(*frameBuf)
		if uint32(cap(fb.b)) >= n {
			fb.b = fb.b[:n]
			return fb.b, fb
		}
		buf := make([]byte, n)
		fb.b = buf
		return buf, fb
	}
	return make([]byte, n), nil
}

func putFrameBuf(fb *frameBuf) {
	if fb != nil && cap(fb.b) <= maxPooledFrameBytes {
		framePool.Put(fb)
	}
}

// Handler processes one decoded request into one response. The echo op is
// the first admitted op; egress-admitting ops arrive via later tickets.
type Handler func(ctx context.Context, req *api.Request) *api.Response

// Server owns the membrane listeners and their lifecycle.
type Server struct {
	sockPath string
	tcpAddr  string
	handler  Handler
	mux      *http.ServeMux

	lnUds net.Listener
	lnTcp net.Listener

	srvTcp *http.Server

	logger *slog.Logger

	baseCtx context.Context

	connRoot   context.Context    // root for per-connection contexts
	connCancel context.CancelFunc // fires when the drain window expires

	wg sync.WaitGroup // in-flight connection goroutines (drain set)

	mu     sync.Mutex
	closed bool
}

// New builds a Server binding sockPath (unix) and tcpAddr (optional, "" to
// disable TCP).
func New(sockPath, tcpAddr string, handler Handler) *Server {
	mux := http.NewServeMux()
	s := &Server{sockPath: sockPath, tcpAddr: tcpAddr, handler: handler, mux: mux, logger: logging.From()}
	mux.HandleFunc("/healthz", func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		w.WriteHeader(http.StatusOK)
		fmt.Fprint(w, `{"status":"ok"}`)
	})
	mux.HandleFunc("/", s.handleHTTPEnvelope)
	return s
}

// WithLogger attaches a slog logger used for request lifecycle logs.
// It must be called before Listen.
func (s *Server) WithLogger(l *slog.Logger) *Server {
	if l != nil {
		s.logger = l
	}
	return s
}

// Listen binds the unix socket (and TCP if configured). The socket directory
// is created and any stale socket file removed.
func (s *Server) Listen() error {
	if err := os.MkdirAll(filepath.Dir(s.sockPath), 0o755); err != nil {
		return fmt.Errorf("create socket dir: %w", err)
	}
	if _, err := os.Stat(s.sockPath); err == nil {
		// Stale socket from a previous run: only remove if nothing is listening.
		if c, err := net.Dial("unix", s.sockPath); err == nil {
			c.Close()
			return fmt.Errorf("socket %s already served by a live process", s.sockPath)
		}
		os.Remove(s.sockPath)
	}
	ln, err := net.Listen("unix", s.sockPath)
	if err != nil {
		return fmt.Errorf("listen unix %s: %w", s.sockPath, err)
	}
	s.lnUds = ln

	if s.tcpAddr != "" {
		tl, err := net.Listen("tcp", s.tcpAddr)
		if err != nil {
			ln.Close()
			return fmt.Errorf("listen tcp %s: %w", s.tcpAddr, err)
		}
		s.lnTcp = tl
		s.srvTcp = &http.Server{Handler: s.mux, ReadHeaderTimeout: 0}
	}
	return nil
}

// Serve runs both listeners until ctx is cancelled or SIGTERM arrives, then
// shuts down gracefully and removes the socket file.
func (s *Server) Serve(ctx context.Context) error {
	ctx, stop := signal.NotifyContext(ctx, syscall.SIGTERM, syscall.SIGINT)
	defer stop()

	s.mu.Lock()
	s.baseCtx = ctx
	s.connRoot, s.connCancel = context.WithCancel(ctx)
	connRoot := s.connRoot
	s.mu.Unlock()

	errCh := make(chan error, 2)
	go func() {
		for {
			c, err := s.lnUds.Accept()
			if err != nil {
				if s.isClosed() || isTemporary(err) {
					errCh <- nil // graceful shutdown closed the listener
					return
				}
				errCh <- fmt.Errorf("uds accept: %w", err)
				return
			}
			s.wg.Add(1)
			go func() {
				defer s.wg.Done()
				s.serveConn(connRoot, c)
			}()
		}
	}()

	var httpErrCh chan error
	if s.lnTcp != nil {
		httpErrCh = make(chan error, 1)
		go func() { httpErrCh <- s.srvTcp.Serve(s.lnTcp) }()
	}

	var runErr error
	select {
	case runErr = <-errCh:
	case runErr = <-httpErrCh:
	case <-ctx.Done():
	}
	s.shutdown()
	return runErr
}

func (s *Server) shutdown() {
	s.mu.Lock()
	if s.closed {
		s.mu.Unlock()
		return
	}
	s.closed = true
	s.mu.Unlock()
	if s.lnUds != nil {
		s.lnUds.Close()
	}
	drain := DrainTimeout()
	if s.srvTcp != nil {
		shCtx, cancel := context.WithTimeout(context.Background(), drain)
		defer cancel()
		s.srvTcp.Shutdown(shCtx)
	}
	// Await in-flight UDS connections within the same bounded drain window.
	drainDone := make(chan struct{})
	go func() {
		s.wg.Wait()
		close(drainDone)
	}()
	select {
	case <-drainDone:
	case <-time.After(drain):
		// Drain window expired: cancel remaining connection goroutines.
		s.mu.Lock()
		cancel := s.connCancel
		s.mu.Unlock()
		if cancel != nil {
			cancel()
		}
	}
	os.Remove(s.sockPath)
}

func (s *Server) isClosed() bool {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.closed
}

// SocketPath reports the bound unix socket path.
func (s *Server) SocketPath() string { return s.sockPath }

// serveConn speaks length-prefixed JSON over a raw UDS connection
// (membrane framing, v1). HTTP upgrades arrive via the TCP listener only.
func (s *Server) serveConn(ctx context.Context, c net.Conn) {
	defer c.Close()
	if err := verifyPeerCred(c); err != nil {
		return
	}
	// Unblock any pending frame read when the connection context fires
	// (drain expiry cancels it via connCancel).
	stopWatch := make(chan struct{})
	defer close(stopWatch)
	go func() {
		select {
		case <-ctx.Done():
			c.SetReadDeadline(time.Now())
		case <-stopWatch:
		}
	}()
	cs := &connState{br: bufio.NewReader(c), bufs: make(net.Buffers, 0, 2)}
	for {
		// Tie the read deadline to the connection context deadline so an
		// idle connection never outlives the drain window.
		if dl, ok := ctx.Deadline(); ok {
			c.SetReadDeadline(dl)
		} else {
			c.SetReadDeadline(time.Time{})
		}
		fr, fb, err := readFramePooled(cs)
		if err != nil {
			return // clean EOF, framed error, or drained/cancelled connection
		}
		var resp *api.Response
		var reqID string
		var reqCtx context.Context
		reqBytes := len(fr)
		start := time.Now()
		req, derr := api.DecodeRequest(fr)
		// The raw frame payload stays live through dispatch (it is the
		// turnstile payloadBody), so it is returned to the pool only after
		// dispatch returns — never while a reference is still held.
		if derr != nil {
			resp = api.NewErrorResponse("unknown", api.NewTransport("decode", derr, "bad envelope"))
		} else {
			reqID = req.ID
			reqCtx = logging.WithRequestID(ctx, req.ID)
			resp, _ = s.dispatch(reqCtx, req, fr)
		}
		putFrameBuf(fb)
		// Tie the write deadline to the request's effective deadline so a
		// stuck client cannot hold the connection goroutine forever.
		if reqCtx != nil {
			if dl, ok := reqCtx.Deadline(); ok {
				c.SetWriteDeadline(dl)
			}
		}
		if werr := writeFrameWithHdr(c, &cs.hdr, &cs.bufs, resp); werr != nil {
			return
		}
		c.SetWriteDeadline(time.Time{})
		s.logRequest(reqID, "uds", reqBytes, resp, time.Since(start))
	}
}

// dispatch applies the deadline fence, calls the handler, and stamps a 32-byte
// BLAKE3 cryptographic turnstile receipt over (op, timestampNs, payloadBody)
// on every admitted response, where payloadBody is the ORIGINAL raw request
// body (the undecoded frame payload on UDS, the undecoded HTTP body on TCP) so
// clients can verify the receipt byte-for-byte against what they sent. It
// returns the response and the receipt timestamp (unixnano) used to build it;
// HTTP callers echo the timestamp back via X-Smalt-Receipt-Timestamp so
// clients can recompute VerifyTurnstile. Request contexts derive from the
// caller's context and carry the envelope deadline via requestContext
// (context.go), so cancellation is consistent across UDS and HTTP transports.
func (s *Server) dispatch(ctx context.Context, req *api.Request, payloadBody []byte) (*api.Response, uint64) {
	ctx, cancel := requestContext(ctx, req.Deadline)
	defer cancel()
	resp := s.handler(logging.WithRequestID(ctx, req.ID), req)
	if resp == nil {
		resp = api.NewErrorResponse(req.ID, api.NewUpstream("dispatch", nil, "handler returned no response"))
	}
	resp.ID = req.ID
	tsNs := uint64(time.Now().UnixNano())
	if resp.Ok != nil && resp.Receipt == "" {
		resp.Receipt = receipt.Hex(receipt.TurnstileReceipt(req.Op, tsNs, payloadBody))
	}
	return resp, tsNs
}

// logRequest emits the request lifecycle log line at debug level. At warn+
// slog's level check short-circuits before any attribute is materialized,
// keeping per-request logging off the hot path.
func (s *Server) logRequest(id, transport string, reqBytes int, resp *api.Response, dur time.Duration) {
	if !s.logger.Enabled(context.Background(), slog.LevelDebug) {
		return
	}
	respBytes := 0
	if resp != nil {
		if b, err := api.Encode(resp); err == nil {
			respBytes = len(b)
		}
	}
	attrs := []any{
		slog.String("id", id),
		slog.String("transport", transport),
		slog.Int("req_bytes", reqBytes),
		slog.Int("resp_bytes", respBytes),
		slog.Int64("duration_ms", dur.Milliseconds()),
	}
	if resp != nil && resp.Receipt != "" {
		attrs = append(attrs, slog.String("receipt", resp.Receipt))
	}
	if resp != nil && resp.Error != nil {
		attrs = append(attrs, slog.String("error_code", string(resp.Error.Code)))
	}
	s.logger.Debug("request", attrs...)
}

// handleHTTPEnvelope accepts a JSON request envelope as the HTTP body and
// answers with the JSON response envelope (used by /healthz-style probes and
// simple HTTP clients).
func (s *Server) handleHTTPEnvelope(w http.ResponseWriter, r *http.Request) {
	body, err := io.ReadAll(io.LimitReader(r.Body, MaxFrameBytes))
	if err != nil {
		http.Error(w, "read body", http.StatusBadRequest)
		return
	}
	w.Header().Set("Content-Type", "application/json")
	req, derr := api.DecodeRequest(body)
	if derr != nil {
		w.WriteHeader(http.StatusBadRequest)
		json.NewEncoder(w).Encode(api.NewErrorResponse("unknown", api.NewTransport("decode", derr, "bad envelope")))
		return
	}
	start := time.Now()
	resp, tsNs := s.dispatch(logging.WithRequestID(r.Context(), req.ID), req, body)
	if resp.Receipt != "" {
		w.Header().Set("X-Smalt-Receipt-Turnstile", resp.Receipt)
		// Echo the receipt timestamp so clients can recompute
		// receipt.VerifyTurnstile(headerHex, op, ts, rawBody) without
		// guessing the server clock sample.
		w.Header().Set("X-Smalt-Receipt-Timestamp", strconv.FormatUint(tsNs, 10))
	}
	if resp.Error != nil && resp.Error.Code == api.CodeDeadline {
		w.WriteHeader(http.StatusGatewayTimeout)
	} else if resp.Error != nil {
		w.WriteHeader(http.StatusInternalServerError)
	} else {
		w.WriteHeader(http.StatusOK)
	}
	json.NewEncoder(w).Encode(resp)
	s.logRequest(req.ID, "http", len(body), resp, time.Since(start))
}

func readFramePooled(cs *connState) ([]byte, *frameBuf, error) {
	if _, err := io.ReadFull(cs.br, cs.hdr[:]); err != nil {
		return nil, nil, err
	}
	n := binary.BigEndian.Uint32(cs.hdr[:])
	if n == 0 || n > MaxFrameBytes {
		return nil, nil, fmt.Errorf("frame length %d out of bounds", n)
	}
	buf, fb := getFrameBuf(n)
	if _, err := io.ReadFull(cs.br, buf); err != nil {
		putFrameBuf(fb)
		return nil, nil, err
	}
	return buf, fb, nil
}

func readFrame(r *bufio.Reader) ([]byte, error) {
	var lenBuf [4]byte
	if _, err := io.ReadFull(r, lenBuf[:]); err != nil {
		return nil, err
	}
	n := binary.BigEndian.Uint32(lenBuf[:])
	if n == 0 || n > MaxFrameBytes {
		return nil, fmt.Errorf("frame length %d out of bounds", n)
	}
	buf := make([]byte, n)
	if _, err := io.ReadFull(r, buf); err != nil {
		return nil, err
	}
	return buf, nil
}

// writeFrame coalesces the 4-byte length prefix and JSON payload into a
// net.Buffers slice and invokes WriteTo(w). When w is a *net.UnixConn or
// *net.TCPConn, Go's net package dispatches through the unexported
// buffersWriter interface directly to internal/poll.FD.Writev, executing a
// single scatter-gather writev(2) syscall with zero intermediate copy
// (design.md §7.2 Starboard Out writev conduit).
func writeFrame(w io.Writer, resp *api.Response) error {
	var hdr [4]byte
	return writeFrameWithHdr(w, &hdr, &net.Buffers{}, resp)
}

func writeFrameWithHdr(w io.Writer, hdr *[4]byte, bufs *net.Buffers, resp *api.Response) error {
	body, err := api.Encode(resp)
	if err != nil {
		return err
	}
	return writeFrameBody(w, hdr, bufs, body)
}

// writeFrameBody performs the vectored write of an ALREADY-ENCODED payload:
// the 4-byte big-endian length prefix plus body go out as one scatter-gather
// writev(2) on *net.UnixConn / *net.TCPConn. The split from writeFrameWithHdr
// exists so callers that encode once and write many times — and the
// alloc-budget court — can pin the write side at its floor. bufs is REBUILT
// in place per call because net.Buffers.WriteTo consumes the slice; the
// caller reuses capacity so the rebuild is allocation-free. The one residual
// allocation per call is the writev iovec scratch inside internal/poll on
// go1.23 (cached into fd.iovecs upstream in go1.24+).
func writeFrameBody(w io.Writer, hdr *[4]byte, bufs *net.Buffers, body []byte) error {
	binary.BigEndian.PutUint32(hdr[:], uint32(len(body)))
	*bufs = append((*bufs)[:0], hdr[:], body)
	_, err := (*bufs).WriteTo(w)
	return err
}

func isTemporary(err error) bool {
	return strings.Contains(err.Error(), "use of closed network connection")
}

// WriteFrame is exported for test clients round-tripping real frames.
func WriteFrame(w io.Writer, resp *api.Response) error { return writeFrame(w, resp) }

// ReadFrame is exported for test clients reading real frames.
func ReadFrame(r *bufio.Reader) ([]byte, error) { return readFrame(r) }
