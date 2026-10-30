// Package pgo provides production-safe Profile-Guided Optimization (PGO)
// profile collection, validation, and multi-profile merging for the POSH membrane.
//
// In Go 1.20+, PGO builds (-pgo=default.pgo) require canonical pprof CPU profiles
// (gzip-compressed protocol buffers). This package implements:
//  1. Safe streaming ingestion from sidecars with bounded memory (io.LimitReader)
//     and concurrent collection limits to prevent OOM.
//  2. Validation of gzip magic headers (0x1f 0x8b) and minimum profile integrity.
//  3. Multi-profile additive merging via `go tool pprof -proto` into a canonical
//     `default.pgo` for compiler optimization.
//  4. Atomic file swapping (write-to-temp + rename) and cryptographic SHA-256 receipts.
package pgo

import (
	"bytes"
	"context"
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"fmt"
	"io"
	"net/http"
	"os"
	"os/exec"
	"path/filepath"
	"sort"
	"sync"
	"time"
)

var (
	// ErrProfileTooLarge is returned when incoming profile exceeds MaxProfileSizeBytes.
	ErrProfileTooLarge = errors.New("pgo: profile payload exceeds maximum size bound")
	// ErrInvalidProfileHeader is returned when incoming data lacks gzip magic bytes.
	ErrInvalidProfileHeader = errors.New("pgo: invalid profile format (missing gzip magic header)")
	// ErrNoValidProfiles is returned when no valid profile inputs are provided for merge.
	ErrNoValidProfiles = errors.New("pgo: no valid profiles found to merge")
	// ErrCollectionTimeout is returned when profile collection exceeds deadline.
	ErrCollectionTimeout = errors.New("pgo: profile collection timed out")
)

// Standard gzip magic header bytes: 0x1F, 0x8B.
var gzipMagic = []byte{0x1f, 0x8b}

// CollectorConfig configures safe runtime profile collection bounds.
type CollectorConfig struct {
	OutputDir              string        // Staging directory for collected profiles
	MaxProfileSizeBytes    int64         // Hard ceiling per profile (default 32 MiB)
	MaxConcurrentCollects  int           // Concurrency ceiling (default 4)
	DefaultTimeout         time.Duration // HTTP/stream timeout (default 30s)
	RetainedProfilesLimit  int           // Maximum staged profiles before FIFO prune (default 20)
}

// DefaultCollectorConfig returns production-safe collection parameters.
func DefaultCollectorConfig() CollectorConfig {
	return CollectorConfig{
		OutputDir:             "pgo/collected",
		MaxProfileSizeBytes:   32 << 20, // 32 MiB
		MaxConcurrentCollects: 4,
		DefaultTimeout:        30 * time.Second,
		RetainedProfilesLimit: 20,
	}
}

// ProfileMetadata captures verified attributes of an ingested profile.
type ProfileMetadata struct {
	Path        string    `json:"path"`
	SizeBytes   int64     `json:"size_bytes"`
	SHA256Hex   string    `json:"sha256_hex"`
	CollectedAt time.Time `json:"collected_at"`
	Source      string    `json:"source"`
}

// Collector coordinates bounded profile gathering from local files, HTTP sidecars,
// or streaming sockets.
type Collector struct {
	cfg CollectorConfig
	sem chan struct{}
	mu  sync.Mutex
}

// NewCollector creates an initialized Collector.
func NewCollector(cfg CollectorConfig) *Collector {
	if cfg.MaxProfileSizeBytes <= 0 {
		cfg.MaxProfileSizeBytes = 32 << 20
	}
	if cfg.MaxConcurrentCollects <= 0 {
		cfg.MaxConcurrentCollects = 4
	}
	if cfg.DefaultTimeout <= 0 {
		cfg.DefaultTimeout = 30 * time.Second
	}
	if cfg.RetainedProfilesLimit <= 0 {
		cfg.RetainedProfilesLimit = 20
	}
	if cfg.OutputDir == "" {
		cfg.OutputDir = "pgo/collected"
	}

	return &Collector{
		cfg: cfg,
		sem: make(chan struct{}, cfg.MaxConcurrentCollects),
	}
}

