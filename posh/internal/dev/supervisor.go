package dev

import (
	"bytes"
	"context"
	"fmt"
	"io"
	"net"
	"os"
	"os/exec"
	"os/signal"
	"path/filepath"
	"sync"
	"syscall"
	"time"

	"smalt.dev/posh/internal/diag"
)

// SupervisorOptions configures the watch/reload supervisor.
type SupervisorOptions struct {
	ConfigPath string
	BinaryPath string
	CmdPath    string
	SocketPath string
	Stdout     io.Writer
	Stderr     io.Writer
	OnReload   func(pid int, dur time.Duration)
	OnCompile  func(err error, diagStr string)
}

// Supervisor owns the pre-bound UDS socket and manages worker child processes.
type Supervisor struct {
	opts       SupervisorOptions
	listener   net.Listener
	socketFile *os.File
	activeCmd  *exec.Cmd
	mu         sync.Mutex
	closed     bool
}

// NewSupervisor initializes the supervisor and pre-binds the socket.
func NewSupervisor(opts SupervisorOptions) (*Supervisor, error) {
	if opts.ConfigPath == "" {
		opts.ConfigPath = "posh.yaml"
	}
	if opts.BinaryPath == "" {
		opts.BinaryPath = "bin/posh"
	}
	if opts.CmdPath == "" {
		opts.CmdPath = "./cmd/posh"
	}
	if opts.SocketPath == "" {
		opts.SocketPath = "run/posh.sock"
	}
	if opts.Stdout == nil {
		opts.Stdout = os.Stdout
	}
	if opts.Stderr == nil {
		opts.Stderr = os.Stderr
	}

	if err := os.MkdirAll(filepath.Dir(opts.SocketPath), 0o755); err != nil {
		return nil, fmt.Errorf("create socket dir: %w", err)
	}
	if _, err := os.Stat(opts.SocketPath); err == nil {
		if c, err := net.Dial("unix", opts.SocketPath); err == nil {
			c.Close()
			return nil, fmt.Errorf("socket %s already served by live process", opts.SocketPath)
		}
		os.Remove(opts.SocketPath)
	}

	ln, err := net.Listen("unix", opts.SocketPath)
	if err != nil {
		return nil, fmt.Errorf("listen unix %s: %w", opts.SocketPath, err)
	}

	unixLn, ok := ln.(*net.UnixListener)
	if !ok {
		ln.Close()
		return nil, fmt.Errorf("expected *net.UnixListener, got %T", ln)
	}

	// File() dup(2)s the listener file descriptor
	sockFile, err := unixLn.File()
	if err != nil {
		ln.Close()
		return nil, fmt.Errorf("dup socket fd: %w", err)
	}

	return &Supervisor{
		opts:       opts,
		listener:   ln,
		socketFile: sockFile,
	}, nil
}

// Build compiles the binary to targetPath.
func (s *Supervisor) Build(ctx context.Context, targetPath string) error {
	t0 := time.Now()
	_ = os.MkdirAll(filepath.Dir(targetPath), 0o755)

	cmd := exec.CommandContext(ctx, "go", "build", "-trimpath", "-o", targetPath, s.opts.CmdPath)
	var outBuf bytes.Buffer
	cmd.Stdout = &outBuf
	cmd.Stderr = &outBuf

	err := cmd.Run()
	dur := time.Since(t0)

	if err != nil {
		diagMsg := outBuf.String()
		d := diag.CompileFailed(s.opts.CmdPath, 1, 1, diagMsg)
		rendered := d.Render(diag.ColorConfig{ForceColor: true})
		if s.opts.OnCompile != nil {
			s.opts.OnCompile(err, rendered)
		} else {
			fmt.Fprintln(s.opts.Stderr, rendered)
		}
		return fmt.Errorf("build failed (%s): %s", dur.Round(time.Millisecond), outBuf.String())
	}

	if s.opts.OnCompile != nil {
		s.opts.OnCompile(nil, "")
	}
	return nil
}

