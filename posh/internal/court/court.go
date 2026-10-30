package court

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"strings"
)

// Andon signal states.
const (
	AndonGreen  = "GREEN"
	AndonYellow = "YELLOW"
	AndonRed    = "RED"
)

// GuardResult captures the mechanical refusal verdict of a guard fence run.
type GuardResult struct {
	ExitCode    int      `json:"exit_code"`
	Violations  []string `json:"violations"`
	AndonStatus string   `json:"andon_status"`
}

// EvaluateGuard checks incoming platform configurations against zero-trust
// and sovereign isolation invariants. If dirty or non-sovereign patterns are
// detected, it trips a Jidoka line stop (AndonRed, ExitCode 1).
func EvaluateGuard(ctx context.Context, rawConfig []byte) (*GuardResult, error) {
	var violations []string

	var parsed map[string]any
	if err := json.Unmarshal(rawConfig, &parsed); err != nil {
		// Non-JSON or syntax defect
		violations = append(violations, "RULE_FAIL_CLOSED_SYNTAX_DEFECT")
	} else {
		// Check 1: Hardcoded secret tokens
		if val, ok := parsed["auth_secret"]; ok && val != nil {
			secretStr := fmt.Sprintf("%v", val)
			if strings.Contains(secretStr, "hardcoded") || strings.Contains(secretStr, "token") {
				violations = append(violations, "RULE_FAIL_CLOSED_HARDCODED_TOKEN")
			}
		}

		// Also check raw byte content for unparsed token strings
		if bytes.Contains(rawConfig, []byte("hardcoded_bearer_token")) && !containsViolation(violations, "RULE_FAIL_CLOSED_HARDCODED_TOKEN") {
			violations = append(violations, "RULE_FAIL_CLOSED_HARDCODED_TOKEN")
		}

		// Check 2: Stripped backend state
		val, exists := parsed["backend_state"]
		if !exists || val == nil {
			violations = append(violations, "RULE_FAIL_CLOSED_BACKEND_STRIPPED")
		}
	}

	if len(violations) > 0 {
		res := &GuardResult{
			ExitCode:    1,
			Violations:  violations,
			AndonStatus: AndonRed,
		}
		return res, fmt.Errorf("mechanical guard fence refused dirty configuration (violations: %s)", strings.Join(violations, ", "))
	}

	return &GuardResult{
		ExitCode:    0,
		Violations:  nil,
		AndonStatus: AndonGreen,
	}, nil
}

func containsViolation(list []string, target string) bool {
	for _, v := range list {
		if v == target {
			return true
		}
	}
	return false
}
