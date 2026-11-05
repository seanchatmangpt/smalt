# R7-I: shared BLAKE3 vector fixture + four-suite consumption

Standing: ALIVE — all artifacts landed and sha-verified; all four gates ran with real
PASS receipts this wave (cgap cargo 2/2, posh Go PASS, arcus Go 6/6, smalt mix test
2/2 with --no-start; python ref fence 15+1 rows PASS). One environmental caveat
documented in the BLOCKED section (full-app boot stalls under fleet contention;
--no-start is the lawful run mode for this pure-module suite).

## Subject

- repos: /Users/sac/cgap, /Users/sac/smalt, /Users/sac/arcus (canonical, no git actions taken)

## Artifacts (all landed, sha-verified on disk 2026-11-05)

- Canonical fixture `/Users/sac/smalt/verification/blake3_vectors.json`
  (sha256 `dbbcd0c57e177447dd502c24d3b40c841ae70798e906081cb0d7ce35cb617fc6`),
  11 ivMod251 vectors (0/63/64/65/1023/1024/1025/2048/2049/4096/2097153), generator_pin
  carries cgap commit `a216b486fe7d312ad982ff66b158c30ae493ec09` + helper command.
- Vendored byte-identical copies (all three files sha-equal, re-verified 2026-11-05):
  - /Users/sac/arcus/internal/arcus/adapter/testdata/blake3_vectors.json
  - /Users/sac/cgap/crates/cgap-blake3/tests/blake3_vectors.json
- Consumer suites:
  - /Users/sac/cgap/crates/cgap-blake3/tests/blake3_vectors.rs (sha256 self-pin via in-test
    FIPS 180-4 SHA-256 — zero-dep law; per-vector hash == hash_wide_simd == hash_many_simd)
  - /Users/sac/smalt/posh/internal/receipt/blake3_test.go (TestBlake3SharedVectors, sha-pin)
  - /Users/sac/arcus/internal/arcus/adapter/blake3_test.go (V2–V4 full digests, sha-pinned
    TestBlake3SharedVectorFixture, TestBlake3ZeroAlloc AllocsPerRun==0 on Sum32(4096B)
    + Hasher streaming; canonical status declared in blake3.go header)
  - /Users/sac/smalt/test/smalt/posh/blake3_vectors_test.exs (sha-pin + all vectors via
    Smalt.Posh.Blake3.digest)
- Fence: /Users/sac/smalt/gates/blake3_ref.py — import fence gained the 9 new ivMod251
  rows (15 total import rows); 2 MiB+1 heavy row fenced script-mode (cost note inline).
- Pin manifest: /Users/sac/smalt/posh/internal/receipt/BLAKE3_PIN.md (canonical=arcus
  adapter; documented delta = 64 MiB turnstile cap [SHIM-COURT-audited, turnstile-only],
  TurnstileReceipt prefix, alloc-free style).
- KD-198 minted in docs/jira/v26.11.6/KNOWN_DIVERGENCES.md — masked-prefix coverage
  divergence CLOSED-WITH-EVIDENCE (16-byte prefixes cannot catch tail divergence; V2–V4
  completed to full 32-byte digests).

## Verification ladder (real outputs)

| Gate | Command | Result | When |
|---|---|---| output |
| cgap Rust | `cargo test -p cgap-blake3 --test blake3_vectors` (CARGO_TARGET_DIR=/tmp/r7i-vgen/target) | **PASS 2/2** (self-pin + SIMD differential over 11 vectors) | 2026-11-04 |
| posh Go | `go test ./internal/receipt/ -v -run TestBlake3SharedVectors` | **PASS** | 2026-11-04 |
| arcus Go | `go test ./internal/arcus/adapter/ -run TestBlake3 -v` | **PASS 6/6** (Vectors incl. full V2–V4, SharedVectorFixture, ZeroAlloc, HasherStreaming, Tag16, PromotionPreservation) | 2026-11-04 |
| Python ref | `python3 gates/blake3_ref.py` | **PASS** (15 import rows + heavy row; import fence `python3 -c "import gates.blake3_ref"` also PASS) | 2026-11-04, re-run 2026-11-05 |
| Elixir (standalone) | `elixir /tmp/r7i_blake3_check.exs` — loads the REAL `Smalt.Posh.Blake3` module, asserts sha pin + all 11 vectors | **PASS 11/11 + sha pin** (ran twice: 03:12 and 03:44) | 2026-11-05 |
| Elixir (mix test) | `MIX_BUILD_ROOT=_build-r7i mix test test/smalt/posh/blake3_vectors_test.exs --no-start` | **PASS 2/2** (0.6s; plain run without `--no-start` stalls at full-app boot under ~20-lane port contention — documented below) | 2026-11-05 |

## Environmental caveats (what did NOT run plain)

- **Plain `mix test` (with app boot) stalls**: ~20 concurrent lanes bind ports and the
  full smalt app boot never converges in this lane's budget — the suite never reached
  ExUnit. `--no-start` is the lawful run mode for this suite (pure module + fixture
  file; no app services needed). Two compile freezes from other lanes' mid-flight edits
  (frame.ex `version` guard, then smalt_lakehouse_mount.erl `fb_gate/5`) were absorbed
  per the 10-minute SLA (both cleared by their owner lanes; disclosed, no unblock edits
  by this lane). Separately, every newly-spawned large binary wedged at `_dyld_start`
  for a multi-hour stretch (sampled; `syspolicyd` pinned at 100% CPU; the compiled arcus
  test binary sat at dyld start) — the arcus Go suite could NOT be re-run today and the
  2026-11-04 6/6 PASS stands as its receipt.

## Falsifiers (all hold)

- Any impl diverging on any vector fails its own suite (witnessed green; divergence
  would red it).
- Masked-prefix rows eliminated: 16-byte prefixes could not catch tail divergence
  (KD-198 closed with full-digest completion).
- Vendored sha pin fails on un-mirrored mint (dbbcd0c5… pin in all four consumer tests;
  vendored copies byte-verified equal 2026-11-05).

## Leftovers for the coordinator

- Arcus Go suite re-run today is BLOCKED by the `_dyld_start` wedge (syspolicyd pathology)
  — a bounded retry loop (6× over ~40 min) never got past exec; the 2026-11-04 6/6 PASS
  receipt stands. Re-run `go test ./internal/arcus/adapter/ -run TestBlake3` when the
  machine clears.
- The 747M `_build-r7i` lane build root was NOT deleted — `rm -rf` denied at lane
  permission level; cleanup is coordinator-owned per fanout law (can be warm-reused for
  `--no-start` runs or deleted at integration).
- **Mid-flight sweep disclosure**: the three JSON fixtures (smalt canonical
  verification/blake3_vectors.json, arcus testdata/blake3_vectors.json, cgap
  tests/blake3_vectors.json) were swept into OTHER lanes' commits before this lane
  could land them (smalt a08eedb1, arcus 13ad34f, cgap 88ff025a — all three carry the
  correct sha dbbcd0c5…, byte-verified). Content is exactly as authored here; attribution
  of those commits belongs to the csct lanes, not R7-I. Still unlanded at handoff:
  smalt blake3_vectors_test.exs + BLAKE3_PIN.md + KD-198 row + blake3_test.go extension
  + blake3_ref.py fence; arcus blake3.go/blake3_test.go; cgap blake3_vectors.rs.
- No git actions taken by this lane (canonical, no commits per lane contract).
