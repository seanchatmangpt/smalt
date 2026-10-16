# Receipt: x3-receipts-relocation (lane X-3)

- **Date**: 2026-10-15
- **Subject**: `/Users/sac/smalt` @ `518b31a54ccc0829cafb9e04538714e58c287a30` (main), working tree.
- **Lane**: X-3 — misplaced-receipt drift fix: relocate repo-root `receipts/` bench
  receipts into `docs/jira/v26.10.14/receipts/`, fix forward the cause, fix the
  lib.sh cd-before-mkdir ordering bug, re-run receipt index + naming sweep.

## Moved (5 files, no name collisions — target had no bench-02/05/07/08/09)

- `receipts/bench-02-blob-ts.md`
- `receipts/bench-05-python-mirror.md`
- `receipts/bench-07-store-beam.md`
- `receipts/bench-08-amqp-beam.md`
- `receipts/bench-09-eh-beam.md`

Root `receipts/` removed (`rmdir` succeeded — was empty after moves).

## Root cause (why lanes wrote to repo-root receipts/)

Dispatch prompts for the bench lanes gave the receipt path as a bare relative
`receipts/`, which resolves against each lane's cwd (repo root) instead of the
jira receipts dir. The moved receipts themselves cite correct absolute
`docs/jira/v26.10.14/bench/*.jsonl` paths for results, so the drift was
receipt-path-only. **Fix forward**: `scripts/bench/lib.sh` now defines
`RECEIPTS_DIR` (absolute, `${RECEIPTS_DIR:-$BENCH_REPO/docs/jira/v26.10.14/receipts}`)
with a comment directing future lanes to `"$RECEIPTS_DIR/<lane-receipt>.md"`.
Dispatch prompts should use `$RECEIPTS_DIR` (or the absolute path) going forward.

## lib.sh cd-before-mkdir fix (B-5 disclosed workaround now unnecessary)

`bench_boot` computed the substrate log path with `cd "$(dirname "$log")"`
BEFORE `mkdir -p "$(dirname "$log")"` — the `cd` fails on a fresh tree
(docs/tmp/ absent), which is why B-5 had to pre-create docs/tmp/ manually.
Reordered: mkdir first, then the cd/pwd normalization. `bash -n` clean.

## Receipt index (witnessed)

`just receipt-index` → `receipts=91 sdk=15 total=106 suspects=7`
wrote `docs/jira/v26.10.14/RECEIPTS.md` + `receipts/INDEX.md`.
Suspects (standing UNKNOWN/UNSUPPORTED, pre-existing, not this lane's scope):
06-blob-x-ms-date-unvalidated, bench-02-blob-ts, bench-05-python-mirror,
bench-07-store-beam, bench-08-amqp-beam, bench-12-consolidation, fin-04-gitignore.

## Naming sweep (witnessed)

`bash scripts/naming_sweep.sh` → **FAIL: 17 violations / 52 allowed — pre-existing,
NOT session-introduced.** Zero of the 17 hits involve the moved receipts or any
file this lane touched; the sweep already excludes `docs/jira/*/receipts/`
(2026-10-15, lane X-4), so the relocated receipts are inside the exclusion.
Two of the 17 sit in `smalt-cli/docs/jira/v26.10.14/receipts/` (cli-02-ledger),
which the exclusion regex `docs/jira/[^/]+/receipts/` does not cover — noted as
a pre-existing gap for the sweep owner, not extended here (no new violations
from receipt content = no exclusion change warranted per task scope).
No commits (per task).

## Verification commands

- `for f in ...; mv receipts/$f.md docs/jira/v26.10.14/receipts/; done` — 5 moved, 0 collisions
- `rmdir receipts` — succeeded
- `bash -n scripts/bench/lib.sh` — ok
- `just receipt-index` — receipts=91 sdk=15 total=106
- `bash scripts/naming_sweep.sh` — exit 1, 17 pre-existing violations

Standing: ALIVE (all transitions executed on the exact subject).
