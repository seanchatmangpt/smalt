#!/usr/bin/env node
// Event Hubs SDK smoke runner (lane 14). Boot the smalt substrate, then run
// eventhubs.test.cjs against the AMQP 5673 lane. Own pid management (detached
// process group, kill group, escalate to SIGKILL), independent of census-run.
// Exit codes: 0 all probes pass / 1 probe failure / 2 substrate never came up /
// 3 harness failure (ports occupied, spawn error).
import { spawn } from "node:child_process";
import net from "node:net";
import fs from "node:fs";
import path from "node:path";
import { randomBytes } from "node:crypto";
import { fileURLToPath } from "node:url";

const REPO = "/Users/sac/smalt";
const HERE = path.dirname(fileURLToPath(import.meta.url));
const LOG_DIR = path.join(HERE, ".logs");
const AMQP_PORT = Number(process.env.SMALT_EH_AMQP_PORT || 15672);
const EH_PORT = Number(process.env.SMALT_EH_PORT || 15673);
const ARM_PORT = Number(process.env.SMALT_EH_ARM_PORT || 19443);
const EGRESS_PORT = Number(process.env.SMALT_EH_EGRESS_PORT || 18443);
const ARM_TLS_PORT = Number(process.env.SMALT_EH_ARM_TLS_PORT || 19444);
const POLL_DEADLINE_MS = 60_000;

const log = (...a) => console.log("[eh-run]", ...a);

function tryConnect(port) {
  return new Promise((resolve) => {
    const s = net.connect({ host: "127.0.0.1", port, timeout: 1500 });
    s.once("connect", () => { s.destroy(); resolve(true); });
    s.once("timeout", () => { s.destroy(); resolve(false); });
    s.once("error", () => resolve(false));
  });
}

async function checkFree(port) {
  return !(await tryConnect(port));
}

async function main() {
  fs.mkdirSync(LOG_DIR, { recursive: true });

  // 1. Ports must be free before boot.
  for (const port of [AMQP_PORT, EH_PORT, ARM_PORT, EGRESS_PORT, ARM_TLS_PORT]) {
    if (!(await checkFree(port))) {
      console.error(
        `[eh-run] port ${port} is occupied. Remediation: ` +
        `lsof -ti tcp:${port} | xargs kill -9`,
      );
      process.exitCode = 3;
      return;
    }
  }

  // Fixed shared key so the SAS the SDK computes matches the broker verifier.
  const sharedKey = randomBytes(48).toString("base64");

  // 2. Spawn substrate: mix run --no-halt in the repo, MIX_ENV=test. The
  // default substrate ports (5672/5673/9443) may be held by another lane's
  // census substrate, so this runner pins its own alternate ports via app env.
  const logPath = path.join(LOG_DIR, "eh-substrate.log");
  const logStream = fs.createWriteStream(logPath, { flags: "w" });
  const child = spawn("mix", [
    "run", "--no-start", "--no-halt",
    "-e",
    `Application.put_env(:smalt, :sb_shared_key, "${sharedKey}"); ` +
      `Application.put_env(:smalt, :amqp_port, ${AMQP_PORT}); ` +
      `Application.put_env(:smalt, :event_hubs_port, ${EH_PORT}); ` +
      `Application.put_env(:smalt, :arm_port, ${ARM_PORT}); ` +
      `Application.put_env(:smalt, :egress_port, ${EGRESS_PORT}); ` +
      `Application.put_env(:smalt, :arm_tls_port, ${ARM_TLS_PORT}); ` +
      `{:ok, _} = Application.ensure_all_started(:smalt)`,
  ], {
    cwd: REPO,
    env: { ...process.env, MIX_ENV: "test" },
    stdio: ["ignore", "pipe", "pipe"],
    detached: true, // own process group so the beam child dies with mix
  });
  child.stdout.pipe(logStream);
  child.stderr.pipe(logStream);

  const killSubstrate = async (signal = "SIGTERM") => {
    try {
      if (child.pid && child.exitCode === null && !child.killed) {
        try {
          process.kill(-child.pid, signal);
        } catch {
          child.kill(signal);
        }
      }
    } catch { /* already gone */ }
    if (signal !== "SIGKILL") {
      const deadline = Date.now() + 5000;
      while (child.exitCode === null && Date.now() < deadline) {
        await new Promise((r) => setTimeout(r, 200));
      }
      if (child.exitCode === null) await killSubstrate("SIGKILL");
    } else {
      await new Promise((resolve) => child.once("close", resolve));
    }
  };
  for (const sig of ["SIGINT", "SIGTERM", "SIGHUP"]) {
    process.on(sig, () => { killSubstrate("SIGKILL"); process.exit(130); });
  }
  process.on("exit", () => { try { if (child.pid && child.exitCode === null) process.kill(-child.pid, "SIGKILL"); } catch {} });

  // 3. Poll TCP until all five listeners accept.
  const start = Date.now();
  for (;;) {
    const [amqp, eh, arm] = await Promise.all([
      tryConnect(AMQP_PORT),
      tryConnect(EH_PORT),
      tryConnect(ARM_PORT),
    ]);
    if (amqp && eh && arm) break;
    if (Date.now() - start > POLL_DEADLINE_MS) {
      console.error(
        `[eh-run] substrate did not open ${AMQP_PORT}/${EH_PORT}/${ARM_PORT} within ` +
        `${POLL_DEADLINE_MS / 1000}s. Substrate log: ${logPath}`,
      );
      await killSubstrate("SIGKILL");
      process.exitCode = 2;
      return;
    }
    await new Promise((r) => setTimeout(r, 500));
  }
  log(`substrate up on ${AMQP_PORT}/${EH_PORT}/${ARM_PORT} after ${Date.now() - start}ms`);

  // 4. Run the event hubs smoke. Propagate the exit code.
  const testRun = spawn("node", ["--test", "test/sdk-smoke/eventhubs.test.cjs"], {
    cwd: REPO,
    env: {
      ...process.env,
      SMALT_SB_SHARED_KEY: sharedKey,
      SMALT_EH_PORT: String(EH_PORT),
      SMALT_SDK_ROOT:
        process.env.SMALT_SDK_ROOT ||
        "/Users/sac/cai/athena/playground/node_modules",
    },
    stdio: "inherit",
  });
  const code = await new Promise((resolve) => testRun.once("close", resolve));
  process.exitCode = code === 0 ? 0 : 1;
  await killSubstrate("SIGTERM");
}

main().catch((err) => {
  console.error("[eh-run] harness error:", err);
  process.exitCode = 3;
});
