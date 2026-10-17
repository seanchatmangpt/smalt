# v26.10.17 Work Orders — Lane Partition

Release: v26.10.17 · Base: main @ 650a8ff + in-flight working tree. Modeled on the
v26.10.16 exemplar (`docs/jira/v26.10.16/_LANES.md`). This window is the W2b
generator-surgery wrap wave: I1's generator landing is already on the tree
(483eee3 / d615661 / 650a8ff); the remaining lanes receipt, flip, and freeze.

## Coordination rules (verbatim from the wave dispatch)

- **One writer per lane; coordinator owns git.** Writers never run git state
  commands — no worktrees, no shadow clones; one canonical checkout per repo.
  The only git transitions this window (two `git mv`s for the window rotation)
  belong to lane I9 alone; every other lane is git-free.
- **`mix.exs` was P1/I1's lease** (generator surgery) and is LANDED at
  483eee3 (smalt.gen task-ification) + d615661 (manifest + receipt ledger) +
  650a8ff (spc-bands regen). No other lane edits `mix.exs` until WO-4's
  version-bump window opens STRICTLY after WO-2 two-green.
- **`CLAUDE.md` + `scripts/naming_sweep.sh` + the affidavit move = I9** only.
- **`docs/jira/v26.10.17/` is split I14 + I19**: I14 owns window COUNTERS
  (counts/ledger files); I19 owns the scaffolding (`_LANES.md`,
  `WORK_ORDERS.md`, `NEXT_WINDOW.md`). Receipt files live under
  `receipts/` and are owned by their producing lanes.
- **`kd_flip.py --apply` is coordinator-only at wave end.** Lanes may run the
  read-only mode; no lane flips KD rows or GAP tokens by hand.
- **No new `lib/` edits after I3's witness receipts without re-witnessing.**
  Once I3 takes witness receipts, any subsequent `lib/` change invalidates the
  witness and its lane must re-witness before flips can reference it.
- **Compile-freeze SLA** (same-checkout-fanout rule 2/6): a lane edit that
  breaks the shared compile is fixed or reverted by its owner within ~10
  minutes; any lane may apply a minimal unblock fix to another lane's
  non-compiling file, disclosing it in BOTH lanes' receipts.
- **Lane builds**: `MIX_BUILD_ROOT=_build-lane<N>` per lane; coordinator
  deletes all lane build roots at integration before the final commit
  (`just lane-clean`). No lane writes outside its lease.
- **Shared seams** are recorded in `RESOLUTIONS.md` (authored at first seam).

## Lane table (I1-I20)

| Lane | File lease(s) | Status |
|---|---|---|
| I1 | `mix.exs`, `lib/mix/tasks/smalt.gen.ex`, ggen_igniter manifest + receipt ledger | LANDED — 483eee3 / d615661 / 650a8ff |
| I2 | `docs/jira/v26.10.17/receipts/*` (standing-line receipts for landed work) | OPEN |
| I3 | KD witness receipts; read-only `scripts/kd_flip.py` runs (no `--apply`) | OPEN |
| I4 | `docs/WIRE_PARITY.md` GAP token flips — receipt-gated only, coordinator applies | OPEN |
| I5 | compliance docs (`NOTICE.md`, `PUBLISH_RECORD.md` carry-forward checks) | OPEN |
| I6 | `lib/smalt/messaging/` AMQP surface + its tests | OPEN |
| I7 | `workspace/` Next.js console (ESLint/e2e-court scope) | OPEN |
| I8 | `scripts/substrate.sh`, `justfile.d/*substrate*`, substrate tests | OPEN |
| I9 | `CLAUDE.md`, `scripts/naming_sweep.sh`, window `git mv`s (v26.10.17 rotation) | OPEN |
| I10 | SDK census probes (`test/sdk-smoke/`, `scripts/sdk_coverage.py` consumers) | OPEN |
| I11 | `smalt-cli/` pytest surface | OPEN |
| I12 | `gates/` invariant gates + negative fixtures | OPEN |
| I13 | ERROR_CODES extractor fix (`scripts/gen_error_codes.py`) — WRAP_LEDGER parked item | OPEN |
| I14 | window COUNTERS (count/ledger artifacts in `docs/jira/v26.10.17/`) | OPEN |
| I15 | `lib/smalt/mcp/` gen/templates (`generated/` rides ggen sync, never hand-edited) | OPEN |
| I16 | `lib/smalt/data_plane/` + `lib/smalt/registry.ex` consumers (registry regen only) | OPEN |
| I17 | `scripts/bench/` lanes + `bench/` jsonl + `BENCH_RESULTS.md` regen input | OPEN |
| I18 | `test/` additions/repairs not owned by I6/I7/I10/I11/I12 | OPEN |
| I19 | window scaffolding: `_LANES.md`, `WORK_ORDERS.md`, `NEXT_WINDOW.md` stub → full mint at wrap | ACTIVE (this file) |
| I20 | freeze: court-x2 coordination, generated-artifact regen sweep, FINAL.md/RECEIPTS.md | OPEN |

## Dependency order

I1 (done) → I3 witnesses → I2/I4 flips (receipt-gated) → parallel surface
lanes I5-I18 within their leases → I9 rotation mvs → I20 court-x2 + fin-sweep
regen → WO-4 version bump (STRICTLY after WO-2 two-green) → I14 counters →
I19 NEXT_WINDOW full mint → wrap.
