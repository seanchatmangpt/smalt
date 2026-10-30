package fastmetrics

import (
	"bytes"
	"strings"
	"sync"
	"testing"
)

func TestFastVector_DeterministicOutput(t *testing.T) {
	vec := NewVector("posh_requests_total", "help")
	s1 := vec.RegisterSeries(Label{Key: "op", Value: "echo"}, Label{Key: "transport", Value: "uds"})
	s2 := vec.RegisterSeries(Label{Key: "op", Value: "echo"}, Label{Key: "transport", Value: "tcp"})

	s1.Inc()
	s1.Inc()
	s2.Inc()

	var buf bytes.Buffer
	if err := vec.WriteRender(&buf); err != nil {
		t.Fatalf("WriteRender error: %v", err)
	}

	got := buf.String()
	want := "# TYPE posh_requests_total counter\n" +
		`posh_requests_total{op="echo",transport="tcp"} 1` + "\n" +
		`posh_requests_total{op="echo",transport="uds"} 2` + "\n"

	if got != want {
		t.Fatalf("Render mismatch:\ngot:\n%s\nwant:\n%s", got, want)
	}
}

func TestFastRegistry_MultiVectors(t *testing.T) {
	reg := NewRegistry()
	v1 := NewVector("v_alpha", "first")
	v2 := NewVector("v_beta", "second")

	s1 := v1.RegisterSeries(Label{Key: "k", Value: "1"})
	s2 := v2.RegisterSeries(Label{Key: "k", Value: "2"})

	s1.Add(10)
	s2.Add(20)

	reg.Register(v2)
	reg.Register(v1) // Out of order, should render sorted

	var buf bytes.Buffer
	if err := reg.WriteRender(&buf); err != nil {
		t.Fatalf("WriteRender: %v", err)
	}

	got := buf.String()
	want := "# TYPE v_alpha counter\n" +
		`v_alpha{k="1"} 10` + "\n" +
		"# TYPE v_beta counter\n" +
		`v_beta{k="2"} 20` + "\n"

	if got != want {
		t.Fatalf("Registry render mismatch:\ngot:\n%s\nwant:\n%s", got, want)
	}
}

func TestRequestVector_PreWarmedZeroAlloc(t *testing.T) {
	rv := NewRequestVector([]string{"echo", "arm_get"})
	rv.Record("echo", "uds", "OK")
	rv.Record("echo", "uds", "OK")
	rv.Record("echo", "uds", "DEADLINE")

	var buf bytes.Buffer
	if err := rv.Vector().WriteRender(&buf); err != nil {
		t.Fatalf("WriteRender: %v", err)
	}

	out := buf.String()
	if !strings.Contains(out, `posh_requests_total{code="OK",op="echo",transport="uds"} 2`) {
		t.Fatalf("Expected 2 OK counts in:\n%s", out)
	}
	if !strings.Contains(out, `posh_requests_total{code="DEADLINE",op="echo",transport="uds"} 1`) {
		t.Fatalf("Expected 1 DEADLINE count in:\n%s", out)
	}
}

func TestConcurrentInc(t *testing.T) {
	rv := NewRequestVector([]string{"echo"})
	var wg sync.WaitGroup
	workers := 8
	iterations := 10000

	for i := 0; i < workers; i++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			for j := 0; j < iterations; j++ {
				rv.Record("echo", "uds", "OK")
			}
		}()
	}
	wg.Wait()

	var buf bytes.Buffer
	_ = rv.Vector().WriteRender(&buf)
	expected := `posh_requests_total{code="OK",op="echo",transport="uds"} 80000`
	if !strings.Contains(buf.String(), expected) {
		t.Fatalf("Concurrent count mismatch, wanted %s in %s", expected, buf.String())
	}
}

func BenchmarkFastSeries_Inc(b *testing.B) {
	vec := NewVector("posh_requests_total", "")
	s := vec.RegisterSeries(Label{Key: "code", Value: "OK"}, Label{Key: "op", Value: "echo"}, Label{Key: "transport", Value: "uds"})

	b.ResetTimer()
	b.ReportAllocs()
	for i := 0; i < b.N; i++ {
		s.Inc()
	}
}

func BenchmarkRequestVector_RecordPreWarmed(b *testing.B) {
	rv := NewRequestVector([]string{"echo", "arm_get", "unknown"})
	b.ResetTimer()
	b.ReportAllocs()
	for i := 0; i < b.N; i++ {
		rv.Record("echo", "uds", "OK")
	}
}

func BenchmarkDenseRequestVector_Record(b *testing.B) {
	dv := NewDenseRequestVector([]string{"echo", "arm_get", "unknown"})
	b.ResetTimer()
	b.ReportAllocs()
	for i := 0; i < b.N; i++ {
		dv.Record("echo", "uds", "OK")
	}
}

func BenchmarkFastVector_AppendRender(b *testing.B) {
	rv := NewRequestVector([]string{"echo", "arm_get", "arm_request", "arm_resource_group"})
	for i := 0; i < 100; i++ {
		rv.Record("echo", "uds", "OK")
		rv.Record("arm_get", "tcp", "OK")
	}

	buf := make([]byte, 0, 8192)
	b.ResetTimer()
	b.ReportAllocs()
	for i := 0; i < b.N; i++ {
		buf = rv.Vector().AppendRender(buf[:0])
	}
}
