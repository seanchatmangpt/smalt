# BK-130 — RU-3 adoption #2–5: react-use pattern-port hook batch

**Standing: PASS** (hooks court ×2 green, ws-lint 0 errors, ws-build green, patterns-court 13/3/0 unchanged)
**Context: solo**
**Milestone:** v26.10.22 · **Date:** 2026-10-22 · **Not committed** (working tree)

## What landed

Four new hook files in `workspace/lib/engine/` — Option C pattern-ports of
streamich/react-use v17.6.1 (Unlicense), no npm dep, domain-blind, no absolute
paths, `import.meta`-free (BK-54 Class A by construction). Each file splits a
framework-free core (node-court drivable with fake events, deterministic) from
a thin SSR-safe React wrapper, following the BK-118 `useAsyncFn` precedent.

## Per-hook diff (files added)

| File | Wire surface |
|---|---|
| `workspace/lib/engine/useNetworkState.ts` | `useNetworkState` (online + downlink/rtt/effectiveType snapshot, `unknown` disclosed where the API is absent); `gateFlushOnNetwork` (offline → typed `OFFLINE` refusal, flush never invoked); `isReconnect`; `onlineClass` |
| `workspace/lib/engine/useIdle.ts` | `useIdle` (activity events: mouse/key/pointer/touch/scroll/wheel); `createIdleCore` + `shouldAutoFlush` wiring decision (idle ≥ timeout AND unsynced > 0); `DEFAULT_IDLE_FLUSH_MS = 30_000`; `ACTIVITY_EVENTS` |
| `workspace/lib/engine/useVisibility.ts` | `useVisibility`; `resumeAfterHidden` / `flushOnResume` predicate (hidden→visible only; prerender counts as hidden) |
| `workspace/lib/engine/usePermission.ts` | `usePermission` (reactive Permissions API query); `permissionClass` (granted/denied/prompt + `unsupported`/`unknown` disclosed); `preflightPermission` → typed `PERMISSION_REFUSED` before any WebAuthn challenge |

Header of every file cites streamich/react-use v17.6.1, Unlicense, Option C
(per reactuse-vendoring-strategy.md §5).

## In-session defect (court non-vacuity witness)

useIdle's core shipped with a real defect the court caught on the FIRST run:
`shouldAutoFlush` recomputed its limit from the optional override only
(`timeoutMs ?? DEFAULT_IDLE_FLUSH_MS`), ignoring the timeout the core was
minted with — a 60s core auto-flushed at 30s. Assertion I2d FAILed; the fix
(the core keeps its minted limit; the argument is an override) landed before
the second green run. The court can fail.

## Courts

| Gate | Command | Exit |
|---|---|---|
| hooks court (new, BK-130) | `just hooks-court` (workspace/scripts/hooks-court.mjs) | 0 |
| hooks court (direct) | `node workspace/scripts/hooks-court.mjs` | 0 |
| sibling regression | `node workspace/scripts/asyncfn-court.mjs` | 0 (bk118 verdict PASS) |
| lint | `just ws-lint` | 0 errors (45 pre-existing warnings, none in new files) |
| build | `just ws-build` | 0 |
| pattern court | `just patterns-court` | 13 PASS / 3 SKIP / 0 FAIL (unchanged) |

### hooks-court transcript (second run, all green)

```
[ok] tsc compile: 4 hook ports typecheck (React wrappers included)
[ok] N1: offline → typed OFFLINE skip, flush invoked 0x
[ok] N2: online → flush ran once, result propagated
[ok] N3: reconnect predicate: offline→online only
[ok] N3b: onlineClass classification
[ok] I1: idle boundary exact at timeoutMs, idleFor monotone
[ok] I2a: idle but zero unsynced → no auto-flush
[ok] I2b: unsynced but not idle → no auto-flush
[ok] I2c: idle ≥30s AND unsynced>0 → auto-flush attempt
[ok] I2d: custom 60s timeout honored (RU-3 range)
[ok] V1: resume predicate: hidden/prerender → visible only
[ok] V1b: flushOnResume is the exposed wiring predicates
[ok] P1: permission classification incl. unsupported/unknown disclosure
[ok] P2: pre-flight: granted runs; denied/unsupported typed-refuse before challenge
hooks-court: all assertions green
```

First run: 13 ok + 1 FAIL (I2d) — the non-vacuity witness above.

## Wire contract notes

- Offline gating: `gateFlushOnNetwork(false, flush)` returns
  `{skipped:true, refusal:{code:"OFFLINE", ...}}` and never invokes the flush —
  no burned 401/HTTP-error cycle (RU-3 item 2's value claim).
- Reconnect leg reuses the existing snapback law: on `offline→online` the
  unacked frames above the ack cursor drain via flushSync; the predicate is
  `isReconnect(prev, next)`.
- Idle auto-flush requires BOTH idle ≥ timeout AND `unsyncedCount > 0` —
  never one alone (drain-before-walk-away, pharma/defense requirement).
- Permissions pre-flight refuses typed, with standing attached, before any
  challenge.
- All four wrappers are SSR-safe: lazy initializers read live APIs only
  client-side; no synchronous setState in effect bodies. (First lint run
  errored react-hooks/set-state-in-effect on all three sensor hooks — fixed
  by removing the sync setState in useNetworkState/useVisibility and
  deferring the unsupported-path setState in usePermission via
  queueMicrotask.)

## Recipe

`just hooks-court` added in `justfile.d/02-workspace.just` (adjacent to
ws-court).

## Falsifier

A hooks-court assertion failing on the landed files, or a ws-lint/ws-build
regression attributable to the new files. The I2d first-run failure and its
in-session fix is the court's non-vacuity witness: the court can fail.
