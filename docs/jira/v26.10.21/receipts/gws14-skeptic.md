# GWS-14 — WASM+DuckDB Wave Final Spec-Compliance Skeptic Audit

- **Lane**: GWS-14 (skeptic, both repos, current branches)
- **Repos**: /Users/sac/graphlaw (main, ahead 4, dirty tree), /Users/sac/smalt (main, ahead 137)
- **Date**: 2026-10-21
**Standing**: ALIVE as of write; every PENDING row below expires if its receipt lands
Context: pair (skeptic audit across smalt + graphlaw against other lanes' landed receipts)

## 1. Spec gates, typed from receipts

### WASM-SANDBOX-SPEC §3 — 3 sandbox gates

No receipt for the 3-gate court exists on disk in either repo (re-polled
2026-10-21 post-GWS-15/17/18 dispatch; only `gws13-integration-manifest.md`
mentions GWS). Typed **PENDING-GWS-13** per the manifest's own token. The
court CODE exists (`test/integration/wasm_sandbox_court.exs`, 5 tests
covering gates 1-3 + 2 lane additions) but is unwitnessed on disk.

| Gate | Spec requirement | Code evidence | Receipt | Verdict |
|---|---|---|---|---|
| 1 Clean wire | focus node → 429 refusal envelope | `wasm_sandbox_court.exs` gate-1 test asserts `{"code":"refusal_envelope","http":429}`; stub_runner emits it | none | **UNWITNESSED** — and note: typed against the STUB runner, not wasmtime |
| 2 64 MiB wall | 65 MiB → `{error,{sandbox_aborted,_}}`, BEAM alive | worker host-side `byte_size > 67_108_864` check + runner halt(86); `--max-memory 67108864` only in abi mode | none | **UNWITNESSED** vs real wasmtime |
| 3 Self-heal | pool respawns after wall kill, admits valid txn | `Pool.handle_info({:EXIT,...})` → `respawn/3`, trap_exit; bounded-poll assert | none | **UNWITNESSED** (court exists, no run output) |

**Critical scope caveat**: default runtime is STUB mode
(`config :smalt, :wasm_binary_path` unset → `priv/wasm/stub_runner.exs`
under plain `elixir`). `graphlaw_duckdb.wasm` (the duckdb-combined binary
the spec names) **does not exist**; only `graphlaw/priv/graphlaw.wasm`
(14-op, no duckdb op). Every sandbox gate is currently typed against a
deterministic Elixir stand-in, not the wasmtime sandbox the spec mandates.

### GRAPHLAW-SPEC §3 — 12 GL acceptance rows (wasm-relevant typing)

| Row | Gate / kill condition | Receipt on disk | Verdict |
|---|---|---|---|
| GL-1 | guard wrapper; no mutation after predicate failure | `gl1-law-guard-seam.md` (ALIVE, 11 court tests, fail-closed legs) | PASS |
| GL-2 | compiler; gen fun ≤15µs | `gl2-law-compiler.md` (court 10/10, twice, real TTL) | PASS |
| GL-3 | JSON-LD refusal receipt shape | `gl3-andon-diagnostic-receipt.md` (8/8) | PASS |
| GL-4 | 3-tier business net court | `gl4-graphlaw-powl-business-net-court.md` (5/5 x4) — BUT GL-12 receipt documents `autoheal:false` ArgumentError on OTP 29 making that court unrunnable as written | PASS w/ **open defect note** (owner GL-4) |
| GL-5 | 500-iter fuzz; no illegal ETS mutation | `gl5-graphlaw-agent-bounding-court.md` (3 consecutive green) | PASS |
| GL-6 | dual-governance parity | `gl6-dual-governance.md` (11/11, 9/9 verdict equality) | PASS |
| GL-7 | stale predicate after atomic swap | `gl7-rule-change-rdf-edit.md` (4/4) | PASS |
| GL-8 | 422 + witnesses; 500 = kill | `gl8-andon-wire-face.md` + adjudication (PARTIAL_ALIVE → adjudicated ALIVE) | PASS (adjudicated) |
| GL-9 | ≤15µs/step overhead jsonl | `gl9-governance-tax.md` (differential measured) | PASS |
| GL-10 | crash-injection; crash fails open = kill | `gl10-skeptic.md` + `glkill-f1-f2-close.md` (27/27→29/29, 2 KILL-class defects closed) | PASS (post-KILL-closure) |
| GL-11 | manifest derivation/anchors | `GRAPHLAW-POWL.md` PARTIAL_ALIVE, standings expire at wrap | PASS as-of artifact |
| GL-12 | refusal included in sealed Merkle token | `gl12-fullstack-seal-court.md` (2/2 x3 runs, root recompute + HSM verify) | PASS |

## 2. Zero-BEAM-contamination claim — VERIFIED (scoped)

`lib/smalt/wasm/worker.ex` line ~122: `Port.open({:spawn_executable, program},
[:binary, :exit_status, packet: 4, ...])`. This is `open_port`, not a NIF.
Census: zero `rustler`/`load_nif`/`:cargo` references in `lib/` or
`mix.exs` (only hits were inside a stale `erl_crash.dump`). A trap kills the
port/OS process only; `Pool` traps EXITs and respawns. **However**: the claim
is repo-wide false if unscoped — `lib/smalt/affidavit/wasm_engine.ex` uses
**Wasmex, a NIF library**, on the BEAM. Contamination-free holds ONLY for the
GWS sandbox path (`lib/smalt/wasm/*`), and must be documented that way.

## 3. Fail-closed claim — VERIFIED in worker, NOT on the admission path

Every worker failure mode returns a refusal, never admission:
- oversized payload → `{:error, {:sandbox_aborted, :memory_wall}}` + stop
- non-ABI payload (abi mode) → `{:error, {:abi_request_malformed, ...}}` pre-send
- >16 MiB request → typed `{:abi_refusal, ResourceLimit}` (mirrors graphlaw MAX_REQUEST_BYTES)
- malformed reply frame → `{:stop, {:sandbox_aborted, :malformed_frame}}`
- guest exit status → `{:error, {:sandbox_aborted, {:exit_status, s}}}`
- timeout (5s) → `Port.close` + `{:error, {:gate_timeout, :fail_closed}}`
- `pool_exhausted` is typed, never queues unbounded
- guard crash inside executor `run_guard` → `{:andon_refusal, :guard_raised, ...}` (fail-closed)
- stub `ok:false` / malformed → `{:sandbox_aborted, ...}` + stop

There is NO path where timeout/exit yields `{:ok, _}`. But see §5: the
bridge is not on the transition path, so this is a property of an engine
that transitions do not currently consult.

## 4. Determinism cross-engine claim — NOT MET / PENDING

`graphlaw/docs/wasm-duckdb-integration.md` row GWS-12: "Determinism
cross-engine (wasm vs native same-input)" = **PENDING-GWS-12**. No table
exists. The only determinism evidence is GL-12's in-process court (2/2
green, 3 consecutive runs, seeds recorded) — that is single-engine
repeatability, NOT cross-engine parity. `pb5-crosslang-differential.md` is
adjacent but is not a wasm-vs-native graphlaw differential. Typed honestly:
**PENDING**. GWS-3's op15 design (`docs/wasm-duckdb-op15-design.md`) adds a
concrete native↔wasm receipt/query_hash byte-identity court requirement —
also unimplemented.

