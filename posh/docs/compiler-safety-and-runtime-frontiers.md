# Compiler Safety, Static Analysis Linters, and Runtime Frontiers for POSH

**Document ID:** POSH-TECH-014  
**Author:** AGENT_5_COMPILER_SAFETY (Compiler & Static Safety Engineer, Go Core Team)  
**Status:** ADMITTED / PRODUCTION READY  
**Component:** `smalt.dev/posh` (SPAF Tier 2 Foreign Membrane)  
**Target Runtimes:** Go 1.23.4 / Go 1.24+  

---

## 1. Executive Summary & Architectural Motivation

The POSH membrane sits directly at the protocol translation boundary between the BEAM actor core and hyperscaler cloud ecosystems (Azure ARM, Kubernetes, Terraform). To maintain the strict invariants defined in the POSH charter:
1. **Charter Law 2 (Zero Domain State):** Protocol translation only — zero persistent state in the membrane.
2. **Charter Law 3 (Fail-Closed Egress):** Zero un-fenced network dials or unreceipted upstream network egress (POSH-008).
3. **Charter §6 (Turnstile Admittance):** 100% of admitted ingress routes must terminate in a cryptographic `posh:Turnstile` emitting a 32-byte BLAKE3 receipt token; 0 orphan nodes.
4. **Hot Path Zero-Alloc Guarantee:** Frame parsing, serialization, and turnstile verification on the hot path must execute with 0 unadmitted heap allocations.

This technical brief details the design, implementation, and empirical verification of three major compiler and static safety frontiers:
- **`poshvet` (Custom `go/analysis` Static Linter):** AST, type-checker, and ontology-aware static analysis preventing slice-to-interface escapes (`runtime.convTslice`), unfenced network clients, and unadmitted membrane operations.
- **Go 1.24+ Memory Frontiers:** `sync.Unique` string interning for hierarchical ARM resource trees and SwissMap SIMD-probed concurrent routing tables.
- **WebAssembly / WASI Isolation (`GOOS=wasip1` via `wazero`):** Sandboxed, CGO-free, capability-bounded operator policy execution with microsecond cold starts and host-verified turnstile receipts.

---

## 2. Custom `go/analysis` Static Analysis Linter: `poshvet`

`poshvet` is built on the official `golang.org/x/tools/go/analysis` multichecker framework and can be run standalone (`poshvet ./...`) or plugged directly into the standard Go toolchain via `go vet -vettool=./bin/poshvet ./...`.

```
                    +------------------------------------+
                    |       poshvet Multichecker         |
                    +-----------------+------------------+
                                      |
         +----------------------------+----------------------------+
         |                            |                            |
         v                            v                            v
  [ convtslice ]               [ fencednet ]               [ opturnstile ]
  AST/Type Analyzer            AST Inspection              AST + RDF Turtle
  - Hotpath detection          - net.Dialer Control        - parses routes.ttl
  - Slice->interface escapes   - http.Client Fenced        - validates 1:1
  - runtime.convTslice 24B     - DefaultClient ban           op -> Turnstile
```

### 2.1 Analyzer 1: `convtslice` (Heap Escape Prevention)
* **Locus:** `posh/internal/poshvet/convtslice.go`
* **Mechanism:** In Go, converting a slice (`[]byte` or `[]T`) to an `interface{}` / `any` invokes `runtime.convTslice`. Because a slice header consists of three 64-bit words (data pointer, length, capacity), boxing it into an interface requires a 24-byte heap allocation to maintain interface pointer semantics. In high-throughput frame loops (`readFramePooled`, `writeFrame`, `TurnstileReceipt`), this creates GC pressure and invalidates zero-allocation guarantees.
* **Analysis Rule:**
  1. Identifies functions marked with `//posh:hotpath`, `@hotpath`, or listed in known hot frame processing paths.
  2. Inspects `ast.CallExpr`, `ast.AssignStmt`, and `ast.ReturnStmt`.
  3. Uses `pass.TypesInfo` to verify if the source expression is a `*types.Slice` and the target is `*types.Interface`.
  4. Emits diagnostic `POSHVET-001: slice-to-interface escape (runtime.convTslice, 24B heap alloc) in hot path %s(); wrap in pointer struct (e.g. *frameBuf)`.

