#!/usr/bin/env node
// azb20/run.mjs — AZB-20 orchestrator: unmodified Microsoft SDK probes
// (test/sdk-full/*.probe.mjs) against EACH plane profile (SMALT_PLANES
// semantics via azb20/boot_plane.exs), per-plane interop matrix + header
// audit (azb20/recording-proxy.mjs).
//
// Exit 0 all cells pass-or-typed / 1 probe or header-audit failure /
// 2 substrate never up / 3 harness error.
import { spawn, spawnSync } from "node:child_process";
import net from "node:net";
import fs from "node:fs";
import path from "node:path";
import { randomBytes } from "node:crypto";
import { fileURLToPath } from "node:url";

const REPO = path.resolve(import.meta.dirname, "../../..");
const HERE = import.meta.dirname;
const OUT_DIR = path.join(REPO, "tmp/azb20");
fs.mkdirSync(OUT_DIR, { recursive: true });
fs.mkdirSync(path.join(REPO, "test/sdk-full/.logs"), { recursive: true });

const PRIV = { arm: 39443, armTls: 39444, egress: 39445, amqp: 39472, eh: 39473, mcp: 39475, proxy: 39454 };
const SB_KEY = randomBytes(48).toString("base64");
const CERT_DIR = process.env.SMALT_CERT_DIR || path.join(REPO, ".smalt/tls");
const CA = path.join(CERT_DIR, "ca-cert.pem");
const CERT = path.join(CERT_DIR, "dev-cert.pem");
const KEYF = path.join(CERT_DIR, "dev-key.pem");
for (const f of [CA, CERT, KEYF]) {
  if (!fs.existsSync(f)) { console.error(`[azb20] missing ${f}. Run: bash scripts/gen_dev_cert.sh`); process.exit(3); }
}

const tryConnect = (port) => new Promise((resolve) => {
  const s = net.connect({ host: "127.0.0.1", port, timeout: 1500 });
  s.once("connect", () => { s.destroy(); resolve(true); });
  s.once("timeout", () => { s.destroy(); resolve(false); });
  s.once("error", () => resolve(false));
});

const waitPort = async (port, deadlineMs = 120_000) => {
  const t0 = Date.now();
  for (;;) {
    if (await tryConnect(port)) return true;
    if (Date.now() - t0 > deadlineMs) return false;
    await new Promise((r) => setTimeout(r, 500));
  }
};

const waitExit = (child) => new Promise((resolve) => child.once("exit", resolve));

function runProbe(name, file, env, timeoutMs = 180_000) {
  return new Promise((resolve) => {
    const child = spawn("node", [path.join(REPO, "test/sdk-full", file)], {
      cwd: path.join(REPO, "test/sdk-full"),
      env: {
        ...process.env,
        NODE_EXTRA_CA_CERTS: CA,
        NODE_TLS_REJECT_UNAUTHORIZED: "0",
        ...env,
      },
      stdio: ["ignore", "pipe", "pipe"],
    });
    let out = "";
    const timer = setTimeout(() => { child.kill("SIGKILL"); out += "\n[azb20] WATCHDOG KILL\n"; }, timeoutMs);
    child.stdout.on("data", (d) => { out += d; });
    child.stderr.on("data", (d) => { out += d; });
    child.once("exit", (code) => {
      clearTimeout(timer);
      resolve({ name, file, exit: code, tail: out.split("\n").filter(Boolean).slice(-40).join("\n") });
    });
  });
}

// Boot one plane; returns the child (or null if never up).
let currentChild = null;
let currentChildSet = (c) => { currentChild = c; };