// CollectFromReader streams an incoming profile from r, enforcing hard byte bounds
// and verifying gzip magic bytes without buffering the full payload in memory.
func (c *Collector) CollectFromReader(ctx context.Context, r io.Reader, filename string, source string) (*ProfileMetadata, error) {
	select {
	case c.sem <- struct{}{}:
		defer func() { <-c.sem }()
	case <-ctx.Done():
		return nil, ctx.Err()
	}

	if err := os.MkdirAll(c.cfg.OutputDir, 0o755); err != nil {
		return nil, fmt.Errorf("pgo: create output dir: %w", err)
	}

	if filename == "" {
		filename = fmt.Sprintf("profile_%s.pgo", time.Now().UTC().Format("20060102_150405.000"))
	}
	destPath := filepath.Join(c.cfg.OutputDir, filename)
	tmpPath := destPath + ".tmp"

	f, err := os.OpenFile(tmpPath, os.O_CREATE|os.O_WRONLY|os.O_TRUNC, 0o644)
	if err != nil {
		return nil, fmt.Errorf("pgo: create temp profile file: %w", err)
	}

	// Stream through limited reader and compute SHA-256 simultaneously
	hasher := sha256.New()
	limitR := io.LimitReader(r, c.cfg.MaxProfileSizeBytes+1)
	writer := io.MultiWriter(f, hasher)

	// Read and verify magic header first
	hdr := make([]byte, 2)
	n, err := io.ReadFull(limitR, hdr)
	if err != nil || n < 2 || !bytes.Equal(hdr, gzipMagic) {
		f.Close()
		_ = os.Remove(tmpPath)
		return nil, ErrInvalidProfileHeader
	}

	// Write magic bytes to file and hash
	if _, err := writer.Write(hdr); err != nil {
		f.Close()
		_ = os.Remove(tmpPath)
		return nil, err
	}

	// Stream remainder
	copied, err := io.Copy(writer, limitR)
	f.Close()

	if err != nil {
		_ = os.Remove(tmpPath)
		return nil, fmt.Errorf("pgo: stream copy: %w", err)
	}

	totalBytes := int64(n) + copied
	if totalBytes > c.cfg.MaxProfileSizeBytes {
		_ = os.Remove(tmpPath)
		return nil, ErrProfileTooLarge
	}

	// Atomically move to final destination
	if err := os.Rename(tmpPath, destPath); err != nil {
		_ = os.Remove(tmpPath)
		return nil, fmt.Errorf("pgo: atomic rename: %w", err)
	}

	meta := &ProfileMetadata{
		Path:        destPath,
		SizeBytes:   totalBytes,
		SHA256Hex:   hex.EncodeToString(hasher.Sum(nil)),
		CollectedAt: time.Now().UTC(),
		Source:      source,
	}

	c.mu.Lock()
	c.pruneOldProfiles()
	c.mu.Unlock()

	return meta, nil
}

// CollectFromURL fetches a profile over HTTP from a sidecar endpoint (e.g. /debug/pprof/profile).
func (c *Collector) CollectFromURL(ctx context.Context, endpointURL string, client *http.Client) (*ProfileMetadata, error) {
	if client == nil {
		client = &http.Client{Timeout: c.cfg.DefaultTimeout}
	}

	req, err := http.NewRequestWithContext(ctx, http.MethodGet, endpointURL, nil)
	if err != nil {
		return nil, fmt.Errorf("pgo: create request: %w", err)
	}

	resp, err := client.Do(req)
	if err != nil {
		return nil, fmt.Errorf("pgo: fetch endpoint %s: %w", endpointURL, err)
	}
	defer resp.Body.Close()

	if resp.StatusCode != http.StatusOK {
		return nil, fmt.Errorf("pgo: unexpected status from %s: %d", endpointURL, resp.StatusCode)
	}

	filename := fmt.Sprintf("sidecar_%s.pgo", time.Now().UTC().Format("20060102_150405.000"))
	return c.CollectFromReader(ctx, resp.Body, filename, endpointURL)
}

