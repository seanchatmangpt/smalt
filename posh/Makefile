GO ?= go
CGO_ENABLED ?= 0
GOFLAGS ?=

# Version stamping: git describe falls back to "dev" outside a git worktree.
VERSION ?= $(shell git describe --tags --always --dirty 2>/dev/null || echo dev)
GO_LDFLAGS ?= -s -w -X main.version=$(VERSION)

BINARY := bin/posh
PKG := ./...
SOCK := run/posh.sock

.PHONY: help build test vet lint fmt check cover bench run clean pgo pgo-bench poshvet poshvet-budget pgo-merge

help: ## List available targets
	@awk 'BEGIN { FS = ":.*##"; printf "Targets:\n" } \
		/^[a-zA-Z_-]+:.*?##/ { printf "  %-10s %s\n", $$1, $$2 }' $(MAKEFILE_LIST)

# PGO: -pgo=auto only looks in the main package dir (cmd/posh), so the
# profile is passed explicitly. -pgo=off override: make build PGO_FLAG=-pgo=off. Profile is an explicit path (see note).
PGO_PROFILE := default.pgo
PGO ?= auto
PGO_FLAG := $(shell test -f $(PGO_PROFILE) && echo "-pgo=$(PGO_PROFILE)" || echo "-pgo=off")
PGO_NOTE := $(shell test -f $(PGO_PROFILE) && echo "PGO:ON ($(PGO_PROFILE))" || echo "PGO:OFF")

build: ## CGO_ENABLED=0 static binary -> bin/posh (version-stamped, PGO if default.pgo present)
	@echo "$(PGO_NOTE)"
	CGO_ENABLED=$(CGO_ENABLED) $(GO) build -trimpath $(GOFLAGS) $(PGO_FLAG) -ldflags "$(GO_LDFLAGS)" -o $(BINARY) ./cmd/posh

test: ## Run the test suite
	$(GO) test $(GOFLAGS) $(PKG)

chaos: ## Run adversarial chaos fault injection suite with race detector
	$(GO) test -race -v -count=1 ./internal/chaos

fuzz-smoke: ## Fast 10s smoke fuzzing across all native Go fuzz targets
	$(GO) test ./internal/server -fuzz=^FuzzFrameParser$$ -fuzztime=5s
	$(GO) test ./internal/server -fuzz=^FuzzSlowlorisChunking$$ -fuzztime=5s
	$(GO) test ./internal/server -fuzz=^FuzzFrameBoundaryInjection$$ -fuzztime=5s
	$(GO) test ./internal/api -fuzz=^FuzzDecodeRequest$$ -fuzztime=5s
	$(GO) test ./internal/api -fuzz=^FuzzDecodeResponse$$ -fuzztime=5s

sbom: ## Generate CycloneDX JSON SBOM using cyclonedx-gomod
	@which cyclonedx-gomod >/dev/null 2>&1 || (echo "installing cyclonedx-gomod..." && go install github.com/CycloneDX/cyclonedx-gomod/cmd/cyclonedx-gomod@v1.7.0)
	cyclonedx-gomod app -json -output posh-sbom.cdx.json ./cmd/posh
	@echo "SBOM generated at posh/posh-sbom.cdx.json"

vet: ## go vet
	$(GO) vet $(PKG)

poshvet: ## Build and run custom poshvet static safety analyzers
	$(GO) build -o bin/poshvet ./cmd/poshvet
	$(GO) vet -vettool=./bin/poshvet ./cmd/posh ./internal/server ./internal/egress ./internal/receipt

poshvet-budget: ## Run poshvet with escape budget pass (-budget) for zero-allocation invariants
	$(GO) build -o bin/poshvet ./cmd/poshvet
	$(GO) vet -vettool=./bin/poshvet -budget ./cmd/posh ./internal/server ./internal/egress ./internal/receipt

lint: vet ## Lint (currently aliased to vet)

fmt: ## gofmt the tree
	$(GO) fmt $(PKG)

check: fmt vet lint test ## Full gate: fmt + vet + lint + test

cover: ## Coverage profile + total %
	$(GO) test $(GOFLAGS) -coverprofile=coverage.out $(PKG)
	$(GO) tool cover -func=coverage.out | awk '/^total:/ { printf "total coverage: %s\n", $$3 }'

bench: ## Placeholder: benchmarks (none admitted yet)
	@echo "no benchmarks admitted yet"; exit 0

run: build ## Build then boot the membrane; clean up socket on exit
	@mkdir -p run
	./$(BINARY) -config posh.yaml; rc=$$?; rm -f $(SOCK); exit $$rc

clean: ## Remove build artifacts
	rm -f $(BINARY) coverage.out
	rm -rf run
	# posh/var/ (andon receipt chain, default posh/var/andon.jsonl) is NOT
	# swept here — it is durable state, deliberately outside posh-clean's
	# rm -rf tmp/posh as well.

# --- PGO (profile-guided optimization) ---
# Capture protocol + embedded capture bench: pgo/README.md. `make pgo`
# stages the bench into internal/server as a temp _test.go, captures the
# profile over the REAL UDS listener, removes the temp file, rebuilds.

pgo: ## Recapture PGO profile + rebuild: real-UDS load bench -> default.pgo -> PGO build
	@mkdir -p pgo
	@sed -n '/^<!-- BENCH-SOURCE/,/^BENCH-SOURCE -->/p' pgo/README.md | sed '1d;$$d' > internal/server/pgo_load_tmp_test.go
	$(GO) test ./internal/server -run '^$$' -bench BenchmarkMembraneLoad -benchtime 3s -cpuprofile $(PGO_PROFILE).tmp
	@rm -f internal/server/pgo_load_tmp_test.go
	mv $(PGO_PROFILE).tmp $(PGO_PROFILE)
	$(MAKE) build

pgo-merge: ## Safely collect and merge .pgo profiles into canonical default.pgo
	$(GO) run ./cmd/pgo-merge -out $(PGO_PROFILE) -dir pgo

pgo-bench: ## A/B PGO vs non-PGO: min-of-3 BenchmarkMembraneLoad + BenchmarkWriteFrame
	@echo "== non-PGO baseline =="
	@sed -n '/^<!-- BENCH-SOURCE/,/^BENCH-SOURCE -->/p' pgo/README.md | sed '1d;$$d' > internal/server/pgo_load_tmp_test.go
	GOFLAGS="$(GOFLAGS) -pgo=off" $(GO) test ./internal/server -run '^$$' -bench 'BenchmarkMembraneLoad|BenchmarkWriteFrame' -benchmem -benchtime=1s -count=3 | tee /tmp/posh-bench-nopgo.txt
	@rm -f internal/server/pgo_load_tmp_test.go
	@echo "== PGO build (-pgo=default.pgo explicit) =="
	@sed -n '/^<!-- BENCH-SOURCE/,/^BENCH-SOURCE -->/p' pgo/README.md | sed '1d;$$d' > internal/server/pgo_load_tmp_test.go
	GOFLAGS="$(GOFLAGS) -pgo=$(PGO_PROFILE)" $(GO) test ./internal/server -run '^$$' -bench 'BenchmarkMembraneLoad|BenchmarkWriteFrame' -benchmem -benchtime=1s -count=3 | tee /tmp/posh-bench-pgo.txt
	@rm -f internal/server/pgo_load_tmp_test.go
