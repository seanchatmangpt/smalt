package poshvet

import (
	"go/ast"
	"go/importer"
	"go/parser"
	"go/token"
	"go/types"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"golang.org/x/tools/go/analysis"
	"golang.org/x/tools/go/analysis/passes/inspect"
	"golang.org/x/tools/go/ast/inspector"
)

func TestParseContract(t *testing.T) {
	// 1. Default contract
	cDefault := ParseContract("")
	if !cDefault["TurnstileReceipt"] || !cDefault["Sum256"] {
		t.Fatalf("expected TurnstileReceipt and Sum256 in default contract")
	}

	// 2. Comma separated list
	cList := ParseContract("customOp1, customOp2")
	if !cList["customOp1"] || !cList["customOp2"] || !cList["TurnstileReceipt"] {
		t.Fatalf("expected custom ops merged into contract")
	}

	// 3. File based contract
	tmp := t.TempDir()
	cFile := filepath.Join(tmp, "contract.txt")
	content := "# Zero Alloc Invariants\nfileOp1\n\nfileOp2\n# comment\n"
	if err := os.WriteFile(cFile, []byte(content), 0644); err != nil {
		t.Fatal(err)
	}
	cFromFile := ParseContract(cFile)
	if !cFromFile["fileOp1"] || !cFromFile["fileOp2"] {
		t.Fatalf("expected fileOp1 and fileOp2 loaded from file")
	}
}

func TestZeroAllocCommentTags(t *testing.T) {
	src := `package testpkg

//posh:zeroalloc
func ZeroAllocTagged() {}

//posh:zero-alloc
func ZeroAllocHyphen() {}

// @zeroalloc
func ZeroAllocAt() {}

func UntaggedFunc() {}
`
	fset := token.NewFileSet()
	file, err := parser.ParseFile(fset, "tags.go", src, parser.ParseComments)
	if err != nil {
		t.Fatalf("parse failed: %v", err)
	}

	contract := make(map[string]bool)
	var taggedCount int
	for _, decl := range file.Decls {
		if fn, ok := decl.(*ast.FuncDecl); ok {
			if isZeroAllocFunction(fn, contract) {
				taggedCount++
			}
		}
	}

	if taggedCount != 3 {
		t.Errorf("expected 3 tagged zeroalloc functions, got %d", taggedCount)
	}
}

func runBudgetTestPass(t *testing.T, src string) []string {
	fset := token.NewFileSet()
	file, err := parser.ParseFile(fset, "test.go", src, parser.ParseComments)
	if err != nil {
		t.Fatalf("parse error: %v", err)
	}

	conf := types.Config{
		Importer: importer.Default(),
	}
	info := &types.Info{
		Types: make(map[ast.Expr]types.TypeAndValue),
		Defs:  make(map[*ast.Ident]types.Object),
		Uses:  make(map[*ast.Ident]types.Object),
	}
	pkg, err := conf.Check("testpkg", fset, []*ast.File{file}, info)
	if err != nil {
		t.Fatalf("type check error: %v", err)
	}

	inspectRes := inspector.New([]*ast.File{file})

	var reports []string
	reportFn := func(diag analysis.Diagnostic) {
		reports = append(reports, diag.Message)
	}

	pass := &analysis.Pass{
		Analyzer: BudgetAnalyzer,
		Fset:     fset,
		Files:    []*ast.File{file},
		Pkg:      pkg,
		TypesInfo: info,
		ResultOf: map[*analysis.Analyzer]any{
			inspect.Analyzer: inspectRes,
		},
		Report: reportFn,
	}

	_, err = runBudget(pass)
	if err != nil {
		t.Fatalf("runBudget error: %v", err)
	}

	return reports
}

func TestBudgetViolationsDetection(t *testing.T) {
	src := `package testpkg

import "sync"

var pool sync.Pool

type Result struct {
	val int
}

//posh:zeroalloc
func BadBoxing(b []byte, n int, r Result) {
	pool.Put(b)       // POSHVET-BUDGET-001: slice to interface
	pool.Put(n)       // POSHVET-BUDGET-001: int to interface
	pool.Put(r)       // POSHVET-BUDGET-001: struct to interface
	var _ any = b     // POSHVET-BUDGET-001: assign to interface
}

//posh:zeroalloc
func BadSliceEscapes() []byte {
	s1 := make([]byte, 16)      // POSHVET-BUDGET-002: make([]byte)
	s2 := []byte{1, 2, 3}       // POSHVET-BUDGET-002: slice composite lit
	s3 := append(s1, 4)         // POSHVET-BUDGET-002: append()
	_ = s2
	return s3
}

//posh:zeroalloc
func BadClosure() {
	fn := func() int { return 42 } // POSHVET-BUDGET-003: closure
	_ = fn()
}

//posh:zeroalloc
func GoodZeroAlloc(buf *[64]byte) [32]byte {
	var out [32]byte
	for i := 0; i < 32; i++ {
		out[i] = buf[i] ^ buf[i+32]
	}
	return out
}
`

	reports := runBudgetTestPass(t, src)

	hasBoxing := false
	hasSliceMake := false
	hasSliceLit := false
	hasAppend := false
	hasClosure := false

	for _, msg := range reports {
		if strings.Contains(msg, "POSHVET-BUDGET-001") {
			hasBoxing = true
		}
		if strings.Contains(msg, "POSHVET-BUDGET-002") && strings.Contains(msg, "make()") {
			hasSliceMake = true
		}
		if strings.Contains(msg, "POSHVET-BUDGET-002") && strings.Contains(msg, "composite literal") {
			hasSliceLit = true
		}
		if strings.Contains(msg, "POSHVET-BUDGET-002") && strings.Contains(msg, "append()") {
			hasAppend = true
		}
		if strings.Contains(msg, "POSHVET-BUDGET-003") {
			hasClosure = true
		}
	}

	if !hasBoxing {
		t.Errorf("expected POSHVET-BUDGET-001 interface boxing reports, got %v", reports)
	}
	if !hasSliceMake {
		t.Errorf("expected POSHVET-BUDGET-002 slice make report, got %v", reports)
	}
	if !hasSliceLit {
		t.Errorf("expected POSHVET-BUDGET-002 slice composite lit report, got %v", reports)
	}
	if !hasAppend {
		t.Errorf("expected POSHVET-BUDGET-002 append report, got %v", reports)
	}
	if !hasClosure {
		t.Errorf("expected POSHVET-BUDGET-003 closure report, got %v", reports)
	}

	// Verify GoodZeroAlloc triggered no reports
	for _, msg := range reports {
		if strings.Contains(msg, "GoodZeroAlloc") {
			t.Errorf("unexpected report for GoodZeroAlloc: %s", msg)
		}
	}
}
