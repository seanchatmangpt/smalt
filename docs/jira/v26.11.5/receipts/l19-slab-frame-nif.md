# L19 — aq_slab NIF Surface 1 (slab frame + lease)

Standing: ALIVE

## Subject
`aq_slab_frame` zero-copy egress NIF over an mmap'd wire-shm-layout slab,
per `docs/jira/v26.11.5/aq-nif-boundary-spec.md` (fa2e15f1), landed in
cgap-beam (spec's decision record: extend cgap-beam, consume wire-shm as a
path dep, no wire-shm edits).

## Diff (cgap @ dfd9ae4f, branch main)
- NEW (landed in WIP commit 8dd66b2e during the wave; finalized in
  dfd9ae4f): `crates/cgap-beam/src/aq_slab.rs` (~840 lines) — AqSlab +
  AqLease resource types (opened fail-closed in nif_load), mmap'd slab
  resource over `Arc<SlabState>`, in-memory frame law (magic, stored
  ordinal, checked_add budget, crc32_ieee over mapped bytes), stamp with the
  frame-BEFORE-ordinal order law, AqLease free-list bitmask resource (u64
  mask, capacity<=64 law, dtor fetch_and AcqRel clearing, stamp refuses a
  leased slot), alloc-spy wired at the open/lease resource-alloc sites,
  SHIM-COURT mutation flag (AQ_MUTATE_CRC_SKIP=1 skips the crc compare).
- `crates/cgap-beam/src/lib.rs` — mod aq_slab; func table now 27 entries
  (aq_slab_open DirtyIo, aq_slab_frame/window/stamp/lease CPU; aq_slab_sync
  DirtyIo was added to the shared surface by a concurrent lane and is
  stubbed in all three escripts).
- `crates/cgap-beam/src/resources.rs` — `resource_type_init_dtor`
  constructor + `open_aq_types` wired into nif_load (one-line-class
  disclosure: build-registry addition only, no existing surface changed).
- `crates/cgap-beam/Cargo.toml` — `wire-shm` path dep (no wire-shm edits).
- `crates/cgap-beam/tests/aq_slab_contract.rs` — NEW BEAM contract court.
- `crates/cgap-beam/tests/{bridge_contract,kill_stress}.rs` — stub + export
  lists extended (load_nif's eager export check requires every library
  entry to have a module export).

## Court (BEAM-side, real BEAM + real mmap'd slab files, no mocks)
`tests/aq_slab_contract.rs` drives escript against the REAL dylib:
1. open refusals: capacity 65 (u64 mask law), capacity-field vs file-size
   mismatch (ring.rs:57-71 law), missing file, non-binary path.
2. stamp/frame/window roundtrip incl. `ordinal % capacity` wrap addressing,
   unstamped BadMagic, stored-ordinal mismatch, window bounds vs plen.
3. CrcMismatch negative leg: stamp, project, corrupt the payload THROUGH
   THE FILE (file:pwrite), re-project → `error` (typed in-memory refusal);
   window refuses too.
4. Lease lifecycle: child process holds leases (stack-bound terms can't be
   GC'd), deterministic stamp refusal inside the holder, double-lease
   error, monitor/receive-timeout ordering (runtime-owned time, no sleeps),
   bounded poll on the stamp observable until dtors clear the bits, then
   frame == stamped payload.
5. Alloc-spy census: K=1000 frame + window projections, `cgap_alloc_stats`
   delta {0,0} — the S12 egress zero-alloc law.
6. SHIM-COURT anti-vacuity (spec falsifier): running the SAME court with
   AQ_MUTATE_CRC_SKIP=1 MUST exit 1 — asserted in the Rust harness
   (assert_ne!(rc_m, 0)). MUTATION VERDICT: FLIPPED (court exits 1 under
   the mutation; green under the real validator).

## Verification ladder (commands + exits, this session)
- `cargo build -p cgap-beam` — exit 0.
- `cargo test -p cgap-beam` — exit 0; 16 lib + 3 integration tests passed;
  stable across 2 full reruns (and 5x lib-only reruns mid-session).
- `git push origin main` → `git ls-remote origin main | grep HEAD` —
  VERIFIED at dfd9ae4fced4b4de755a550666191eee78526a6e (bounded retry x3,
  first attempt confirmed).

## Rust-side courts (in aq_slab.rs #[cfg(test)], 4 tests)
Real tempdir segment files, no mocks: roundtrip incl. wrap, CrcMismatch +
budget laws, lease-mask dtor law (SlotLeased refusal, clear-then-stamp),
open refusals (capacity 65, size mismatch, missing file). One real bug was
caught and fixed by these tests: stamp_into never wrote the header ordinal
field (StaleOrdinal on every later validate).

## Deviations from the spec (disclosed, each one-line)
1. Ingress uses `enif_inspect_binary` (stamp arg is a binary term), not the
   spec's `enif_inspect_iovec` — same law, smaller transcribed ABI surface.
2. Windows are a direct `enif_make_resource_binary` over the mapped window
   bytes, not `enif_make_sub_binary` of an intermediate frame term — same
   zero-copy law, window pins the slab resource directly.
3. Open validation applies `WireRing::open`'s size-mismatch law on the
   mapped bytes (fstat-by-metadata vs bookkeeping capacity) instead of a
   second WireRing handle (Darwin second-handle law, shm.rs:31-51).
4. Lease lifetimes go through `Arc<SlabState>` inside each resource (the
   spec's own "Rust-side Arc inside the resource" safety rule) rather than
   raw pointer + manual refcount plumbing.
5. `aq_slab_sync` (DirtyIo msync durability NIF) landed on the shared
   surface via a concurrent lane's edit to this same module — stubbed and
   green here, not re-derived in this receipt.

## Collision ledger
- L14's files untouched: no cgap-crypto/pqc_seal files in this diff.
- Shared-file touches: bridge_contract.rs and kill_stress.rs (stub/export
  lists only — required by load_nif's eager export check after the table
  grew to 27 entries); lib.rs and resources.rs (build registry: mod line,
  func table entries, open_aq_types in nif_load, resource-init ctor).
- Mid-flight collision witnessed: a concurrent lane's WIP commits
  (8dd66b2e, 391a7981, 425b6a28) landed in-flight versions of THIS lane's
  files; final state committed in dfd9ae4f supersedes them.

## Standing
ALIVE: every claim above is backed by a command + exit run this session
against the exact subject (cgap dfd9ae4f). Known open items: the `file`
field of SlabState is read only through its Drop (dead_code-warned field is
kept for fd-lifetime law); SlabErr payloads are unread outside Debug/tests
(allow-annotated, typed-refusal surface).
