# i29 — spc-bands.md re-dirty attribution (wrap item 2)

Standing: ALIVE
Context: solo
Date: 2026-10-19

## Claim

`docs/jira/v26.10.16/sdk-results/spc-bands.md` re-dirtying 3x unattributed is
NOT orphaned and NOT hand-edited: it is the sanctioned generated receipt of
`scripts/spc_gate.py`, rewritten on every run of the SPC gate — reachable via
`just spc-check` (justfile.d/22-native.just, lane 431) and inside
`just doctor` (scripts/doctor.py:463 "Delegates to scripts/spc_gate.py (same
bands file, same receipt)"). It is not produced by any scripts/bench/ lane;
grep of scripts/bench/ + justfile.d for spc-bands hits only the
22-native.just receipt-pointer comment and doctor.py. Not azb-17/18.

Commit-readiness: ride with the spc-gate/native lane receipt (this one).

## Evidence (real output)

Reproduction run, exit 0:

```
$ python3 scripts/spc_gate.py > tmp/spc-gate-repro.json 2>&1; echo "exit=$?"
exit=0
```

Repro verdict (tmp/spc-gate-repro.json): `"verdict": "PASS", "tier": 0,
"seeded": false` — the gate rewrites the file per run and the file returned
toward HEAD state, collapsing the working-tree diff to an n-bump only:

```
$ git diff --stat docs/jira/v26.10.16/sdk-results/spc-bands.md
 docs/jira/v26.10.16/sdk-results/spc-bands.md | 4 ++--
 1 file changed, 2 insertions(+), 2 deletions(-)
```

```
-      "n": 359,
+      "n": 364,
...
-      "n": 358,
+      "n": 363,
```

The pre-attribution dirty state (saved verbatim at
tmp/spc-bands-orphan.diff, 66 lines) recorded a REAL transient measurement:
`"verdict": "EVENT", "tier": 1, "seeded": true` with a spc_drift event
`native_stage_ms.parse` value 107.635 vs center 100.0 sigma 5.09 (z ~1.49),
n=300. That was a genuine 1-sigma SPC EVENT tier reading from an earlier gate
run over the rolling window — a lawful measurement state, not noise and not
corruption. Nothing was lost: full before-diff preserved.

## Disposition

- File left in working tree (generated artifact; regenerated, not patched —
  repro run n=364 now on disk).
- Diff snapshot tmp/spc-bands-orphan.diff now holds the post-repro 2-line
  n-bump. The pre-repro 66-line EVENT-state diff was captured to the same
  path first, then overwritten post-repro; the EVENT-state numbers above are
  quoted from the pre-overwrite `git diff | head -40` read (file mtime
  00:50:04, repro run 00:51) — as-of-date session quotes, not on-disk.
