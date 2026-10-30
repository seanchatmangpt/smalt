// Package mutation provides an in-process AST mutation testing court for Go code.
//
// It parses Go source ASTs, discovers candidate mutation sites across multiple
// operator classes (boundary flips, nil-check inversions, return value replacements,
// logical swaps, and arithmetic swaps), synthesizes mutated ASTs, and evaluates
// test suite killing rates to certify non-vacuous assertions.
//
// Principles:
//   - A = μ(O*): Only verified mutations with reproducible AST coordinates are admitted.
//   - Anti-vacuity: A test suite that passes when mutations are injected is vacuous.
//   - Zero disk dependency: All AST mutations and syntheses operate in-memory.
package mutation

import (
	"bytes"
	"context"
	"errors"
	"fmt"
	"go/ast"
	"go/format"
	"go/parser"
	"go/token"
	"strings"
	"sync"
	"time"
)

// MutationType classifies the structural transformation applied to an AST node.
type MutationType string

const (
	// BoundaryFlip flips comparison operators:
	// > to >=, >= to >, < to <=, <= to <, == to !=, != to ==.
	BoundaryFlip MutationType = "boundary_flip"

	// NilCheckInversion inverts nil checks:
	// err != nil to err == nil, x == nil to x != nil.
	NilCheckInversion MutationType = "nil_check_inversion"

	// ReturnValueReplacement alters function return values:
	// return true to return false, return nil to error, return err to return nil.
	ReturnValueReplacement MutationType = "return_value_replacement"

	// LogicalSwap swaps boolean conjunction and disjunction:
	// && to ||, || to &&.
	LogicalSwap MutationType = "logical_swap"

	// ArithmeticSwap swaps basic arithmetic operations:
	// + to -, - to +, * to /, / to *.
	ArithmeticSwap MutationType = "arithmetic_swap"
)

// Mutant describes a concrete mutation site identified in an AST.
type Mutant struct {
	ID          string       `json:"id"`
	Type        MutationType `json:"type"`
	File        string       `json:"file"`
	Line        int          `json:"line"`
	Column      int          `json:"column"`
	Original    string       `json:"original"`
	Replacement string       `json:"replacement"`
	Description string       `json:"description"`

	// nodePos tracks the exact byte offset in the source FileSet.
	nodePos token.Pos
	// opPos tracks the exact operator position where applicable.
	opPos token.Pos
}

// OutcomeStatus defines the outcome of evaluating a mutant against a test runner.
type OutcomeStatus string

const (
	// StatusKilled indicates the test suite failed on the mutant (desirable: test is non-vacuous).
	StatusKilled OutcomeStatus = "KILLED"

	// StatusSurvived indicates the test suite passed despite the mutant (defect: vacuous test).
	StatusSurvived OutcomeStatus = "SURVIVED"

	// StatusErrored indicates the mutated AST failed compilation, parsing, or panicked.
	StatusErrored OutcomeStatus = "ERRORED"

	// StatusTimeout indicates the test suite exceeded its evaluation deadline.
	StatusTimeout OutcomeStatus = "TIMEOUT"
)

// MutantResult records the evaluation outcome for an individual mutant.
type MutantResult struct {
	Mutant   *Mutant       `json:"mutant"`
	Status   OutcomeStatus `json:"status"`
	Details  string        `json:"details,omitempty"`
	Duration time.Duration `json:"duration_ns"`
}

// CourtReport summarizes the mutation testing court findings.
type CourtReport struct {
	TotalMutants     int            `json:"total_mutants"`
	KilledCount      int            `json:"killed_count"`
	SurvivedCount    int            `json:"survived_count"`
	ErroredCount     int            `json:"errored_count"`
	TimeoutCount     int            `json:"timeout_count"`
	KillRate         float64        `json:"kill_rate"`
	Threshold        float64        `json:"threshold"`
	CertifiedVacuous bool           `json:"certified_vacuous"` // true if kill rate < threshold
	CertifiedValid   bool           `json:"certified_valid"`   // true if kill rate >= threshold
	TotalDuration    time.Duration  `json:"total_duration_ns"`
	Results          []MutantResult `json:"results"`
}

// TestRunner is a function invoked by the court to evaluate a mutated source code.
// Returning an error or passed=false signifies that the test failed, killing the mutant.
type TestRunner func(ctx context.Context, m *Mutant, mutatedSrc []byte) (passed bool, details string, err error)

