#!/usr/bin/env node
/**
 * SPOF-4 court — browser-tab hardening (spofb-boundary-audit.md vector 4).
 *
 * Compiles the real engine closure (tab-lease / journal-sync / useJournal +
 * codec, snapback, receipt, merkle) with tsc to a private temp dir and runs
 * it against REAL collaborators:
 *
 *   - fake LockManager: a hand-written FIFO exclusive mutex (same shape as
 *     tab-lease-court's) — a real degraded Web Locks, not a call-counting mock
 *   - fake IndexedDB: hand-written store over plain Maps implementing the
 *     exact request/transaction surface journal-sync uses (getAll, get, put,
 *     delete, openCursor(null,"prev"), upgrade)
 *   - node's real BroadcastChannel for peer-tab presence (PeerGuard)
 *
 * Legs:
 *   1. SPOF-4.1 (a): two fallback tabs, peer detected → append typed-refused
 *      PEER_TAB_ACTIVE, no seqId minted; single-tab fallback still runs and
 *      discloses leaseMode "fallback" on the snapshot.
 *   2. SPOF-4.2 (b): master-tab death — survivor re-acquires the lease,
 *      rehydrate-on-promotion advances the stale horizon (currentSeq, frames,
 *      merkle root match a full replay), and the next append mints max+1.
 *   3. (c) regression: single-tab locked path — snapshot semantics identical
 *      (currentSeq/frames/root/leaseMode "locked").
 *   4. pure math: needsRehydrate / rehydratePlan / toSnapshotLeaseMode.
 *
 * Verdict `# PASS: n / # FAIL: n`; exit 0 iff zero FAIL.
 */

import { spawnSync } from "node:child_process";
import fs from "node:fs";
import path from "node:path";
import { createRequire } from "node:module";
import { fileURLToPath } from "node:url";

const WS_ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
let pass = 0;
let fail = 0;
function check(name, cond, detail) {
  if (cond) {
    pass++;
    console.log(`# PASS: ${name}`);
  } else {
    fail++;
    console.log(`# FAIL: ${name}${detail ? ` — ${JSON.stringify(detail)}` : ""}`);
  }
}

// --- compile the engine closure to CJS in a temp dir inside workspace --------
const tmp = fs.mkdtempSync(path.join(WS_ROOT, ".spof4-court-"));
const LIB = path.join(tmp, "lib");
fs.mkdirSync(path.join(LIB, "engine"), { recursive: true });
const ENGINE_FILES = [
  "tab-lease.ts",
  "journal-sync.ts",
  "useJournal.ts",
  "codec.ts",
  "snapback.ts",
  "receipt.ts",
  "merkle.ts",
];
for (const f of ENGINE_FILES) {
  fs.copyFileSync(path.join(WS_ROOT, "lib", "engine", f), path.join(LIB, "engine", f));
}
fs.copyFileSync(path.join(WS_ROOT, "lib", "smalt.ts"), path.join(LIB, "smalt.ts"));

const tsc = spawnSync(
  process.execPath,
  [
    path.join(WS_ROOT, "node_modules", "typescript", "bin", "tsc"),
    ...ENGINE_FILES.map((f) => path.join(LIB, "engine", f)),
    "--outDir",
    path.join(tmp, "out"),
    "--module",
    "commonjs",
    "--target",
    "es2020",
    "--esModuleInterop",
    "--skipLibCheck",
    "--lib",
    "es2020,dom",
    "--types",
    "node",
    "--ignoreConfig",
  ],
  { encoding: "utf8" },
);
if (tsc.status !== 0) {
  console.error(`# FAIL: tsc compile of engine closure\n${tsc.stdout}\n${tsc.stderr}`);
  fs.rmSync(tmp, { recursive: true, force: true });
  process.exit(1);
}

// --- collaborators: fake LockManager + fake IndexedDB ------------------------

/** FIFO exclusive mutex — the real degraded Web Locks collaborator. */
function installFakeLocks() {
  const held = new Set();
  const waiters = [];
  const release = () => {
    const next = waiters.shift();
    if (next) next();
    else held.delete("held");
  };
  const request = (name, optsOrCb, maybeCb) => {
    const granted = maybeCb ?? optsOrCb;
    return new Promise((resolve, reject) => {
      const run = () => {
        let done = false;
        const finish = (v) => {
          if (done) return;
          done = true;
          release();
          resolve(v);
        };
        granted({ name, mode: "exclusive" }).then(finish, (e) => {
          done = true;
          release();
          reject(e);
        });
      };
      if (!held.has("held")) {
        held.add("held");
        run();
      } else {
        waiters.push(run);
      }
    });
  };
  setNavigator({ locks: { request } });
  return { holding: () => held.has("held") };
}