## 5. Adversarial bypass attempt (novel, lanes didn't try this)

**Bypass: run a POWL transition that never touches the sandbox at all.**

Trace: `lib/smalt/powl2/executor.ex` `guard_for/2` + `run_guard/4`:
- `run_guard(_shape, nil, _ctx, _law), do: :ok` — a node with no guard,
  no `law_guard`, no `law_module` evaluates to `:ok` and runs the op.
- `grep Wasm lib/smalt/powl2/executor.ex` → zero hits. The executor never
  routes through `Smalt.Wasm.Bridge`. GL-1/GL-2 guards are BEAM-side
  compiled SHACL funs.
- `Bridge.eval/2` production callers: **none** — only
  `test/integration/wasm_{sandbox,abi}_court.exs`.

**Typing per WASM-SANDBOX-SPEC §4.3 fail-closed directive**: the guard is
**config-optional, not mandatory**. Unprotected transitions are admitted
with zero verification and zero ANDON evidence — this is not a timeout
bypass (spec §4.3 only covers timeout/exit), so it is technically
spec-conformant today, but it means the fail-closed and zero-contamination
properties are properties of an engine that is not yet on the admission
path. The sandbox is a parallel-built component awaiting wiring; until a
transition is REQUIRED to route through Bridge.eval (or an equivalent
mandatory seam), "never unverified transitions" is true only inside the
sandbox, not on the wire. Typed **SUSPECT** (spec gap, not defect in
landed code).

Second, related finding: **stub mode is the default**, and mode selection
is a single config key (`:wasm_binary_path`) with no environment gate —
a deployment can silently run "the sandbox" as plain Elixir code in the
same trust domain as the BEAM. Fail-closed still holds there (worker
refuses on timeout/exit), but the 64 MiB wall is then host-side-only
(belt-and-braces check + runner halt), not the OS-level wasmtime ceiling
the spec's Directive 1 mandates.

## 6. Verdicts summary

| Claim | Verdict |
|---|---|
| 3 sandbox gates | **PENDING** (court code exists, no receipt, stub-mode-typed) |
| 12 GL rows | 12/12 **PASS** (GL-4 with open pre-existing defect note; GL-11 as-of artifact) |
| Zero BEAM contamination | **TRUE, scoped** to `lib/smalt/wasm/*` (open_port). Repo-wide claim FALSE: Wasmex NIF exists in affidavit engine |
| Fail-closed (timeout/exit → refusal) | **TRUE in worker/bridge** (all paths refuse) — but engine not on admission path |
| Determinism cross-engine | **PENDING-GWS-12** — no wasm-vs-native table exists |
| Mandatory sandbox on transitions | **SUSPECT** — guard is config-optional; bridge has zero production callers |

## 7. Standing

- ALIVE as of 2026-10-21, both repos current branches.
- Wave-level standing: **LANDED-UNWITNESSED → NOT WRAP-READY**. Blocking
  items: (a) run + receipt `wasm_sandbox_court.exs` (PENDING-GWS-13),
  (b) build `graphlaw_duckdb.wasm` and flip gate typing from stub to abi
  mode (PENDING-GWS-14/17/18), (c) determinism cross-engine differential
  receipt (PENDING-GWS-12), (d) mandatory-seam decision: either wire the
  bridge into the executor guard seam or scope the fail-closed directive
  honestly in the spec.