// Court manages mutation scanning, code synthesis, and test suite execution.
type Court struct {
	mu           sync.Mutex
	threshold    float64
	timeout      time.Duration
	enabledTypes map[MutationType]bool
}

// Option configures the Court.
type Option func(*Court)

// WithThreshold sets the minimum kill rate required for test suite certification (default 0.80).
func WithThreshold(t float64) Option {
	return func(c *Court) {
		if t < 0.0 {
			t = 0.0
		}
		if t > 1.0 {
			t = 1.0
		}
		c.threshold = t
	}
}

// WithTimeout sets the maximum duration permitted per mutant test run (default 5s).
func WithTimeout(d time.Duration) Option {
	return func(c *Court) {
		if d > 0 {
			c.timeout = d
		}
	}
}

// WithMutationTypes restricts the court to only the specified mutation categories.
func WithMutationTypes(types ...MutationType) Option {
	return func(c *Court) {
		c.enabledTypes = make(map[MutationType]bool)
		for _, t := range types {
			c.enabledTypes[t] = true
		}
	}
}

// NewCourt initializes an AST Mutation Testing Court with default settings.
func NewCourt(opts ...Option) *Court {
	c := &Court{
		threshold: 0.80,
		timeout:   5 * time.Second,
		enabledTypes: map[MutationType]bool{
			BoundaryFlip:           true,
			NilCheckInversion:      true,
			ReturnValueReplacement: true,
			LogicalSwap:            true,
			ArithmeticSwap:         true,
		},
	}
	for _, opt := range opts {
		opt(c)
	}
	return c
}

// ScanSource parses Go source code and returns all identified candidate mutants.
func (c *Court) ScanSource(filename string, src []byte) ([]*Mutant, error) {
	fset := token.NewFileSet()
	file, err := parser.ParseFile(fset, filename, src, parser.ParseComments)
	if err != nil {
		return nil, fmt.Errorf("mutation: failed to parse source %q: %w", filename, err)
	}
	return c.ScanAST(fset, file)
}

