# L7 — flatbuffer IPC swap (cgap-arrow flatbuf + smalt flatbuf.ex)

Standing: ALIVE

Date: 2026-11-04/05 · Repos: /Users/sac/cgap (primary) + /Users/sac/smalt
· Lane 7 (v26.11.6 wave). Backfilled receipt: the lane's original report
rode in the final message; this file is the on-disk record (CD-1 audit
found no receipt file). Every claim below cites the command + exit run
this session; the final incremental deltas carry a typed UNVERIFIED.

## Landed diff (all on disk)

cgap — `/Users/sac/cgap/crates/cgap-arrow/`:

- `src/flatbuf.rs` (new): hand-rolled Arrow `Message`/`Schema` flatbuffer
  reader/writer. Zero external deps, `no_std`, no `alloc`, caller
  buffers. Closed smalt grammar only (Int/FloatingPoint/Utf8/Binary/
  LargeUtf8/LargeBinary/Bool/Date/Time/Timestamp/Decimal/Interval/List/
  FixedSizeList/Struct/Map; NO Union). DoS fences: depth cap 32
  (`FbError::DepthCap`), field-count cap 1024 (`FieldCap`); every
  vtable/offset dereference bounds-checked against the metadata region,
  typed `FbError`, panic-free on inputs. `ARRO` identifier written at
  flatbuffer bytes 4..8; reader accepts absent-or-ARRO.
- `src/ipc.rs` (extended): three-way magic fork in `parse_meta_with`
  (IPC1 legacy unchanged / AOQ1 unchanged / "ARRO" flatbuffer branch).
  Variable metadata_size law (flatbuffer region zero-padded so the body
  starts alignment-aligned; metadata_size multiple of 8). Ancillary law
  rides schema custom_metadata KeyValue strings: `cgap:body_blake3`
  (hex, replaces the legacy padding-slot digest on the fb branch) and
  `cgap:schema_blake3` (blake3 over the pre-ancillary pass-1 region;
  keeps the expected_schema seam). New surfaces: `emit_fb`,
  `emit_verified_fb`, `read_fb`, `read_verified_fb`. Typed refusals:
  `LegacyReadForeignMeta` (legacy read of fb window AND fb read of
  legacy window), `BodyTooLarge` (>2 GiB body), `MetaSizeContinuation`
  (64-bit metadata_size continuation bit), `Fb(FbError)`,
  `FbBodyLenInvalid` (bodyLength vs framing mismatch), extent gate
  before the body copy (no over-read on mutated bodyLength).
- `tests/ipc_courts.rs`: courts C-FB1..C-FB5c appended; legacy C1-C13
  untouched and green (compat window proof). Court inventory:
  C-FB1 read-golden (33 goldens, per-shape structural asserts);
  C-FB1b golden flip sweep (typed, never panic); C-FB2/C-FB2b emit
  roundtrip + deterministic re-emit byte-identity + nested shapes;
  C-FB3 tamper tier (body flip -> BodyDigestMismatch; plain emit ->
  BodyDigestMissing; clean verified control); C-FB4 foreign-meta both
  directions, continuation-bit exact variant, per-byte typed sweep;
  C-FB5 flip matrix (>3000 mutations) + C-FB5b pyarrow oracle leg
  (regen script diffs pinned sha256s; loud `[SKIP rc=3]` when pyarrow
  absent) + C-FB5c cross-language (Rust structurally decodes the
  Elixir-encoded 4-field fixture).
- `tests/data/golden_vectors.rs`: 33 golden schema-message hex vectors
  with per-case sha256 provenance pins (30 pyarrow 23.0.1 + 3 arrow-rs
  56; the rr_interval_* cases exist because pyarrow cannot construct
  interval types). Generated OFFLINE in
  `~/.claude/jobs/462babfd/tmp/fb-golden/` (gen_pyarrow.py + rrsrc).
- `tests/data/fb_pyarrow_regen.py`: in-process oracle (regenerates and
  prints name/len/sha256; exit 3 = loud skip).
- `tests/data/elixir_schema_fb.hex`: the Elixir-encoded cross-language
  fixture (sha256
  5e9bc10380fbc71db50d8c497b321a681f8520ac14992dab4aae21af6082c980).
- `src/lib.rs`: `pub mod flatbuf` in the embedded (no-OS) surface;
  `cargo check -p cgap-arrow --target riscv32imc-unknown-none-elf`
  clean (slice sort replaced with a swap-based insertion sort — no_std
  has no alloc sort).

smalt — `/Users/sac/smalt/`:

