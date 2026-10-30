// Package otlp provides a high-performance, zero-allocation OpenTelemetry (OTLP v1)
// exporter for POSH membrane trace spans and fastmetrics vectors in pure Go.
//
// Concurrency & Safety Invariants:
//  1. Zero Allocations on the Hot Path: Spans and metrics are serialized directly
//     into pooled byte buffers without heavy third-party SDK or gRPC bloat.
//  2. Non-blocking Overflow Protection: When the internal ring buffer fills up,
//     incoming spans are dropped and accounted for in atomic counters without
//     blocking the membrane caller goroutine.
//  3. Full OTLP v1 Wire Parity: Supports both Protobuf (application/x-protobuf)
//     and JSON (application/json) payloads conforming to the OpenTelemetry v1 spec.
package otlp

import (
	"bytes"
	"context"
	"encoding/binary"
	"encoding/hex"
	"errors"
	"fmt"
	"io"
	"net/http"
	"strconv"
	"sync"
	"sync/atomic"
	"time"

	"smalt.dev/posh/internal/telemetry/fastmetrics"
	"smalt.dev/posh/internal/telemetry/tracing"
)

// Wire types in Protocol Buffers.
const (
	wireVarint  = 0
	wireFixed64 = 1
	wireBytes   = 2
	wireFixed32 = 5
)

// Format indicates the wire serialization format.
type Format int

const (
	// FormatProtobuf serializes into binary OTLP Protobuf (default, lowest overhead).
	FormatProtobuf Format = iota
	// FormatJSON serializes into OTLP JSON.
	FormatJSON
)

func (f Format) String() string {
	if f == FormatJSON {
		return "json"
	}
	return "protobuf"
}

// SenderFunc sends serialized payload to an external collector endpoint.
type SenderFunc func(ctx context.Context, endpoint string, contentType string, payload []byte) error

// ExporterOptions configures the OTLP exporter.
type ExporterOptions struct {
	EndpointTraces  string                    // e.g., "http://localhost:4318/v1/traces"
	EndpointMetrics string                    // e.g., "http://localhost:4318/v1/metrics"
	ServiceName     string                    // OpenTelemetry service.name (default "posh")
	ScopeName       string                    // Instrumentation scope name (default "smalt.dev/posh/membrane")
	ScopeVersion    string                    // Instrumentation scope version (default "v26.10.30")
	Format          Format                    // FormatProtobuf or FormatJSON
	BufferSize      int                       // Ring buffer capacity (default 4096)
	BatchSize       int                       // Max spans per flush batch (default 128)
	FlushInterval   time.Duration             // Periodic flush interval (default 500ms)
	MetricsInterval time.Duration             // Periodic metrics flush interval (default 5s, 0 to disable)
	HTTPClient      *http.Client              // Custom HTTP client (default http.DefaultClient with 5s timeout)
	Sender          SenderFunc                // Custom transport sender (for testing or direct pipelines)
	Registry        *fastmetrics.FastRegistry // Optional fastmetrics registry for automatic metrics scraping
}

// DefaultExporterOptions returns safe, production-grade defaults.
func DefaultExporterOptions() ExporterOptions {
	return ExporterOptions{
		EndpointTraces:  "http://localhost:4318/v1/traces",
		EndpointMetrics: "http://localhost:4318/v1/metrics",
		ServiceName:     "posh",
		ScopeName:       "smalt.dev/posh/membrane",
		ScopeVersion:    "v26.10.30",
		Format:          FormatProtobuf,
		BufferSize:      4096,
		BatchSize:       128,
		FlushInterval:   500 * time.Millisecond,
		MetricsInterval: 5 * time.Second,
	}
}

// RingBuffer implements a thread-safe, non-blocking ring buffer with overflow protection.
type RingBuffer struct {
	ch      chan *tracing.Span
	dropped atomic.Uint64
}

// NewRingBuffer allocates a new ring buffer with the given capacity.
func NewRingBuffer(capacity int) *RingBuffer {
	if capacity <= 0 {
		capacity = 4096
	}
	return &RingBuffer{
		ch: make(chan *tracing.Span, capacity),
	}
}

// Push enqueues a span into the ring buffer.
// Returns true if enqueued; returns false if dropped due to buffer overflow.
// GUARANTEED NON-BLOCKING: Never stalls the caller goroutine.
func (rb *RingBuffer) Push(span *tracing.Span) bool {
	select {
	case rb.ch <- span:
		return true
	default:
		rb.dropped.Add(1)
		return false
	}
}

