# SPOF-B — Boundary audit, vectors 3 + 4 (adversarial, read-only)

**Standing:** UNKNOWN (SUSPECT — 2 OPEN defect classes found, findings typed and unverified; no code edits made)
Date: 2026-10-21
Repos: /Users/sac/smalt (main) + /Users/sac/graphlaw (read-only)
Context: solo
Inputs read: `receipts/wasm1-otp29-sandbox-port.md` → actually
`docs/jira/v26.10.21/receipts/{wasm1-otp29-sandbox-port,gws11-wasm-memory-wall,gws18-real-runner-court}.md`

---

## Vector 3 — WASM / port-pool bottlenecks

Targets: `lib/smalt/wasm/{bridge,pool,worker}.ex`,
`lib/smalt/affidavit/wasm_engine.ex`, graphlaw `src/bin/graphlaw_run.rs`.

### SPOF-3.1 — Affidavit WasmEngine input-allocation leak → permanent engine wedge

- **SPOF Identifier**: `Smalt.Affidavit.WasmEngine.run_request/2` + `run_seal/5`
  (`/Users/sac/smalt/lib/smalt/affidavit/wasm_engine.ex:436-455` (run_request),
  `:488-522` (run_seal))
- **Failure Classification**: Table Destruction class (engine wedge; guest-heap
  exhaustion is unrecoverable without restart — the CTRT machine is a singleton)
- **Failure Scenario**: `af_alloc(len)` for the REQUEST bytes is never matched
  by `af_free(ptr, len)` on any path. `run_request` frees only the OUTPUT block
  (`free_out(out_ptr)`); the input ptr leaks on every call, including the
  error branches (af_call error → `_ -> @engine_unavailable` leaves the block
  allocated). `run_seal` allocates `delta_ptr` AND `out_ptr`, frees only
  `out_ptr` — `delta_ptr` leaks every seal. Per GWS-11's measured outstanding
  budget (255–256 MiB, `gl_alloc`/af_alloc null-return), the guest heap wedges
  permanently: every later `af_alloc` returns 0 → `@engine_unavailable` forever
  until process restart. Wedge point ≈ 16 requests of 16 MiB each (the host cap
  `@max_payload 16_777_216`), or cumulative 256 MiB of smaller requests.
- **Blast radius**: the entire Affidavit CTRT/seal surface — a singleton
  GenServer (`Smalt.Affidavit through ControlSupervisor`) →
  `{:error, :engine_unavailable}` on every caller of
  `affi_admit_and_seal/1`/`call_json/1`/`call_admit_and_seal/4` until
  restart. Fail-closed (no corruption), but a permanent availability SPOF.
- **Decomposition patch** (not applied — read-only lane): free the input block
  on ALL paths: after `af_call` returns (success or error), `af_free(ptr, len)`
  the request allocation; in `run_seal`, free `delta_ptr` after
  `affi_admit_and_seal` returns. Because the `with` chain can fail mid-way, the
  free must be in an `after`-style cleanup, not inline in the happy path.
- **Falsification Court**: real wasmex instance over the pinned artifact:
  drive cumulative >256 MiB through `call_json/1` (e.g. 20 × 16 MiB capped
  requests), then assert a valid 1 KiB request still admits. Today it returns
  `:engine_unavailable` — court fails, proving the leak. After patch, court
  passes and a second run (engine restarted) is byte-identical.

### SPOF-3.2 — WasmEngine is a single serialized GenServer (Process Bottleneck)

- **SPOF Identifier**: `Smalt.Affidavit WasmEngine` GenServer
  (`wasm_engine.ex:416-423`), client helpers `call/2`, `call_json/1`,
  `call_admit_and_seal/3` all `GenServer.call(__MODULE__, ...)` to ONE named
  process.
- ** fans through a single shared port/worker?**: Not port-based (wasmex NIF,
  in-process). But ALL affidavit requests serialize through one GenServer:
  one slow `af_call` blocks every other caller; `GenServer.call` default 5s
  timeout → callers get a caught `:exit` mapped to `:engine_unavailable`
  >5s-class requests CONFLATE "engine busy" with "engine down" — callers
  cannot distinguish retryable-busy from wedge.
- **Blast radius**: affidavit throughput ceiling = one call at a time; under
  concurrent load the 5s-class timeouts surface as engine_down noise.
- **Decomposition patch**: pool it like `Smalt.Wasm.Pool` (N wasmex store/
  instance pairs, checkout/checkin, crash-only respawn) — the exact pattern
  the guard-engine side already has; or at minimum a distinct typed
  `{:error, :engine_busy}` for timeout-class failures.
- **Sizing: what happens at burst > 16 (the 16-worker guard pool)**: **CLOSED
  (court receipt)** — `Smalt.Wasm.Pool` returns the typed
  `{:error, :pool_exhausted}` immediately (no unbounded queue, "it never
  queues unbounded work" — pool.ex moduledoc; court gate 4 of
  `test/integration/wasm_sandbox_court.exs`, 6/6 green per wasm1 receipt).
  Burst load > 16 concurrent evals is refused typed, recovers on checkin.
