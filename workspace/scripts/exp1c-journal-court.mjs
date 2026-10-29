#!/usr/bin/env node
// EXP1C journal-sync / useSovereignTerminal repair court. Plain node, no new
// deps. Conventions follow sync-e2e-court.mjs / codec-court.mjs: byte-copied
// engine sources into an OS temp dir (relative imports rewritten to `.ts`),
// real store state via the tracked IndexedDB shim
// (workspace/scripts/bk83/idb-shim.mjs — the W2-relocated collaborator; no
// /tmp dependency, fresh-clone runnable).
//
// Legs:
//   L1 W3  ensureClientId mints once, persists in sync_cursor, nonzero u64
//   L2 W3  appendLocal threads the persisted identity into frame + segment
//   L3 W4  gap falsifier: ledger {1,2,4}, lastSeq=3 -> typed gap refusal
//          (old code sliced by array index and verified the wrong chain)
//   L4 W4  deleteSeqIds reports REAL deletion counts (get-then-delete):
//          snapback purged matches rows actually gone; rows below the new
//          cursor survive
//   L5 W5  a failed open does not negative-cache: dbPromise resets, retry
//          succeeds (old code bricked the journal for the page lifetime)
//   L6 W5  onblocked -> typed STORE_FAILURE (and the retry still recovers)
//   L7 W5  withWalLease removes its external-signal abort listener on release
//   L8 W8  dead wrappers markSynced/snapbackStoreOps are gone; rehydratePlan
//          prefers real stored seqIds over index numbers
//   L9 F1  concurrent first boot: two simultaneous ensureClientId calls end
//          on ONE persisted identity (old code minted distinct u64s)
//   L10 F2 entries/frames mismatch fallback is loud (warn), no-entries
//          fallback stays quiet
//
// Exit 0 pass / 1 fail.

import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { getEventListeners } from "node:events";
import { fileURLToPath, pathToFileURL } from "node:url";

const ROOT = path.resolve(fileURLToPath(import.meta.url), "../../..");
const { installIdbShim } = await import(
  new URL("./bk83/idb-shim.mjs", import.meta.url).href
);

// Byte-copy engine sources to scratch with `.ts` appended to relative import
// specifiers (extensionless in lib for the bundler; node type-stripping needs
// the extension). `tag` separates module worlds: scratch2 gets a fresh
// module-level dbPromise for the openDb legs.
function genEngineScratch(tag) {
  const out = fs.mkdtempSync(path.join(os.tmpdir(), `exp1c-${tag}-`));
  fs.mkdirSync(path.join(out, "engine"), { recursive: true });
  const files = [
    "codec.ts",
    "journal-sync.ts",
    "merkle.ts",
    "receipt.ts",
    "snapback.ts",
    "tab-lease.ts",
  ];
  for (const f of files) {
    let src = fs.readFileSync(path.join(ROOT, "workspace/lib/engine", f), "utf8");
    src = src.replace(
      /from "((?:\.\/|\.\.\/)[a-z-]+)"/g,
      (_m, spec) => `from "${spec}.ts"`
    );
    // World 2 imports the same journal-sync source; nothing special needed —
    // a separate scratch dir gives a separate module instance.
    fs.writeFileSync(path.join(out, "engine", f), src);
  }
  const smaltSrc = fs.readFileSync(path.join(ROOT, "workspace/lib/smalt.ts"), "utf8");
  const smaltRewritten = smaltSrc.replace(
    /from "((?:\.\/|\.\.\/)[a-z-]+)"/g,
    (_m, spec) => `from "${spec}.ts"`
  );
  fs.writeFileSync(path.join(out, "smalt.ts"), smaltRewritten);
  return out;
}

const R = [];
function ok(name, cond, detail) {
  R.push(cond);
  const v = cond ? "PASS" : "FAIL";
  console.log(`[${v}] ${name} :: ${detail}`);
}