// CollectLocal copies and validates a locally produced profile file into the collector staging dir.
func (c *Collector) CollectLocal(ctx context.Context, localPath string) (*ProfileMetadata, error) {
	f, err := os.Open(localPath)
	if err != nil {
		return nil, fmt.Errorf("pgo: open local profile: %w", err)
	}
	defer f.Close()

	name := filepath.Base(localPath)
	return c.CollectFromReader(ctx, f, name, "local:"+localPath)
}

func (c *Collector) pruneOldProfiles() {
	entries, err := os.ReadDir(c.cfg.OutputDir)
	if err != nil || len(entries) <= c.cfg.RetainedProfilesLimit {
		return
	}

	type fileItem struct {
		path    string
		modTime time.Time
	}
	var items []fileItem
	for _, e := range entries {
		if e.IsDir() || filepath.Ext(e.Name()) != ".pgo" {
			continue
		}
		info, err := e.Info()
		if err != nil {
			continue
		}
		items = append(items, fileItem{
			path:    filepath.Join(c.cfg.OutputDir, e.Name()),
			modTime: info.ModTime(),
		})
	}

	if len(items) <= c.cfg.RetainedProfilesLimit {
		return
	}

	sort.Slice(items, func(i, j int) bool {
		return items[i].modTime.Before(items[j].modTime)
	})

	toPrune := len(items) - c.cfg.RetainedProfilesLimit
	for i := 0; i < toPrune; i++ {
		_ = os.Remove(items[i].path)
	}
}

// MergerConfig defines execution options for PGO profile merging.
type MergerConfig struct {
	CanonicalOutput     string // Default output path (e.g. "default.pgo")
	MinProfileSizeBytes int64  // Reject tiny corrupt profiles (<128B)
	GoBinaryPath        string // Path to `go` binary (defaults to "go")
}

// DefaultMergerConfig returns production default merger settings.
func DefaultMergerConfig() MergerConfig {
	return MergerConfig{
		CanonicalOutput:     "default.pgo",
		MinProfileSizeBytes: 128,
		GoBinaryPath:        "go",
	}
}

// MergeReceipt provides cryptographic and forensic evidence of a completed profile merge.
type MergeReceipt struct {
	CanonicalPath   string    `json:"canonical_path"`
	InputFiles      []string  `json:"input_files"`
	ValidInputCount int       `json:"valid_input_count"`
	OutputSizeBytes int64     `json:"output_size_bytes"`
	SHA256Hex       string    `json:"sha256_hex"`
	Timestamp       time.Time `json:"timestamp"`
	DurationMs      int64     `json:"duration_ms"`
}

// Merger handles filtering, validation, and multi-profile merging.
type Merger struct {
	cfg MergerConfig
}

// NewMerger creates a new Merger instance.
func NewMerger(cfg MergerConfig) *Merger {
	if cfg.CanonicalOutput == "" {
		cfg.CanonicalOutput = "default.pgo"
	}
	if cfg.MinProfileSizeBytes <= 0 {
		cfg.MinProfileSizeBytes = 128
	}
	if cfg.GoBinaryPath == "" {
		cfg.GoBinaryPath = "go"
	}
	return &Merger{cfg: cfg}
}

// ValidateProfile verifies that path exists, is >= min size, and begins with gzip magic bytes.
func ValidateProfile(path string, minSize int64) error {
	info, err := os.Stat(path)
	if err != nil {
		return err
	}
	if info.Size() < minSize {
		return fmt.Errorf("profile %s too small (%d bytes < %d)", path, info.Size(), minSize)
	}

	f, err := os.Open(path)
	if err != nil {
		return err
	}
	defer f.Close()

	var hdr [2]byte
	if _, err := io.ReadFull(f, hdr[:]); err != nil || !bytes.Equal(hdr[:], gzipMagic) {
		return ErrInvalidProfileHeader
	}
	return nil
}