- **Trap containment: does ONLY the transient context drop, or does the host
  port/worker die?**: **CLOSED (receipt)** — per-worker isolation: guest trap
  → runner exit → port dies → worker GenServer `{:stop, {:sandbox_aborted,
  ...}}` → pool EXIT-respawn (wasm1 court gates 2/3/5/6, gws18 gates 2/3/5);
  the pool and the rest of the queue never stall. Respawn drops fault args,
  so a `--crash` respawn traps again on its next frame (gws18 defect 3) —
  contained, but note for any court asserting "respawn admits next frame".
- **stdin/stdout latin1 law sweep**: exactly ONE `Port.open` site in
  `lib/` + `priv/`: `worker.ex:122` (`:binary` + `packet: 4` — BEAM side
  binary-safe). Guest side: `priv/wasm/stub_runner.exs:33` sets
  `:io.setopts(:standard_io, encoding: :latin1)` at top level, before any
  frame I/O — **CLOSED (receipt wasm1-otp29-sandbox-port.md)**. The real
  runner `graphlaw_run.rs` is Rust (binary `read_exact`/`write_all` with
  explicit `flush`, lines 183–236) — binary by construction, law vacuously
  satisfied. No un-pinned packet-N stdio harness found in smalt `lib/`/`priv/`
  or graphlaw `src/bin/`. NOTE: the law is enforced by discipline only (a grep
  sweep), no gate; a new runner would regress silently — candidate for a
  sleep-gate-style sweep gate.

**Residual OPEN for vector 3**: SPOF-3.1 (input-alloc leak), SPOF-3.2
(single-GenServer affidavit bottleneck + busy/down conflation).

---

## Vector 4 — Browser single-tab contention

Targets: `workspace/lib/engine/{journal-sync,tab-lease}.ts`, caller
`workspace/lib/engine/useJournal.ts`.

### SPOF-4.1 — Fallback mode is silent multi-tab corruption; the mode bit is dropped

- **SPOF Identifier**: `withWalLease` fallback (tab-lease.ts:78-92) +
  `unwrapLease` (useJournal.ts:200-210)
- **Failure Classification**: Table Destruction class (seq-horizon corruption
  when 2+ tabs append without the lease)
 two concurrent tabs each run their own module-level
  AppendQueue turnstile (journal-sync.ts:123) against one origin store; both
  read `openCursor(null,"prev")` inside readwrite txs and can both mint the
  same `seqId = max+1` before either `put` lands → duplicate-key abort or
  (keyPath upsert semantics of IDB `put` — an overwrite) silent
  OVERWRITE of the other tab's segment, breaking frame-chain/merkle replay and
  `flushSync`'s leaf chain vs server receipt verification.
  - Web Locks absent (non-secure context, old Chromium): `withWalLease`
    returns `mode:"fallback"` and RUNS THE BODY ANYWAY (typed at the wrapper,
    by design so single-tab flush works). But `unwrapLease` (useJournal.ts)
    DROPS the mode bit: callers and the journal snapshot never learn the
    hazard is live. The module doc says "the single-tab hazard stays loud,
    never a faked pass" — at the wrapper yes, at the engine no: `JournalSyncEngine.append/sync`
    collapse `mode:"fallback"` to a normal success.
- **Failure Scenario**: two tabs on a non-secure origin: both append
  concurrently → IDB `put` with colliding seqId → one segment overwritten
  (acked=false both) → flushSync's concatenated leaf chain no longer matches
  the server's recomputation → permanent SYNC_REFUSED_BY_SERVER + snapback
  purge of real local frames, or silent ledger divergence.
  Node courts (tab-lease-court legs 1) exercise the fallback only single-tab,
  so the hazard is unexercised multi-tab.
  - Blast radius: whole local ledger for the origin (snapback purges un-acked
    frames; verified seals unclaimable).
- **Decomposition patch**: surface `mode` in the snapshot (e.g. `leaseMode: "web-locks" | "fallback"` field patched at first observed mode), and/or
  gate multi-tab hazard with a BroadcastChannel-free guard: a fallback-mode
  tab that detects another live tab (e.g. localStorage heartbeat) refuses
  appends typed (`LEASE_REFUSED`-class) instead of running.
- **SPOF-4.2 — Master-tab death: lease transfer works, horizon does NOT transfer
  with it — stale in-memory horizon (no rehydrate-on-promotion)
- **SPOF Identifier**: `JournalSyncEngine.init()` runs ONCE per page lifetime
  (useJournal.ts:103-128, `initPromise` memoization); no
  rehydration on lease acquisition
- **Failure Classification**: Table Destruction class (stale horizon →
  snapshot divergence; IDB itself stays consistent)