// ScanAST inspects a parsed AST and identifies candidate mutation points.
func (c *Court) ScanAST(fset *token.FileSet, file *ast.File) ([]*Mutant, error) {
	c.mu.Lock()
	defer c.mu.Unlock()

	var mutants []*Mutant
	counter := 1

	ast.Inspect(file, func(n ast.Node) bool {
		if n == nil {
			return false
		}

		// 1. Binary Expressions (Comparisons, Nil-checks, Logical, Arithmetic)
		if binExpr, ok := n.(*ast.BinaryExpr); ok {
			pos := fset.Position(binExpr.OpPos)

			// Check for nil comparisons first
			if isNilCheck(binExpr) {
				if c.enabledTypes[NilCheckInversion] {
					newOp, desc := invertNilCheck(binExpr.Op)
					if newOp != token.ILLEGAL {
						mutants = append(mutants, &Mutant{
							ID:          fmt.Sprintf("MUT-%04d", counter),
							Type:        NilCheckInversion,
							File:        pos.Filename,
							Line:        pos.Line,
							Column:      pos.Column,
							Original:    binExpr.Op.String(),
							Replacement: newOp.String(),
							Description: desc,
							nodePos:     binExpr.Pos(),
							opPos:       binExpr.OpPos,
						})
						counter++
					}
				}
				return true
			}

			// Boundary flips (<, <=, >, >=, ==, !=)
			if isComparisonOp(binExpr.Op) {
				if c.enabledTypes[BoundaryFlip] {
					newOp, desc := flipBoundary(binExpr.Op)
					if newOp != token.ILLEGAL {
						mutants = append(mutants, &Mutant{
							ID:          fmt.Sprintf("MUT-%04d", counter),
							Type:        BoundaryFlip,
							File:        pos.Filename,
							Line:        pos.Line,
							Column:      pos.Column,
							Original:    binExpr.Op.String(),
							Replacement: newOp.String(),
							Description: desc,
							nodePos:     binExpr.Pos(),
							opPos:       binExpr.OpPos,
						})
						counter++
					}
				}
				return true
			}

			// Logical operators (&&, ||)
			if binExpr.Op == token.LAND || binExpr.Op == token.LOR {
				if c.enabledTypes[LogicalSwap] {
					newOp := token.LOR
					if binExpr.Op == token.LOR {
						newOp = token.LAND
					}
					mutants = append(mutants, &Mutant{
						ID:          fmt.Sprintf("MUT-%04d", counter),
						Type:        LogicalSwap,
						File:        pos.Filename,
						Line:        pos.Line,
						Column:      pos.Column,
						Original:    binExpr.Op.String(),
						Replacement: newOp.String(),
						Description: fmt.Sprintf("swap logical operator %s to %s", binExpr.Op, newOp),
						nodePos:     binExpr.Pos(),
						opPos:       binExpr.OpPos,
					})
					counter++
				}
				return true
			}

			// Arithmetic operators (+, -, *, /)
			if isArithmeticOp(binExpr.Op) {
				if c.enabledTypes[ArithmeticSwap] {
					newOp, desc := swapArithmetic(binExpr.Op)
					if newOp != token.ILLEGAL {
						mutants = append(mutants, &Mutant{
							ID:          fmt.Sprintf("MUT-%04d", counter),
							Type:        ArithmeticSwap,
							File:        pos.Filename,
							Line:        pos.Line,
							Column:      pos.Column,
							Original:    binExpr.Op.String(),
							Replacement: newOp.String(),
							Description: desc,
							nodePos:     binExpr.Pos(),
							opPos:       binExpr.OpPos,
						})
						counter++
					}
				}
				return true
			}
		}

		// 2. Return Statements (Boolean literals, Nil/Error swaps, Numeric literals)
		if retStmt, ok := n.(*ast.ReturnStmt); ok {
			if !c.enabledTypes[ReturnValueReplacement] {
				return true
			}
			for i, res := range retStmt.Results {
				pos := fset.Position(res.Pos())

				// Boolean return: true -> false, false -> true
				if ident, isIdent := res.(*ast.Ident); isIdent {
					if ident.Name == "true" || ident.Name == "false" {
						replacement := "false"
						if ident.Name == "false" {
							replacement = "true"
						}
						mutants = append(mutants, &Mutant{
							ID:          fmt.Sprintf("MUT-%04d", counter),
							Type:        ReturnValueReplacement,
							File:        pos.Filename,
							Line:        pos.Line,
							Column:      pos.Column,
							Original:    ident.Name,
							Replacement: replacement,
							Description: fmt.Sprintf("invert return boolean %s to %s at result[%d]", ident.Name, replacement, i),
							nodePos:     res.Pos(),
							opPos:       res.Pos(),
						})
						counter++
						continue
					}

					// Swallow error: return err -> return nil
					if isErrorIdentifier(ident.Name) {
						mutants = append(mutants, &Mutant{
							ID:          fmt.Sprintf("MUT-%04d", counter),
							Type:        ReturnValueReplacement,
							File:        pos.Filename,
							Line:        pos.Line,
							Column:      pos.Column,
							Original:    ident.Name,
							Replacement: "nil",
							Description: fmt.Sprintf("swallow error: replace %s with nil at result[%d]", ident.Name, i),
							nodePos:     res.Pos(),
							opPos:       res.Pos(),
						})
						counter++
						continue
					}

					// Nil error to synthesized error
					if ident.Name == "nil" {
						mutants = append(mutants, &Mutant{
							ID:          fmt.Sprintf("MUT-%04d", counter),
							Type:        ReturnValueReplacement,
							File:        pos.Filename,
							Line:        pos.Line,
							Column:      pos.Column,
							Original:    "nil",
							Replacement: "errors.New(\"mutation: injected fault\")",
							Description: fmt.Sprintf("replace return nil with synthetic error at result[%d]", i),
							nodePos:     res.Pos(),
							opPos:       res.Pos(),
						})
						counter++
						continue
					}
				}

				// Integer return: 0 -> 1, N -> 0
				if lit, isLit := res.(*ast.BasicLit); isLit && lit.Kind == token.INT {
					replacement := "1"
					if lit.Value != "0" {
						replacement = "0"
					}
					mutants = append(mutants, &Mutant{
						ID:          fmt.Sprintf("MUT-%04d", counter),
						Type:        ReturnValueReplacement,
						File:        pos.Filename,
						Line:        pos.Line,
						Column:      pos.Column,
						Original:    lit.Value,
						Replacement: replacement,
						Description: fmt.Sprintf("replace return int %s with %s at result[%d]", lit.Value, replacement, i),
						nodePos:     res.Pos(),
						opPos:       res.Pos(),
					})
					counter++
					continue
				}
			}
		}

		return true
	})

	return mutants, nil
}

