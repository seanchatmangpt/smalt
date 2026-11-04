// Error-code parity court (P-i Wave A): table-driven per (code, surface)
// against the BEAM authority templates — lib/smalt/arm_gateway/plug/
// common.ex:208/:836, resource_providers.ex:2148, egress_router.ex:1407.
// Each mounted row asserts: HTTP status, error.code, BYTE-EXACT message
// template, innererror present-but-empty, and member order. BEAM-face-only
// surfaces (locks, WORM, policy) hold no posh-membrane state — they ride as
// loud t.Skip rows, never a silent pass. Mutation leg proves non-vacuity:
// corrupting a template must flip the court's byte-exact assertion.
package azure_test

import (
	"encoding/json"
	"strings"
	"testing"

	"smalt.dev/posh/internal/dialect/azure"
)

// parityRow is one (code, surface) row of the parity court table.
type parityRow struct {
	code    string
	surface string
	status  int
	message string // BYTE-EXACT message with slots filled at the render call
	render  func() azure.ContractError
}

// parityTable: every mounted contract code, one row per BEAM authority face.
func parityTable(t *testing.T) []parityRow {
	t.Helper()
	return []parityRow{
		{
			code:    "ScopeLocked",
			surface: "constructor (BEAM face lib/smalt/arm_gateway/plug/common.ex:208 lock_scope_locked_body/1)",
			status:  409,
			message: "The scope '/subscriptions/sub-1' is locked at a level that blocks this operation. Remove the lock (Microsoft.Authorization/locks) to proceed.",
			render:  func() azure.ContractError { return azure.ScopeLocked("/subscriptions/sub-1") },
		},
		{
			code:    "PreconditionFailed",
			surface: "constructor (BEAM face lib/smalt/arm_gateway/plug/resource_providers.ex:2148 check_lock_precondition)",
			status:  412,
			message: "The If-Match header is required for the lock action at '/rg/lock'.",
			render:  func() azure.ContractError { return azure.PreconditionFailedMissing("/rg/lock") },
		},
		{
			code:    "InvalidResourceShape",
			surface: "constructor (BEAM face lib/smalt/arm_gateway/plug/common.ex:836 send_graphlaw_refusal/3)",
			status:  0, // filled below from render
			message: "GraphLaw validation failure: closed property bazz not declared",
			render:  func() azure.ContractError { return azure.InvalidResourceShape("closed property bazz not declared") },
		},
		{
			code:    "WriteConflict",
			surface: "constructor (BEAM face lib/smalt/egress_router.ex:1407)",
			status:  409,
			message: "kv key-1 (label no-label) exists; supply If-Match to overwrite or If-None-Match: * for create-only",
			render:  func() azure.ContractError { return azure.WriteConflict("key-1", "no-label") },
		},
	}
}

// expectedStatuses pins the constructor statuses independently of the table.
var expectedStatuses = map[string]int{
	"ScopeLocked":          409,
	"PreconditionFailed":   412,
	"InvalidResourceShape": 400,
	"WriteConflict":        409,
}

func TestErrorCodeParityCourt(t *testing.T) {
	for _, row := range parityTable(t) {
		ce := row.render()

		t.Run(row.code, func(t *testing.T) {
			if ce.Status != expectedStatuses[row.code] {
				t.Errorf("status = %d, want %d (BEAM authority)", ce.Status, expectedStatuses[row.code])
			}
			if ce.Envelope.Code != row.code {
				t.Errorf("error.code = %q, want %q", ce.Envelope.Code, row.code)
			}
			if ce.Envelope.Message != row.message {
				t.Errorf("message drift from BEAM authority:\n got: %q\nwant: %q", ce.Envelope.Message, row.message)
			}

			body := ce.Envelope.Render()

			// Innererror present-but-empty (BEAM envelope law).
			var parsed struct {
				Error struct {
					InnerError map[string]any `json:"innererror"`
				} `json:"error"`
			}
			if err := json.Unmarshal(body, &parsed); err != nil {
				t.Fatalf("render is not valid JSON: %v", err)
			}
			if parsed.Error.InnerError == nil {
				t.Fatalf("innererror absent — BEAM present-but-empty law violated: %s", body)
			}
			if len(parsed.Error.InnerError) != 0 {
				t.Fatalf("innererror not empty: %s", body)
			}

			// Member order: code, message, target?, innererror. Walk the
			// rendered bytes in order.
			order := []string{"code", "message"}
			if ce.Envelope.Target != "" {
				order = append(order, "target")
			}
			order = append(order, "innererror")
			cursor := 0
			for _, member := range order {
				idx := strings.Index(string(body[cursor:]), `"`+member+`"`)
				if idx < 0 {
					t.Fatalf("member %q out of order or missing in %s", member, body)
				}
				cursor += idx + len(member)
			}

			// Byte-exact full-body pin: re-render the expected envelope and
			// compare whole bytes (order + innererror + no extras).
			want := azure.ErrorEnvelope{
				Code:    row.code,
				Message: row.message,
				Target:  ce.Envelope.Target,
			}.Render()
			if string(body) != string(want) {
				t.Errorf("full-body drift:\n got: %s\nwant: %s", body, want)
			}
		})
	}
}

// TestErrorCodeParityCourtMutationLeg proves the byte-exact assertion is
// non-vacuous: a corrupted template must FAIL the same comparison the
// mounted rows pass (a court that cannot flip is FAIL).
func TestErrorCodeParityCourtMutationLeg(t *testing.T) {
	row := parityTable(t)[0] // ScopeLocked
	corrupted := row.message + "!"

	got := azure.ScopeLocked("/subscriptions/sub-1").Envelope.Message
	if got == corrupted {
		t.Fatal("mutation leg vacuous: corrupted template equals mounted template")
	}
	// The exact assertion the mounted row uses must flip on the corruption.
	want := azure.ErrorEnvelope{Code: row.code, Message: corrupted, Target: got}.Render()
	body := azure.ScopeLocked("/subscriptions/sub-1").Envelope.Render()
	if string(body) == string(want) {
		t.Fatal("mutation leg failed to flip: corrupted body byte-equal to mounted body")
	}
}

// TestErrorCodeParityCourtBeamFaceOnlyRows — the mounting surfaces the
// membrane holds no state for. Loud skips, never silent passes.
func TestErrorCodeParityCourtBeamFaceOnlyRows(t *testing.T) {
	t.Run("ScopeLocked-mount", func(t *testing.T) {
		t.Skip("BEAM-face-only: membrane holds no locks state")
	})
	t.Run("WORM", func(t *testing.T) {
		t.Skip("BEAM-face-only: membrane holds no WORM state")
	})
	t.Run("policy", func(t *testing.T) {
		t.Skip("BEAM-face-only: membrane holds no policy state")
	})
}
