package chaos

import (
	"bytes"
	"crypto/sha256"
	"io"
	"net"
	"os"
	"sync"
	"testing"
	"time"
)

func TestNetem_DeterministicJitter(t *testing.T) {
	t.Parallel()

	cfg := NetemConfig{
		Latency:      10 * time.Millisecond,
		Jitter:       5 * time.Millisecond,
		Distribution: DistributionUniform,
		Seed:         1337,
	}

	c1, _ := net.Pipe()
	c2, _ := net.Pipe()

	netem1 := WrapNetem(c1, cfg)
	netem2 := WrapNetem(c2, cfg)

	for i := 0; i < 20; i++ {
		d1 := netem1.calculateDelay()
		d2 := netem2.calculateDelay()
		if d1 != d2 {
			t.Fatalf("step %d: PRNG divergence: d1=%v, d2=%v", i, d1, d2)
		}
	}
}

func TestNetem_LatencyDistributions(t *testing.T) {
	t.Parallel()

	distributions := []DistributionType{
		DistributionUniform,
		DistributionNormal,
		DistributionPareto,
	}

	for _, dist := range distributions {
		t.Run(string(dist), func(t *testing.T) {
			cfg := NetemConfig{
				Latency:      15 * time.Millisecond,
				Jitter:       5 * time.Millisecond,
				Distribution: dist,
				Seed:         42,
			}

			client, server := NewNetemPipe(cfg, NetemConfig{})
			defer client.Close()
			defer server.Close()

			msg := []byte("ping")
			start := time.Now()

			go func() {
				_, _ = client.Write(msg)
			}()

			buf := make([]byte, len(msg))
			n, err := io.ReadFull(server, buf)
			elapsed := time.Since(start)

			if err != nil {
				t.Fatalf("read failed: %v", err)
			}
			if n != len(msg) {
				t.Fatalf("read %d bytes, want %d", n, len(msg))
			}
			if elapsed < 8*time.Millisecond {
				t.Errorf("elapsed %v was less than expected lower bound", elapsed)
			}
		})
	}
}

func TestNetem_PacketLoss(t *testing.T) {
	t.Parallel()

	// 100% loss on write
	clientLossCfg := NetemConfig{
		PacketLossRate: 1.0,
		Seed:           99,
	}
	client, server := NewNetemPipe(clientLossCfg, NetemConfig{})
	defer client.Close()
	defer server.Close()

	n, err := client.Write([]byte("will-be-dropped"))
	if err != nil {
		t.Fatalf("unexpected write error on dropped packet: %v", err)
	}
	if n != len("will-be-dropped") {
		t.Errorf("expected write to report full length %d, got %d", len("will-be-dropped"), n)
	}

	server.SetReadDeadline(time.Now().Add(50 * time.Millisecond))
	buf := make([]byte, 64)
	_, readErr := server.Read(buf)
	if readErr == nil {
		t.Fatal("expected read timeout or error due to dropped packet, got success")
	}
}

func TestNetem_StallAndRecovery(t *testing.T) {
	t.Parallel()

	cfg := NetemConfig{
		StallRate:     1.0, // force stall on every I/O
		StallDuration: 30 * time.Millisecond,
		Seed:          7,
	}

	client, server := NewNetemPipe(cfg, NetemConfig{})
	defer client.Close()
	defer server.Close()

	start := time.Now()
	go func() {
		_, _ = client.Write([]byte("stall-test"))
	}()

	buf := make([]byte, 10)
	n, err := server.Read(buf)
	elapsed := time.Since(start)

	if err != nil {
		t.Fatalf("read error: %v", err)
	}
	if n != 10 {
		t.Fatalf("read %d bytes, want 10", n)
	}
	if elapsed < 25*time.Millisecond {
		t.Errorf("elapsed %v was shorter than stall duration", elapsed)
	}
}

func TestNetem_BandwidthRateLimiting(t *testing.T) {
	t.Parallel()

	// 50 KB/sec limit
	rateLimit := int64(50 * 1024)
	cfg := NetemConfig{
		RateLimitBytesPerSec: rateLimit,
		Seed:                 123,
	}

	client, server := NewNetemPipe(cfg, NetemConfig{})
	defer client.Close()
	defer server.Close()

	// Transfer 25 KB: should take ~500ms
	payload := bytes.Repeat([]byte("A"), 25*1024)

	start := time.Now()
	var wg sync.WaitGroup
	wg.Add(1)
	go func() {
		defer wg.Done()
		_, _ = client.Write(payload)
	}()

	received := make([]byte, len(payload))
	_, err := io.ReadFull(server, received)
	wg.Wait()
	elapsed := time.Since(start)

	if err != nil {
		t.Fatalf("failed reading throttled data: %v", err)
	}

	// 25 KB at 50 KB/s needs at least ~250-500ms depending on burst tokens
	if elapsed < 150*time.Millisecond {
		t.Errorf("transfer finished too fast (%v), rate limiter failed to throttle", elapsed)
	}
}

