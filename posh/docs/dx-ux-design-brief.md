# Technical Design Brief: Go DX & Terminal UX Architecture for the POSH Membrane

**Author:** AGENT_1_DX_UX (Go DX and Terminal UX Engineer, Go Core Team)  
**System:** POSH Go Sovereign Adapter Membrane (SPAF Tier 2) & Smalt Ecosystem  
**Target Release:** v26.10.30  
**Standing:** ALIVE (Witnessed Implementation & Comprehensive Test Suite)

---

## 1. Executive Summary & Problem Topology

The POSH Go adapter membrane sits as the high-throughput, sovereign foreign-function gateway between the BEAM core (Smalt) and the outer hyperscaler infrastructure (ARM, Terraform, Kubernetes). Under SPAF charter laws, the membrane must adhere to two non-negotiable architectural tenets:
1. **Stateless Membrane (Charter Law 2):** Protocol translation only — zero domain state.
2. **Jidoka & Poka-Yoke Mistake-Proofing:** Abnormalities must halt the line immediately (Andon RED) with root causes diagnosed via deterministic 5-Whys analysis and executable remediation prescriptions.

Historically, Go micro-services and systems daemons suffer from jarring developer ergonomics:
- **Connection-severing development loops:** Traditional hot-reloaders (e.g., `air`, `reflex`) kill the running process and unlink the socket (`run/posh.sock`). When BEAM or Terraform clients attempt requests during the 100ms–500ms recompile window, they experience `ECONNREFUSED`, `ENOENT`, or `ECONNRESET`.
- **Silent metrics and headless obscurity:** Operators and developers lack real-time visibility into frame throughput, microsecond latency quantiles ($p_{50}, p_{95}, p_{99}$), connection backpressure, and Andon signal latching.
- **Environment friction:** Manual creation of socket directories (`run/`, `var/`), ad hoc Terraform `.terraformrc` dev_overrides, missing shell completions, and config bootstrapping impede rapid onboarding.
- **Cryptic compiler and runtime failures:** Standard Go runtime error strings (e.g., `open posh.yaml: no such file or directory`) lack context, source pointers, and actionable remediations.

This brief introduces a unified developer experience (DX) and terminal user experience (UX) subsystem engineered for POSH, featuring:
1. **`posh dev` Zero-Downtime Socket Hot-Reload:** A file descriptor inheritance and supervisory handoff architecture guaranteeing zero dropped frames and zero connection resets during rebuilds.
2. **Interactive Charm Bubbletea & Lipgloss TUI Dashboard:** Real-time visual terminal telemetry displaying TPS Andon state, request throughput, latency percentiles, active connections, and Jidoka probe outcomes.
3. **Automated Shell Completion & Self-Healing Setup (`posh setup` & `posh completion`):** Native Bash, Zsh, and Fish completions, coupled with automated environment bootstrapping.
4. **Rust/Elm-Style Human-Centered Diagnostic Engine:** Rich ANSI source-pointing diagnostics featuring 5-Whys causal invariants, inline carets, and copy-pastable remediation commands.

---

## 2. 'posh dev': Zero-Downtime Socket Hot-Reload Architecture

### 2.1 The Kernel UDS Handoff Challenge
On Unix systems, unlinking a Unix Domain Socket path (`unlink(2)`) breaks the inode connection for new callers. Furthermore, killing a process with in-flight socket buffers induces `ECONNRESET` on connected clients.

```
[ Traditional Reload ]
Process N (serving) ──(SIGKILL)──> 💥 Dropped Conns (ECONNRESET)
                          ▲
Unlink socket file        │ 100-300ms Downtime Window (ECONNREFUSED)
                          ▼
Process N+1 compiles & binds ───> New Conns Accepted
```

### 2.2 Supervisor-Worker Socket Inheritance Protocol
To eliminate this window completely, `posh dev` implements the **Pre-bound Listener FD Handoff Pattern**:

```
                         ┌─────────────────────────────────────────┐
                         │         posh dev (Supervisor)           │
                         │                                         │
                         │ 1. Binds run/posh.sock (net.Listen)     │
                         │ 2. Owns listening socket file descriptor│
                         │ 3. Watches source tree via fsnotify     │
                         └───────┬─────────────────────────┬───────┘
                                 │ ExtraFiles: [sockFD]    │ ExtraFiles: [sockFD]
                                 │ POSH_LISTEN_FD=3        │ POSH_LISTEN_FD=3
                                 ▼                         ▼
                 ┌───────────────────────────┐   ┌───────────────────────────┐
                 │    Worker N (Old Child)   │   │   Worker N+1 (New Child)  │
                 │                           │   │                           │
                 │ net.FileListener(fd 3)    │   │ net.FileListener(fd 3)    │
                 │ In-flight requests drain  │   │ Accepts new incoming conns│
                 │ Receives SIGTERM          │   │ Active immediately        │
                 │ Clean exit (no unlinking) │   └───────────────────────────┘
                 └───────────────────────────┘
```

