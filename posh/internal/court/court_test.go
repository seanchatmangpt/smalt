package court_test

import (
	"context"
	"testing"

	"smalt.dev/posh/internal/court"
)

func TestEvaluateGuard_CleanConfig(t *testing.T) {
	ctx := context.Background()
	clean := []byte(`{"resource_group": "rg-clean", "backend_state": {"storage": "active"}}`)

	res, err := court.EvaluateGuard(ctx, clean)
	if err != nil {
		t.Fatalf("expected clean config to pass, got: %v", err)
	}
	if res.ExitCode != 0 || res.AndonStatus != court.AndonGreen {
		t.Fatalf("expected ExitCode 0 and AndonGreen, got %+v", res)
	}
}

func TestEvaluateGuard_DirtyConfig(t *testing.T) {
	ctx := context.Background()
	dirty := []byte(`{
		"resource_group": "rg-legacy-dirty",
		"auth_secret": "hardcoded_bearer_token_12345",
		"backend_state": null
	}`)

	res, err := court.EvaluateGuard(ctx, dirty)
	if err == nil {
		t.Fatal("expected error on dirty config, got nil")
	}
	if res.ExitCode != 1 {
		t.Fatalf("expected ExitCode 1, got %d", res.ExitCode)
	}
	if res.AndonStatus != court.AndonRed {
		t.Fatalf("expected AndonRed, got %s", res.AndonStatus)
	}
	hasToken := false
	hasBackend := false
	for _, v := range res.Violations {
		if v == "RULE_FAIL_CLOSED_HARDCODED_TOKEN" {
			hasToken = true
		}
		if v == "RULE_FAIL_CLOSED_BACKEND_STRIPPED" {
			hasBackend = true
		}
	}
	if !hasToken || !hasBackend {
		t.Fatalf("expected both token and backend violations, got %v", res.Violations)
	}
}
