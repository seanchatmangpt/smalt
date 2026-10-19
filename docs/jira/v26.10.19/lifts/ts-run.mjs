#!/usr/bin/env node
// ts-run.mjs — reality-grade TypeScript court harness for test/sdk-full.
//
// Boots the smalt substrate on its canonical ports (5672/5673/9443/8443/9444)
// with real TLS material from scripts/gen_dev_cert.sh, then runs
// ts-reality.test.mjs under `node --test` with NODE_EXTRA_CA_CERTS wired so
// the real Azure SDKs trust the dev CA. Real npm installs, real SDKs, real
// auth flows. Fail-closed exit codes:
//   0 all pass / 1 test failure (incl. documented SDK limitation) /
//   2 substrate never came up / 3 harness failure / 124 watchdog kill.
import { spawn } from "node:child_process";
import net from "node:net";
import fs from "node:fs";
import path from "node:path";
import { randomBytes } from "node:crypto";
import { fileURLToPath } from "node:url";

const REPO = process.env.SMALT_REPO || path.resolve(import.meta.dirname, "../..");
const HERE = import.meta.dirname;
const LOG_DIR = path.join(HERE, ".logs");
fs.mkdirSync(LOG_DIR, { recursive: true });

// Ports: env-overridable, canonical defaults.
const AMQP_PORT = Number(process.env.SMALT_TS_AMQP_PORT || 5672);
const EH_PORT = Number(process.env.SMALT_TS_EH_PORT || 5673);
const ARM_PORT = Number(process.env.SMALT_TS_ARM_PORT || 9443);
const EGRESS_PORT = Number(process.env.SMALT_TS_EGRESS_PORT || 8443);
const ARM_TLS_PORT = Number(process.env.SMALT_TS_ARM_TLS_PORT || 9444);
const POLL_DEADLINE_MS = 90_000;
const TEST_WATCHDOG_MS = Number(process.env.SMALT_TS_WATCHDOG_MS || 200_000);

// Fixed attestation measurement seeded into the substrate baseline via the
// boot eval. hex64 per Smalt.Security.Attestation.
export const MEASUREMENT =
  "11".repeat(32);

const CERT_DIR = process.env.SMALT_CERT_DIR || path.join(REPO, ".smalt/tls");
const CA_CERT = path.join(CERT_DIR, "ca-cert.pem");
const CERT_FILE = path.join(CERT_DIR, "dev-cert.pem");
const KEY_FILE = path.join(CERT_DIR, "dev-key.pem");

for (const f of [CA_CERT, CERT_FILE, KEY_FILE]) {
  if (!fs.existsSync(f)) {
    console.error(
      `[ts-run] missing ${f}. Run: bash scripts/gen_dev_cert.sh`,
    );
    process.exit(3);
  }
}

const log = (...a) => console.log("[ts-run]", ...a);

function tryConnect(port) {
  return new Promise((resolve) => {
    const s = net.connect({ host: "127.0.0.1", port, timeout: 1500 });
    s.once("connect", () => { s.destroy(); resolve(true); });
    s.once("timeout", () => { s.destroy(); resolve(false); });
    s.once("error", () => resolve(false));
  });
}

const checkFree = async (port) => !(await tryConnect(port));

