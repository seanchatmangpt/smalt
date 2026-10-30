package metrics

import (
	"net/http/httptest"
	"sync"
	"testing"
	"time"
)

func TestRenderSortedDeterministic(t *testing.T) {
	r := New()
	r.Inc("m", map[string]string{"b": "2", "a": "1"})
	r.Inc("m", map[string]string{"a": "1"})
	r.Inc("m", map[string]string{"a": "1"})
	want := "# TYPE m counter\n" +
		`m{a="1"} 2` + "\n" +
		`m{a="1",b="2"} 1` + "\n"
	if got := r.Render(); got != want {
		t.Fatalf("Render =\n%s\nwant\n%s", got, want)
	}
}

func TestServeHTTPContentTypeAndBody(t *testing.T) {
	r := New()
	r.Inc("x_total", map[string]string{"k": "v"})
	w := httptest.NewRecorder()
	r.ServeHTTP(w, nil)
	if w.Code != 200 {
		t.Fatalf("code = %d, want 200", w.Code)
	}
	want := "# TYPE x_total counter\n" + `x_total{k="v"} 1` + "\n"
	if w.Body.String() != want {
		t.Fatalf("body = %q, want %q", w.Body.String(), want)
	}
}

func TestConcurrentIncRace(t *testing.T) {
	r := New()
	var wg sync.WaitGroup
	for i := 0; i < 8; i++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			for j := 0; j < 1000; j++ {
				r.Inc("c", map[string]string{"w": "x"})
			}
		}()
	}
	wg.Wait()
	want := "# TYPE c counter\n" + `c{w="x"} 8000` + "\n"
	if got := r.Render(); got != want {
		t.Fatalf("Render = %q, want %q", got, want)
	}
}

func TestQuantilesAndConnections(t *testing.T) {
	r := New()
	r.IncConn()
	r.IncConn()
	if got := r.ActiveConns(); got != 2 {
		t.Fatalf("ActiveConns = %d, want 2", got)
	}
	r.DecConn()
	if got := r.ActiveConns(); got != 1 {
		t.Fatalf("ActiveConns = %d, want 1", got)
	}

	for i := 1; i <= 100; i++ {
		r.RecordDuration(time.Duration(i) * time.Millisecond)
	}

	p50, p95, p99 := r.Quantiles()
	if p50 < 45*time.Millisecond || p50 > 55*time.Millisecond {
		t.Errorf("p50 = %v, want ~50ms", p50)
	}
	if p95 < 90*time.Millisecond || p95 > 98*time.Millisecond {
		t.Errorf("p95 = %v, want ~95ms", p95)
	}
	if p99 < 95*time.Millisecond || p99 > 100*time.Millisecond {
		t.Errorf("p99 = %v, want ~99ms", p99)
	}
}
