package bootstrap

import (
	"bytes"
	"context"
	"os"
	"path/filepath"
	"testing"
)

func TestSetupBootstrap(t *testing.T) {
	tmpDir := t.TempDir()
	cfgPath := filepath.Join(tmpDir, "posh.yaml")

	var buf bytes.Buffer
	res, err := Run(context.Background(), SetupOptions{
		RepoRoot:   tmpDir,
		ConfigPath: cfgPath,
		Out:        &buf,
	})
	if err != nil {
		t.Fatalf("Run setup: %v", err)
	}

	if !res.ConfigCreated {
		t.Errorf("expected ConfigCreated to be true")
	}

	// Verify posh.yaml was created on disk
	if _, err := os.Stat(cfgPath); os.IsNotExist(err) {
		t.Fatalf("config file was not created on disk: %s", cfgPath)
	}

	// Verify run and var directories exist
	if _, err := os.Stat(filepath.Join(tmpDir, "run")); os.IsNotExist(err) {
		t.Errorf("run dir was not created")
	}
	if _, err := os.Stat(filepath.Join(tmpDir, "var")); os.IsNotExist(err) {
		t.Errorf("var dir was not created")
	}

	// Idempotent second run
	buf.Reset()
	res2, err := Run(context.Background(), SetupOptions{
		RepoRoot:   tmpDir,
		ConfigPath: cfgPath,
		Out:        &buf,
	})
	if err != nil {
		t.Fatalf("Run setup second time: %v", err)
	}
	if res2.ConfigCreated {
		t.Errorf("expected ConfigCreated to be false on second run")
	}
}
