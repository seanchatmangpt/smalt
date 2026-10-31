package chicago

// OCEL2Log models the official IEEE OCEL 2.0 JSON standard structure
// compatible with pm4py and wasm4pm-compat.
type OCEL2Log struct {
	GlobalLog   map[string]any       `json:"ocel:globalLog"`
	ObjectTypes []OCELTypeDefinition `json:"objectTypes"`
	EventTypes  []OCELTypeDefinition `json:"eventTypes"`
	Objects     []OCELObject         `json:"objects"`
	Events      []OCELEvent          `json:"events"`

	// Legacy/standard un-prefixed keys for Python jsonocel importer
	LegacyObjectTypes []string `json:"ocel:objectTypes,omitempty"`
	LegacyEventTypes  []string `json:"ocel:eventTypes,omitempty"`
	LegacyObjects     any      `json:"ocel:objects,omitempty"`
	LegacyEvents      any      `json:"ocel:events,omitempty"`
}

type OCELTypeDefinition struct {
	Name       string          `json:"name"`
	Attributes []OCELAttribute `json:"attributes"`
}

type OCELAttribute struct {
	Name string `json:"name"`
	Type string `json:"type"` // "string", "time", "integer", "float", "boolean"
}

type OCELAttrValue struct {
	Name  string `json:"name"`
	Value any    `json:"value"`
	Time  string `json:"time,omitempty"`
}

type OCELRelationship struct {
	ObjectID  string `json:"objectId"`
	Qualifier string `json:"qualifier"`
}

type OCELObject struct {
	ID            string             `json:"id"`
	Type          string             `json:"type"`
	Attributes    []OCELAttrValue    `json:"attributes"`
	Relationships []OCELRelationship `json:"relationships,omitempty"` // O2O topology
}

type OCELEvent struct {
	ID            string             `json:"id"`
	Type          string             `json:"type"`
	Time          string             `json:"time"` // RFC3339 timestamp
	Attributes    []OCELAttrValue    `json:"attributes"`
	Relationships []OCELRelationship `json:"relationships"` // E2O topology
}
