# AZB-03 — Burn JSONL receipt schema + validator

Standing: ALIVE
Context: script gates (validate_burn.py --gate over burn fixtures); no mix test invocation

Work order: AZB-03 (`docs/jira/v26.10.18/azsim-burn/TICKETS.md`). Lane foundry, Q CREATE, deps none.

## Consequence

- `docs/jira/v26.10.18/burn/burn-row.schema.json` — smalt-burn/v2 row schema:
  one row per (container, plane, cycle, stage); required fields `subject_sha`,
  `image_digest`, `container`, `plane`, `cycle`, `stage ∈ {boot,probe,chaos,
  recover,teardown,soak}`, `verdict ∈ {CLEAN,ORPHAN_LISTENER,ZOMBIE_BEAM,
  UNHANDLED_EXIT,DETS_UNREPAIRED,TYPED_VOCAB_MISMATCH,TIMEOUT_DEADLINE}`,
  `t_start`, `t_end`, `exit_code`, `orphans[]`, `crash_reports`, `evidence_path`,
  `broken_term` (null iff CLEAN, enforced by schema allOf both directions).
  Optional provenance extras (`lane`, `detail`, `recovery_ms`, `clean`, `tier`,
  `tests`, `failures`, `faces`, `flood_conns`, `hogs`, `note`) so the burn
  scripts can carry richer detail without a second format.
- `scripts/validate_burn.py` — fail-closed validator. `--gate` refuses (exit 1)
  on: row schema violation, missing `(container,cycle,stage)` cell vs the
  `run_header`-declared expected matrix (header is mandatory in gate mode — a
  dropped cycle is otherwise invisible, the AZB-03 falsifier), any non-CLEAN
  row, missing/invalid `run_receipt` (validated against
  `~/.zcode/dfcm/receipt.schema.json`). Exit 0/1, 2 usage/IO.
- Row emitters in `docker/burn/{chaos-kill,boot-burn,container-burn,soak}.sh`
  extended in place (call sites unchanged) to emit smalt-burn/v2 rows.
  Stage mapping: chaos-kill `gate-*`→probe else chaos; boot-burn
  `boot-probe`→probe, `kill9-recovery`→recover, `*shutdown*`→teardown; soak
  `offline`→probe, `wire`→soak; container-burn stage=probe cycle=0, legacy
  `clean` boolean kept so `parallel-matrix.sh`'s verdict parse is unchanged.
  Env knobs: `SMALT_BURN_SUBJECT_SHA`, `BURN_IMAGE_DIGEST`, `BURN_CONTAINER`,
  `SMALT_BURN_PLANE`; `unrecorded` fallback when the emitter cannot see git.
- Fixtures under `docs/jira/v26.10.18/burn/fixtures/` (clean, missing-cell,
  orphan, plus dropped-cycle falsifier fixture).
- `docs/jira/v26.10.18/burn/README.md` already documents the validator entry
  point.

## Replay

