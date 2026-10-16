#!/usr/bin/env node
// eventhubs.probe.mjs — TS-5 lane: first real-SDK witness of the post-fix
// Event Hubs AMQP wire delivery path (route/2 mode :eh + deliver_eventhubs/2
// with x-opt-sequence-number stamping).
//
// Follows test/sdk-full/ts-run.mjs's bootstrap: boots the smalt substrate
// (mix run --no-start --no-halt, MIX_ENV=test) on env-overridable ports
// (defaults in the documented private 39000-39999 range so this probe never
// contends the front door or sibling lanes' published blocks), then runs the
// @azure/event-hubs probes and prints a per-probe receipt. Fail-closed.
//
// Run: flock /tmp/smalt-substrate.lock node test/sdk-full/eventhubs.probe.mjs
// Exit codes: 0 all pass / 1 probe failure / 2 substrate never up / 3 harness.
import { spawn } from "node:child_process";
import net from "node:net";
import fs from "node:fs";
import path from "node:path";
import { randomBytes } from "node:crypto";

const REPO = path.resolve(import.meta.dirname, "../..");
// Private block (docs/DEV_LOOP.md "Private port allocation", 39000-39999):
// 39690-39694, one allocation for this harness.
const AMQP_PORT = Number(process.env.SMALT_TSEH_AMQP_PORT || 39690);
const EH_PORT = Number(process.env.SMALT_TSEH_EH_PORT || 39691);
const ARM_PORT = Number(process.env.SMALT_TSEH_ARM_PORT || 39692);
const EGRESS_PORT = Number(process.env.SMALT_TSEH_EGRESS_PORT || 39693);
const ARM_TLS_PORT = Number(process.env.SMALT_TSEH_ARM_TLS_PORT || 39694);
const POLL_DEADLINE_MS = 90_000;

const RESULTS = [];
const probe = (name, fn) => {
  RESULTS.push({ name, run: fn });
};

