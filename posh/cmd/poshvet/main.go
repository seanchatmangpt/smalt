// Command poshvet is the static safety analyzer for the POSH membrane
// and Smalt ecosystem. It runs as a go/analysis multichecker or can be invoked
// directly via `go vet -vettool=./bin/poshvet ./...`.
package main

import (
	"golang.org/x/tools/go/analysis/multichecker"

	"smalt.dev/posh/internal/poshvet"
)

func main() {
	multichecker.Main(
		poshvet.ConvTSliceAnalyzer,
		poshvet.FencedNetAnalyzer,
		poshvet.OpTurnstileAnalyzer,
		poshvet.BudgetAnalyzer,
	)
}
