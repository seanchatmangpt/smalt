// GAP-01 classification court: asserts the dialect-#0 classification
// shard (sts.go) against the GAP-01 verdict.
package azure

import (
	"strings"
	"testing"
)

func TestSTSDialect0Classification(t *testing.T) {
	if STSDialect != 0 {
		t.Fatalf("STSDialect = %d, want 0", STSDialect)
	}
	if !STSFaceClassifiesDialect0 {
		t.Fatal("STS face must classify dialect #0")
	}
	if !STSAuthorityIsSovereign {
		t.Fatal("STS authority must stay sovereign in smalt")
	}
}

func TestSTSMigrationTable(t *testing.T) {
	if len(stsMigrationTable) != 10 {
		t.Fatalf("rows = %d, want 10", len(stsMigrationTable))
	}
	okClass := map[string]bool{"azure-dialect": true, "sovereign": true, "neutral-core": true}
	okMig := map[string]bool{
		"stays-smalt-byte-identical":                     true,
		"stays-smalt":                                    true,
		"already-posh-court-side":                        true,
		"new-work-core-level (CC-3, charter item, OPEN)": true,
	}
	for _, r := range stsMigrationTable {
		if r.item == "" || r.location == "" || r.classification == "" || r.migration == "" {
			t.Fatalf("row %+v: empty field", r)
		}
		if !okClass[r.classification] {
			t.Fatalf("row %s: bad classification %q", r.item, r.classification)
		}
		if !okMig[r.migration] {
			t.Fatalf("row %s: bad migration %q", r.item, r.migration)
		}
	}
	// posh carries no STS surface: no row may locate STS code under posh.
	for _, r := range stsMigrationTable {
		if strings.Contains(r.location, "posh/") {
			t.Fatalf("row %s: STS surface located in posh — GAP-01 violation", r.item)
		}
	}
	// Every wire-face row must stay byte-identical in smalt.
	for _, r := range stsMigrationTable {
		if r.classification == "azure-dialect" && r.migration == "already-posh-court-side" {
			continue
		}
		if r.classification == "azure-dialect" && r.migration != "stays-smalt-byte-identical" {
			t.Fatalf("row %s: dialect row not pinned byte-identical in smalt", r.item)
		}
	}
}
