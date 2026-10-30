// Package dialect defines the POSH dialect interface: the typed
// resource-reference and operation-spec vocabulary an inbound ARM-shaped
// request is resolved against before any frame crosses the membrane.
//
// Import-cycle law: dialect imports internal/api and internal/config ONLY.
// internal/api must never import internal/egress (egress imports api — a
// cycle). dialect never imports ingress, adapter, or egress; ParseRef
// re-states ingress.ParseARMResourceID semantics locally rather than
// reaching across to the router package.
package dialect

import (
	"strings"

	"smalt.dev/posh/internal/api"
)

// Ref is a parsed ARM resource reference. It carries the same fields
// ingress.ParseARMResourceID extracts, without importing the router
// package (import-cycle law: dialect -> api/config only).
type Ref struct {
	// Raw is the cleaned input path (leading slash kept, trailing slash
	// trimmed).
	Raw string
	// SubscriptionID is the segment after "subscriptions", if any.
	SubscriptionID string
	// ResourceGroupName is the segment after "resourceGroups", if any.
	ResourceGroupName string
	// ProviderNamespace is the segment after "providers", if any.
	ProviderNamespace string
	// ResourceType is the resource type segment (e.g. "vaults").
	ResourceType string
	// ResourceName is the resource name segment.
	ResourceName string
	// SubResourceType / SubResourceName name an optional child resource
	// (e.g. "secrets"/"apiVersion" under a vault).
	SubResourceType string
	SubResourceName string
	// Action is a terminal action verb (POST operation), when present.
	Action string
	// IsOperation reports whether the reference resolves to an action
	// verb rather than a resource.
	IsOperation bool
}

// ParseRef parses an ARM-shaped path into a Ref, restating the
// ingress.ParseARMResourceID semantics: segments are split on "/", matched
// case-insensitively for the keywords (subscriptions, resourceGroups,
// providers), and a single terminal non-keyword segment after a resource
// is an action verb.
func ParseRef(path string) (Ref, error) {
	p := cleanPath(path)
	segs := splitSegments(p)
	if len(segs) == 0 {
		return Ref{}, api.NewTransport("parseRef", nil, "empty ARM path %q", path)
	}

	ref := Ref{Raw: p}
	i := 0
	n := len(segs)
	for i < n {
		sLower := strings.ToLower(segs[i])
		switch sLower {
		case "subscriptions":
			if i+1 < n {
				ref.SubscriptionID = segs[i+1]
				i += 2
				continue
			}
		case "resourcegroups":
			if i+1 < n {
				ref.ResourceGroupName = segs[i+1]
				i += 2
				continue
			}
		case "providers":
			if i+1 < n {
				ref.ProviderNamespace = segs[i+1]
				i += 2
				if i < n && !isKeyword(segs[i]) {
					ref.ResourceType = segs[i]
					i++
					if i < n && !isKeyword(segs[i]) {
						ref.ResourceName = segs[i]
						i++
					}
					if i < n && !isKeyword(segs[i]) {
						if i == n-1 {
							ref.Action = segs[i]
							ref.IsOperation = true
							i++
						} else {
							ref.SubResourceType = segs[i]
							i++
							if i < n && !isKeyword(segs[i]) {
								ref.SubResourceName = segs[i]
								i++
							}
						}
					}
				}
				continue
			}
		default:
			if i == n-1 && !isKeyword(segs[i]) {
				ref.Action = segs[i]
				ref.IsOperation = true
			}
		}
		i++
	}
	return ref, nil
}

// OpSpec is the admitted shape of one dialect operation: what it is
// called, which turnstile receipt admitted it, which hosts its egress may
// reach, and the payload shape it accepts.
type OpSpec struct {
	// Op is the operation name (e.g. "echo").
	Op string
	// TurnstileReceipt is the receipt emitted by the admitting turnstile.
	// An empty receipt fails closed (POS-008).
	TurnstileReceipt string
	// AllowHosts is the egress allowlist for this op.
	AllowHosts []string
	// Shape names the expected payload shape (e.g. "echo.v1").
	Shape string
}

// Registry resolves operation names to their admitted OpSpec. An op absent
// from the registry is a policy refusal, never a dynamic admission.
type Registry interface {
	LookupOp(op string) (OpSpec, bool)
}

// shapeViolation reports whether payload violates the op's declared Shape.
// Shapes are matched case-sensitively; an empty Shape on the spec means
// the shape check is waived (the spec never declared one).
func ShapeViolation(spec OpSpec, shape string) error {
	if spec.Shape == "" || spec.Shape == shape {
		return nil
	}
	return api.NewRefusedEgress(spec.Op, nil, "shape %q refused for op %q (want %q)", shape, spec.Op, spec.Shape)
}

func isKeyword(s string) bool {
	l := strings.ToLower(s)
	return l == "providers" || l == "subscriptions" || l == "resourcegroups"
}

func cleanPath(p string) string {
	if !strings.HasPrefix(p, "/") {
		p = "/" + p
	}
	if len(p) > 1 && strings.HasSuffix(p, "/") {
		p = p[:len(p)-1]
	}
	return p
}

func splitSegments(p string) []string {
	parts := strings.Split(p, "/")
	res := make([]string, 0, len(parts))
	for _, part := range parts {
		if part != "" {
			res = append(res, part)
		}
	}
	return res
}
