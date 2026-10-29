# BK-119B — W3C-E row 8 Web Locks master lease: reactive face + court

**Standing: PARTIAL_ALIVE** · Context: solo · 2026-10-22

Lane BK-119B. Successor to BK-119 (typed DEAD-NO-ARTIFACT by BK-LANEAUD — the
useWebLocks PR branch never landed, 429-killed). The row-8 work order survives.

## What landed

1. **`workspace/lib/engine/useWebLocks.ts`** (new) — the React face of the
   `navigator.locks.request("lawinput_wal_lock")` master lease. Composes
   `tab-lease.ts` (which owns the cross-tab mechanics: `withWalLease`,
   PeerGuard, typed fallback) — no mutex duplication. Pattern-16
   module-scoped singleton core (`WebLocksCore`) + `useSyncExternalStore`
   hook with a server snapshot (pattern 13: SSR renders the unsupported
   default, never touches `navigator.locks`).
   Standing disclosed, never dropped: `supported` / `lastMode`
   (`"web-locks" | "fallback" | "never-held"`) / `isMaster` / `inFlight`
   on every snapshot; standing moves with the real outcome, never ahead
   of it.
2. **`workspace/scripts/weblocks-court.mjs`** (new) — node court over a
   real degraded collaborator (hand-written FIFO exclusive mutex installed
   as `globalThis.navigator.locks`; a literal mutex, not a call-counting
   mock — same honest-shim pattern as tab-lease-court). 11 assertions / 6
   legs, all green:
   - L1 compile gate: useWebLocks.ts + tab-lease.ts typecheck (React + dom).
   - L2 unsupported runtime honestly typed (fallback runs, snapshot
     supported=false, isMaster=false).
   - L3 master-lease acquired + exclusive (overlapping bodies serialize,
     `mode === "web-locks"`, standing tracked).
   - L4 secondary-observer read-only: while the master held, the secondary
     observed isMaster=false, inFlight=1, body never started; ran only
     after release, never interleaved.
   - L5 server snapshot is the unsupported default.
   - L6 failing body → typed BODY_FAILED, isMaster falls to false,
     lastMode disclosed, inFlight drained.
3. **`docs/jira/v26.10.22/W3C-FORMALIZATION.md`** row 8 standing cell
   updated with the receipt path + honest standing (PARTIAL_ALIVE: browser
   `navigator.locks` unexercised — the court's LockManager is a real FIFO
   mutex shim; secondary-tab replica *reading* of the store is follow-on).

## Embedded court output

```
$ cd workspace && node scripts/weblocks-court.mjs
[ok] L1 tsc compile: useWebLocks.ts + tab-lease.ts typecheck (React + dom types)
[ok] L2a body runs in fallback, mode typed
[ok] L2b snapshot discloses unsupported/degraded
[ok] L3a both bodies succeed under the real lease
[ok] L3b bodies serialize (exclusive, no interleaving)
[ok] L3c snapshot: supported, master standing, drained inFlight
[ok] L4a master body ran to completion first
[ok] L4b secondary body never started while master held
[ok] L4c secondary observed non-master + in-flight while waiting
[ok] L4d secondary ran only after release, never interleaved
[ok] L5 server snapshot is the unsupported default (pattern 13)
[ok] L6 body failure typed BODY_FAILED, isMaster falls back to false, lastMode disclosed
# PASS: 11
# FAIL: 0
```

## Verification commands

```
just ws-lint                          # my files clean; pre-existing error in scripts/kd171r-court.mjs (BK-171R lane's file, not mine)
node scripts/weblocks-court.mjs       # exit 0, 11/11
node scripts/hooks-court.mjs          # exit 0
node scripts/tab-lease-court.mjs      # exit 0
```

## Honest limits

- **[Witnessed 2026-10-22, BK-WLB — superseded]** Browser `navigator.locks`
  was unexercised by this lane's node court (LockManager shim). The
  browser-context court has since run: `workspace/scripts/weblocks-browser-court.mjs`,
  22/22 PASS on real headless Chromium with native `navigator.locks` —
  master lease held/queried exclusive, second tab waits read-only
  (isMaster=false, body never starts), release → transfer, quiesced tail.
  Receipt: `receipts/bkwl-browser-witness.md`. The browser UNKNOWN typing
  above is CLOSED; the standing is ALIVE for the lease/standing face.
  Two harness/engine laws witnessed there: the snapshot standing is
  outcome-tracked (isMaster/lastMode patch at body completion, not
  acquisition — the holder shows isMaster=false mid-body), and playwright
  `browser.newPage()` mints isolated contexts (separate lock managers);
  cross-tab courts need one shared BrowserContext.
- Secondary-tab replica observation of the store (read-only replica
  observers) is not implemented here — only the lease/exclusivity +
  observer standing face; the row-8 read path is follow-on work.
- The React hook (`useSyncExternalStore`) face is not exercised in-browser
  (the browser court drives `WebLocksCore` directly; hook rendering is
  UI-layer follow-on).
- `just ws-lint` currently exits 1 on a pre-existing error in
  `workspace/scripts/kd171r-court.mjs` (BK-171R lane's file; untouched by
  this lane).