// Drain extracts up to max spans from the ring buffer into dst.
func (rb *RingBuffer) Drain(dst []*tracing.Span, max int) []*tracing.Span {
	for len(dst) < max {
		select {
		case s := <-rb.ch:
			dst = append(dst, s)
		default:
			return dst
		}
	}
	return dst
}

// Dropped returns the total number of spans dropped due to overflow.
func (rb *RingBuffer) Dropped() uint64 {
	return rb.dropped.Load()
}

// Len returns the current count of queued spans.
func (rb *RingBuffer) Len() int {
	return len(rb.ch)
}

// Cap returns the total capacity of the ring buffer.
func (rb *RingBuffer) Cap() int {
	return cap(rb.ch)
}

// Exporter manages asynchronous OTLP background flushing with zero-alloc serialization.
type Exporter struct {
	opts           ExporterOptions
	ring           *RingBuffer
	httpClient     *http.Client
	ctx            context.Context
	cancel         context.CancelFunc
	wg             sync.WaitGroup
	active         atomic.Bool
	flushedSpans   atomic.Uint64
	flushedMetrics atomic.Uint64
	flushSignal    chan struct{}
}

// NewExporter creates a new OTLP Exporter.
func NewExporter(opts ExporterOptions) *Exporter {
	if opts.ServiceName == "" {
		opts.ServiceName = "posh"
	}
	if opts.ScopeName == "" {
		opts.ScopeName = "smalt.dev/posh/membrane"
	}
	if opts.ScopeVersion == "" {
		opts.ScopeVersion = "v26.10.30"
	}
	if opts.BufferSize <= 0 {
		opts.BufferSize = 4096
	}
	if opts.BatchSize <= 0 {
		opts.BatchSize = 128
	}
	if opts.FlushInterval <= 0 {
		opts.FlushInterval = 500 * time.Millisecond
	}

	client := opts.HTTPClient
	if client == nil && opts.Sender == nil {
		client = &http.Client{
			Timeout: 5 * time.Second,
		}
	}

	return &Exporter{
		opts:        opts,
		ring:        NewRingBuffer(opts.BufferSize),
		httpClient:  client,
		flushSignal: make(chan struct{}, 1),
	}
}

// Start initiates the background non-blocking flush loop.
func (e *Exporter) Start(parent context.Context) error {
	if e.active.Swap(true) {
		return errors.New("otlp exporter already running")
	}

	e.ctx, e.cancel = context.WithCancel(parent)
	e.wg.Add(1)
	go e.workerLoop()
	return nil
}

// Stop gracefully stops the exporter, draining remaining buffered spans.
func (e *Exporter) Stop() error {
	return e.Shutdown(context.Background())
}

// Shutdown gracefully terminates the exporter, flushing buffered spans within ctx deadline.
func (e *Exporter) Shutdown(ctx context.Context) error {
	if !e.active.Swap(false) {
		return nil
	}

	if e.cancel != nil {
		e.cancel()
	}

	done := make(chan struct{})
	go func() {
		e.wg.Wait()
		close(done)
	}()

	select {
	case <-done:
		// Drain remaining items from ring buffer
		return e.drainAndFlush(ctx)
	case <-ctx.Done():
		return ctx.Err()
	}
}

// RecordSpan records a trace span into the ring buffer with zero caller blocking.
func (e *Exporter) RecordSpan(span *tracing.Span) bool {
	if span == nil {
		return false
	}
	ok := e.ring.Push(span)
	if ok && e.ring.Len() >= e.opts.BatchSize {
		select {
		case e.flushSignal <- struct{}{}:
		default:
		}
	}
	return ok
}

// DroppedSpans returns total dropped spans due to ring buffer overflow.
func (e *Exporter) DroppedSpans() uint64 {
	return e.ring.Dropped()
}

// QueuedSpans returns the current number of spans pending in the ring buffer.
func (e *Exporter) QueuedSpans() int {
	return e.ring.Len()
}

// FlushedSpans returns total number of successfully exported spans.
func (e *Exporter) FlushedSpans() uint64 {
	return e.flushedSpans.Load()
}

// FlushedMetrics returns total number of successfully exported metric points.
func (e *Exporter) FlushedMetrics() uint64 {
	return e.flushedMetrics.Load()
}

