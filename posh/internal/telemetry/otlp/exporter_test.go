package otlp

import (
	"context"
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync"
	"sync/atomic"
	"testing"
	"time"

	"smalt.dev/posh/internal/telemetry/fastmetrics"
	"smalt.dev/posh/internal/telemetry/tracing"
)

func makeTestSpan(name string) *tracing.Span {
	s := tracing.StartSpan(name, nil)
	s.SetAttribute("test.key", "test.val")
	s.SetAttribute("smalt.actor.pid", "<0.123.0>")
	s.CorrelateTurnstileReceipt("abcd1234deadbeef", 1000000, true)
	s.End()
	return s
}

func TestRingBuffer_OverflowProtection(t *testing.T) {
	capacity := 10
	rb := NewRingBuffer(capacity)

	// Fill buffer completely
	for i := 0; i < capacity; i++ {
		s := makeTestSpan("span")
		if !rb.Push(s) {
			t.Fatalf("Expected span %d to be enqueued successfully", i)
		}
	}

	if rb.Len() != capacity {
		t.Fatalf("Expected Len() == %d, got %d", capacity, rb.Len())
	}
	if rb.Dropped() != 0 {
		t.Fatalf("Expected Dropped() == 0, got %d", rb.Dropped())
	}

	// Next pushes MUST drop without blocking
	overflowCount := 5
	for i := 0; i < overflowCount; i++ {
		s := makeTestSpan("overflow")
		enqueued := rb.Push(s)
		if enqueued {
			t.Fatalf("Expected span %d to be dropped on full buffer", i)
		}
	}

	if rb.Dropped() != uint64(overflowCount) {
		t.Fatalf("Expected Dropped() == %d, got %d", overflowCount, rb.Dropped())
	}

	// Drain half
	batch := make([]*tracing.Span, 0, 5)
	batch = rb.Drain(batch, 5)
	if len(batch) != 5 {
		t.Fatalf("Expected 5 spans drained, got %d", len(batch))
	}
	if rb.Len() != 5 {
		t.Fatalf("Expected remaining 5 spans in buffer, got %d", rb.Len())
	}

	// Now can push again
	if !rb.Push(makeTestSpan("new")) {
		t.Fatalf("Expected push to succeed after drain")
	}
}

func TestSpanSerialization_ProtobufAndJSON(t *testing.T) {
	s1 := makeTestSpan("membrane.handleEcho")
	s2 := makeTestSpan("membrane.handleARM")
	s2.Status = tracing.SpanStatus{Code: "ERROR", Description: "downstream timeout"}
	spans := []*tracing.Span{s1, s2}

	// 1. Protobuf
	protoBuf := make([]byte, 0, 4096)
	protoBuf = AppendTraceSpansProtobuf(protoBuf, spans, "posh-test", "smalt.dev/posh", "v26.10.30")
	if len(protoBuf) == 0 {
		t.Fatalf("Protobuf output is empty")
	}

	// Verify it contains field 1 (ResourceSpans) tag
	if protoBuf[0]>>3 != 1 {
		t.Fatalf("Expected root protobuf field 1, got tag byte 0x%x", protoBuf[0])
	}

	// 2. JSON
	jsonBuf := make([]byte, 0, 4096)
	jsonBuf = AppendTraceSpansJSON(jsonBuf, spans, "posh-test", "smalt.dev/posh", "v26.10.30")
	jsonStr := string(jsonBuf)

	if !strings.Contains(jsonStr, `"resourceSpans"`) {
		t.Fatalf("Expected JSON to contain resourceSpans, got:\n%s", jsonStr)
	}
	if !strings.Contains(jsonStr, `"name":"membrane.handleEcho"`) {
		t.Fatalf("Expected JSON to contain s1 name, got:\n%s", jsonStr)
	}
	if !strings.Contains(jsonStr, `"smalt.actor.pid"`) {
		t.Fatalf("Expected JSON to contain actor PID attribute, got:\n%s", jsonStr)
	}
	if !strings.Contains(jsonStr, `"turnstile_admission"`) {
		t.Fatalf("Expected JSON to contain turnstile event, got:\n%s", jsonStr)
	}
}