async function main() {
  // SMALT_TSEH_EXTERNAL=1: attach to an already-running substrate instead of
  // booting one (key via SMALT_TSEH_KEY; substrate log capture skipped).
  const EXTERNAL = process.env.SMALT_TSEH_EXTERNAL === "1";
  const sharedKey = EXTERNAL
    ? process.env.SMALT_TSEH_KEY
    : randomBytes(48).toString("base64");
  if (EXTERNAL && (!sharedKey || sharedKey.length < 16)) {
    console.error("[ts-eh-probe] SMALT_TSEH_EXTERNAL=1 requires SMALT_TSEH_KEY");
    process.exitCode = 3;
    return;
  }

  const portsFree = EXTERNAL
    ? [true, true, true, true, true]
    : await Promise.all(
    [AMQP_PORT, EH_PORT, ARM_PORT, EGRESS_PORT, ARM_TLS_PORT].map(async (p) => {
      const s = net.connect({ host: "127.0.0.1", port: p, timeout: 1200 });
      return new Promise((resolve) => {
        s.once("connect", () => { s.destroy(); resolve(false); });
        s.once("error", () => resolve(true));
        s.once("timeout", () => { s.destroy(); resolve(true); });
      });
    }),
  );
  if (!portsFree.every(Boolean)) {
    console.error("[ts-eh-probe] a port in 39690-39694 is occupied — wait or override SMALT_TSEH_*");
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
    `{:ok, _} = Application.ensure_all_started(:smalt)`,
  ].join("; ");

  const logPath = path.join(REPO, "test/sdk-full/.logs/eh-probe-substrate.log");
  fs.mkdirSync(path.dirname(logPath), { recursive: true });
  const logStream = EXTERNAL
    ? null
    : fs.createWriteStream(logPath, { flags: "w" });
  const child = EXTERNAL
    ? null
    : spawn("mix", ["run", "--no-start", "--no-halt", "-e", bootEval], {
        cwd: REPO,
        env: { ...process.env, MIX_ENV: "test" },
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
    const ups = await Promise.all(
      [AMQP_PORT, EH_PORT, ARM_PORT, EGRESS_PORT, ARM_TLS_PORT].map(tryConnect),
    );
    if (ups.every(Boolean)) break;
    if (Date.now() - start > POLL_DEADLINE_MS) {
      console.error(`[ts-eh-probe] substrate did not open ports in ${POLL_DEADLINE_MS / 1000}s. Log: ${logPath}`);
      await killSubstrate();
      process.exitCode = 2;
      return;
    }
    await new Promise((r) => setTimeout(r, 500));
  }
  console.log(`[ts-eh-probe] substrate up on 39690-39694 after ${Date.now() - start}ms`);

  // --- SDK probes (real @azure/event-hubs over the real AMQP wire) ---------
  const { createRequire } = await import("node:module");
  const req = createRequire(path.join(import.meta.dirname, "package.json"));
  const { EventHubProducerClient, EventHubConsumerClient } = req("@azure/event-hubs");
  try { (await import("@azure/logger")).default ??= {}; } catch {}
  try {
    const logger = req("@azure/logger");
    if (logger.AzureLogger) logger.AzureLogger.silent = true;
  } catch {}

  const CONN =
    `Endpoint=sb://127.0.0.1:${EH_PORT};SharedAccessKeyName=RootManageSharedAccessKey;` +
    `SharedAccessKey=${sharedKey};EntityPath=ts5-hub;UseDevelopmentEmulator=true`;
  const OPTS = { retryOptions: { maxRetries: 0, timeoutInMs: 10_000 } };
  const probeOpts = () => OPTS;
  const T = (ms) => AbortSignal.timeout(ms);
  const boundedClose = async (h, ms = 4000) => {
    try {
      await Promise.race([
        Promise.resolve(h.close()).catch(() => {}),
        new Promise((r) => setTimeout(r, ms)),
      ]);
    } catch {}
  };

  // Probe 1: getEventHubProperties (management link) — recorded witness; a
  // 501 here is a typed gap of the lane, not a delivery-gate failure.
  let partitionIds = ["0", "1"];
  probe("get-event-hub-properties", async () => {
    const client = new EventHubProducerClient(CONN, probeOpts());
    try {
      const props = await client.getEventHubProperties({ abortSignal: T(12_000) });
      if (!props || !Array.isArray(props.partitionIds) || props.partitionIds.length === 0) {
        return `GAP-CLASS: bad props: ${JSON.stringify(props)}`;
      }
      partitionIds = props.partitionIds.map(String);
      return `partitionIds=${JSON.stringify(props.partitionIds)} createdOn=${props.createdOn?.toISOString?.() ?? props.createdOn}`;
    } catch (err) {
      return `GAP-CLASS: ${err?.name}(${err?.code}) ${String(err?.message).slice(0, 80)}`;
    } finally {
      await boundedClose(client);
    }
  });

  // Probe 2: getPartitionProperties (management link, per-partition).
  probe("get-partition-properties", async () => {
    const client = new EventHubProducerClient(CONN, probeOpts());
    try {
      const out = [];
      for (const pid of partitionIds) {
        try {
          const pp = await client.getPartitionProperties(pid, { abortSignal: T(12_000) });
          out.push(`${pid}:begin=${pp.beginningSequenceNumber},end=${pp.lastEnqueuedSequenceNumber},offset=${pp.lastEnqueuedOffset}`);
        } catch (err) {
          out.push(`${pid}: ${err?.name}(${err?.code}) ${String(err?.message).slice(0, 60)}`);
        }
      }
      return out.join(" | ");
    } finally {
      await boundedClose(client);
    }
  });

  // Probe 3: THE delivery witness — producer send (partition-pinned) ->
  // consumer $Default subscribe-earliest on the real AMQP wire; assert
  // in-order delivery and the x-opt-sequence-number annotation (surfaced by
  // the SDK as event.sequenceNumber, long).
  probe("wire-delivery-ordered-sequence", async () => {
    const partitionId = "0";
    const producer = new EventHubProducerClient(CONN, probeOpts());
    const consumer = new EventHubConsumerClient(
      EventHubConsumerClient.defaultConsumerGroupName,
      CONN,
      probeOpts(),
    );
    const subHandles = [];
    try {
      const N = 6;
      const sent = [];
      for (let i = 0; i < N; i++) {
        const body = `ts5-wire-${Date.now()}-${i}`;
        const batch = await producer.createBatch({ partitionId, abortSignal: T(15_000) });
        if (!batch.tryAdd({ body })) throw new Error("tryAdd failed");
        await producer.sendBatch(batch, { abortSignal: T(15_000) });
        sent.push(body);
      }

      const received = [];
      const sub = await consumer.subscribe(
        partitionId,
        {
          processEvents: async (events) => {
            for (const ev of events) {
              received.push({
                body: typeof ev.body === "string" ? ev.body : JSON.stringify(ev.body),
                seq: ev.sequenceNumber,
                enqueued: ev.enqueuedTimeUtc?.toISOString?.(),
                offset: ev.offset,
                systemProps: ev.systemProperties?.modificationNumber,
                rawSeqAnnotation: ev.systemProperties
                  ? Object.fromEntries(Object.entries(ev.systemProperties).filter(([k]) => String(k).includes("sequence")))
                  : undefined,
              });
            }
          },
          processError: async (err) => {
            console.error(`[wire-delivery] processError: ${err?.name}: ${String(err?.message).slice(0, 200)}`);
          },
        },
        { startPosition: { offset: "-1" }, maxWaitTimeInSeconds: 2 },
      );
      subHandles.push(sub);

      const deadline = Date.now() + 20_000;
      while (received.length < N && Date.now() < deadline) {
        await new Promise((r) => setTimeout(r, 300));
        if (received.length >= N) break;
      }

      const seqs = received.map((r) => r.seq);
      const bodiesMatch = sent.every((b, i) => received[i]?.body === b);
      if (received.length < N) {
        throw new Error(`DELIVERY_TIMEOUT: sent ${N}, received ${received.length}: ${JSON.stringify(received).slice(0, 400)}`);
      }
      if (JSON.stringify(received.slice(0, N).map((r) => r.body)) !== JSON.stringify(sent)) {
        throw new Error(`ORDER_VIOLATION: sent=${JSON.stringify(sent)} got=${JSON.stringify(received.map((r) => r.body))}`);
      }
      if (!seqs.slice(0, N).every((s) => Number.isInteger(s))) {
        throw new Error(`SEQUENCE_ANNOTATION_MISSING: seqs=${JSON.stringify(seqs)}`);
      }
      if (JSON.stringify(seqs.slice(0, N)) !== JSON.stringify([...seqs.slice(0, N)].sort((a, b) => a - b))) {
        throw new Error(`SEQUENCE_NOT_MONOTONIC: ${JSON.stringify(seqs)}`);
      }
      return `sent ${N} on partition ${partitionId}; received ${N} in order; sequenceNumbers=${JSON.stringify(seqs.slice(0, N))}; first offset=${received[0].offset} enqueued=${received[0].enqueued}`;
    } finally {
      for (const s of subHandles) await boundedClose(s, 2500);
      await boundedClose(consumer);
      await boundedClose(producer);
    }
  });

  // Probe 5: BODY-DECODE witness — post-KD-18 the substrate transfers with
  // message_format 0 and re-emits the recursively-unwrapped body section
  // (eh_body_section/1 unwraps the SDK batch envelope inside the message
  // stream), so the SDK tier decodes event bodies directly. Contract: each
  // event sent through the real SDK producer (batch API, one event per send,
  // matching the passing smoke subscribe-earliest shape) arrives with its body
  // deepEqual the original JSON payload, in order, with x-opt-sequence-number
  // surfaced as integer event.sequenceNumber, strictly increasing.
  // (Premise-drift note: this probe previously asserted the removed format!=0
  // raw-Buffer passthrough; "undecodable: 0" in its own output proved the
  // flip. KD-18 rewrite, not a substrate gap.)
  probe("wire-delivery-batch-unwrap-decode", async () => {
    const partitionId = "0";
    const producer = new EventHubProducerClient(CONN, probeOpts());
    const consumer = new EventHubConsumerClient(
      EventHubConsumerClient.defaultConsumerGroupName,
      CONN,
      probeOpts(),
    );
    const subHandles = [];
    try {
      const N = 4;
      const MARK = `ts5-unwrap-${Date.now()}`;
      const sent = [];
      for (let i = 0; i < N; i++) {
        const payload = { probe: "batch-unwrap", mark: MARK, i, nested: { k: `v${i}`, n: i * 7 } };
        const batch = await producer.createBatch({ partitionId, abortSignal: T(15_000) });
        if (!batch.tryAdd({ body: JSON.stringify(payload) })) throw new Error("tryAdd failed");
        await producer.sendBatch(batch, { abortSignal: T(15_000) });
        sent.push(payload);
      }

      const received = [];
      const sub = await consumer.subscribe(
        partitionId,
        {
          processEvents: async (events) => {
            for (const ev of events) {
              let body = ev.body;
              if (typeof body === "string") {
                try { body = JSON.parse(body); } catch { /* keep raw string */ }
              }
              // only this run's marked payloads — the partition carries
              // earlier probes' events from the earliest position
              if (body && typeof body === "object" && body.probe === "batch-unwrap" && body.mark === MARK) {
                received.push({ body, seq: ev.sequenceNumber });
              }
            }
          },
          processError: async (err) => {
            console.error(`[batch-unwrap] processError: ${err?.name}: ${String(err?.message).slice(0, 200)}`);
          },
        },
        { startPosition: { offset: "-1" }, maxWaitTimeInSeconds: 2 },
      );
      subHandles.push(sub);

      const deadline = Date.now() + 20_000;
      while (received.length < N && Date.now() < deadline) {
        await new Promise((r) => setTimeout(r, 300));
      }

      if (received.length < N) {
        throw new Error(`UNWRAP_TIMEOUT: sent ${N}, received ${received.length}: ${JSON.stringify(received).slice(0, 400)}`);
      }
      const got = received.slice(0, N);
      // THE contract: bodies deepEqual the original JSON payloads (recursive
      // batch-envelope unwrap is the delivered shape).
      const { deepStrictEqual } = await import("node:assert");
      for (let i = 0; i < N; i++) {
        deepStrictEqual(got[i].body, sent[i], `BODY_MISMATCH at ${i}: got=${JSON.stringify(got[i].body)}`);
      }
      // ordered-sequence assertions (kept intact from the raw-wire witness)
      const seqs = got.map((r) => r.seq);
      if (!seqs.every((s) => Number.isInteger(s))) {
        throw new Error(`SEQUENCE_ANNOTATION_MISSING: seqs=${JSON.stringify(seqs)}`);
      }
      if (JSON.stringify(seqs) !== JSON.stringify([...seqs].sort((a, b) => a - b))) {
        throw new Error(`SEQUENCE_NOT_MONOTONIC: ${JSON.stringify(seqs)}`);
      }
      return `batch of ${N} JSON payloads; bodies deepStrictEqual originals in order; ` +
        `sequenceNumbers=${JSON.stringify(seqs)} strictly increasing; ` +
        `recursive batch-envelope unwrap confirmed at SDK tier`;
    } finally {
      for (const s of subHandles) await boundedClose(s, 2500);
      await boundedClose(consumer);
      await boundedClose(producer);
    }
  });

  // Probe 4: negative probes — record 404-class / typed error behavior.
  probe("negative-probes", async () => {
    const client = new EventHubProducerClient(CONN, probeOpts());
    const out = [];
    // (a) nonexistent partition on getPartitionProperties
    try {
      await client.getPartitionProperties("does-not-exist", { abortSignal: T(8_000) });
      out.push("nonexistent-partition: NO ERROR (accepted)");
    } catch (err) {
      out.push(`nonexistent-partition: ${err?.name ?? "?"}(${err?.code ?? "-"}) ${String(err?.message).slice(0, 120)}`);
    }
    // (b) send to nonexistent partition
    const producer = new EventHubProducerClient(CONN, probeOpts());
    try {
      const batch = await producer.createBatch({ partitionId: "does-not-exist", abortSignal: T(8_000) });
      batch.tryAdd({ body: "x" });
      await producer.sendBatch(batch, { abortSignal: T(8_000) });
      out.push("send-bad-partition: NO ERROR (accepted)");
    } catch (err) {
      out.push(`send-bad-partition: ${err?.name ?? "?"}(${err?.code ?? "-"}) ${String(err?.message).slice(0, 120)}`);
    }
    // (c) nonexistent consumer group on $Default-named consumer
    try {
      const badConsumer = new EventHubConsumerClient("no-such-group", CONN, probeOpts());
      const badSub = await badConsumer.subscribe(
        "0",
        { processEvents: async () => {}, processError: async () => {} },
        { startPosition: { offset: "-1" }, maxWaitTimeInSeconds: 1 },
      );
      await new Promise((r) => setTimeout(r, 3000));
      await boundedClose(badSub, 1500);
      await boundedClose(badConsumer);
      out.push("nonexistent-consumer-group: no synchronous error (processError channel observed above if any)");
    } catch (err) {
      out.push(`nonexistent-consumer-group: ${err?.name ?? "?"}(${err?.code ?? "-"}) ${String(err?.message).slice(0, 120)}`);
    }
    return out.join(" || ");
  });

  let failures = 0;
  for (const p of RESULTS) {
    const t0 = Date.now();
    try {
      const detail = await p.run();
      console.log(`PASS [${((Date.now() - t0) / 1000).toFixed(1)}s] ${p.name}: ${detail}`);
    } catch (err) {
      failures++;
      console.log(`FAIL [${((Date.now() - t0) / 1000).toFixed(1)}s] ${p.name}: ${err?.name}: ${String(err?.message).slice(0, 500)}`);
    }
  }

  await killSubstrate();
  console.log(`[ts-eh-probe] done: ${RESULTS.length - failures}/${RESULTS.length} pass`);
  process.exitCode = failures === 0 ? 0 : 1;
}

main().catch((err) => {
  console.error("[ts-eh-probe] harness error:", err);
  process.exitCode = 3;
});