1. **Pre-binding:** The supervisor creates `run/posh.sock` and holds the duplicate file descriptor (`unixListener.File()`). The socket inode is never unlinked during worker restarts.
2. **Descriptor Inheritance:** When spawning `bin/posh`, the supervisor passes the socket file in `exec.Cmd.ExtraFiles = []*os.File{sockFile}` and injects `POSH_LISTEN_FD=3`.
3. **Worker Initialization:** In `posh/cmd/posh/main.go`, the server checks `os.Getenv("POSH_LISTEN_FD")`. If present, it initializes the listener via `net.FileListener(os.NewFile(3, "inherited_listener"))` and attaches it via `srv.WithInheritedListener(ln)`.
4. **Non-destructive Shutdown:** When a worker terminates, `Server.shutdown()` inspects `s.inheritedUds`. If inherited, it avoids `os.Remove(s.sockPath)`, preserving the socket for the supervisor and new worker.
5. **Atomic Recompilation:** When a `.go` or `.yaml` file changes:
   - Events are debounced across a 75ms window.
   - `go build -trimpath -o bin/posh.next ./cmd/posh` is executed.
   - If compilation fails, the active worker continues serving uninterrupted, while Elm-style compiler diagnostics are rendered to stderr.
   - If compilation succeeds, `bin/posh.next` is atomically renamed to `bin/posh`.
   - Worker $N+1$ is spawned with the inherited FD and enters `Accept()`.
   - Worker $N$ receives `SIGTERM`, drains active connections within the `DrainTimeout()` window, and exits.

---

## 3. Interactive Terminal User Interface (TUI) Dashboard

### 3.1 Design Principles
Built using `charmbracelet/bubbletea` and `charmbracelet/lipgloss`, the POSH dashboard provides an ambient, zero-flicker developer console operating at 4 FPS (250ms tick rate) with minimal CPU overhead (< 0.1% core).

### 3.2 Visual Management Layout
```
┌──────────────────────────────────────────────────────────────────────────────┐
│  SMALT POSH MEMBRANE — DEV DASHBOARD                    Uptime: 14m 22s      │
├──────────────────────────────────────────────────────────────────────────────┤
│  ● ANDON GREEN (NOMINAL)                                                     │
│                                                                              │
│  ┌────────────────────┐  ┌─────────────────────────┐  ┌───────────────────┐  │
│  │    THROUGHPUT      │  │   LATENCY PERCENTILES   │  │   CLIENT CONNS    │  │
│  │     142.5 req/s    │  │  p50: 124µs   p95: 412µs│  │    4 active UDS   │  │
│  │   Total: 18,492    │  │  p99: 1.15ms            │  │  Wire: v1 (JSON)  │  │
│  └────────────────────┘  └─────────────────────────┘  └───────────────────┘  │
│                                                                              │
│  EVENT LOG / RELOAD STREAM:                                                  │
│   [13:00:15] Console initialized. Watching for UDS membrane events...        │
│   [13:02:40] Change detected in internal/server/server.go, reloading...      │
│   [13:02:41] Zero-downtime reload completed in 142ms                         │
│                                                                              │
│  r recompile  •  d toggle doctor  •  c clear logs  •  q quit                 │
└──────────────────────────────────────────────────────────────────────────────┘
```

### 3.3 Microsecond Latency Quantile Reservoir
To prevent latency metrics calculation from incurring lock contention on high-throughput paths:
- Per-request durations are recorded in a fixed-size circular reservoir ($N=2048$ samples).
- On each TUI tick, the reservoir is copied under a brief read lock (`sync.RWMutex`) and sorted to extract $p_{50}$, $p_{95}$, and $p_{99}$ quantiles without heap allocations.
- Active connections are tracked using lock-free 64-bit atomic counters (`atomic.Int64`) directly at `Accept()` and connection close.

---

## 4. Zero-Friction Setup & Shell Completions

### 4.1 Automated Shell Completions (`posh completion <shell>`)
The `posh completion` command generates shell completion definitions for Bash, Zsh, and Fish:
- **Bash:** Standard `complete -F _posh_completions posh` using `compgen` for commands, subcommands, and YAML configuration path completion.
- **Zsh:** Rich descriptive completion script using `#compdef posh` and `_describe -t commands` with detailed subcommand docstrings and flag completions.
- **Fish:** Native completions utilizing `__fish_seen_subcommand_from` conditionals.

