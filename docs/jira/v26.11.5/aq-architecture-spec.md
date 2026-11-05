# AoQ-BEAM Architecture Spec

Program: AoQ-on-BEAM, LANE-01. Milestone dir: `docs/jira/v26.11.5/`.
Scope: the architecture of the AoQ plane as a NEW BEAM plane inside smalt,
including the compile-time enforcement design for match-context reuse.

## 0. Grounding — AoQ is a new plane, not a retrofit

The posh P1 census facts this spec builds on:

- `lib/smalt/posh` is a pure-Elixir BEAM engine (blake3, turnstile, ingress/
  egress, pipeline). It is NOT a Go binary dependency for the AoQ plane.
- `lib/smalt/posh/port.ex` / `lib/smalt/posh/client.ex` are
  latent-never-armed: both modules refuse to start unless `:socket_path` /
  `:bin_path` opts are supplied (`Keyword.fetch!` → module not started).
  No supervisor in the boot path arms them: POSH-005 scaffold, parked.
- AoQ therefore lands as a NEW plane on the TLS-twin dispatch pattern:
  `SMALT_TLS_ALL_PLANES=1` mounts the additive https Bandit listener
  running `Smalt.Application.TlsTwinDispatch` (see
  `lib/smalt/plane/data_supervisor.ex:81-94` — `egress_tls_child/0`).
  AoQ joins that pattern with its own port + dispatch plug; it does not
  retrofit the posh engine or the existing data-plane listeners.

## 1. Process topology

### 1.1 Processes in the AoQ plane

| process | kind | role |
|---|---|---|
| `Smalt.Aoq.Supervisor` | `one_for_one` supervisor | root of the AoQ subtree |
| `Smalt.Aoq.Listener` | Bandit/ThousandIsland | AoQ wire face (own pinned port) |
| `Smalt.Aoq.WorkerPool` | `:poolboy`-class pool supervisor | fixed pool of frame workers |
| `Smalt.Aoq.Worker` (xN) | plain GenServer-free processes | stateless per-frame parse/emit |
| `Smalt.Aoq.NifHolder` (per NIF family) | GenServer | holds NIF resource refs alive |
| `Smalt.Aoq.Cursor` | GenServer owning `:atomics` | ring cursors, lease counters, seq (see §6) |
| QUIC runtime (deferred) | per LANE-03 decision | placeholder slot, not started in v1 |

### 1.2 Supervision shape

```
Smalt.Aoq.Supervisor (one_for_one)
├── Smalt.Aoq.Listener        (Bandit; shutdown 10_000 — the AZB-22b pattern)
├── Smalt.Aoq.WorkerPool      (pool supervisor; workers restart, state lives
│                             in :atomics/persistent_term, not the worker)
├── Smalt.Aoq.NifHolder(s)    (one per NIF resource family)
└── Smalt.Aoq.Cursor          (atomics owner; crashes rebuild tables, data
                              unaffected — :atomics survive process death)
```

Design law: workers are stateless. All durable AoQ state (cursors, leases,
seq) lives in `:atomics` (owned by `Smalt.Aoq.Cursor`, but atomics memory
survives the owning process), so a worker crash is a restart, never data
loss. This is the same law the existing ring buffer honors structurally:
`Smalt.Posh.Ingress.RingBuffer` keeps state in the GenServer and callers
never block indefinitely; AoQ moves the hot counters OUT of the GenServer
into lock-free atomics so the GenServer is not on the hot path at all.

### 1.3 Message flow and ports

```
client → Listener port (pinned, config :smalt, :aoq_port; test = ephemeral
         under config/test.exs — the 9092/5675/5676 precedent)
       → TlsTwinDispatch-class plug → frame demux
       → WorkerPool (push frames in; workers pull)
       → Worker parses (§4), resolves tables (§5), emits via iolist (§3)
       → Listener socket egress (iolist write, zero-copy into ErlIOVec)
       → Cursor atomics updated by the emitting worker directly (no
         GenServer call on the hot path)
```

Direction of authority is one-way: Listener owns the socket; workers own
nothing; Cursor owns no data, only the atomics handles. NifHolder owns
resource lifetimes only. No process sends a request to another on the data
path — the only synchronous hop is Listener → pool push, and the only
reply is the socket write from the same worker.

AoQ is NOT behind the 8443 data-plane Bandit and does not retrofit the
posh ingress ring buffer; it gets its own listener + pool (the plane
law: `SMALT_PLANES` gains `aoq` as a bootable plane name — unknown names
already refuse boot, `lib/smalt/planes.ex`).

