#!/usr/bin/env node
// Service Bus SDK census runner (lane 15). Boot the smalt substrate, then run
// census.test.cjs against it. Exit codes: 0 all probes pass / 1 census failure
// / 2 substrate never came up / 3 harness failure (ports occupied, spawn error).
import { spawn } from "node:child_process";
import net from "node:net";
import fs from "node:fs";
import path from "node:path";
import { randomBytes } from "node:crypto";
import { fileURLToPath } from "node:url";

const REPO = process.env.SMALT_REPO || process.cwd();
const HERE = path.dirname(fileURLToPath(import.meta.url));
const LOG_DIR = path.join(HERE, ".logs");
// Port check must match the ports the substrate will actually bind. The
// sb_census_replay.sh front door exports SMALT_TEST_*; when unset, defaults
// are the front-door ports (unchanged behavior). For a private-port census
// run, export SMALT_TEST_AMQP_PORT/SMALT_TEST_ARM_PORT from the documented
// private range 39000-39999 (docs/DEV_LOOP.md "Private port allocation").
const AMQP_PORT = Number(process.env.SMALT_TEST_AMQP_PORT || 5672);
const ARM_PORT = Number(process.env.SMALT_TEST_ARM_PORT || 9443);
const POLL_DEADLINE_MS = 60_000;

const log = (...a) => console.log("[census-run]", ...a);

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
  for (const port of [AMQP_PORT, ARM_PORT]) {
    if (!(await checkFree(port))) {
      console.error(
        `[census-run] port ${port} is occupied. Do NOT kill the holder (it may ` +
        `be another lane's live substrate). Either wait for it to exit, or run ` +
        `a private-port census: export SMALT_TEST_AMQP_PORT / ` +
        `SMALT_TEST_ARM_PORT from the private range 39000-39999 ` +
        `(docs/DEV_LOOP.md "Private port allocation") and rerun.`,
      );
      process.exitCode = 3;
      return;
    }
  }

  // Fixed shared key so the SAS the SDK computes matches the broker verifier.
  // Injected via mix run -e (Application env, before any CBS verify).
  const sharedKey = randomBytes(48).toString("base64");

  // 2. Spawn substrate: mix run --no-halt in the repo, MIX_ENV=test.
  const logPath = path.join(LOG_DIR, "census-substrate.log");
  const logStream = fs.createWriteStream(logPath, { flags: "w" });
  const child = spawn("mix", [
    "run", "--no-halt",
    "-e", `Application.put_env(:smalt, :auth_mode, :anonymous); Application.put_env(:smalt, :sb_shared_key, "${sharedKey}"); Application.put_env(:smalt, :sb_endpoint, "sb://127.0.0.1:${AMQP_PORT}")`,
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
      // Escalate if the group does not die within 5s.
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

  // 3. Poll TCP 5672 + 9443 until both accept.
  const start = Date.now();
  for (;;) {
    const [amqp, arm] = await Promise.all([
      tryConnect(AMQP_PORT),
      tryConnect(ARM_PORT),
    ]);
    if (amqp && arm) break;
    if (Date.now() - start > POLL_DEADLINE_MS) {
      console.error(
        `[census-run] substrate did not open ${AMQP_PORT}/${ARM_PORT} within ` +
        `${POLL_DEADLINE_MS / 1000}s. Substrate log: ${logPath}`,
      );
      await killSubstrate("SIGKILL");
      process.exitCode = 2;
      return;
    }
    await new Promise((r) => setTimeout(r, 500));
  }
  log(`substrate up on ${AMQP_PORT}/${ARM_PORT} after ${Date.now() - start}ms`);

  // 4. Run the census. Propagate the exit code.
  const testRun = spawn("node", ["--test", "test/sdk-smoke/census.test.cjs"], {
    cwd: REPO,
    env: {
      ...process.env,
      SMALT_SB_SHARED_KEY: sharedKey,
      // Derive the census connection string from the substrate's actual AMQP
      // port: without this the probes default to 5672 and fail ECONNREFUSED
      // on any private-port census run (c3 witnessed: substrate up on 39172,
      // all 8 probes refused on 5672 in <10ms each).
      SMALT_SB_CONNECTION_STRING:
        process.env.SMALT_SB_CONNECTION_STRING ||
        `Endpoint=sb://127.0.0.1:${AMQP_PORT};SharedAccessKeyName=RootManageSharedAccessKey;SharedAccessKey=${sharedKey};UseDevelopmentEmulator=true`,
    },
    stdio: "inherit",
  });
  const code = await new Promise((resolve) => testRun.once("close", resolve));
  process.exitCode = code === 0 ? 0 : 1;
  await killSubstrate("SIGTERM");
}

main().catch((err) => {
  console.error("[census-run] harness error:", err);
  process.exitCode = 3;
});
