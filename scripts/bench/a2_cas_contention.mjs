// A-2 SDK-tier: high-contention optimistic CAS over the smalt Cosmos NoSQL wire
// (If-Match etag replace via @azure/cosmos), mirroring the BEAM-tier lane.
// Run: node scripts/bench/a2_cas_contention.mjs  (smalt egress on :PORT, env EGRESS_URL)
// For N in {10,100,1000}: N concurrent conditional replaces racing with the
// SAME etag per round. Exactly one 200, N-1 get 412 PreconditionFailed (the
// billed-retry analog). Zero-phantom proof: after each round the item is read
// back; value must be previous+1.

import { createRequire } from "node:module";
import crypto from "node:crypto";
const require2 = createRequire(new URL("../../verification/ts/package.json", import.meta.url));
const { CosmosClient } = require2("@azure/cosmos");

const ENDPOINT = process.env.EGRESS_URL || "http://127.0.0.1:8443";
const MASTER_KEY = crypto.randomBytes(32).toString("hex");
const client = new CosmosClient({
  endpoint: ENDPOINT,
  key: MASTER_KEY,
  retryOptions: { maxRetryAttemptCount: 0 },
  connectionPolicy: { enableEndpointsDiscovery: false },
});

const results = [];
function emit(o) {
  results.push(o);
  console.log(JSON.stringify(o));
}

const dbId = `a2db-${Date.now()}`;
const { database } = await client.databases.createIfNotExists({ id: dbId });
const { container } = await database.containers.createIfNotExists({ id: "c1", partitionKey: { paths: ["/pk"] } });
emit({ lane: "a2", tier: "sdk", op: "meta", endpoint: ENDPOINT, db: dbId });

const Ns = [10, 100, 1000];
const ROUNDS = 5;

for (const N of Ns) {
  for (let r = 1; r <= ROUNDS; r++) {
    const pk = `p-${N}-${r}`;
    await container.items.create({ id: `doc-${pk}`, pk, value: 0, winner: null });
    const read = await container.item(`doc-${pk}`, pk).read();
    const base = read.resource.value;
    const etag = read.resource._etag;

    const lat = [];
    if (!globalThis.__a2lats) globalThis.__a2lats = {};
    if (!globalThis.__a2lats[N]) globalThis.__a2lats[N] = [];
    let ok = 0, c412 = 0, other = 0;
    const t0 = performance.now();

    await Promise.all(
      Array.from({ length: N }, () =>
        container.item(`doc-${pk}`, pk)
          .replace(
            { id: `doc-${pk}`, pk, value: base + 1, winner: crypto.randomUUID() },
            { accessCondition: { type: "IfMatch", condition: etag } }
          )
          .then((resp) => {
            const d = performance.now() - t0;
            lat.push(d);
            if (resp.statusCode === 200) ok++;
            else if (resp.statusCode === 412) c412++;
            else other++;
          })
          .catch((e) => {
            const d = performance.now() - t0;
            lat.push(d);
            if (e.code === 412 || e?.body?.code === "PreconditionFailed") c412++;
            else other++;
          })
      )
    );

    globalThis.__a2lats[N].push(...lat);
    const after = await container.item(`doc-${pk}`, pk).read();
    const value_after = after.resource.value;
    const phantom = value_after !== base + 1;

    emit({
      lane: "a2", tier: "sdk", op: "cas_contention", n: N, round: r,
      winners: ok, conflicts_412: c412, unexpected: other, phantom_overwrites: phantom ? 1 : 0,
      value_after, expected_after: base + 1,
      round_ms: +(performance.now() - t0).toFixed(1),
    });
  }

  // aggregate row for this N
  const rows = results.filter((x) => x.op === "cas_contention" && x.n === N);
  const lats = [];
  // (per-attempt latencies are collected above per round; approximate aggregate from round_ms)
  const s = rows.reduce(
    (a, x) => ({ w: a.w + x.winners, c: a.c + x.conflicts_412, u: a.u + x.unexpected, ph: a.ph + x.phantom_overwrites, ms: a.ms + x.round_ms }),
    { w: 0, c: 0, u: 0, ph: 0, ms: 0 }
  );
  const attempts = N * ROUNDS;
  const lv = globalThis.__a2lats[N].sort((a, b) => a - b);
  const at = (p) => +lv[Math.round(p / 100 * (lv.length - 1))].toFixed(1);
  emit({
    lane: "a2", tier: "sdk", op: "cas_contention_agg", n: N, rounds: ROUNDS, attempts,
    winners: s.w, conflicts_412: s.c, unexpected: s.u, phantom_overwrites: s.ph,
    exactly_one_winner_per_round: s.w === ROUNDS && s.c === attempts - ROUNDS && s.ph === 0 && s.u === 0,
    attempts_per_success: +(attempts / Math.max(s.w, 1)).toFixed(2),
    attempts_per_sec: +(attempts / (s.ms / 1000)).toFixed(0),
    p50_ms: at(50), p95_ms: at(95), p99_ms: at(99),
    max_inflight_ms: +lv[lv.length - 1].toFixed(1),
  });
}

const { resource: finalDoc } = await container.item(`doc-p-1000-1`, "p-1000-1").read();
emit({ lane: "a2", tier: "sdk", op: "done" });
try {
  await container.delete();
  await database.delete();
} catch (e) {
  console.log(JSON.stringify({ lane: "a2", tier: "sdk", op: "cleanup_err", code: e.code ?? null, msg: String(e.message ?? "").slice(0, 120) }));
}
