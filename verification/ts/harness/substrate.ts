// substrate.ts — boot/teardown via scripts/substrate-ctl (v-block ports),
// bounded health poll, typed errors, exit contract 0/1/2/3/124.
import { spawn, spawnSync } from "node:child_process";
import net from "node:net";
import fs from "node:fs";
import path from "node:path";
import { boundedPoll } from "./poll.ts";
import { SUB } from "./credential.ts";

export const REPO = process.env.SMALT_REPO || path.resolve(import.meta.dirname, "../../..");
export const CERT_DIR = process.env.SMALT_CERT_DIR || path.join(REPO, ".smalt/tls");
export const CA_CERT = path.join(CERT_DIR, "ca-cert.pem");

const CTL = path.join(REPO, "scripts/substrate-ctl");

export interface Receipt {
  block: string;
  sharedKey?: string;
  ports: number[]; // [amqp, eh, arm, egress, tls, mcp] (+ optional 7th: kafka)
  pid: number;
  reused: boolean;
  auth: string;
}

export class SubstrateBootError extends Error {
  exitCode: number;
  constructor(msg: string, exitCode: number) {
    super(msg);
    this.name = "SubstrateBootError";
    this.exitCode = exitCode;
  }
}

export function tryConnect(port: number, host = "127.0.0.1", timeoutMs = 1500): Promise<boolean> {
  return new Promise((resolve) => {
    const s = net.connect({ host, port, timeout: timeoutMs });
    s.once("connect", () => {
      s.destroy();
      resolve(true);
    });
    s.once("timeout", () => {
      s.destroy();
      resolve(false);
    });
    s.once("error", () => resolve(false));
  });
}

export function parseReceipt(stdout: string): Receipt {
  const lines = stdout.trim().split("\n").filter(Boolean);
  const last = lines[lines.length - 1];
  const r = JSON.parse(last);
  return { block: r.block, ports: r.ports.map(Number), pid: Number(r.pid), reused: !!r.reused, auth: r.auth };
}

// Boot the shared substrate (wf1-4) via substrate-ctl on a v-block.
export async function bootShared(block: string): Promise<Receipt> {
  const res = spawnSync(CTL, ["up", "--block", block, "--auth", "enforce"], {
    encoding: "utf8",
    timeout: 150_000,
  });
  if (res.error) throw new SubstrateBootError(`substrate-ctl spawn failed: ${res.error}`, 2);
  const out = (res.stdout ?? "").trim();
  const lines = out.split("\n").filter(Boolean);
  const last = lines[lines.length - 1] ?? "";
  if (res.status !== 0 || !last.startsWith("{")) {
    throw new SubstrateBootError(
      `substrate-ctl up exit=${res.status} out=${(out + res.stderr).slice(-600)}`,
      res.status === 3 ? 2 : 2,
    );
  }
  const receipt = parseReceipt(out);
  await waitHealthy(receipt);
  return receipt;
}

async function waitHealthy(r: Receipt) {
  const [amqp, eh, arm, egress, tls, mcp] = r.ports;
  // HC lane additive: a 7-port receipt (bootPrivate) also gates on the kafka
  // face port; shared receipts (substrate-ctl, 6 ports) are unchanged.
  const kafka = r.ports[6];
  const wanted = kafka ? [amqp, eh, arm, egress, tls, mcp, kafka] : [amqp, eh, arm, egress, tls, mcp];
  await boundedPoll(
    `substrate ${r.block} ports+health`,
    async () => {
      const up = (
        await Promise.all(wanted.map((p) => tryConnect(p)))
      ).every(Boolean);
      if (!up) return null;
      const health = await fetch(`http://127.0.0.1:${arm}/metadata/endpoints`);
      return health.status === 200 ? true : null;
    },
    90_000,
  );
}