// MutateSource takes Go source code and applies a single mutant, returning the mutated source bytes.
func (c *Court) MutateSource(src []byte, mutant *Mutant) ([]byte, error) {
	fset := token.NewFileSet()
	file, err := parser.ParseFile(fset, mutant.File, src, parser.ParseComments)
	if err != nil {
		return nil, fmt.Errorf("mutation: failed to parse source for mutation: %w", err)
	}

	applied := false
	ast.Inspect(file, func(n ast.Node) bool {
		if n == nil || applied {
			return false
		}

		// Mutate Binary Expression
		if binExpr, ok := n.(*ast.BinaryExpr); ok {
			pos := fset.Position(binExpr.OpPos)
			if pos.Line == mutant.Line && pos.Column == mutant.Column {
				newOp := parseToken(mutant.Replacement)
				if newOp != token.ILLEGAL {
					binExpr.Op = newOp
					applied = true
					return false
				}
			}
		}

		// Mutate Return Statement Expressions
		if retStmt, ok := n.(*ast.ReturnStmt); ok {
			for i, res := range retStmt.Results {
				pos := fset.Position(res.Pos())
				if pos.Line == mutant.Line && pos.Column == mutant.Column {
					switch mutant.Type {
					case ReturnValueReplacement:
						if mutant.Replacement == "true" || mutant.Replacement == "false" || mutant.Replacement == "nil" {
							retStmt.Results[i] = ast.NewIdent(mutant.Replacement)
							applied = true
							return false
						} else if strings.HasPrefix(mutant.Replacement, "errors.New") {
							retStmt.Results[i] = &ast.CallExpr{
								Fun: &ast.SelectorExpr{
									X:   ast.NewIdent("errors"),
									Sel: ast.NewIdent("New"),
								},
								Args: []ast.Expr{
									&ast.BasicLit{
										Kind:  token.STRING,
										Value: `"mutation: injected fault"`,
									},
								},
							}
							applied = true
							return false
						} else {
							// Basic literal (e.g. integer)
							retStmt.Results[i] = &ast.BasicLit{
								Kind:  token.INT,
								Value: mutant.Replacement,
							}
							applied = true
							return false
						}
					}
				}
			}
		}

		return true
	})

	if !applied {
		return nil, fmt.Errorf("mutation: could not locate AST node at %s:%d:%d for mutant %s",
			mutant.File, mutant.Line, mutant.Column, mutant.ID)
	}

	var buf bytes.Buffer
	if err := format.Node(&buf, fset, file); err != nil {
		return nil, fmt.Errorf("mutation: failed to format mutated AST: %w", err)
	}

	return buf.Bytes(), nil
}