## 2. The >64B RefcBinary framing law

BEAM binaries ≤64 bytes are heap binaries (HeapBin): allocated inline in
the process heap, copied on message send. Binaries >64 bytes are RefcBin-
aries: allocated off-heap in a refc arena, message "send" passes a
reference (procret/sub-binary sharing) — zero copy. Sources: Erlang
Efficiency Guide, "Memory usage / Shell" and the `erl_nif` docs
(`enif_new_binary`/resource semantics); Erlang Reference Manual, "Heap
binaries" (the 64-byte constant `ERL_ONHEAP_BIN_LIMIT`).

Law: every AoQ frame is encoded as a 64-byte header + body of at least
1 byte. A ≥65-byte total guarantees the payload is always a RefcBinary,
so frame handoff between Listener, pool, and workers is pointer-passing,
never a 64B-capped heap copy. Two corollaries:

- No AoQ message may carry a bare ≤64B binary as its only payload. The
  64B header is always present, so this falls out structurally; the CI
  frame-court asserts header size exactly 64 and body ≥1 on the wire
  format module.
- Sub-binary extraction (`binary:part/3`, pattern matches) on a RefcBinary
  creates shared sub-binaries — also off-heap, also zero-copy. The law
  makes the whole frame path share one allocation per frame.

## 3. Egress law: iolist `[Header | Payload]`, never `<>`

`<>`/`<<...>>` binary append allocates and copies into a new binary.
An iolist is a scatter-gather list the runtime writes straight into
`ErlIOVec` — zero intermediate copy through every port/file/socket writer
(`file:write`, `gen_tcp`/`ssl` send, Bandit's adapter layer all consume
iolists natively).

Law: every AoQ egress site emits `[header :: binary-size(64), payload]`
(or deeper `[h, p]` nesting — iolists flatten at the writer). Banned:
`header <> payload`, `<<header::binary, payload::binary>>` at any egress
site.

Enforcement: a grep gate in CI (same class as the existing naming-sweep
fail-closed greps) asserting no `<>` binary-append on the frame path
modules (`lib/smalt/aoq/**`), plus a byte-fidelity court that asserts the
iolist write produces the identical wire bytes as a `<>` reference
encode — the court proves the law, the grep keeps it.

## 4. Match-context reuse per parse site (bin_opt_info enforcement)

Requirement: every binary match in AoQ code must compile with
`ERL_COMPILER_OPTIONS=bin_opt_info` reporting match-context reuse — no
`INFO: no match of the binary ... could be optimized` /
`optimization of ... is not possible` class warnings on any AoQ module.

Per-site requirements:

- Every parse function takes the remainder binary as its LAST argument
  (match-context chaining works only when the matched binary is the last
  argument) and returns `{parsed, rest}` so the next match reuses `rest`
  as the context.
- No match on a sub-binary produced by `binary:part/3` in the same match
  chain — pass `rest` directly.
- Size segments before the match, not inside it (a variable-size segment
  ahead of a fixed segment can defeat the optimization).
- No match on the result of `<>` (constructs defeat context reuse).
- Skip-ahead with `_/binary` and explicit byte-size matches reuses the
  context; matches that resize (e.g. `size/1` calls before matching) do
  not.

Compile-time enforcement design (CI step):

1. `scripts/bin_opt_gate.sh`: compiles `lib/smalt/aoq/**` with
   `ERL_COMPILER_OPTIONS=bin_opt_info`, captures stderr, and fails
   closed on ANY line matching the warning classes
   (`no match .* could be optimized|optimization .* is not possible|
   not a binary directive|deferred`) emitted for a module under
   `lib/smalt/aoq`. Zero warnings = exit 0. Warnings for NON-AoQ modules
   (stdlib, deps, rest of lib/) are ignored — the gate is scoped to the
   AoQ surface, like the naming sweep is scoped to its surface.
2. Non-vacuity: a shim-court mutation inserts a deliberately
   non-reusable match (match on `binary:part/2` output mid-chain) into an
   AoQ module → the gate MUST exit 1; a gate that accepts the shim exits
   1 as `VACUOUS GATE` (`just shim-court bin-opt`). Same contract class
   as sleep-gate-court.
3. Wiring: `justfile.d/NN-bin-opt.just` adds `bin-opt` +
   `bin-opt-court`; `just court` chains `bin-opt-court` after
   `invariant-gates` (a new red gate after an early red gate is the
   documented cascade — budget for it).
