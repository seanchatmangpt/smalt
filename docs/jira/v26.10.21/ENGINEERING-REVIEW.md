# Engineering Execution Review: OTP 27–29 / Elixir 1.17–1.20 Runtime Boundaries

Standing: OPERATOR-REVIEW — cross-checked against the executed probe evidence (this file's §5 maps each claim to its receipt); every agreement noted, zero divergences found at landing
Context: full · Date: 2026-10-21

## 1. Concrete API Signatures & Critical Runtime Traps

Several modern primitives contain subtle contract constraints that will trigger badarg exceptions or compiler rejections if invoked naively.

### A. ETS Atomic Traversal & Update Semantics

- **`ets:next_lookup/2` (not arity 1)**: requires two arguments. **Supported only on `ordered_set` tables** — `set`/`bag`/`duplicate_bag` raise immediate `badarg`. Past end of table it returns the bare atom `:'$end_of_table'`, not a tuple or error.
- **`ets:update_element/4` insert-or-update variant**: the atomic upsert signature is `ets:update_element(Tab, Key, ElementSpec, DefaultTuple)`. The 3-arity form fails when the key does not exist. `(Tab, Key, Pos, Value)` is a badarg — `ElementSpec` must be `{Pos, Value}` or a list of such tuples.

### B. Dynamic Supervisor Elasticity (`PartitionSupervisor.resize!/2`)

- **Ceiling rule**: cannot grow beyond the original `partitions:` count — `resize!(sup, N)` with `N > configured` raises `ArgumentError` ("must be between 0 and N").
- **Return contract**: returns the **previous partition count** (integer), not `:ok`. Call sites must match on `prev_count`. Elastic strategies must be modeled **boot-at-max-capacity, shrink-to-idle**.

### C. Process Iterators vs. Legacy Sweepers

```erlang
Iter = erlang:processes_iterator(),
sweep_processes(erlang:processes_next(Iter)).

sweep_processes(none) -> ok;
sweep_processes({Pid, NextIter}) ->
    inspect_pid(Pid),
    sweep_processes(erlang:processes_next(NextIter)).
```

The BIF is `erlang:processes_next/1` (plural), matching the iterator constructor — `process_next/1` does not exist (witnessed `undef` on all three releases).

### D. Dialyzer Nominal Typing (`-nominal`)

`-nominal` (OTP 28+) enforces non-equivalence across identically shaped base types **strictly within the Dialyzer phase**. The BEAM runtime does not tag primitives with nominal metadata — at runtime an integer is a plain integer. Runtime structural guards require pattern-matched tagged wrappers or Elixir structs.

## 2. Verification Status: Available vs. Refuted Claims

| Primitive / Proposal | Operational Status | Production Guidance |
| --- | --- | --- |
| **`is_integer/3` guard** | **CONFIRMED (OTP 29)** | Single optimized VM opcode in function heads. Use heavily in protocol decoders for byte sizes and frame limits. |
| **Hybrid TLS (`x25519mlkem768`)** | **CONFIRMED (OTP 29)** | Default-preferred in `ssl`; out-of-the-box for handshakes without custom cipher manipulation. |
| **Native JSON (`:json`)** | **CONFIRMED (OTP 27+)** | SAX chunked decoding: bounded heap (< 30 KB measured on 50 MB payloads). Streaming NDJSON, Cosmos bulk arrays, blob listings. |
| **Isolated tracing (`trace:session_create/3`)** | **CONFIRMED (OTP 27+)** | Concurrent courts trace identical functions without cross-clearing. |
| **Functional graphs (`graph`)** | **CONFIRMED (OTP 29)** | Pure immutable terms replace process-bound `digraph` tables; Petri-net decomposition without cleanup debt. |
| **EEP 79 native records** | **REFUTED / UNAVAILABLE** | Not landed in OTP 29 / Elixir 1.20. Mitigation: strict Elixir structs (`@enforce_keys`) + Dialyzer nominal typing for AST boundaries. |
| **Comprehension syntax (`<-:-`, `compr_assign`)** | **REFUTED / UNAVAILABLE** | Not valid Elixir syntax, not standard Erlang compiler features. Mitigation: explicit multi-clause matching and `with` pipelines. |

## 3. Queueing Dynamics: Little's Law and the In-Memory Illusion

In-memory storage eliminates disk and network bottlenecks but introduces a queueing paradox governed by Little's Law (L = λW):

1. **Latency trap**: cloud middleware residence time is network/IO-dominated (15–50 ms); the in-memory substrate collapses W to 50–800 µs.
2. **Throughput spike**: with W down three orders of magnitude, unbackpressured client pools skyrocket λ.
3. **Mailbox saturation**: a downstream pause (scheduler preemption, minor GC) cascades the backlog directly into BEAM mailboxes and ETS write buffers — it does not stay on the wire.
4. **Counter-measures**:
   - Priority aliases are reserved strictly for **control-plane and supervisory signals** (drain, shutdown, resize) — never high-volume data streams (mailbox fairness).
   - **Client-side micro-batching** for high-frequency point writes (Cosmos CAS) before they hit the substrate — protects reduction budgets and browser/container memory ceilings.

## 4. Implementation Blueprint: Invariant Enforcement Pipeline

```
[ Inbound Wire Frame (TLS 1.3 / ML-KEM) ]
                  │
                  ▼
[ Function Head Invariants ]  <── is_integer(Len, 0, 104857600)
                  │
                  ▼
[ Streaming Parser ]         <── :json SAX decode (bounded heap)
                  │
                  ▼
[ In-Process Coordination ]  <── Registry.lock/3 (term-scoped mutex)
                  │
                  ▼
[ Shared Storage Plane ]     <── Dynamic ETS ({write_concurrency, auto})
                                  ├── ets:update_element/4 (atomic upsert)
                                  └── ets:next_lookup/2 (ordered-set cursor)
                  │
                  ▼
[ Observability & Telemetry ] <── proc_lib:set_label/1 + trace:session_create/3
```

Substituting deprecated patterns (`processes/0`, `slave`, global tracing, unindexed ETS traversals) with the verified mechanisms eliminates unforced GC stalls, cache-line thrashing, and secures microsecond execution determinism.

## 5. Cross-Check Against Executed Evidence (coordinator, 2026-10-21)

Every claim in this review was cross-checked against the probe receipts; **zero divergences found**:

| Review claim | Landed evidence | Agreement |
|---|---|---|
| `next_lookup/2` ordered_set-only, `:'$end_of_table'` | `receipts/val-ar-data.md` (probed both toolchains, same findings incl. arity correction) | ✓ |
| `update_element/4` ElementSpec/DefaultTuple form | `receipts/val-ar-data.md` (insert-or-update verified live) | ✓ |
| `resize!/2` ceiling + previous-count return | `receipts/val-ar-data.md` (resize_probe: "must be between 0 and N", 4→2 returned 4) | ✓ |
| `processes_next/1` plural; iterator works | `receipts/val-conflict-arbiter.md` (T37 upheld: 354× heap delta) + `impl1-process-iterator.md` (0 vs 514,605 words) | ✓ |
| `is_integer/3` CONFIRMED on 29, refused on 28 | `receipts/otp29-capability-probes.md` claim 6 | ✓ |
| ML-KEM default-preferred on 29 | `receipts/otp29-capability-probes.md` claim 5 (`default_groups()` leads with it on 29; last on 28) | ✓ |
| `:json` SAX bounded heap | `receipts/val-ar-wire.md` + `tmp/bench/t42-json.jsonl` (~23 KB peak, 3.3× faster) | ✓ |
| `session_create/3` CONFIRMED, list opts | `receipts/val-conflict-arbiter.md` (VAL-OBS's badarg was map-opts probe bug) | ✓ |
| `graph` module OTP 29-only | `receipts/val-ar-powl.md` + IMPL-7 cross-engine court | ✓ |
| EEP-79 / `<-:-` / `compr_assign` REFUTED | `receipts/val-ar-powl.md` + `receipts/val-ar-wire.md` + `val-ar-core.md` (EEP-76 head-injection behaviorally absent) | ✓ |
| Little's Law mailbox saturation | Measured analog: T43's head-of-line burst finding (sub-60 ms scheduler stalls queueing consecutive requests) + T3's L8192 queueing-collapse wall — the substrate exhibits exactly this regime at saturation | ✓ (measured analog) |

**One refinement to the review's §2 table**: `x25519mlkem768` is default-*preferred* on OTP 29 — but the substrate's listener currently pins TLS 1.2 (R90/D52 residual, `receipts/tls13-unpin-trial.md`); the ML-KEM default takes effect only after IMPL-14's opt-in-flip lands on the 29.1.2 host. CONFIRMED refers to the runtime capability, not the current listener posture.

*Addendum (BK-BMIR3, 2026-10-22): the `tmp/bench/t42-json.jsonl` evidence cited above now has a tracked byte-identical mirror at `docs/jira/v26.10.21/bench/t42-json.jsonl`; paired-sha256-verified, provenance `docs/jira/v26.10.21/bench/PROVENANCE.md`.*
