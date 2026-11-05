# aq-nif-boundary-spec

AQ NIF Boundary Spec (LANE-02, v26.11.5). Grounded in real code on 2026-11-04.

## Grounding (read this session)

- `/Users/sac/cgap/crates/wire-shm/src/ring.rs` @ cce95c35 — the landed
  zero-alloc ring (`WireRing`): `read_frame_into(&self, ordinal, &mut [u8]) ->
  Result<usize, WireError>` with `HEADER_LEN.checked_add(plen)` and typed
  refusals `FrameTooLarge` / `BudgetTooSmall` (ring.rs:158-189); fixed
  slots `ordinal % capacity`, 16-B header (magic/crc32/plen/ordinal),
  `MAX_PAYLOAD = SLOT_LEN - HEADER_LEN` = 4080 B.
- `/Users/sac/cgap/crates/cgap-beam/src/resources.rs` — hand-transcribed
  erl_nif resource ABI (OTP 28.3.1 / erts-16.2): `ErlNifResourceTypeInit`
  (resources.rs:45-51), `enif_open_resource_type_x` open-at-load, fail-closed
  `nif_load` (resources.rs:212-225), refcount ledger
  alloc → make_resource → release-NIF-local.
- `/Users/sac/cgap/crates/cgap-beam/src/resbin.rs` — `cgap_batch_binary/1`
  already projects an envelope payload zero-copy via
  `enif_make_resource_binary` (resbin.rs:63-84), with the consuming-id /
  non-consuming-envelope refcount discipline (resbin.rs:22-26) and the
  extern-verification receipt (declared erl_nif_api_funcs.h:134, exported by
  beam.smp; `enif_inspect_resource_binary` does NOT exist in this OTP).
- `/Users/sac/cgap/crates/cgap-beam/src/shm.rs` — mmap'd SPSC slot ring
  (`ShmRing`): `shm_open`+`mmap` MAP_SHARED, `NUM_SLOTS=8`, `SLOT_SIZE=64
  KiB`, Acquire/Release SPSC protocol, Darwin reopen-by-name EACCES platform
  law (shm.rs:31-51).
- One correction to the dispatch text: wire-shm itself carries **no bitmask**
  and no free list — its laws are the fixed-slot addressing and the S12
  zero-alloc/checked-add budget law. The bitmask recycling below is therefore
  **new** NIF-side machinery that mirrors the *fixed-slot* law (slot index ↔
  bit index, capacity ↔ bits), not a copy of any wire-shm bitmask.

## Slab model

The NIF exposes mmap'd slab memory, not syscall reads. Grounds:

- `enif_make_resource_binary` wraps a raw pointer for the binary's whole
  lifetime; a `pread`-based ring (`WireRing` is `File`-based,
  ring.rs:9-17) has no pointer to wrap. Zero-copy egress therefore requires
  the slab be memory: an mmap'd segment (`ShmRing`-class) or an mmap of a
  `WireRing` segment file.
- Choice: the resource holds an mmap'd slab of `capacity` fixed slots laid
  out per the wire-shm segment law — `[bookkeeping 4096B][slot 0]...[slot
  capacity-1]` (ring.rs:3-5), 16-B headers, crc32-validated. Frame
  validation reuses `read_frame_into`'s logic **in memory** (header check,
  `checked_add` budget law, crc32 over the mmap'd bytes) rather than
  re-implementing the ring.
- Egress binary = the whole mapped segment: `enif_make_resource_binary(env,
  obj, map_ptr, map_len)`. Per-frame views and receipt windows are
  `enif_make_sub_binary` of that parent — OTP sub-binaries reference the
  parent refc binary (no payload copy) when the parent is > 64 B, so a
  window is O(1) and 0 payload B/op.

## NIF surface

One new resource type `AqSlab` opened at load in `resources.rs::nif_load`
(fail-closed, same as `BatchEnvelope`; this OTP refuses resource-type opens
outside load/upgrade — falsified on the real BEAM, resources.rs:217-219).

- `aq_slab_open(PathBytes) -> Slab :: reference() | error`
  - mmap the segment (PROT_READ|PROT_WRITE, MAP_SHARED), validate the
    bookkeeping header (capacity vs file size, the `open` size-mismatch law,
    ring.rs:57-71). Backed by `WireRing::open` for validation, then `mmap`
    the same fd. Errors are the atom `error` (the `cgap_len` convention).
  - DirtyIo NIF (mmap + fstat + header pread on first open).
