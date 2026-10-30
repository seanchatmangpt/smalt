# Gemini delta inventory — posh/ uncommitted work

# Gemini Delta Inventory — posh/ uncommitted (Gemini lane) work

As-of: 2026-10-30 14:15–14:20 PDT. Repo: /Users/sac/smalt (branch main). Gemini agents are concurrently writing to /Users/sac/smalt/posh (operator-confirmed Explore-mode work, not drift). Read-only lane; no posh/ files touched.

## Volatility note

Writes are IN FLIGHT: `internal/court/` and `internal/membrane/` mtimes advanced from 13:2x to 14:09–14:11 between two reads during this inventory; `internal/api/api.go` at 14:00. Total 70 status rows (17 modified + ~53 untracked paths, many untracked dirs). Treat all entries below as-of 14:15; re-stat before consuming.

## Modified tracked files (git diff HEAD --stat, posh/)

| path | class | intent (from comments) | membrane composition |
|---|---|---|---|
| posh/go.mod / go.sum | engine deps | go 1.23→1.26.0; adds bubbletea+lipgloss (TUI), fsnotify (dev watcher), wazero (WASM), testify, golang.org/x/tools (poshvet) | composes; deps serve the new trees |
| posh/Dockerfile | build | distroless purity: golang:1.26 builder, BuildKit cache mounts, `-buildid=`, removes busybox shell stage; UDS-only (no EXPOSE) preserved | composes (UDS-only kept) |
| posh/cmd/posh/main.go (+481 lines) | engine wiring | DEV-only pprof on private mux (POSH_DEBUG=1), opt-in metrics via POSH_METRICS_ADDR (default off, loopback, private mux so pprof/metrics "can never leak into any serving path of the membrane"), andon transition metrics hook | composes |
| posh/cmd/andon/main.go | test scaffold | +56 lines: outcome tests wiring | composes |
| posh/internal/server/server.go | engine | `WithInheritedListener` (pre-bound UDS from dev supervisor, never re-binds/unlinks socket), `WithMetrics` (posh_requests_total{op,transport,code}) | composes — still UDS-first, metrics opt-in |
| posh/internal/doctor/* (doctor.go +171, telemetry.go, remediation.go, kube_healer.go, predictive.go, circuit_breaker.go, jsonld.go + tests) | dev/observability | probes over `net.DialTimeout("unix", …)` UDS; kube_healer is the one TCP-capable path (k8s API) via `egress.Control` fenced dialer; circuit breaker, predictive probes, JSON-LD output | composes: all self-probes are UDS; external egress gated through egress fence |
| posh/internal/andon/{machine.go,helpers.go,hooks.go,andon_test.go} | engine | on-transition hook (`andon.OnTransition`) → metrics counter; outcome tests | composes |
| posh/Makefile, README.md, KNOWN_DIVERGENCES.md, docs/configuration.md | docs/build | docs/config for the new surfaces | n/a |

## New (untracked) trees — per-file inventory

| tree | files | class | intent | membrane composition |
|---|---|---|landing|---|
| internal/membrane/ | 2 (13:2x→14:11, ACTIVE) | other (platform) | `NewSmaltTestEnvironment`: tenant/matter fixture provisioning w/ BLAKE3 settlement receipts; imports court+receipt+storage | PARTIAL — in-memory in-process env; no UDS op surface yet, no network; stateless law holds (fixtures, not persistent state) |
| internal/court/ | 2 (14:09, ACTIVE) | other (governance) | `EvaluateGuard`: Jidoka/Andon line-stop guard over platform configs (zero-trust/sovereign-isolation violations → RED, exit 1); AndonGreen/Yellow/Red | composes — refusal verdicts are typed, wired to andon states |
| internal/storage/ | 2 (14:10, ACTIVE) | other (platform) | Azure Blob lifecycle (CRMH 14-day retention) management policy models + in-memory store | composes — data-plane models only, no network |
| internal/api/api.go (+fuzz_test.go) | 2-3 (api.go 14:00) | engine | op surface types (Request/Response, typed codes) | composes — this IS the op registry surface |
| internal/tui/ | 4 (≤13:00) | TUI dashboard | bubbletea/lipgloss developer console: `DashboardModel`, TelemetrySnapshot (andon, throughput, p50/95/99, reload times), andon color styles | composes — reads via `TelemetrySource` interface fed by doctor UDS probes; `mockTelemetrySource` in tests is a test-side simple fake (Chicago-exception, in tests only) |
| internal/wasm/ | 2 (≤13:02) | WASM engine | wazero (pure-Go, zero CGO) plugin sandbox: `transform_payload` export, memory bounds, `ErrPluginTimeout`/`ErrMemoryExceeded`/`ErrFunctionMissing`, receipt-wrapped | composes — sandboxed WASI, receipt-wrapped, no network |
| internal/dev/ | 3 (≤12:59) | dev watcher | fsnotify watcher + supervisor: rebuild/restart, socket inheritance handoff to server (`WithInheritedListener`), `shouldHandle` filter rules | composes — hands the UDS listener to the membrane server, does not open its own network surface |
| internal/poshvet/ | 7 (≤13:27) | test scaffold (static analysis) | go/analysis multichecker; `fencednet.go` enforces POSHVET-002: any bare `net.Dialer`/`http.Client` without `egress.Control` fails vet — mechanical fence for the egress law | composes — makes the egress fence mechanically enforced |
| internal/egress/ | 2 | engine (fence) | DNS/Socket tripwire dialer `Control` fail-closed egress | composes (this is the fence) |
| internal/metrics/ | 2 | observability | `Registry`, posh_requests_total/andon_transitions counters, Prometheus text | composes — opt-in, private mux |
| internal/mutation/ , internal/chaos/ , internal/replay/ , internal/mock/ | 2 each | test scaffold | mutation testing, chaos courts, replay, simple fakes | composes |
| internal/pgo/ + cmd/pgo-merge + default.pgo | 3 | build | PGO profile merge for optimized builds | n/a (build) |
| internal/completion/ , internal/diag/ , internal/bootstrap/ , internal/uniqueintern/ , internal/swissmap/ , internal/adapter/ , internal/armclient/ , internal/telemetry/ (19 files) , internal/receipt/simd_research.go | various | engine/other | DX/completion, diagnostics catalog, bootstrap, internal perf research (SIMD, swissmap, intern) — perf research, no network | composes or perf-local |
| docs/ (ci-chaos, compiler-safety, dx, observability v26.10.30 + architecture briefs) | ~7 | docs | design briefs for the above | n/a |
| tests/ , tmp/ , completions/ , config/ | various | scaffold/build | test corpus, build scratch | n/a |

## Composition verdict per tree (specified scope)

- **TUI dashboard (internal/tui/)**: COMPOSES. Pure consumer: `TelemetrySource` interface over doctor's UDS probes; renders andon state, latency percentiles, reload metrics. No socket binding, no own state beyond a snapshot struct.
 Stateless law holds. Test fake is test-local.
- **WASM engine (internal/wasm/)**: COMPOSES. wazero pure-Go WASI sandbox (zero CGO), memory/deadline bounds, typed errors, receipt-wrapped plugin execution, hand-crafted module in tests. No network, stateless per-call.
- **dev watcher (internal/dev/)**: COMPOSES. fsnotify rebuild/restart supervisor that inherits/hands off the pre-bound UDS listener to the membrane server (`WithInheritedListener` — server never re-binds or unlinks the socket). No direct network; diag-integrated.
- **cmd/posh/main.go wiring**: COMPOSES. pprof and /metrics on private muxes, opt-in via POSH_DEBUG / POSH_METRICS_ADDR, loopback default, explicitly documented so the surface "can never leak into any serving path of the membrane".
- **New 14:0x trees (court, membrane, storage, api)**: PARTIAL / in-flight. They form a new platform provisioning chain (fixture → guard → blob-policy) with BLAKE3 receipts — conceptually aligned with the receipt/andon law, but not yet UDS-surfaced through the op registry; observed actively changing at 14:09–14:11.
- **Dockerfile**: COMPOSES (UDS-only preserved, distroless purity increased; note: pure-distroless means no shell — k8s probes must exec /bin/posh directly).

## Bypass check (direct network / own state)

- `http.ListenAndServe` only in cmd/posh/main.go — pprof/metrics debug muxes, DEV-only/opt-in, loopback, private mux (documented deliberate exceptions, not membrane bypass).
- kube_healer.go is the only TCP-capable path (k8s API) and routes through the `egress.Control` fenced dialer.
- `net.Dial`/`DialTimeout("unix", …)` everywhere else: all UDS to the membrane.
- poshvet/POSHVET-002 now makes bare dialers a vet failure — the egress law is mechanically fenced.

## Status

ALIVE (inventory observed 2026-10-30 14:15–14:20 PDT; volatile trees court/membrane/storage/api re-stat before use).