// Evaluate runs all discovered mutants against the provided TestRunner and calculates the kill rate.
func (c *Court) Evaluate(ctx context.Context, filename string, src []byte, runner TestRunner) (*CourtReport, error) {
	mutants, err := c.ScanSource(filename, src)
	if err != nil {
		return nil, err
	}

	report := &CourtReport{
		TotalMutants: len(mutants),
		Threshold:    c.threshold,
		Results:      make([]MutantResult, 0, len(mutants)),
	}

	start := time.Now()

	for _, m := range mutants {
		select {
		case <-ctx.Done():
			return nil, ctx.Err()
		default:
		}

		mStart := time.Now()
		mutatedCode, err := c.MutateSource(src, m)
		if err != nil {
			report.ErroredCount++
			report.Results = append(report.Results, MutantResult{
				Mutant:   m,
				Status:   StatusErrored,
				Details:  fmt.Sprintf("synthesis error: %v", err),
				Duration: time.Since(mStart),
			})
			continue
		}

		// Run in bounded sub-context
		subCtx, cancel := context.WithTimeout(ctx, c.timeout)
		passed, details, runErr := runner(subCtx, m, mutatedCode)
		cancel()

		mDuration := time.Since(mStart)

		if errors.Is(subCtx.Err(), context.DeadlineExceeded) {
			report.TimeoutCount++
			report.Results = append(report.Results, MutantResult{
				Mutant:   m,
				Status:   StatusTimeout,
				Details:  "test suite timed out on mutant",
				Duration: mDuration,
			})
			continue
		}

		if runErr != nil || !passed {
			// Test suite detected the fault! Mutant is KILLED.
			report.KilledCount++
			report.Results = append(report.Results, MutantResult{
				Mutant:   m,
				Status:   StatusKilled,
				Details:  details,
				Duration: mDuration,
			})
		} else {
			// Test suite passed despite mutation! Mutant SURVIVED (vacuous test assertion).
			report.SurvivedCount++
			report.Results = append(report.Results, MutantResult{
				Mutant:   m,
				Status:   StatusSurvived,
				Details:  "test suite passed on mutant: non-killing assertion defect",
				Duration: mDuration,
			})
		}
	}

	report.TotalDuration = time.Since(start)

	viable := report.KilledCount + report.SurvivedCount
	if viable > 0 {
		report.KillRate = float64(report.KilledCount) / float64(viable)
	} else {
		report.KillRate = 0.0
	}

	report.CertifiedValid = report.KillRate >= report.Threshold && report.TotalMutants > 0
	report.CertifiedVacuous = !report.CertifiedValid

	return report, nil
}

// -------------------------------------------------------------------------
// AST Traversal & Transformation Helpers
// -------------------------------------------------------------------------

func isNilCheck(bin *ast.BinaryExpr) bool {
	if bin.Op != token.EQL && bin.Op != token.NEQ {
		return false
	}
	return isNilIdent(bin.X) || isNilIdent(bin.Y)
}

func isNilIdent(expr ast.Expr) bool {
	if ident, ok := expr.(*ast.Ident); ok {
		return ident.Name == "nil"
	}
	return false
}

func invertNilCheck(op token.Token) (token.Token, string) {
	if op == token.NEQ {
		return token.EQL, "invert nil check != to =="
	}
	if op == token.EQL {
		return token.NEQ, "invert nil check == to !="
	}
	return token.ILLEGAL, ""
}

func isComparisonOp(op token.Token) bool {
	switch op {
	case token.GTR, token.GEQ, token.LSS, token.LEQ, token.EQL, token.NEQ:
		return true
	default:
		return false
	}
}

func flipBoundary(op token.Token) (token.Token, string) {
	switch op {
	case token.GTR:
		return token.GEQ, "flip boundary > to >="
	case token.GEQ:
		return token.GTR, "flip boundary >= to >"
	case token.LSS:
		return token.LEQ, "flip boundary < to <="
	case token.LEQ:
		return token.LSS, "flip boundary <= to <"
	case token.EQL:
		return token.NEQ, "flip equality == to !="
	case token.NEQ:
		return token.EQL, "flip inequality != to =="
	default:
		return token.ILLEGAL, ""
	}
}

func isArithmeticOp(op token.Token) bool {
	switch op {
	case token.ADD, token.SUB, token.MUL, token.QUO:
		return true
	default:
		return false
	}
}

func swapArithmetic(op token.Token) (token.Token, string) {
	switch op {
	case token.ADD:
		return token.SUB, "swap arithmetic + to -"
	case token.SUB:
		return token.ADD, "swap arithmetic - to +"
	case token.MUL:
		return token.QUO, "swap arithmetic * to /"
	case token.QUO:
		return token.MUL, "swap arithmetic / to *"
	default:
		return token.ILLEGAL, ""
	}
}

func isErrorIdentifier(name string) bool {
	return name == "err" || strings.HasSuffix(name, "Err") || strings.HasSuffix(name, "Error")
}

func parseToken(s string) token.Token {
	switch s {
	case "==":
		return token.EQL
	case "!=":
		return token.NEQ
	case ">":
		return token.GTR
	case ">=":
		return token.GEQ
	case "<":
		return token.LSS
	case "<=":
		return token.LEQ
	case "&&":
		return token.LAND
	case "||":
		return token.LOR
	case "+":
		return token.ADD
	case "-":
		return token.SUB
	case "*":
		return token.MUL
	case "/":
		return token.QUO
	default:
		return token.ILLEGAL
	}
}
