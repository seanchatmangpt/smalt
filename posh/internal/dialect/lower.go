package dialect

import (
	"encoding/json"

	"smalt.dev/posh/internal/api"
)

// Triple is the stub target of the Lower seam: one subject/predicate/object
// row. Lane 11's wiring owns the real triple store type; this stub keeps
// the Lower signature stable so the seam can be wired without a store
// landing first. Replace the type alias, not the seam.
type Triple struct {
	Subject   string
	Predicate string
	Object    string
}

// Lower converts an ARM-shaped JSON resource body into triples. Stub:
// it decodes the envelope and emits one (id, hasField, value) triple per
// top-level object field plus an identity triple, refusing malformed JSON
// as a transport (decode) failure. The projection is intentionally
// minimal — the real lowering rules land with lane 11's store.
func Lower(body []byte) ([]Triple, error) {
	var obj map[string]any
	if err := json.Unmarshal(body, &obj); err != nil {
		return nil, api.NewTransport("lower", err, "decode ARM resource body")
	}
	triples := make([]Triple, 0, len(obj)+1)
	id, _ := obj["id"].(string)
	if id == "" {
		return nil, api.NewTransport("lower", nil, "ARM resource body has no id field")
	}
	triples = append(triples, Triple{Subject: id, Predicate: "rdf:type", Object: "arm:Resource"})
	for k, v := range obj {
		if k == "id" {
			continue
		}
		triples = append(triples, Triple{Subject: id, Predicate: "arm:" + k, Object: valueString(v)})
	}
	return triples, nil
}

func valueString(v any) string {
	switch t := v.(type) {
	case string:
		return t
	default:
		b, err := json.Marshal(v)
		if err != nil {
			return ""
		}
		return string(b)
	}
}
