// Package socket implements passive inspection of kernel socket metrics,
// DNS resolution latency, TCP connection resets, and eBPF kernel observability
// for the POSH membrane egress layer.
package socket

import (
	"context"
	"crypto/tls"
	"errors"
	"net"
	"net/http/httptrace"
	"sync/atomic"
	"syscall"
	"time"
)

// SocketMetrics holds aggregate passive metrics for outbound egress sockets.
type SocketMetrics struct {
	DNSQueriesTotal       atomic.Uint64
	DNSFailuresTotal      atomic.Uint64
	DNSLatencyTotalNs     atomic.Uint64
	TCPConnectsTotal      atomic.Uint64
	TCPConnectFailTotal   atomic.Uint64
	TCPResetsTotal        atomic.Uint64 // ECONNRESET / TCP RST
	TCPRetransmitsTotal   atomic.Uint64
	TCPConnectLatencyNs   atomic.Uint64
	TLSHandshakesTotal    atomic.Uint64
	TLSHandshakeLatencyNs atomic.Uint64
}

// GlobalSocketMetrics provides process-wide aggregate metrics for egress.
var GlobalSocketMetrics = &SocketMetrics{}

// ConnectionSnapshot captures instantaneous socket health metrics.
type ConnectionSnapshot struct {
	Host             string
	Addr             string
	DNSDuration      time.Duration
	ConnectDuration  time.Duration
	TLSDuration      time.Duration
	TTFBDuration     time.Duration
	Retransmits      uint32
	RTTMicroseconds  uint32
	ResetEncountered bool
	Err              error
}

// TraceHook provides callback notifications when connection events complete.
type TraceHook func(snapshot *ConnectionSnapshot)

// NewEgressTrace creates an httptrace.ClientTrace that passively instruments
// DNS resolution, TCP handshake, TLS handshake, and socket stats.
func NewEgressTrace(ctx context.Context, m *SocketMetrics, hook TraceHook) (context.Context, *ConnectionSnapshot) {
	if m == nil {
		m = GlobalSocketMetrics
	}

	snap := &ConnectionSnapshot{}

	var (
		dnsStart time.Time
		connStart time.Time
		tlsStart time.Time
		reqStart time.Time
	)

	trace := &httptrace.ClientTrace{
		DNSStart: func(info httptrace.DNSStartInfo) {
			dnsStart = time.Now()
			snap.Host = info.Host
		},
		DNSDone: func(info httptrace.DNSDoneInfo) {
			dur := time.Since(dnsStart)
			snap.DNSDuration = dur
			m.DNSQueriesTotal.Add(1)
			m.DNSLatencyTotalNs.Add(uint64(dur.Nanoseconds()))
			if info.Err != nil {
				m.DNSFailuresTotal.Add(1)
				snap.Err = info.Err
			}
		},
		ConnectStart: func(network, addr string) {
			connStart = time.Now()
			snap.Addr = addr
		},
		ConnectDone: func(network, addr string, err error) {
			dur := time.Since(connStart)
			snap.ConnectDuration = dur
			m.TCPConnectsTotal.Add(1)
			m.TCPConnectLatencyNs.Add(uint64(dur.Nanoseconds()))
			if err != nil {
				m.TCPConnectFailTotal.Add(1)
				snap.Err = err
				if isConnectionReset(err) {
					snap.ResetEncountered = true
					m.TCPResetsTotal.Add(1)
				}
			}
		},
		TLSHandshakeStart: func() {
			tlsStart = time.Now()
		},
		TLSHandshakeDone: func(cs tls.ConnectionState, err error) {
			dur := time.Since(tlsStart)
			snap.TLSDuration = dur
			m.TLSHandshakesTotal.Add(1)
			m.TLSHandshakeLatencyNs.Add(uint64(dur.Nanoseconds()))
			if err != nil && snap.Err == nil {
				snap.Err = err
			}
		},
		WroteRequest: func(info httptrace.WroteRequestInfo) {
			reqStart = time.Now()
			if info.Err != nil && snap.Err == nil {
				snap.Err = info.Err
				if isConnectionReset(info.Err) {
					snap.ResetEncountered = true
					m.TCPResetsTotal.Add(1)
				}
			}
		},
		GotFirstResponseByte: func() {
			if !reqStart.IsZero() {
				snap.TTFBDuration = time.Since(reqStart)
			}
			if hook != nil {
				hook(snap)
			}
		},
	}

	return httptrace.WithClientTrace(ctx, trace), snap
}

// isConnectionReset inspects error trees for ECONNRESET or syscall resets.
func isConnectionReset(err error) bool {
	if err == nil {
		return false
	}
	if errors.Is(err, syscall.ECONNRESET) {
		return true
	}
	var netOpErr *net.OpError
	if errors.As(err, &netOpErr) {
		if errors.Is(netOpErr.Err, syscall.ECONNRESET) {
			return true
		}
	}
	return false
}