func TestMetricsSerialization_ProtobufAndJSON(t *testing.T) {
	v := fastmetrics.NewVector("posh_requests_total", "Total requests")
	s1 := v.RegisterSeries(fastmetrics.Label{Key: "code", Value: "OK"}, fastmetrics.Label{Key: "op", Value: "echo"})
	s2 := v.RegisterSeries(fastmetrics.Label{Key: "code", Value: "ERROR"}, fastmetrics.Label{Key: "op", Value: "arm"})
	s1.Add(42)
	s2.Add(7)

	vectors := []*fastmetrics.Vector{v}

	// 1. Protobuf
	protoBuf := make([]byte, 0, 4096)
	protoBuf = AppendMetricsProtobuf(protoBuf, vectors, "posh-test", "smalt.dev/posh", "v26.10.30")
	if len(protoBuf) == 0 {
		t.Fatalf("Protobuf metrics output is empty")
	}

	// 2. JSON
	jsonBuf := make([]byte, 0, 4096)
	jsonBuf = AppendMetricsJSON(jsonBuf, vectors, "posh-test", "smalt.dev/posh", "v26.10.30")
	jsonStr := string(jsonBuf)

	if !strings.Contains(jsonStr, `"resourceMetrics"`) {
		t.Fatalf("Expected JSON to contain resourceMetrics, got:\n%s", jsonStr)
	}
	if !strings.Contains(jsonStr, `"name":"posh_requests_total"`) {
		t.Fatalf("Expected JSON to contain metric name, got:\n%s", jsonStr)
	}
	if !strings.Contains(jsonStr, `"asInt":"42"`) {
		t.Fatalf("Expected JSON to contain series value 42, got:\n%s", jsonStr)
	}
}

func TestExporter_BackgroundFlushWithMockSender(t *testing.T) {
	var sentPayloads [][]byte
	var mu sync.Mutex

	sender := func(ctx context.Context, endpoint string, contentType string, payload []byte) error {
		mu.Lock()
		defer mu.Unlock()
		cp := make([]byte, len(payload))
		copy(cp, payload)
		sentPayloads = append(sentPayloads, cp)
		return nil
	}

	opts := ExporterOptions{
		EndpointTraces:  "http://mock:4318/v1/traces",
		EndpointMetrics: "http://mock:4318/v1/metrics",
		ServiceName:     "posh",
		Format:          FormatJSON,
		BufferSize:      100,
		BatchSize:       2, // Flush every 2 spans
		FlushInterval:   50 * time.Millisecond,
		Sender:          sender,
	}

	exp := NewExporter(opts)
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()

	if err := exp.Start(ctx); err != nil {
		t.Fatalf("Start failed: %v", err)
	}

	// Push 4 spans
	for i := 0; i < 4; i++ {
		exp.RecordSpan(makeTestSpan("req"))
	}

	// Wait for background worker to flush
	time.Sleep(150 * time.Millisecond)

	mu.Lock()
	payloadCount := len(sentPayloads)
	mu.Unlock()

	if payloadCount == 0 {
		t.Fatalf("Expected at least 1 flushed payload, got 0")
	}
	if exp.FlushedSpans() != 4 {
		t.Fatalf("Expected 4 flushed spans, got %d", exp.FlushedSpans())
	}

	// Graceful shutdown
	if err := exp.Shutdown(context.Background()); err != nil {
		t.Fatalf("Shutdown failed: %v", err)
	}
}