// Boot a PRIVATE substrate (wf5 throttle profile) with extra boot-eval
// put_envs. substrate-ctl cannot inject extra env, so this lifts the
// ts-run.mjs eval shape (docs/jira/v26.10.19/lifts/ts-run.mjs) and uses a
// v-block for port isolation + sweep-down after.
export async function bootPrivate(block: string, extraEnv: string, auth: "enforce" | "anonymous" = "enforce"): Promise<Receipt> {
  const ports = blockPorts(block);
  // Sweep anything beamish on the block's ports first (same law as sb_up).
  spawnSync(CTL, ["down", "--block", block, "--mode", "sweep"], { timeout: 60_000 });
  for (const p of ports) {
    if (await tryConnect(p, "127.0.0.1", 500)) {
      throw new SubstrateBootError(`block ${block} port ${p} occupied by non-sweepable listener`, 3);
      }
  }
  if (!fs.existsSync(CA_CERT)) {
    throw new SubstrateBootError("missing TLS CA — run bash scripts/gen_dev_cert.sh", 3);
  }
  const [amqp, eh, arm, egress, tls, mcp, kafka] = ports;
  const sharedKey = Buffer.from(`${block}-${Date.now()}-ts-suite`).toString("base64");
  const bootEval = [
    `Application.put_env(:smalt, :sb_shared_key, "${sharedKey}")`,
    `Application.put_env(:smalt, :sb_endpoint, "sb://127.0.0.1:${amqp}")`,
    `Application.put_env(:smalt, :amqp_port, ${amqp})`,
    `Application.put_env(:smalt, :event_hubs_port, ${eh})`,
    `Application.put_env(:smalt, :arm_port, ${arm})`,
    `Application.put_env(:smalt, :egress_port, ${egress})`,
    `Application.put_env(:smalt, :arm_tls_port, ${tls})`,
    `Application.put_env(:smalt, :mcp_port, ${mcp})`,
    // HC lane: 7th slot — pin the AZ-1 Kafka wire face to the block's kafka
    // port (config/test.exs default is ephemeral-probe; put_env wins here).
    `Application.put_env(:smalt, :kafka_port, ${kafka})`,
    `Application.put_env(:smalt, :auth_mode, :${auth})`,
    extraEnv,
    `{:ok, _} = Application.ensure_all_started(:smalt)`,
  ].join("; ");
  const log = fs.openSync(`/tmp/smalt-substrate-state/logs/${block}.log`, "w");
  const child = spawn(
    // asdf-pinned elixir ~> 1.20 (homebrew mix 1.19.5 is refused by mix.exs;
    // asdf shim dir first so PATH "mix" resolves lawfully)
    process.env.SMALT_MIX || path.join(process.env.HOME || "", ".asdf/shims/mix"),
    ["run", "--no-start", "--no-halt", "-e", bootEval],
    {
      cwd: REPO,
      env: {
        ...process.env,
        MIX_ENV: "test",
        SMALT_TLS_CERTFILE: path.join(CERT_DIR, "dev-cert.pem"),
        SMALT_TLS_KEYFILE: path.join(CERT_DIR, "dev-key.pem"),
      },
      stdio: ["ignore", log, log],
      detached: true,
    },
  );
  fs.closeSync(log);
  const deadline = Date.now() + 90_000;
  // WO-32 cordon (v26.10.31): the BEAM no longer binds arm_port (9443) or
  // arm_tls_port (9444) — posh owns the 9443 wire. A private BEAM-only boot
  // therefore binds amqp/eh/egress/mcp (+kafka); gating health on arm/tls
  // never converges. HC lane: disclosed minimal unblock, bootPrivate only.
  const bound = ports.filter((_, i) => ![2, 4].includes(i));
  for (;;) {
    const up = (await Promise.all(bound.map((p) => tryConnect(p)))).every(Boolean);
    const health = up
      ? await fetch(`http://127.0.0.1:${arm}/metadata/endpoints`).then((r) => r.status).catch(() => 0)
      : 0;
    if (up && health === 200) break;
    if (Date.now() > deadline) {
      try { process.kill(-child.pid!, "SIGKILL"); } catch {}
      throw new SubstrateBootError(`private substrate ${block} not healthy in 90s (log: /tmp/smalt-substrate-state/logs/${block}.log)`, 2);
    }
    await new Promise((r) => setTimeout(r, 250));
  }
  return { block, ports, pid: child.pid!, reused: false, auth, sharedKey };
}

export function blockPorts(block: string): number[] {
  const m = /^v(\d+)$/.exec(block);
  if (!m) throw new SubstrateBootError(`unknown block ${block}`, 64);
  const n = Number(m[1]);
  // 7 slots: [amqp, eh, arm, egress, tls, mcp, kafka] — kafka is the HC-lane
  // additive 7th (39700+10n+6). Shared-substrate consumers destructuring six
  // names are unaffected (JS destructuring ignores the extra element).
  return [0, 1, 2, 3, 4, 5, 6].map((i) => 39700 + 10 * n + i);
}

export async function down(block: string, mode: "owner" | "sweep" = "owner") {
  const res = spawnSync(CTL, ["down", "--block", block, "--mode", mode], { timeout: 60_000 });
  if (res.status !== 0) {
    console.error(`[substrate] down --block ${block} exit=${res.status}`);
  }
}
