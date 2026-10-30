# Gap 74 — Gemini-authored test audit (posh tui/dev/wasm) — lane 4

Subject: /Users/sac/smalt/posh @ f0e0a125 ("Land remaining wave residue: ... tests"), 2026-10-30.
Executed: `cd /Users/sac/smalt/posh && go test -count=1 ./internal/tui/... ./internal/dev/... ./internal/wasm/...`
Output (verbatim): `ok smalt.dev/posh/internal/tui 0.464s / ok .../internal/dev 1.037s / ok .../internal/wasm 0.745s`, exit 0 (go1.26.0 darwin/arm64).
Status: **PARTIAL_ALIVE** — green now, Chicago-predominant, with named untested surfaces.

## 1. Chicago or London?

**Chicago-predominant; no London violation.**

- `internal/tui/tui_test.go` uses a hand-written `mockTelemetrySource` implementing the
  one-method `TelemetrySource` interface (lines 13–19). Per the smalt rule this is a
  hand-written real interface implementation, not a mock library — but it is a scripted
  data source, so the tui tests assert against injected snapshot data, not a live
  metrics registry. Asserts are on final rendered view + model state — Chicago-style
  assertions, London-free mechanism.
- `internal/dev/dev_test.go` is fully Chicago: real unix socket bind + collision refusal
  (real `net.Dial`), real fsnotify watcher over `t.TempDir()` with real file writes, and
  a bounded poll (`select` with 500ms deadline) on `w.Events()`. Two fixed 5ms sleeps
  pace the five writes inside the debounce window — write pacing inside a bounded poll,
  not a sleep-as-observation; borderline but lawful under the no-sleep doctrine.
- `internal/wasm/engine_test.go` is the strongest: real wazero engine, hand-crafted
  real WASM binaries (74-byte export module; 2-page memory module), asserts real
  execution output equals input and real BLAKE3 turnstile receipt equality, and a real
  memory-limit rejection. No doubles at all.

## 2. Green now

All three target packages pass uncached (`-count=1`), exit 0, on go1.26.0. Toolchain
does not block (contrasts with lane 3's findings on other surfaces).

## 3. Untested Gemini surfaces (no test, no falsifier)

| surface | file | gap |
|---|---|---|
| `NewDirectMetricsSource` / `DirectMetricsSource.Snapshot` | internal/tui/telemetry.go | live metrics registry → snapshot path never executed by any test; the tui tests only feed it scripted snapshots |
| `RenderAndonBadge` | internal/tui/styles.go | exported, zero tests |
| `DashboardModel.Init` + `onReload` callback path | internal/tui/dashboard.go | tests pass `nil` for onReload; reload command path unexercised |
| `Supervisor.Build` / `SpawnWorker` / `Reload` / `Run` | internal/dev/supervisor.go | the entire rebuild-spawn-reload loop — the dev supervisor's reason to exist — has no test or falsifier; only socket bind + watcher debounce are covered |
| `Watcher.Errors()` channel | internal/dev/watcher.go | error path unexercised |
| `hostLog` (WASI host fn) | internal/wasm/engine.go | registered via `WithFunc(hostLog)` but no guest module invokes it; log path never runs |
| `hostTurnstileReceipt` error paths | internal/wasm/engine.go | only the success path is witness via ExecutePolicy |

## 4. Court contradictions

None found. `internal/membrane/membrane_test.go` (TestSmaltTestEnvironment_FullLifecycle)
pins tenant→resource-group→container-app state with receipts; nothing in the tui/dev/wasm
tests asserts state the membrane forbids. The wasm receipt test actively reinforces the
turnstile-receipt court (receipt equality asserted on every execution).

## Verdict

- Chicago status: no mock-laundering; wasm tests are exemplary real-collaborator tests.
- Vacuity: dev supervisor lifecycle (Build/SpawnWorker/Reload/Run) is the largest
  untested Gemini surface — an exported, wave-landed capability with zero falsifier.
- Receipts: exits recorded above; no test file was modified.