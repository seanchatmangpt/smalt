package server

import (
	"context"
	"os"
	"testing"
	"time"

	"smalt.dev/posh/internal/api"
)

// TestDrainTimeoutEnv covers POSH_DRAIN_TIMEOUT parsing against the real
// function (Chicago): duration form, plain-seconds form, and unparseable
// input falling back to the default.
func TestDrainTimeoutEnv(t *testing.T) {
	orig := os.Getenv("POSH_DRAIN_TIMEOUT")
	t.Cleanup(func() { os.Setenv("POSH_DRAIN_TIMEOUT", orig) })

	cases := []struct {
		env  string
		want time.Duration
	}{
		{"", DefaultDrainTimeout},
		{"2s", 2 * time.Second},
		{"10", 10 * time.Second},
		{"1500ms", 1500 * time.Millisecond},
		{"bogus", DefaultDrainTimeout},
	}
	for _, tc := range cases {
		os.Setenv("POSH_DRAIN_TIMEOUT", tc.env)
		if got := DrainTimeout(); got != tc.want {
			t.Errorf("env %q -> %v, want %v", tc.env, got, tc.want)
		}
	}
}

// TestRequestContextFence re-proves the deadline fence semantics through the
// extracted helper: the envelope deadline lands on the derived context, a
// zero deadline yields a cancel-only context, and cancellation is
// observable via ctx.Done.
func TestRequestContextFence(t *testing.T) {
	dl := time.Now().Add(50 * time.Millisecond)
	ctx, cancel := requestContext(context.Background(), dl)
	defer cancel()
	got, _ := ctx.Deadline()
	if diff := got.Sub(dl); diff < -50*time.Millisecond || diff > 50*time.Millisecond {
		t.Errorf("deadline = %v, want ~%v", got, dl)
	}
	if ctx.Err() != nil {
		t.Fatalf("fresh context has error %v", ctx.Err())
	}
	<-ctx.Done() // real fence: context actually fires at the envelope deadline
	if ctx.Err() != context.DeadlineExceeded {
		t.Errorf("ctx.Err() = %v, want DeadlineExceeded", ctx.Err())
	}

	zeroCtx, zeroCancel := requestContext(context.Background(), time.Time{})
	defer zeroCancel()
	if _, has := zeroCtx.Deadline(); has {
		t.Errorf("zero deadline context carries a deadline")
	}

	req := &api.Request{ID: "req-x", Op: "echo", Deadline: time.Now().Add(-1 * time.Second)}
	fCtx, fCancel := requestContext(context.Background(), req.Deadline)
	defer fCancel()
	if fCtx.Err() == nil {
		t.Errorf("already-past envelope deadline not immediately expired")
	}
}