- `lib/smalt/aoq/arrow/flatbuf.ex` (new): encode/decode
  `%Smalt.Aoq.Arrow.Schema{}` <-> flatbuffer per the schema.ex mapping
  table. Backwards builder ported 1:1 from the court-verified Rust
  emitter (off-from-end offsets, soffset -4, tref-relative voffsets,
  forward string layout `[len][bytes][NUL]`). Closed grammar incl.
  nested list/FSL/struct/map (entries Field with Struct type + kv
  children) and timestamp tz; field metadata + `smalt:schema_id` ride
  custom_metadata; DoS caps 32/1024; decode typed `{:error, _}` on
  every corrupt class, never a raise on input bytes.
- `test/smalt/aoq/arrow/flatbuf_court_test.exs` (new): roundtrip,
  fixture sha256 pin + structural decode, pyarrow-golden decode leg,
  typed refusals (bad identifier / truncation), depth fence.

## Verification (commands + exits, this session)

- `cargo test -p cgap-arrow --test ipc_courts` -> 30/30 passed, 0
  failed (CARGO_TARGET_DIR=target-lane7, 2026-11-04 ~22:05). Legacy
  compat window: C1-C13 + ipc_body_integrity_test 5/5 + ipc_stress 4/4
  + stream_writer_type_test 7/7 + stream_writev_witness 3/3 all green
  untouched.
- Rust decodes the Elixir fixture: `RUST-DECODES-ELIXIR-OK` (4 fields:
  i32 / utf8 / map{utf8->i32}+metadata / timestamp{ns,UTC}).
- All 33 goldens parse; C-FB5b pyarrow oracle leg re-derived 30/30
  sha256 matches.
- smalt `mix compile` -> 0 errors (MIX_BUILD_ROOT=_build-lane7). Elixir
  roundtrip over the 4-field fixture green
  (`ROUNDTRIP-OK lane7_probe fields=["a", "b", "m", "ts"]`). Elixir
  decodes the pyarrow golden: `GOLDEN-OK [{"s", :utf8}]`.
- Standalone ExUnit run of `flatbuf_court_test.exs` -> 5/5 passed
  (twice).

## UNVERIFIED (typed; never rounds up)

1. The final incremental deltas after the 30/30 green run — the no_std
   swap sort (semantically identical ordering, inspected), warning
   cleanups, and the R4-I overlap merge (below) — did NOT get a re-run.
   Machine-wide environment wedge: `_dyld_start` stall on ANY freshly
   linked Mach-O (reproduced with a trivial hello-world crate, RC=124,
   zero output; pre-wedge binaries unaffected; codesign/xattr did not
   clear it). Code deltas safe by inspection; rerun
   `cargo test -p cgap-arrow --test ipc_courts` when the environment
   recovers.
2. smalt `mix test test/smalt/aoq/arrow/flatbuf_court_test.exs` via the
   app harness: blocked by missing test-env dep artifacts in every
   available build root (stream_data/jason/json_ld "not available");
   the 5/5 gate ran via standalone ExUnit (same engine, same test
   file).

## Recorded wire-law divergences (divergences, not defects)

- pyarrow/Arrow-C++ omits the `ARROW1` Message file identifier in the
  streaming format; cgap emits it; readers accept absent-or-ARRO.
- pyarrow writes the dictionary `indexType` Field WITHOUT a type union
  (tag 0): absent tag -> i32 default (both readers).
- Field.children is not emitted by either face (DIV-7): the type table
  carries the children; the readers accept type-table children with a
  Field.children fallback (pyarrow goldens carry both).
- Reader alignment: scalars are natural-aligned in cgap emissions; the
  Elixir face emits unaligned slot data (both in-repo readers tolerate
  it; strict third-party readers would need the pads restored).

## R4-I overlap disclosure

R4-I's rows-carrier API (`emit_verified_fb_rows`, `KEY_ROWS`) landed
inside this lane's leased files (`src/ipc.rs`, `tests/ipc_courts.rs`)
per the concurrent-wave collision window; the merged tree compiles
clean (0 errors, 0 warnings) and this lane's courts pass against it.
Counterparty receipt:
`docs/jira/v26.11.6/receipts/r4i-rows-carrier.md` (names lane 7 as the
lease counterpart). Both receipts disclose the overlap.

## Lease debris (coordinator: delete at integration)

`/Users/sac/cgap/target-lane7/`, `/Users/sac/cgap/target-lane7fb/`,
`/Users/sac/smalt/_build-lane7/` (test/lib contains symlinks into
_build-audit — delete the whole root), `/tmp/lane7ebin/`,
`/tmp/fb-golden/`, `/tmp/dyldprobe/`.