async function main() {
  // 0. Fixed shared key so SDK-computed SAS matches the broker verifier
  // (mirrors eh-run.mjs).
  const sharedKey = randomBytes(48).toString("base64");

  // 1. Ports must be free before boot.
  const ports = [AMQP_PORT, EH_PORT, ARM_PORT, EGRESS_PORT, ARM_TLS_PORT];
  for (const port of ports) {
    if (!(await checkFree(port))) {
      console.error(
        `[ts-run] port ${port} is occupied. Remediation: lsof -ti tcp:${port} | xargs kill -9`,
      );
      process.exitCode = 3;
      return;
    }
  }

  // 2. Boot substrate with TLS twin enabled (SMALT_TLS_CERTFILE/KEYFILE) and
  // seed the MAA attestation baseline with our measurement via the boot eval.
  const bootEval = [
    `Application.put_env(:smalt, :sb_shared_key, "${sharedKey}")`,
    `Application.put_env(:smalt, :sb_endpoint, "sb://127.0.0.1:${AMQP_PORT}")`,
    `Application.put_env(:smalt, :amqp_port, ${AMQP_PORT})`,
    `Application.put_env(:smalt, :event_hubs_port, ${EH_PORT})`,
    `Application.put_env(:smalt, :arm_port, ${ARM_PORT})`,
    `Application.put_env(:smalt, :egress_port, ${EGRESS_PORT})`,
    `Application.put_env(:smalt, :arm_tls_port, ${ARM_TLS_PORT})`,
    `{:ok, _} = Application.ensure_all_started(:smalt)`,
    `Smalt.Store.put(:smalt_attestation_baseline, "${MEASUREMENT}", %{"measurement" => "${MEASUREMENT}"})`,
  ].join("; ");

  const logPath = path.join(LOG_DIR, "substrate.log");
  const logStream = fs.createWriteStream(logPath, { flags: "w" });
  const child = spawn("mix", ["run", "--no-start", "--no-halt", "-e", bootEval], {
    cwd: REPO,
    env: {
      ...process.env,
      MIX_ENV: "test",
      SMALT_TLS_CERTFILE: CERT_FILE,
      SMALT_TLS_KEYFILE: KEY_FILE,
    },
    stdio: ["ignore", "pipe", "pipe"],
    detached: true, // own process group so the beam dies with mix
  });
  child.stdout.pipe(logStream);
  child.stderr.pipe(logStream);

  const killSubstrate = async (signal = "SIGTERM") => {
    try {
      if (child.pid && child.exitCode === null && !child.killed) {
        try { process.kill(-child.pid, signal); } catch { child.kill(signal); }
      }
    } catch { /* gone */ }
    if (signal !== "SIGKILL") {
      const dl = Date.now() + 5000;
      while (child.exitCode === null && Date.now() < dl) {
        await new Promise((r) => setTimeout(r, 200));
      }
      if (child.exitCode === null) await killSubstrate("SIGKILL");
    } else {
      await new Promise((resolve) => {
        try { child.once("close", resolve); } catch { resolve(); }
        setTimeout(resolve, 5000);
      });
    }
  };
  for (const sig of ["SIGINT", "SIGTERM", "SIGHUP"]) {
    process.on(sig, () => { killSubstrate("SIGKILL"); process.exit(130); });
  }
  process.on("exit", () => {
    try { if (child.pid && child.exitCode === null) process.kill(-child.pid, "SIGKILL"); } catch {}
  });

  // 3. Poll TCP until all five listeners accept.
  const start = Date.now();
  for (;;) {
    const ups = await Promise.all(ports.map(tryConnect));
    if (ups.every(Boolean)) break;
    if (Date.now() - start > POLL_DEADLINE_MS) {
      console.error(
        `[ts-run] substrate did not open ${ports.join("/")} within ${POLL_DEADLINE_MS / 1000}s. Log: ${logPath}`,
      );
      await killSubstrate("SIGKILL");
      process.exitCode = 2;
      return;
    }
    await new Promise((r) => setTimeout(r, 500));
  }
  log(`substrate up on ${ports.join("/")} after ${Date.now() - start}ms`);

  // 4. Run the reality suite under a hard watchdog (SMALT_TS_WATCHDOG_MS,
  // default 200s). SMALT_TS_TEST_PATTERN narrows the suite for iteration.
  const testArgs = ["--test", "--test-timeout", "60_000", "ts-reality.test.mjs"];
  if (process.env.SMALT_TS_TEST_PATTERN) {
    testArgs.push("--test-name-pattern", process.env.SMALT_TS_TEST_PATTERN);
  }
  const testRun = spawn(
    "node",
    testArgs,
    {
      cwd: HERE,
      env: {
        ...process.env,
        NODE_EXTRA_CA_CERTS: CA_CERT,
        SMALT_TS_MEASUREMENT: MEASUREMENT,
        SMALT_TS_SB_SHARED_KEY: sharedKey,
        SMALT_TS_AMQP_PORT: String(AMQP_PORT),
        SMALT_TS_EH_PORT: String(EH_PORT),
        SMALT_TS_ARM_PORT: String(ARM_PORT),
        SMALT_TS_EGRESS_PORT: String(EGRESS_PORT),
        SMALT_TS_ARM_TLS_PORT: String(ARM_TLS_PORT),
      },
      stdio: "inherit",
    },
  );

  let watchdogFired = false;
  const watchdog = setTimeout(() => {
    watchdogFired = true;
    console.error(`[ts-run] WATCHDOG: suite exceeded ${TEST_WATCHDOG_MS}ms — SIGKILL, fail-closed`);
    try { testRun.kill("SIGKILL"); } catch {}
  }, TEST_WATCHDOG_MS);

  const code = await new Promise((resolve) => testRun.once("close", resolve));
  clearTimeout(watchdog);
  await killSubstrate("SIGTERM");

  if (watchdogFired) {
    process.exitCode = 124;
  } else {
    process.exitCode = code === 0 ? 0 : 1;
  }
}

main().catch((err) => {
  console.error("[ts-run] harness error:", err);
  process.exitCode = 3;
});