async function main() {
  installIdbShim();
  const w1 = genEngineScratch("w1");
  const w2 = genEngineScratch("w2");
  const w3 = genEngineScratch("w3");
  const W1 = path.join(w1, "engine");
  const W2 = path.join(w2, "engine");
  const W3 = path.join(w3, "engine");

  // Direct shim-store access for seeding/inspecting final court state (real
  // rows, asserted after the real engine path ran over them).
  function rawDb() {
    return new Promise((res) => {
      const rq = globalThis.indexedDB.open("smalt_local_ledger", 1);
      rq.onupgradeneeded = () => {
        const db = rq.result;
        if (!db.objectStoreNames.contains("wal_segments"))
          db.createObjectStore("wal_segments", { keyPath: "seqId" });
        if (!db.objectStoreNames.contains("sync_cursor"))
          db.createObjectStore("sync_cursor");
      };
      rq.onsuccess = () => res(rq.result);
    });
  }
  async function rawClear() {
    const db = await rawDb();
    for (const store of ["wal_segments", "sync_cursor"]) {
      const tx = db.transaction([store], "readwrite");
      const st = tx.objectStore(store);
      const rows = await new Promise((res) => {
        const r = st.getAll();
        r.onsuccess = () => res(r.result);
      });
      if (store === "wal_segments") {
        for (const row of rows) st.delete(row.seqId);
      }
      // the shim's cursor store uses out-of-line keys; sweep the known set
      for (const k of ["cursor", "clientId"]) st.delete(k);
      await new Promise((res, rej) => {
        tx.oncomplete = res;
        tx.onerror = () => rej(tx.error);
        tx.onabort = () => rej(tx.error);
      });
    }
  }
  async function rawSeedSegments(rows) {
    const db = await rawDb();
    const tx = db.transaction(["wal_segments"], "readwrite");
    const st = tx.objectStore("wal_segments");
    for (const r of rows) st.put(r.seg, r.seq);
    await new Promise((res, rej) => {
      tx.oncomplete = res;
      tx.onerror = () => rej(tx.error);
      tx.onabort = () => rej(tx.error);
    });
  }
  async function rawSetCursor(seq) {
    const db = await rawDb();
    const tx = db.transaction(["sync_cursor"], "readwrite");
    tx.objectStore("sync_cursor").put(seq, "cursor");
    await new Promise((res, rej) => {
      tx.oncomplete = res;
      tx.onerror = () => rej(tx.error);
      tx.onabort = () => rej(tx.error);
    });
  }
  async function rawCursor(key = "cursor") {
    const db = await rawDb();
    const tx = db.transaction(["sync_cursor"], "readonly");
    const v = await new Promise((res) => {
      const r = tx.objectStore("sync_cursor").get(key);
      r.onsuccess = () => res(r.result);
    });
    return v;
  }
  async function rawSeqIds() {
    const db = await rawDb();
    const tx = db.transaction(["wal_segments"], "readonly");
    const rows = await new Promise((res) => {
      const r = tx.objectStore("wal_segments").getAll();
      r.onsuccess = () => res(r.result);
    });
    return rows.map((s) => s.seqId).sort((a, b) => a - b);
  }

  async function main2() {
    const J = await import(pathToFileURL(path.join(W1, "journal-sync.ts")).href);
    const C = await import(pathToFileURL(path.join(W1, "codec.ts")).href);
    const TL = await import(pathToFileURL(path.join(W1, "tab-lease.ts")).href);
    const J2 = await import(pathToFileURL(path.join(W2, "journal-sync.ts")).href);
    const J3 = await import(pathToFileURL(path.join(W3, "journal-sync.ts")).href);

    // --- L1: W3 clientId identity -------------------------------------------
    await rawClear();
    const c1 = await J.ensureClientId();
    const c1b = await J.ensureClientId();
    ok(
      "w3.clientid-mint-once-persisted",
      c1.ok && c1b.ok && c1.value > 0n && c1.value === c1b.value,
      `first=${c1.ok ? c1.value : "-"} second=${c1b.ok ? c1b.value : "-"}`
    );
    const storedCid = await rawCursor("clientId");
    ok(
      "w3.clientid-in-sync-cursor-store",
      typeof storedCid === "string" && /^[0-9]+$/.test(storedCid) && BigInt(storedCid) === c1.value,
      `stored=${storedCid}`
    );
    // fresh world (wiped identity): a different nonzero u64
    const db1 = await rawDb();
    await new Promise((res, rej) => {
      const tx = db1.transaction(["sync_cursor"], "readwrite");
      tx.objectStore("sync_cursor").delete("clientId");
      tx.oncomplete = res;
      tx.onerror = () => rej(tx.error);
    });
    const c2 = await J.ensureClientId();
    ok(
      "w3.fresh-world-mints-distinct-nonzero",
      c2.ok && c2.value > 0n && c2.value !== c1.value,
      `first=${c1.value} fresh=${c2.ok ? c2.value : "-"}`
    );

    // --- L2: W3 append threads the persisted identity ------------------------
    await rawClear();
    const cid = await J.ensureClientId();
    if (!cid.ok) throw new Error("ensureClientId failed");
    const ap = await J.appendLocal(cid.value, 1, new TextEncoder().encode("exp1c-l2"));
    const hyd = await J.hydrate();
    ok(
      "w3.append-carries-clientid",
      ap.ok && ap.value.clientId === cid.value.toString(),
      `segment.clientId=${ap.ok ? ap.value.clientId : "-"} persisted=${cid.value}`
    );
    ok(
      "w4.hydrate-entries-carry-seqids",
      hyd.ok &&
        hyd.value.entries.length === hyd.value.frames.length &&
        hyd.value.entries[0].seqId === ap.value.seqId &&
        hyd.value.entries[0].frame.length === ap.value.frame.byteLength,
      `entries=${hyd.ok ? JSON.stringify(hyd.value.entries.map((e) => e.seqId)) : "-"}`
    );

    // --- L3: W4 gap falsifier ------------------------------------------------
    // Seed ledger seqIds {1,2,4}, ack cursor 3. The server acks lastSeq=3
    // (cumulative per-client chain). OLD code sliced frames[0..2] by INDEX
    // and fed the wrong frames to verifyReceipt. NEW code walks the acked
    // seqIds, finds 3 missing, refuses typed BEFORE any verify.
    await rawClear();
    const seedFrames = [1, 2, 4].map((seq) => ({
      seq,
      seg: {
        seqId: seq,
        clientId: "7",
        ts: Date.now(),
        op: 1,
        payload: new Uint8Array([seq]).buffer,
        frame: C.encodeFrame(7n, BigInt(seq), BigInt(Date.now()), 1, new Uint8Array([seq])).slice().buffer,
        acked: true,
      },
    }));
    await rawSeedSegments(seedFrames);
    await rawSetCursor(3);
    const realFetch = globalThis.fetch;
    globalThis.fetch = async () => ({
      ok: true,
      status: 200,
      json: async () => ({ lastSeq: 3, receiptToken: "ab".repeat(320) }),
    });
    const gap = await J.flushSync();
    globalThis.fetch = realFetch;
    ok(
      "w4.gap-typed-refusal-not-wrong-chain-verify",
      gap.ok === false &&
        gap.error.code === "SYNC_REFUSED" &&
        /gap/.test(gap.error.detail) &&
        /seqId 3/.test(gap.error.detail),
      `ok=${gap.ok} code=${gap.ok ? "-" : gap.error.code} detail=${gap.ok ? "-" : gap.error.detail}`
    );

    // --- L4: W4 real deletion counts through the snapback path ----------------
    // Seed {1,2,4}, cursor 1 -> unacked {2,4}. A server refusal at head 0
    // purges the unacked set; the purged count must equal the rows ACTUALLY
    // gone (2), and the row below the cursor (seqId 1) must survive.
    await rawClear();
    await rawSeedSegments(seedFrames);
    await rawSetCursor(1);
    globalThis.fetch = async () => ({
      ok: false,
      status: 409,
      json: async () => ({ refusal: "exp1c-leg4", serverHeadSeq: 0 }),
    });
    const sb = await J.flushSync();
    globalThis.fetch = realFetch;
    const seqAfter = await rawSeqIds();
    const curAfter = await rawCursor("cursor");
    ok(
      "w4.deleteSeqIds-real-counts",
      sb.ok === false &&
        sb.error.code === "SYNC_REFUSED_BY_SERVER" &&
        sb.error.purged === 2 &&
        seqAfter.join(",") === "1" &&
        curAfter === 0,
      `purged=${sb.ok ? "-" : sb.error.purged} remaining=[${seqAfter}] cursor=${curAfter}`
    );

    // --- L5: W5 failed open does not negative-cache --------------------------
    // Fresh module world (w2, pristine dbPromise). Wrap indexedDB.open to
    // fail the FIRST open only; the retry must succeed (old code: every op
    // for the page lifetime refused STORE_FAILURE).
    let failFirst = true;
    const realIdb = globalThis.indexedDB;
    globalThis.indexedDB = {
      open(name, version) {
        if (failFirst) {
          failFirst = false;
          const r = { onsuccess: null, onerror: null, onupgradeneeded: null, onblocked: null };
          queueMicrotask(() => {
            if (r.onerror) r.onerror({ target: { error: new Error("exp1c injected open failure") } });
          });
          return r;
        }
        return realIdb.open(name, version);
      },
    };
    const h5a = await J2.hydrate();
    const h5b = await J2.hydrate();
    globalThis.indexedDB = realIdb;
    ok(
      "w5.failed-open-retry-succeeds",
      h5a.ok === false && h5a.error.code === "STORE_FAILURE" && h5b.ok === true,
      `first=${h5a.ok ? "ok" : h5a.error.code} retry=${h5b.ok ? "ok" : h5b.error.code}`
    );

    // --- L6: W5 onblocked -> typed refusal, retry still recovers -------------
    let blockOnce = true;
    globalThis.indexedDB = {
      open(name, version) {
        if (blockOnce) {
          blockOnce = false;
          const r = { onsuccess: null, onerror: null, onupgradeneeded: null, onblocked: null };
          queueMicrotask(() => {
            if (r.onblocked) r.onblocked({ target: r });
          });
          return r;
        }
        return realIdb.open(name, version);
      },
    };
    const h6a = await J3.hydrate();
    const h6b = await J3.hydrate();
    globalThis.indexedDB = realIdb;
    ok(
      "w5.onblocked-typed-refusal",
      h6a.ok === false &&
        h6a.error.code === "STORE_FAILURE" &&
        /blocked/.test(h6a.error.detail) &&
        h6b.ok === true,
      `first=${h6a.ok ? "ok" : h6a.error.code} detail=${h6a.ok ? "-" : h6a.error.detail} retry=${h6b.ok ? "ok" : h6b.error.code}`
    );

    // --- L7: W5 abort-listener leak -------------------------------------------
    // After withWalLease releases (body settled), the caller's external
    // signal must carry ZERO abort listeners (old code leaked one per call
    // for the page lifetime). Assert against the real listener registry.
    {
      const ac = new AbortController();
      const before = getEventListeners(ac.signal, "abort").length;
      const r = await TL.withWalLease(async () => 42, { signal: ac.signal });
      const after = getEventListeners(ac.signal, "abort").length;
      ok(
        "w5.wal-lease-abort-listener-removed",
        r.ok && r.value === 42 && before === 0 && after === 0,
        `ok=${r.ok} listeners-before=${before} listeners-after=${after}`
      );
    }

    // --- L8: W8 dead wrappers gone + entries-aware rehydratePlan --------------
    ok(
      "w8.dead-wrappers-deleted",
      J.markSynced === undefined && J.snapbackStoreOps === undefined,
      `markSynced=${String(J.markSynced)} snapbackStoreOps=${String(J.snapbackStoreOps)}`
    );
    {
      const plan = J.rehydratePlan(
        {
          currentSeq: 4,
          unsyncedCount: 1,
          frames: [new Uint8Array(11), new Uint8Array(11), new Uint8Array(11)],
          entries: [{ seqId: 1 }, { seqId: 2 }, { seqId: 4 }],
        },
        3,
      );
      ok(
        "w8.rehydratePlan-prefers-stored-seqids",
        plan.frames.join(",") === "1,2,4",
        `frames=${plan.frames.join(",")}`
      );
      const planIdx = J.rehydratePlan(
        {
          currentSeq: 2,
          unsyncedCount: 2,
          frames: [new Uint8Array(11), new Uint8Array(11)],
        },
        0,
      );
      ok(
        "w8.rehydratePlan-index-fallback-intact",
        planIdx.frames.join(",") === "1,2",
        `frames=${planIdx.frames.join(",")}`
      );
    }

    // --- L9 (WSKEP-R1 F1): concurrent first boot mints ONE identity ---------
    // BK-WSKEP F1: two concurrent ensureClientId calls on a fresh store used
    // to mint DISTINCT u64s (read tx + write tx, last-writer-wins); the race
    // loser signed frames with a non-persisted clientId. Fixed: the whole
    // read-mint-write runs through one FIFO turnstile + a single readwrite
    // transaction. Two simultaneous first-boot callers must end on the SAME,
    // persisted identity.
    await rawClear();
    const [f1a, f1b] = await Promise.all([J.ensureClientId(), J.ensureClientId()]);
    const f1c = await J.ensureClientId();
    const f1Stored = await rawCursor("clientId");
    ok(
      "f1.concurrent-first-boot-single-identity",
      f1a.ok &&
        f1b.ok &&
        f1c.ok &&
        f1a.value > 0n &&
        f1a.value === f1b.value &&
        f1c.value === f1a.value &&
        typeof f1Stored === "string" &&
        /^[0-9]+$/.test(f1Stored) &&
        BigInt(f1Stored) === f1a.value,
      `a=${f1a.ok ? f1a.value : "-"} b=${f1b.ok ? f1b.value : "-"} posthoc=${f1c.ok ? f1c.value : "-"} stored=${f1Stored}`,
    );

    // --- L10 (WSKEP-R1 F2): entries/frames mismatch fallback is LOUD ---------
    // The entries-present-but-short shape must still produce the plan (no
    // caller can produce it today) but MUST log the fallback — silent drift
    // may not hide behind the index path.
    {
      const realWarn = console.warn;
      let warned = "";
      console.warn = (m) => {
        warned = String(m);
      };
      try {
        const planLoud = J.rehydratePlan(
          {
            currentSeq: 5,
            unsyncedCount: 2,
            frames: [new Uint8Array(11), new Uint8Array(11), new Uint8Array(11)],
            entries: [{ seqId: 1 }, { seqId: 2 }],
          },
          3,
        );
        ok(
          "f2.entries-frames-mismatch-fallback-is-loud",
          planLoud.frames.join(",") === "1,2,3" &&
            /entries\.length \(2\) !== frames\.length \(3\)/.test(warned),
          `frames=${planLoud.frames.join(",")} warn=${warned || "-none-"}`,
        );
      } finally {
        console.warn = realWarn;
      }
      // the no-entries caller shape stays quiet (court-idiom fallback intact)
      const realWarn2 = console.warn;
      let quiet = true;
      console.warn = () => {
        quiet = false;
      };
      try {
        J.rehydratePlan(
          { currentSeq: 2, unsyncedCount: 2, frames: [new Uint8Array(11), new Uint8Array(11)] },
          0,
        );
        ok("f2.no-entries-fallback-stays-quiet", quiet, `warned=${!quiet}`);
      } finally {
        console.warn = realWarn2;
      }
    }

    const pass = R.filter(Boolean).length;
    const total = R.length;
    console.log(`SUMMARY: ${pass}/${total} PASS, ${total - pass} FAIL`);
    process.exit(pass === total ? 0 : 1);
  }

  await main2();
}

main().catch((e) => {
  console.error("COURT CRASH:", e);
  process.exit(1);
});
