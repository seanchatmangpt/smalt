# fin-01 — Register MISSING SDK_MATRIX cells in KNOWN_DIVERGENCES

- Date: 2026-10-15
- Repo: /Users/sac/smalt @ main (3fc2543), v26.10.14
- Lane: fin-01 (DoD-only finish lane; no commits, no lib edits)
- Task: append MISSING-cell KD rows (KD-36..KD-43) from DoD-14's SDK_MATRIX, rerun
  `scripts/sdk_coverage.py`, witness exit.

## Changes

1. `docs/jira/v26.10.14/KNOWN_DIVERGENCES.md` — appended rows KD-36..KD-43
   (7 probe-cell registrations + KD-36, see divergence note below). Each row:
   id / surface / divergence / evidence `SDK_MATRIX.md` / close condition
   "probe authoring (next window)" / status OPEN. Also KD-44 (below).
2. `scripts/sdk_coverage.py` — MINIMAL registration-side data change:
   - `missing_kd` map added to SURFACES entries (cosmos removed later, see below;
     eventgrid→KD-39, sentinel→KD-37, resource-graph→KD-38, purview-atlas→KD-40/41,
     ledger→KD-42/43);
   - main loop: a MISSING probe/receipt cell with a `missing_kd` entry becomes
     `MISSING-REGISTERED[<KD>]` and emits no finding. Unregistered MISSING still
     fails (exit 1). No probe/lib code touched.

## Concurrency event (same tree, mid-window)

- A sibling lane landed `sdk-results/ts-cosmos.md` (TS-3, 17/20 PASS, 3 divergences)
  and edited the cosmos SURFACES entry to cite it while this lane was running.
- Consequence: cosmos/ts flipped MISSING → UNREGISTERED-GAP. Response:
  - KD-36 was re-pointed from "no TS cosmos cell" to the actual first divergence
    (upsert-of-existing 409 vs 200 replace), evidence `ts-cosmos.md` (probe 9).
  - KD-44 minted for the second divergence (items.bulk pk-mismatch 400, probes 16-17).
  - cosmos `missing_kd` mapping dropped; cosmos/ts now REGISTERED-DIVERGENCE
    [KD-36, KD-44] from the receipt citation alone.
- Census line in KNOWN_DIVERGENCES.md: sibling lanes added KD-45..KD-51 and keep the
  register count current (51 rows at last run); this lane does not own that line.

## Final compiler run (witnessed)

```
python3 scripts/sdk_coverage.py
...
MISSING=0 UNREGISTERED-GAP=0 REGISTERED-DIVERGENCE=13
EXIT=0
```

- Cells: eventgrid/sentinel/resource-graph TS + purview-atlas/ledger both-language
  cells now MISSING-REGISTERED[KD-37..KD-43] per KD id; cosmos TS REGISTERED-DIVERGENCE
  [KD-36, KD-44]; servicebus census CRC OK (11 claimed = 11 registered + 3 supplementary).
- Exit code 0 (was 1 at baseline).

## Standing

PARTIAL_ALIVE — the register rows are doc truth keyed to the compiler; MISSING cells
are registered, not closed (probe authoring deferred to next window). KD-36/44 are
wire-evidenced (ts-cosmos.md, reproduced 4/4 and 3/3 runs) and remain OPEN until the
upsert flag and bulk wire shape are honored, falsifiers re-run.
