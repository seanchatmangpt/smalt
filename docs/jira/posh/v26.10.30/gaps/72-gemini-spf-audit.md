# Gap 72 — Gemini-delta lane 2: posh TUI/dev/wasm/cmd audit vs SPAF contract + POSH charter

Status: **PARTIAL_ALIVE** (code read at `/Users/sac/smalt/posh` @ 845c1318, 2026-10-30; no tests executed)
Subject: `posh/internal/tui/`, `internal/dev/`, `internal/wasm/`, `cmd/` delta.

## (1) Zero domain state (charter Rule 1/2 — stateless plumbing)

**MET.**
- `internal/tui/dashboard.go:17-28` — `DashboardModel` holds only view state:
  snapshot, log ring (capped at `maxLogs: 8`, line 47), window size, toggles.
  No persistence, no domain data; every 250 ms tick re-polls a
  `TelemetrySource` (`dashboard.go:100-107`).
- `internal/tui/telemetry.go:32-46` — `DirectMetricsSource` caches only doctor
  probe results with a 3 s throttle (`telemetry.go:64-71`) — rebuildable live
  state, explicitly permitted by charter Law 2.
- `internal/dev/watcher.go` — pure fsnotify event plumbing; the only retained
  state is a debounce timer + pending path (watcher.go:126-160); nothing
  written to disk.
- `internal/dev/supervisor.go` — retains a pre-bound UDS listener fd
  (`supervisor.go:58-92`), active worker `exec.Cmd`, and writes two build
  artifacts: `bin/posh(.next)` (`supervisor.go:104-107`) and `run/posh.sock`
  (removed on Close, `supervisor.go:246-251`). All rebuildable build/socket
  state, no domain state, no DB. The lone `net.Dial` is a localhost UDS
  liveness probe (`supervisor.go:67`) — not egress.

## (2) internal/wasm/engine.go vs BEAM wasmex/Affidavit.WasmEngine

**VIOLATION (competitor, not charter Phase-4)** — mitigated by being unwired.
- `internal/wasm/engine.go:13-19,43-79` — a full Go-native wazero v1.12.0
  runtime (`posh/go.mod:10`) with a custom `posh_host` host ABI
  (`posh_turnstile_receipt`, `posh_log`); `ExecutePolicy` (engine.go:151-223)
  calls a guest `transform_payload` entrypoint and returns `[32]byte` BLAKE3
  receipts via `internal/receipt`'s host kernel.
- This is neither the BEAM `Smalt.Affidavit.WasmEngine`
  (`lib/smalt/affidavit/wasm_engine.ex:65-71`: sha256-sidecar-pinned
  `priv/wasm/affidavit_wasm.wasm`, WASI import allowlist, required exports
  `af_abi_version/af_alloc/af_call/af_free`, fail-closed
  `{:error, : engine_unavailable}`) nor its Go port. The two runtimes share no
  artifact, no ABI (`transform_payload` vs `af_call` in/out packing differs),
  no admission gate: the Go engine compiles arbitrary modules by name with
  **no sha256 pin, no import allowlist beyond WASI defaults, no
  `af_abi_version` handshake** (engine.go:123-132: `CompileModule` stores
  whatever bytes it is handed).
 vs the BEAM engine's fail-closed admission (`wasm_engine.ex:65-71`).
- Not the charter's Phase-4 `#![no_std] Rust BLAKE3 kernel` either (charter
  lines 13-16): that is a Rust no_std kernel, not a Go wasm runtime.
- Mitigation: `grep -rn "posh/internal/wasm"` over `posh/` shows **zero
  non-test consumers** — the engine is not reachable from any cmd/ entrypoint,
  the server, or the membrane. It is dead code until admitted through a
  receipted wiring change, and does not bypass the op-registry dispatch today.
- Verdict: **competing runtime, currently unwired (dead code)**. Required
  before any wiring: sha256 sidecar pin + WASI import allowlist + required
  export admission mirroring `wasm_engine.ex` (or deletion per ERRC).

## (3) Egress / stateless / dispatch-bypass sweep

**MET (no violations found in the audited delta).**
- Egress fence: `internal/egress/egress.go` (pre-DNS allowlist fence + post-DNS
  socket tripwire via `net.Dialer.Control`) is enforced where HTTP transport is
  constructed. None of `internal/tui`, `internal/dev`, `internal/wasm`,
  `cmd/andon` construct an unfenced dial: the only network construction in the
  delta is the localhost UDS listener/probe (supervisor.go:67,79), which is
  membrane-local, not egress. `cmd/andon/main.go:32` uses `internal/andon`
  (in-process andon state, no dial). Direct `http.Get/Post/Client{}` grep over
  the delta: zero hits.
- Persistence: only posh.yaml (read), bin/ build outputs and run/posh.sock
  (supervisor.go:104-107,246-251). No DB, no file writes in tui/wasm/dev.
  `gaps/73-gemini-toolchain.md` earlier found **this repo
  (courtroom-platform-az) contains no posh Go tree** — the audited tree is
  the canonical checkout at `/Users/sac/ smalt/posh`. Existing receipts stay
  under `var/`.
- Op-registry dispatch: no bypass — nothing in the delta dispatches ops at
  all; the wasm engine is unreachable (see (2)).

## Receipt

- Subject: /Users/sac/smalt/posh @ 845c1318 (one commit, "Land POSH wave v26.10.30")
- Commands: file reads + grep sweeps (internal/tui, internal/dev, internal/wasm, cmd/, lib/smalt/affidavit/wasm_engine.ex, charter 00-charter.md)
- Status: PARTIAL_ALIVE — static read audit, no builds/tests run (read-only lane)