- **Failure Scenario**: master tab killed abruptly (`kill()`ed) mid-flush.
  Web Locks DOES guarantee release on tab death (court leg 3 covers
  release-on-body-failure; death-release is browser-guaranteed and leg 3 is
  the in-process analog). Survivor tab B acquires the lease, calls
  `flushSync()` under lease → `unacked()`/`unacked` reads live IDB → the DRAIN
  path rehydrates from the store correctly (CLOSED). BUT the surviving tab's
  IN-MEMORY state (`acc` merkle accumulator, `snapshot.currentSeq`,
  `snapshot.frames`, `unsyncedCount`) was built at init time; frames appended
  by the dead master after tab B's init are missing from B's accumulator —
  `snapshot.accumulatorRoot` now disagrees with the stored frame chain, and
  `snapshot.frames` omits seqs that exist in IDB. The IDB ledger stays
  contiguous (appends and drains are leased), so this is snapshot-divergence
  (andon reads a wrong merkle root) not ledger corruption.
  - Blast radius: wrong merkle root / frames trail in every survivor tab;
    UI claims a chain the stored frames don't prove — an overclaiming face.
  - Decomposition patch: rehydrate on promotion — when a tab acquires the
    lease and observes `store.maxSeq > snapshot.currentSeq`, re-run the
    init/replay path (hydrate() is idempotent; rebuild acc from stored
    frames).
  - Falsification court: two-tab court — tab A appends seqs 1..5; tab B
    inits, then A appends 6..10 and dies; B acquires lease, asserts
    `snapshot.currentSeq == 10` and `accumulatorRoot` matches replay of all
    10 stored frames. Today B shows currentSeq=5 and a stale root — fails.
- **SPOF-4.3 — appendLocal exported bypassable lease (defense in depth, OPEN, minor)
- **SPOF leasing is a CALLER discipline**: `appendLocal`/`markSynced`/
  `snapbackStoreOps` are exported and mutate the ledger without the lease;
  only `useJournal` wraps. Any future caller (or court wiring
  `snapbackStoreOps` directly) bypasses the master lease. Decomposition
  patch: make the leased path the only path (private `appendLocal` inside
  `withWalLease` in journal-sync itself, or prefix the unwrapped exports with
  a `_unsafe` marker + grep gate.

---

## Verification (what was actually run)

Read-only lane: no code edits, no tests executed (no gate applies). All
claims are file-read receipts at the listed line numbers on /Users/sac/smalt
@ main 2925d40 (dirty tree; `lib/smalt/affidavit/wasm_engine.ex` is NOT in
the dirty set — audited as committed; `config/config.exs` and
`lib/smalt/plane/data_supervisor.ex` are dirty but out of audit scope).

Falsifier: any cited line/claim failing re-reading on HEAD; or a court
running the SPOF-3.1 / SPOF-4.2 falsification legs and passing without a
patch landing.

---

## ADDENDUM 2026-10-21 — SPOF-3.1 premise corrected (record-coherence fix)

**Authority**: `docs/jira/v26.10.22/receipts/spof3-affidavit-fixes.md`
(SPOF-3 lane, Context: solo). Original text above is preserved unchanged;
this addendum supersedes it for SPOF-3.1's wedge classification.

**Correction**: the "256MiB input-alloc leak wedge" premise is **REFUTED on
the pinned affidavit artifact** (`priv/wasm/affidavit_wasm.wasm`). A pre-fix
probe swapped the HEAD engine in and drove 80 × (16MiB−1B) = 1.31 GiB
cumulative — 5x the audit's projected wedge point — in 3093ms: 80/80
non-empty guest responses, a follow-up 1KiB request admits, and two
consecutive seals return deterministic typed answers. The guest's `af_alloc`
does not exhaust the way GWS-11 measured for graphlaw's `gl_alloc`; the
255–256MiB outstanding-budget figure cited in SPOF-3.1 was measured on a
DIFFERENT engine (`docs/jira/v26.10.21/receipts/gws11-wasm-memory-wall.md`
subject), not the affidavit artifact. The "permanent engine wedge" Failure
Classification and the ≈16×16MiB / 256MiB wedge-point projections above are
therefore withdrawn.

**What stands as code-truth**: the missing-free observation itself was
correct — `run_request/2` did leak the input block and `run_seal/5` leaked
`delta_ptr` on every path (line cites verified). The free-on-every-path
fixes (try/after `free_block` in both) landed anyway as defense-in-depth
ABI-contract hygiene (af_alloc/af_free pairing per the module's documented
C-ABI), fenced by `test/internal/spof3_affidavit_engine_court_test.exs`
which pins the measured no-wedge bound.

**SPOF-3.2 stands as filed**: the busy/down conflation is real; typed
`{:error, :engine_busy}` (vs `:engine_unavailable`) landed in
`call/3`, `call_admit_and_seal/4`, `call_json/1`, and `affi_admit_and_seal/1`
passthrough, witnessed by the court's busy leg on a real 16MiB in-flight
occupier.