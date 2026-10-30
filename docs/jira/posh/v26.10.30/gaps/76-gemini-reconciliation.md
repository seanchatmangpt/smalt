# G76 — Gemini-delta reconciliation (lane 6 of 6), wave v26.10.30

- Subject: `/Users/sac/smalt/posh` Go module (uncommitted Gemini-delta state),
  read from the lane's canonical checkout `/Users/sac/cai/courtroom-platform-az`.
- Read date: 2026-10-30. gaps/71-75 have NOT landed (only `gaps/69-dod-execution.md`
  exists in the courtroom checkout) — dispositions synthesized from direct reads of
  the delta itself.
- ALIVE evidence (this session, exit 0): `go build ./...` and
  `go test ./internal/tui/ ./internal/wasm/ ./internal/dev/ ./internal/bootstrap/`
  (module `smalt.dev/posh`; all four packages `ok`).

## Per-component dispositions

### 1. internal/tui/ (bubbletea dashboard) — KEEP, with a RECONCILE seam

- `dashboard.go` (tea.Model), `styles.go`, `telemetry.go` (`TelemetrySource` interface
  + `DirectMetricsSource` over `metrics.Registry` and `doctor.Options`).
- Composes with charter: the dashboard is a `TelemetrySource`-abstracted viewer, so it
  can render anything that exposes a snapshot. Verdict: KEEP the component; RECONCILE
  the data path — the TUI currently invents its own snapshot shape from in-memory
  metrics and never reads the canonical `scripts/posh_status.sh` (7082 bytes) /
  `scripts/dx_report.py` (2419 bytes) outputs. Wire those outputs (or delete the
  scripts) so exactly one status surface survives.
- Close condition: a `ScriptTelemetrySource` parses canonical `posh_status.sh` /
  `dx_report.py` output, OR the scripts are retired in favor of the in-process source
  — either way a gate fails if two status surfaces coexist.
- Integration note: seam is the single `TelemetrySource` interface; TUI can land ahead
  of the adapter. Adapter is a follow-up lane owning `internal/tui/telemetry.go` + new
  `internal/tui/source_script.go` (disjoint from other lanes).

### 2. internal/wasm/ (wazero engine) — KEEP (it IS the court host)

- `engine.go` (223 L): wazero runtime with a `posh_host` host module exposing
  `hostTurnstileReceipt` + `hostLog`; `CompileModule`/`ExecutePolicy` return a
  `[32]byte` receipt alongside the result — receipts as the register of truth.
- Does not duplicate a court; it is the execution substrate a court drives. Guest
  modules supply policy; host mints receipts.
- Close condition: one integration court drives `ExecutePolicy` end-to-end with a real
  guest module and asserts on the returned `[32]byte` receipt (current
  `engine_test.go` is unit-level only).
- Integration note: disjoint ownership of `internal/wasm/`; no dependency on TUI/dev
  lanes. Hard floor: wazero v1.12.0 requires go 1.25 — see blocking row.

### 3. internal/dev/ (fsnotify watcher + supervisor) — RECONCILE (scoped, not killed)

- `watcher.go` (198 L, fsnotify recursive) + `supervisor.go` (253 L): on change →
  `go build -trimpath` → exec binary with `-config`. A generic rebuild-restart loop.
- Does NOT currently serve posh-bootstrap's regen needs: `internal/bootstrap/setup.go`
  (`Run(ctx, SetupOptions)`) is one-shot setup, never invoked by watcher or
  supervisor; no regen hook exists. As-is it duplicates what an outer loop (justfile /
  CI) already does generically. Not a stateless violation, so not KILL; it becomes
  charter-serving only if wired to bootstrap regen.
- Close condition: either (a) the watcher's change-event routes to
  `internal/bootstrap.Run` (regen-on-change), making it serve posh-bootstrap's regen
  needs — disposition flips to KEEP — or (b) it is retired via the zero-witnessed-
  firing pruner lane (C23 pattern).
