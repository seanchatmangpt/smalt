#!/usr/bin/env node
// T3 SDK smoke harness. Exit codes: 0 pass / 1 test failure / 2 substrate
// never came up / 3 harness failure (ports occupied, spawn error).
import { spawn } from "node:child_process";
import net from "node:net";
import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

const REPO = process.cwd().endsWith("test/sdk-smoke") ? path.resolve(process.cwd(), "../..") : process.env.SMALT_REPO || process.cwd();
const HERE = path.dirname(fileURLToPath(import.meta.url));
const LOG_DIR = path.join(HERE, ".logs");
const ARM_PORT = 9443;
const EGRESS_PORT = 8443;
const AMQP_PORT = 5672;
// Enforce-mode substrate (Bearer verification ON) for the ARM token-path
// assertions in arm.test.cjs. The SDK-tier substrate (9443/8443/5672) runs
// MIX_ENV=test -> auth_mode :anonymous (config/test.exs): the JS SDKs do
// their own auth semantics in production; the enforce-mode contract is
// covered by test/auth_enforce_test.exs and the arm.test.cjs enforce rows.
// NOTE: the primary substrate ALWAYS binds an HTTPS TLS twin at
// arm_tls_port default 9444 (Smalt.Application TlsTwinDispatch), so the
// enforce twin uses 9445/8445 and re-pins ITS twin to 9446.
const ENFORCE_ARM_PORT = 9445;
const ENFORCE_EGRESS_PORT = 8445;
const ENFORCE_TLS_PORT = 9446;
const POLL_DEADLINE_MS = 60_000;

const log = (...a) => console.log("[sdk-smoke]", ...a);

function tryConnect(port) {
  return new Promise((resolve) => {
    const s = net.connect({ host: "127.0.0.1", port, timeout: 1500 });
    s.once("connect", () => { s.destroy(); resolve(true); });
    s.once("timeout", () => { s.destroy(); resolve(false); });
    s.once("error", () => resolve(false));
  });
}

function checkFree(port) {
  // A free port fails to connect.
  return tryConnect(port).then((up) => !up);
}

