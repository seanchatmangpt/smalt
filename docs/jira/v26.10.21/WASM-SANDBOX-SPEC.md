# Architecture Specification: In-Memory WASM Sandboxed Guard Engine

Standing: OPERATOR-CHARTER (Chicago Verification Standard) — implementation lanes port the reference modules; the pool/sandbox mechanics are court-proven before any wire exposure
Context: full · Implementation: Erlang/OTP 29.1.2 · Runtime sandbox: wasmtime (installed at /opt/homebrew/bin/wasmtime) · Memory: hard 64 MiB (1,024 × 64 KiB pages)

> **AMENDED 2026-10-21 per GWS-14 skeptic audit** (`receipts/gws14-skeptic.md`,
> typed SUSPECT on the mandatory-seam gap). Sections 1-4 below are the TARGET
> state, preserved verbatim; §5 Current State and §6 Path to Compliance are
> the honest scoping amendments. Nothing in §1-4 is witnessed end-to-end on a
> real wasm binary yet.

## 1. Topology & Philosophy

NIFs introduce catastrophic risk: one memory fault kills the BEAM node and all tenants. graphlaw + frozen-duckdb compile to a standalone linear-memory-bounded WASM binary (`graphlaw_duckdb.wasm`), hosted through an isolated worker pool communicating via binary IPC over a port boundary. A panic, infinite loop, or memory-wall breach kills **only the port/worker**; the supervisor traps the EXIT and returns a fail-closed ANDON refusal.

```
[ HTTP Frame / POWL Transition Request ]
            │
            ▼
smalt_wasm_bridge.erl   (ingress router / focus-node packer)
            │ worker checkout
            ▼
smalt_wasm_pool.erl     (supervised worker pool, trap_exit, self-healing)
            │ gen_server:call
            ▼
smalt_wasm_worker.erl   (port driver / 64 MiB enforcer)
            │ packet-4 stdio
            ▼
graphlaw_duckdb.wasm    (sandboxed execution, 1,024 pages)
```

> **Note**: the 64 MiB ceiling is an enforced HOST-layer boundary
> (`wasmtime --max-memory` in the smalt worker), not a
> WASM-module-internal limit — the raw WASI imported memory declares no
> maximum (cross-ref §3b / GWS-11).

## 2. Components

- **smalt_wasm_bridge**: focus-node extraction (route-classified predicate packing: RU charge, If-Match, blob-type, byte-range as typed predicate frames), wasmtime invocation, refusal mapping to wire-exact HTTP.
- **smalt_wasm_pool**: 16 pre-warmed workers, queue checkout, trap_exit + EXIT-driven fresh respawn (crash-only self-healing), pool_exhausted typed when drained.
- **smalt_wasm_worker**: port driver (`wasmtime run --max-memory 67108864`), 5s execution timeout → fail-closed refusal, sandbox violation → worker exit + pool respawn.

## 3. Verification Court (3 gates)

1. **Clean wire evaluation** — normal focus node → expected 429 refusal envelope (RU burst injection).
2. **64 MiB memory wall** — adversarial 65 MiB payload → `{error, {sandbox_aborted, _}}`, BEAM node alive.
3. **Pool self-healing** — after the wall kill, the pool respawns and admits a valid transaction immediately.

## 4. Operational Directives

1. Deterministic memory limits enforced at the OS process boundary — no guest allocation past 67,108,864 bytes.
2. Zero BEAM contamination — no NIF object code in the ERTS address space; catastrophic events drop the port only.
3. Fail-closed gate — timeout or non-zero exit ⇒ HTTP 500 `SecurityGateFailure` envelope, never unverified transitions.

## 5. Current State (AMENDMENT, 2026-10-21 — GWS-14 audit scoping)

Typed from `receipts/gws14-skeptic.md` (ALIVE as of 2026-10-21):

- **Stub mode is the default.** `config :smalt, :wasm_binary_path` unset →
  `priv/wasm/stub_runner.exs` under plain `elixir` — a deterministic Elixir
  stand-in, not wasmtime. `graphlaw_duckdb.wasm` (the spec-named binary)
  does not exist; only `graphlaw/priv/graphlaw.wasm` (14-op, no duckdb op).
- **64 MiB wall is host-side-only in stub mode** (worker `byte_size` check +
  runner halt(86)); the OS-level `wasmtime --max-memory 67108864` ceiling
  exists only in abi mode.
- **The guard is config-optional, not mandatory.** `Powl2.Executor.run_guard`
  admits transitions with no guard / `law_guard` / `law_module` as `:ok`
  with zero sandbox verification and zero ANDON evidence. `Smalt.Wasm.Bridge`
  has zero production callers — only
  `test/integration/wasm_{sandbox,abi}_court.exs`. Per audit §5 this is
  typed **SUSPECT** (spec gap, not a defect in landed code): the fail-closed
  and zero-contamination properties are demonstrated for the sandbox engine,
  but the engine is not yet on the admission path.
- **Fail-closed is verified inside the engine.** Every worker failure mode
  (oversized payload, non-ABI payload, >16 MiB request, malformed frame,
  guest exit, 5s timeout, pool exhaustion, guard crash, stub `ok:false`)
  returns a typed refusal; no path yields `{:ok, _}`.
