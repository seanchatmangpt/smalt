#!/usr/bin/env node
// run-all.mjs — sequential wf1..wf5 over one shared substrate (wf1-4, block
// v-block via substrate-ctl) + a private arm_rate_limit substrate for wf5.
// Fail-closed aggregation: exit 0 all green-or-registered; 1 any FAIL;
// 2 substrate never up; 3 harness/skip (incl. azure-credential loud-SKIP);
// 4 wf5 throttle not enforced; 124 watchdog.
import { spawn } from "node:child_process";
import path from "node:path";
import { setTimeout as delay } from "node:timers/promises";

const HERE = import.meta.dirname;
const REPO = path.resolve(HERE, "../..");
const WATCHDOG_MS = Number(process.env.SMALT_TS_WATCHDOG_MS || 600_000);
const BLOCK = process.env.SMALT_TS_BLOCK || "v13";
const PRIVATE_BLOCK = process.env.SMALT_TS_PRIVATE_BLOCK || "v14";
const CRED_MODE = process.env.SMALT_TS_CREDENTIAL || "smalt";

const log = (...a) => console.log("[run-all]", ...a);

function runWf(wf, env) {
  return new Promise((resolve) => {
    const child = spawn(process.execPath, [path.join(HERE, "harness", "wfmain.ts"), wf], {
      env: { ...process.env, ...env },
      stdio: ["ignore", "pipe", "pipe"],
    });
    let out = "";
    let err = "";
    child.stdout.on("data", (d) => { out += d; process.stdout.write(d); });
    child.stderr.on("data", (d) => { err += d; process.stderr.write(d); });
    // SLEEP-CLASS: POLL-STEP — watchdog kill-deadline for the wf child; the
    // timer owns nothing but the bounded kill budget.
    const watchdog = setTimeout(() => {
      console.error(`[run-all] WATCHDOG ${wf}: ${WATCHDOG_MS}ms — SIGKILL`);
      child.kill("SIGKILL");
      resolve({ code: 124, out, err: err + "\nWATCHDOG" });
    }, WATCHDOG_MS);
    child.on("close", (code) => {
      clearTimeout(watchdog);
      resolve({ code: code ?? 1, out, err });
    });
  });
}