func TestNetem_Corruption(t *testing.T) {
	t.Parallel()

	cfg := NetemConfig{
		CorruptionRate: 1.0, // 100% corruption
		Seed:           42,
	}

	client, server := NewNetemPipe(cfg, NetemConfig{})
	defer client.Close()
	defer server.Close()

	orig := bytes.Repeat([]byte("K"), 128)
	origHash := sha256.Sum256(orig)

	go func() {
		_, _ = client.Write(orig)
	}()

	buf := make([]byte, 128)
	_, err := io.ReadFull(server, buf)
	if err != nil {
		t.Fatalf("read error: %v", err)
	}

	corruptHash := sha256.Sum256(buf)
	if origHash == corruptHash {
		t.Fatal("expected payload hash mismatch due to injected bit flips, but hashes match")
	}
}

func TestNetem_DeadlineExceeded(t *testing.T) {
	t.Parallel()

	cfg := NetemConfig{
		Latency: 100 * time.Millisecond,
		Seed:    1,
	}

	client, server := NewNetemPipe(cfg, NetemConfig{})
	defer client.Close()
	defer server.Close()

	client.SetWriteDeadline(time.Now().Add(15 * time.Millisecond))
	_, err := client.Write([]byte("timeout"))
	if err == nil {
		t.Fatal("expected write timeout error, got nil")
	}
	if !os.IsTimeout(err) {
		t.Errorf("expected timeout error, got: %v", err)
	}
}

func TestNetem_Duplication(t *testing.T) {
	t.Parallel()

	cfg := NetemConfig{
		DuplicationRate: 1.0, // 100% duplicate
		Seed:            55,
	}

	client, server := NewNetemPipe(cfg, NetemConfig{})
	defer client.Close()
	defer server.Close()

	go func() {
		_, _ = client.Write([]byte("DUP"))
	}()

	buf := make([]byte, 6)
	_, err := io.ReadFull(server, buf)
	if err != nil {
		t.Fatalf("failed to read duplicated data: %v", err)
	}

	if string(buf) != "DUPDUP" {
		t.Errorf("expected duplicated string 'DUPDUP', got %q", string(buf))
	}
}

func TestNetemListener_TCPAccept(t *testing.T) {
	t.Parallel()

	rawListener, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatalf("failed to listen on TCP: %v", err)
	}
	defer rawListener.Close()

	cfg := NetemConfig{
		Latency: 5 * time.Millisecond,
		Seed:    777,
	}
	netemListener := WrapNetemListener(rawListener, cfg)

	var wg sync.WaitGroup
	wg.Add(1)
	go func() {
		defer wg.Done()
		conn, err := netemListener.Accept()
		if err != nil {
			return
		}
		defer conn.Close()

		buf := make([]byte, 4)
		_, _ = io.ReadFull(conn, buf)
		_, _ = conn.Write([]byte("PONG"))
	}()

	conn, err := net.Dial("tcp", rawListener.Addr().String())
	if err != nil {
		t.Fatalf("failed to dial: %v", err)
	}
	defer conn.Close()

	_, _ = conn.Write([]byte("PING"))
	resp := make([]byte, 4)
	_, err = io.ReadFull(conn, resp)
	if err != nil {
		t.Fatalf("failed to read pong: %v", err)
	}

	if string(resp) != "PONG" {
		t.Errorf("got %q, want PONG", string(resp))
	}
	wg.Wait()
}

func BenchmarkNetemConnThroughput(b *testing.B) {
	cfg := NetemConfig{
		RateLimitBytesPerSec: 0, // unthrottled
		Seed:                 100,
	}
	client, server := NewNetemPipe(cfg, NetemConfig{})
	defer client.Close()
	defer server.Close()

	payload := make([]byte, 4096)
	buf := make([]byte, 4096)

	b.SetBytes(4096)
	b.ResetTimer()

	for i := 0; i < b.N; i++ {
		go func() {
			_, _ = client.Write(payload)
		}()
		_, _ = io.ReadFull(server, buf)
	}
}

func BenchmarkNetemJitter(b *testing.B) {
	c1, _ := net.Pipe()
	defer c1.Close()

	cfg := NetemConfig{
		Latency:      10 * time.Millisecond,
		Jitter:       2 * time.Millisecond,
		Distribution: DistributionNormal,
		Seed:         42,
	}
	conn := WrapNetem(c1, cfg)

	b.ResetTimer()
	for i := 0; i < b.N; i++ {
		_ = conn.calculateDelay()
	}
}