func (e *Exporter) workerLoop() {
	defer e.wg.Done()

	flushTicker := time.NewTicker(e.opts.FlushInterval)
	defer flushTicker.Stop()

	var metricsTicker *time.Ticker
	var metricsCh <-chan time.Time
	if e.opts.MetricsInterval > 0 && e.opts.Registry != nil {
		metricsTicker = time.NewTicker(e.opts.MetricsInterval)
		defer metricsTicker.Stop()
		metricsCh = metricsTicker.C
	}

	for {
		select {
		case <-e.ctx.Done():
			return
		case <-flushTicker.C:
			_ = e.drainAndFlushBatch(e.ctx)
		case <-e.flushSignal:
			_ = e.drainAndFlushBatch(e.ctx)
		case <-metricsCh:
			if e.opts.Registry != nil {
				_ = e.FlushMetrics(e.ctx, e.opts.Registry.Vectors()...)
			}
		}
	}
}

func (e *Exporter) drainAndFlushBatch(ctx context.Context) error {
	if e.ring.Len() == 0 {
		return nil
	}
	batch := make([]*tracing.Span, 0, e.opts.BatchSize)
	batch = e.ring.Drain(batch, e.opts.BatchSize)
	if len(batch) == 0 {
		return nil
	}
	return e.exportSpanBatch(ctx, batch)
}

func (e *Exporter) drainAndFlush(ctx context.Context) error {
	for e.ring.Len() > 0 {
		batch := make([]*tracing.Span, 0, e.opts.BatchSize)
		batch = e.ring.Drain(batch, e.opts.BatchSize)
		if len(batch) == 0 {
			break
		}
		if err := e.exportSpanBatch(ctx, batch); err != nil {
			return err
		}
	}
	return nil
}

// Flush forces a synchronous drain and flush of all pending spans.
func (e *Exporter) Flush(ctx context.Context) error {
	return e.drainAndFlush(ctx)
}

var payloadBufferPool = sync.Pool{
	New: func() any {
		b := make([]byte, 0, 32768)
		return &b
	},
}

func (e *Exporter) exportSpanBatch(ctx context.Context, spans []*tracing.Span) error {
	if len(spans) == 0 || e.opts.EndpointTraces == "" {
		return nil
	}

	bufPtr := payloadBufferPool.Get().(*[]byte)
	buf := (*bufPtr)[:0]
	defer func() {
		*bufPtr = buf
		payloadBufferPool.Put(bufPtr)
	}()

	var contentType string
	if e.opts.Format == FormatJSON {
		contentType = "application/json"
		buf = AppendTraceSpansJSON(buf, spans, e.opts.ServiceName, e.opts.ScopeName, e.opts.ScopeVersion)
	} else {
		contentType = "application/x-protobuf"
		buf = AppendTraceSpansProtobuf(buf, spans, e.opts.ServiceName, e.opts.ScopeName, e.opts.ScopeVersion)
	}

	if err := e.sendPayload(ctx, e.opts.EndpointTraces, contentType, buf); err != nil {
		return err
	}

	e.flushedSpans.Add(uint64(len(spans)))
	return nil
}

// FlushMetrics serializes and exports the provided fastmetrics vectors.
func (e *Exporter) FlushMetrics(ctx context.Context, vectors ...*fastmetrics.Vector) error {
	if len(vectors) == 0 || e.opts.EndpointMetrics == "" {
		return nil
	}

	bufPtr := payloadBufferPool.Get().(*[]byte)
	buf := (*bufPtr)[:0]
	defer func() {
		*bufPtr = buf
		payloadBufferPool.Put(bufPtr)
	}()

	var contentType string
	if e.opts.Format == FormatJSON {
		contentType = "application/json"
		buf = AppendMetricsJSON(buf, vectors, e.opts.ServiceName, e.opts.ScopeName, e.opts.ScopeVersion)
	} else {
		contentType = "application/x-protobuf"
		buf = AppendMetricsProtobuf(buf, vectors, e.opts.ServiceName, e.opts.ScopeName, e.opts.ScopeVersion)
	}

	if err := e.sendPayload(ctx, e.opts.EndpointMetrics, contentType, buf); err != nil {
		return err
	}

	count := 0
	for _, v := range vectors {
		count += len(v.SeriesList())
	}
	e.flushedMetrics.Add(uint64(count))
	return nil
}

