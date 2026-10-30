package dev

import (
	"context"
	"net"
	"os"
	"path/filepath"
	"testing"
	"time"
)

func TestSupervisorLifecycle(t *testing.T) {
	tmpDir := t.TempDir()
	sockPath := filepath.Join(tmpDir, "lifecycle.sock")
	binPath := filepath.Join(tmpDir, "dummy_bin")

	// Create dummy executable script
	dummyScript := "#!/bin/sh\nsleep 10\n"
	if err := os.WriteFile(binPath, []byte(dummyScript), 0o755); err != nil {
		t.Fatalf("failed to create dummy script: %v", err)
	}

	opts := SupervisorOptions{
		SocketPath: sockPath,
		BinaryPath: binPath,
	}

	sup, err := NewSupervisor(opts)
	if err != nil {
		t.Fatalf("NewSupervisor: %v", err)
	}
	defer sup.Close()

	// Verify pre-bound UDS socket accepts connection
	c, err := net.Dial("unix", sockPath)
	if err != nil {
		t.Fatalf("failed to dial supervisor socket: %v", err)
	}
	c.Close()

	// Test SpawnWorker launches process
	cmd, err := sup.SpawnWorker()
	if err != nil {
		t.Fatalf("SpawnWorker failed: %v", err)
	}
	if cmd.Process == nil || cmd.Process.Pid <= 0 {
		t.Fatalf("expected valid running worker process, got: %+v", cmd.Process)
	}

	firstPid := cmd.Process.Pid

	// Test second worker spawn drains first worker
	cmd2, err := sup.SpawnWorker()
	if err != nil {
		t.Fatalf("second SpawnWorker failed: %v", err)
	}
	secondPid := cmd2.Process.Pid
	if secondPid == firstPid {
		t.Fatalf("expected different pid for new worker, got %d", secondPid)
	}

	// Allow graceful drain goroutine to signal old process
	time.Sleep(100 * time.Millisecond)

	// Close supervisor and verify clean cleanup
	if err := sup.Close(); err != nil {
		t.Fatalf("Close failed: %v", err)
	}

	// Verify socket was removed on close
	if _, err := os.Stat(sockPath); !os.IsNotExist(err) {
		t.Fatalf("expected socket %s to be removed on close, err: %v", sockPath, err)
	}
}

func TestSupervisorBuildFailureDiagnostic(t *testing.T) {
	tmpDir := t.TempDir()
	sockPath := filepath.Join(tmpDir, "diag.sock")
	targetBin := filepath.Join(tmpDir, "unbuildable_bin")

	var reportedDiag string
	var reportedErr error

	opts := SupervisorOptions{
		SocketPath: sockPath,
		CmdPath:    filepath.Join(tmpDir, "non_existent_cmd"),
		OnCompile: func(err error, diagStr string) {
			reportedErr = err
			reportedDiag = diagStr
		},
	}

	sup, err := NewSupervisor(opts)
	if err != nil {
		t.Fatalf("NewSupervisor: %v", err)
	}
	defer sup.Close()

	ctx, cancel := context.WithTimeout(context.Background(), 2*time.Second)
	defer cancel()

	err = sup.Build(ctx, targetBin)
	if err == nil {
		t.Fatalf("expected build error for non-existent cmd, got nil")
	}

	if reportedErr == nil {
		t.Fatalf("expected OnCompile callback to record build error")
	}
	if reportedDiag == "" {
		t.Fatalf("expected non-empty diagnostic message in OnCompile callback")
	}
}