async function bootPlane(plane) {
  const portsToCheck = [PRIV.arm, PRIV.armTls, PRIV.egress, PRIV.amqp, PRIV.eh, PRIV.mcp, PRIV.proxy];
  for (const p of portsToCheck) {
    if (await tryConnect(p)) { console.error(`[azb20] private port ${p} occupied — BLOCKED`); return null; }
  }
  const logStream = fs.createWriteStream(path.join(REPO, `test/sdk-full/.logs/azb20-${plane}-substrate.log`), { flags: "w" });
  const child = spawn("mix", ["run", "--no-start", "--no-halt", "test/sdk-full/azb20/boot_plane.exs"], {
    cwd: REPO,
    env: {
      ...process.env,
      MIX_ENV: "test",
      MIX_BUILD_ROOT: process.env.MIX_BUILD_ROOT || "_build-lane-azb20",
      AZB20_PLANES: plane,
      AZB20_SB_KEY: SB_KEY,
      SMALT_TLS_CERTFILE: CERT,
      SMALT_TLS_KEYFILE: KEYF,
    },
    stdio: ["ignore", "pipe", "pipe"],
    detached: true,
  });
  child.stdout.pipe(logStream); child.stderr.pipe(logStream);
  currentChildSet(child);
  // Liveness: the top-level MCP listener opens last on every plane shape.
  const exited = new Promise((resolve) => child.once("exit", resolve));
  const up = await Promise.race([
    waitPort(PRIV.mcp, 180_000).then((ok) => (ok ? "up" : null)),
    exited.then(() => "exited"),
  ]);
  if (!up || up === "exited") {
    try { child.kill("SIGKILL"); } catch {}
    console.error(`[azb20] ${plane}: substrate never up${up === "exited" ? " (boot process exited)" : ""}`);
    return null;
  }
  // Plane sockets must open and STAY open (crash-loop detector).
  const expected = { control: ["arm", "armTls"], data: ["egress"], integration: ["amqp", "eh"], identity: [] }[plane];
  const portOf = { arm: PRIV.arm, armTls: PRIV.armTls, egress: PRIV.egress, amqp: PRIV.amqp, eh: PRIV.eh };
  const t0 = Date.now();
  let sockets = {};
  for (;;) {
    if (await Promise.race([exited.then(() => true), new Promise((r) => setTimeout(r, 50))])) {
      console.error(`[azb20] ${plane}: substrate exited while waiting for sockets ${expected.join(",")}`);
      return null;
    }
    sockets = {};
    for (const k of expected) sockets[k] = await tryConnect(portOf[k]);
    if (expected.every((k) => sockets[k])) break;
    if (Date.now() - t0 > 60_000) {
      try { child.kill("SIGKILL"); } catch {}
      console.error(`[azb20] ${plane}: expected sockets never opened: ${JSON.stringify(sockets)}`);
      return null;
    }
    await new Promise((r) => setTimeout(r, 500));
  }
  await new Promise((r) => setTimeout(r, 1500));
  return child;
}

const killTree = async (child) => {
  if (!child) return;
  const exited = new Promise((resolve) => child.once("exit", resolve));
  if (child.exitCode !== null) { await Promise.race([exited, new Promise((r) => setTimeout(r, 100))]); return; }
  try { process.kill(-child.pid, "SIGTERM"); } catch { child.kill("SIGTERM"); }
  const won = await Promise.race([exited, new Promise((r) => setTimeout(r, 5000))]);
  if (!won) { try { process.kill(-child.pid, "SIGKILL"); } catch { child.kill("SIGKILL"); } await exited; }
};
const cleanup = () => { try { if (currentChild && currentChild.exitCode === null) process.kill(-currentChild.pid, "SIGKILL"); } catch {} };
process.on("exit", cleanup);
process.on("SIGINT", () => { cleanup(); process.exit(130); });