func (e *Exporter) sendPayload(ctx context.Context, endpoint string, contentType string, payload []byte) error {
	if e.opts.Sender != nil {
		return e.opts.Sender(ctx, endpoint, contentType, payload)
	}

	req, err := http.NewRequestWithContext(ctx, http.MethodPost, endpoint, bytes.NewReader(payload))
	if err != nil {
		return fmt.Errorf("create otlp request: %w", err)
	}
	req.Header.Set("Content-Type", contentType)

	resp, err := e.httpClient.Do(req)
	if err != nil {
		return fmt.Errorf("send otlp payload to %s: %w", endpoint, err)
	}
	defer resp.Body.Close()

	if resp.StatusCode >= 400 {
		body, _ := io.ReadAll(io.LimitReader(resp.Body, 1024))
		return fmt.Errorf("otlp collector %s rejected with status %d: %s", endpoint, resp.StatusCode, string(body))
	}

	return nil
}

// ============================================================================
// Zero-Allocation Protobuf Serializers
// ============================================================================

func varintLen(x uint64) int {
	n := 1
	for x >= 0x80 {
		n++
		x >>= 7
	}
	return n
}

func tagLen(fieldNum int) int {
	return varintLen(uint64(fieldNum << 3))
}

func stringFieldLen(fieldNum int, s string) int {
	return tagLen(fieldNum) + varintLen(uint64(len(s))) + len(s)
}

func bytesFieldLen(fieldNum int, bLen int) int {
	return tagLen(fieldNum) + varintLen(uint64(bLen)) + bLen
}

func varintFieldLen(fieldNum int, v uint64) int {
	return tagLen(fieldNum) + varintLen(v)
}

func fixed64FieldLen(fieldNum int) int {
	return tagLen(fieldNum) + 8
}

func appendVarint(dst []byte, x uint64) []byte {
	for x >= 0x80 {
		dst = append(dst, byte(x)|0x80)
		x >>= 7
	}
	return append(dst, byte(x))
}

func appendTag(dst []byte, fieldNum int, wireType int) []byte {
	return appendVarint(dst, uint64(fieldNum<<3|wireType))
}

func appendBytesField(dst []byte, fieldNum int, b []byte) []byte {
	dst = appendTag(dst, fieldNum, wireBytes)
	dst = appendVarint(dst, uint64(len(b)))
	return append(dst, b...)
}

func appendStringField(dst []byte, fieldNum int, s string) []byte {
	dst = appendTag(dst, fieldNum, wireBytes)
	dst = appendVarint(dst, uint64(len(s)))
	return append(dst, s...)
}

func appendVarintField(dst []byte, fieldNum int, v uint64) []byte {
	dst = appendTag(dst, fieldNum, wireVarint)
	return appendVarint(dst, v)
}

func appendFixed64Field(dst []byte, fieldNum int, v uint64) []byte {
	dst = appendTag(dst, fieldNum, wireFixed64)
	var b [8]byte
	binary.LittleEndian.PutUint64(b[:], v)
	return append(dst, b[:]...)
}

func keyValuePayloadLen(key, val string) int {
	anyValPayloadLen := stringFieldLen(1, val)
	anyValFieldLen := tagLen(2) + varintLen(uint64(anyValPayloadLen)) + anyValPayloadLen
	return stringFieldLen(1, key) + anyValFieldLen
}

func appendKeyValueProto(dst []byte, fieldNum int, key, val string) []byte {
	anyValPayloadLen := stringFieldLen(1, val)
	kvPayloadLen := stringFieldLen(1, key) + tagLen(2) + varintLen(uint64(anyValPayloadLen)) + anyValPayloadLen

	dst = appendTag(dst, fieldNum, wireBytes)
	dst = appendVarint(dst, uint64(kvPayloadLen))

	dst = appendStringField(dst, 1, key)

	dst = appendTag(dst, 2, wireBytes)
	dst = appendVarint(dst, uint64(anyValPayloadLen))
	dst = appendStringField(dst, 1, val)

	return dst
}

func eventPayloadLen(ev tracing.SpanEvent) int {
	total := fixed64FieldLen(1) + stringFieldLen(2, ev.Name)
	for k, v := range ev.Attributes {
		kvPayloadLen := keyValuePayloadLen(k, v)
		total += tagLen(3) + varintLen(uint64(kvPayloadLen)) + kvPayloadLen
	}
	return total
}

