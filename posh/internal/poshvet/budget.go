package poshvet

import (
	"go/ast"
	"go/types"
	"os"
	"strings"

	"golang.org/x/tools/go/analysis"
	"golang.org/x/tools/go/analysis/passes/inspect"
	"golang.org/x/tools/go/ast/inspector"
)

// BudgetAnalyzer enforces escape and allocation budgets for zero-allocation
// critical paths. Functions marked with //posh:zeroalloc, @zeroalloc, or listed
// in a zero-alloc contract are statically analyzed to ensure:
//  1. No interface boxing (convTslice, convTstring, convT64, convTnoptr, convT)
//  2. No slice heap escapes (make([]T), append(), composite slice literals)
//  3. No closure allocations (func literals, escaping closures)
//  4. No goroutine, channel, or map allocations
var BudgetAnalyzer = &analysis.Analyzer{
	Name:     "budget",
	Doc:      "enforces zero-allocation escape budget (no interface boxing, slice escapes, or closure allocations) on zero-alloc functions",
	Requires: []*analysis.Analyzer{inspect.Analyzer},
	Run:      runBudget,
}

var (
	budgetContractFlag string
	maxAllocLimitFlag  int
)

func init() {
	BudgetAnalyzer.Flags.StringVar(
		&budgetContractFlag,
		"contract",
		"",
		"path to zero-alloc contract file or comma-separated function list",
	)
	BudgetAnalyzer.Flags.IntVar(
		&maxAllocLimitFlag,
		"maxalloc",
		0,
		"maximum allowed heap escapes/allocations per function (default 0)",
	)
}

// DefaultZeroAllocContract contains core turnstile receipt functions that must
// maintain a strict 0-heap-allocation invariant under all conditions.
var DefaultZeroAllocContract = map[string]bool{
	"TurnstileReceipt":     true,
	"Sum256":               true,
	"compress":             true,
	"round":                true,
	"permute":              true,
	"g":                    true,
	"wordsToBytes":         true,
	"VerifyTurnstile":      true,
	"MerkleRoot":           true,
	"TurnstileReceiptSIMD": true,
	"CompressSIMD":         true,
}

// ParseContract parses a comma-separated list or newline-separated file of function names.
func ParseContract(contractSpec string) map[string]bool {
	contract := make(map[string]bool)
	for k, v := range DefaultZeroAllocContract {
		contract[k] = v
	}
	if contractSpec == "" {
		return contract
	}

	// Try reading as file first
	if data, err := os.ReadFile(contractSpec); err == nil {
		lines := strings.Split(string(data), "\n")
		for _, line := range lines {
			line = strings.TrimSpace(line)
			if line != "" && !strings.HasPrefix(line, "#") {
				contract[line] = true
			}
		}
		return contract
	}

	// Fallback to comma-separated list
	parts := strings.Split(contractSpec, ",")
	for _, part := range parts {
		part = strings.TrimSpace(part)
		if part != "" {
			contract[part] = true
		}
	}
	return contract
}

func isZeroAllocFunction(fn *ast.FuncDecl, contract map[string]bool) bool {
	if fn == nil || fn.Name == nil {
		return false
	}
	name := fn.Name.Name
	if contract[name] {
		return true
	}
	// Check receiver.Method format if receiver exists
	if fn.Recv != nil && len(fn.Recv.List) > 0 {
		recvType := fn.Recv.List[0].Type
		recvStr := types.ExprString(recvType)
		recvStr = strings.TrimPrefix(recvStr, "*")
		if contract[recvStr+"."+name] {
			return true
		}
	}
	// Check doc comments and preceding line comments
	if fn.Doc != nil {
		for _, comment := range fn.Doc.List {
			text := strings.TrimSpace(comment.Text)
			if strings.Contains(text, "//posh:zeroalloc") ||
				strings.Contains(text, "//posh:zero-alloc") ||
				strings.Contains(text, "@zeroalloc") {
				return true
			}
		}
	}
	return false
}

