# i29 — validate_burn.py standing derivation fix (fail-closed)

**Standing: ALIVE** — fix landed, non-vacuity fixture passes, real-data proof on
both sides (dirty cgroup file now refuses; clean 8x4 gate files stay ALIVE).
Context: pair(bench-runner lane, scripts/validate_burn.py + receipt only; no lib/ edits).

## Defect (named in azb-18-cgroup-soak.md)

`scripts/validate_burn.py` accepted a run_receipt `standing: ALIVE` derived from
the replay command exit alone, even when every plane row was
`clean:false / UNHANDLED_EXIT` (cgroup-20261019T061643Z).

## Fix

`scripts/validate_burn.py`:

- New `derive_standing(rows)`: all rows `clean:true` and `verdict:"CLEAN"` =>
  `ALIVE`; any non-clean row => `PARTIAL_ALIVE` with the failing rows named
  (container/cycle/stage/verdict/broken_term); no rows => `UNKNOWN`.
- The validator re-derives standing from the plane rows and REFUSES
  (`STANDING_REFUSED`, exit 1) an ALIVE claim over dirty rows, or an ALIVE
  claim with zero burn rows. The derived standing is always printed
  (`derived_standing=...`).
- New `--self-check` non-vacuity fixture: a clean 2-row run derives ALIVE with
  0 errors; the same file mutated so one row carries `clean:false /
  UNHANDLED_EXIT / mu_unlawful / exit 137` derives PARTIAL_ALIVE and the ALIVE
  claim is refused. A gate that accepts the mutation exits 1 as
  `self-check FAILED — mutated observation did not flip the standing (vacuous gate)`.
  Self-check fixtures skip receipt-schema validation (synthetic receipts do not
  carry the full DfCM required fields; `check_receipt=False` on that path only).
- Docstring documents the standing law (azb-18 named defect).

## Non-vacuity (actual output)

```
$ python3 scripts/validate_burn.py --self-check
[VALIDATE-BURN] self-check clean: derived=ALIVE errors=0
[VALIDATE-BURN] self-check dirty: derived=PARTIAL_ALIVE refused=True failing=container=smalt-self-control cycle=1 stage=soak verdict=UNHANDLED_EXIT broken_term=mu_unlawful
[VALIDATE-BURN] self-check PASS
```

## Real-data proof — dirty file now refused

```
$ python3 scripts/validate_burn.py docs/jira/v26.10.18/burn/cgroup-20261019T061643Z.jsonl
[VALIDATE-BURN] .../cgroup-20261019T061643Z.jsonl: derived_standing=PARTIAL_ALIVE failing_rows=[container=smalt-soak-control cycle=1 stage=soak verdict=UNHANDLED_EXIT broken_term=mu_unlawful; container=smalt-soak-data ... ; container=smalt-soak-integration ...; container=smalt-soak-identity ...]
[VALIDATE-BURN] .../cgroup-20261019T061643Z.jsonl: line 1: not valid JSON: Illegal trailing comma before end of array: line 1 column 181 (char 180)
[VALIDATE-BURN] .../cgroup-20261019T061643Z.jsonl: STANDING_REFUSED: ALIVE claimed over dirty rows (derived standing PARTIAL_ALIVE); failing rows: ...
exit=1
```

The re-derived standing is now PARTIAL_ALIVE (non-ALIVE) over the four dirty
rows, matching the azb-18 prose standing. Pre-existing, disclosed: line 1 of
the cgroup file (its run_header) has a trailing comma and was already invalid
JSON before this change.

## Real-data proof — clean gate files stay ALIVE

```
$ for f in docs/jira/v26.10.18/burn/parallel-matrix-8x4-*.jsonl; do
    python3 scripts/validate_burn.py "$f" | tail -2; echo exit=$?
  done
parallel-matrix-8x4-1792388329.jsonl: derived_standing=ALIVE / OK   exit=0
parallel-matrix-8x4-1792388827.jsonl: derived_standing=ALIVE / OK   exit=0
parallel-matrix-8x4-1792389235.jsonl: derived_standing=ALIVE / OK   exit=0
```

`--gate` on 1792389235 also exit 0 (64 CLEAN rows, matrix covered, standing ALIVE).

## Replay

```bash
python3 scripts/validate_burn.py --self-check                       # exit 0
python3 scripts/validate_burn.py docs/jira/v26.10.18/burn/cgroup-20261019T061643Z.jsonl   # exit 1, STANDING_REFUSED, derived PARTIAL_ALIVE
python3 scripts/validate_burn.py docs/jira/v26.10.18/burn/parallel-matrix-8x4-1792389235.jsonl  # exit 0, ALIVE
```

## Falsifier status

- azb-18 non-vacuity falsifier ("a shim with one clean:false row must flip the
  standing"): CLOSED — `--self-check` dirty case flips to PARTIAL_ALIVE + STANDING_REFUSED.
- No regressions: all three clean 8x4 gate files remain exit 0 / ALIVE.
