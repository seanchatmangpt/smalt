# S-6 Receipt: shim-court harness (generalization of mutation_court.py)

- Subject: `/Users/sac/smalt` @ main (518b31a working tree)
- Lane: S-6, generalization lane. No commits (per dispatch).
- Date: 2026-10-15

## Landed (all executed this session)

| Artifact | Purpose |
|---|---|
| `scripts/shim_court/lib.sh` | Reusable protocol: `with_shim <file> <before-cmd> <after-cmd>` — BASELINE (sha256), BEFORE (old signature), SHIM (caller `apply_shim`, `SHIM-COURT` marker enforced), AFTER (new outcome), RESTORE (sha256 byte-exact, fail-closed). Typed `[FAIL:PHASE]` lines. `shim_court_skip` = loud skip, exit 3, never a faked pass. `shim_court_self_check` proves the restore-detection rule on a real temp copy. |
| `justfile.d/18-shim-court.just` | `shim-court <name>` (dispatch + available-court listing, rc=2 on unknown), `shim-courts` aggregate (PASS/FAIL/SKIP/BLOCKED summary, exits 1 iff any FAIL). |
| `Justfile` | Import line appended after 15-bench (verified in place at line 229). |
| `scripts/shim_court/README.md` | Contract doc: BEFORE/AFTER/restore contract, sha256 rule, SKIP-loud-with-reason allowance. |

## Harness verification (real runs, /tmp subjects)

- PASS path: BASELINE → BEFORE → SHIM → AFTER → RESTORE all green, subject sha256 after == baseline (`d9531d42…`), rc=0.
- Vacuous/AFTER-fail path: `[FAIL:AFTER]`, rc=1, subject restored and intact (`grep -c OLD-GATE` = 1).
- `shim_court_self_check`: clean restore verifies, corrupted restore detected.
- Skip path: `[SKIP] … env missing`, rc=3.
- `just shim-court nosuch`: lists `amqp_framing`, rc=2.

## Aggregate witness (`just shim-courts`)

At receipt time exactly **1** sibling court existed: `amqp_framing_court.sh`
(+ its `amqp_witness.py`). Aggregate result:

```
== shim-courts aggregate: 1 court(s) ==
  -> amqp_framing: BLOCKED (rc=137)
== summary: 0 PASS, 0 FAIL, 1 SKIP ==
```

`amqp_framing` killed its own process group at its 75s witness timeout
(the KD-49 pyamqp-hang signature its script documents). The harness
classified it SKIP/BLOCKED, exited 0 (zero FAILs).

## Post-run residue check

- `grep -rl SHIM-COURT lib/` → no matches (clean; no shim residue).
- `connection.ex` currently differs from HEAD (+33/−2) but carries **no**
  SHIM-COURT marker — that is sibling lanes' concurrent edit, not court
  residue. Court baseline it printed (85c5fa30…) was of the already
  sibling-modified working-tree file.

## Pending (did not exist when S-6 finished)

- S-1..S-5 courts other than `amqp_framing`: not yet landed. Aggregate is
  re-runnable via `just shim-courts` as they arrive.

## Falsifiers (unchecked here, run by each court)

- A court passes while its subject never flips → harness reports FAIL
  (witnessed: bad_court AFTER-fail run).
- Restore not byte-exact → `[FAIL:RESTORE]` (witnessed: self-check
  corruption detection).
- SKIP without reason → the typed `[SKIP] <court>: <reason>` line is
  mandatory by construction.