### 2.2 Analyzer 2: `fencednet` (POSH-008 Egress Firewall Static Enforcer)
* **Locus:** `posh/internal/poshvet/fencednet.go`
* **Mechanism:** Cloud environments are vulnerable to Server-Side Request Forgery (SSRF) and instance credential theft via link-local addresses (`169.254.169.254`, `fe80::/10`, and NAT64 synthetics `64:ff9b::/96`). POSH-008 mandates that all outbound connections be gated by `egress.Control` pre-connect hooks and strict allowlist enforcement.
* **Analysis Rule:**
  1. Scans all composite literals for `net.Dialer` outside `internal/egress`: statically requires the `Control:` field to be set.
  2. Scans all composite literals for `http.Client`: forbids direct construction without `Transport:` and `CheckRedirect:`, mandating `egress.NewFencedClient(cfg, timeout)`.
  3. Identifies and rejects any usage of `http.DefaultClient`, `http.DefaultTransport`, `http.Get()`, `http.Post()`, or `http.Head()`.
  4. Witnessed Catch: During initial execution on the codebase, `poshvet` immediately flagged `internal/armclient/client.go:79:8: POSHVET-002: use of unfenced http.DefaultClient violates POSH-008 fail-closed egress`, identifying an unfenced egress bypass when `cfg.HTTPClient == nil`.

### 2.3 Analyzer 3: `opturnstile` (Ontology Turnstile Admittance Enforcer)
* **Locus:** `posh/internal/poshvet/opturnstile.go`
* **Mechanism:** In the POSH architecture, routes are not ad hoc strings in code; they are declared in RDF Turtle ontologies (`ggen-marketplace/packs/posh/ontology/routes.ttl`). Charter §6 requires that 100% of routes terminate in an admitted `posh:Turnstile` emitting a `posh:Receipt`.
* **Analysis Rule:**
  1. Discovers and parses the Turtle ontology graph (`routes.ttl`).
  2. Traverses `posh:IngressRoute` triples to locate `posh:membraneOp`, `posh:admittedBy`, and `posh:emits`.
  3. Inspects Go AST for `ops = map[string]server.Handler{...}` definitions.
  4. Emits `POSHVET-003` if an operation registered in Go has no corresponding route, no admitted `Turnstile`, or no emitted `Receipt` in the ontology.

---

## 3. Go 1.24+ Runtime & Memory Optimization Frontiers

### 3.1 `sync.Unique` String Interning for ARM Resource Topologies
* **Locus:** `posh/internal/uniqueintern/intern.go`
* **Problem:** In large enterprise cloud footprints, managing 50,000+ Azure resources produces massive memory bloat:
  `/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-smalt-prod/providers/Microsoft.App/containerApps/app-posh-core`
  Across 50,000 resources, subscription IDs, resource group names, provider namespaces (`Microsoft.App`), and regions (`eastus2`) are duplicated tens of thousands of times, allocating tens of megabytes of redundant strings.
* **Architecture:**
  - Utilizing Go 1.24 `unique.Make[T](v T) unique.Handle[T]`.
  - Canonical handles hold internal pointers to deduplicated strings.
  - Unlike naive global cache maps that leak memory indefinitely, Go 1.24's runtime manages interning via weak pointers (`weak.Pointer[T]`), allowing unreferenced strings to be swept cleanly during GC.
* **Empirical Benchmark Results (Apple M3 Max):**
  ```
  BenchmarkStringEqualityCheck/StandardStringMemequal-16       827,724,402   1.442 ns/op   0 B/op   0 allocs/op
  BenchmarkStringEqualityCheck/InternedHandlePointerEquality-16 1,000,000,000 0.3607 ns/op  0 B/op   0 allocs/op
  BenchmarkConcurrentInterning-16                               4,154,238   256.1 ns/op   0 B/op   0 allocs/op
  ```
  - **4x Faster Equality Comparison:** Comparing interned handles executes in **0.36 ns** (single CPU cycle `CMPQ` pointer comparison) vs 1.44 ns for byte-by-byte string comparison (`runtime.memequal`).
  - **Memory Reduction:** Reduces per-resource structural overhead and eliminates heap fragmentation across concurrent adapter requests.

### 3.2 Go 1.24 SwissMap Internals & Concurrent Routing Tables
* **Locus:** `posh/internal/swissmap/swissmap.go`
* **Architectural Evolution:**
  - *Go <= 1.23 Classic Maps:* Array of buckets (`bmap`), each with 8 tophash bytes, 8 keys, 8 values, and an overflow pointer. When collisions occur, overflow buckets form singly-linked lists on the heap, triggering severe CPU cache line misses and pointer chasing. Maximum load factor is ~81.25%.
  - *Go 1.24 SwissTable:* Replaces bucket chains with flat 8- or 16-slot groups. Each group contains an 8- or 16-byte metadata control array (`ctrl`), storing empty/deleted tags or 7-bit hash fingerprints (`h2`). SIMD instructions (`PCMPEQB` / NEON `vceqq_u8` / 64-bit SWAR) match all slots in parallel in a single CPU instruction. Probing is flat and quadratic, achieving 87.5%–93.75% load factor with 0 overflow pointers.
