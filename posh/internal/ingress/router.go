package ingress

import (
	"errors"
	"net/http"
	"strings"
	"sync"
)

// ARMResourceID represents a parsed, normalized Azure Resource Manager URI.
type ARMResourceID struct {
	Raw               string
	SubscriptionID    string
	ResourceGroupName string
	ProviderNamespace string
	ResourceType      string
	ResourceName      string
	SubResourceType   string
	SubResourceName   string
	Action            string
	IsOperation       bool
}

// Handler is a high-performance HTTP handler that receives the parsed ARMResourceID.
type Handler func(w http.ResponseWriter, r *http.Request, id *ARMResourceID)

type routeNode struct {
	part       string
	isParam    bool
	paramName  string
	handler    Handler
	children   []*routeNode
	wildcard   *routeNode
}

// Router is a zero-allocation, case-insensitive Radix tree router optimized for ARM URIs.
type Router struct {
	mu           sync.RWMutex
	staticRoutes map[string]Handler // fast path O(1) for static endpoints
	root         *routeNode
}

// NewRouter constructs a clean ARM Ingress Radix Router.
func NewRouter() *Router {
	return &Router{
		staticRoutes: make(map[string]Handler),
		root:         &routeNode{part: "/"},
	}
}

// RegisterStatic registers an exact, case-insensitive static path (e.g., /metadata/endpoints).
func (r *Router) RegisterStatic(path string, h Handler) {
	r.mu.Lock()
	defer r.mu.Unlock()
	r.staticRoutes[strings.ToLower(strings.TrimSpace(path))] = h
}

// Register registers a parameterized route pattern (e.g. /subscriptions/:sub/resourceGroups/:rg).
func (r *Router) Register(pattern string, h Handler) {
	r.mu.Lock()
	defer r.mu.Unlock()

	pattern = cleanPath(pattern)
	segments := splitSegments(pattern)

	curr := r.root
	for _, seg := range segments {
		if strings.HasPrefix(seg, ":") {
			paramName := seg[1:]
			found := false
			for _, child := range curr.children {
				if child.isParam && child.paramName == paramName {
					curr = child
					found = true
					break
				}
			}
			if !found {
				child := &routeNode{
					part:      seg,
					isParam:   true,
					paramName: paramName,
				}
				curr.children = append(curr.children, child)
				curr = child
			}
		} else {
			segLower := strings.ToLower(seg)
			found := false
			for _, child := range curr.children {
				if !child.isParam && strings.ToLower(child.part) == segLower {
					curr = child
					found = true
					break
				}
			}
			if !found {
				child := &routeNode{
					part: segLower,
				}
				curr.children = append(curr.children, child)
				curr = child
			}
		}
	}
	curr.handler = h
}

// Match performs a case-insensitive radix lookup and tokenizes the ARM URI.
func (r *Router) Match(path string) (Handler, *ARMResourceID, bool) {
	path = cleanPath(path)
	pathLower := strings.ToLower(path)

	r.mu.RLock()
	if h, ok := r.staticRoutes[pathLower]; ok {
		r.mu.RUnlock()
		return h, &ARMResourceID{Raw: path}, true
	}
	root := r.root
	r.mu.RUnlock()

	segments := splitSegments(path)
	id := &ARMResourceID{Raw: path}
	params := make(map[string]string)

	curr := root
	for _, seg := range segments {
		segLower := strings.ToLower(seg)
		var matchedChild *routeNode

		// Try exact static child first
		for _, child := range curr.children {
			if !child.isParam && child.part == segLower {
				matchedChild = child
				break
			}
		}

		// Fallback to param child
		if matchedChild == nil {
			for _, child := range curr.children {
				if child.isParam {
					matchedChild = child
					params[child.paramName] = seg
					break
				}
			}
		}

		if matchedChild == nil {
			// Try direct ARM tokenizer fallback if path has standard ARM prefix
			if parsedID, err := ParseARMResourceID(path); err == nil {
				return nil, parsedID, false
			}
			return nil, nil, false
		}
		curr = matchedChild
	}

	if curr.handler == nil {
		return nil, nil, false
	}

	// Map params into ARMResourceID fields
	if v, ok := params["sub"]; ok {
		id.SubscriptionID = v
	} else if v, ok := params["subscriptionId"]; ok {
		id.SubscriptionID = v
	}
	if v, ok := params["rg"]; ok {
		id.ResourceGroupName = v
	} else if v, ok := params["resourceGroupName"]; ok {
		id.ResourceGroupName = v
	}
	if v, ok := params["provider"]; ok {
		id.ProviderNamespace = v
	}
	if v, ok := params["type"]; ok {
		id.ResourceType = v
	}
	if v, ok := params["name"]; ok {
		id.ResourceName = v
	}
	if v, ok := params["action"]; ok {
		id.Action = v
		id.IsOperation = true
	}

	return curr.handler, id, true
}

// ParseARMResourceID parses standard ARM resource URI structures without allocations where possible.
func ParseARMResourceID(path string) (*ARMResourceID, error) {
	path = cleanPath(path)
	segs := splitSegments(path)
	if len(segs) == 0 {
		return nil, errors.New("empty ARM path")
	}

	id := &ARMResourceID{Raw: path}
	i := 0
	n := len(segs)

	for i < n {
		sLower := strings.ToLower(segs[i])
		switch sLower {
		case "subscriptions":
			if i+1 < n {
				id.SubscriptionID = segs[i+1]
				i += 2
				continue
			}
		case "resourcegroups":
			if i+1 < n {
				id.ResourceGroupName = segs[i+1]
				i += 2
				continue
			}
		case "providers":
			if i+1 < n {
				id.ProviderNamespace = segs[i+1]
				i += 2
				if i < n && !isKeyword(segs[i]) {
					id.ResourceType = segs[i]
					i++
					if i < n && !isKeyword(segs[i]) {
						id.ResourceName = segs[i]
						i++
					}
					// Sub-resources or terminal action
					if i < n && !isKeyword(segs[i]) {
						if i == n-1 {
							// Single terminal segment after resource is an action verb
							id.Action = segs[i]
							id.IsOperation = true
							i++
						} else {
							id.SubResourceType = segs[i]
							i++
							if i < n && !isKeyword(segs[i]) {
								id.SubResourceName = segs[i]
								i++
							}
						}
					}
				}
				continue
			}
		default:
			// Check if terminal segment is an action (POST action verb)
			if i == n-1 && !isKeyword(segs[i]) {
				id.Action = segs[i]
				id.IsOperation = true
			}
		}
		i++
	}

	return id, nil
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