async function main() {
  fs.mkdirSync(LOG_DIR, { recursive: true });

  // 1. Ports must be free before boot.
  for (const port of [ARM_PORT, EGRESS_PORT, AMQP_PORT, ENFORCE_ARM_PORT, ENFORCE_EGRESS_PORT, ENFORCE_TLS_PORT]) {
    if (!(await checkFree(port))) {
      console.error(
        `[sdk-smoke] port ${port} is occupied. Do NOT kill the holder (it may be ` +
        `another lane's live substrate). Wait for it to exit, or rerun with a ` +
        `private-port override from the range 39000-39999 ` +
        `(docs/DEV_LOOP.md "Private port allocation").`,
      );
      process.exitCode = 3;
      return;
    }
  }

  // 2. Spawn substrate: mix run --no-halt in the repo, MIX_ENV=test.
  const logPath = path.join(LOG_DIR, "substrate.log");
  const logStream = fs.createWriteStream(logPath, { flags: "w" });
  const child = spawn("mix", ["run", "--no-halt"], {
    cwd: REPO,
    detached: true, // own process group so the beam cannot outlive us
    // config/test.exs (test isolation lane) randomizes the listener ports at
    // config time unless SMALT_TEST_*_PORT is set — pin the ports this
    // harness and the SDK tier address.
    env: {
      ...process.env,
      MIX_ENV: "test",
      SMALT_TEST_ARM_PORT: String(ARM_PORT),
      SMALT_TEST_EGRESS_PORT: String(EGRESS_PORT),
      SMALT_TEST_AMQP_PORT: String(AMQP_PORT),
    },
    stdio: ["ignore", "pipe", "pipe"],
  });
  child.stdout.pipe(logStream);
  child.stderr.pipe(logStream);
  child.stdout.pipe(process.stdout);
  child.stderr.pipe(process.stderr);

  const killSubstrate = (signal = "SIGTERM") => {
    try {
      if (child.pid && child.exitCode === null && !child.killed) {
        try { process.kill(-child.pid, signal); } catch { /* group gone */ }
        child.kill(signal);
      }
    } catch { /* already gone */ }
  };
  // killEnforce is defined later; handlers hold a ref set at definition.
  const killEnforceRef = { fn: null };
  for (const sig of ["SIGINT", "SIGTERM", "SIGHUP"]) {
    process.on(sig, () => { killSubstrate("SIGKILL"); killEnforceRef.fn?.(); process.exit(130); });
  }
  process.on("exit", () => { killSubstrate("SIGKILL"); killEnforceRef.fn?.(); });

  // 3. Poll TCP 9443 + 8443 (hard), 5672 log-only (broker may still be landing).
  const start = Date.now();
  let amqpUp = false;
  for (;;) {
    const [arm, egress] = await Promise.all([
      tryConnect(ARM_PORT),
      tryConnect(EGRESS_PORT),
    ]);
    if (arm && egress) break;
    if (Date.now() - start > POLL_DEADLINE_MS) {
      console.error(
        `[sdk-smoke] substrate did not open ${ARM_PORT}/${EGRESS_PORT} within ` +
        `${POLL_DEADLINE_MS / 1000}s. Substrate log: ${logPath}`,
      );
      killSubstrate("SIGKILL");
      process.exitCode = 2;
      return;
    }
    if (!amqpUp && (await tryConnect(AMQP_PORT))) {
      amqpUp = true;
      log(`amqp port ${AMQP_PORT} is accepting (log-only check)`);
    }
    await new Promise((r) => setTimeout(r, 500));
  }
  log(`substrate up on ${ARM_PORT}/${EGRESS_PORT} after ${Date.now() - start}ms`);

  // 3b. Boot the enforce-mode twin on 9444/8444. --no-start lets us set
  // application env (ports + auth_mode) BEFORE Smalt.Application boots its
  // Bandit listeners; MIX_ENV=test config would otherwise pin :anonymous.
  const enforceLogPath = path.join(LOG_DIR, "substrate-enforce.log");
  const enforceLog = fs.createWriteStream(enforceLogPath, { flags: "w" });
  const enforceEval =
    `Application.put_env(:smalt, :arm_port, ${ENFORCE_ARM_PORT}); ` +
    `Application.put_env(:smalt, :egress_port, ${ENFORCE_EGRESS_PORT}); ` +
    `Application.put_env(:smalt, :auth_mode, :enforce); ` +
    `Application.put_env(:smalt, :arm_tls_port, ${ENFORCE_TLS_PORT}); ` +
    `{:ok, _} = Application.ensure_all_started(:smalt); ` +
    `Process.sleep(:infinity)`;
  const enforce = spawn(
    "mix",
    ["run", "--no-start", "--no-halt", "-e", enforceEval],
    {
      cwd: REPO,
      detached: true,
      env: { ...process.env, MIX_ENV: "test" },
      stdio: ["ignore", "pipe", "pipe"],
    },
  );
  enforce.stdout.pipe(enforceLog);
  enforce.stderr.pipe(enforceLog);
  const killEnforce = (signal = "SIGKILL") => {
    try {
      if (enforce.pid && enforce.exitCode === null && !enforce.killed) {
        try { process.kill(-enforce.pid, signal); } catch { /* group gone */ }
        enforce.kill(signal);
      }
    } catch { /* already gone */ }
  };
  killEnforceRef.fn = killEnforce;
  process.on("exit", () => killEnforce());
  const enforceStart = Date.now();
  let enforceUp = false;
  for (;;) {
    const [arm4, egress4] = await Promise.all([
      tryConnect(ENFORCE_ARM_PORT),
      tryConnect(ENFORCE_EGRESS_PORT),
    ]);
    if (arm4 && egress4) { enforceUp = true; break; }
    if (Date.now() - enforceStart > POLL_DEADLINE_MS) break;
    if (enforce.exitCode !== null) break;
    await new Promise((r) => setTimeout(r, 500));
  }
  if (!enforceUp) {
    console.error(
      `[sdk-smoke] enforce substrate did not open ` +
      `${ENFORCE_ARM_PORT}/${ENFORCE_EGRESS_PORT} within ` +
      `${POLL_DEADLINE_MS / 1000}s. Log: ${enforceLogPath}`,
    );
    killSubstrate("SIGKILL");
    killEnforce();
    process.exitCode = 2;
    return;
  }
  log(`enforce substrate up on ${ENFORCE_ARM_PORT}/${ENFORCE_EGRESS_PORT} ` +
      `after ${Date.now() - enforceStart}ms`);

  // 3c. Mint one Bearer token from the ENFORCE substrate's own STS. Its dev
  // signing secret is generated per-VM, so the token minted here is the one
  // the enforce plane will verify. Exposed to tests via env.
  const tokenRes = await fetch(
    `http://127.0.0.1:${ENFORCE_ARM_PORT}/oauth2/v2.0/token`,
    {
      method: "POST",
      headers: { "content-type": "application/x-www-form-urlencoded" },
      body: new URLSearchParams({
        grant_type: "client_credentials",
        client_id: "sdk-smoke",
        client_secret: "sdk-smoke",
        scope: "https://management.azure.com/.default",
      }),
      signal: AbortSignal.timeout(15_000),
    },
  );
  if (!tokenRes.ok) {
    console.error(`[sdk-smoke] token mint failed: HTTP ${tokenRes.status}`);
    killSubstrate("SIGKILL");
    killEnforce();
    process.exitCode = 2;
    return;
  }
  const tokenBody = await tokenRes.json();
  if (!tokenBody.access_token) {
    console.error("[sdk-smoke] token mint returned no access_token");
    killSubstrate("SIGKILL");
    killEnforce();
    process.exitCode = 2;
    return;
  }
  log("bearer token minted from enforce STS");

  // 3d. Mode self-check (fail-closed): witness which auth mode each plane
  // is ACTUALLY serving before the suite runs — a stale or substituted VM
  // on these ports otherwise turns the SDK tier red for the wrong reason
  // (witnessed: 401 MalformedBearerHeader on the anonymous plane).
  const modeProbe = async (base) => {
    const res = await fetch(`${base}/subscriptions`, {
      signal: AbortSignal.timeout(10_000),
    });
    return res.status;
  };
  const anonStatus = await modeProbe(`http://127.0.0.1:${ARM_PORT}`);
  const enforceStatus = await modeProbe(`http://127.0.0.1:${ENFORCE_ARM_PORT}`);
  log(`mode self-check: anonymous-plane /subscriptions -> ${anonStatus} ` +
      `(expect 200); enforce-plane -> ${enforceStatus} (expect 401)`);
  if (anonStatus !== 200 || enforceStatus !== 401) {
    console.error(
      "[sdk-smoke] FATAL: substrate auth-mode drift — anonymous plane " +
      `answered ${anonStatus}, enforce plane ${enforceStatus}. A stale or ` +
      "substituted VM is serving these ports. Remediation: kill listeners " +
      "on 9443/8443 and re-run.",
    );
    killSubstrate("SIGKILL");
    killEnforce();
    process.exitCode = 2;
    return;
  }

  // 4. Run the test suite. The SDK tier reads the anonymous substrate's
  // ports directly; arm.test.cjs reads SMALT_ARM_BASE + SMALT_SMOKE_TOKEN.
  // SMALT_SDK_ROOT is exported to the children (census-run convention):
  // vendored SDKs at test/sdk-full/node_modules unless the caller pinned one.
  const SDK_ROOT = process.env.SMALT_SDK_ROOT ||
    path.join(REPO, "test/sdk-full/node_modules");
  // Explicit file list: census/eventhubs have dedicated fail-closed runners
  // (census-run.mjs / eh-run.mjs) that pin the broker shared key; a bare
  // dir run would only witness their guard-exit, not their probes.
  const testRun = spawn("node", ["--test",
    "test/sdk-smoke/amqp.test.cjs",
    "test/sdk-smoke/blob.test.cjs",
    "test/sdk-smoke/cosmos.test.cjs",
    "test/sdk-smoke/arm.test.cjs",
  ], {
    cwd: REPO,
    env: {
      ...process.env,
      SMALT_SDK_ROOT: SDK_ROOT,
      SMALT_SMOKE_TOKEN: tokenBody.access_token,
      SMALT_ARM_BASE: `http://127.0.0.1:${ENFORCE_ARM_PORT}`,
    },
    stdio: "inherit",
  });
  const code = await new Promise((resolve) => testRun.once("close", resolve));
  process.exitCode = code === 0 ? 0 : 1;
}

main().catch((err) => {
  console.error("[sdk-smoke] harness error:", err);
  process.exitCode = 3;
});
