package provider

import (
	"strings"
	"testing"

	"github.com/hashicorp/terraform-plugin-framework/diag"
)

// Honesty-law courts (lane C2, 2026-10-30): fabricated values must be LOUD or
// absent, never silent. Default = typed error; TFPOSH_ALLOW_FABRICATED_IDS=1 =
// loud warning + fabricated value. A court that cannot flip is vacuous.

func TestCarryOrMintIdentityAttrRefusedByDefault(t *testing.T) {
	t.Setenv("TFPOSH_ALLOW_FABRICATED_IDS", "")
	var d diag.Diagnostics
	got := carryOrMintIdentityAttr(&d, "", "uai-principal:/subscriptions/x", "principal_id")
	if got != "" {
		t.Fatalf("want empty attr on refusal, got %q", got)
	}
	if !d.HasError() {
		t.Fatalf("want error diag by default, got %v", d)
	}
	errs := d.Errors()
	if !strings.Contains(errs[0].Summary(), "principal_id") {
		t.Fatalf("error must name the missing attr, got %q", errs[0].Summary())
	}
	if !strings.Contains(errs[0].Detail(), "smalt ARM face") {
		t.Fatalf("error must name the smalt face limitation, got %q", errs[0].Detail())
	}
}

func TestCarryOrMintIdentityAttrLoudWarningUnderOptIn(t *testing.T) {
	t.Setenv("TFPOSH_ALLOW_FABRICATED_IDS", "1")
	var d diag.Diagnostics
	got := carryOrMintIdentityAttr(&d, "", "uai-client:/subscriptions/x", "client_id")
	if got == "" {
		t.Fatalf("opt-in must mint, got empty")
	}
	if d.HasError() {
		t.Fatalf("opt-in must not error, got %v", d)
	}
	if len(d.Warnings()) == 0 {
		t.Fatalf("opt-in must carry a loud warning")
	}
	if !strings.Contains(d.Warnings()[0].Summary(), "FABRICATED") {
		t.Fatalf("warning must be loud, got %q", d.Warnings()[0].Summary())
	}
}

func TestCarryOrMintIdentityAttrPriorStateWinsSilently(t *testing.T) {
	t.Setenv("TFPOSH_ALLOW_FABRICATED_IDS", "")
	var d diag.Diagnostics
	got := carryOrMintIdentityAttr(&d, "prior-id", "in", "client_id")
	if got != "prior-id" || d.HasError() || len(d.Warnings()) > 0 {
		t.Fatalf("prior state must carry silently: got %q diags %v", got, d)
	}
}

func TestRefuseFabricatedValueBothBranches(t *testing.T) {
	t.Setenv("TFPOSH_ALLOW_FABRICATED_IDS", "")
	var d diag.Diagnostics
	if !refuseFabricatedValue(&d, "t", "d") {
		t.Fatalf("default must refuse")
	}
	if !d.HasError() {
		t.Fatalf("refusal must be an error diag")
	}

	t.Setenv("TFPOSH_ALLOW_FABRICATED_IDS", "1")
	var d2 diag.Diagnostics
	if refuseFabricatedValue(&d2, "t", "d") {
		t.Fatalf("opt-in must not refuse")
	}
	if d2.HasError() || len(d2.Warnings()) == 0 {
		t.Fatalf("opt-in must warn loudly, got %v", d2)
	}
}

func TestResolveRoleDefinitionInputWarnsOnBareNameMint(t *testing.T) {
	t.Setenv("TFPOSH_ALLOW_FABRICATED_IDS", "")
	var d diag.Diagnostics
	scope := "/subscriptions/00000000-0000-0000-0000-000000000000"
	got := resolveRoleDefinitionInput(scope, "", "Contributor", &d)
	want := mintDeterministicGUID("Contributor|" + scope)
	if !strings.Contains(got, want) {
		t.Fatalf("mint funnel changed: got %s want suffix %s", got, want)
	}
	if len(d.Warnings()) == 0 || !strings.Contains(d.Warnings()[0].Summary(), "Contributor") {
		t.Fatalf("bare-name mint must warn loudly, got %v", d.Warnings())
	}
	// Real ARM path passes through without any fabricated warning.
	var d2 diag.Diagnostics
	got2 := resolveRoleDefinitionInput(scope,
		"/subscriptions/s/providers/Microsoft.Authorization/roleDefinitions/abc", "", &d2)
	if got2 == "" || len(d2.Warnings()) != 0 {
		t.Fatalf("real path must pass silently: got %q diags %v", got2, d2.Warnings())
	}
}
