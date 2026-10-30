// Package uniqueintern explores Go 1.24+ unique.Make string interning
// architectures for ARM resource models, subscriptions, and regions.
package uniqueintern

import (
	"fmt"
	"strings"
	"sync"
	"sync/atomic"
	"unsafe"
)

// Handle represents a canonical interned value, mirroring Go 1.24's unique.Handle[T].
// Two handles h1 and h2 are equal (h1 == h2) if and only if their underlying values
// are identical. Comparing handles is an O(1) single pointer comparison rather than
// an O(N) runtime.memequal call.
type Handle[T comparable] struct {
	ptr *T
}

// Value returns the underlying interned value.
func (h Handle[T]) Value() T {
	if h.ptr == nil {
		var zero T
		return zero
	}
	return *h.ptr
}

// IsZero reports whether the handle is the zero value.
func (h Handle[T]) IsZero() bool {
	return h.ptr == nil
}

// RawPointer returns the canonical memory address of the interned value.
func (h Handle[T]) RawPointer() uintptr {
	return uintptr(unsafe.Pointer(h.ptr))
}

// String implements fmt.Stringer for string handles.
func (h Handle[T]) String() string {
	if h.ptr == nil {
		return ""
	}
	return fmt.Sprint(*h.ptr)
}

// Pool is a concurrent, lock-free read intern pool implementing the canonicalization
// semantics of Go 1.24 unique.Make.
type Pool[T comparable] struct {
	mu      sync.RWMutex
	entries map[T]*T
	// Metrics for memory reduction tracking
	totalInternRequests atomic.Uint64
	dedupHits           atomic.Uint64
}

// NewPool creates a new intern pool.
func NewPool[T comparable]() *Pool[T] {
	return &Pool[T]{
		entries: make(map[T]*T, 1024),
	}
}

// DefaultStringPool is the global pool for string interning.
var DefaultStringPool = NewPool[string]()

// Intern interns value v, returning its canonical Handle.
func (p *Pool[T]) Intern(v T) Handle[T] {
	p.totalInternRequests.Add(1)

	// Fast path: lock-free read check under RLock
	p.mu.RLock()
	ptr, exists := p.entries[v]
	p.mu.RUnlock()
	if exists {
		p.dedupHits.Add(1)
		return Handle[T]{ptr: ptr}
	}

	// Slow path: insert canonical value under full Lock
	p.mu.Lock()
	defer p.mu.Unlock()
	if ptr, exists = p.entries[v]; exists {
		p.dedupHits.Add(1)
		return Handle[T]{ptr: ptr}
	}

	canonical := new(T)
	*canonical = v
	p.entries[v] = canonical
	return Handle[T]{ptr: canonical}
}

// Stats returns the intern request count and deduplication hit count.
func (p *Pool[T]) Stats() (requests uint64, hits uint64, uniqueEntries int) {
	p.mu.RLock()
	defer p.mu.RUnlock()
	return p.totalInternRequests.Load(), p.dedupHits.Load(), len(p.entries)
}

// Make mirrors Go 1.24 unique.Make(v) using the default string pool.
func Make(s string) Handle[string] {
	return DefaultStringPool.Intern(s)
}

// ParsedARMResource represents an Azure Resource Manager resource whose
// repetitive structural components (subscription ID, resource group, provider,
// resource type, location) are interned to eliminate tens of megabytes of heap
// duplicates across thousands of resources.
type ParsedARMResource struct {
	Subscription  Handle[string]
	ResourceGroup Handle[string]
	Provider      Handle[string]
	ResourceType  Handle[string]
	ResourceName  Handle[string]
	Location      Handle[string]
}

// ParseARMResource parses a raw ARM resource ID string into an interned resource:
// /subscriptions/{subId}/resourceGroups/{rg}/providers/{provider}/{type}/{name}
func ParseARMResource(rawID string, location string) (ParsedARMResource, error) {
	clean := strings.Trim(rawID, "/")
	parts := strings.Split(clean, "/")

	var res ParsedARMResource
	res.Location = Make(strings.ToLower(location))

	// /subscriptions/{sub}/resourceGroups/{rg}/providers/{provider}/{type}/{name}
	if len(parts) >= 8 && strings.EqualFold(parts[0], "subscriptions") && strings.EqualFold(parts[2], "resourceGroups") {
		res.Subscription = Make(parts[1])
		res.ResourceGroup = Make(parts[3])
		if strings.EqualFold(parts[4], "providers") {
			res.Provider = Make(parts[5])
			res.ResourceType = Make(parts[6])
			res.ResourceName = Make(parts[7])
			return res, nil
		}
	}

	// Shorter forms or fallback
	if len(parts) >= 2 && strings.EqualFold(parts[0], "subscriptions") {
		res.Subscription = Make(parts[1])
	}
	if len(parts) >= 4 && strings.EqualFold(parts[2], "resourceGroups") {
		res.ResourceGroup = Make(parts[3])
	}
	return res, nil
}

// StandardARMResource represents an uninterned representation for benchmarking.
type StandardARMResource struct {
	Subscription  string
	ResourceGroup string
	Provider      string
	ResourceType  string
	ResourceName  string
	Location      string
}

// ParseStandard parses without interning.
func ParseStandard(rawID, location string) StandardARMResource {
	clean := strings.Trim(rawID, "/")
	parts := strings.Split(clean, "/")
	var res StandardARMResource
	res.Location = strings.ToLower(location)
	if len(parts) >= 8 && strings.EqualFold(parts[0], "subscriptions") && strings.EqualFold(parts[2], "resourceGroups") {
		res.Subscription = parts[1]
		res.ResourceGroup = parts[3]
		if strings.EqualFold(parts[4], "providers") {
			res.Provider = parts[5]
			res.ResourceType = parts[6]
			res.ResourceName = parts[7]
		}
	}
	return res
}
