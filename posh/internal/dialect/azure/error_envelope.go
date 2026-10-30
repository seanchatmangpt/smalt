// Azure error-envelope spelling (wave-2 lane 13): the posh-owned port of
// Smalt.ArmGateway.Plug.Common.send_arm_error/5
// (lib/smalt/arm_gateway/plug/common.ex:148-176). Key order —
// code, message, target?, details?, innererror — is load-bearing: 40+
// BEAM suites byte-assert refusal templates (wave-1 L2 HIGH row), so the
// dialect renders the same member order via ordered struct fields.
package azure

import (
	"bytes"
	"encoding/json"
)

// ErrorDetails is one ARM error.details row (structured SHACL issue rows
// cross the boundary through this type, never as rendered strings).
type ErrorDetails struct {
	Code     string `json:"code"`
	Message  string `json:"message"`
	Target   string `json:"target,omitempty"`
	Severity string `json:"severity,omitempty"`
}

// ErrorEnvelope is the ARM error body: {"error": {...}} with the exact
// member order the BEAM spelling emits.
type ErrorEnvelope struct {
	Code       string          `json:"code"`
	Message    string          `json:"message"`
	Target     string          `json:"target,omitempty"`
	Details    []ErrorDetails  `json:"details,omitempty"`
	InnerError json.RawMessage `json:"innererror,omitempty"`
}

// ShaclIssue is the STRUCTURED SHACL violation row that crosses the
// posh/BEAM boundary (digest HIGH row: never rendered strings).
type ShaclIssue struct {
	Component  string `json:"component"`
	FocusNode  string `json:"focus_node"`
	ResultPath string `json:"result_path"`
	Severity   string `json:"severity"`
	Message    string `json:"message"`
}

// ToDetails renders ShaclIssue rows as ARM error.details rows — the
// structured crossing.
func ShaclIssuesToDetails(issues []ShaclIssue) []ErrorDetails {
	out := make([]ErrorDetails, 0, len(issues))
	for _, is := range issues {
		out = append(out, ErrorDetails{
			Code:     is.Component,
			Message:  is.Message,
			Target:   is.ResultPath,
			Severity: is.Severity,
		})
	}
	return out
}

// Render renders the full {"error": {...}} body bytes, emitting an
// empty-object innererror when none is set (the BEAM spelling's
// present-but-empty law) and preserving member order.
func (e ErrorEnvelope) Render() []byte {
	if e.InnerError == nil {
		e.InnerError = json.RawMessage("{}")
	}
	inner := struct {
		Error ErrorEnvelope `json:"error"`
	}{Error: e}
	var buf bytes.Buffer
	enc := json.NewEncoder(&buf)
	enc.SetEscapeHTML(false)
	_ = enc.Encode(inner)
	return bytes.TrimRight(buf.Bytes(), "\n")
}