- Integration note: coordinator lands this only together with (a); a standalone
  rebuild-restart loop is scope creep against the charter.

### 4. go.mod 1.26 bump + new deps — BLOCKING ROW (resolution: keep 1.26, fix the pin)

Constraint evidence (all re-read this session):

| constraint source | value | consequence |
|---|---|---|
| `posh/go.mod` directive | go 1.26.0 | module floor |
| wazero v1.12.0 directive | 1.25.0 | hard floor 1.25 |
| bubbletea v1.3.10 directive | 1.24.0 | floor 1.24 via TUI |
| golang.org/x/tools v0.52.0 (+ x/sys, x/sync, x/mod) | 1.26.0 | floor 1.26 while at v0.52 |
| CI `.github/workflows/posh-go.yml:45` | `go-version-file: posh/go.mod` | CI auto-derives 1.26 — CI is NOT the blocker |
| `docker/Dockerfile.posh:2` | `golang:1.23-alpine` | THE blocker: cannot build a 1.26 module except by network toolchain fetch (breaks hermetic build) |
| `posh/Dockerfile:12` | `golang:1.26-alpine` | already correct |
| doctor | local go1.23.4 | local builds rely on GOTOOLCHAIN=auto fetch of 1.26 |

- Code evidence: no post-1.23 language/stdlib features in non-test code (greps for
  math/rand/v2, rangefunc, iterators/`iter.`, new maps/slices fns, omitzero — zero
  non-test hits). The floor is dependency-driven, not language-driven.
  `internal/server/server.go:537` even documents go1.23 *semantics* compat (writev
  iovec caching differs on go1.24+) — behavior-compat code, not a lower floor.
- Concrete resolution: **keep the 1.26.0 directive** ("Gemini lowers directive" is
  REFUTED by dep floors: x/tools 1.26, wazero 1.25, bubbletea 1.24; lowering requires
  downgrading x/tools and fighting the other floors). **Edit
  `docker/Dockerfile.posh:2` to `golang:1.26-alpine`** (matches posh/Dockerfile:12,
  CI, and dep floors). CI needs no change (go-version-file auto-follows). "Toolchain
  auto" is already the local behavior and needs no directive change.
- Close condition: `docker/Dockerfile.posh` builder stage is `golang:1.26-alpine` and
  `docker build -f docker/Dockerfile.posh` succeeds; a grep gate fails CI if any
  `golang:` image pin under `docker/` is below the go.mod directive.
- Integration note: one-line diff, coordinator-owned; should ride the same commit as
  go.mod/go.sum.

### 5. Dockerfile/CI fallout — PARTIAL, one edit

- `posh/Dockerfile:12` already `golang:1.26-alpine` — correct as-is.
- `docker/Dockerfile.posh:2` still `golang:1.23-alpine` — the single required edit
  (row 4). Runtime stages (`scratch` at Dockerfile.posh:15; distroless in
  posh/Dockerfile) are fine for static binaries.
- CI (`posh-go.yml`) needs no change: the "matrix" IS go.mod via go-version-file.
  Dockerfile.posh has no CI or Makefile/Justfile consumers (grepped: zero refs), so
  the stale pin has been latent, not breaking, until someone builds it.
- Close condition: shared with row 4.
- Integration note: fold into the go.mod commit; no separate lane needed.

## Status line

- Components tui / wasm / dev / bootstrap: ALIVE — `go build ./...` and targeted
  `go test` exited 0 this session (subsequent runs cached).
- Blocking row: RESOLVED — keep go 1.26.0 (dep floors 1.24/1.25/1.26); fix
  `docker/Dockerfile.posh` golang pin to 1.26-alpine; CI auto-follows via
  go-version-file.
- Overall lane 6: **PARTIAL** — dispositions complete; one edit queued
  (Dockerfile.posh golang pin); gaps/71-75 absent, so no cross-lane reconciliation was
  possible.