- `aq_slab_frame(Slab, Ordinal) -> Binary | error`
  - Zero-copy egress: `enif_make_resource_binary(env, obj,
    map_ptr + slot_offset(ordinal % capacity) + HEADER_LEN, plen)` —
    the binary IS the slab bytes. Header validated in memory first
    (magic, ordinal match, `checked_add` plen budget, crc32) — a failed
    validation is `error`, never a projected binary over bad bytes.
  - CPU-bound (memory ops only), regular scheduler.
- `aq_slab_window(Slab, Ordinal, Offset, Len) -> Binary | error`
  - `enif_make_sub_binary(frame_binary, offset, len)` — receipt windows
    (payload slices) without copying. Bounds checked against plen; refusal
    is `error`. The window keeps the parent binary (and thus the resource)
    alive — refcount law holds transitively.
- `aq_slab_stamp(Slab, PayloadBinary) -> ok | error` (writer side)
  - Ingress via `enif_inspect_iovec` (erl_nif_api_funcs.h:200, verified to
    exist by resbin.rs:46-52's extern survey): the BEAM passes the payload
    as an iovec; Rust validates `plen <= MAX_PAYLOAD` (the `FrameTooLarge`
    law) and copies into the next slot in memory (header stamp + crc32 in
    place). One bounded copy BEAM→slab is the ingress cost; egress stays
    0-copy. `enif_inspect_iovec` yields a temporary `ErlNifVec`/slice view
    valid for the NIF call only — read within the call, never stored.
  - CPU-bound; the stamped frame is crc'd and published by the bookkeeping
    `next_ordinal` store (ring.rs:119-121 order law: frame BEFORE ordinal).

## Slab free-list bitmask recycling (dtor)

`AqSlab` is per-slab state; frame leasing needs per-slot liveness so the
BEAM's drop of a frame binary returns its slot to the ring. Mechanism:

- A second resource type `AqLease` (dtor-owning): `aq_slab_lease(Slab,
  Ordinal) -> Lease :: reference()`. Its allocation is
  `(slab_obj_ptr, ordinal)`; its dtor clears the ordinal's bit in the slab's
  free-list bitmask.
- Slab-side bitmask: `u64` free mask, bit `i` = slot `i` leased for write.
  For capacity ≤ 64 (wire-shm slots: capacity is a segment design constant)
  one u64 covers every wire-shm-class segment; capacity > 64 is REFUSED at
  open (typed refusal, not a panic) until a mask array lands.
- Dtor law mirrors the BEAM refcount law: the BEAM GC of the last `Lease`
  term fires the dtor on SOME scheduler thread; the dtor clears the bit
  under the slab's spinlock/atomic AND-wap (`mask &= !(1<<i)` as an atomic
  AND, or a seqlock if stamp needs the mask too). At-most-once dtors are
  VM-guaranteed (resources.rs:167-179 ledger), so no double-free of a bit.
  At-most-once does not mean no-race: a concurrent `aq_slab_stamp` on the
  same slot (ordinal wrap) must see the bit set — stamp refuses a slot whose
  bit is still leased (`SlabSlotLeased` refusal, new error variant).
- Honest note: this is the NIF analog of the BEAM resource refcount, not a
  wire-shm mechanism; wire-shm's own law is `ordinal % capacity` overwrite
  (ring.rs:110, StampFrame overwrites silently by design).

## Safety analysis

### Refcount / dtor race windows

1. **GC-while-reading.** BEAM GCs the `AqSlab` resource while a Rust reader
   holds slab memory. Law: `enif_make_resource_binary`'s binary term holds
   the resource alive (erl_nif.h contract, resbin.rs:64-69), so any live
   frame binary pins the slab; a Rust reader inside a NIF call is pinned by
   the argument term (enif_get_resource pins for the call,
   resources.rs:279-301). The dangerous window is a Rust reader that
   OUTLIVES the NIF call (a thread or a dirty IO worker holding `&slab`
   past the call). Rule: no slab pointer leaves a NIF call; long-lived
   readers take the Lease resource (refcount) not a raw borrow. If a future
   lane needs cross-call borrows, it must `enif_keepreference`-class
   pinning or a Rust-side Arc inside the resource — never a raw borrow.
