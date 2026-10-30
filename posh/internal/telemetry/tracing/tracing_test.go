package tracing

import (
	"context"
	"testing"
)

func TestParseTraceparent_Valid(t *testing.T) {
	raw := "00-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-01"
	tc, err := ParseTraceparent(raw)
	if err != nil {
		t.Fatalf("ParseTraceparent failed: %v", err)
	}

	if tc.Version != 0 {
		t.Errorf("expected version 0, got %d", tc.Version)
	}
	if tc.TraceIDHex() != "4bf92f3577b34da6a3ce929d0e0e4736" {
		t.Errorf("trace id mismatch: %s", tc.TraceIDHex())
	}
	if tc.SpanIDHex() != "00f067aa0ba902b7" {
		t.Errorf("span id mismatch: %s", tc.SpanIDHex())
	}
	if !tc.IsSampled() {
		t.Errorf("expected sampled bit to be true")
	}

	// Round-trip
	if got := tc.String(); got != raw {
		t.Errorf("round-trip string mismatch:\ngot:  %s\nwant: %s", got, raw)
	}
}

func TestParseTraceparent_Invalid(t *testing.T) {
	tests := []struct {
		name string
		raw  string
	}{
		{"too short", "00-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7"},
		{"bad delimiter", "00_4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-01"},
		{"forbidden ff version", "ff-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-01"},
		{"all zero trace id", "00-00000000000000000000000000000000-00f067aa0ba902b7-01"},
		{"all zero span id", "00-4bf92f3577b34da6a3ce929d0e0e4736-0000000000000000-01"},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			_, err := ParseTraceparent(tt.raw)
			if err == nil {
				t.Fatalf("expected error for %s, got nil", tt.raw)
			}
		})
	}
}

func TestParseTracestate_SmaltMetadata(t *testing.T) {
	header := "other=vendor1,smalt=pid:<0.152.0>;node:smalt@node1,third=xyz"
	ts := ParseTracestate(header)

	if ts.ActorPID != "<0.152.0>" {
		t.Errorf("expected actor pid <0.152.0>, got %s", ts.ActorPID)
	}
	if ts.Node != "smalt@node1" {
		t.Errorf("expected node smalt@node1, got %s", ts.Node)
	}

	formatted := FormatSmaltTracestate("<0.152.0>", "smalt@node1")
	if formatted != "smalt=pid:<0.152.0>;node:smalt@node1" {
		t.Errorf("FormatSmaltTracestate mismatch: %s", formatted)
	}
}

func TestTraceDAG_Correlation(t *testing.T) {
	rawParent := "00-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-01"
	parentCtx, err := ParseTraceparent(rawParent)
	if err != nil {
		t.Fatalf("parse parent: %v", err)
	}

	// Membrane ingress span
	span := StartSpan("posh.uds.dispatch", &parentCtx)
	span.SetAttribute("rpc.system", "posh_uds")
	span.SetAttribute("rpc.method", "echo")
	span.CorrelateBEAMActor("<0.152.0>", "smalt@cluster")

	receiptHex := "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
	span.CorrelateTurnstileReceipt(receiptHex, 1730300000000, true)
	span.End()

	if span.TraceIDHex() != "4bf92f3577b34da6a3ce929d0e0e4736" {
		t.Errorf("span trace id mismatch: %s", span.TraceIDHex())
	}
	if span.ParentSpanIDHex() != "00f067aa0ba902b7" {
		t.Errorf("span parent id mismatch: %s", span.ParentSpanIDHex())
	}
	if span.Attributes["smalt.actor.pid"] != "<0.152.0>" {
		t.Errorf("actor pid attribute missing: %v", span.Attributes)
	}
	if span.Attributes["smalt.turnstile.receipt"] != receiptHex {
		t.Errorf("turnstile receipt attribute missing: %v", span.Attributes)
	}
}

func TestContextPropagation(t *testing.T) {
	tc := NewRootContext()
	ctx := WithTraceContext(context.Background(), tc)

	extracted, ok := FromContext(ctx)
	if !ok {
		t.Fatalf("FromContext returned false")
	}
	if extracted.TraceID != tc.TraceID {
		t.Fatalf("Extracted TraceID mismatch")
	}
}

func BenchmarkParseTraceparent(b *testing.B) {
	raw := "00-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-01"
	b.ResetTimer()
	b.ReportAllocs()
	for i := 0; i < b.N; i++ {
		_, _ = ParseTraceparent(raw)
	}
}

func BenchmarkTraceContext_String(b *testing.B) {
	tc := NewRootContext()
	b.ResetTimer()
	b.ReportAllocs()
	for i := 0; i < b.N; i++ {
		_ = tc.String()
	}
}
