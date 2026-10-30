//go:build tools

// Package tools documents the lint-toolchain install path for the posh tree.
//
// golangci-lint is intentionally NOT pinned via the blank-import tools pattern
// (//go:build tools + `_ "github.com/golangci/golangci-lint/..."`): that would
// add golangci-lint's full module graph to go.mod/go.sum and slow every
// `go mod tidy`. Instead it is installed out-of-band:
//
//	go install github.com/golangci/golangci-lint/v2/cmd/golangci-lint@latest
//
// then run against this tree with its own config:
//
//	golangci-lint run
//
// If the project ever wants a hermetic, version-pinned lint toolchain, convert
// this file to the blank-import pattern and run `go mod tidy` — the config in
// .golangci.yml stays unchanged either way.
package tools
