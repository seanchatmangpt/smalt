// Package chaos provides adversarial fault injection and network emulation
// for integration testing and verification of the POSH membrane.
package chaos

import (
	"errors"
	"math"
	"math/rand"
	"net"
	"os"
	"sync"
	"time"
)

// DistributionType defines the statistical distribution for artificial network jitter.
type DistributionType string

const (
	// DistributionUniform spreads latency evenly in [Latency - Jitter, Latency + Jitter].
	DistributionUniform DistributionType = "uniform"

	// DistributionNormal (Gaussian) models typical ISP and cloud routing jitter.
	DistributionNormal DistributionType = "normal"

	// DistributionPareto models heavy-tailed WAN buffers and long-tail latency spikes.
	DistributionPareto DistributionType = "pareto"
)

// NetemConfig configures the micro-network jitter and WAN simulator.
type NetemConfig struct {
	// Latency is the baseline one-way network propagation delay.
	Latency time.Duration

	// Jitter is the maximum or standard deviation variation around Latency.
	Jitter time.Duration

	// Distribution controls the jitter probability density function.
	Distribution DistributionType

	// PacketLossRate is the probability [0.0, 1.0] of silently dropping a write or read.
	PacketLossRate float64

	// CorruptionRate is the probability [0.0, 1.0] of injecting random bit-flips.
	CorruptionRate float64

	// DuplicationRate is the probability [0.0, 1.0] of duplicating a packet on the wire.
	DuplicationRate float64

	// RateLimitBytesPerSec throttles bandwidth (token bucket); 0 means unthrottled.
	RateLimitBytesPerSec int64

	// StallRate is the probability [0.0, 1.0] of a temporary connection freeze.
	StallRate float64

	// StallDuration is the duration of an injected connection stall.
	StallDuration time.Duration

	// Seed initializes the PRNG for deterministic failure replays. 0 uses wall clock.
	Seed int64
}

// NetemStats tracks telemetry of all simulated WAN anomalies.
type NetemStats struct {
	BytesRead         int64
	BytesWritten      int64
	PacketsRead       int64
	PacketsWritten    int64
	PacketsDropped    int64
	PacketsCorrupted  int64
	PacketsDuplicated int64
	StallsTriggered   int64
	TotalJitterDelay  time.Duration
}

// NetemConn wraps a net.Conn with deterministic user-space WAN network emulation.
// It requires zero Linux root privileges or tc/netem kernel modules.
type NetemConn struct {
	net.Conn
	mu              sync.Mutex
	cfg             NetemConfig
	rng             *rand.Rand
	stats           NetemStats
	closed          chan struct{}
	closeOnce       sync.Once
	readDeadline    time.Time
	writeDeadline   time.Time
	lastTokenRefill time.Time
	tokens          float64
}

// WrapNetem wraps an existing net.Conn with the specified WAN emulation parameters.
func WrapNetem(c net.Conn, cfg NetemConfig) *NetemConn {
	seed := cfg.Seed
	if seed == 0 {
		seed = time.Now().UnixNano()
	}
	if cfg.Distribution == "" {
		cfg.Distribution = DistributionUniform
	}

	return &NetemConn{
		Conn:            c,
		cfg:             cfg,
		rng:             rand.New(rand.NewSource(seed)),
		closed:          make(chan struct{}),
		lastTokenRefill: time.Now(),
		tokens:          0,
	}
}

// Stats returns a copy of current emulation metrics.
func (c *NetemConn) Stats() NetemStats {
	c.mu.Lock()
	defer c.mu.Unlock()
	return c.stats
}

// SetDeadline sets both read and write deadlines.
func (c *NetemConn) SetDeadline(t time.Time) error {
	c.mu.Lock()
	c.readDeadline = t
	c.writeDeadline = t
	c.mu.Unlock()
	return c.Conn.SetDeadline(t)
}

// SetReadDeadline sets the read deadline.
func (c *NetemConn) SetReadDeadline(t time.Time) error {
	c.mu.Lock()
	c.readDeadline = t
	c.mu.Unlock()
	return c.Conn.SetReadDeadline(t)
}

// SetWriteDeadline sets the write deadline.
func (c *NetemConn) SetWriteDeadline(t time.Time) error {
	c.mu.Lock()
	c.writeDeadline = t
	c.mu.Unlock()
	return c.Conn.SetWriteDeadline(t)
}

