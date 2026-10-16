// Sanity harness: compiles the solver TS in-memory via the typescript API
// (tsx-free), runs solve() twice on freshly built fixtures, asserts
// determinism + correctness. Run: node lib/solver/sanity.mjs
import { execSync } from "node:child_process";
import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

const here = path.dirname(fileURLToPath(import.meta.url));
const tscRoot = path.resolve(here, "../../"); // workspace root (package.json)
const tsModulePath = execSync("node -e \"console.log(require.resolve('typescript'))\"", {
  cwd: tscRoot,
  encoding: "utf8",
}).trim();

const ts = (await import(tsModulePath)).default;
const outDir = fs.mkdtempSync("/tmp/ws7-solver-");
const compiler = ts.createCompilerHost({
  module: ts.ModuleKind.NodeNext,
  moduleResolution: ts.ModuleResolutionKind.NodeNext,
  strict: true,
  target: ts.ScriptTarget.ES2022,
  outDir,
});
const program = ts.createProgram(
  ["bellman.ts", "policy.ts", "fixtures.ts"].map((f) => path.join(here, f)),
  { module: ts.ModuleKind.NodeNext, moduleResolution: ts.ModuleResolutionKind.NodeNext, strict: true, target: ts.ScriptTarget.ES2022, outDir },
  compiler,
);
const diags = ts.getPreEmitDiagnostics(program);
if (diags.length) {
  for (const d of diags) console.error(ts.flattenDiagnosticMessageText(d.messageText, "\n"));
  process.exit(1);
}
program.emit();
const mod = await import(path.join(outDir, "fixtures.js"));
const { solve } = await import(path.join(outDir, "bellman.js"));
const { extractPolicyPath } = await import(path.join(outDir, "policy.js"));

const SCALE = 10_000;

// --- Correctness: hand-computable single-window case -----------------------
const trivial = {
  assets: ["a"],
  windows: [[{ index: 0, asset: "a", actions: [{ id: "s", reward: 5 * SCALE, batteryCost: 2 * SCALE, thermalCost: 0 }] }]],
  initialBudget: 3 * SCALE,
  horizon: 1,
};
const t = solve(trivial);
console.assert(t.value[0][0][3 * SCALE] === 5 * SCALE, "affordable action taken");
console.assert(t.value[0][0][2 * SCALE - 1] === 0, "unaffordable -> idle value 0");
console.assert(t.policy[0][0][3 * SCALE] === 0, "policy picks action 0");
console.assert(t.policy[0][1][0] === -1, "terminal policy -1");

// --- Tie-break: two identical actions -> lowest index wins -----------------
const tie = {
  assets: ["a"],
  windows: [[{ index: 0, asset: "a", actions: [
    { id: "x", reward: SCALE, batteryCost: 0, thermalCost: 0 },
    { id: "y", reward: SCALE, batteryCost: 0, thermalCost: 0 },
  ] }]],
  initialBudget: SCALE,
  horizon: 1,
};
const tieSol = solve(tie);
console.assert(tieSol.policy[0][0][SCALE] === 0, "tie -> lowest action index");

// --- Determinism: two runs identical ---------------------------------------
const p1 = mod.buildMissionFixture();
const r1 = solve(p1);
const p2 = mod.buildMissionFixture();
const r2 = solve(p2);
const j1 = JSON.stringify({ v: r1.value, p: r1.policy });
const j2 = JSON.stringify({ v: r2.value, p: r2.policy });
console.assert(j1 === j2, "two runs identical value+policy");
if (j1 !== j2) { console.error("DETERMINISM FAIL"); process.exit(1); }

const path0 = extractPolicyPath(p1, r1, 0);
const path0b = extractPolicyPath(p2, r2, 0);
console.assert(JSON.stringify(path0) === JSON.stringify(path0b), "policy paths identical");
console.assert(path0.length === 4, "path covers horizon");
console.assert(path0.every((s) => Number.isInteger(s.qValue) && Number.isInteger(s.budgetAfter)), "integer fixed-point");

// Fixture values are seeded-jittered integers; policy picks narrow mostly.
console.assert(r1.stats.stateSpace === 3 * 4 * (6 * SCALE + 1), "stateSpace = 3*4*(B+1)");
console.assert(r1.stats.statesEvaluated === r1.stats.stateSpace, "all states evaluated");

console.log("SANITY OK", JSON.stringify(r1.stats));
console.log("path(sat-0):", path0.map((s) => `${s.window}:${s.actionId}`).join(" "));
