// Command pgo-merge combines multiple .pgo runtime profiles into a canonical
// default.pgo profile for Go Profile-Guided Optimization builds.
package main

import (
	"context"
	"encoding/json"
	"flag"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"time"

	"smalt.dev/posh/internal/pgo"
)

func main() {
	outPath := flag.String("out", "default.pgo", "canonical output profile path")
	dirPath := flag.String("dir", "pgo", "directory containing .pgo or .pprof files to merge")
	asJSON := flag.Bool("json", false, "output merge receipt in JSON format")
	flag.Parse()

	var inputs []string
	if flag.NArg() > 0 {
		inputs = flag.Args()
	} else {
		// Scan directory
		entries, err := os.ReadDir(*dirPath)
		if err == nil {
			for _, e := range entries {
				if e.IsDir() {
					continue
				}
				ext := filepath.Ext(e.Name())
				if ext == ".pgo" || ext == ".pprof" {
					inputs = append(inputs, filepath.Join(*dirPath, e.Name()))
				}
			}
		}

		// Also check run/profiles if available
		if runEntries, err := os.ReadDir("run/profiles"); err == nil {
			for _, e := range runEntries {
				if e.IsDir() {
					continue
				}
				ext := filepath.Ext(e.Name())
				if ext == ".pgo" || ext == ".pprof" {
					inputs = append(inputs, filepath.Join("run/profiles", e.Name()))
				}
			}
		}

		// If default.pgo exists and nothing else found, keep default.pgo
		if len(inputs) == 0 {
			if _, err := os.Stat(*outPath); err == nil {
				inputs = append(inputs, *outPath)
			}
		}
	}

	if len(inputs) == 0 {
		fmt.Fprintf(os.Stderr, "pgo-merge: no profile candidates found in %s or arguments\n", *dirPath)
		os.Exit(0)
	}

	merger := pgo.NewMerger(pgo.MergerConfig{
		CanonicalOutput: *outPath,
	})

	ctx, cancel := context.WithTimeout(context.Background(), 2*time.Minute)
	defer cancel()

	receipt, err := merger.Merge(ctx, inputs, *outPath)
	if err != nil {
		fmt.Fprintf(os.Stderr, "pgo-merge error: %v\n", err)
		os.Exit(1)
	}

	if *asJSON {
		b, _ := json.MarshalIndent(receipt, "", "  ")
		fmt.Println(string(b))
	} else {
		fmt.Printf("PGO MERGE SUCCESS -> %s\n", receipt.CanonicalPath)
		fmt.Printf("  Inputs merged:  %d files (%s)\n", receipt.ValidInputCount, strings.Join(receipt.InputFiles, ", "))
		fmt.Printf("  Output size:    %d bytes\n", receipt.OutputSizeBytes)
		fmt.Printf("  SHA-256:        %s\n", receipt.SHA256Hex)
		fmt.Printf("  Merge duration: %d ms\n", receipt.DurationMs)
	}
}
