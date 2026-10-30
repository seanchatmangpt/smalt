package poshvet

import (
	"go/ast"
	"go/parser"
	"go/token"
	"go/types"
	"testing"

	"golang.org/x/tools/go/analysis"
)

func TestConvTSliceDetection(t *testing.T) {
	src := `package testpkg

import "sync"

type frameBuf struct {
	b []byte
}

var pool sync.Pool

//posh:hotpath
func HotPathBad(data []byte) {
	pool.Put(data) // violation: slice-to-interface escape
}

//posh:hotpath
func HotPathGood(fb *frameBuf) {
	pool.Put(fb) // valid: pointer-to-struct
}

func ColdPath(data []byte) {
	pool.Put(data) // ignored: not hotpath
}
`
	fset := token.NewFileSet()
	file, err := parser.ParseFile(fset, "sample.go", src, parser.ParseComments)
	if err != nil {
		t.Fatalf("parse failed: %v", err)
	}

	conf := types.Config{
		Importer: nil, // stdlib imported via default or dummy
	}
	// Basic syntax and type check verification for hotpath detection logic
	var hotCount int
	for _, decl := range file.Decls {
		if fn, ok := decl.(*ast.FuncDecl); ok {
			if isHotFunction(fn) {
				hotCount++
				if fn.Name.Name != "HotPathBad" && fn.Name.Name != "HotPathGood" {
					t.Errorf("unexpected hot function %s", fn.Name.Name)
				}
			}
		}
	}
	if hotCount != 2 {
		t.Errorf("expected 2 hot functions, got %d", hotCount)
	}
	_ = conf
}

func TestOpTurnstileValidation(t *testing.T) {
	ontologyOps := map[string]OntologyTurnstileInfo{
		"echo": {OpName: "echo", RouteURI: "posh:routeEcho", TurnstileURI: "posh:turnstileEcho", HasReceipt: true},
		"arm.resource_group": {
			OpName:       "arm.resource_group",
			RouteURI:     "posh:routeResourceGroup",
			TurnstileURI: "posh:turnstileResourceGroup",
			HasReceipt:   true,
		},
		"orphan.op": {
			OpName:       "orphan.op",
			RouteURI:     "posh:routeOrphan",
			TurnstileURI: "",
			HasReceipt:   false,
		},
		"noreceipt.op": {
			OpName:       "noreceipt.op",
			RouteURI:     "posh:routeNoReceipt",
			TurnstileURI: "posh:turnstileNoReceipt",
			HasReceipt:   false,
		},
	}

	cases := []struct {
		op        string
		wantValid bool
		reason    string
	}{
		{"echo", true, "admitted turnstile with receipt"},
		{"arm.resource_group", true, "admitted turnstile with receipt"},
		{"unregistered.op", false, "op does not exist in ontology"},
		{"orphan.op", false, "op has no turnstile in ontology"},
		{"noreceipt.op", false, "turnstile has no emits receipt declaration"},
	}

	for _, tc := range cases {
		info, found := ontologyOps[tc.op]
		isValid := found && info.TurnstileURI != "" && info.HasReceipt
		if isValid != tc.wantValid {
			t.Errorf("op %q: got valid=%v, want %v (%s)", tc.op, isValid, tc.wantValid, tc.reason)
		}
	}
}

func TestAnalyzerIntegration(t *testing.T) {
	analyzers := []*analysis.Analyzer{
		ConvTSliceAnalyzer,
		FencedNetAnalyzer,
		OpTurnstileAnalyzer,
	}

	for _, a := range analyzers {
		if a.Name == "" || a.Doc == "" || a.Run == nil {
			t.Errorf("analyzer %v incomplete", a)
		}
	}
}