/** Hand-written IndexedDB over Maps — the exact surface journal-sync uses. */
function installFakeIndexedDB() {
  const dbs = new Map();
  class FakeRequest {
    result;
    onsuccess = null;
    onerror = null;
  }
  function makeStore(db, name, keyPath) {
    const rows = new Map();
    const methods = {
      get(key) {
        const req = new FakeRequest();
        queueMicrotask(() => {
          req.result = rows.get(key);
          req.onsuccess?.();
        });
        return req;
      },
      getAll() {
        const req = new FakeRequest();
        queueMicrotask(() => {
          req.result = [...rows.values()];
          req.onsuccess?.();
        });
        return req;
      },
      put(valueOrValue, maybeKey) {
        const req = new FakeRequest();
        queueMicrotask(() => {
          if (keyPath) rows.set(valueOrValue[keyPath], valueOrValue);
          else rows.set(maybeKey, valueOrValue);
          req.result = maybeKey ?? valueOrValue[keyPath];
          req.onsuccess?.();
        });
        return req;
      },
      delete(key) {
        const req = new FakeRequest();
        queueMicrotask(() => {
          rows.delete(key);
          req.result = undefined;
          req.onsuccess?.();
        });
        return req;
      },
      openCursor(range, direction) {
        const req = new FakeRequest();
        queueMicrotask(() => {
          if (direction === "prev") {
            const keys = [...rows.keys()].sort((a, b) => b - a);
            req.result = keys.length ? { key: keys[0] } : null;
          } else {
            req.result = null;
          }
          req.onsuccess?.();
        });
        return req;
      },
    };
    db.stores.set(name, { keyPath, rows, methods });
    return methods;
  }
  const factory = {
    open(name, _version) {
      const req = new FakeRequest();
      const db = { stores: new Map() };
      dbs.set(name, db);
      req.result = {
        objectStoreNames: { contains: (s) => db.stores.has(s) },
        createObjectStore: (s, o) => makeStore(db, s, o?.keyPath),
        transaction: (_names) => {
          const tx = {
            objectStore: (s) => {
              const st = db.stores.get(s);
              if (!st) throw new Error(`no store ${s}`);
              return st.methods;
            },
          };
          // complete on a macrotask: every request microtask (and the
          // txDone oncomplete registration) has run by then
          setTimeout(() => tx.oncomplete?.(), 0);
          return tx;
        },
        close() {},
      };
      queueMicrotask(() => {
        req.onupgradeneeded?.({ target: req });
        req.onsuccess?.();
      });
      return req;
    },
  };
  globalThis.indexedDB = factory;
  return { dbs, segmentRows: () => dbs.get("smalt_local_ledger")?.stores.get("wal_segments").rows };
}

const fakeIdb = installFakeIndexedDB();

// crash-safe: never leave the temp compile dir behind on an unexpected throw
for (const ev of ["uncaughtException", "unhandledRejection"]) {
  process.on(ev, (e) => {
    console.error(`# FAIL: court crashed (${ev}): ${e?.stack ?? e}`);
    fs.rmSync(tmp, { recursive: true, force: true });
    process.exit(1);
  });
}

// --- load the compiled engine ------------------------------------------------
const req = createRequire(path.join(tmp, "out", "engine", "useJournal.js"));
const TL = req(path.join(tmp, "out", "engine", "tab-lease.js"));
const JS = req(path.join(tmp, "out", "engine", "journal-sync.js"));
const UJ = req(path.join(tmp, "out", "engine", "useJournal.js"));
const MERKLE = req(path.join(tmp, "out", "engine", "merkle.js"));

const { JournalSyncEngine, initialJournalSnapshot } = UJ;
const { withWalLease, PeerGuard } = TL;