2. **Dtor-vs-stamp.** Lease dtor (clear bit) racing `aq_slab_stamp` (test
   bit): both touch the same u64 mask from different scheduler threads.
   Law: the mask is an AtomicU64 with
   `fetch_and !(1<<i)` in the dtor and an Acquire load + fetch_or in stamp;
   the slot-offset law (`ordinal % capacity`) means two ordinals can map to
   one slot — stamp refuses while the bit is set (typed `SlabSlotLeased`),
   the writer retries with a new ordinal. Lost-update impossible: AND and OR
   on one atomic are serialized by the hardware.
   fetch_and is not a primitive x86 btr — it is a cmpxchg loop at the LLVM
   level; the spec's law is the serialization, not the instruction.
3. **Dtor-on-garbage.** Leases are `enif_alloc_resource` blocks fully
   initialized before any term can name them (the
   "take-before-allocate / restore-on-fail" ledger, resbin.rs:148-156) —
   no dtor-on-garbage window, same discipline as `cgap_envelope_new`.
4. **Resource-binary mutability.** A resource binary aliases live slab
   bytes and BEAM binaries are immutable by assumption — the resbin.rs
   immutability law (resbin.rs:28-38) applies: once `aq_slab_frame`
   projects a frame, that slot's bytes are frozen for the binary's life.
   The bitmask lease does exactly this: a slot cannot be re-stamped while
   its bits are leased, so the overwrite law of the plain ring
   (ring.rs:96-122, silent overwrite) is SUSPENDED under the NIF boundary
   and replaced by `SlabSlotLeased` refusal. Writers that need ring-style
   overwrite use the plain (non-lease) path `aq_slab_stamp` with the
   ordinal advancing anyway — document the two modes explicitly, never
   infer at runtime.
   More precisely: with leases, the writer MUST hold a lease for the slot
   before stamping into it; the lease IS the reservation. No-lease stamp is
   the overwrite-legal mode, valid only when no frame binary was ever
   projected from that slot.
5. **fd/mapping lifetime.** The resource owns fd + mapping; its dtor
   munmaps and closes (the `ShmRing` Drop, shm.rs:410-417). Frame binaries
   pin the resource, so the mapping cannot die under a live binary. An
   external `unlink` of the segment name does not kill the mapping
   (POSIX: the mapping survives until munmap); Darwin EACCES reopen law
   (shm.rs:31-51) applies to any second-handle attempt — handles come from
   resource terms only, never name reopen.
6. **Two seeds law** applies to any crc/seed constants: wire-shm crc32 is
   IEEE crc32 (`crc32_ieee`, ring.rs:7); never conflate with cgap-parquet
   seeds.

### Dirty-scheduler classification

- `aq_slab_open`: **DirtyIo** — open/fstat/first-page touch + header
  validation pread; not scheduler-safe (syscall with possible disk wait).
- `aq_slab_frame` / `aq_slab_window`: **CPU** — pure memory ops on mapped
  memory (header validation in memory, crc32 over ≤ 4080 B ≈ tens of ns at
  3 GB/s). Bounded by MAX_PAYLOAD; never blocks. Regular scheduler legal;
  keep under ~1 ms (crc32 over 4 KiB is ~1.3 µs at 3 GB/s, three orders
  under the 1 ms budget).
  Bounded-poll law: no sleeps anywhere (no-sleep law); WouldBlock-class
  waits, if ever added, are bounded polls with Instant deadlines
  (shm.rs:365-396 is the pattern).
- `aq_slab_stamp` (iovec ingress + in-memory stamp + crc32): **CPU**. The
  file-backed durability path (`msync`, or a file-backed segment's
  fdatasync) is DirtyIo and MUST be a separate NIF (`aq_slab_sync`),
  never folded into stamp.
- `aq_slab_sync` (proposed, durability): **DirtyIo** — msync(MS_SYNC) or
  fdatasync; may block on disk.
- The mmap-based `aq_slab_frame` read path REPLACES `WireRing::read_frame`
  (pread + to_vec = 1 alloc + syscall) on the hot path; pread remains only
  in `aq_slab_open` validation. This preserves the S12 zero-alloc law while
  removing the syscall from the per-frame cost.

### Alloc census expectation

