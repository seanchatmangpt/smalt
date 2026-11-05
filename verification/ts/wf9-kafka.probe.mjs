// wf9-kafka.probe.mjs — HC lane: real kafkajs 2.2.4 roundtrip against the
// smalt AZ-1 Kafka face on a lane-private substrate (block v10, 7-slot port
// block 39800-39806, kafka at +6 via bootPrivate's put_env injection).
//   node verification/ts/wf9-kafka.probe.mjs
// Override: SMALT_WF9_BOOTSTRAP=127.0.0.1:PORT attaches to an already-listening
// Kafka face (no boot) — used when another lane holds the shared compile red.
// rc: 0 pass / 1 real wire-or-client failure (KD candidate, printed verbatim)
//     / 2 substrate never up / 3 kafkajs absent (loud skip).
import { createRequire } from "node:module";
import net from "node:net";
import path from "node:path";
import { bootPrivate, down } from "./harness/substrate.ts";

let Kafka;
try {
  Kafka = createRequire(path.join(import.meta.dirname, "package.json"))("kafkajs").Kafka;
} catch {
  console.log("WF9 SKIP-LOUD rc=3: kafkajs absent — npm install in verification/ts");
  process.exit(3);
}

const TOPIC = "wf9-ts-topic";
const bootstrapEnv = process.env.SMALT_WF9_BOOTSTRAP;
let rc = 0;
let booted = null;
let broker;

const tryConnect = (port) =>
  new Promise((resolve) => {
    const s = net.connect({ host: "127.0.0.1", port, timeout: 1000 });
    s.once("connect", () => { s.destroy(); resolve(true); });
    s.once("timeout", () => { s.destroy(); resolve(false); });
    s.once("error", () => resolve(false));
  });

if (bootstrapEnv) {
  broker = bootstrapEnv;
  const [host, port] = bootstrapEnv.split(":");
  if (!(await tryConnect(Number(port)))) {
    console.log(`FAIL substrate: SMALT_WF9_BOOTSTRAP ${bootstrapEnv} not listening`);
    process.exit(2);
  }
  console.log(`attach mode: kafka face at ${broker} (no boot)`);
} else {
  try {
    booted = await bootPrivate("v10", "", "enforce");
    broker = `127.0.0.1:${booted.ports[6]}`;
    console.log(`substrate v10 up pid=${booted.pid} kafka=${broker}`);
  } catch (e) {
    console.log(`FAIL substrate: ${e.message}`);
    process.exit(2);
  }
}

try {
  const kafka = new Kafka({
    clientId: "wf9-ts",
    brokers: [broker],
    // KAFKAJS_DEBUG=1 -> wire-level debug lines for KD-candidate receipts
    logLevel: process.env.KAFKAJS_DEBUG ? 5 : 2,
  });

  // produce
  const producer = kafka.producer();
  await producer.connect();
  const produced = [];
  for (let i = 0; i < 10; i++) {
    const payload = `wf9-ts-msg-${String(i).padStart(2, "0")}`;
    produced.push(payload);
    await producer.send({
      topic: TOPIC,
      messages: [{ key: `k${i}`, value: Buffer.from(payload) }],
    });
  }
  await producer.disconnect();
  console.log(`PASS produce: 10 msgs -> ${TOPIC}`);

  // consume via consumer group
  const consumer = kafka.consumer({ groupId: "wf9-ts-group", sessionTimeout: 10000, heartbeatInterval: 2000 });
  await consumer.connect();
  const got = [];
  let done;
  const finished = new Promise((r) => { done = r; });
  await consumer.subscribe({ topic: TOPIC, fromBeginning: true });
  await consumer.run({
    eachBatchAutoResolve: true,
    eachBatch: async ({ batch }) => {
      for (const m of batch.messages) {
        got.push(m.value.toString());
        if (got.length >= produced.length) done();
      }
    },
  });
  const deadline = Date.now() + 60000;
  while (got.length < produced.length && Date.now() < deadline) {
    await new Promise((r) => setTimeout(r, 250));
  }
  if (got.length < produced.length) {
    throw new Error(`CONSUME_SHORT: got ${got.length}/${produced.length} in 60s`);
  }
  console.log(`PASS consume via group: ${got.length} msgs ${got[0]}..${got[got.length - 1]}`);
  await consumer.disconnect();
} catch (e) {
  console.log(`FAIL kafkajs leg: ${e.message}`);
  if (e.stack) console.log(e.stack.split("\n").slice(0, 4).join("\n"));
  rc = 1;
}
if (booted) await down("v10", "owner");
console.log(`WF9 rc=${rc}`);
process.exit(rc);
