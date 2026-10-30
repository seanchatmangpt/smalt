package ingress

import (
	"errors"
	"strings"
)

// APIVersion represents a fast, parsed ARM API version with monotonic numeric representation.
type APIVersion struct {
	Raw       string
	Numeric   uint32 // YYYYMMDD
	IsPreview bool
}

// ParseAPIVersion parses ARM api-version strings (e.g., "2022-09-01", "2023-01-01-preview")
// into integer dates with 0 heap allocations.
func ParseAPIVersion(v string) (APIVersion, error) {
	v = strings.TrimSpace(v)
	if len(v) < 10 {
		return APIVersion{}, errors.New("api-version too short (expected YYYY-MM-DD)")
	}

	// Fast ASCII validation and parsing of YYYY-MM-DD
	y0, y1, y2, y3 := v[0], v[1], v[2], v[3]
	sep1 := v[4]
	m0, m1 := v[5], v[6]
	sep2 := v[7]
	d0, d1 := v[8], v[9]

	if sep1 != '-' || sep2 != '-' {
		return APIVersion{}, errors.New("invalid date separator in api-version")
	}

	if !isDigit(y0) || !isDigit(y1) || !isDigit(y2) || !isDigit(y3) ||
		!isDigit(m0) || !isDigit(m1) || !isDigit(d0) || !isDigit(d1) {
		return APIVersion{}, errors.New("non-numeric character in api-version date")
	}

	year := uint32(y0-'0')*1000 + uint32(y1-'0')*100 + uint32(y2-'0')*10 + uint32(y3-'0')
	month := uint32(m0-'0')*10 + uint32(m1-'0')
	day := uint32(d0-'0')*10 + uint32(d1-'0')

	if month < 1 || month > 12 || day < 1 || day > 31 {
		return APIVersion{}, errors.New("invalid calendar month/day in api-version")
	}

	numeric := year*10000 + month*100 + day
	isPreview := strings.HasSuffix(strings.ToLower(v), "-preview")

	return APIVersion{
		Raw:       v,
		Numeric:   numeric,
		IsPreview: isPreview,
	}, nil
}

// IsOlderOrEqual returns true if a <= b monotonically.
func (a APIVersion) IsOlderOrEqual(b APIVersion) bool {
	if a.Numeric != b.Numeric {
		return a.Numeric <= b.Numeric
	}
	// If dates are identical, preview is older than GA
	if a.IsPreview && !b.IsPreview {
		return true
	}
	if !a.IsPreview && b.IsPreview {
		return false
	}
	return true
}

func isDigit(b byte) bool {
	return b >= '0' && b <= '9'
}