func runBudget(pass *analysis.Pass) (any, error) {
	contract := ParseContract(budgetContractFlag)
	inspect := pass.ResultOf[inspect.Analyzer].(*inspector.Inspector)

	nodeFilter := []ast.Node{
		(*ast.FuncDecl)(nil),
	}

	inspect.Preorder(nodeFilter, func(n ast.Node) {
		fn, ok := n.(*ast.FuncDecl)
		if !ok || fn.Body == nil {
			return
		}
		if !isZeroAllocFunction(fn, contract) {
			return
		}

		fnName := fn.Name.Name

		ast.Inspect(fn.Body, func(inner ast.Node) bool {
			if inner == nil {
				return true
			}

			switch expr := inner.(type) {
			case *ast.CallExpr:
				checkBudgetCallExpr(pass, fn, fnName, expr)
			case *ast.AssignStmt:
				checkBudgetAssignStmt(pass, fnName, expr)
			case *ast.ReturnStmt:
				checkBudgetReturnStmt(pass, fn, fnName, expr)
			case *ast.CompositeLit:
				checkBudgetCompositeLit(pass, fnName, expr)
			case *ast.FuncLit:
				pass.Reportf(
					expr.Pos(),
					"POSHVET-BUDGET-003: closure allocation (runtime.newobject) in zero-alloc function %s(); function literal escapes to heap",
					fnName,
				)
			case *ast.GoStmt:
				pass.Reportf(
					expr.Pos(),
					"POSHVET-BUDGET-005: goroutine allocation in zero-alloc function %s(); go statement allocates runtime stack and goroutine struct",
					fnName,
				)
			case *ast.SendStmt:
				checkBudgetSendStmt(pass, fnName, expr)
			}
			return true
		})
	})

	return nil, nil
}

func checkBudgetCallExpr(pass *analysis.Pass, fn *ast.FuncDecl, fnName string, call *ast.CallExpr) {
	// 1. Check if call is a builtin (make, new, append)
	if ident, ok := call.Fun.(*ast.Ident); ok {
		if obj := pass.TypesInfo.Uses[ident]; obj != nil && obj.Pkg() == nil {
			switch ident.Name {
			case "make":
				if len(call.Args) > 0 {
					argType := pass.TypesInfo.Types[call.Args[0]].Type
					if isSliceType(argType) {
						pass.Reportf(
							call.Pos(),
							"POSHVET-BUDGET-002: slice heap allocation via make() in zero-alloc function %s(); use fixed stack array [N]T or pre-allocated pooled buffer",
							fnName,
						)
						return
					}
					if isMapType(argType) || isChanType(argType) {
						pass.Reportf(
							call.Pos(),
							"POSHVET-BUDGET-004: heap allocation via make(%s) in zero-alloc function %s(); dynamic allocation disallowed",
							argType.String(),
							fnName,
						)
						return
					}
				}
			case "new":
				pass.Reportf(
					call.Pos(),
					"POSHVET-BUDGET-004: heap allocation via new() in zero-alloc function %s(); use stack value",
					fnName,
				)
				return
			case "append":
				pass.Reportf(
					call.Pos(),
					"POSHVET-BUDGET-002: slice escape/reallocation via append() in zero-alloc function %s(); use fixed-capacity buffer or stack array",
					fnName,
				)
				return
			}
		}
	}

	// 2. Check explicit type conversions to interface: e.g. any(x) or InterfaceType(x)
	callType := pass.TypesInfo.Types[call.Fun]
	if callType.IsType() && isInterfaceType(callType.Type) {
		if len(call.Args) > 0 {
			srcType := pass.TypesInfo.Types[call.Args[0]].Type
			if isBoxing(callType.Type, srcType) {
				pass.Reportf(
					call.Pos(),
					"POSHVET-BUDGET-001: interface boxing (runtime.convT*, heap alloc) in zero-alloc function %s(); converting %s to interface %s",
					fnName,
					srcType.String(),
					callType.Type.String(),
				)
				return
			}
		}
	}

	// 3. Check regular function/method calls for parameter interface boxing
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
		if isBoxing(paramType, argType) {
			pass.Reportf(
				arg.Pos(),
				"POSHVET-BUDGET-001: interface boxing (runtime.convT*, heap alloc) in zero-alloc function %s(); argument %d (%s) boxed into interface %s",
				fnName,
				i+1,
				argType.String(),
				paramType.String(),
			)
		}
	}
}