// Merge combines multiple valid .pgo profiles into the canonical destination.
func (m *Merger) Merge(ctx context.Context, inputPaths []string, outputPath string) (*MergeReceipt, error) {
	start := time.Now()
	if outputPath == "" {
		outputPath = m.cfg.CanonicalOutput
	}

	// 1. Filter and validate input profiles
	var validInputs []string
	for _, p := range inputPaths {
		if err := ValidateProfile(p, m.cfg.MinProfileSizeBytes); err == nil {
			validInputs = append(validInputs, p)
		}
	}

	if len(validInputs) == 0 {
		return nil, ErrNoValidProfiles
	}

	// 2. Prepare temp output file for atomic replacement
	if err := os.MkdirAll(filepath.Dir(outputPath), 0o755); err != nil && filepath.Dir(outputPath) != "." {
		return nil, fmt.Errorf("pgo: create output parent dir: %w", err)
	}
	tmpOutput := outputPath + fmt.Sprintf(".tmp.%d", time.Now().UnixNano())
	defer func() {
		_ = os.Remove(tmpOutput) // Clean up temp file on failure
	}()

	// 3. If single input profile, copy directly to avoid pprof overhead
	if len(validInputs) == 1 {
		if err := copyFile(validInputs[0], tmpOutput); err != nil {
			return nil, fmt.Errorf("pgo: copy single profile: %w", err)
		}
	} else {
		// Multi-input: invoke `go tool pprof -proto -output=<tmpOutput> in1 in2 ...`
		args := []string{"tool", "pprof", "-proto", "-output=" + tmpOutput}
		args = append(args, validInputs...)

		cmd := exec.CommandContext(ctx, m.cfg.GoBinaryPath, args...)
		output, err := cmd.CombinedOutput()
		if err != nil {
			return nil, fmt.Errorf("pgo: merge command failed: %w (output: %s)", err, string(output))
		}
	}

	// 4. Verify merged output integrity
	if err := ValidateProfile(tmpOutput, m.cfg.MinProfileSizeBytes); err != nil {
		return nil, fmt.Errorf("pgo: invalid merged profile generated: %w", err)
	}

	outInfo, err := os.Stat(tmpOutput)
	if err != nil {
		return nil, fmt.Errorf("pgo: stat merged output: %w", err)
	}

	outSHA, err := computeFileSHA256(tmpOutput)
	if err != nil {
		return nil, fmt.Errorf("pgo: compute hash: %w", err)
	}

	// 5. Atomic rename to target canonical output
	if err := os.Rename(tmpOutput, outputPath); err != nil {
		return nil, fmt.Errorf("pgo: atomic swap to canonical output: %w", err)
	}

	receipt := &MergeReceipt{
		CanonicalPath:   outputPath,
		InputFiles:      validInputs,
		ValidInputCount: len(validInputs),
		OutputSizeBytes: outInfo.Size(),
		SHA256Hex:       outSHA,
		Timestamp:       time.Now().UTC(),
		DurationMs:      time.Since(start).Milliseconds(),
	}

	return receipt, nil
}

// MergeDirectory scans dir for all *.pgo and *.pprof files and merges them.
func (m *Merger) MergeDirectory(ctx context.Context, dir string, outputPath string) (*MergeReceipt, error) {
	entries, err := os.ReadDir(dir)
	if err != nil {
		return nil, fmt.Errorf("pgo: read dir %s: %w", dir, err)
	}

	var candidates []string
	for _, e := range entries {
		if e.IsDir() {
			continue
		}
		ext := filepath.Ext(e.Name())
		if ext == ".pgo" || ext == ".pprof" {
			candidates = append(candidates, filepath.Join(dir, e.Name()))
		}
	}

	return m.Merge(ctx, candidates, outputPath)
}

func copyFile(src, dst string) error {
	in, err := os.Open(src)
	if err != nil {
		return err
	}
	defer in.Close()

	out, err := os.OpenFile(dst, os.O_CREATE|os.O_WRONLY|os.O_TRUNC, 0o644)
	if err != nil {
		return err
	}
	defer out.Close()

	_, err = io.Copy(out, in)
	return err
}

func computeFileSHA256(path string) (string, error) {
	f, err := os.Open(path)
	if err != nil {
		return "", err
	}
	defer f.Close()

	h := sha256.New()
	if _, err := io.Copy(h, f); err != nil {
		return "", err
	}
	return hex.EncodeToString(h.Sum(nil)), nil
}
