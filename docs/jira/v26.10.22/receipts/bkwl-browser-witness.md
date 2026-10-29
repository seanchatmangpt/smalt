# BK-WLB — useWebLocks browser-context witness (real navigator.locks)

**Standing: ALIVE** · Context: solo · 2026-10-22

Lane BK-WLB. Closes BK-119B's honest-limits UNKNOWN: browser-true
`navigator.locks` behavior for the row-8 master lease is now WITNESSED, not
shimmed.

## What ran

New court `workspace/scripts/weblocks-browser-court.mjs` (BK-SKIPPORT's
headless-Chromium pattern): transpiles the REAL engine modules
(`useWebLocks.ts` + `tab-lease.ts`) with the workspace's own tsc, serves them
with COOP/COEP, boots headless Chromium (system Chrome 143 headless; the
playwright headless-shell cache path was empty on this box), opens TWO PAGES
OF ONE SHARED `BrowserContext`, and drives `WebLocksCore` in both — real
`navigator.locks`, native `function request() { [native code] }`, NO shim.
Exit contract 0/1/3 (3 = typed SKIP if the browser lacks `navigator.locks`).

**Court-witnessed engine law (refines BK-119B's standing model): the
snapshot's standing is outcome-tracked, not live-holder tracked.** `isMaster`
and `lastMode` are patched only when a leased body COMPLETES ("standing moves
with the real outcome, never ahead of it" — literally), so:

- mid-body, the holder's own snapshot shows `isMaster=false` /
  `lastMode="never-held"`;
- after completion the standing stays disclosed (A keeps `lastMode=
  "web-locks"` after release — it does not reset to false);
- live holdership is witnessed behaviorally: the second tab's body cannot
  start while the master holds, and `navigator.locks.query()` shows the
  exclusive lock HELD (cross-tab visible from the waiting tab, same
  clientId).

Also witnessed (environment law): `browser.newPage()` in playwright mints an
ISOLATED context per page — two `browser.newPage()` pages each held
`lawinput_wal_lock` exclusively with distinct clientIds (no cross-tab
semantics). The court therefore uses one shared `BrowserContext`, two pages;
only there do Web Locks bind per origin. This is the load-bearing harness law
for any future cross-tab browser court.

## Embedded court output (verbatim, run 2 of 2, both 22/22)

```
$ cd /Users/sac/smalt/workspace && node scripts/weblocks-browser-court.mjs
playwright: workspace node_modules
serving /Users/sac/smalt/workspace/.weblocks-browser-court on http://127.0.0.1:54437
browser: /Applications/Google Chrome.app/Contents/MacOS/Google Chrome
native check (page A): {"present":true,"native":true,"repr":"function request() { [native code] }"}
[ok] B1a: page A snapshot supported=true (real LockManager present)
[ok] B1b: page A inFlight=1 while body runs
[ok] B1c: page A isMaster=false mid-body (standing is outcome-tracked: patched at completion, never ahead of the outcome)
[ok] B1d: page A lastMode="never-held" until the body completes
[ok] B1e: navigator.locks.query() shows the exclusive master lease held: [{"clientId":"ABEA23528C81599837E78763D7E03EA3","mode":"exclusive","name":"lawinput_wal_lock"}]
[ok] B1f: lock name is the pinned row-8 literal
[ok] B2: navigator.locks.request is native (no shim): function request() { [native code] }
[ok] B3a: page B supported=true
[ok] B3b: page B isMaster=false while A holds (read-only standing)
[ok] B3c: page B lastMode="never-held" while waiting
[ok] B3d: page B inFlight=1 (waiting on the held lease)
[ok] B3e: page B body never started while A holds
[ok] B3f: query() from page B sees A's held exclusive lock (shared lock manager, cross-tab): same clientId as A's hold
[ok] B4a: A body completed, mode=web-locks
[ok] B4b: page A isMaster=true after completing as master (outcome-tracked standing)
[ok] B4c: page A lastMode="web-locks" after completing (disclosed, not dropped)
[ok] B4d: B body started only after A released (release=1792672679165 <= bstart=1792672679169)
[ok] B4e: B acquired after release, mode=web-locks
[ok] B4f: page B isMaster=true after completing as master
[ok] B4g: page B lastMode="web-locks" after completing
[ok] B4h: page B inFlight drained to 0
[ok] B5a: query() after both bodies complete: no held locks (lease actually released): []
# PASS: 22
# FAIL: 0
weblocks-browser-court exit: 0
```

The clientId hex is reproduced verbatim from the witnessed run; the court
asserts the exact "web-locks" literal.

## Verification commands

```
node --check workspace/scripts/weblocks-browser-court.mjs    # SYNTAX-OK
node scripts/weblocks-browser-court.mjs                      # exit 0, 22/22 (twice)
node scripts/weblocks-court.mjs                              # node shim court, untouched, 11/11
```

## Falsifier

Re-run `node scripts/weblocks-browser-court.mjs`. The browser witness flips
to FAIL if: the engine's lock name changes, the snapshot standing stops being
outcome-tracked, the second tab starts its body while the master holds
(exclusivity broken), `query()` stops showing the held exclusive lock, or the
lease leaks past completion (B5a non-empty). Exit 3 types a
`navigator.locks`-less browser loudly (SKIP, never a fake pass).

## Honest limits

- The court drives `WebLocksCore` directly; the React hook
  (`useSyncExternalStore`) is not exercised in-browser (its served specifier
  rides a disclosed pass-through shim; no assertion surface). The node court
  covers the snapshot face; hook rendering is UI-layer follow-on.
- Witnessed on system Chrome headless (playwright-driven), macOS arm64, one
  origin, two tabs. No cross-browser (Safari/Firefox) witness.
- The wal-lock master lease is exercised with the court's body; the
  journal-sync append+drain path (the production body of the lease) is not
  exercised here — the lease mechanics, not the journal, are the surface
  under witness.
