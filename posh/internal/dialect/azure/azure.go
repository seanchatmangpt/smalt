// Package azure provides the default in-memory dialect Registry for the
// ARM dialect: the projected allowlist of admitted membrane ops, seeded
// with the echo op so lanes wiring the dispatcher (internal/adapter) and
// the courts have a concrete table to bind against.
package azure

import "smalt.dev/posh/internal/dialect"

// Default is the registry seeded with the built-in ops. The map is the
// allowlist: an op absent from it is refused by LookupOp — no dynamic
// admission, no bypass.
var Default = NewRegistry()

// builtinOps mirrors the adapter's projected MembraneOp table for the
// default (non-generated) surface: op -> admitted spec.
var builtinOps = map[string]dialect.OpSpec{
	"echo": {
		Op:               "echo",
		TurnstileReceipt: "posh-turnstile-echo-v1",
		AllowHosts:       []string{"http://127.0.0.1:9545"},
		Shape:            "echo.v1",
	},
}

// MemRegistry is a minimal in-memory Registry over a static op table.
type MemRegistry struct {
	ops map[string]dialect.OpSpec
}

// compile-time proof MemRegistry satisfies the dialect.Registry seam.
var _ dialect.Registry = (*MemRegistry)(nil)

// NewRegistry builds a MemRegistry seeded with the builtin ops.
func NewRegistry() *MemRegistry {
	ops := make(map[string]dialect.OpSpec, len(builtinOps))
	for k, v := range builtinOps {
		ops[k] = v
	}
	return &MemRegistry{ops: ops}
}

// Register admits one op spec into the registry (test/wiring extension
// point; production tables are the generated projections).
func (m *MemRegistry) Register(spec dialect.OpSpec) {
	m.ops[spec.Op] = spec
}

// LookupOp resolves an op name. An unknown op returns ok=false; callers
// turn that into api.NewRefusedEgress — the refusal is typed at the call
// site so dialect needs no error taxonomy of its own.
func (m *MemRegistry) LookupOp(op string) (dialect.OpSpec, bool) {
	spec, ok := m.ops[op]
	return spec, ok
}
