// run-all.mjs — SDK-smoke tier aggregator.
//
// Runs the tier in sequence: run.mjs -> census-run.mjs -> eh-run.mjs.
// Each runner owns its substrate lifecycle (spawns mix, kills it on exit),
// so this aggregator only serializes them and waits for the shared hardcoded
// ports (5672/9443/8443) to be released between runners. eh-run uses its own
// SMALT_EH_* ports (15672+) so it cannot collide with the others.
//
// Exit codes: 0 = all runners passed, 1 = >=1 runner failed, 2 = usage error,
// 3 = harness error. Per-runner exit codes are propagated in the receipt.
//
// Usage: node test/sdk-smoke/run-all.mjs [--quick]
//   --quick: only run.mjs.
import { spawn } from "node:child_process";
import net from "node:net";
import path from "node:path";
import { fileURLToPath } from "node:url";

const HERE = path.dirname(fileURLToPath(import.meta.url));
const REPO = process.env.SMALT_REPO || path.resolve(HERE, "../..");

// Ports the non-env-aware runners bind (run.mjs: 9443/8443/5672,
// census-run.mjs: 5672/9443). These are hardcoded there, so the aggregator
// can only wait for them to be free — not shift them.
const SHARED_PORTS = [5672, 9443, 8443];
const PORT_FREE_TIMEOUT_MS = 30_000;

const RUNNERS = [
  { name: "run", script: "run.mjs" },
  { name: "census", script: "census-run.mjs" },
  { name: "eventhubs", script: "eh-run.mjs" },
];

const log = (msg) => console.log(`[run-all] ${msg}`);

function tryConnect(port, timeout = 1500) {
  return new Promise((resolve) => {
    const s = net.connect({ host: "127.0.0.1", port, timeout });
    s.once("connect", () => { s.destroy(); resolve(true); });
    s.once("error", () => resolve(false));
    s.once("timeout", () => { s.destroy(); resolve(false); });
  });
}

async function waitPortsFree(ports, label) {
  const deadline = Date.now() + PORT_FREE_TIMEOUT_MS;
  for (const port of ports) {
    for (;;) {
      if (!(await tryConnect(port, 500))) break;
      if (Date.now() > deadline) {
        log(`WARNING: port ${port} still occupied before ${label}; ` +
            `runner will fail with its own typed port error`);
        return;
      }
      await new Promise((r) => setTimeout(r, 500));
    }
  }
  log(`ports free for ${label}`);
}

function runRunner(script, args = []) {
  return new Promise((resolve) => {
    const child = spawn("node", [path.join(HERE, script), ...args], {
      cwd: REPO,
      env: process.env,
      stdio: "inherit",
    });
    child.once("close", (code) => resolve(code === null ? 1 : code));
    child.once("error", () => resolve(1));
  });
}

async function main() {
  const quick = process.argv.includes("--quick");
  const runners = quick ? RUNNERS.slice(0, 1) : RUNNERS;
  if (process.argv.length > 2 && !process.argv.slice(2).every((a) => a === "--quick")) {
    console.error(`[run-all] unknown args: ${process.argv.slice(2).join(" ")}`);
    process.exitCode = 2;
    return;
  }

  log(`tier start (runners: ${runners.map((r) => r.name).join(", ")})`);
  const results = [];
  for (const runner of runners) {
    await waitPortsFree(SHARED_PORTS, runner.name);
    log(`>>> ${runner.name} (${runner.script}) starting`);
    const started = Date.now();
    const exit = await runRunner(runner.script);
    const ms = Date.now() - started;
    results.push({ name: runner.name, exit, pass: exit === 0, ms });
    log(`<<< ${runner.name} exit=${exit} (${ms}ms)`);
  }

  // Aggregate receipt.
  console.log("\n[run-all] ================= SDK-SMOKE TIER RECEIPT =================");
  for (const r of results) {
    console.log(
      `[run-all] ${r.name.padEnd(12)} exit=${String(r.exit).padEnd(3)} ` +
      `${r.pass ? "PASS" : "FAIL"} (${(r.ms / 1000).toFixed(1)}s)`,
    );
  }
  const allPass = results.length > 0 && results.every((r) => r.pass);
  console.log(`[run-all] overall: ${allPass ? "PASS" : "FAIL"} ` +
      `(${results.filter((r) => r.pass).length}/${results.length} runners passed)`);
  process.exitCode = allPass ? 0 : 1;
}

main().catch((err) => {
  console.error("[run-all] harness error:", err);
  process.exitCode = 3;
});
