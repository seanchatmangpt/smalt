package swissmap

import (
	"fmt"
	"math/rand"
	"sync"
	"testing"
)

func TestSwissTableLookup(t *testing.T) {
	entries := map[string]any{
		"echo":                          "handler_echo",
		"arm.resource_group":            "handler_rg",
		"arm.container_app":             "handler_ca",
		"arm.key_vault":                 "handler_kv",
		"arm.storage_account":           "handler_sa",
		"arm.user_assigned_identity":    "handler_uai",
		"arm.role_definition":           "handler_rd",
		"arm.role_assignment":           "handler_ra",
		"arm.container_registry":        "handler_cr",
		"arm.log_analytics_workspace":   "handler_law",
	}

	st := NewSwissRouteTable(entries)

	for k, v := range entries {
		got, found := st.Lookup(k)
		if !found {
			t.Fatalf("key %q not found", k)
		}
		if got != v {
			t.Fatalf("key %q: got %v, want %v", k, got, v)
		}
	}

	// Negative lookup
	if _, found := st.Lookup("nonexistent.op"); found {
		t.Fatalf("expected nonexistent.op to return false")
	}
}

func TestConcurrentRouterRCU(t *testing.T) {
	router := NewConcurrentRouter(map[string]any{
		"echo": "echo_v1",
	})

	val, ok := router.Route("echo")
	if !ok || val != "echo_v1" {
		t.Fatalf("expected echo_v1, got %v", val)
	}

	// Concurrent register and lookup
	var wg sync.WaitGroup
	for i := 0; i < 10; i++ {
		wg.Add(1)
		go func(idx int) {
			defer wg.Done()
			op := fmt.Sprintf("dynamic.op_%d", idx)
			router.Register(op, fmt.Sprintf("val_%d", idx))
		}(i)
	}

	for i := 0; i < 50; i++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			router.Route("echo")
		}()
	}
	wg.Wait()

	for i := 0; i < 10; i++ {
		op := fmt.Sprintf("dynamic.op_%d", i)
		val, ok := router.Route(op)
		if !ok || val != fmt.Sprintf("val_%d", i) {
			t.Errorf("expected %s, got %v", op, val)
		}
	}
}

func BenchmarkRouteTableComparison(b *testing.B) {
	ops := []string{
		"echo", "arm.resource_group", "arm.container_app", "arm.key_vault",
		"arm.storage_account", "arm.user_assigned_identity", "arm.role_definition",
		"arm.role_assignment", "arm.container_registry", "arm.log_analytics_workspace",
	}

	// 1. Standard map with RWMutex
	var mu sync.RWMutex
	stdMap := make(map[string]any)
	for _, op := range ops {
		stdMap[op] = "handler_" + op
	}

	b.Run("StandardMapRWMutexParallel", func(b *testing.B) {
		b.ReportAllocs()
		b.ResetTimer()
		b.RunParallel(func(pb *testing.PB) {
			rng := rand.New(rand.NewSource(42))
			for pb.Next() {
				op := ops[rng.Intn(len(ops))]
				mu.RLock()
				_ = stdMap[op]
				mu.RUnlock()
			}
		})
	})

	// 2. SwissTable with atomic.Pointer (RCU wait-free)
	router := NewConcurrentRouter(stdMap)

	b.Run("SwissRouterWaitFreeParallel", func(b *testing.B) {
		b.ReportAllocs()
		b.ResetTimer()
		b.RunParallel(func(pb *testing.PB) {
			rng := rand.New(rand.NewSource(42))
			for pb.Next() {
				op := ops[rng.Intn(len(ops))]
				_, _ = router.Route(op)
			}
		})
	})
}
