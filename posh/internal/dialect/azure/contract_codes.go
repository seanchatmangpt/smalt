// Typed contract error codes (P-i Wave A): the posh-owned port of the
// BEAM contract refusal faces. Message templates are BYTE-COPIED from the
// BEAM authority — do not reword:
//
//	ScopeLocked            lib/smalt/arm_gateway/plug/common.ex:208 (lock_scope_locked_body/1)
//	PreconditionFailed     lib/smalt/arm_gateway/plug/resource_providers.ex:2148 (check_lock_precondition)
//	InvalidResourceShape   lib/smalt/arm_gateway/plug/common.ex:836 (send_graphlaw_refusal/3)
//	WriteConflict          lib/smalt/egress_router.ex:1407
//
// Every constructor renders through ErrorEnvelope.Render(), so each body
// carries the BEAM envelope law: code, message, target?, innererror
// present-but-empty. The BEAM PreconditionFailed/WriteConflict sites are
// inline send_json bodies without innererror; the posh envelope law
// renders the present-but-empty innererror on all four (superset, P-i
// Wave A decision) — the parity court pins this per row.
package azure

import "fmt"

// ContractError couples the HTTP status with the ARM error envelope for
// one contract refusal.
type ContractError struct {
	Status   int
	Envelope ErrorEnvelope
}

// ScopeLocked is the 409 face for a scope covered by a blocking lock
// (KD-113 leg b).
func ScopeLocked(scopeID string) ContractError {
	return ContractError{
		Status: 409,
		Envelope: ErrorEnvelope{
			Code:    "ScopeLocked",
			Message: fmt.Sprintf("The scope '%s' is locked at a level that blocks this operation. Remove the lock (Microsoft.Authorization/locks) to proceed.", scopeID),
			Target:  scopeID,
		},
	}
}

// PreconditionFailedMissing is the 412 face for a missing If-Match
// precondition (the azapi lock-action law).
func PreconditionFailedMissing(path string) ContractError {
	return ContractError{
		Status: 412,
		Envelope: ErrorEnvelope{
			Code:    "PreconditionFailed",
			Message: fmt.Sprintf("The If-Match header is required for the lock action at '%s'.", path),
		},
	}
}

// InvalidResourceShape is the 400 GraphLaw refusal face (ARM never
// returns 422 — PINNED decision, common.ex:182).
func InvalidResourceShape(reason string) ContractError {
	return ContractError{
		Status: 400,
		Envelope: ErrorEnvelope{
			Code:    "InvalidResourceShape",
			Message: fmt.Sprintf("GraphLaw validation failure: %s", reason),
			Target:  "AshGraphLaw.Enforcement",
		},
	}
}

// WriteConflict is the 409 face for exists-without-If-Match
// (egress_router KV CAS law).
func WriteConflict(key, label string) ContractError {
	return ContractError{
		Status: 409,
		Envelope: ErrorEnvelope{
			Code:    "WriteConflict",
			Message: fmt.Sprintf("kv %s (label %s) exists; supply If-Match to overwrite or If-None-Match: * for create-only", key, label),
		},
	}
}
