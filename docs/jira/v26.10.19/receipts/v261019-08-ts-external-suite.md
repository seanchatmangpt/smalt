# Receipt — V261019-08 (ts-external-suite)

Context: solo(V261019-08) — census commands executed in this lane, 2026-10-19 ~10:10 PDT.
Standing: **PARTIAL / IN-FLIGHT** — the suite surface exists on disk
(`verification/ts/`: wf1..wf5 + harness) but the suite has NOT landed: no
lane receipt exists for a full green run, and the portable-target gate
currently exits 1 against the tree (output below, honest failure).
Base: 64f6099663a4ec32fd9478c4c39fca49ab1961f8 (shared checkout, 143 dirty paths)
Date: 2026-10-19

## What changed

- The external TypeScript suite moved from the old plan's `workspace/test/`
  to `verification/ts/` per the clean-room reset. On disk right now:
  `wf1/`–`wf5/`, `harness/`, `package.json`, `package-lock.json`,
  `node_modules/` (installed), `verification/README.md` documents the
  contract (boot via `mix run --no-start --no-halt`, no `lib/smalt` refs).
- Runner: `node --test` surface (`node:test` / `node:assert` are the only
  allowed test surface per `scripts/portable_target_gate.py`).
- No suite-owned fixes landed in this lane's file set; no `lib/` or
  `workspace/` edit disclosed by this receipt.

## Verification (real output tails)

```
$ find verification/ts -name "*.test.*" -not -path "*/node_modules/*" | wc -l
0
```

```
$ python3 scripts/portable_target_gate.py; echo "exit=$?"
[first lines]
/Users/sac/smalt/verification/ts/node_modules/which-typed-array/index.js:6: disallowed import: call-bound
...
[112 violation lines total; includes HARD violations in
 verification/ts/node_modules/wsl-utils/* and doc-text false positives in
 verification/README.md / verification/py/.venv]
exit=1
```

The portable gate's exit 1 is honest RED: the scanner currently descends
into `verification/ts/node_modules/` and `.venv` (third-party transitive
deps, not lane-authored code) and flags README prose. The suite owner must
either add scanner exclusions for installed third-party trees or pin
deps to clean versions before the suite can close green.

```
$ node --test verification/ts/     # NOT EXECUTED
```

Not run: the suite owner's WO-08, not this receipt lane; a full run without
scanner exclusions would be measuring the gate RED, not the suite.

## Acceptance greps

- `grep -rn "node:test" verification/ts --include="*.ts" -l | wc -l` — not
  migrated: zero `.test.ts` leaves exist yet (census above).
- `grep -n "test" verification/ts/package.json` — not censused by this lane
  (deferred to the suite owner).

## Deviations

1. Skeleton assumed `workspace/test/*.test.ts` leaves; the reset moved the
   external suite to `verification/ts/` with wf1..wf5 + harness layout.
   Recorded here as a measured deviation, not argued.
2. Standing is PARTIAL/IN-FLIGHT, not LANDED: no executed `node --test`
   run exists on the tree this session; the portable gate is RED (exit 1).