async function main() {
  const t0 = Date.now();
  const { bootShared, bootPrivate, down, CA_CERT, SubstrateBootError } =
    await import("./harness/substrate.ts");
  const { makeCredential } = await import("./harness/credential.ts");
  const { rollup } = await import("./harness/enum.ts");
  const { randomUUID } = await import("node:crypto");

  // The suite boots its OWN substrate so the AMQP SAS shared key is known
  // to the harness (substrate-ctl's boot generates one it doesn't expose).
  let receipt;
  try {
    receipt = await bootPrivate(BLOCK, ":ok", "enforce");
  } catch (e) {
    if (e instanceof SubstrateBootError) {
      console.error(`[run-all] SUBSTRATE-BOOT-FAIL: ${e.message}`);
      process.exit(2);
    }
    throw e;
  }
  const [amqp, eh, arm, egress, tls] = receipt.ports;
  log(`shared substrate block=${receipt.block} ports=${receipt.ports.join("/")} reused=${receipt.reused}`);

  const env = {
    NODE_EXTRA_CA_CERTS: CA_CERT,
    SMALT_TS_SB_SHARED_KEY: receipt.sharedKey ?? "unset",
    SMALT_TS_RUNID: randomUUID().slice(0, 8),
    SMALT_TS_AMQP_PORT: String(amqp),
    SMALT_TS_EH_PORT: String(eh),
    SMALT_TS_ARM: `http://127.0.0.1:${arm}`,
    SMALT_TS_EGRESS: `http://127.0.0.1:${egress}`,
    SMALT_TS_TLS: `https://localhost:${tls}`,
    SMALT_TS_CREDENTIAL: CRED_MODE,
  };

  const results = [];
  let exitCode = 0;

  const WFS = (process.env.SMALT_TS_WF ?? "wf1,wf2,wf3,wf4").split(",").filter(Boolean);
  for (const wf of WFS) {
    const r = await runWf(wf, env);
    results.push({ wf, r });
    if (r.code === 2) { exitCode = 2; break; }
  }

  // azure-credential loud-SKIP: if credMode=azure and wf1 exit 3, propagate.
  if (CRED_MODE === "azure" && results.some(({ r }) => r.code === 3)) {
    console.error("[run-all] LOUD-SKIP: azure credential leg failed (KD-100 instance-discovery)");
    exitCode = 3;
  }

  if (exitCode === 0) {
    // wf5 on a private throttle-profile substrate.
    const RATE = Number(process.env.SMALT_TS_ARM_RATE_LIMIT || 20);
    let preceipt;
    try {
      preceipt = await bootPrivate(
        PRIVATE_BLOCK,
        `Application.put_env(:smalt, :arm_rate_limit, ${RATE})`,
        "enforce",
      );
    } catch (e) {
      if (e instanceof SubstrateBootError) {
        console.error(`[run-all] PRIVATE-SUBSTRATE-BOOT-FAIL: ${e.message}`);
        console.error(`[run-all] LOUD-SKIP exit 3: wf5 could not establish its private substrate`);
        process.exitCode = 3;
        finish(results, rollupMod(rollup, results), 3);
        return;
      }
      throw e;
    }
    const [pamqp, peh, parm, pegress, ptls] = preceipt.ports;
    const wf5env = {
      ...env,
      SMALT_TS_RUNID: randomUUID().slice(0, 8),
      SMALT_TS_AMQP_PORT: String(pamqp),
      SMALT_TS_EH_PORT: String(peh),
      SMALT_TS_ARM: `http://127.0.0.1:${parm}`,
      SMALT_TS_EGRESS: `http://127.0.0.1:${pegress}`,
      SMALT_TS_TLS: `https://localhost:${ptls}`,
      SMALT_TS_RATE_LIMIT: String(RATE),
    };
    const r5 = await runWf("wf5", wf5env);
    results.push({ wf: "wf5", r: r5 });
    await down(PRIVATE_BLOCK, "sweep");
    if (r5.code === 4) exitCode = 4;
    else if (r5.code !== 0) exitCode = 1;
  }

  // Verdict table from each wf child's structured final line if present.
  const { summary, ok } = aggregate(results);
  console.log(summary);
  if (exitCode === 0 && !ok) exitCode = 1;
  process.exitCode = exitCode;
  log(`done in ${((Date.now() - t0) / 1000).toFixed(1)}s exit=${exitCode}`);
  await down(BLOCK, "sweep").catch(() => {});
}

function aggregate(results) {
  const lines = [];
  let ok = true;
  for (const { wf, r } of results) {
    lines.push(`-- ${wf}: child exit=${r.code}`);
    // child prints a final JSON line: {"checks":[...]}
    const m = r.out.match(/\{"id":[^\n]*\}\s*$/m);
    if (m) {
      try {
        const parsed = JSON.parse(m[0]);
        for (const c of parsed.checks) {
          lines.push(`   [${c.verdict}] ${c.name} — ${c.detail}`);
          if (c.verdict !== "GREEN" && !c.verdict.startsWith("REGISTERED-DIVERGENCE")) ok = false;
        }
      } catch { lines.push("   (unparseable result line)"); ok = false; }
    } else if (r.code !== 0) {
      lines.push(`   (no result line; stderr tail: ${r.err.slice(-300).replace(/\n/g, " | ")})`);
      ok = false;
    }
  }
  return { summary: "\n== VERDICT TABLE ==\n" + lines.join("\n"), ok };
}

// helper kept trivial so the early-exit path can print a table too
function rollupMod(rollup, results) { return aggregate(results).summary; }

function finish(results, summary, code) {
  console.log(summary);
  process.exit(code);
}

main().catch((e) => {
  console.error("[run-all] harness error:", e);
  process.exit(3);
});
