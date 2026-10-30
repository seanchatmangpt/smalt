package main

import "testing"

// TestDefaultReceiptPathDurable (GAP10(e)): the DEFAULT receipt chain
// location is the durable posh/var/ tree — swept by neither `make clean`
// nor `just posh-clean` (rm -rf tmp/posh). The old tmp/posh path remains
// honored when passed explicitly via -receipts (flag override semantics).
func TestDefaultReceiptPathDurable(t *testing.T) {
	if defaultReceiptsPath != "posh/var/andon.jsonl" {
		t.Fatalf("cmd/andon default -receipts = %q, want posh/var/andon.jsonl", defaultReceiptsPath)
	}
}
