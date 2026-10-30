package uniqueintern

import (
	"fmt"
	"math/rand"
	"runtime"
	"testing"
)

func TestInternPointerEquality(t *testing.T) {
	pool := NewPool[string]()

	s1 := fmt.Sprintf("sub-%d", 42)
	s2 := fmt.Sprintf("sub-%d", 42)

	h1 := pool.Intern(s1)
	h2 := pool.Intern(s2)

	if h1 != h2 {
		t.Fatalf("expected handles to be equal by value: h1=%v, h2=%v", h1, h2)
	}
	if h1.RawPointer() != h2.RawPointer() {
		t.Fatalf("expected handles to share canonical pointer: %x != %x", h1.RawPointer(), h2.RawPointer())
	}
	if h1.Value() != s1 {
		t.Fatalf("expected value %q, got %q", s1, h1.Value())
	}

	reqs, hits, unique := pool.Stats()
	if reqs != 2 || hits != 1 || unique != 1 {
		t.Fatalf("unexpected pool stats: reqs=%d, hits=%d, unique=%d", reqs, hits, unique)
	}
}

func TestParseARMResource(t *testing.T) {
	raw := "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-smalt-prod/providers/Microsoft.App/containerApps/app-posh"
	res, err := ParseARMResource(raw, "EastUS2")
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}

	if res.Subscription.Value() != "00000000-0000-0000-0000-000000000000" {
		t.Errorf("subscription = %q", res.Subscription.Value())
	}
	if res.ResourceGroup.Value() != "rg-smalt-prod" {
		t.Errorf("rg = %q", res.ResourceGroup.Value())
	}
	if res.Provider.Value() != "Microsoft.App" {
		t.Errorf("provider = %q", res.Provider.Value())
	}
	if res.Location.Value() != "eastus2" {
		t.Errorf("location = %q", res.Location.Value())
	}
}

func BenchmarkStringEqualityCheck(b *testing.B) {
	s1 := "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-smalt-prod/providers/Microsoft.App/containerApps/app-posh"
	s2 := "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-smalt-prod/providers/Microsoft.App/containerApps/app-posh"

	b.Run("StandardStringMemequal", func(b *testing.B) {
		b.ReportAllocs()
		var res bool
		for i := 0; i < b.N; i++ {
			res = (s1 == s2)
		}
		_ = res
	})

	h1 := Make(s1)
	h2 := Make(s2)

	b.Run("InternedHandlePointerEquality", func(b *testing.B) {
		b.ReportAllocs()
		var res bool
		for i := 0; i < b.N; i++ {
			res = (h1 == h2) // single CMPQ instruction
		}
		_ = res
	})
}

func BenchmarkMemoryFootprint10kResources(b *testing.B) {
	const numResources = 10000
	const numSubs = 5
	const numRGs = 20
	const numProviders = 4
	locations := []string{"eastus", "eastus2", "westeurope", "centralus"}

	subs := make([]string, numSubs)
	for i := range subs {
		subs[i] = fmt.Sprintf("00000000-0000-0000-0000-%012d", i)
	}
	rgs := make([]string, numRGs)
	for i := range rgs {
		rgs[i] = fmt.Sprintf("rg-smalt-cluster-%d", i)
	}
	provs := []string{"Microsoft.App", "Microsoft.KeyVault", "Microsoft.Storage", "Microsoft.ContainerRegistry"}

	rawIDs := make([]string, numResources)
	rawLocs := make([]string, numResources)
	for i := 0; i < numResources; i++ {
		s := subs[i%numSubs]
		rg := rgs[i%numRGs]
		p := provs[i%numProviders]
		loc := locations[i%len(locations)]
		name := fmt.Sprintf("resource-%d", i)
		rawIDs[i] = fmt.Sprintf("/subscriptions/%s/resourceGroups/%s/providers/%s/components/%s", s, rg, p, name)
		rawLocs[i] = loc
	}

	b.Run("StandardUninternedMemory", func(b *testing.B) {
		b.ReportAllocs()
		for n := 0; n < b.N; n++ {
			items := make([]StandardARMResource, numResources)
			for i := 0; i < numResources; i++ {
				items[i] = ParseStandard(rawIDs[i], rawLocs[i])
			}
			runtime.KeepAlive(items)
		}
	})

	b.Run("InternedHandleMemory", func(b *testing.B) {
		b.ReportAllocs()
		for n := 0; n < b.N; n++ {
			items := make([]ParsedARMResource, numResources)
			for i := 0; i < numResources; i++ {
				res, _ := ParseARMResource(rawIDs[i], rawLocs[i])
				items[i] = res
			}
			runtime.KeepAlive(items)
		}
	})
}

func BenchmarkConcurrentInterning(b *testing.B) {
	pool := NewPool[string]()
	keys := []string{
		"eastus", "eastus2", "westeurope", "centralus", "japaneast",
		"rg-core", "rg-gateway", "rg-compute", "rg-storage", "rg-sec",
	}

	b.ReportAllocs()
	b.ResetTimer()

	b.RunParallel(func(pb *testing.PB) {
		rng := rand.New(rand.NewSource(42))
		for pb.Next() {
			k := keys[rng.Intn(len(keys))]
			h := pool.Intern(k)
			if h.Value() != k {
				b.Fatalf("value mismatch")
			}
		}
	})
}