- **Rust side: 0 allocs/frame** (S12 law, ring.rs:151-158). Paths:
  `read_frame_into`-class in-memory validation onto stack buffers
  (`[u8; HEADER_LEN]`, crc over the mmap'd bytes), no assembled Vec.
  Witnessed precedent: P17 found shm.rs alloc-free; `alloc_spy`
  (alloc_spy.rs) is the existing census mechanism — extend it to record
  0 on the aq path; the census gate must be able to exit 1.
- **BEAM side: 0 payload B/op.** Resource binary = no copy; sub-binary
  window = no payload copy (parent > 64 B; windows are ≥ 1 B slices of a
  4080-B parent, parent law satisfied). The only BEAM bytes are the term
  boxes themselves (constant, not per-byte-of-payload). The 0 B/op charter
  claim is falsifiable via `:erlang.process_info`-level binary refs — no,
  the honest court is `erlang:memory(binary)` delta over N frames == N * 0
  payload bytes (constant term overhead excluded, stated in the court).
- Ingress is the declared exception: one bounded copy BEAM→slab per
  `aq_slab_stamp` (up to MAX_PAYLOAD = 4080 B). Egress is 0-copy; the
  charter's 0 B/op claim is scoped to egress + windows.
- Divan omits all-zero alloc columns (cgap CLAUDE.md known behavior) —
  absent means 0 only if courts corroborate; the alloc-spy census + a
  BEAM-side `erlang:memory(binary)` delta court is the pair.

## Decision record: new NIF in smalt vs extending cgap-beam

**Decision: extend cgap-beam.**

- cgap-beam already owns the hand-transcribed erl_nif ABI
  (resources.rs:1-112, verified against
  `/Users/sac/.erlmcp/otp-28.3.1/.../erl_nif.h` with line cites), the
  load-open fail-closed pattern, the refcount ledger
  (alloc → make → release-NIF-local), `enif_make_resource_binary` landed
  and extern-verified (resbin.rs:40-52), `alloc_spy`/`dtor_stats`
  instrumentation, and the single `ErlNifFunc` table discipline (lib.rs:480,
  21 entries).
- smalt has no `native/` tree and no NIF infrastructure — a smalt-side NIF
  would re-transcribe the ABI from scratch (the N-implementations-of-one-
  calculus O(N^2) drift law) and would need its own extern verification
  against the same OTP headers cgap-beam already cites by line number.
- Both crates are `publish = false` (cgap CLAUDE.md census), so no registry
  constraint favors either.
- cgap-beam also already owns the mmap'd slab machinery (shm.rs) — the slab
  the NIF exposes lives there.
- wire-shm is `ORPHANED-DATUM-FROZEN` (cgap CLAUDE.md) with its escalation
  ladder: the NIF consumes it as a runtime path dep for layout constants
  and `crc32_ieee`, via the cached `next_ordinal` + direct-slice
  "parked raise" rung — no wire-shm edits (the byte-identity drift fence
  stands). The NIF code lands in cgap-beam as `src/aq_slab.rs` (new module,
  new resource types registered in `nif_load`), consuming wire-shm as a
  path dependency for layout constants (SLOT_LEN/HEADER_LEN/MAGIC/
  crc32_ieee), not editing wire-shm.
- Note: cgap repo is currently mid-flight on OTHER lanes' files (mldsa
  dirty files, cce95c35) — cgap-beam edits are out of this lane's scope;
  this spec only names the landing site.

**Falsifier for the decision**: if a smalt-native NIF is ever proposed,
its ABI transcription must byte-match cgap-beam's extern signatures and
pass the same export-table (`nm -gU beam.smp`) verification; if it cannot
reuse cgap-beam's slab resource directly (cross-crate resource sharing is
not possible across separate .so files — resource types are per-loaded-
library), that is the only lawful trigger to re-open this decision.

**Falsifier for the spec itself (anti-vacuity)**: implement
`aq_slab_frame` per spec, then mutate the validator to skip crc32 — a
frame over corrupted slot bytes must be projected with the crc mismatch
still detected in-memory (i.e. the mutation must be caught by the typed
`CrcMismatch` refusal path) and the court must exit 1. A green run against
the mutated validator is VACUOUS. Second mutation: clear the lease bit in
the dtor without the atomic AND — a concurrent stamp must observe the race
or the court must demonstrate serialization; a court that cannot flip is
FAIL.

## Standing

- This doc: LANE-02 deliverable, ALIVE as a spec (planning artifact,
  not code). No code written, per lane contract.
- Landed code cited by path:line @ cce95c35 (cgap, this session's read).
- smalt main at c94b0143 before this commit; spec doc is the only change.
