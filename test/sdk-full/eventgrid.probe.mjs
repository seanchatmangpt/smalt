#!/usr/bin/env node
// eventgrid.probe.mjs — KD-39 lane: first real-SDK witness cell for the
// Event Grid ingest surface (POST /topics/:topic/events) via the real
// @azure/eventgrid EventGridPublisherClient.
//
// What it proves (the expected outcome is the REGISTERED DIVERGENCE):
//   1. Native Event Grid event schema (EG1 / EventGridEvent, system-topic
//      events) is refused fail-closed with typed 400 InvalidCloudEvent whose
//      message names the CloudEvents-1.0-only ingestion law — the pinned
//      GAP(eventgrid-eg1-schema-absent) / KD-39 divergence.
//   2. CloudEvents 1.0 payloads are admitted (200, real Event Grid empty
//      body) and stored (GET returns the event).
//   3. Hostile CloudEvents (missing specversion/source) are refused typed
//      400 all-or-nothing.
//
// A probe PASS here is a DIVERGENCE row in the receipt (parse_receipt
// counts them as divergence cells, not failures): the SDK is exercised
// honestly, the divergence is the server behavior under test.
//
// Bootstrap modeled on eventhubs.probe.mjs: boots a lane-private substrate
// (mix run --no-start --no-halt, MIX_ENV=test, MIX_BUILD_ROOT=_build-lane327)
// on env-overridable ports. Fail-closed: exit 0 all pass / 1 probe failure /
// 2 substrate never up / 3 harness skip.
//
// Run: node test/sdk-full/eventgrid.probe.mjs
import { spawn } from "node:child_process";
import net from "node:net";
import fs from "node:fs";
import path from "node:path";
import { randomBytes } from "node:crypto";

const REPO = path.resolve(import.meta.dirname, "../..");
// Lane-private block: exercised planes in 39311-39313 (amqp / eventhubs /
// arm), plus the listener ports the app unavoidably opens alongside them
// (egress / arm_tls / mcp) — all still lane-private 39311-39316.
const AMQP_PORT = Number(process.env.SMALT_TSEG_AMQP_PORT || 39311);
const EH_PORT = Number(process.env.SMALT_TSEG_EH_PORT || 39312);
const ARM_PORT = Number(process.env.SMALT_TSEG_ARM_PORT || 39313);
const EGRESS_PORT = Number(process.env.SMALT_TSEG_EGRESS_PORT || 39314);
const ARM_TLS_PORT = Number(process.env.SMALT_TSEG_ARM_TLS_PORT || 39315);
const MCP_PORT = Number(process.env.SMALT_TSEG_MCP_PORT || 39316);
const POLL_DEADLINE_MS = Number(process.env.SMALT_TSEG_POLL_MS || 90_000);

const RESULTS = [];
const probe = (name, fn) => {
  RESULTS.push({ name, run: fn });
};