/** Replay all stored frames through a fresh accumulator (ground truth root). */
async function replayRootFromStore() {
  const rows = fakeIdb.segmentRows();
  const acc = new MERKLE.Accumulator();
  const segs = [...rows.values()].sort((a, b) => a.seqId - b.seqId);
  for (const s of segs) await acc.append(new Uint8Array(s.frame));
  return { root: acc.rootHex(), count: segs.length };
}

const tick = (ms = 5) => new Promise((r) => setTimeout(r, ms));

/** Replace the (getter-only) global navigator wholesale. */
function setNavigator(value) {
  Object.defineProperty(globalThis, "navigator", {
    configurable: true,
    value,
  });
}

// --- leg 1: SPOF-4.1 — two fallback tabs, peer detected → typed refusal ------
{
  // No navigator.locks installed → fallback mode for every lease.
  setNavigator({});
  const guardA = new PeerGuard("tab-a");
  const engA = new JournalSyncEngine({ peerGuard: guardA });
  await engA.init();
  await engA.append(1n, 7, new Uint8Array([1]));
  check(
    "leg1: single fallback tab appends, leaseMode disclosed as fallback",
    engA.getSnapshot().leaseMode === "fallback" &&
      engA.getSnapshot().currentSeq === 1,
    engA.getSnapshot(),
  );

  // second tab appears
  const guardB = new PeerGuard("tab-b");
  const engB = new JournalSyncEngine({ peerGuard: guardB });
  await engB.init();
  const before = fakeIdb.segmentRows().size;
  await engB.append(1n, 7, new Uint8Array([2]));
  const afterRows = fakeIdb.segmentRows();
  check(
    "leg1: fallback append with live peer refused (phase SYNC_REFUSED_BY_SERVER)",
    engB.getSnapshot().phase === "SYNC_REFUSED_BY_SERVER",
    engB.getSnapshot(),
  );
  check(
    "leg1: refused append minted NO seqId (store size unchanged)",
    afterRows.size === before,
    { before, after: afterRows.size },
  );

  // direct wrapper-level refusal, typed PEER_TAB_ACTIVE with peer ids
  const r = await withWalLease(async () => "never", {
    refuseFallbackWithPeers: true,
    peerGuard: guardB,
  });
  check(
    "leg1: withWalLease fallback + peer typed-refuses PEER_TAB_ACTIVE",
    !r.ok && r.error.code === "PEER_TAB_ACTIVE" && r.error.peers.includes("tab-a"),
    r,
  );
  // read-only bodies are NOT peer-blocked (no refuseFallbackWithPeers)
  const ro = await withWalLease(async () => "readonly-ok", { peerGuard: guardB });
  check(
    "leg1: read-only fallback body still runs beside a live peer",
    ro.ok && ro.value === "readonly-ok" && ro.mode === "fallback",
    r,
  );

  // tab-a goes away; a fresh solo tab's fallback append is allowed (degraded)
  guardA.close();
  guardB.close();
  await tick(10);
  const guardSolo = new PeerGuard("tab-solo-fb");
  const rb = await withWalLease(async () => "solo", {
    refuseFallbackWithPeers: true,
    peerGuard: guardSolo,
  });
  check(
    "leg1: after peer death, single-tab fallback append is allowed again",
    rb.ok && rb.value === "solo",
    rb,
  );
  guardB.close();
  fakeIdb.segmentRows().clear();
}

