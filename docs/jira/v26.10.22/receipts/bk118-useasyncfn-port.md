# BK-118 — useAsyncFn pattern-port (RU-3 adoption #1)

**Standing: ALIVE** — courts green ×1 (dom-contract / spof4 / patterns / asyncfn all exit 0, ws-lint 0 errors, ws-build exit 0).
Context: solo

## Subject

- Repo: /Users/sac/smalt (canonical checkout), branch main, base 8c2fb38
- Files (session diff, uncommitted):
  - `workspace/lib/engine/useAsyncFn.ts` (NEW) — pattern-port of react-use
    `useAsyncFn` (streamich/react-use v17.6.1, Unlicense) per RU-4 Option C:
    framework-free `createAsyncFnCore` (in-flight + error in mutable core,
    fresh synchronous read) + `useAsyncFn` React wrapper (stable `fn`,
    useState snapshot for render reads; core exposed as third tuple element
    for fresh callback reads). No npm dependency added.
  - `workspace/lib/engine/useSovereignTerminal.ts` (MODIFIED) — admit/sync
    routed through the ported core. The stale-closure `busy` boolean gate
    (`if (busy) return; setBusy(true) … finally setBusy(false)`) is REMOVED:
    in-flight standing lives in the core, `busy` renders from the state
    snapshot, and a rapid second admit is no longer dropped — it lands on
    the journal turnstile (AppendQueue) and serializes there. Captured
    errors surface to the ANDON cord as `BK118_ASYNC_ERROR: <message>`.
  - `workspace/scripts/asyncfn-court.mjs` (NEW) — node court for the
    ref-semantics (see Courts).

## Defect class closed

RU-3 audit item #1: React 18/19 strict-mode double-invoke made the
hand-rolled `busy` gate in `admitAndCommit` close over a stale `busy`,
dropping admits or letting them race. Vendor discipline ported: in-flight
in a ref-like core read fresh at call time; error captured as state and
raised to the andon instead of vanishing in a bare `finally`.

## Courts (real output, exit codes)

- `node scripts/asyncfn-court.mjs` — **PASS (0 failures), exit 0**:
  - A1 first run flips loading synchronously; rapid second call sees
    in-flight=true; both rapid runs resolve (zero dropped); loading false after settle
  - A2 double-admit through the journal `AppendQueue` yields contiguous
    trail `["a","b"]` — zero dropped transitions
  - A3 throwing task resolves undefined, error captured as state, loading
    false, core not poisoned by next run
  - A4 successful rerun clears error
- `node scripts/dom-contract-court.mjs` — **PASS (0 failures), exit 0**
  (P3 50-burst serialization, replay determinism, cap refusals, andon mapping)
- `node scripts/spof4-court.mjs` — **19 PASS / 0 FAIL, exit 0**
- `node scripts/pattern-court.mjs` — **13 PASS / 3 SKIP / 0 FAIL, exit 0**
- `just ws-lint` — **0 errors** (45 pre-existing warnings; none in the two
  owned files — `useAsyncFn.ts`/`useSovereignTerminal.ts` produce zero
  findings). Two iterations were required: initial version read ref cores
  during render (`react-hooks/refs` errors); fixed by moving render reads to
  a useState snapshot and keeping fresh core reads inside callbacks only,
  and minting the core via a `useState(createAsyncFnCore)` initializer.
- `just ws-build` — **exit 0** (Next.js 16 production build, typecheck clean).

## Diff discipline

- 3 files touched, all within the lane's ownership
  (useSovereignTerminal.ts, useAsyncFn.ts + its court script).
- `useAsyncFn.ts` carries the prior-art header citing streamich/react-use
  v17.6.1 (Unlicense) per RU-4 Option C.
- Not committed (per dispatch). Pre-existing session diff on
  `lib/smalt/messaging/event_hubs.ex` + `test/integration/amqp10_debug_test.exs`
  untouched.

## Falsifier check

- "rapid double-admit drops the second call" — killed: A1/A2 assert both
  calls execute and serialize contiguously through AppendQueue.
- "errors vanish into the bare finally" — killed: A3 + the andon raise path
  (`BK118_ASYNC_ERROR` → `andon.raise`, status derives to HALTED_BY_SIEVE).

## Replay

```bash
cd /Users/sac/smalt/workspace && NODE_PATH="$PWD/node_modules" node scripts/asyncfn-court.mjs
node scripts/dom-contract-court.mjs && node scripts/spof4-court.mjs && node scripts/pattern-court.mjs
just ws-lint && just ws-build
```
