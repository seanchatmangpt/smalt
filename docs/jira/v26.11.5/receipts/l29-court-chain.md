# L29 — AoQ fences wired into the full court (spec §3/§4)

Standing: PARTIAL_ALIVE

## Scope / diff

- `justfile.d/63-aoq.just` (NEW): `aoq-fence` (runs LANE-13
  `scripts/aoq_egress_fence.sh`, fail-closed) + `aoq-court-stage` (shim
  court, receipts under `tmp/aoq-court/`). `AOQ_ROOT := justfile_directory()`
  — NOTE: `parent_directory(justfile_directory())` in an IMPORTED module
  resolves to the parent of the ROOT justfile dir (`/Users/sac`), which is
  the defect currently breaking `just bin-opt` / `just bin-opt-court`
  (rc=127) in `justfile.d/62-bin-opt.just`; not my lease (C1 in-flight),
  disclosed to coordinator.
- `Justfile`: ONE import line for 63-aoq + additive append on the shared
  `court:` seam — `bin-opt-court aoq-fence` (bin-opt-court words already
  present from L12/C1; I added only ` aoq-fence`). L24's 64-receipts import
  landed concurrently; no conflict.
- `scripts/shim_court/aoq_fence_court.sh` (NEW): non-vacuity court per
  `scripts/shim_court/lib.sh`. SCRATCH scope only: materializes
  `tmp/aoq-court/shim/` with a fence COPY + `lib/smalt/aoq/fixture.ex`
  scratch fixture; the real fence scans dirname($0)/.., so lib/ is never
  read, written, or restored. BASELINE → BEFORE (fence CLEAN, exit 0) →
  SHIM (un-allowlisted `<>` egress appended, SHIM-COURT marker) → AFTER
  (fence must exit 1 with `VIOLATION ... fixture.ex`) → RESTORE (sha256
  byte-exact, fail-closed). Court receipt emitted under `tmp/aoq-court/`.

## Court verdicts (as-run 2026-11-04)

- `just aoq-court-stage` → **PASS, FLIPPED** (rc=0). Witness: fence exit 0
  CLEAN before shim; exit 1 `VIOLATION fixture.ex` after; restore
  byte-exact. Receipt `tmp/aoq-court/aoq_fence_court_20261104T173446.md`.
- `bash scripts/aoq_egress_fence.sh` → **rc=1, PRE-EXISTING RED**:
  `VIOLATION lib/smalt/aoq/frame.ex:126: def encode_frame(%__MODULE__{}, <<>>)`
  — the fence's `rg '<>'` matches the empty-binary pattern `<<>>` (a pattern
  match, not an egress append). Fence is LANE-13-labeled (not my lease) and
  `frame.ex` is not in my lease (L28 live) — coordinator/lane-13 to fix
  (word-boundary regex or allowlist comment). Until fixed, `just court` is
  RED through aoq-fence — loud, not silent.
- `just bin-opt-court` → **rc=127 PRE-EXISTING** (62-bin-opt.just
  `parent_directory` cwd defect, above). Direct run of
  `scripts/shim_court/bin_opt_gate_court.sh` → **FAIL:BEFORE** (gate not
  green on the unmodified tree) — pre-existing, C1 in-flight.
- `just court` full run NOT executed (heavy, multi-lane tree); the chain is
  wired by recipe dependency — `court: ... bin-opt-court aoq-fence`
  (Justfile, verified on disk) and `just --list` parses all recipes.

## Commands/exits

- `just aoq-court-stage` → 0
- `bash scripts/aoq_egress_fence.sh` → 1 (pre-existing violation)
- `just bin-opt-court` → 127 (pre-existing recipe defect)
- `just --list` → parses, aoq-fence + aoq-court-stage listed

## Standing

PARTIAL_ALIVE: my two stages land wired and the fence non-vacuity court
PASSES with a real flip; the court chain is currently RED through two
pre-existing defects outside my lease (fence `<<>>` false-positive at
frame.ex:126; 62-bin-opt cwd defect). No new regressions introduced.