// Close terminates the connection and unblocks pending emulated delays.
func (c *NetemConn) Close() error {
	c.closeOnce.Do(func() {
		close(c.closed)
	})
	return c.Conn.Close()
}

func (c *NetemConn) coinFlip(p float64) bool {
	if p <= 0.0 {
		return false
	}
	if p >= 1.0 {
		return true
	}
	return c.rng.Float64() < p
}

func (c *NetemConn) calculateDelay() time.Duration {
	if c.cfg.Latency == 0 && c.cfg.Jitter == 0 {
		return 0
	}

	base := float64(c.cfg.Latency)
	jitter := float64(c.cfg.Jitter)
	var delta float64

	switch c.cfg.Distribution {
	case DistributionNormal:
		// Box-Muller / Go standard normal distribution
		delta = c.rng.NormFloat64() * jitter
	case DistributionPareto:
		// Heavy-tailed Pareto (Lomax with alpha = 1.5)
		alpha := 1.5
		u := c.rng.Float64()
		if u >= 0.999 {
			u = 0.999
		}
		multiplier := math.Pow(1.0-u, -1.0/alpha) - 1.0
		delta = (multiplier * jitter) - jitter/2.0
	case DistributionUniform:
		fallthrough
	default:
		delta = (2.0*c.rng.Float64() - 1.0) * jitter
	}

	result := base + delta
	if result < 0 {
		result = 0
	}
	return time.Duration(result)
}

func (c *NetemConn) waitDelay(delay time.Duration, deadline time.Time) error {
	if delay <= 0 {
		return nil
	}

	if !deadline.IsZero() {
		untilDeadline := time.Until(deadline)
		if untilDeadline <= 0 {
			return os.ErrDeadlineExceeded
		}
		if delay > untilDeadline {
			timer := time.NewTimer(untilDeadline)
			defer timer.Stop()
			select {
			case <-c.closed:
				return net.ErrClosed
			case <-timer.C:
				return os.ErrDeadlineExceeded
			}
		}
	}

	timer := time.NewTimer(delay)
	defer timer.Stop()
	select {
	case <-c.closed:
		return net.ErrClosed
	case <-timer.C:
		return nil
	}
}

func (c *NetemConn) calculateThrottle(n int) time.Duration {
	if c.cfg.RateLimitBytesPerSec <= 0 {
		return 0
	}

	now := time.Now()
	elapsed := now.Sub(c.lastTokenRefill)
	c.lastTokenRefill = now

	// Replenish tokens
	c.tokens += elapsed.Seconds() * float64(c.cfg.RateLimitBytesPerSec)
	maxTokens := float64(c.cfg.RateLimitBytesPerSec) / 10.0 // allow up to 100ms burst
	if maxTokens < 512 {
		maxTokens = 512
	}
	if c.tokens > maxTokens {
		c.tokens = maxTokens
	}

	c.tokens -= float64(n)
	if c.tokens < 0 {
		deficit := -c.tokens
		sleepSec := deficit / float64(c.cfg.RateLimitBytesPerSec)
		return time.Duration(sleepSec * float64(time.Second))
	}
	return 0
}

// Read intercepts incoming bytes, applying latency, jitter, loss, and corruption.
func (c *NetemConn) Read(b []byte) (n int, err error) {
	c.mu.Lock()
	delay := c.calculateDelay()
	stall := c.coinFlip(c.cfg.StallRate)
	stallDur := c.cfg.StallDuration
	drop := c.coinFlip(c.cfg.PacketLossRate)
	corrupt := c.coinFlip(c.cfg.CorruptionRate)
	rDeadline := c.readDeadline

	if delay > 0 {
		c.stats.TotalJitterDelay += delay
	}
	if stall {
		c.stats.StallsTriggered++
	}
	if drop {
		c.stats.PacketsDropped++
	}
	c.mu.Unlock()

	// Apply latency delay
	if err := c.waitDelay(delay, rDeadline); err != nil {
		return 0, err
	}

	// Apply stall
	if stall && stallDur > 0 {
		if err := c.waitDelay(stallDur, rDeadline); err != nil {
			return 0, err
		}
	}

	// Apply packet drop (simulates dropped packet on the receiver boundary)
	if drop {
		return 0, errors.New("netem: simulated packet loss on read")
	}

	n, err = c.Conn.Read(b)
	if err != nil {
		return n, err
	}

	c.mu.Lock()
	c.stats.BytesRead += int64(n)
	c.stats.PacketsRead++

	// Apply bit corruption if triggered
	if corrupt && n > 0 {
		c.stats.PacketsCorrupted++
		byteIdx := c.rng.Intn(n)
		bitIdx := c.rng.Intn(8)
		b[byteIdx] ^= 1 << bitIdx
	}

	throttleDur := c.calculateThrottle(n)
	c.mu.Unlock()

	if throttleDur > 0 {
		if err := c.waitDelay(throttleDur, rDeadline); err != nil {
			return n, err
		}
	}

	return n, nil
}

