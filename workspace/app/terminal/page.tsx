"use client";

/**
 * ATH-2 sovereign console — browser-side client surface.
 *
 * The page is pure projection: every selector on the DOM is driven by real
 * engine state through the pattern hooks (14 Ambient Cord, 15 Persistent
 * Worker Pin, 16 Reactive Hearth, 19 derived status machine). No local
 * source of truth lives here — the journal, the worker pin, and the andon
 * cord own the state; this tree renders it. Egress rides smaltFetch
 * exclusively inside journal-sync (air-gap law).
 */

import { useEffect, useRef, useState } from "react";
import { AndonProvider, useAndon } from "@/lib/engine/useAndon";
import { globalJournalEngine } from "@/lib/engine/useJournal";
import { lawWorkerBridge } from "@/lib/engine/law-worker-bridge";
import { renderReceiptFields } from "@/lib/engine/receipt";
import { useSovereignTerminal } from "@/lib/engine/useSovereignTerminal";

/** Default reticle: generic graph mechanics (s/p/o), no domain semantics. */
const DEFAULT_RETICLE = [
  "@prefix sh: <http://www.w3.org/ns/shacl#> .",
  "<urn:r0> a sh:NodeShape ;",
  "  sh:targetNode <urn:s> ;",
  "  sh:property [ sh:path <urn:p> ; sh:minCount 1 ] .",
].join("\n");

const DEFAULT_BYTES = "<urn:s> <urn:p> <urn:o> .";

function statusTone(p: string): string {
  if (p === "HALTED_BY_SIEVE") return "#b91c1c";
  if (p === "SYNC_REFUSED_BY_SERVER") return "#b45309";
  return "#15803d";
}

/** Worker URL resolves from the page (bundler territory, not lib/engine). */
function spawnLawWorker(): Worker {
  return new Worker(new URL("../../workers/law-reticle.worker.ts", import.meta.url), {
    type: "module",
  });
}

function TerminalBody() {
  const t = useSovereignTerminal();
  const andon = useAndon();
  const [payload, setPayload] = useState(DEFAULT_BYTES);
  const [token, setToken] = useState("");
  const mainRef = useRef<HTMLElement | null>(null);

  // BK-83 AUTH-SEAM (browser wiring): the page-owned token threads into the
  // engine's flushSync bearer. Empty = tokenless — enforce mode answers the
  // typed 401 challenge and the sync refuses SYNC_HTTP/401 honestly.
  const wireToken = (v: string) => {
    setToken(v);
    t.setToken(v);
  };

  // P12 Constant Seal: the receipt path (parseReceipt + verifyReceipt, run
  // inside journal-sync.flushSync) lands in the snapshot; the DOM emission
  // rides renderReceiptFields on the live element. A refused sync keeps
  // verified=false honestly — parse alone never verifies.
  useEffect(() => {
    if (mainRef.current) {
      renderReceiptFields(mainRef.current, t.receipt, t.receiptVerified);
    }
  }, [t.receipt, t.receiptVerified]);

  // Pattern 15: pin the worker once; Pattern 5: hydrate the journal before
  // the status leaves INITIALIZING. Both are idempotent and SSR-safe.
  useEffect(() => {
    void globalJournalEngine.init();
    void lawWorkerBridge.init(DEFAULT_RETICLE, spawnLawWorker).catch(() => {
      // INIT failure surfaces as GUARD_FAULT on the first admit (andon).
    });
  }, []);

  const admit = () => void t.admitAndCommit(payload);
  const sync = () => void t.syncUpstream();

  return (
    <main
      ref={mainRef}
      data-status={t.status}
      data-machine-state={t.status}
      data-seq={t.currentSeq}
      data-unsynced-count={t.unsyncedCount}
      data-receipt={t.receipt || ""}
      data-andon-state={andon.raised ? "RAISED" : "CLEARED"}
      style={{ maxWidth: 860, margin: "0 auto", padding: 24, fontFamily: "monospace" }}
    >
      <h1 style={{ fontSize: 20 }}>Sovereign Console — Terminal</h1>
      <p style={{ color: statusTone(t.status), fontWeight: 700 }}>{t.status}</p>

      <section style={{ marginBottom: 12 }}>
        <label htmlFor="payload">payload bytes (opaque)</label>
        <textarea
          id="payload"
          role="textbox"
          data-slot="payload-input"
          rows={4}
          value={payload}
          onChange={(e) => setPayload(e.target.value)}
          style={{ width: "100%", fontFamily: "monospace" }}
        />
      </section>

      <section style={{ marginBottom: 12 }}>
        <label htmlFor="sync-token">sync bearer token (empty = tokenless)</label>
        <input
          id="sync-token"
          data-slot="sync-token-input"
          type="password"
          value={token}
          onChange={(e) => wireToken(e.target.value)}
          style={{ width: "100%", fontFamily: "monospace" }}
        />
      </section>

      <div style={{ display: "flex", gap: 8, marginBottom: 16 }}>
        <button data-action="admit" onClick={admit} disabled={t.busy || t.status === "INITIALIZING"}>
          Evaluate + Commit
        </button>
        <button data-action="sync" data-testid="sync-trigger" onClick={sync} disabled={t.busy}>
          Sync
        </button>
      </div>

      <section style={{ marginBottom: 16 }}>
        <h2 style={{ fontSize: 14 }}>Journal standing</h2>
        <ul>
          <li>seq (current): {t.currentSeq}</li>
          <li>un-acked: {t.unsyncedCount}</li>
          <li>receipt: {t.receipt ? `${t.receipt.slice(0, 12)}…` : "—"}</li>
        </ul>
      </section>

      <section style={{ marginBottom: 16 }}>
        <h2 style={{ fontSize: 14 }}>Frame log</h2>
        <div
          role="log"
          style={{ background: "#f4f4f5", padding: 8, maxHeight: 240, overflow: "auto" }}
        >
          {t.frames.length === 0
            ? "—"
            : t.frames.map((seq) => (
                <div key={seq} data-frame-seq={seq}>
                  frame seq={seq} journaled (local, un-acked until sync)
                </div>
              ))}
        </div>
      </section>
    </main>
  );
}

export default function TerminalPage() {
  return (
    <AndonProvider>
      <TerminalBody />
    </AndonProvider>
  );
}