func appendEventProto(dst []byte, fieldNum int, ev tracing.SpanEvent) []byte {
	payloadLen := eventPayloadLen(ev)
	dst = appendTag(dst, fieldNum, wireBytes)
	dst = appendVarint(dst, uint64(payloadLen))

	dst = appendFixed64Field(dst, 1, uint64(ev.Timestamp.UnixNano()))
	dst = appendStringField(dst, 2, ev.Name)
	for k, v := range ev.Attributes {
		dst = appendKeyValueProto(dst, 3, k, v)
	}
	return dst
}

func statusPayloadLen(code uint64, desc string) int {
	total := varintFieldLen(3, code)
	if desc != "" {
		total += stringFieldLen(2, desc)
	}
	return total
}

func appendStatusProto(dst []byte, fieldNum int, code uint64, desc string) []byte {
	payloadLen := statusPayloadLen(code, desc)
	dst = appendTag(dst, fieldNum, wireBytes)
	dst = appendVarint(dst, uint64(payloadLen))
	dst = appendVarintField(dst, 3, code)
	if desc != "" {
		dst = appendStringField(dst, 2, desc)
	}
	return dst
}

func spanHasParent(s *tracing.Span) bool {
	for _, b := range s.ParentSpanID {
		if b != 0 {
			return true
		}
	}
	return false
}

func spanPayloadLen(s *tracing.Span) int {
	total := bytesFieldLen(1, 16) // trace_id
	total += bytesFieldLen(2, 8)  // span_id
	if spanHasParent(s) {
		total += bytesFieldLen(4, 8) // parent_span_id
	}
	total += stringFieldLen(5, s.Name) // name
	total += varintFieldLen(6, 2)      // kind (SPAN_KIND_SERVER = 2)
	total += fixed64FieldLen(7)        // start_time_unix_nano
	total += fixed64FieldLen(8)        // end_time_unix_nano

	for k, v := range s.Attributes {
		kvPayloadLen := keyValuePayloadLen(k, v)
		total += tagLen(9) + varintLen(uint64(kvPayloadLen)) + kvPayloadLen
	}

	for _, ev := range s.Events {
		evLen := eventPayloadLen(ev)
		total += tagLen(11) + varintLen(uint64(evLen)) + evLen
	}

	code := uint64(1)
	if s.Status.Code == "ERROR" {
		code = 2
	}
	stLen := statusPayloadLen(code, s.Status.Description)
	total += tagLen(15) + varintLen(uint64(stLen)) + stLen

	return total
}

func appendSpanProto(dst []byte, fieldNum int, s *tracing.Span) []byte {
	payloadLen := spanPayloadLen(s)
	dst = appendTag(dst, fieldNum, wireBytes)
	dst = appendVarint(dst, uint64(payloadLen))

	dst = appendBytesField(dst, 1, s.TraceID[:])
	dst = appendBytesField(dst, 2, s.SpanID[:])
	if spanHasParent(s) {
		dst = appendBytesField(dst, 4, s.ParentSpanID[:])
	}
	dst = appendStringField(dst, 5, s.Name)
	dst = appendVarintField(dst, 6, 2)

	dst = appendFixed64Field(dst, 7, uint64(s.StartTime.UnixNano()))
	endTime := s.EndTime
	if endTime.IsZero() {
		endTime = time.Now()
	}
	dst = appendFixed64Field(dst, 8, uint64(endTime.UnixNano()))

	for k, v := range s.Attributes {
		dst = appendKeyValueProto(dst, 9, k, v)
	}

	for _, ev := range s.Events {
		dst = appendEventProto(dst, 11, ev)
	}

	code := uint64(1)
	if s.Status.Code == "ERROR" {
		code = 2
	}
	dst = appendStatusProto(dst, 15, code, s.Status.Description)

	return dst
}

