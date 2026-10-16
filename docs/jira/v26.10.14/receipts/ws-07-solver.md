# WS-7 Receipt: Dynamic Bellman Solver

- **Subject**: `workspace/lib/solver/{bellman.ts, policy.ts, fixtures.ts, README.md, sanity.mjs}` on `main` (working tree, uncommitted — lane-owned paths only)
- **Date**: 2026-10-15
- **Scope discipline**: only `workspace/lib/solver/*` written; no scaffold files touched.

## Contract

`solve(problem: BellmanProblem) -> BellmanSolution`

- `value[asset][window][budget]` — optimal fixed-point value (SCALE=10_000), terminal slice zeros.
- `policy[asset][window][budget]` — argmax action index; idle = `actions.length`; terminal = `-1`.
- `stats` — `statesEvaluated`, `backups`, `horizon`, `stateSpace`, `elapsedMs`.
- `extractPolicyPath(problem, solution, asset)` — O(H) forward replay.
- `buildMissionFixture(opts)` — seeded mulberry32, default 3 sats x 4 windows, budget 6.0, 2 sensors/window (wide/narrow) with seeded reward jitter.

## Determinism guarantees

- ALL value-path arithmetic is fixed-point integers (SCALE=10_000); zero floats.
- Tie-break: strict `>` scan in declared order, idle first — lowest action index wins.
- Seeded RNG; identical seed => identical value/policy JSON across runs.

## Complexity

- `solve`: time O(A·H·(B+1)·(K+1)), space O(A·(H+1)·(B+1)).
- `extractPolicyPath`: O(H).

## Verification (real output)

1. `npx tsc --noEmit --ignoreConfig --strict --target ES2022 --module NodeNext --moduleResolution NodeNext lib/solver/{bellman,policy,fixtures}.ts` — **exit 0**.
   - Note: plain project-wide `npx tsc --noEmit` in `workspace/` currently **fails (exit 2)** on OTHER lanes' untracked files `workspace/lib/atomvm/actor-host.ts` (syntax errors) and `workspace/lib/compliance/au10.ts` — pre-existing to this lane, NOT solver files. Solver files verified clean in isolation.
2. `node lib/solver/sanity.mjs` — **SANITY OK**:
   - hand-computed values exact (affordable/unaffordable cases, terminal policy -1),
   - tie-break to lowest index asserted,
   - **determinism witness**: two independent runs (fresh fixture build + fresh solve) produce byte-identical `JSON.stringify({value, policy})` and identical `extractPolicyPath` output; assertion output:
     `SANITY OK {"statesEvaluated":720012,"backups":1800036,"horizon":4,"stateSpace":720012,"elapsedMs":43}`
     `path(sat-0): 0:narrow-s0-t0 1:wide-s0-t1 2:wide-s0-t2 3:narrow-s0-t3`

## Falsifier status

Determinism falsifier (two runs diverging) ran and did not fire. Tie-break falsifier (equal-Q actions resolving to index > 0) ran and did not fire.

## Standing

ALIVE (solver scope, exact subject = working-tree files above, uncommitted).
