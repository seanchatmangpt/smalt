# GAP-75: Gemini-delta vs coordinator-wave file ownership map (posh/, 2026-10-30)

Lane 5/6, read-only cross-reference. Subjects: Gemini delta = `posh/internal/{tui,wasm,dev}/`,
`posh/cmd/posh/main.go` changes, `posh/go.mod`. Wave lands = `posh/internal/andon/` (L41+F8),
`posh/internal/metrics/` (C3), `posh/internal/server/server.go` (GoDX 3/5), `posh/internal/config`
(GoDX 11), `cmd/posh/main.go` wiring, `posh.yaml` + `internal/config/config.go` allowlist (L42),
`posh/internal/adapter/generated_*.go` (L42/F12). Evidence: `git status`/`git diff` on
`/Users/sac/smalt/posh` at HEAD f0e0a125.

## Answers to the three directed checks

1. **Does cmd/posh/main.go now contain BOTH wave AND Gemini changes? YES — SHARED-SEAM, the
   hottest file in the tree.** Baseline (HEAD, 248 lines) already carried logging/pprof/version;
   the working tree (703 lines, +481/-21) carries wave-side additions (metrics registry +
   `startMetricsIfConfigured`/`POSH_METRICS_ADDR`, `andOnTransitionHook` into
   `internal/metrics` (C3), `WithMetrics(reg)` on server, `POSH_LISTEN_FD` socket
   inheritance, `diag.*` render calls) **and** Gemini-side additions (the `dev` and `tui`
   subcommands importing `internal/dev` + `internal/tui`, `runDev`/`runTUI` which construct a
   `metrics.New()` registry and a `doctor.Options` of their own). Both sides touch the same
   `main()` subcommand switch and the same import block in one uncommitted diff — neither
   side is attributable by file history alone; blame will be all-or-nothing at integration.
2. **Does the dev watcher (fsnotify) watch files regen-check/L42 also owns? YES.**
   `internal/dev/watcher.go` `DefaultWatcherConfig(".", "cmd", "internal")` watches
   extensions `.go .yaml .yml .toml` recursively with IgnorePrefix
   `[".git","bin","run","var","tmp",".hypothesis","_build","deps"]`. That includes:
   `internal/adapter/generated_*.go` (L42/F12-owned), `posh.yaml` and
   `config/egress_allowlist.generated.yaml` (L42-owned), `internal/config/config.go` and
   `internal/metrics/*.go` (wave-owned). Supervisor wires it at
   `internal/dev/supervisor.go:206` (`DefaultWatcherConfig(".", "cmd", "internal")`). A
   `just posh-regen-check` run (regen → `gofmt -w posh/internal/adapter/*.go`, byte-compare)
   while `posh dev` is live fires a reload rebuild per generated file touched —
   read-modify-write churn on wave-owned bytes via a Gemini-owned trigger.
3. **Where does the next collision fire?** Ranked:
   a. **`posh/cmd/posh/main.go` import block + subcommand switch** (HIGH): two logical
      authors, one uncommitted hunk region; the next lane appending a subcommand
      (e.g. `poshvet`, `pgo-merge` wiring) edits the same switch. Highest read-modify-write
      risk of the wave (same class as F14 posh:sidecar tag collision, DOD13
      posh_doctor.sh double-write — both witnessed this wave on single-file multi-author
      seams).
   b. **`posh/go.mod`** (HIGH): single require block; wave-added deps
      (testify, golang.org/x/tools, possibly ggen-flows) and Gemini deps
      (bubbletea, lipgloss, fsnotify, wazero) are interleaved in one alphabetical block,
      plus a `go 1.23 → go 1.26.0` toolchain bump attributable to neither side alone.
   c. **`internal/adapter/generated_*.go` via the watcher** (MEDIUM): not a write conflict
      (Gemini never writes them) but a trigger conflict — regen-check rewrites while
      `posh dev` watches; every generated-file land causes a supervisor reload storm.
      Fix candidate: add `internal/adapter` (or `config/`) to IgnorePrefix, or
      gate reload on `.go` outside `generated_`.
   d. **`internal/server/server.go`** (LOW-MED): wave-owned (GoDX 3/5, +107/-21);
      Gemini touches it only through `runDev`'s socket path selection
      (`cfg.Socket` fallback `run/posh.sock` duplicated from config defaults) —
      duplicated default is drift risk, not collision.
   e. **`internal/andon/`, `internal/metrics/`, `internal/config/`** (LOW): wave-owned,
      Gemini consumes read-only via `andOnTransitionHook` / `metrics.New()` /
      `config.Load`. `andon.OnTransition` is a package-global var hook set from main.go —
      if Gemini's `runTUI` path ever sets it too, last-writer-wins on a global.
   f. **`posh.yaml` / `config/egress_allowlist.generated.yaml`** (LOW): L42-owned,
      regen-check fail-closed on drift; Gemini not a writer.

## File-level ownership map

| File/dir | Owner | Collision risk | Note |
|---|---|---|---|
| `posh/internal/tui/` | GEMINI-TOUCHED | — | untracked, self-contained (bubbletea/lipgloss) |
| `posh/internal/wasm/` | GEMINI-TOUCHED | — | untracked, wazero |
| `posh/internal/dev/` | GEMINI-TOUCHED | MEDIUM (c) | fsnotify watcher overlaps L42 regen surfaces |
| `posh/cmd/posh/main.go` | SHARED-SEAM (wave + Gemini) | HIGH (a) | both author sets in one uncommitted diff |
| `posh/go.mod`/`go.sum` | SHARED-SEAM | HIGH (b) | interleaved require block + go 1.26 bump |
| `posh/internal/andon/` (L41+F8) | WAVE-TOUCHED | LOW | Gemini reads hook only |
| `posh/internal/metrics/` (C3) | WAVE-TOUCHED | LOW | consumed read-only by runDev/runTUI |
| `posh/internal/server/server.go` (GoDX 3/5) | WAVE-POUCHED → WAVE-TOUCHED | LOW-MED (d) | socket-default duplication in runDev |
| `posh/internal/config/` (GoDX 11, L42) | WAVE-TOUCHED | LOW | |
| `posh.yaml`, `posh/config/egress_allowlist.generated.yaml` | WAVE-TOUCHED (L42) | LOW | regen-check fail-closed |
| `posh/internal/adapter/generated_*.go` (L42/F12) | WAVE-TOUCHED | MEDIUM (c) | watcher trigger overlap, not write overlap |
| `posh/cmd/posh/diff_pprof_test.go` | WAVE-TOUCHED | — | telemetry/diffpprof lane |

## Status

ALIVE (evidence: `git diff posh/cmd/posh/main.go` +481/-21 vs HEAD f0e0a125;
`git diff posh/go.mod`; `sed -n` reads of `internal/dev/watcher.go` /
`internal/dev/supervisor.go:206`; `justfile.d/58-posh.just:779-830` regen-check paths).
PARTIAL on attribution: both author sets are merged in the same uncommitted working-tree
diff — per-hunk Gemini-vs-wave attribution inside main.go/go.mod is UNVERIFIED (no
per-lane diff receipts inspected).
