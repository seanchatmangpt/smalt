package provider

import (
	"context"
	"fmt"
	"regexp"
	"strings"

	"github.com/hashicorp/terraform-plugin-framework/diag"
	"github.com/hashicorp/terraform-plugin-framework/path"
	"github.com/hashicorp/terraform-plugin-framework/schema/validator"
)

// validators.go — provider DX validators (lane 7).
//
// URL and UUID format validators used on the provider schema
// (arm_endpoint, subscription_id). The hashicorp framework-validators
// module ships no URL validator and (in the stringvalidator package) no
// UUID validator, so these are local implementations of the
// schema.StringValidator interface.

var uuidRegexp = regexp.MustCompile(`^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$`)

// urlRegexp accepts http/https absolute URLs with a host; query and
// fragment are permitted.
var urlRegexp = regexp.MustCompile(`^https?://[^\s/:]+(?::\d+)?(?:/[^\s]*)?$`)

type uuidValidator struct{}

func (v uuidValidator) Description(ctx context.Context) string {
	return "value must be a canonical UUID (8-4-4-4-12 hexadecimal)"
}

func (v uuidValidator) MarkdownDescription(ctx context.Context) string {
	return v.Description(ctx)
}

func (v uuidValidator) ValidateString(ctx context.Context, req validator.StringRequest, resp *validator.StringResponse) {
	if req.ConfigValue.IsNull() || req.ConfigValue.IsUnknown() {
		return
	}
	s := req.ConfigValue.ValueString()
	if s == "" {
		// Empty is handled by Optional semantics / env fallback, not a
		// format error.
		return
	}
	if !uuidRegexp.MatchString(s) {
		resp.Diagnostics.Append(validDiag(
			req.Path, "Invalid UUID",
			fmt.Sprintf("value %q is not a valid UUID: expected 8-4-4-4-12 hexadecimal, e.g. 00000000-0000-0000-0000-000000000000", s)))
	}
}

type urlValidator struct{}

func (v urlValidator) Description(ctx context.Context) string {
	return "value must be an absolute http:// or https:// URL with a host"
}

func (v urlValidator) MarkdownDescription(ctx context.Context) string {
	return v.Description(ctx)
}

func (v urlValidator) ValidateString(ctx context.Context, req validator.StringRequest, resp *validator.StringResponse) {
	if req.ConfigValue.IsNull() || req.ConfigValue.IsUnknown() {
		return
	}
	s := req.ConfigValue.ValueString()
	if s == "" {
		return
	}
	if !urlRegexp.MatchString(s) {
		resp.Diagnostics.Append(validDiag(
			req.Path, "Invalid URL",
			fmt.Sprintf("value %q is not a valid absolute http(s) URL, e.g. http://127.0.0.1:9443", s)))
	}
}

func validDiag(p path.Path, summary, detail string) diag.Diagnostic {
	return diag.NewAttributeErrorDiagnostic(
		p,
		summary,
		detail,
	)
}

type ciOneOfValidator struct {
	allowed []string
}

func oneOfCIValidator(allowed ...string) validator.String {
	return ciOneOfValidator{allowed: allowed}
}

func (v ciOneOfValidator) Description(ctx context.Context) string {
	return fmt.Sprintf("value must be one of (case-insensitive): %s", strings.Join(v.allowed, ", "))
}

func (v ciOneOfValidator) MarkdownDescription(ctx context.Context) string {
	return v.Description(ctx)
}

func (v ciOneOfValidator) ValidateString(ctx context.Context, req validator.StringRequest, resp *validator.StringResponse) {
	if req.ConfigValue.IsNull() || req.ConfigValue.IsUnknown() {
		return
	}
	s := req.ConfigValue.ValueString()
	for _, a := range v.allowed {
		if strings.EqualFold(s, a) {
			return
		}
	}
	resp.Diagnostics.Append(validDiag(
		req.Path,
		"Invalid Value",
		fmt.Sprintf("value %q must be one of: %s", s, strings.Join(v.allowed, ", ")),
	))
}