// Recording proxy lifecycle. Returns {stop(), audit()} — audit() runs after
// SIGTERM and resolves {pass, violations, count}.
function startProxy(plane, target) {
  const cap = path.join(OUT_DIR, `capture-${plane}.jsonl`);
  try { fs.unlinkSync(cap); } catch {}
  const child = spawn("node", [
    path.join(HERE, "recording-proxy.mjs"),
    "--listen", String(PRIV.proxy),
    "--target", target,
    "--plane", plane,
    "--capture", cap,
  ], {
    env: { ...process.env, SMALT_CERT_DIR: CERT_DIR },
    stdio: ["ignore", "pipe", "pipe"],
  });
  let out = "";
  child.stdout.on("data", (d) => (out += d));
  child.stderr.on("data", (d) => (out += d));
  const stop = () => new Promise((resolve) => {
    child.once("exit", (code) => resolve({ code, log: out }));
    child.kill("SIGTERM");
    setTimeout(() => { try { child.kill("SIGKILL"); } catch {} resolve({ code: -1, log: out }); }, 5000).unref?.();
  });
  return { stop, capture: cap };
}

const PROXIED = "https://localhost:39454"; // proxy fronts the plane's http listener

// Per-plane probe plan: [probeFile, env]. Probes exit 2 on plane-down (typed).
function probePlan(plane) {
  const armHttp = `http://127.0.0.1:${PRIV.arm}`;
  const egress = `http://127.0.0.1:${PRIV.egress}`;
  const attach = {
    SMALT_TSEG_EXTERNAL: "1", SMALT_TSEG_KEY: SB_KEY,
    SMALT_TSEG_AMQP_PORT: String(PRIV.amqp), SMALT_TSEG_EH_PORT: String(PRIV.eh),
    SMALT_TSEG_ARM_PORT: String(PRIV.arm), SMALT_TSEG_EGRESS_PORT: String(PRIV.egress),
    SMALT_TSEG_ARM_TLS_PORT: String(PRIV.armTls), SMALT_TSEG_MCP_PORT: String(PRIV.mcp),
  };
  const eh = {
    SMALT_TSEH_EXTERNAL: "1", SMALT_TSEH_KEY: SB_KEY,
    SMALT_TSEH_AMQP_PORT: String(PRIV.amqp), SMALT_TSEH_EH_PORT: String(PRIV.eh),
    SMALT_TSEH_ARM_PORT: String(PRIV.arm), SMALT_TSEH_EGRESS_PORT: String(PRIV.egress),
    SMALT_TSEH_ARM_TLS_PORT: String(PRIV.armTls),
  };
  const sn = {
    SMALT_TSSN_EXTERNAL: "1", SMALT_TSSN_KEY: SB_KEY,
    SMALT_TSSN_AMQP_PORT: String(PRIV.amqp), SMALT_TSSN_EH_PORT: String(PRIV.eh),
    SMALT_TSSN_ARM_PORT: String(PRIV.arm), SMALT_TSSN_EGRESS_PORT: String(PRIV.egress),
    SMALT_TSSN_ARM_TLS_PORT: String(PRIV.armTls),
  };
  const base = {
    SMALT_TS_ARM_PORT: String(PRIV.arm), SMALT_TS_ARM_TLS_PORT: String(PRIV.proxy),
    SMALT_TS_ARM: armHttp, SMALT_TS_ARM_TLS: PROXIED, SMALT_TS_EGRESS: egress,
    SMALT_TS_KV_ENDPOINT: egress, SMALT_TS_KV_ARM: armHttp,
    LEDGER_ENDPOINT: egress,
  };
  // KV/secret surfaces live behind the TLS-twin dispatch (TlsTwinDispatch
  // routes /keys,/secrets,/kv to the egress router), so the kv + secrets
  // probes target the REAL TLS twin directly — not the recording proxy,
  // which fronts the plain ARM router and would mis-route those prefixes.
  const kvDirect = {
    SMALT_TS_ARM_TLS_PORT: String(PRIV.armTls),
    SMALT_TS_ARM_TLS: `https://localhost:${PRIV.armTls}`,
  };
  const plan = [
    ["arm-resources.probe.mjs", base],
    ["resourcegraph.probe.mjs", base],
    ["keyvault.probe.mjs", { ...base, ...kvDirect }],
    ["secrets.probe.mjs", { ...base, ...kvDirect }],
    ["appconfig.probe.mjs", base],
    ["blob.probe.mjs", base],
    ["cosmos.probe.mjs", base],
    ["ledger.probe.mjs", base],
    ["eventgrid.probe.mjs", { ...base, ...attach }],
    ["eventhubs.probe.mjs", { ...base, ...eh }],
    ["sentinel.probe.mjs", { ...base, ...sn }],
  ];
  return plan.map(([file, env]) => [file, { ...env, SMALT_PLANES: plane }]);
}

