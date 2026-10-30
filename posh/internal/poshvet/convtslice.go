// Package poshvet implements custom go/analysis static analyzers for the
// POSH membrane and Smalt ecosystem.
package poshvet

import (
	"go/ast"
	"go/types"
	"strings"

	"golang.org/x/tools/go/analysis"
	"golang.org/x/tools/go/analysis/passes/inspect"
	"golang.org/x/tools/go/ast/inspector"
)

// ConvTSliceAnalyzer statically bans any slice-to-interface conversion
// (which triggers runtime.convTslice and a 24-byte heap allocation) on hot
// frame processing paths.
var ConvTSliceAnalyzer = &analysis.Analyzer{
	Name:     "convtslice",
	Doc:      "bans runtime.convTslice slice-to-interface escapes on hot frame processing paths",
	Requires: []*analysis.Analyzer{inspect.Analyzer},
	Run:      runConvTSlice,
}

// knownHotFuncs are functions always considered hot path even without comment tags.
var knownHotFuncs = map[string]bool{
	"readFrame":        true,
	"readFramePooled":  true,
	"writeFrame":       true,
	"TurnstileReceipt": true,
	"Sum256":           true,
	"compress":         true,
	"round":            true,
	"VerifyTurnstile":  true,
}

func isHotFunction(fn *ast.FuncDecl) bool {
	if fn == nil || fn.Name == nil {
		return false
	}
	if knownHotFuncs[fn.Name.Name] {
		return true
	}
	if fn.Doc != nil {
		for _, comment := range fn.Doc.List {
			text := strings.TrimSpace(comment.Text)
			if strings.Contains(text, "//posh:hotpath") || strings.Contains(text, "@hotpath") {
				return true
			}
		}
	}
	return false
}

func isSliceType(t types.Type) bool {
	if t == nil {
		return false
	}
	_, ok := t.Underlying().(*types.Slice)
	return ok
}

func isInterfaceType(t types.Type) bool {
	if t == nil {
		return false
	}
	_, ok := t.Underlying().(*types.Interface)
	return ok
}

func runConvTSlice(pass *analysis.Pass) (any, error) {
	inspect := pass.ResultOf[inspect.Analyzer].(*inspector.Inspector)

	nodeFilter := []ast.Node{
		(*ast.FuncDecl)(nil),
	}

	inspect.Preorder(nodeFilter, func(n ast.Node) {
		fn, ok := n.(*ast.FuncDecl)
		if !ok || fn.Body == nil {
			return
		}
		if !isHotFunction(fn) {
			return
		}

		// Inspect inner statements in hot function body
		ast.Inspect(fn.Body, func(inner ast.Node) bool {
			if inner == nil {
				return true
			}

			switch expr := inner.(type) {
			case *ast.CallExpr:
				checkCallExpr(pass, fn, expr)
			case *ast.AssignStmt:
				checkAssignStmt(pass, fn, expr)
			case *ast.ReturnStmt:
				checkReturnStmt(pass, fn, expr)
			}
			return true
		})
	})

	return nil, nil
}

func checkCallExpr(pass *analysis.Pass, fn *ast.FuncDecl, call *ast.CallExpr) {
	callType := pass.TypesInfo.Types[call.Fun]
	sig, ok := callType.Type.(*types.Signature)
	if !ok {
		return
	}

	params := sig.Params()
	numParams := params.Len()
	if numParams == 0 {
		return
	}

	for i, arg := range call.Args {
		var paramType types.Type
		if sig.Variadic() && i >= numParams-1 {
			lastParam := params.At(numParams - 1).Type()
			if slice, ok := lastParam.(*types.Slice); ok {
				paramType = slice.Elem()
			} else {
				paramType = lastParam
			}
		} else if i < numParams {
			paramType = params.At(i).Type()
		} else {
			continue
		}

		argType := pass.TypesInfo.Types[arg].Type
		if argType == nil {
			continue
		}

		// Check if slice is passed to interface param (runtime.convTslice)
		if isInterfaceType(paramType) && isSliceType(argType) {
			pass.Reportf(
				arg.Pos(),
				"POSHVET-001: slice-to-interface escape (runtime.convTslice, 24B heap alloc) in hot path %s(); wrap in pointer struct (e.g. *frameBuf)",
				fn.Name.Name,
			)
		}
	}
}

func checkAssignStmt(pass *analysis.Pass, fn *ast.FuncDecl, assign *ast.AssignStmt) {
	for i, rhs := range assign.Rhs {
		if i >= len(assign.Lhs) {
			break
		}
		lhs := assign.Lhs[i]

		lhsType := pass.TypesInfo.Types[lhs].Type
		rhsType := pass.TypesInfo.Types[rhs].Type

		if isInterfaceType(lhsType) && isSliceType(rhsType) {
			pass.Reportf(
				rhs.Pos(),
				"POSHVET-001: assigning slice to interface causes runtime.convTslice heap alloc in hot path %s(); wrap in pointer struct",
				fn.Name.Name,
			)
		}
	}
}

func checkReturnStmt(pass *analysis.Pass, fn *ast.FuncDecl, ret *ast.ReturnStmt) {
	fnType := pass.TypesInfo.Defs[fn.Name]
	sig, ok := fnType.Type().(*types.Signature)
	if !ok || sig.Results() == nil {
		return
	}

	results := sig.Results()
	for i, result := range ret.Results {
		if i >= results.Len() {
			break
		}
		expectedType := results.At(i).Type()
		actualType := pass.TypesInfo.Types[result].Type

		if isInterfaceType(expectedType) && isSliceType(actualType) {
			pass.Reportf(
				result.Pos(),
				"POSHVET-001: returning slice as interface causes runtime.convTslice heap alloc in hot path %s()",
				fn.Name.Name,
			)
		}
	}
}
