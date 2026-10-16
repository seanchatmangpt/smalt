# Receipt: fin-07 — TS cosmos probe cell registration (RAISE)

- date: 2026-10-15
- lane: fin-07 (DoD-only finish lane; no commits, no lib edits, no probe edits)
- subject: /Users/sac/smalt @ main 3fc2543 (dirty tree, in-flight v26.10.14 wave)

## What was done

TS-3's lane already authored and ran `test/sdk-full/cosmos.probe.mjs` (17/20 PASS,
3 divergences, exit 1 fail-closed) and filed
`docs/jira/v26.10.14/sdk-results/ts-cosmos.md` (mtime 2026-10-15 18:18). This
lane did not touch probe content.

Registration-side change only — `/Users/sac/smalt/scripts/sdk_coverage.py`,
SURFACES cosmos entry:

```python
# before
receipts=["py-cosmos.md"]),
# after
receipts=["py-cosmos.md", "ts-cosmos.md"]),
```

The filename matcher (`find_probe`) already recognized `cosmos.probe.mjs` via
the `ts=["cosmos"]` substring pattern; the MISSING verdict came from
`rcpt_name` being `None` (no TS receipt registered), so the minimal fix is
adding `ts-cosmos.md` to the receipts list. No pattern/matcher code changed.

## Witnessed result

`python3 scripts/sdk_coverage.py` (run twice, ~18:3x and ~18:40 local):

```
cosmos           ground=ok  TS=UNREGISTERED-GAP  PY=REGISTERED-DIVERGENCE[KD-06,KD-07,KD-08,KD-09]
FINDING: cosmos/ts: UNREGISTERED-GAP (receipt ts-cosmos.md records failures, no KD row cites it)
```

Totals flipped MISSING=8 -> 7; exit remains 1 (fail-closed, correctly surfacing
the gap). The cell is no longer MISSING — the probe and receipt are registered;
the receipt records 3 failures (rows 9, 16, 17 of ts-cosmos.md: upsert-of-
existing 409; bulk single-partition pk-mismatch; bulk cross-partition
pk-mismatch).

## Gap: KD registration pending (F-12's lane)

The task's expected REG-DIV[KD-06..09 + new TS divergences] is conditional on
F-12 registering the TS divergences in KNOWN_DIVERGENCES.md. As of this
receipt, no KD row's evidence column cites `sdk-results/ts-cosmos.md`
(KD-06..09 cite `py-cosmos.md` only; KD-36 — "no TS receipt filed" — is now
stale/landed since ts-cosmos.md exists and is registered). kd_for_receipt()
matches KD rows whose evidence names the receipt, so once F-12 lands KD rows
citing ts-cosmos.md, rerunning the script flips the cell to
REGISTERED-DIVERGENCE with no further script change. Not done by this lane to
avoid two lanes editing the same register (same-checkout fan-out: one owner per
file). Poll performed twice (~2 min apart): no F-12 rows landed during window.

## Falsifier

Revert the one-line receipts change and rerun: cosmos TS returns to MISSING
("MISSING receipt None"). Re-run after F-12's KD rows land: TS cell reads
REGISTERED-DIVERGENCE[...] without further edits.

## Standing

ALIVE (registration witnessed on real output). Residual: UNREGISTERED-GAP on
cosmos/ts pending F-12 KD registration — a correctly surfaced finding, not a
registration defect.
