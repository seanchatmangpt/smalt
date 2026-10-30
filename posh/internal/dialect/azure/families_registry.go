// Wave-2 lane 13: admits the first MOVE families' ops into a MemRegistry
// (fail-closed allowlist — every route's RouteOp must resolve here).
package azure

import "smalt.dev/posh/internal/dialect"

// RegisterFirstFamilies admits one op per first-family route row into
// the registry, keyed by the rows' RouteOp names. POS-008: every op
// carries a non-empty turnstile receipt and shape.
func RegisterFirstFamilies(reg *MemRegistry) {
	for _, r := range firstFamilyRoutes() {
		reg.Register(specFor(r))
	}
}

// specFor derives the admitted OpSpec for a route row.
func specFor(r Route) dialect.OpSpec {
	return dialect.OpSpec{
		Op:               r.RouteOp,
		TurnstileReceipt: "posh-turnstile-azure-" + r.Family + "-v1",
		AllowHosts:       []string{"http://127.0.0.1:9545"},
		Shape:            r.Family + ".v1",
	}
}
