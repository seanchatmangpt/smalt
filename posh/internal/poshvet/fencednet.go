package poshvet

import (
	"go/ast"
	"strings"

	"golang.org/x/tools/go/analysis"
	"golang.org/x/tools/go/analysis/passes/inspect"
	"golang.org/x/tools/go/ast/inspector"
)

// FencedNetAnalyzer statically enforces that all network dialers and HTTP
// clients wire egress.Control / NewFencedTransport, preventing un-fenced
// egress, IMDS SSRF, or allowlist bypasses (POSH-008).
var FencedNetAnalyzer = &analysis.Analyzer{
	Name:     "fencednet",
	Doc:      "enforces that all net.Dialer and http.Client constructions wire egress.Control",
	Requires: []*analysis.Analyzer{inspect.Analyzer},
	Run:      runFencedNet,
}

func runFencedNet(pass *analysis.Pass) (any, error) {
	// Allow internal/egress to define the baseline dialers/clients.
	pkgPath := pass.Pkg.Path()
	if strings.HasSuffix(pkgPath, "/internal/egress") || strings.HasSuffix(pkgPath, "internal/egress") {
		return nil, nil
	}

	inspect := pass.ResultOf[inspect.Analyzer].(*inspector.Inspector)

	nodeFilter := []ast.Node{
		(*ast.CompositeLit)(nil),
		(*ast.SelectorExpr)(nil),
		(*ast.CallExpr)(nil),
	}

	inspect.Preorder(nodeFilter, func(n ast.Node) {
		// Ignore test files for mock servers if needed, but flag production code
		file := pass.Fset.File(n.Pos())
		if file != nil && strings.HasSuffix(file.Name(), "_test.go") {
			return
		}

		switch expr := n.(type) {
		case *ast.CompositeLit:
			checkCompositeLit(pass, expr)
		case *ast.SelectorExpr:
			checkDefaultClientOrTransport(pass, expr)
		case *ast.CallExpr:
			checkPackageHttpCalls(pass, expr)
		}
	})

	return nil, nil
}

func checkCompositeLit(pass *analysis.Pass, lit *ast.CompositeLit) {
	t := pass.TypesInfo.Types[lit].Type
	if t == nil {
		return
	}

	typeStr := t.String()
	// Check net.Dialer
	if typeStr == "net.Dialer" || strings.HasSuffix(typeStr, "/net.Dialer") {
		hasControl := false
		for _, elt := range lit.Elts {
			if kv, ok := elt.(*ast.KeyValueExpr); ok {
				if key, ok := kv.Key.(*ast.Ident); ok && key.Name == "Control" {
					hasControl = true
					break
				}
			}
		}
		if !hasControl {
			pass.Reportf(
				lit.Pos(),
				"POSHVET-002: net.Dialer constructed without Control callback; violates POSH-008 fail-closed egress. Wire egress.Control or use egress.NewFencedTransport",
			)
		}
	}

	// Check http.Client
	if typeStr == "net/http.Client" || strings.HasSuffix(typeStr, "/http.Client") {
		hasTransport := false
		hasCheckRedirect := false
		for _, elt := range lit.Elts {
			if kv, ok := elt.(*ast.KeyValueExpr); ok {
				if key, ok := kv.Key.(*ast.Ident); ok {
					if key.Name == "Transport" {
						hasTransport = true
					}
					if key.Name == "CheckRedirect" {
						hasCheckRedirect = true
					}
				}
			}
		}
		if !hasTransport || !hasCheckRedirect {
			pass.Reportf(
				lit.Pos(),
				"POSHVET-002: raw http.Client constructed without fenced Transport and CheckRedirect; use egress.NewFencedClient(cfg, timeout)",
			)
		}
	}
}

func checkDefaultClientOrTransport(pass *analysis.Pass, sel *ast.SelectorExpr) {
	pkgIdent, ok := sel.X.(*ast.Ident)
	if !ok || pkgIdent.Name != "http" {
		return
	}
	if sel.Sel.Name == "DefaultClient" {
		pass.Reportf(
			sel.Pos(),
			"POSHVET-002: use of unfenced http.DefaultClient violates POSH-008 fail-closed egress; use egress.NewFencedClient",
		)
	} else if sel.Sel.Name == "DefaultTransport" {
		pass.Reportf(
			sel.Pos(),
			"POSHVET-002: use of unfenced http.DefaultTransport violates POSH-008 fail-closed egress; use egress.NewFencedTransport",
		)
	}
}

func checkPackageHttpCalls(pass *analysis.Pass, call *ast.CallExpr) {
	sel, ok := call.Fun.(*ast.SelectorExpr)
	if !ok {
		return
	}
	pkgIdent, ok := sel.X.(*ast.Ident)
	if !ok || pkgIdent.Name != "http" {
		return
	}

	switch sel.Sel.Name {
	case "Get", "Post", "PostForm", "Head":
		pass.Reportf(
			call.Pos(),
			"POSHVET-002: direct unfenced http.%s() bypasses POSH-008 egress fence; use egress.NewFencedClient",
			sel.Sel.Name,
		)
	}
}
