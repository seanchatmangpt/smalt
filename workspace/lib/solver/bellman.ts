/**
 * Dynamic Bellman Solver — finite-horizon MDP value iteration (exact backward
 * induction) over a reachability DAG.
 *
 * State:  { asset, orbital-window index, resource-budget }
 * Action: sensor-tasking choice (a sensor observation or idle) with
 *         battery/thermal costs charged against the budget.
 * Reward: coverage value of the tasked action, minus costs.
 *
 * ALL arithmetic is in fixed-point scaled integers (SCALE = 10_000): rewards,
 * costs, and values are integer scaled units. Zero floats in the math path —
 * output is bit-for-bit deterministic across runs and platforms.
 *
 * Tie-breaking: strict `>` over fixed-point Q values, iterating actions in
 * declared order (idle evaluated first), so the LOWEST action index wins ties.
 *
 * Complexity (per asset, A assets, H windows, budgets 0..B, |acts| actions/window):
 *   time  = O(A * H * (B+1) * (|acts|+1))
 *   space = O(A * (H+1) * (B+1)) for the full value/policy tables.
 */

/** Fixed-point scale: 10_000 units per "1.0". All math operates on this grid. */
export const SCALE = 10_000;

/** A sensor-tasking action available to an asset in a given window. */
export interface SensorAction {
  /** Stable action id. Tie-breaking is by array index, not by this id. */
  readonly id: string;
  /** Coverage reward if taken, in fixed-point units (SCALE = 1.0). */
  readonly reward: number;
  /** Battery cost charged against remaining budget, in fixed-point units. */
  readonly batteryCost: number;
  /** Thermal cost charged against remaining budget, in fixed-point units. */
  readonly thermalCost: number;
}

/** One orbital window for one asset, with its action list in priority order. */
export interface OrbitalWindow {
  /** Window index within the asset's horizon (0-based). */
  readonly index: number;
  /** Asset id this window belongs to. */
  readonly asset: string;
  /** Actions available in this window, in deterministic priority order. */
  readonly actions: readonly SensorAction[];
}

/** A fully specified finite-horizon reachability-DAG MDP problem. */
export interface BellmanProblem {
  /** Asset ids, ordered (deterministic). */
  readonly assets: readonly string[];
  /** Per-asset window lists, each in horizon order, indices 0..horizon-1. */
  readonly windows: ReadonlyArray<readonly OrbitalWindow[]>;
  /** Initial resource budget per asset, in fixed-point units. */
  readonly initialBudget: number;
  /** Horizon length (windows per asset). */
  readonly horizon: number;
}

/** Solver statistics — integer fields only except elapsedMs (stats, not math). */
export interface SolverStats {
  /** Number of (asset, window, budget) states evaluated. */
  readonly statesEvaluated: number;
  /** Number of (state, action) backups computed. */
  readonly backups: number;
  /** Horizon length. */
  readonly horizon: number;
  /** Total state-space size = assets * horizon * (budget+1). */
  readonly stateSpace: number;
  /** Wall-clock milliseconds. Never feeds values. */
  readonly elapsedMs: number;
}

/** Solver output: value function, argmax policy, and stats. */
export interface BellmanSolution {
  /**
   * value[assetIndex][window][budget] = optimal fixed-point value.
   * At window == horizon: terminal, value 0.
   * Index space: windows 0..H, budget 0..initialBudget.
   */
  readonly value: number[][][];
  /**
   * policy[assetIndex][window][budget] = chosen action index into the window's
   * action array. Idle = actions.length (always the highest index, evaluated
   * first). At window == horizon: -1 (terminal).
   */
  readonly policy: number[][][];
  readonly stats: SolverStats;
}

/** Idle action id. Idle is always feasible: zero reward, zero cost. */
export const IDLE_ACTION_ID = "__idle__";

/**
 * Solve the finite-horizon MDP exactly by backward induction.
 *
 * Pure function: no I/O, no globals, no randomness. `elapsedMs` uses
 * Date.now() for stats only and never enters the value path.
 */
export function solve(problem: BellmanProblem): BellmanSolution {
  const { assets, windows, initialBudget: B, horizon } = problem;
  const nAssets = assets.length;

  const value: number[][][] = [];
  const policy: number[][][] = [];

  let statesEvaluated = 0;
  let backups = 0;
  const t0 = Date.now();

  for (let a = 0; a < nAssets; a++) {
    const windowsA = windows[a];
    const valueA: number[][] = new Array(horizon + 1);
    const policyA: number[][] = new Array(horizon + 1);

    // Terminal slice.
    valueA[horizon] = new Array<number>(B + 1).fill(0);
    policyA[horizon] = new Array<number>(B + 1).fill(-1);

    for (let t = horizon - 1; t >= 0; t--) {
      const acts = windowsA[t].actions;
      const vT: number[] = new Array<number>(B + 1);
      const pT: number[] = new Array<number>(B + 1);

      for (let b = 0; b <= B; b++) {
        // Idle first (index = acts.length): reward 0, cost 0, stays at budget b.
        backups++;
        let best = valueA[t + 1][b];
        let bestIdx = acts.length;

        for (let i = 0; i < acts.length; i++) {
          const spent = acts[i].batteryCost + acts[i].thermalCost;
          if (spent > b) continue; // unaffordable at this budget
          backups++;
          const q = acts[i].reward + valueA[t + 1][b - spent];
          if (q > best) {
            best = q;
            bestIdx = i;
          }
        }

        vT[b] = best;
        pT[b] = bestIdx;
        statesEvaluated++;
      }
      valueA[t] = vT;
      policyA[t] = pT;
    }

    value.push(valueA);
    policy.push(policyA);
  }

  return {
    value,
    policy,
    stats: {
      statesEvaluated,
      backups,
      horizon,
      stateSpace: nAssets * horizon * (B + 1),
      elapsedMs: Date.now() - t0,
    },
  };
}