// SpawnWorker launches a worker child process with the inherited listener FD.
func (s *Supervisor) SpawnWorker() (*exec.Cmd, error) {
	s.mu.Lock()
	defer s.mu.Unlock()

	cmd := exec.Command(s.opts.BinaryPath, "-config", s.opts.ConfigPath)
	cmd.Stdout = s.opts.Stdout
	cmd.Stderr = s.opts.Stderr

	// ExtraFiles are passed starting at fd 3 in child process
	cmd.ExtraFiles = []*os.File{s.socketFile}
	cmd.Env = append(os.Environ(), "POSH_LISTEN_FD=3")

	if err := cmd.Start(); err != nil {
		return nil, fmt.Errorf("start worker: %w", err)
	}

	oldCmd := s.activeCmd
	s.activeCmd = cmd

	// Graceful drain of previous worker
	if oldCmd != nil && oldCmd.Process != nil {
		go func(p *os.Process) {
			// Give new worker a brief moment to enter Accept()
			time.Sleep(35 * time.Millisecond)
			_ = p.Signal(syscall.SIGTERM)
			_ = oldCmd.Wait()
		}(oldCmd.Process)
	}

	return cmd, nil
}

// Reload rebuilds the code and performs a zero-downtime hot-swap.
func (s *Supervisor) Reload(ctx context.Context) error {
	t0 := time.Now()
	nextBin := s.opts.BinaryPath + ".next"
	if err := s.Build(ctx, nextBin); err != nil {
		return err
	}

	if err := os.Rename(nextBin, s.opts.BinaryPath); err != nil {
		return fmt.Errorf("atomic binary swap: %w", err)
	}

	cmd, err := s.SpawnWorker()
	if err != nil {
		return err
	}

	dur := time.Since(t0)
	if s.opts.OnReload != nil {
		s.opts.OnReload(cmd.Process.Pid, dur)
	} else {
		fmt.Fprintf(s.opts.Stderr, "posh dev: recompiled & hot-swapped worker (pid %d) in %s\n",
			cmd.Process.Pid, dur.Round(time.Millisecond))
	}
	return nil
}

// Run executes the initial build, boots the initial worker, and runs the watch loop.
func (s *Supervisor) Run(ctx context.Context) error {
	defer s.Close()

	ctx, cancel := signal.NotifyContext(ctx, syscall.SIGINT, syscall.SIGTERM)
	defer cancel()

	fmt.Fprintf(s.opts.Stderr, "posh dev: initial build of %s...\n", s.opts.CmdPath)
	if err := s.Build(ctx, s.opts.BinaryPath); err != nil {
		fmt.Fprintf(s.opts.Stderr, "posh dev: initial build error: %v\n", err)
	} else {
		if _, err := s.SpawnWorker(); err != nil {
			return err
		}
	}

	watcher, err := NewWatcher(DefaultWatcherConfig(".", "cmd", "internal"))
	if err != nil {
		return fmt.Errorf("start watcher: %w", err)
	}
	defer watcher.Close()

	go watcher.Start(ctx)

	fmt.Fprintf(s.opts.Stderr, "posh dev: watching filesystem for changes (zero-downtime UDS hot-reload active)...\n")

	for {
		select {
		case <-ctx.Done():
			return nil
		case path := <-watcher.Events():
			fmt.Fprintf(s.opts.Stderr, "posh dev: change detected in %s, reloading...\n", path)
			if err := s.Reload(ctx); err != nil {
				// Error already rendered via diagnostic engine
			}
		case err := <-watcher.Errors():
			fmt.Fprintf(s.opts.Stderr, "posh dev: watcher error: %v\n", err)
		}
	}
}

// Close shuts down the active worker, closes the listener, and removes the socket file.
func (s *Supervisor) Close() error {
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.closed {
		return nil
	}
	s.closed = true

	if s.activeCmd != nil && s.activeCmd.Process != nil {
		_ = s.activeCmd.Process.Signal(syscall.SIGTERM)
		_ = s.activeCmd.Wait()
	}

	if s.socketFile != nil {
		_ = s.socketFile.Close()
	}
	if s.listener != nil {
		_ = s.listener.Close()
	}
	_ = os.Remove(s.opts.SocketPath)
	return nil
}
