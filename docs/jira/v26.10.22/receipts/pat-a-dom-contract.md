# Receipt — PAT-A: semantic DOM contract (patterns 1-6) + reference wiring (13-16, 19-20)

**Standing:** **ALIVE** (all contract selectors driven by real engine state; every pure-logic
claim executed in a real node court; workspace gates exit 0 on the landed tree).

Context: solo

## Landed

- `workspace/lib/engine/journal-sync.ts` (extended):
  - `AppendQueue` + module-level `appendQueue` turnstile (P3 Monotonic Turnstile) —
    all appends serialize through one FIFO promise queue; `appendLocal` routes through
    it, so concurrent callers observe contiguous seqIds.
  - Pure hydration math: `nextSeqFromSegments`, `countUnsynced` (node-court-testable).
  - `hydrate()` (P5 Cold Ash Rehydration): restores `currentSeq` + unsynced count from
    IndexedDB and returns stored frames for accumulator replay. Merkle-rebuild choice:
    **rebuild-from-frames** (exact chain, drift-detecting, O(n) once per page) over
    persisting the accumulator root (which would trust a digest the frames no longer
    prove). Documented at `hydrate()` and in the court.
  - Compile-freeze unblock (PAT-B's in-flight `flushSync` refusal-typing fix): typed
    the local `refusal` binding (`RefusalBody` alias) — PAT-B separately patched the
    same site; disclosed per the same-checkout law.
- `workspace/lib/engine/guard.ts` (extended): `ALLOC_CAP_BYTES` (16 MiB),
  `capRefusal()` (structured `ALLOC_CAP_EXCEEDED` verdict, enforced BEFORE the worker
  call — pattern 6 pre-gl_alloc), `andonRule()` (structured refusal → andon rule;
  guard faults map to `GUARD_FAULT`).
- `workspace/lib/engine/law-worker-bridge.ts` (new, pattern 15): module-scoped worker
  pin, idempotent memoized INIT, pending map (packet-4 over the Guard surface), cap
  check pre-worker in `admit()`. `import.meta` worker-spawn lives in the page, not
  lib/engine — the shared ws-court compiles lib as commonjs where `import.meta` is
  illegal (disclosed below).
- `workspace/lib/engine/useJournal.ts` (new, pattern 16): module-scoped
  `globalJournalEngine`, snapshot + listeners, `useSyncExternalStore` with distinct
  server snapshot (INITIALIZING defaults — pattern 13 SSR boundary). P5 hydration runs
  in `init()` before the phase leaves INITIALIZING; accumulator rebuilt by frame
  replay. Getters `getUnsyncedFrames()` / `getCurrentSeq()` present per the reference.
- `workspace/lib/engine/useAndon.tsx` (new, pattern 14): AndonProvider + the
  `role="alert"` banner with `data-andon-state="RAISED"` / `data-andon-rule` /
  `data-action="acknowledge-andon"`.
- `workspace/lib/engine/useSovereignTerminal.ts` (new, pattern 19): derived status
  machine (andon cord outranks journal phase), `admitAndCommit` / `syncUpstream`.
- `workspace/app/terminal/page.tsx` (rewritten to the reference wiring): root carries
  `data-status` + `data-machine-state` + `data-seq` + `data-unsynced-count` +
  `data-receipt` + `data-andon-state`; textarea `role="textbox" data-slot="payload-input"`;
  buttons `data-action="admit"` / `data-action="sync"` (`data-testid="sync-trigger"`);
  `role="log"` with per-frame `[data-frame-seq]` entries (pattern 3 trail);
  AndonProvider wrapper. Every selector is driven by hook state — no local source of
  truth in the page.
- `workspace/scripts/dom-contract-court.mjs` (new): 16-assertion node court over the
  pure logic (queue serialization, hydration math, accumulator replay determinism +
  tamper divergence, cap refusal, andon mapping).

## Per-pattern status

| # | Pattern | Status | Witness |
|---|---|---|---|
| 1 | Ontological Airlock (`data-action="admit"` → COMMITTED_LOCAL, seq+1) | ALIVE (DOM contract + state machine wired; browser witness = PAT-C) | `data-status` derived from engine phase; admit appends via queued appendLocal |
| 1–4, 6 | selector-driving logic | ALIVE | dom-contract court exit 0 (16/16 PASS) |
| 2 | Visible Andon Cord | ALIVE (logic) | `andonRule` maps structured worker refusals; banner from context state; cap refusal raises pre-worker |
| 3 | Monotonic Turnstile | ALIVE | 50-burst serialization proven ordered (court assertion 1); `data-frame-seq` trail in role="log" |
| 5 | Cold Ash Rehydration | ALIVE (math + engine init) | hydration vectors + accumulator replay byte-exact root / tamper divergence proven in court |
| 6 | Bounded Arena | ALIVE | capRefusal(16 MiB + 1) → ALLOC_CAP_EXCEEDED; exactly-16 MiB passes; enforced in `LawWorkerBridge.admit` BEFORE `guard.admit` |
| 13 | client boundary / SSR shell | ALIVE | "use client" page; getServerSnapshot returns INITIALIZING defaults; `next build` prerenders /terminal statically (60/60 pages) |
| 14 | Ambient Cord | ALIVE | useAndon.tsx landed |
| 15 | Persistent Worker Pin | ALIVE | law-worker-bridge.ts landed |
| 16 | Reactive Hearth | ALIVE | useJournal.ts landed |
| 17 | smaltFetch-only egress | satisfied (pre-existing law) | grep over workspace/lib stays clean; untouched |
| 20 | frozen console (`output: 'export'`) | **REPORTED, NOT FORCED** | next.config.mjs has no `output` setting; workspace serves dynamic routes (/process, /api/*, middleware proxy) which `output:'export'` forbids — adding it breaks ws-build/routes; left to the operator |

## Gate outputs (real runs, this tree, 2026-10-21)

- `node scripts/dom-contract-court.mjs` → `# dom-contract court verdict: PASS (0 failure(s))`, exit 0 (16/16 PASS)
- `just ws-lint` → exit 0 (35 pre-existing warnings, 0 errors)
- `just ws-build` → exit 0 (Compiled successfully; 60/60 static pages)
- `just ws-court` → exit 0 — `# PASS=60 FAIL=0 SKIP=3` (3 loud skips are pre-existing:
  DOM rendering not executable in node ×1, no Next server on :3100, no ARM on 9443)

## Disclosures (same-checkout law)

1. Compile-freeze unblocks (both minimal, both in shared files mid-flight by PAT-B /
   WS-12): typed PAT-B's in-flight `refusal` binding in `journal-sync.ts` (PAT-B then
   landed their own patch on the same site — theirs stands); added `jsx: 'react-jsx'`
   + `*.tsx` include to `e2e-court.mjs`'s lib tsconfig because my lib/engine files
   broke the shared lib typecheck leg.
2. Lane overlap: PAT-B landed `snapback.ts`, `receipt.ts`, their courts, and
   snapback/pattern-8/10/12 fields inside journal-sync.ts while this lane ran; all
   gates were run on the combined tree and pass.

## Falsifiers / open items

- Browser-side pattern verification (12 Playwright checks, incl. the reload/rehydrate
  leg and the 50-burst DOM trail) is PAT-C's court — this receipt witnesses the
  state-driving logic and the pure math, not the rendered DOM.
- `lawWorkerBridge` singleton is not exercised in node (worker/DOM unavailable there);
  its pure pieces (cap, mapping) are, and the class is typed for the page wiring.
- Pattern 20 not applied — operator decision needed on the dynamic-route tradeoff.
