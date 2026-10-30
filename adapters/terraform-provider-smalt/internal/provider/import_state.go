package provider

import (
	"context"
	"fmt"
	"strings"

	"github.com/hashicorp/terraform-plugin-framework/diag"
	"github.com/hashicorp/terraform-plugin-framework/path"
	"github.com/hashicorp/terraform-plugin-framework/resource"
)

// GAP22-3 close: per-type import segment assertions. Every ImportState MUST
// assert the id's segments match the resource type BEFORE adopting it; a
// mismatch is a typed error diag, never a silent wrong-resource adoption.

// requireImportSegment asserts that the (normalized) import id carries the
// required ARM segment marker (e.g. "/providers/Microsoft.KeyVault/vaults/").
// On mismatch it records a typed error diag and returns false; callers must
// return without touching state.
func requireImportSegment(diags *diag.Diagnostics, id, marker, resourceType string) bool {
	if strings.Contains(strings.ToLower(id), strings.ToLower(marker)) {
		return true
	}
	diags.AddError(
		"Invalid Resource Import ID",
		fmt.Sprintf("Import ID %q is not a valid %s ID: expected the ARM segment "+
			"%q in the ID path. Wrong-resource IDs are refused rather than silently "+
			"adopted (GAP22-3).", id, resourceType, marker),
	)
	return false
}

// forbidImportSegment is the inverse assertion for segment-free ids: an
// azurerm_resource_group ID must never carry a "providers/" segment (that
// would make it a resource-inside-a-group ID, not a group ID).
func forbidImportSegment(diags *diag.Diagnostics, id, marker, resourceType string) bool {
	if !strings.Contains(strings.ToLower(id), strings.ToLower(marker)) {
		return true
	}
	diags.AddError(
		"Invalid Resource Import ID",
		fmt.Sprintf("Import ID %q is not a valid %s ID: the ID must not contain "+
			"the ARM segment %q. Wrong-resource IDs are refused rather than silently "+
			"adopted (GAP22-3).", id, resourceType, marker),
	)
	return false
}

// setImportIDRGName applies the shared "id + resource_group_name + name"
// portion of an ImportState once the per-type segment assertion has passed.
func setImportIDRGName(ctx context.Context, resp *resource.ImportStateResponse, id string) {
	resp.Diagnostics.Append(resp.State.SetAttribute(ctx, path.Root("id"), id)...)
	if rg := extractResourceGroupFromID(id); rg != "" {
		resp.Diagnostics.Append(resp.State.SetAttribute(ctx, path.Root("resource_group_name"), rg)...)
	}
	parts := strings.Split(id, "/")
	if len(parts) > 0 {
		resp.Diagnostics.Append(resp.State.SetAttribute(ctx, path.Root("name"), parts[len(parts)-1])...)
	}
}