// --- leg 2: SPOF-4.2 — master death, survivor rehydrates ----------------------
{
  installFakeLocks();
  const guardA = new PeerGuard("tab-a2");
  const guardB = new PeerGuard("tab-b2");
  const master = new JournalSyncEngine({ peerGuard: guardA });
  await master.init();
  for (let i = 1; i <= 5; i++) await master.append(9n, 1, new Uint8Array([i]));
  check(
    "leg2: master at seq 5 under web-locks",
    master.getSnapshot().currentSeq === 5 &&
      master.getSnapshot().leaseMode === "locked",
    master.getSnapshot(),
  );

  // survivor inits behind, then master appends past its horizon and "dies"
  const survivor = new JournalSyncEngine({ peerGuard: guardB });
  await survivor.init();
  check(
    "leg2: survivor initialized at seq 5 (stale horizon reproduced)",
    survivor.getSnapshot().currentSeq === 5,
    survivor.getSnapshot(),
  );
  for (let i = 6; i <= 10; i++) await master.append(9n, 1, new Uint8Array([i]));
  check(
    "leg2: dead master advanced the store to seq 10 while survivor snapshot sat at 5",
    fakeIdb.segmentRows().size === 10 && survivor.getSnapshot().currentSeq === 5,
    { store: fakeIdb.segmentRows().size, survivor: survivor.getSnapshot().currentSeq },
  );

  // master death = lock released; survivor's next leased call re-acquires.
  // Rehydrate-on-promotion must rebuild BEFORE the body mints a seq.
  await survivor.append(9n, 1, new Uint8Array([99]));
  const snap = survivor.getSnapshot();
  const truth = await replayRootFromStore();
  check(
    "leg2: survivor rehydrated — currentSeq advanced to the next free seq (11)",
    snap.currentSeq === 11,
    snap,
  );
  check(
    "leg2: survivor frames trail covers 1..11 after promotion",
    snap.frames.join(",") === "1,2,3,4,5,6,7,8,9,10,11",
    snap.frames,
  );
  check(
    "leg2: survivor accumulatorRoot matches a full replay of all 11 stored frames",
    snap.accumulatorRoot === truth.root && truth.count === 11,
    { snapRoot: snap.accumulatorRoot, truthRoot: truth.root, count: truth.count },
  );
  check(
    "leg2: unsyncedCount reflects the full un-acked horizon",
    snap.unsyncedCount === 11,
    snap,
  );
  guardA.close();
  guardB.close();
  fakeIdb.segmentRows().clear();
}

// --- leg 3: regression — single-tab locked path unchanged ---------------------
{
  installFakeLocks();
  const guard = new PeerGuard("tab-solo");
  const eng = new JournalSyncEngine({ peerGuard: guard });
  await eng.init();
  for (let i = 1; i <= 3; i++) await eng.append(5n, 2, new Uint8Array([i, i]));
  const snap = eng.getSnapshot();
  const truth = await replayRootFromStore();
  check(
    "leg3: single-tab locked snapshot byte-identical semantics",
    snap.ready === true &&
      snap.phase === "COMMITTED_LOCAL" &&
      snap.currentSeq === 3 &&
      snap.frames.join(",") === "1,2,3" &&
      snap.unsyncedCount === 3 &&
      snap.leaseMode === "locked" &&
      snap.accumulatorRoot === truth.root,
    { snap, truthRoot: truth.root },
  );
  // lease still serializes: overlapping appends stay contiguous
  await Promise.all([
    eng.append(5n, 2, new Uint8Array([4])),
    eng.append(5n, 2, new Uint8Array([5])),
  ]);
  check(
    "leg3: overlapping appends under one lease stay contiguous (4,5)",
    eng.getSnapshot().currentSeq === 5 &&
      eng.getSnapshot().frames.join(",") === "1,2,3,4,5",
    eng.getSnapshot(),
  );
  guard.close();
  fakeIdb.segmentRows().clear();
}

// --- leg 4: pure rehydrate math (node-testable split) -------------------------
{
  const { needsRehydrate, rehydratePlan } = JS;
  check(
    "leg4: needsRehydrate true only when store is ahead",
    needsRehydrate(5, 5) === false && needsRehydrate(5, 10) === true && needsRehydrate(10, 5) === false,
  );
  const plan = rehydratePlan(
    { currentSeq: 10, unsyncedCount: 10, frames: Array.from({ length: 10 }, () => new Uint8Array(11)) },
    7,
  );
  check(
    "leg4: rehydratePlan maps hydration to the snapshot patch",
    plan.currentSeq === 10 && plan.ackedTo === 7 && plan.unsyncedCount === 10 &&
      plan.frames.join(",") === "1,2,3,4,5,6,7,8,9,10",
    plan,
  );
  const { toSnapshotLeaseMode } = TL;
  check(
    "leg4: toSnapshotLeaseMode maps web-locks→locked, fallback→fallback",
    toSnapshotLeaseMode("web-locks") === "locked" && toSnapshotLeaseMode("fallback") === "fallback",
  );
  check(
    "leg4: initial snapshot discloses leaseMode unknown",
    initialJournalSnapshot().leaseMode === "unknown",
  );
}

// --- verdict ------------------------------------------------------------------
console.log(`# PASS: ${pass}`);
console.log(`# FAIL: ${fail}`);
fs.rmSync(tmp, { recursive: true, force: true });
process.exit(fail === 0 ? 0 : 1);