func TestExporter_HTTPEndpointIntegration(t *testing.T) {
	var receivedTraces atomic.Uint64
	var receivedMetrics atomic.Uint64

	ts := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		body, _ := io.ReadAll(r.Body)
		if strings.HasSuffix(r.URL.Path, "/v1/traces") {
			receivedTraces.Add(1)
			if len(body) == 0 {
				t.Errorf("Empty traces body")
			}
		} else if strings.HasSuffix(r.URL.Path, "/v1/metrics") {
			receivedMetrics.Add(1)
			if len(body) == 0 {
				t.Errorf("Empty metrics body")
			}
		}
		w.WriteHeader(http.StatusOK)
	}))
	defer ts.Close()

	reg := fastmetrics.NewRegistry()
	vec := fastmetrics.NewVector("test_counter", "help")
	vec.RegisterSeries(fastmetrics.Label{Key: "env", Value: "test"}).Inc()
	reg.Register(vec)

	opts := ExporterOptions{
		EndpointTraces:  ts.URL + "/v1/traces",
		EndpointMetrics: ts.URL + "/v1/metrics",
		ServiceName:     "posh-integration",
		Format:          FormatProtobuf,
		BufferSize:      64,
		BatchSize:       4,
		FlushInterval:   50 * time.Millisecond,
		Registry:        reg,
	}

	exp := NewExporter(opts)
	if err := exp.Start(context.Background()); err != nil {
		t.Fatalf("Start failed: %v", err)
	}

	for i := 0; i < 4; i++ {
		exp.RecordSpan(makeTestSpan("test"))
	}

	// Flush metrics manually as well
	if err := exp.FlushMetrics(context.Background(), vec); err != nil {
		t.Fatalf("FlushMetrics failed: %v", err)
	}

	// Force synchronous flush of spans
	if err := exp.Flush(context.Background()); err != nil {
		t.Fatalf("Flush failed: %v", err)
	}

	if err := exp.Shutdown(context.Background()); err != nil {
		t.Fatalf("Shutdown failed: %v", err)
	}

	if receivedTraces.Load() == 0 {
		t.Fatalf("Expected HTTP server to receive trace payloads")
	}
	if receivedMetrics.Load() == 0 {
		t.Fatalf("Expected HTTP server to receive metric payloads")
	}
}

func TestExporter_ConcurrentWorkersNoRaces(t *testing.T) {
	sender := func(ctx context.Context, endpoint string, contentType string, payload []byte) error {
		return nil
	}

	opts := ExporterOptions{
		EndpointTraces: "http://mock:4318/v1/traces",
		Format:         FormatProtobuf,
		BufferSize:     500,
		BatchSize:      50,
		FlushInterval:  20 * time.Millisecond,
		Sender:         sender,
	}

	exp := NewExporter(opts)
	if err := exp.Start(context.Background()); err != nil {
		t.Fatalf("Start failed: %v", err)
	}

	workers := 8
	iterations := 500
	var wg sync.WaitGroup

	for w := 0; w < workers; w++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			for i := 0; i < iterations; i++ {
				_ = exp.RecordSpan(makeTestSpan("worker_span"))
			}
		}()
	}

	wg.Wait()
	_ = exp.Shutdown(context.Background())
}

func BenchmarkAppendTraceSpansProtobuf(b *testing.B) {
	spans := make([]*tracing.Span, 10)
	for i := 0; i < 10; i++ {
		spans[i] = makeTestSpan("benchSpan")
	}

	buf := make([]byte, 0, 32768)
	b.ResetTimer()
	b.ReportAllocs()

	for i := 0; i < b.N; i++ {
		buf = buf[:0]
		buf = AppendTraceSpansProtobuf(buf, spans, "posh", "smalt.dev/posh", "v26.10.30")
	}
}

func BenchmarkAppendTraceSpansJSON(b *testing.B) {
	spans := make([]*tracing.Span, 10)
	for i := 0; i < 10; i++ {
		spans[i] = makeTestSpan("benchSpan")
	}

	buf := make([]byte, 0, 32768)
	b.ResetTimer()
	b.ReportAllocs()

	for i := 0; i < b.N; i++ {
		buf = buf[:0]
		buf = AppendTraceSpansJSON(buf, spans, "posh", "smalt.dev/posh", "v26.10.30")
	}
}