4. Gate result receipt lands in `tmp/bin-opt/` (scratch, not indexed),
   with the warning-class regexes pinned in the script header so
   premise rot in the warning text is a diff, not a silent pass.

## 5. persistent_term tables

Three `:persistent_term` tables (single-key tables — each key holds one
map, so updates rewrite one key, never scan):

- **Frame-type dispatch table** (`{:aoq, :frame_types}`): frame-type byte
  → {module, function} handler map. Written ONCE at boot from the static
  frame-type registry (compile-time module attribute). Read on every
  frame by workers — the read is a constant-time ETS-internal lookup with
  no lock. What never changes after boot: the key set and handler
  bindings. Update path: none in v1; a future hot-reload path replaces
  the whole map in one `persistent_term:put` and pays the documented
  global GC scan cost — which is why it is write-once.
- **Epoch-key registry** (`{:aoq, :epochs}`): epoch id → {key material
  reference, start offset}. Written at boot and ONLY on epoch rotation
  (rare, operator-driven). Reads: workers resolve the epoch of an
  incoming frame header. Never changes after boot except rotation; the
  registry is append-only per epoch (old epochs retained for late
  frames).
- **Arrow schema registry** (`{:aoq, :arrow_schemas}`): schema id →
  compiled Arrow schema (NIF resource term held alive by the matching
  `Smalt.Aoq.NifHolder`). Written at boot from the schema bundle; never
  changes after boot. Holding the schema as a NIF resource term inside
  persistent_term means every worker read passes the resource pointer
  across process boundaries with no copy — this is why the NifHolder
  exists as a separate supervised process (§1.1) rather than the schema
  living in a GenServer state.

Write/read pattern summary: boot-time `put`, hot-path `get`, and the
invariant that a table whose key never changes after boot costs one
GC-scan-free read forever. Any future mutation of these tables must
re-derive from the boot source and `put` the whole map.

## 6. :atomics lease/cursor/seq layout

One `:atomics` array per ring, owned (created) by `Smalt.Aoq.Cursor` but
addressed by index from any worker (atomics are ref-counted off-heap
memory, immune to the owner's death — recreate via Cursor restart only
re-establishes the handle, data semantics preserved by the layout below).

Layout (u64 slots, indices fixed at boot):

| index | name | meaning |
|---|---|---|
| 0 | `ring_head` | write cursor: next slot a producer claims |
| 1 | `ring_tail` | read cursor: next slot a consumer releases |
| 2 | `lease_ctr` | monotone lease counter for slot leases |
| 3 | `lease_gen` | lease generation (bumped on ring reset) |
| 4 | `seq` | u64 wrapping sequence number for frame ordering |
| 5 | `drop_ctr` | cumulative drops (RingBuffer drops/1 successor, off GenServer hot path) |

Semantics:

- Ring cursors (`ring_head`/`ring_tail`) advance with
  `:atomics.add_get` — the CAS-equivalent claim/release. Producers claim
  head slots with `add_get(head, 1)`, consumers release tail the same
  way. Capacity bounds are enforced by the head−tail distance, not by a
  counter check-then-set.
- Lease counters (`lease_ctr`, `lease_gen`) are `add_get`-only; a lease
  is (gen, ctr) — gen bumps invalidate all outstanding leases on ring
  reset without resetting ctr, so late lease holders fail typed.
  Wrapping is lawful: u64 wraps are accepted, comparison is
  subtraction-based (unsigned wrap-safe compare).
- `seq` is a plain wrapping u64 (`:atomics.add_get(seq, 1)`); ordering
  comparisons must be `(a - b) mod 2^64 < 2^63` — never `a < b` (a
  wrapped seq would invert every comparison after 2^64 frames).
- All reads use `:atomics.get`; no lock exists anywhere in the layout.
  The single-writer-per-index law holds: each index has exactly one
  mutating op class (add_get), so no compare-exchange loop is needed.

## 7. Falsifiers

- A frame under 65 bytes total reaching the wire → framing law refuted.
- An egress site emitting a single concatenated binary → iolist law
  refuted (the byte-fidelity court also detects the copy indirectly via
  the grep gate; the court is the proof, the grep the fence).
- A `bin_opt_info` warning on an AoQ module passing CI → enforcement
  refuted (shim-court proves the gate is not vacuous).
- A hot-path GenServer call between worker → Cursor on the frame path →
  topology law refuted.
