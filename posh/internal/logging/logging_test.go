package logging_test

import (
	"bytes"
	"context"
	"log/slog"
	"os"
	"testing"

	"github.com/stretchr/testify/require"

	"smalt.dev/posh/internal/logging"
)

func TestLogging_InitAndLevelParsing(t *testing.T) {
	// 1. Test From() returns fallback discard logger prior to Init if nil
	origL := logging.L
	defer func() { logging.L = origL }()

	logging.L = nil
	logger := logging.From()
	require.NotNil(t, logger, "From() must never return nil")

	// 2. Test Init() initializes process logger
	os.Setenv("POSH_LOG_LEVEL", "DEBUG")
	defer os.Unsetenv("POSH_LOG_LEVEL")

	logging.Init()
	require.NotNil(t, logging.L, "Init() must populate logging.L")
	require.True(t, logging.L.Enabled(context.Background(), slog.LevelDebug), "Logger must be enabled for DEBUG")

	// 3. Test WithRequestID and RequestID context roundtrip
	ctx := context.Background()
	require.Empty(t, logging.RequestID(ctx), "Unset request ID should be empty")

	reqID := "req-trace-999"
	ctxWithID := logging.WithRequestID(ctx, reqID)
	require.Equal(t, reqID, logging.RequestID(ctxWithID), "RequestID must extract stamped ID")
}

func TestLogging_JSONOutputFormatting(t *testing.T) {
	t.Parallel()

	var buf bytes.Buffer
	handler := slog.NewJSONHandler(&buf, &slog.HandlerOptions{Level: slog.LevelInfo})
	logger := slog.New(handler)

	logger.Info("audit event", slog.String("component", "membrane"), slog.String("subsystem", "turnstile"))

	output := buf.String()
	require.Contains(t, output, `"msg":"audit event"`)
	require.Contains(t, output, `"component":"membrane"`)
	require.Contains(t, output, `"subsystem":"turnstile"`)
	require.Contains(t, output, `"level":"INFO"`)
}
