package ingress_test

import (
	"testing"

	"github.com/stretchr/testify/require"
	"smalt.dev/posh/internal/ingress"
)

func TestParseAPIVersion_ValidDates(t *testing.T) {
	t.Parallel()

	tests := []struct {
		input     string
		numeric   uint32
		isPreview bool
	}{
		{"2020-01-01", 20200101, false},
		{"2022-09-01", 20220901, false},
		{"2023-05-01-preview", 20230501, true},
		{"2026-10-30", 20261030, false},
	}

	for _, tc := range tests {
		v, err := ingress.ParseAPIVersion(tc.input)
		require.NoError(t, err)
		require.Equal(t, tc.numeric, v.Numeric)
		require.Equal(t, tc.isPreview, v.IsPreview)
	}
}

func TestParseAPIVersion_Invalid(t *testing.T) {
	t.Parallel()

	invalid := []string{
		"invalid",
		"2020/01/01",
		"2020-13-01",
		"2020-00-01",
		"2020-01-32",
		"short",
	}

	for _, in := range invalid {
		_, err := ingress.ParseAPIVersion(in)
		require.Error(t, err)
	}
}

func TestAPIVersion_IsOlderOrEqual(t *testing.T) {
	t.Parallel()

	v1, _ := ingress.ParseAPIVersion("2020-01-01")
	v2, _ := ingress.ParseAPIVersion("2022-09-01")
	v3, _ := ingress.ParseAPIVersion("2022-09-01-preview")
	v4, _ := ingress.ParseAPIVersion("2022-09-01")

	require.True(t, v1.IsOlderOrEqual(v2))
	require.False(t, v2.IsOlderOrEqual(v1))
	require.True(t, v3.IsOlderOrEqual(v2)) // preview <= GA on same date
	require.True(t, v2.IsOlderOrEqual(v4))
}