```
$ python3 scripts/validate_burn.py --gate docs/jira/v26.10.18/burn/fixtures/clean.jsonl; echo "exit=$?"
[VALIDATE-BURN] docs/jira/v26.10.18/burn/fixtures/clean.jsonl: OK
exit=0

$ python3 scripts/validate_burn.py --gate docs/jira/v26.10.18/burn/fixtures/missing-cell.jsonl; echo "exit=$?"
[VALIDATE-BURN] docs/jira/v26.10.18/burn/fixtures/missing-cell.jsonl: MISSING_CELL container=smalt-burn-all-2 cycle=1 stage=probe
exit=1

$ python3 scripts/validate_burn.py --gate docs/jira/v26.10.18/burn/fixtures/orphan.jsonl; echo "exit=$?"
[VALIDATE-BURN] docs/jira/v26.10.18/burn/fixtures/orphan.jsonl: DIRTY_ROW container=smalt-burn-all-1 cycle=0 stage=boot verdict=ORPHAN_LISTENER broken_term=mu_unlawful
exit=1

$ python3 scripts/validate_burn.py --gate docs/jira/v26.10.18/burn/fixtures/dropped-cycle.jsonl; echo "exit=$?"
[VALIDATE-BURN] docs/jira/v26.10.18/burn/fixtures/dropped-cycle.jsonl: MISSING_CELL container=smalt-burn-all-1 cycle=2 stage=boot
[VALIDATE-BURN] docs/jira/v26.10.18/burn/fixtures/dropped-cycle.jsonl: MISSING_CELL container=smalt-burn-all-1 cycle=2 stage=probe
[VALIDATE-BURN] docs/jira/v26.10.18/burn/fixtures/dropped-cycle.jsonl: MISSING_CELL container=smalt-burn-all-1 cycle=2 stage=teardown
[VALIDATE-BURN] docs/jira/v26.10.18/burn/fixtures/dropped-cycle.jsonl: MISSING_CELL container=smalt-burn-all-2 cycle=2 stage=boot
[VALIDATE-BURN] docs/jira/v26.10.18/burn/fixtures/dropped-cycle.jsonl: MISSING_CELL container=smalt-burn-all-2 cycle=2 stage=probe
[VALIDATE-BURN] docs/jira/v26.10.18/burn/fixtures/dropped-cycle.jsonl: MISSING_CELL container=smalt-burn-all-2 cycle=2 stage=teardown
exit=1

$ # Falsifier: a matrix with a dropped cycle passes --gate — REFUTED (exit 1 above).
$ # Anti-vacuity: delete one row from clean fixture:
$ python3 - <<'PY'
lines = open("docs/jira/v26.10.18/burn/fixtures/clean.jsonl").readlines()
del lines[4]
open("/tmp/clean-mutated.jsonl", "w").writelines(lines)
PY
$ python3 scripts/validate_burn.py --gate /tmp/clean-mutated.jsonl; echo "exit=$?"
[VALIDATE-BURN] /tmp/clean-mutated.jsonl: MISSING_CELL container=smalt-burn-all-1 cycle=0 stage=teardown
exit=1
```

Also witnessed: emitters exercised in isolation and their rows validated —
chaos-kill, boot-burn, container-burn, soak all `OK` (exit 0); `bash -n`
clean on all four scripts. Full in-image path simulated (run_header +
4 CLEAN rows + schema-valid run_receipt from `emit_run_receipt` with a
40-hex `SMALT_BURN_SUBJECT_SHA`): `python3 scripts/validate_burn.py --gate
/tmp/ck-full.jsonl` → `OK`, exit 0.

## Cross-lane unblock fixes (disclosed)

Applied minimal fixes to sibling-lane in-flight files per the compile-freeze
SLA, both disclosed here:

- `docker/burn/{chaos-kill,boot-burn}.sh`: the concurrent lane's
  `run_header` printf reads `$BURN_CONTAINER` before the emitter block
  defines it — under `set -euo pipefail` the script dies on the first line.
  Moved the `SUBJ_SHA/IMG_DIGEST/BURN_CONTAINER/BURN_PLANE` block above the
  header printf in both.
- `docker/Dockerfile`: added `ENV SMALT_BURN_SUBJECT_SHA=${SUBJECT_SHA}` so
  the container exports a 40-hex subject anchor (the runtime stage has no
  git; `emit_run_receipt`'s 40-hex guard would otherwise withhold the
  run_receipt and the gate would refuse the file).

## Standing derivation

ALIVE from replay.commands: all three Accept commands green (exit 0 / 1 / 1),
falsifier refuted (dropped cycle exits 1), anti-vacuity witnessed (row
deletion exits 1 with `MISSING_CELL container=… cycle=…`), receipt.schema.json
validation hook active in gate mode (clean fixture carries a schema-valid
`run_receipt`; a missing one fails the gate).

## Falsifiers

- A matrix with a dropped cycle passes `--gate` — refuted (dropped-cycle
  fixture exits 1, six MISSING_CELL lines).
- Gate admitting a non-CLEAN row — refuted (orphan fixture exits 1).
- Gate passing a receipt that violates `~/.zcode/dfcm/receipt.schema.json` —
  structurally refused (jsonschema Draft202012 against the v2 receipt schema);
  missing receipt fails the gate (R_missing_consequence).