* **POSH Concurrent Router (`ConcurrentRouter`):**
  - Read-mostly frame dispatch uses RCU (Read-Copy-Update) over `atomic.Pointer[SwissRouteTable]`.
  - Reads are 100% wait-free, non-blocking, and cache-line local.
  - Updates atomically swap in a freshly constructed flat SwissTable.
* **Empirical Benchmark Results (Apple M3 Max, 16 Cores):**
  ```
  BenchmarkRouteTableComparison/StandardMapRWMutexParallel-16     8,970,310   138.9 ns/op   0 B/op   0 allocs/op
  BenchmarkRouteTableComparison/SwissRouterWaitFreeParallel-16  341,889,716     4.06 ns/op   0 B/op   0 allocs/op
  ```
  - **34x Throughput Multiplier:** Standard map protected by `sync.RWMutex` suffers severe cache line bouncing and lock acquisition stalls under 16 cores (138.9 ns/op). The wait-free SwissTable router resolves operations in **4.06 nanoseconds** (over **340 million ops/second**)!

---

## 4. WebAssembly / WASI Isolation Target (`GOOS=wasip1`)

### 4.1 Evaluation & Trade-off Matrix
To support untrusted third-party operator transformation plugins within the POSH membrane, three isolation approaches were evaluated:

| Isolation Model | Cold Start Latency | Memory Overhead | CGO Required? | Process Isolation | Sandboxing Guarantees |
|---|---|---|---|---|---|
| **OCI Container (Docker/K8s)** | 50 – 250 ms | ~100 – 256 MiB | No | Full OS Process | High (Namespace/Cgroups) |
| **Go Native Plugin (`plugin`)** | < 1 µs | ~10 MiB | **Yes (breaks CGO=0)** | In-process | None (Can segfault/leak) |
| **WASI (`wasip1` + `wazero`)** | **< 100 µs** | **< 2 MiB** | **No (Pure Go)** | **In-process Linear Memory** | **Strict (Capability-based)** |

### 4.2 Sandboxed Runtime Architecture
* **Locus:** `posh/internal/wasm/engine.go`
* **Host Engine:** Built with `github.com/tetratelabs/wazero`, executing completely static without CGO or external system shared libraries.
* **Sandboxing Guarantees:**
  - Memory bounds: Strict page limits via `WithMemoryLimitPages(512)` (32 MiB max linear memory). Any module requesting excessive memory is rejected at compile time (verified via `TestWasmMemoryBoundEnforcement`).
  - Execution bounds: Strict per-invocation timeout via `context.WithTimeout` (default 100ms) to terminate runaway loops (`ErrPluginTimeout`).
  - Zero ambient authority: Guest modules have no filesystem, network, or environment access unless explicitly mapped.
* **POSH Host-Guest ABI (`posh_host`):**
  - `posh_turnstile_receipt(op_ptr, op_len, ts, payload_ptr, payload_len, out_receipt_ptr) -> u32`: Guest requests cryptographic BLAKE3 receipt calculation from host SIMD core without bloating guest binaries with crypto kernels.
  - `posh_log(level, msg_ptr, msg_len)`: Direct logging into POSH structured logger.
  - `transform_payload(ptr, len) -> u64 (out_ptr << 32 | out_len)`: Guest entrypoint for zero-copy envelope transformation.
* **Empirical Benchmark Results:**
  ```
  BenchmarkWasmExecution-16   59,881   19,900 ns/op   85,105 B/op   38 allocs/op
  ```
  - Executes a complete sandboxed plugin lifecycle (memory write, JIT execution, output extraction, and BLAKE3 turnstile receipt computation) in **19.9 microseconds**, representing a **2500x to 10000x speedup** over container execution.

---

## 5. Verification Matrix & Verification Commands

All components are implemented, fully tested, and integrated into `posh/Makefile`:

| Target | Command | Result |
|---|---|---|
| **Linter Build & Vet** | `make poshvet` | PASS (0 errors, build clean) |
| **Linter Unit Tests** | `go test -v ./internal/poshvet` | PASS (5/5 tests green) |
| **String Interning Bench** | `go test -v -bench=. -benchmem ./internal/uniqueintern` | PASS (4x faster, 0.36 ns/op) |
| **SwissMap Bench** | `go test -v -bench=. -benchmem ./internal/swissmap` | PASS (34x faster, 4.06 ns/op) |
| **WASI Isolation Suite** | `go test -v -bench=. -benchmem ./internal/wasm` | PASS (19.9 µs/op, sandboxed) |
