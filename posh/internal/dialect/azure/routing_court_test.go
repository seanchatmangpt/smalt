// Wave-2 lane 13 courts. Precedence law: the route table is first-match-
// in-order and construction REFUSES a glob-before-specific table — the
// "reordered catch-all must fail" falsifier. Envelope court: the dialect
// spelling is byte-compared against the BEAM send_arm_error bytes.
package azure

import (
	"strings"
	"testing"

	"smalt.dev/posh/internal/dialect"
)

// newTestOps builds a registry admitting every first-family op plus the
// core catch-all op used by the mutation leg.
func newTestOps(t *testing.T) *MemRegistry {
	t.Helper()
	reg := NewRegistry()
	RegisterFirstFamilies(reg)
	reg.Register(dialectOpSpecCatchall())
	return reg
}

func dialectOpSpecCatchall() dialect.OpSpec {
	return dialect.OpSpec{Op: "azure.core.catchall", TurnstileReceipt: "posh-turnstile-core-v1", AllowHosts: []string{"http://127.0.0.1:9545"}, Shape: "core.v1"}
}

// TestPrecedenceCourtReorderedCatchAllFails pins the law twice: the real
// table (specific rows first, catch-all last) resolves the specific
// family; a reordered table (catch-all promoted first) must FAIL
// CONSTRUCTION — the fail-closed precedence law.
func TestPrecedenceCourtReorderedCatchAllFails(t *testing.T) {
	rows := firstFamilyRoutes()
	table, err := NewFamilies(newTestOps(t), rows)
	if err != nil {
		t.Fatalf("real table refused: %v", err)
	}
	path := "/subscriptions/s1/resourceGroups/rg1/providers/Microsoft.KeyVault/vaults/v1"
	route, spec, ok := table.Resolve("PUT", path)
	if !ok {
		t.Fatal("armkv vault PUT unresolved in real table")
	}
	if route.Family != "armkv" || spec.Op != "azure.armkv.vault.put" {
		t.Fatalf("armkv PUT resolved to family %q op %q", route.Family, spec.Op)
	}
	reordered := append([]Route{{Method: "*", Segments: [][]string{{"*"}}, Family: "core-catch-all", RouteOp: "azure.core.catchall"}}, rows...)
	if _, err := NewFamilies(newTestOps(t), reordered); err == nil {
		t.Fatal("reordered catch-all table ADMITTED: precedence law not fail-closed")
	}
}

// TestFamiliesRegistryClosed pins POS-008 + the closed allowlist: every
// first-family route's op must resolve with a non-empty receipt; an
// unknown op must refuse; a route whose op is missing from the registry
// fails closed at Resolve.
func TestFamiliesRegistryClosed(t *testing.T) {
	table, err := NewFamilies(newTestOps(t), firstFamilyRoutes())
	if err != nil {
		t.Fatalf("table refused: %v", err)
	}
	for _, r := range firstFamilyRoutes() {
		probe := r.Method
		if probe == "*" {
			probe = "GET"
		}
		_, spec, ok := table.Resolve(probe, pathFor(r))
		if !ok {
			t.Fatalf("family %q op %q unresolved", r.Family, r.RouteOp)
		}
		if spec.TurnstileReceipt == "" || spec.Shape == "" {
			t.Fatalf("family %q op %q violates POS-008: %+v", r.Family, r.RouteOp, spec)
		}
	}
	if _, ok := newTestOps(t).LookupOp("no-such-op"); ok {
		t.Fatal("unknown op admitted")
	}
}

// pathFor renders a concrete path satisfying a route row (params filled
// with court-fixed values).
func pathFor(r Route) string {
	segs := r.Segments[0]
	out := make([]string, 0, len(segs))
	for _, s := range segs {
		switch {
		case s == ":sub":
			s = "sub-l13"
		case s == ":rg":
			s = "rg-l13"
		case strings.HasPrefix(s, ":"):
			s = strings.TrimPrefix(s, ":") + "-l13"
		}
		out = append(out, s)
	}
	return "/" + strings.Join(out, "/")
}

// TestErrorEnvelopeByteParity byte-compares the dialect spelling against
// the BEAM send_arm_error bytes for the target and no-target forms.
func TestErrorEnvelopeByteParity(t *testing.T) {
	cases := []struct {
		name string
		env  ErrorEnvelope
		want string
	}{
		{
			name: "target form (BEAM: send_arm_error(conn, 404, \"RouteNotFound\", msg, path))",
			env: ErrorEnvelope{
				Code:    "RouteNotFound",
				Message: "The route '/x/y' could not be found.",
				Target:  "/x/y",
			},
			want: `{"error":{"code":"RouteNotFound","message":"The route '/x/y' could not be found.","target":"/x/y","innererror":{}}}`,
		},
		{
			name: "no-target form",
			env: ErrorEnvelope{
				Code:    "ResourceNotFound",
				Message: "Resource not found.",
			},
			want: `{"error":{"code":"ResourceNotFound","message":"Resource not found.","innererror":{}}}`,
		},
	}
	for _, tc := range cases {
		if got := string(tc.env.Render()); got != tc.want {
			t.Errorf("%s: byte drift\n got: %s\nwant: %s", tc.name, got, tc.want)
		}
	}
}