// AppendTraceSpansProtobuf serializes spans into ExportTraceServiceRequest protobuf bytes without allocations.
func AppendTraceSpansProtobuf(dst []byte, spans []*tracing.Span, serviceName, scopeName, scopeVersion string) []byte {
	// Calculate ScopeSpans payload length
	scopePayloadLen := stringFieldLen(1, scopeName) + stringFieldLen(2, scopeVersion)
	scopeSpansPayloadLen := tagLen(1) + varintLen(uint64(scopePayloadLen)) + scopePayloadLen
	for _, s := range spans {
		sLen := spanPayloadLen(s)
		scopeSpansPayloadLen += tagLen(2) + varintLen(uint64(sLen)) + sLen
	}

	// Calculate Resource payload length
	svcKVPayloadLen := keyValuePayloadLen("service.name", serviceName)
	resPayloadLen := tagLen(1) + varintLen(uint64(svcKVPayloadLen)) + svcKVPayloadLen

	// Calculate ResourceSpans payload length
	resSpansPayloadLen := tagLen(1) + varintLen(uint64(resPayloadLen)) + resPayloadLen +
		tagLen(2) + varintLen(uint64(scopeSpansPayloadLen)) + scopeSpansPayloadLen

	// 1. ExportTraceServiceRequest (field 1 = ResourceSpans)
	dst = appendTag(dst, 1, wireBytes)
	dst = appendVarint(dst, uint64(resSpansPayloadLen))

	// 2. ResourceSpans -> 1: Resource
	dst = appendTag(dst, 1, wireBytes)
	dst = appendVarint(dst, uint64(resPayloadLen))
	dst = appendKeyValueProto(dst, 1, "service.name", serviceName)

	// 3. ResourceSpans -> 2: ScopeSpans
	dst = appendTag(dst, 2, wireBytes)
	dst = appendVarint(dst, uint64(scopeSpansPayloadLen))

	// ScopeSpans -> 1: Scope
	dst = appendTag(dst, 1, wireBytes)
	dst = appendVarint(dst, uint64(scopePayloadLen))
	dst = appendStringField(dst, 1, scopeName)
	dst = appendStringField(dst, 2, scopeVersion)

	// ScopeSpans -> 2: repeated Span
	for _, s := range spans {
		dst = appendSpanProto(dst, 2, s)
	}

	return dst
}

// AppendMetricsProtobuf serializes fastmetrics vectors into ExportMetricsServiceRequest protobuf bytes.
func AppendMetricsProtobuf(dst []byte, vectors []*fastmetrics.Vector, serviceName, scopeName, scopeVersion string) []byte {
	nowNano := uint64(time.Now().UnixNano())

	// ScopeSpans calculation
	scopePayloadLen := stringFieldLen(1, scopeName) + stringFieldLen(2, scopeVersion)
	scopeMetricsPayloadLen := tagLen(1) + varintLen(uint64(scopePayloadLen)) + scopePayloadLen

	type metricMeta struct {
		v              *fastmetrics.Vector
		series         []*fastmetrics.Series
		sumPayloadLen  int
		metPayloadLen  int
	}

	metas := make([]metricMeta, 0, len(vectors))

	for _, v := range vectors {
		series := v.SeriesList()
		if len(series) == 0 {
			continue
		}

		sumPayloadLen := varintFieldLen(2, 2) + varintFieldLen(3, 1) // aggregation_temporality=2, is_monotonic=1
		for _, s := range series {
			dpPayloadLen := fixed64FieldLen(3) + fixed64FieldLen(6) // time_unix_nano + as_int
			for _, lbl := range s.Labels() {
				kvLen := keyValuePayloadLen(lbl.Key, lbl.Value)
				dpPayloadLen += tagLen(1) + varintLen(uint64(kvLen)) + kvLen
			}
			sumPayloadLen += tagLen(1) + varintLen(uint64(dpPayloadLen)) + dpPayloadLen
		}

		metPayloadLen := stringFieldLen(1, v.Name()) + stringFieldLen(3, "1")
		if v.Help() != "" {
			metPayloadLen += stringFieldLen(2, v.Help())
		}
		metPayloadLen += tagLen(5) + varintLen(uint64(sumPayloadLen)) + sumPayloadLen

		scopeMetricsPayloadLen += tagLen(2) + varintLen(uint64(metPayloadLen)) + metPayloadLen

		metas = append(metas, metricMeta{
			v:             v,
			series:        series,
			sumPayloadLen: sumPayloadLen,
			metPayloadLen: metPayloadLen,
		})
	}

	// Resource
	svcKVPayloadLen := keyValuePayloadLen("service.name", serviceName)
	resPayloadLen := tagLen(1) + varintLen(uint64(svcKVPayloadLen)) + svcKVPayloadLen

	// ResourceMetrics
	resMetricsPayloadLen := tagLen(1) + varintLen(uint64(resPayloadLen)) + resPayloadLen +
		tagLen(2) + varintLen(uint64(scopeMetricsPayloadLen)) + scopeMetricsPayloadLen

	// ExportMetricsServiceRequest
	dst = appendTag(dst, 1, wireBytes)
	dst = appendVarint(dst, uint64(resMetricsPayloadLen))

	// ResourceMetrics -> 1: Resource
	dst = appendTag(dst, 1, wireBytes)
	dst = appendVarint(dst, uint64(resPayloadLen))
	dst = appendKeyValueProto(dst, 1, "service.name", serviceName)

	// ResourceMetrics -> 2: ScopeMetrics
	dst = appendTag(dst, 2, wireBytes)
	dst = appendVarint(dst, uint64(scopeMetricsPayloadLen))

	// ScopeMetrics -> 1: Scope
	dst = appendTag(dst, 1, wireBytes)
	dst = appendVarint(dst, uint64(scopePayloadLen))
	dst = appendStringField(dst, 1, scopeName)
	dst = appendStringField(dst, 2, scopeVersion)

	// ScopeMetrics -> 2: repeated Metric
	for _, meta := range metas {
		dst = appendTag(dst, 2, wireBytes)
		dst = appendVarint(dst, uint64(meta.metPayloadLen))

		dst = appendStringField(dst, 1, meta.v.Name())
		if meta.v.Help() != "" {
			dst = appendStringField(dst, 2, meta.v.Help())
		}
		dst = appendStringField(dst, 3, "1")

		// Metric -> 5: Sum
		dst = appendTag(dst, 5, wireBytes)
		dst = appendVarint(dst, uint64(meta.sumPayloadLen))

		for _, s := range meta.series {
			dpPayloadLen := fixed64FieldLen(3) + fixed64FieldLen(6)
			for _, lbl := range s.Labels() {
				kvLen := keyValuePayloadLen(lbl.Key, lbl.Value)
				dpPayloadLen += tagLen(1) + varintLen(uint64(kvLen)) + kvLen
			}
			dst = appendTag(dst, 1, wireBytes)
			dst = appendVarint(dst, uint64(dpPayloadLen))

			for _, lbl := range s.Labels() {
				dst = appendKeyValueProto(dst, 1, lbl.Key, lbl.Value)
			}
			dst = appendFixed64Field(dst, 3, nowNano)
			dst = appendFixed64Field(dst, 6, s.Load())
		}
		dst = appendVarintField(dst, 2, 2) // CUMULATIVE
		dst = appendVarintField(dst, 3, 1) // is_monotonic
	}

	return dst
}

