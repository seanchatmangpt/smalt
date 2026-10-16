# Dynamic Bellman Solver (WS-7)

Finite-horizon MDP value iteration over a reachability DAG for sensor-tasking
scheduling.

- `bellman.ts` — exact backward-induction solver. States =
  {asset, orbital-window, resource-budget}; actions = sensor tasking choices
  with battery/thermal costs; rewards = coverage value.
- `policy.ts` — argmax policy extraction (`extractPolicyPath`) + forward
  replay from initial budget.
- `fixtures.ts` — deterministic 3-satellite x 4-window mission with a seeded
  mulberry32 RNG.

## Contract

```ts
solve(problem: BellmanProblem): BellmanSolution
// BellmanSolution = { value, policy, stats }
```

- `value[asset][window][budget]` — optimal fixed-point value; terminal slice
  (window == horizon) is all zeros.
- `policy[asset][window][budget]` — argmax action index; idle =
  `actions.length`; terminal slice is `-1`.
- `stats` — `statesEvaluated`, `backups`, `horizon`, `stateSpace`, `elapsedMs`.

## Determinism

- ALL value/cost arithmetic is fixed-point integer with `SCALE = 10_000`;
  zero floats in the math path.
- Tie-break: strict `>` scan in declared action order, idle first — lowest
  action index wins ties.
- Fixture RNG is seeded (mulberry32); identical seed => identical problem,
  value, and policy across runs and platforms.

## Complexity

- `solve`: time O(A * H * (B+1) * (K+1)) with A assets, H windows, budgets
  0..B, K actions per window; space O(A * (H+1) * (B+1)) for full tables.
- `extractPolicyPath`: O(H) time.

## Verification

`sanity.mjs` compiles the TS in-memory (typescript API) and asserts: exact
fixed-point values on a hand-computed case, tie-break to lowest index, and
two full runs (fresh `solve` + fixture rebuild) produce identical
value/policy JSON.
