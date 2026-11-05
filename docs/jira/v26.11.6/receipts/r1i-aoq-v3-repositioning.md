# R1-I: AOQ v3 repositioning (smalt frame.ex v3 + cgap golden bytes)

Standing: ALIVE

## LANDING BLOCKER RESOLVED (L17-R, bin_opt gate — 2026-11-05)

The sole v26.11.6 landing red (4 scoped bin_opt warnings on
stage3_fields/10 + admit_stream/7) is FIXED by owner-lane context-reuse
restructure per the L17-R unblock path:

- stage1 now matches only the fixed 64B header (+ trailing `_::binary`
  discard; the ≥65B guard stays in the stage1 head guard).
- `stage3_fields/8` FORWARDS ONLY — no sub-binary args (was /10 carrying
  body_rest).
- `admit_stream/5` head binary-matches `bin`:
  `<<_header::binary-size(64), body::binary>>` — the body sub-binary is
  created in the CALLEE HEAD (bin_opt law), no binary_part slice, no
  `<>` copy; the inner `<<stream_type, _rest>> = body` match reuses
  context; the returned body is the zero-copy sub-binary.

Verification (this session, exact commands):
```
bash scripts/bin_opt_gate.sh
  → SUMMARY scoped_fail=0 scoped_benign=8 ; bin_opt gate: PASS (was
    scoped_fail=4 on stage3_fields/10 + admit_stream/7 pre-fix)
MIX_BUILD_ROOT=_build-laneR1 mix test test/courts/aoq_framing_court.exs \
  test/courts/aoq_cross_repo_court.exs test/courts/aoq_layout_drift_court.exs \
  test/smalt/aoq/frame_epoch_rotate_test.exs → rc=0, Result: 38 passed
```
One regression caught and fixed during the restructure (witnessed 22/38
RED → fixed → 38/38 GREEN): the stage1 fixed-prefix match needed a
trailing `_::binary` segment or every ≥65B frame fell to :bad_header.
The 24-leg framing-law court held the guard exactly as contracted.

Executed 2026-11-04, canonical checkouts /Users/sac/smalt + /Users/sac/cgap, NO git
transitions (fleet law). Plan per overnight contract, stages S1–S7.

## Landed diff (subject)

smalt:
- `lib/smalt/aoq/frame.ex` — v3 rewrite. Wire: LE 64B header, magic u32 LE
  0x414F5131 (wire bytes "1QOA"), version 3 u16 LE @4, epoch u16 @6
  (closed enum), key_id u64 @8, frame_ordinal u32 @16, seq u32 @20,
  reserved 36B zeros, FNV-1a32 over [0,60) stored LE @60. 3-stage decode
  with digest gate over the ORIGINAL binary (binary_part [0,60)); refusal
  order magic→version→epoch→(reserved/stream); struct {epoch, key_id,
  frame_ordinal, seq}; v2 type/flags/payload_len RETIRED; StreamType
  1-byte body prefix dispatch; EOS = exactly the 1-byte prefix;
  `:bad_digest` replaces `:bad_crc`; encode refuses `:retired_epoch`.
- `lib/smalt/aoq/generated_aoq_header_layout.ex` (new) — DO-NOT-EDIT graph
  twin with compile-time contiguity court + `header_fields/0`.
- `lib/smalt/aoq/epoch.ex` (new) — closed `aoq:Epoch` enum
  (genesis/rotated_1/rotated_2/retired=65535 read-only sentinel).
- `lib/smalt/aoq/tables.ex` — frame_types re-keyed by aoq:StreamType
  {0,1,2}; `epochs` demoted to a key-material registry (decode no longer
  consults it; enum enforcement moved into the codec).
- `test/data/aoq_v3_golden.hex` (new) — 65-byte genesis frame (epoch=0,
  key_id=0x0102030405060708, ordinal=7, seq=42, StreamType prefix 0,
  1-byte body), DERIVED from the real cgap-aoq `codec::encode`, never
  guessed.
- `test/courts/aoq_framing_court.exs` — 24-leg v3 re-pin.
- `test/courts/aoq_layout_drift_court.exs` (new) — parses the landed
  ontology TTL and asserts field-by-field equality with the generated
  twin; 4 anti-vacuity mutation legs (offset/wireKind/sizeBytes/version)
  all RED on mutated copies.