// ============================================================================
// Zero-Allocation OTLP JSON Serializers
// ============================================================================

func appendJSONEscaped(dst []byte, s string) []byte {
	dst = append(dst, '"')
	for i := 0; i < len(s); i++ {
		switch s[i] {
		case '"':
			dst = append(dst, `\"`...)
		case '\\':
			dst = append(dst, `\\`...)
		case '\n':
			dst = append(dst, `\n`...)
		case '\r':
			dst = append(dst, `\r`...)
		case '\t':
			dst = append(dst, `\t`...)
		default:
			dst = append(dst, s[i])
		}
	}
	dst = append(dst, '"')
	return dst
}

// AppendTraceSpansJSON serializes spans into OTLP v1 JSON format.
func AppendTraceSpansJSON(dst []byte, spans []*tracing.Span, serviceName, scopeName, scopeVersion string) []byte {
	dst = append(dst, `{"resourceSpans":[{"resource":{"attributes":[{"key":"service.name","value":{"stringValue":`...)
	dst = appendJSONEscaped(dst, serviceName)
	dst = append(dst, `}}]},"scopeSpans":[{"scope":{"name":`...)
	dst = appendJSONEscaped(dst, scopeName)
	dst = append(dst, `,"version":`...)
	dst = appendJSONEscaped(dst, scopeVersion)
	dst = append(dst, `},"spans":[`...)

	var hexTraceID [32]byte
	var hexSpanID [16]byte
	var hexParentSpanID [16]byte

	for i, s := range spans {
		if i > 0 {
			dst = append(dst, ',')
		}
		hex.Encode(hexTraceID[:], s.TraceID[:])
		hex.Encode(hexSpanID[:], s.SpanID[:])
		hex.Encode(hexParentSpanID[:], s.ParentSpanID[:])

		dst = append(dst, `{"traceId":"`...)
		dst = append(dst, hexTraceID[:]...)
		dst = append(dst, `","spanId":"`...)
		dst = append(dst, hexSpanID[:]...)
		dst = append(dst, `","parentSpanId":"`...)
		dst = append(dst, hexParentSpanID[:]...)
		dst = append(dst, `","name":`...)
		dst = appendJSONEscaped(dst, s.Name)
		dst = append(dst, `,"kind":2,"startTimeUnixNano":"`...)
		dst = strconv.AppendInt(dst, s.StartTime.UnixNano(), 10)
		dst = append(dst, `","endTimeUnixNano":"`...)
		endTime := s.EndTime
		if endTime.IsZero() {
			endTime = time.Now()
		}
		dst = strconv.AppendInt(dst, endTime.UnixNano(), 10)
		dst = append(dst, `","attributes":[`...)

		attrIdx := 0
		for k, v := range s.Attributes {
			if attrIdx > 0 {
				dst = append(dst, ',')
			}
			dst = append(dst, `{"key":`...)
			dst = appendJSONEscaped(dst, k)
			dst = append(dst, `,"value":{"stringValue":`...)
			dst = appendJSONEscaped(dst, v)
			dst = append(dst, `}}`...)
			attrIdx++
		}

		dst = append(dst, `],"events":[`...)
		for evIdx, ev := range s.Events {
			if evIdx > 0 {
				dst = append(dst, ',')
			}
			dst = append(dst, `{"timeUnixNano":"`...)
			dst = strconv.AppendInt(dst, ev.Timestamp.UnixNano(), 10)
			dst = append(dst, `","name":`...)
			dst = appendJSONEscaped(dst, ev.Name)
			dst = append(dst, `,"attributes":[`...)
			eaIdx := 0
			for ek, evVal := range ev.Attributes {
				if eaIdx > 0 {
					dst = append(dst, ',')
				}
				dst = append(dst, `{"key":`...)
				dst = appendJSONEscaped(dst, ek)
				dst = append(dst, `,"value":{"stringValue":`...)
				dst = appendJSONEscaped(dst, evVal)
				dst = append(dst, `}}`...)
				eaIdx++
			}
			dst = append(dst, `]}`...)
		}

		dst = append(dst, `],"status":{"code":`...)
		if s.Status.Code == "ERROR" {
			dst = append(dst, '2')
		} else {
			dst = append(dst, '1')
		}
		dst = append(dst, `}}`...)
	}

	dst = append(dst, `]}]}]}`...)
	return dst
}