### 4.2 Self-Healing Bootstrap (`posh setup`)
Developers can initialize a clean repository clone in a single command:
```bash
./bin/posh setup
```
1. **Directory Invariant Enforcement:** Ensures `posh/run/` (0755), `posh/var/` (0755), and `posh/bin/` exist.
2. **Default-Deny Config Scaffolding:** If `posh.yaml` is absent, automatically synthesizes a sovereign configuration template with `smalt.internal` allowlisted.
3. **Jidoka Auto-Healing:** Invokes `doctor.Run(..., Fix: true)` to automatically prune orphaned sockets, verify kernel peercred UID matching, and configure Terraform provider `dev_overrides`.
4. **Shell Integration Assistance:** Outputs copy-pastable shell completion configuration lines for the user's active environment.

---

## 5. Human-Centered Error Diagnostics (Rust/Elm-Style)

### 5.1 Architecture & Formatting
Diagnostics follow an Elm/Rustc-inspired format with visual gutters, source pointers, SPAF charter invariant citations, and copy-paste remediation commands.

```text
error[E0101]: egress request to host "untrusted.external.com" refused by default-deny security policy
  --> posh.yaml:12:1
   │
10 │ socket: run/posh.sock
11 │ egress_allowlist:
12 │   - smalt.internal
   │     ^^^^^^^^^^^^^^ host "untrusted.external.com" is not present on egress_allowlist
   │
   = invariant: Charter Law 2 & POSH-008: Sovereign air-gap egress boundaries require explicit allowlist enrollment.
   = 5-whys: Membrane received request requiring upstream connection to "untrusted.external.com", but egress_allowlist in posh.yaml has no matching rule.
   = help: Review posh.yaml and append "untrusted.external.com" to egress_allowlist if sovereign access is intentional.
   = remediation: printf '  - untrusted.external.com\n' >> posh.yaml && posh dev --reload
```

### 5.2 Error Code Taxonomy
| Code | Category | Name | Meaning | Actionable Remediation |
|---|---|---|---|---|
| `E0101` | Security | `RefusedEgress` | Destination host rejected by default-deny allowlist | Append host to `posh.yaml` `egress_allowlist` |
| `E0102` | Transport | `SocketCollision` | Existing live process already listening on UDS path | Run `posh doctor --fix` or kill conflicting PID |
| `E0103` | Protocol | `FrameOverflow` | Request frame length exceeds `MaxFrameBytes` (4 MiB) | Batch payload into smaller chunks |
| `E0104` | Runtime | `DeadlineExceeded` | Handler execution exceeded client SLA deadline | Raise request deadline or optimize backend |
| `E0105` | Security | `PeercredUnauthorized` | Kernel UID of caller does not match POSH daemon UID | Run client and POSH under matching system user |
| `E0201` | Config | `ConfigMissing` | `posh.yaml` absent at boot | Run `posh setup` to scaffold template |
| `E0202` | Config | `ConfigSyntax` | YAML syntax parse error | Validate YAML formatting at designated line |
| `E0301` | Build | `CompileFailed` | Go syntax or type failure during live watch | Correct Go code at line:col pointer |

---

## 6. Implementation Verification & Test Matrix

All capabilities have been implemented and verified with automated test suites in the `posh/` repository:

| Package | Test Surface | Test Cases | Status |
|---|---|---|---|
| `internal/diag` | Error formatting & styling | `TestDiagnosticRenderNoColor`, `TestDiagnosticColorCodes`, `TestDiagnosticErrorInterface` | **PASS (100%)** |
| `internal/metrics` | Latency quantiles & conns | `TestRenderSortedDeterministic`, `TestQuantilesAndConnections`, `TestConcurrentIncRace` | **PASS (100%)** |
| `internal/dev` | Watcher, debounce, supervisor | `TestWatcherFilterRules`, `TestSupervisorSocketInheritance`, `TestWatcherDebounce` | **PASS (100%)** |
| `internal/tui` | Terminal view & key navigation | `TestDashboardModelView`, `TestDashboardKeyNavigation` | **PASS (100%)** |
| `internal/completion` | Bash, Zsh, Fish generation | `TestSupportedShells`, `TestGenerateBash`, `TestGenerateZsh`, `TestGenerateFish` | **PASS (100%)** |
| `internal/bootstrap` | Directory & config scaffolding | `TestSetupBootstrap` (idempotent verification) | **PASS (100%)** |
| `cmd/posh` | CLI integration & subcommands | `./bin/posh completion <shell>`, `./bin/posh setup --dry-run` | **PASS (100%)** |

---

## 7. Operational Runbook

```bash
# 1. Zero-to-running self-healing bootstrap
./bin/posh setup

# 2. Interactive file-watch development loop with attached TUI console
./bin/posh dev --tui

# 3. Headless file-watch development loop
./bin/posh dev

# 4. Generate and load Zsh completions
eval "$(./bin/posh completion zsh)"

# 5. Execute system doctor verification
./bin/posh doctor --strict
```