const PLANE_TARGETS = {
  control: `http://127.0.0.1:${PRIV.arm}`,
  data: `http://127.0.0.1:${PRIV.egress}`,
  integration: `http://127.0.0.1:${PRIV.arm}`,
  identity: `http://127.0.0.1:${PRIV.arm}`,
};

const matrix = [];
const HEADER_AUDIT_PLANES = ["control", "data"];

for (const plane of ["control", "data", "integration", "identity"]) {
  console.log(`\n===== plane ${plane} =====`);
  const child = await bootPlane(plane);
  if (!child) {
    for (const [file] of probePlan(plane)) matrix.push({ plane, probe: file, exit: 2, verdict: "SUBSTRATE-NEVER-UP" });
    continue;
  }
  // Which plane sockets actually opened (typed matrix facts).
  const sockets = {};
  for (const [k, p] of Object.entries({ arm: PRIV.arm, armTls: PRIV.armTls, egress: PRIV.egress, amqp: PRIV.amqp, eh: PRIV.eh })) {
    sockets[k] = await tryConnect(p);
  }
  console.log(`[azb20] ${plane} sockets: ${JSON.stringify(sockets)}`);

  const proxy = HEADER_AUDIT_PLANES.includes(plane)
    ? startProxy(plane, PLANE_TARGETS[plane])
    : null;
  await new Promise((r) => setTimeout(r, 800));

  for (const [file, env] of probePlan(plane)) {
    const r = await runProbe(file, file, env);
    const verdict = r.exit === 0 ? "PASS" : r.exit === 2 ? "PLANE-DOWN" : r.exit === 3 ? "HARNESS-SKIP" : "FAIL";
    matrix.push({ plane, probe: file, exit: r.exit, verdict, detail: r.tail.split("\n").slice(-6).join(" | ") });
    console.log(`[${plane}] ${file} -> exit ${r.exit} (${verdict})`);
  }

  if (proxy) {
    const res = await proxy.stop();
    matrix.push({
      plane, probe: "HEADER-AUDIT", exit: res.code, verdict: res.code === 0 ? "PASS" : "FAIL",
      detail: res.log.split("\n").filter((l) => l.includes("AUDIT") || l.includes("VIOLATION")).slice(0, 8).join(" | "),
    });
    console.log(`[${plane}] header audit -> exit ${res.code}`);
  }
  await killTree(child);
}

// ---- Falsifier witnesses + typed-gap extraction ----
fs.writeFileSync(path.join(OUT_DIR, "matrix.json"), JSON.stringify(matrix, null, 2));

// Console matrix.
const probes = [...new Set(matrix.map((r) => r.probe))];
console.log("\n===== INTEROP MATRIX (exit 0=PASS 1=FAIL 2=PLANE-DOWN 3=HARNESS) =====");
console.log(["probe", ...["control", "data", "integration", "identity"]].join("\t"));
for (const p of probes) {
  const row = ["control", "data", "integration", "identity"].map((pl) => {
    const r = matrix.find((m) => m.plane === pl && m.probe === p);
    return r ? String(r.exit) : "-";
  });
  console.log([p, ...row].join("\t"));
}

const fails = matrix.filter((r) => r.verdict === "FAIL" || r.verdict === "SUBSTRATE-NEVER-UP");
if (fails.length) {
  console.error(`\n[azb20] ${fails.length} FAIL/SUBSTRATE-NEVER-UP cells (typed gaps — see tmp/azb20/matrix.json)`);
  process.exitCode = 1;
} else {
  console.log("\n[azb20] all cells PASS or typed (PLANE-DOWN / HARNESS-SKIP)");
}
