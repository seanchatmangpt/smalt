// Route precedence law for the Azure dialect (v26.10.31 wave-2 lane 13).
//
// The BEAM arm_gateway reproduces Azure's specific-before-catch-all
// precedence by PLUG MOUNT ORDER (router.ex mounts FunctionsRouter and
// ContainerAppsRouter before :match; AcrRouter immediately before
// ResourceProviders) and by declaring both casings of the
// resourcegroups/resourceGroups literal for every RG-scoped route.
//
// The dialect reproduces the same law declaratively: a RouteTable is an
// ORDERED list of routes; resolution is first-match-in-order, and
// construction REJECTS a table where a glob route precedes a literal or
// param route it would shadow (fail-closed precedence — a reordered
// catch-all is a construction-time refusal, not a silent re-route).
package azure

import (
	"fmt"
	"strings"

	"smalt.dev/posh/internal/dialect"
)

// Route is one row of the dialect route table.
type Route struct {
	// Method is the HTTP verb ("GET", "POST", ...) or "*" for any verb.
	Method string
	// Segments patterns, one alternative per inner slice (a route may
	// carry several casing alternatives, mirroring the BEAM's explicit
	// resourcegroups/resourceGroups route pairs).
	Segments [][]string
	// Family names the dialect family that answers the route.
	Family string
	// RouteOp is the operation name registered for this route in the op
	// registry (the LookupOp key).
	RouteOp string
}

// Families is the family registry: it answers which admitted op spec (if
// any) serves a (method, path) request. Resolution is strictly ordered:
// first match in table order wins, so specificity order is load-bearing.
type Families struct {
	ops  *MemRegistry
	Rows []Route
}

// NewFamilies validates precedence and wires a Families over the given op
// registry. Construction is fail-closed: a table whose catch-all ("*"
// segment) precedes a non-glob route it would shadow is REFUSED at
// construction — the "reordered catch-all must fail" court pins this.
func NewFamilies(ops *MemRegistry, rows []Route) (*Families, error) {
	globIdx := -1
	for i, r := range rows {
		if !isGlobRoute(r) {
			continue
		}
		globIdx = i
		break
	}
	if globIdx >= 0 {
		for j := globIdx + 1; j < len(rows); j++ {
			if !isGlobRoute(rows[j]) {
				return nil, fmt.Errorf("azure: route table precedence violation: glob route %q at index %d shadows non-glob route %q at index %d",
					rows[globIdx].Family, globIdx, rows[j].Family, j)
			}
		}
	}
	return &Families{ops: ops, Rows: rows}, nil
}

func isGlobRoute(r Route) bool {
	return len(r.Segments) == 1 && len(r.Segments[0]) == 1 && r.Segments[0][0] == "*"
}

// Resolve answers the first matching route for (method, path) in table
// order. ok=false means no route claims the request — the dialect-level
// 404 (posh owns the RouteNotFound spelling; the BEAM catch-all is the
// legacy face).
func (f *Families) Resolve(method, path string) (Route, dialect.OpSpec, bool) {
	segs := splitPath(path)
	for _, r := range f.Rows {
		if !methodMatch(r.Method, method) {
			continue
		}
		if _, ok := matchSegments(r, segs); ok {
			spec, ok := f.ops.LookupOp(r.RouteOp)
			if !ok {
				// Route matched but its op is not admitted: fail closed.
				return r, dialect.OpSpec{}, false
			}
			return r, spec, true
		}
	}
	return Route{}, dialect.OpSpec{}, false
}

// ResolveRoute resolves without op-admission (table geometry only).
func (f *Families) ResolveRoute(method, path string) (Route, bool) {
	segs := splitPath(path)
	for _, r := range f.Rows {
		if !methodMatch(r.Method, method) {
			continue
		}
		if _, ok := matchSegments(r, segs); ok {
			return r, true
		}
	}
	return Route{}, false
}

func methodMatch(pattern, method string) bool {
	return pattern == "*" || strings.EqualFold(pattern, method)
}

// matchSegments matches one route's segment alternatives against the
// request segments. Literals are case-insensitive (ARM keyword + Azure
// resource-provider tolerance: real ARM answers lowercase resourcegroups).
func matchSegments(r Route, segs []string) (map[string]string, bool) {
	for _, alt := range r.Segments {
		if params, ok := matchOne(alt, segs); ok {
			return params, true
		}
	}
	return nil, false
}

func matchOne(alt, segs []string) (map[string]string, bool) {
	if len(alt) == 1 && alt[0] == "*" {
		return map[string]string{}, true
	}
	if len(alt) != len(segs) {
		return nil, false
	}
	params := map[string]string{}
	for i, pat := range alt {
		if strings.HasPrefix(pat, ":") {
			params[pat[1:]] = segs[i]
			continue
		}
		if !strings.EqualFold(pat, segs[i]) {
			return nil, false
		}
	}
	return params, true
}

// splitPath splits an ARM path into lowercase-preserving segments,
// dropping empty segments (leading slash, "//" tolerance mirrors the
// BEAM normalize_leading_empty_segment law).
func splitPath(p string) []string {
	parts := strings.Split(strings.TrimPrefix(p, "/"), "/")
	res := make([]string, 0, len(parts))
	for _, part := range parts {
		if part != "" {
			res = append(res, part)
		}
	}
	return res
}
