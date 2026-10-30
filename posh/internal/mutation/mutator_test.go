package mutation

import (
	"context"
	"go/parser"
	"go/token"
	"strings"
	"testing"
	"time"
)

const sampleTargetCode = `package sample

import "errors"

func ValidateBoundaries(x, y int) bool {
	if x > 10 {
		return true
	}
	if y <= 0 {
		return false
	}
	if x == y {
		return true
	}
	return false
}

func CheckPointer(err error) (int, error) {
	if err != nil {
		return 0, err
	}
	return 42, nil
}

func ComputeScore(a, b int, flag bool) int {
	if flag && a > 0 {
		return a + b
	}
	return 0
}
`

func TestScanAST_MutationCategories(t *testing.T) {
	t.Parallel()

	court := NewCourt()
	mutants, err := court.ScanSource("sample.go", []byte(sampleTargetCode))
	if err != nil {
		t.Fatalf("unexpected scan error: %v", err)
	}

	if len(mutants) == 0 {
		t.Fatal("expected discovered mutants, got 0")
	}

	typeCounts := make(map[MutationType]int)
	for _, m := range mutants {
		typeCounts[m.Type]++
	}

	// Verify all requested categories are identified
	if typeCounts[BoundaryFlip] == 0 {
		t.Errorf("expected BoundaryFlip mutants, got 0")
	}
	if typeCounts[NilCheckInversion] == 0 {
		t.Errorf("expected NilCheckInversion mutants, got 0")
	}
	if typeCounts[ReturnValueReplacement] == 0 {
		t.Errorf("expected ReturnValueReplacement mutants, got 0")
	}
	if typeCounts[LogicalSwap] == 0 {
		t.Errorf("expected LogicalSwap mutants, got 0")
	}
	if typeCounts[ArithmeticSwap] == 0 {
		t.Errorf("expected ArithmeticSwap mutants, got 0")
	}

	t.Logf("Discovered %d mutants across categories: %+v", len(mutants), typeCounts)
}

func TestMutateSource_ValidSyntax(t *testing.T) {
	t.Parallel()

	court := NewCourt()
	mutants, err := court.ScanSource("sample.go", []byte(sampleTargetCode))
	if err != nil {
		t.Fatalf("scan error: %v", err)
	}

	fset := token.NewFileSet()
	for _, m := range mutants {
		mutated, err := court.MutateSource([]byte(sampleTargetCode), m)
		if err != nil {
			t.Fatalf("failed to mutate %s (%s): %v", m.ID, m.Description, err)
		}

		// Ensure mutated code is syntactically valid Go
		_, parseErr := parser.ParseFile(fset, "mutated.go", mutated, parser.AllErrors)
		if parseErr != nil {
			t.Fatalf("mutated code for %s is invalid Go syntax: %v\nCode:\n%s", m.ID, parseErr, string(mutated))
		}
	}
}

func TestCourtEvaluate_KilledAndSurvived(t *testing.T) {
	t.Parallel()

	court := NewCourt(
		WithThreshold(0.75),
		WithTimeout(2*time.Second),
	)

	// TestRunner that simulates test suite execution:
	// Kills boundary flips on x > 10, but fails to assert on y <= 0 (allowing mutant to survive).
	runner := func(ctx context.Context, m *Mutant, mutatedSrc []byte) (bool, string, error) {
		// If x > 10 boundary was flipped to >= 10, our test suite catches it:
		if m.Line == 6 && m.Type == BoundaryFlip {
			return false, "assertion failure: boundary check off-by-one", nil
		}

		// If err != nil was inverted to err == nil, our test catches it:
		if m.Type == NilCheckInversion {
			return false, "nil check assertion tripped", nil
		}

		// If return err was swapped to nil, our test catches it:
		if m.Type == ReturnValueReplacement && m.Original == "err" {
			return false, "expected error, got nil", nil
		}

		// If y <= 0 was flipped, our test suite lacks coverage -> SURVIVES!
		if strings.Contains(m.Description, "<=") {
			return true, "all tests passed", nil
		}

		// Default: kills
		return false, "caught by test harness", nil
	}

	report, err := court.Evaluate(context.Background(), "sample.go", []byte(sampleTargetCode), runner)
	if err != nil {
		t.Fatalf("court evaluation failed: %v", err)
	}

	if report.TotalMutants == 0 {
		t.Fatal("expected mutants to be evaluated")
	}

	if report.KilledCount == 0 {
		t.Errorf("expected killed mutants, got 0")
	}

	if report.SurvivedCount == 0 {
		t.Errorf("expected at least 1 survived mutant (uncovered assertion), got 0")
	}

	if report.KillRate <= 0.0 || report.KillRate >= 1.0 {
		t.Errorf("expected kill rate between 0 and 1, got %.2f", report.KillRate)
	}

	t.Logf("Report: Total=%d, Killed=%d, Survived=%d, KillRate=%.2f%%, Valid=%v",
		report.TotalMutants, report.KilledCount, report.SurvivedCount, report.KillRate*100, report.CertifiedValid)
}

func TestCourtEvaluate_TimeoutDetection(t *testing.T) {
	t.Parallel()

	court := NewCourt(
		WithTimeout(10 * time.Millisecond),
		WithMutationTypes(BoundaryFlip),
	)

	slowRunner := func(ctx context.Context, m *Mutant, mutatedSrc []byte) (bool, string, error) {
		select {
		case <-ctx.Done():
			return false, "timeout", ctx.Err()
		case <-time.After(50 * time.Millisecond):
			return true, "done", nil
		}
	}

	report, err := court.Evaluate(context.Background(), "sample.go", []byte(sampleTargetCode), slowRunner)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}

	if report.TimeoutCount == 0 {
		t.Errorf("expected timeouts to be recorded, got 0")
	}
}

func BenchmarkScanAST(b *testing.B) {
	court := NewCourt()
	src := []byte(sampleTargetCode)
	b.ResetTimer()
	for i := 0; i < b.N; i++ {
		_, err := court.ScanSource("sample.go", src)
		if err != nil {
			b.Fatal(err)
		}
	}
}

func BenchmarkMutateSource(b *testing.B) {
	court := NewCourt()
	src := []byte(sampleTargetCode)
	mutants, err := court.ScanSource("sample.go", src)
	if err != nil || len(mutants) == 0 {
		b.Fatalf("failed setup: %v", err)
	}
	target := mutants[0]

	b.ResetTimer()
	for i := 0; i < b.N; i++ {
		_, err := court.MutateSource(src, target)
		if err != nil {
			b.Fatal(err)
		}
	}
}

func BenchmarkCourtEvaluate(b *testing.B) {
	court := NewCourt(WithMutationTypes(BoundaryFlip))
	src := []byte(sampleTargetCode)
	runner := func(ctx context.Context, m *Mutant, mutatedSrc []byte) (bool, string, error) {
		return false, "killed", nil
	}

	b.ResetTimer()
	for i := 0; i < b.N; i++ {
		_, err := court.Evaluate(context.Background(), "sample.go", src, runner)
		if err != nil {
			b.Fatal(err)
		}
	}
}