- `test/courts/aoq_cross_repo_court.exs (new) — cgap-encoded bytes decode
  byte-identically in smalt, smalt re-encode reproduces the fixture, FNV
  agreement, plus a structural non-default frame leg.
- `test/smalt/aoq/frame_epoch_rotate_test.exs` — v3 control-stream
  contract (prefix 1 + u16 BE new epoch), closed-enum epochs.
- `test/smalt/aoq/iovec_court_test.exs` — refusal token re-pin
  (`:empty_payload` → `:empty_body`).

cgap (read-only + fixture per plan):
- `crates/cgap-aoq/tests/aoq_v3_golden_bytes_fixture.rs` (new) — derives
  the golden frame via real `codec::encode` and asserts byte-identity with
  the committed hex; round-trips the committed fixture.
- `crates/cgap-aoq/src/header.rs` — KD-201 rider: v2→v3 PROSE-ONLY doc fix
  (three doc lines), `// KD-COVERS: KD-201` comment. Consts untouched
  (already graph-pinned to gen::AOQ1_VERSION=3).

docs:
- `docs/jira/v26.11.6/KNOWN_DIVERGENCES.md` — KD-201 row minted (v3
  wire-version bump, CLOSED-WITH-EVIDENCE). Note: KD-199/200 were minted
  mid-flight by sibling lanes (first-minted-wins); renumbered to KD-201.

## Commands + exits

```
cd /Users/sac/cgap && cargo test -p cgap-aoq --test aoq_v3_golden_bytes_fixture
  → 1 passed (first derivation run; lock-contended re-verify pending, see UNVERIFIED)
cd / smalt: MIX_BUILD_ROOT=_build-laneR1 mix compile → 0 errors
MIX_BUILD_ROOT=_build-laneR1 mix test test/courts/aoq_framing_court.exs \
  test/courts/aoq_layout_drift_court.exs test/courts/aoq_cross_repo_court.exs \
  test/smalt/aoq/frame_epoch_rotate_test.exs
  → Result: 38 passed  (24 framing legs + 5 drift + 4 cross-repo + 5 rotate)
MIX_BUILD_ROOT=_build-laneR1 mix test test/smalt/aoq test/courts/aoq_quic_roundtrip_court.exs
  → 121/124; 3 failures = 1 lane-fixed (iovec :empty_body re-pin → now green)
    + 2 PRE-EXISTING environmental (aoq_quic_roundtrip_court CERTS ARM legs
    require /tmp/lane4-certs from lane L4, absent; loud assert, not mine)
test/smalt/aoq/{tables,session,listener,transport,rdf_projector_court}_tests
  → 29 passed
```

## Verification ladder / standing

- ALIVE: framing court 24/24, drift court 5/5 (incl. 4 anti-vacuity
  mutations flipping RED), cross-repo court 4/4, rotate test 5/5, iovec 4/4,
  tables/session/listener/transport/rdf 29/29 — all run this session,
  command+exit above.
- BLOCKED-environmental (fleet incident 22:47, acknowledged; three
  bounded retries, no kill/re-spawn loops): the cgap fixture-court re-run
  AFTER the header.rs prose edit could not complete this session. Chain
  of witnesses: (1) sampled fresh test binary parked at `_dyld_start`
  (syspolicyd stall signature); (2) post-all-clear retries blocked on the
  shared cgap build-dir lock held continuously by sibling lanes' resumed
  gates (waited 10+10+7 min windows). The FIRST standalone run of the
  fixture court (pre-prose-edit) passed 1/1 this session; the edit is
  doc-comment only and cannot change behavior. Close condition: run
  `cargo test -p cgap-aoq --test aoq_v3_golden_bytes_fixture` + `--test
  aoq1_codec_court` + `--test aoq1_layout_drift_court` when the cgap
  build-dir lock drains.
- PARTIAL: the pre-existing committed E0004 in
  `crates/cgap-aoq/tests/cbmqs_runner.rs:518` (KemShapeMismatch variant
  added to error.rs without covering the match) blocks a full `cargo
  test -p cgap-aoq`; not my file, disclosed for the owner lane.
- BLOCKED-none. REFUSED-none. Session-introduced failures: none remaining
  (the iovec refusal-token failure was introduced by my rename and fixed
  this session).

## Falsifiers

- Drift court anti-vacuity legs (mutated TTL copies MUST flip RED).
- Framing court FNV mutate law: every raw flip in [0,60) → :bad_digest
  (60 individual flips asserted).
- Cross-repo court: a v2-era codec against the v3 wire would fail leg 1
  (magic "1QOA" + version 3 pin).

## Disclosures

- Compile-freeze windows: shared smalt build was twice blocked by SIBLING
  lanes' in-flight files (smalt_lakehouse_mount.erl fb_gate/5, ~22:14;
  arrow/flatbuf.ex __STACKTRACE__, ~22:30) — not my files; I resumed when
  owners landed. My own frame.ex had a guard compile error at 22:04
  (witnessed by the census) — fixed and compile-green verified after.
- `test/smalt/aoq` sweep: session/listener/transport tests consume only the
  compat `Frame.encode/2` surface (unchanged) — no edits needed beyond
  iovec; disclosed rather than churned.
- cargo lock contention with sibling lanes on cgap-aoq targets; my
  fixture-court re-verify is queued (UNVERIFIED above).
