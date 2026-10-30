package telemetry_test

import (
	"bytes"
	"strings"
	"testing"
	"time"

	"github.com/stretchr/testify/require"
	"smalt.dev/posh/internal/telemetry"
)

func TestSPCState_WelfordAndShewhart(t *testing.T) {
	t.Parallel()

	spc := telemetry.NewSPCState(0.35, 20)

	// Ingest stable distribution around 100.0
	for i := 0; i < 20; i++ {
		val := 100.0 + float64(i%5) - 2.0 // 98, 99, 100, 101, 102
		mean, stdDev, ewma, ooc := spc.Observe(val)
		require.InDelta(t, 100.0, mean, 3.0)
		if i > 5 {
			require.Greater(t, stdDev, 0.0)
			require.InDelta(t, 100.0, ewma, 5.0)
			require.False(t, ooc, "Stable distribution should not be out of control")
		}
	}

	// Inject 3-sigma anomaly
	_, _, _, ooc := spc.Observe(500.0)
	require.True(t, ooc, "Point at 500 should trigger out-of-control rule")
}

func TestOCELWriter_NDJSONStreaming(t *testing.T) {
	t.Parallel()

	var buf bytes.Buffer
	writer := telemetry.NewOCELWriter(&buf)

	evt := &telemetry.OCELEvent{
		ID:        "evt-001",
		Type:      "ARM_MUTATION",
		Timestamp: time.Now().UTC(),
		Attributes: map[string]any{
			"resource": "/subscriptions/sub-1/resourceGroups/rg-1",
			"op":       "PUT",
		},
		Relationships: []telemetry.OCELRelation{
			{ObjectID: "sub-1", Qualifier: "SUBSCRIPTION"},
		},
	}

	err := writer.WriteEvent(evt)
	require.NoError(t, err)

	err = writer.Flush()
	require.NoError(t, err)

	output := buf.String()
	require.True(t, strings.HasPrefix(output, `{"ocel:id":"evt-001"`))
	require.True(t, strings.HasSuffix(output, "\n"))
	require.Equal(t, uint64(1), writer.Count())

	err = writer.Close()
	require.NoError(t, err)
}