// Write intercepts outgoing bytes, injecting latency, drops, duplication, and bandwidth throttling.
func (c *NetemConn) Write(b []byte) (n int, err error) {
	c.mu.Lock()
	delay := c.calculateDelay()
	stall := c.coinFlip(c.cfg.StallRate)
	stallDur := c.cfg.StallDuration
	drop := c.coinFlip(c.cfg.PacketLossRate)
	duplicate := c.coinFlip(c.cfg.DuplicationRate)
	corrupt := c.coinFlip(c.cfg.CorruptionRate)
	wDeadline := c.writeDeadline

	if delay > 0 {
		c.stats.TotalJitterDelay += delay
	}
	if stall {
		c.stats.StallsTriggered++
	}
	if drop {
		c.stats.PacketsDropped++
	}
	if duplicate {
		c.stats.PacketsDuplicated++
	}
	c.mu.Unlock()

	// Inject jitter delay
	if err := c.waitDelay(delay, wDeadline); err != nil {
		return 0, err
	}

	// Inject connection freeze/stall
	if stall && stallDur > 0 {
		if err := c.waitDelay(stallDur, wDeadline); err != nil {
			return 0, err
		}
	}

	// Inject silent packet drop (write succeeds from caller perspective, but dropped on wire)
	if drop {
		c.mu.Lock()
		c.stats.BytesWritten += int64(len(b))
		c.stats.PacketsWritten++
		c.mu.Unlock()
		return len(b), nil
	}

	payload := b
	if corrupt && len(b) > 0 {
		c.mu.Lock()
		c.stats.PacketsCorrupted++
		cloned := make([]byte, len(b))
		copy(cloned, b)
		byteIdx := c.rng.Intn(len(cloned))
		bitIdx := c.rng.Intn(8)
		cloned[byteIdx] ^= 1 << bitIdx
		payload = cloned
		c.mu.Unlock()
	}

	n, err = c.Conn.Write(payload)
	if err != nil {
		return n, err
	}

	// If packet duplication triggered, deliver a duplicate packet
	if duplicate && n > 0 {
		_, _ = c.Conn.Write(payload)
	}

	c.mu.Lock()
	c.stats.BytesWritten += int64(n)
	c.stats.PacketsWritten++
	throttleDur := c.calculateThrottle(n)
	c.mu.Unlock()

	if throttleDur > 0 {
		if err := c.waitDelay(throttleDur, wDeadline); err != nil {
			return n, err
		}
	}

	return n, nil
}

// NetemListener wraps a net.Listener to accept connections that automatically
// have micro-network emulation and WAN constraints attached.
type NetemListener struct {
	net.Listener
	cfg NetemConfig
}

// WrapNetemListener wraps an active listener with WAN emulation.
func WrapNetemListener(l net.Listener, cfg NetemConfig) *NetemListener {
	return &NetemListener{
		Listener: l,
		cfg:      cfg,
	}
}

// Accept awaits incoming connections and wraps them in a NetemConn.
func (l *NetemListener) Accept() (net.Conn, error) {
	conn, err := l.Listener.Accept()
	if err != nil {
		return nil, err
	}
	return WrapNetem(conn, l.cfg), nil
}

// NewNetemPipe creates an in-memory duplex pair of net.Conn connections (like net.Pipe),
// each wrapped with independent asymmetric WAN emulation profiles.
//
// Ideal for zero-socket, rootless, in-process chaos testing.
func NewNetemPipe(clientCfg, serverCfg NetemConfig) (client net.Conn, server net.Conn) {
	c1, c2 := net.Pipe()
	return WrapNetem(c1, clientCfg), WrapNetem(c2, serverCfg)
}
