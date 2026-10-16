/**
 * Argmax policy extraction + deterministic replay for the Dynamic Bellman
 * Solver. All values are fixed-point integers (SCALE = 10_000) produced by
 * `solve`; this module performs no float arithmetic on them.
 */
import type { BellmanProblem, BellmanSolution } from "./bellman";
import { IDLE_ACTION_ID } from "./bellman";

/** A decoded action choice at one decision point. */
export interface PolicyStep {
  /** Asset index. */
  readonly asset: number;
  /** Asset id. */
  readonly assetId: string;
  /** Window index within the asset's horizon. */
  readonly window: number;
  /** Chosen action index into the window's action array (idle = actions.length). */
  readonly actionIndex: number;
  /** Action id (idle = IDLE_ACTION_ID). */
  readonly actionId: string;
  /** Budget remaining AFTER the action's costs are charged (fixed-point). */
  readonly budgetAfter: number;
  /** Fixed-point Q value of the chosen action at the decision point. */
  readonly qValue: number;
}

/**
 * Extract the greedy policy path from a solved problem, starting at
 * (asset, window 0, budget = initialBudget) and replaying forward.
 * Deterministic: follows the recorded argmax action at every step.
 *
 * Complexity: O(H) time, O(H) output space.
 */
export function extractPolicyPath(
  problem: BellmanProblem,
  solution: BellmanSolution,
  asset: number,
): PolicyStep[] {
  const { horizon, initialBudget: B } = problem;
  const steps: PolicyStep[] = [];
  let budget = B;

  for (let t = 0; t < horizon; t++) {
    const acts = problem.windows[asset][t].actions;
    const idx = solution.policy[asset][t][budget];
    const isIdle = idx === acts.length;
    const act = isIdle ? undefined : acts[idx];
    const spent = act ? act.batteryCost + act.thermalCost : 0;
    steps.push({
      asset,
      assetId: problem.assets[asset],
      window: t,
      actionIndex: idx,
      actionId: act ? act.id : IDLE_ACTION_ID,
      budgetAfter: budget - spent,
      qValue: solution.value[asset][t][budget],
    });
    budget -= spent;
  }
  return steps;
}