func checkBudgetAssignStmt(pass *analysis.Pass, fnName string, assign *ast.AssignStmt) {
	for i, rhs := range assign.Rhs {
		if i >= len(assign.Lhs) {
			break
		}
		lhs := assign.Lhs[i]

		lhsType := pass.TypesInfo.Types[lhs].Type
		rhsType := pass.TypesInfo.Types[rhs].Type

		if lhsType == nil || rhsType == nil {
			continue
		}

		if isBoxing(lhsType, rhsType) {
			pass.Reportf(
				rhs.Pos(),
				"POSHVET-BUDGET-001: interface boxing (runtime.convT*, heap alloc) in zero-alloc function %s(); assigning %s to interface %s",
				fnName,
				rhsType.String(),
				lhsType.String(),
			)
		}
	}
}

func checkBudgetReturnStmt(pass *analysis.Pass, fn *ast.FuncDecl, fnName string, ret *ast.ReturnStmt) {
	fnObj := pass.TypesInfo.Defs[fn.Name]
	if fnObj == nil {
		return
	}
	sig, ok := fnObj.Type().(*types.Signature)
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

		if expectedType == nil || actualType == nil {
			continue
		}

		if isBoxing(expectedType, actualType) {
			pass.Reportf(
				result.Pos(),
				"POSHVET-BUDGET-001: interface boxing (runtime.convT*, heap alloc) in zero-alloc function %s(); returning %s as interface %s",
				fnName,
				actualType.String(),
				expectedType.String(),
			)
		}
	}
}

func checkBudgetCompositeLit(pass *analysis.Pass, fnName string, lit *ast.CompositeLit) {
	litType := pass.TypesInfo.Types[lit].Type
	if litType == nil {
		return
	}

	if isSliceType(litType) {
		pass.Reportf(
			lit.Pos(),
			"POSHVET-BUDGET-002: slice heap allocation in zero-alloc function %s(); composite literal %s allocates on heap",
			fnName,
			litType.String(),
		)
		return
	}

	if isMapType(litType) {
		pass.Reportf(
			lit.Pos(),
			"POSHVET-BUDGET-004: map heap allocation in zero-alloc function %s(); composite literal %s allocates on heap",
			fnName,
			litType.String(),
		)
		return
	}
}

func checkBudgetSendStmt(pass *analysis.Pass, fnName string, stmt *ast.SendStmt) {
	chanType := pass.TypesInfo.Types[stmt.Chan].Type
	valType := pass.TypesInfo.Types[stmt.Value].Type
	if chanType == nil || valType == nil {
		return
	}

	if ch, ok := chanType.Underlying().(*types.Chan); ok {
		elemType := ch.Elem()
		if isInterfaceType(elemType) && !isInterfaceType(valType) && !isUntypedNil(valType) {
			pass.Reportf(
				stmt.Value.Pos(),
				"POSHVET-BUDGET-001: interface boxing (runtime.convT*, heap alloc) in zero-alloc function %s(); sending %s to interface channel %s",
				fnName,
				valType.String(),
				elemType.String(),
			)
		}
	}
}

func isUntypedNil(t types.Type) bool {
	if t == nil {
		return false
	}
	b, ok := t.(*types.Basic)
	return ok && b.Kind() == types.UntypedNil
}

func isBoxing(target, src types.Type) bool {
	if !isInterfaceType(target) {
		return false
	}
	if src == nil || isInterfaceType(src) || isPointerType(src) || isUntypedNil(src) {
		return false
	}
	return true
}

func isPointerType(t types.Type) bool {
	if t == nil {
		return false
	}
	_, ok := t.Underlying().(*types.Pointer)
	return ok
}

func isMapType(t types.Type) bool {
	if t == nil {
		return false
	}
	_, ok := t.Underlying().(*types.Map)
	return ok
}

func isChanType(t types.Type) bool {
	if t == nil {
		return false
	}
	_, ok := t.Underlying().(*types.Chan)
	return ok
}