- **Zero-NIF claim is scoped strictly to `lib/smalt/wasm/`**
  (open_port, no NIF object code on that path). Repo-wide it is FALSE:
  `lib/smalt/affidavit/wasm_engine.ex` uses Wasmex, a NIF library, on the BEAM.
- The 3-gate court code exists (`test/integration/wasm_sandbox_court.exs`,
  5 tests) but is **unwitnessed on disk** (PENDING-GWS-13) and typed against
  the stub runner.

## 6. Path to Directive 1-3 Compliance (AMENDMENT, 2026-10-21)

1. **Mandatory-seam decision (blocks Directive 3 as written).** Either wire
   `Smalt.Wasm.Bridge` into the `Powl2.Executor` guard seam so every
   transition routes through the sandbox (Directive 3 "never unverified
   transitions" then holds on the wire), OR keep the guard config-optional
   and amend Directive 1/3 scope to opt-in explicitly in this spec. One or
   the other — no silent middle.
2. **Build `graphlaw_duckdb.wasm`** (PENDING-GWS-14/17/18): GWS-2's
   DOCS_RS path (frozen-duckdb-sys link directive; artifact typed
   ABI-identical to the pinned one) + GWS-17's gate restoration. Gate
   typing then flips from stub to abi mode.
3. **Determinism cross-engine differential** (PENDING-GWS-12): the
   wasm-vs-native same-input table does not exist; GL-12 is single-engine
   repeatability only. GWS-3's op15 design adds the
   receipt/query_hash byte-identity court requirement.
4. **14-op vs duckdb-op re-scope decision (RECORDED 2026-10-21)**
   (`receipts/wrap1-duckdb-rescope-decision.md`): the **14-op ABI ships on
   `graphlaw.wasm`**; frozen-duckdb stays **native-side** via the op-15
   `duckdb` cursor-streamed ABI op (GWS-16, landed natively). The wasm module
   **excludes duckdb** — GWS-2's build trial proved frozen-duckdb has no
   wasm32 artifact and its DOCS_RS workaround produces a binary with zero
   duckdb contribution anyway (ABI hash identical to the pinned 14-op
   artifact) — so real-SQL-in-wasm is typed as a **follow-up**
   (BLOCKED on a wasm32 frozen-duckdb). Smalt's runner shim (GWS-18) serves
   the real 14-op artifact. Evidence: `receipts/gws2-wasm-build-trial.md`,
   `/Users/sac/graphlaw/receipts/gws-16-wasm-duckdb-op15.md` (PARTIAL_ALIVE),
   `receipts/gws18-real-runner-court.md` (ALIVE, 7/7 gates on the real
   artifact).
5. **Run + receipt `wasm_sandbox_court.exs`** (PENDING-GWS-13) on the real
   binary, closing §3's gate verdicts.

## 3a. Gate standing (AMENDMENT to §3 — original §3 is the target state)

| Gate | Standing on stub | Standing on real wasmtime binary |
|---|---|---|
| 1 Clean wire (429 refusal envelope) | **DEMONSTRATED-ON-STUB** (court code asserts the envelope; run unwitnessed, PENDING-GWS-13) | **PENDING-ON-REAL-BINARY** |
| 2 64 MiB wall | **DEMONSTRATED-ON-STUB** — host-side check only, not the wasmtime ceiling | **PENDING-ON-REAL-BINARY** |
| 3 Pool self-heal | **DEMONSTRATED-ON-STUB** (`Pool` trap_exit → respawn, bounded-poll assert) | **DEMONSTRATED-ON-REAL-RUNNER** (GWS-18 gates 3/5: crash contained `exit_status 86`, bounded-poll heal, real frame admitted) |
| op-15 `duckdb` (analytical SQL) | n/a — **NATIVE-SIDE ONLY**, landed (GWS-16, PARTIAL_ALIVE: `src/duckdb_op.rs` behind the `duckdb` feature; wasm op table unchanged at 14 ops; cursor exec/stream/close, typed `DuckDb` refusals). In-wasm real SQL is a **typed follow-up**, BLOCKED on a wasm32 frozen-duckdb (GWS-2) | same — the op never enters the wasm module by decision (§6 item 4) |

## 3b. Enforced-boundary map (AMENDMENT per GWS-11, measured on the real pinned binary — `receipts/gws11-wasm-memory-wall.md`)

| Boundary | Enforced at | Measured |
|---|---|---|
| 16 MiB request cap | INSIDE the module (gl_alloc null-return) | typed refusal reachable only via hostile host misreporting len — proven |
| 256 MiB outstanding budget | INSIDE the module (ffi.rs reserve) | saturates to null alloc, no UB; one free re-admits |
| JSON depth 64 / N3 compute caps | INSIDE the module | typed ResourceLimit refusals, bounded |
| **64 MiB wall** | **HOST-layer only** (smalt worker's wasmtime `--max-memory`); raw WASI imported memory declares NO maximum | **correction to §1's assumed semantics** — the wall exists where smalt hosts it, not at the wasmi/raw-wasi layer |
| Survival | pool respawn analog | saturated instance dropped → fresh instance admits immediately |
