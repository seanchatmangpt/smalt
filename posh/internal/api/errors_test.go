package api

import (
	"context"
	"errors"
	"fmt"
	"io"
	"net"
	"testing"
)

func TestSentinelMatching(t *testing.T) {
	// A constructor error matches its sentinel with no cause.
	if !errors.Is(NewDeadline("dispatch", nil, "slow"), ErrDeadline) {
		t.Fatal("NewDeadline should match ErrDeadline")
	}
	// ...and through a wrapped cause chain.
	_, netErr := net.Dial("unix", "/nonexistent/posh-test.sock")
	if netErr == nil {
		t.Fatal("expected dial to fail")
	}
	wrapped := NewTransport("dial", netErr, "membrane dial failed")
	if !errors.Is(wrapped, ErrTransport) {
		t.Fatal("wrapped transport error should match ErrTransport")
	}
	if !errors.As(wrapped, new(*net.OpError)) {
		t.Fatal("errors.As should reach the net.OpError cause")
	}
	// Unwrap returns the cause first, then the sentinel.
	if errors.Unwrap(wrapped) != netErr {
		t.Fatal("Unwrap should return the cause")
	}
	// Bare sentinels match themselves.
	if !errors.Is(fmt.Errorf("outer: %w", ErrRefusedEgress), ErrRefusedEgress) {
		t.Fatal("plain wrapping of sentinel should match")
	}
}

func TestErrorString(t *testing.T) {
	e := NewUpstream("dispatch", io.ErrUnexpectedEOF, "handler %s failed", "echo")
	want := "dispatch: upstream: handler echo failed: unexpected EOF"
	if e.Error() != want {
		t.Fatalf("got %q, want %q", e.Error(), want)
	}
	noCause := NewTransport("decode", nil, "bad envelope")
	if noCause.Error() != "decode: transport: bad envelope" {
		t.Fatalf("got %q", noCause.Error())
	}
}

func TestMapping(t *testing.T) {
	cases := []struct {
		err  error
		want ErrorCode
	}{
		{NewRefusedEgress("egress", nil, "host not admitted"), CodeRefusedEgress},
		{NewDeadline("dispatch", context.DeadlineExceeded, "fence fired"), CodeDeadline},
		{context.DeadlineExceeded, CodeDeadline},
		{fmt.Errorf("wrap: %w", NewDeadline("op", nil, "inner")), CodeDeadline},
		{fmt.Errorf("plain"), CodeUpstream},
		{NewTransport("read", nil, "x"), CodeTransport},
		{nil, ""},
	}
	for _, c := range cases {
		if got := Mapping(c.err); got != c.want {
			t.Fatalf("Mapping(%v) = %s, want %s", c.err, got, c.want)
		}
	}
}
