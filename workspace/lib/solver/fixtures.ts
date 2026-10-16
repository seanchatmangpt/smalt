/**
 * Deterministic 3-satellite x 4-window mission fixture for the Dynamic
 * Bellman Solver. Seeded RNG (mulberry32) — every run is byte-identical.
 * All rewards/costs are fixed-point integers (SCALE = 10_000).
 */
import type { BellmanProblem, OrbitalWindow, SensorAction } from "./bellman";
import { SCALE } from "./bellman";

/** Deterministic 32-bit PRNG (mulberry32). Returns uint32 per call. */
export function mulberry32(seed: number): () => number {
  let a = seed >>> 0;
  return function () {
    a = (a + 0x6d2b79f5) | 0;
    let t = Math.imul(a ^ (a >>> 15), 1 | a);
    t = (t + Math.imul(t ^ (t >>> 7), 61 | t)) ^ t;
    return (t ^ (t >>> 16)) >>> 0;
  };
}

/** Scale a float ratio (0..1) to fixed-point, round-half-up (deterministic). */
function toFixed(ratio: number): number {
  return Math.round(ratio * SCALE);
}

/** Fixture parameters. */
export interface FixtureOptions {
  /** PRNG seed. Default 20261015. */
  seed?: number;
  /** Satellite count. Default 3. */
  satellites?: number;
  /** Orbital windows (horizon). Default 4. */
  windows?: number;
  /** Initial budget per satellite, fixed-point. Default 6.0. */
  initialBudget?: number;
}

/** Build the deterministic 3-satellite x 4-window mission problem. */
export function buildMissionFixture(opts: FixtureOptions = {}): BellmanProblem {
  const seed = opts.seed ?? 20261015;
  const S = opts.satellites ?? 3;
  const H = opts.windows ?? 4;
  const B = opts.initialBudget ?? 6 * SCALE;

  const rand = mulberry32(seed);
  const assets: string[] = [];
  const windows: OrbitalWindow[][] = [];

  // Two sensors per window: "wide" (cheap, low value) and "narrow" (costly, high value).
  const sensors = [
    { id: "wide", rBase: 1.5, cBase: 1.0 },
    { id: "narrow", rBase: 3.0, cBase: 2.0 },
  ] as const;

  for (let s = 0; s < S; s++) {
    assets.push(`sat-${s}`);
    const perAsset: OrbitalWindow[] = [];
    for (let t = 0; t < H; t++) {
      const actions: SensorAction[] = [];
      for (const sensor of sensors) {
        // Per-(satellite, window, sensor) seeded jitter in [-0.5, 0.5) on the
        // base reward; costs stay at base (integer grid preserved via round).
        const jitter = (rand() / 4294967296 - 0.5) * 1.0;
        const reward = toFixed(sensor.rBase + jitter);
        const cost = toFixed(sensor.cBase);
        actions.push({ id: `${sensor.id}-s${s}-t${t}`, reward, batteryCost: cost, thermalCost: 0 });
      }
      perAsset.push({ index: t, asset: `sat-${s}`, actions });
    }
    windows.push(perAsset);
  }
  return { assets, windows, initialBudget: B, horizon: H };
}
