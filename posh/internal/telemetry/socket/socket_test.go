package socket

import (
	"context"
	"fmt"
	"net"
	"net/http"
	"net/http/httptest"
	"syscall"
	"testing"
)

func TestEgressTrace_LoopbackHTTP(t *testing.T) {
	ts := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusOK)
		_, _ = w.Write([]byte("pong"))
	}))
	defer ts.Close()

	metrics := &SocketMetrics{}
	ctx, snap := NewEgressTrace(context.Background(), metrics, nil)

	req, err := http.NewRequestWithContext(ctx, http.MethodGet, ts.URL, nil)
	if err != nil {
		t.Fatalf("NewRequest: %v", err)
	}

	client := ts.Client()
	resp, err := client.Do(req)
	if err != nil {
		t.Fatalf("client.Do failed: %v", err)
	}
	defer resp.Body.Close()

	if metrics.TCPConnectsTotal.Load() == 0 {
		t.Errorf("expected at least 1 TCP connect recorded, got 0")
	}
	if snap.ConnectDuration == 0 {
		t.Errorf("expected non-zero ConnectDuration")
	}
	if snap.TTFBDuration == 0 {
		t.Errorf("expected non-zero TTFBDuration")
	}
}

func TestIsConnectionReset(t *testing.T) {
	if !isConnectionReset(syscall.ECONNRESET) {
		t.Errorf("expected ECONNRESET to be recognized")
	}

	wrapped := fmt.Errorf("transport failure: %w", syscall.ECONNRESET)
	if !isConnectionReset(wrapped) {
		t.Errorf("expected wrapped ECONNRESET to be recognized")
	}

	netOpErr := &net.OpError{
		Op:  "read",
		Net: "tcp",
		Err: syscall.ECONNRESET,
	}
	if !isConnectionReset(netOpErr) {
		t.Errorf("expected net.OpError with ECONNRESET to be recognized")
	}

	if isConnectionReset(syscall.EPIPE) {
		t.Errorf("EPIPE should not be considered ECONNRESET")
	}
	if isConnectionReset(nil) {
		t.Errorf("nil error should not be connection reset")
	}
}

func TestInspectTCPInfo_Loopback(t *testing.T) {
	ln, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatalf("Listen: %v", err)
	}
	defer ln.Close()

	acceptCh := make(chan net.Conn, 1)
	go func() {
		c, _ := ln.Accept()
		acceptCh <- c
	}()

	clientConn, err := net.Dial("tcp", ln.Addr().String())
	if err != nil {
		t.Fatalf("Dial: %v", err)
	}
	defer clientConn.Close()

	serverConn := <-acceptCh
	defer serverConn.Close()

	// Inspect socket metrics
	_, _, err = InspectTCPInfo(clientConn)
	if err != nil {
		t.Logf("InspectTCPInfo (client): %v (may vary depending on OS sandbox permissions)", err)
	}
}

func TestEBPFSpecs(t *testing.T) {
	strat := DetectStrategy()
	if strat.Driver != "getsockopt-fallback" {
		t.Errorf("unexpected fallback driver: %s", strat.Driver)
	}
	if RetransmitProbeSpec.Name == "" || ResetProbeSpec.Name == "" {
		t.Errorf("eBPF probe specs must have non-empty names")
	}
}