// AppendMetricsJSON serializes fastmetrics vectors into OTLP v1 JSON format.
func AppendMetricsJSON(dst []byte, vectors []*fastmetrics.Vector, serviceName, scopeName, scopeVersion string) []byte {
	dst = append(dst, `{"resourceMetrics":[{"resource":{"attributes":[{"key":"service.name","value":{"stringValue":`...)
	dst = appendJSONEscaped(dst, serviceName)
	dst = append(dst, `}}]},"scopeMetrics":[{"scope":{"name":`...)
	dst = appendJSONEscaped(dst, scopeName)
	dst = append(dst, `,"version":`...)
	dst = appendJSONEscaped(dst, scopeVersion)
	dst = append(dst, `},"metrics":[`...)

	nowNano := time.Now().UnixNano()
	metricIdx := 0

	for _, v := range vectors {
		series := v.SeriesList()
		if len(series) == 0 {
			continue
		}
		if metricIdx > 0 {
			dst = append(dst, ',')
		}
		dst = append(dst, `{"name":`...)
		dst = appendJSONEscaped(dst, v.Name())
		dst = append(dst, `,"description":`...)
		dst = appendJSONEscaped(dst, v.Help())
		dst = append(dst, `,"unit":"1","sum":{"aggregationTemporality":2,"isMonotonic":true,"dataPoints":[`...)

		for sIdx, s := range series {
			if sIdx > 0 {
				dst = append(dst, ',')
			}
			dst = append(dst, `{"timeUnixNano":"`...)
			dst = strconv.AppendInt(dst, nowNano, 10)
			dst = append(dst, `","asInt":"`...)
			dst = strconv.AppendUint(dst, s.Load(), 10)
			dst = append(dst, `","attributes":[`...)

			for lIdx, lbl := range s.Labels() {
				if lIdx > 0 {
					dst = append(dst, ',')
				}
				dst = append(dst, `{"key":`...)
				dst = appendJSONEscaped(dst, lbl.Key)
				dst = append(dst, `,"value":{"stringValue":`...)
				dst = appendJSONEscaped(dst, lbl.Value)
				dst = append(dst, `}}`...)
			}
			dst = append(dst, `]}`...)
		}

		dst = append(dst, `]}}`...)
		metricIdx++
	}

	dst = append(dst, `]}]}]}`...)
	return dst
}