async function main() {
  const EXTERNAL = process.env.SMALT_TSEG_EXTERNAL === "1";
  const sharedKey = EXTERNAL
    ? process.env.SMALT_TSEG_KEY
    : randomBytes(48).toString("base64");
  if (EXTERNAL && (!sharedKey || sharedKey.length < 16)) {
    console.error("[ts-eg-probe] SMALT_TSEG_EXTERNAL=1 requires SMALT_TSEG_KEY");
    process.exitCode = 3;
    return;
  }

  const ports = [AMQP_PORT, EH_PORT, ARM_PORT, EGRESS_PORT, ARM_TLS_PORT, MCP_PORT];
  const portsFree = EXTERNAL
    ? ports.map(() => true)
    : await Promise.all(ports.map(async (p) => {
        const s = net.connect({ host: "127.0.0.1", port: p, timeout: 1200 });
        return new Promise((resolve) => {
          s.once("connect", () => { s.destroy(); resolve(false); });
          s.once("error", () => resolve(true));
          s.once("timeout", () => { s.destroy(); resolve(true); });
        });
      }));
  if (!portsFree.every(Boolean)) {
    console.error("[ts-eg-probe] a port in 39311-39316 is occupied — wait or override SMALT_TSEG_*");
    process.exitCode = 3;
    return;
  }

  const bootEval = [
    `Application.put_env(:smalt, :sb_shared_key, "${sharedKey}")`,
    `Application.put_env(:smalt, :sb_endpoint, "sb://127.0.0.1:${AMQP_PORT}")`,
    `Application.put_env(:smalt, :amqp_port, ${AMQP_PORT})`,
    `Application.put_env(:smalt, :event_hubs_port, ${EH_PORT})`,
    `Application.put_env(:smalt, :arm_port, ${ARM_PORT})`,
    `Application.put_env(:smalt, :egress_port, ${EGRESS_PORT})`,
    `Application.put_env(:smalt, :arm_tls_port, ${ARM_TLS_PORT})`,
    `Application.put_env(:smalt, :mcp_port, ${MCP_PORT})`,
    `{:ok, _} = Application.ensure_all_started(:smalt)`,
  ].join("; ");

  const logPath = path.join(REPO, "test/sdk-full/.logs/eg-probe-substrate.log");
  fs.mkdirSync(path.dirname(logPath), { recursive: true });
  const logStream = EXTERNAL ? null : fs.createWriteStream(logPath, { flags: "w" });
  const child = EXTERNAL
    ? null
    : spawn("mix", ["run", "--no-start", "--no-halt", "-e", bootEval], {
        cwd: REPO,
        env: {
          ...process.env,
          MIX_ENV: "test",
          MIX_BUILD_ROOT: process.env.MIX_BUILD_ROOT || "_build-lane327",
        },
        stdio: ["ignore", "pipe", "pipe"],
        detached: true,
      });
  if (logStream) { child.stdout.pipe(logStream); child.stderr.pipe(logStream); }

  const killSubstrate = async () => {
    if (EXTERNAL) return;
    try {
      if (child.pid && child.exitCode === null) {
        try { process.kill(-child.pid, "SIGTERM"); } catch { child.kill("SIGTERM"); }
        const dl = Date.now() + 5000;
        while (child.exitCode === null && Date.now() < dl) await new Promise((r) => setTimeout(r, 200));
        if (child.exitCode === null) process.kill(-child.pid, "SIGKILL");
      }
    } catch { /* gone */ }
  };
  for (const sig of ["SIGINT", "SIGTERM", "SIGHUP"]) {
    process.on(sig, () => { killSubstrate(); process.exit(130); });
  }
  process.on("exit", () => {
    try { if (child.pid && child.exitCode === null) process.kill(-child.pid, "SIGKILL"); } catch {}
  });

  const tryConnect = (port) =>
    new Promise((resolve) => {
      const s = net.connect({ host: "127.0.0.1", port, timeout: 1500 });
      s.once("connect", () => { s.destroy(); resolve(true); });
      s.once("error", () => resolve(false));
      s.once("timeout", () => { s.destroy(); resolve(false); });
    });

  const start = Date.now();
  for (;;) {
    const ups = await Promise.all(ports.map(tryConnect));
    if (ups.every(Boolean)) break;
    if (Date.now() - start > POLL_DEADLINE_MS) {
      console.error(`[ts-eg-probe] substrate did not open ports in ${POLL_DEADLINE_MS / 1000}s. Log: ${logPath}`);
      await killSubstrate();
      process.exitCode = 2;
      return;
    }
    await new Promise((r) => setTimeout(r, 500));
  }
  console.log(`[ts-eg-probe] substrate up on 39311-39316 after ${Date.now() - start}ms`);

  // --- SDK probes (real @azure/eventgrid over the real HTTP wire) ----------
  const { createRequire } = await import("node:module");
  const req = createRequire(path.join(import.meta.dirname, "package.json"));
  const { EventGridPublisherClient, AzureKeyCredential } = req("@azure/eventgrid");

  const TOPIC = "ts-eg-kd39";
  const ENDPOINT = `http://127.0.0.1:${EGRESS_PORT}/topics/${TOPIC}/events`;
  // The JS SDK's schema is a constructor arg, not per-event: "EventGrid"
  // (EG1 native) vs "CloudEvent". Credential is arbitrary local-dev key
  // material, same as the py lane's AzureKeyCredential("py5-local").
  const client = (schema) =>
    new EventGridPublisherClient(ENDPOINT, schema, new AzureKeyCredential("ts-eg-local"), {
      retryOptions: { maxRetries: 0 }, allowInsecureConnection: true,
    });
  const T = (ms) => AbortSignal.timeout(ms);
  const errBody = async (err) => {
    const b = err?.response?.bodyAsText ?? err?.detail ?? "";
    return typeof b === "string" ? b : String(b);
  };

  // Probe 1 — THE DIVERGENCE WITNESS (KD-39 / GAP(eventgrid-eg1-schema-absent)).
  // A native Event Grid event-schema event (EG1: what the real SDK emits on
  // an "Event Grid" input-schema topic: id/subject/eventType/eventTime/data/
  // dataVersion, no specversion) must be refused fail-closed with typed 400
  // InvalidCloudEvent, message naming the CloudEvents-1.0-only ingestion
  // law. If the server instead admits it, the pinned divergence is
  // falsified -> hard FAIL.
  probe("eg.eg1-gridevent-schema-typed-unsupported", async () => {
    const c = client("EventGrid");
    const ev = {
      id: "kd39-eg1-witness",
      subject: "Smalt.Ts.KD39.Subject",
      eventType: "Smalt.Ts.KD39.EG1Probe",
      dataVersion: "1.0",
      data: { lane: "ts-kd39", kind: "eg1-native-schema", run: Date.now() },
    };
    try {
      await c.send([ev], { abortSignal: T(12_000) });
      throw new Error(
        "EG1_SCHEMA_ADMITTED — GAP(eventgrid-eg1-schema-absent) falsified: " +
        "native Event Grid schema was accepted but is registered unsupported",
      );
    } catch (err) {
      if (String(err?.message).startsWith("EG1_SCHEMA_ADMITTED")) throw err;
      const status = err?.statusCode ?? err?.status;
      const body = await errBody(err);
      let code = null;
      try { code = JSON.parse(body)?.error?.code; } catch { /* noop */ }
      if (status !== 400 || code !== "InvalidCloudEvent") {
        throw new Error(`EXPECTED_TYPED_400_InvalidCloudEvent got status=${status} code=${code} body=${body.slice(0, 200)}`);
      }
      if (!body.includes("CloudEvents 1.0")) {
        throw new Error(`REFUSAL_DOES_NOT_NAME_GAP: body=${body.slice(0, 300)}`);
      }
      return `DIVERGENCE (registered KD-39): EG1 native schema ` +
        `(id=${ev.id}) refused typed 400 InvalidCloudEvent naming ` +
        `CloudEvents-1.0-only ingestion — fail-closed as pinned`;
    }
  });

  // Probe 2 — the admitted path: CloudEvents 1.0 via the real SDK publisher
  // ("CloudEvent" input schema), answered 200 with the real Event Grid EMPTY
  // body, then retrievable via GET /topics/:topic/events.
  probe("eg.cloudevents-1.0-admitted", async () => {
    const c = client("CloudEvent");
    const id = `kd39-ce-${Date.now()}`;
    const ev = {
      id,
      specversion: "1.0",
      source: "/smalt/ts/kd39",
      type: "Smalt.Ts.KD39.CloudEvent",
      data: { lane: "ts-kd39", kind: "cloudevents-1.0", run: id },
    };
    await c.send([ev], { abortSignal: T(12_000) });
    const listRes = await fetch(`http://127.0.0.1:${EGRESS_PORT}/topics/${TOPIC}/events`, { signal: T(12_000) });
    if (listRes.status !== 200) throw new Error(`LIST_EXPECTED_200 got ${listRes.status}`);
    const events = await listRes.json();
    const found = (Array.isArray(events) ? events : []).find((e) => e?.id === id || e?.data?.id === id);
    if (!found) throw new Error(`EVENT_NOT_STORED: id=${id} list=${JSON.stringify(events).slice(0, 300)}`);
    return `CloudEvent ${id} admitted (200, empty body per real Event Grid form) and ` +
      `retrieved via GET (specversion=${found.specversion ?? "?"}, type=${found.type})`;
  });

  // Probe 3 — hostile CloudEvents refused all-or-nothing. Two-tier witness:
  // (a) the real TS SDK refuses a source-less CloudEvent client-side (payload
  // serializer: "events.source cannot be null or undefined") before any wire
  // byte; (b) the same hostile payload over the raw wire (exactly what a
  // looser client emits) must answer typed 400 InvalidCloudEvent, never a
  // 500 or a silent store.
  probe("eg.hostile-cloudevent-400", async () => {
    const c = client("CloudEvent");
    const bad = { id: "kd39-hostile-1", type: "Smalt.Ts.KD39.Hostile" }; // no source
    let sdkRefusal = "";
    try {
      await c.send([bad], { abortSignal: T(12_000) });
      throw new Error("HOSTILE_EVENT_ACCEPTED — expected a refusal");
    } catch (err) {
      if (String(err?.message).startsWith("HOSTILE_EVENT_ACCEPTED")) throw err;
      sdkRefusal = String(err?.message || err);
      if (!sdkRefusal.includes("source cannot be null or undefined")) {
        throw new Error(`UNEXPECTED_SDK_ERROR: ${sdkRefusal.slice(0, 200)}`);
      }
    }
    // tier (b): raw wire, server-side all-or-nothing gate
    const res = await fetch(`http://127.0.0.1:${EGRESS_PORT}/topics/${TOPIC}/events`, {
      method: "POST",
      headers: { "content-type": "application/json", "aeg-sas-key": "ts-eg-local" },
      body: JSON.stringify(bad),
      signal: T(12_000),
    });
    const body = await res.text();
    let code = null;
    try { code = JSON.parse(body)?.error?.code; } catch { /* noop */ }
    if (res.status !== 400 || code !== "InvalidCloudEvent") {
      throw new Error(`EXPECTED_TYPED_400_InvalidCloudEvent got status=${res.status} code=${code} body=${body.slice(0, 200)}`);
    }
    return `tier(a) SDK client-side refusal ("${sdkRefusal.slice(0, 60)}..."); ` +
      `tier(b) raw wire: hostile CloudEvent (missing source) refused typed 400 InvalidCloudEvent (all-or-nothing admission)`;
  });

  // --- runner ---------------------------------------------------------------
  let failed = 0;
  for (const { name, run } of RESULTS) {
    try {
      const detail = await run();
      console.log(`PASS ${name} :: ${detail}`);
    } catch (err) {
      failed++;
      console.log(`FAIL ${name} :: ${String(err?.message || err).slice(0, 400)}`);
    }
  }
  console.log(`SUMMARY ${RESULTS.length - failed}/${RESULTS.length} probes passed`);
  await killSubstrate();
  process.exitCode = failed === 0 ? 0 : 1;
}

main().catch((err) => {
  console.error(`[ts-eg-probe] harness error: ${err?.stack || err}`);
  process.exitCode = 3;
});
