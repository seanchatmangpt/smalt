# React-Use vs Sovereign-Console Engine Hooks — Audit

Milestone: v26.10.22 · Type: read-only vendor audit (no code touched).
Subject: `workspace/lib/engine/{law-worker-bridge,useJournal,useAndon,useSovereignTerminal,journal-sync,tab-lease}` compared against streamich/react-use (docs read at HEAD).
Standing: PARTIAL_ALIVE — static audit + spot doc checks (useIdle verified live; useNetwork doc path 404s under that name, catalog knowledge used instead).

## Typed comparison table

| Engine surface (file) | Nearest react-use analogue | react-use does better | Engine-only (vendor cannot) | Verdict |
|---|---|---|---|---|
| `LawWorkerBridge` + module pin `lawWorkerBridge` (law-worker-bridge.ts) | `useAsyncFn`/`useAsync` (memoized promise, idempotent init ≈ react-use's caching); singleton ≈ module-scope store | SSR `isBrowser` guards on every hook; `useMounted`-style setState-after-unmount protection; standardized `loading/error` tuple | Worker LIFECYCLE pin: one WASM worker per page, memoized ready-promise, concurrent callers race-free; main-thread 16 MiB cap BEFORE `gl_alloc`; structured refusal `ALLOC_CAP_EXCEEDED` typed end-to-end | port-pattern (init memoization already ≥ vendor; borrow SSR/mount guards only) |
| `JournalSyncEngine` / `useJournal` (useJournal.ts) | `useSyncExternalStore` is React core, not react-use; closest vendor neighbours `useObservable`, `useList`, `useLocalStorage` | Vendor stores re-render via copy-on-write helpers consistently; `useLocalStorage` handles storage-event cross-tab echo | IndexedDB WAL as the store of record; merkle accumulator rebuild by frame replay; `getServerSnapshot` returns INITIALIZING defaults — SSR never touches IDB (vendor's `useLocalStorage` reads lazily client-only but has no server-snapshot contract); `leaseMode` disclosed on snapshot; rehydrate-on-promotion before leased body serves | skip-with-reason (nothing in vendor models external durable stores + lease standing) |
| `AndonProvider` / `useAndon` (useAndon.tsx) | `useBoolean` + `useToggle` (raised/acknowledge), context-provider pattern | Tiny state, vendor adds nothing material; `useSessionStorage` could persist `lastRule` across reloads | Structured refusal vocabulary (`rule` string) as first-class state; contract selectors (`role="alert"`, `data-andon-state/-rule`) court-assertable; provider renders the banner itself, not a headless flag | adopt-vendor is NOT applicable — port `useBoolean` shape only if a rewrite ever happens; otherwise skip |
| `useSovereignTerminal` (useSovereignTerminal.ts) | `useAsyncFn` (busy/error state machine) + `useMediatedState` (derived status) | `useAsyncFn` tracks in-flight per-fn and returns `error` captured from throws — engine's `finally setBusy(false)` is hand-rolled and silently swallows nothing but also reports nothing | Derived state machine: journal phase overridden by andon standing (`HALTED_BY_SIEVE` outranks), status never stored twice; admit routed through pinned worker then journal; busy-gate prevents double submit | port-pattern (replace hand-rolled busy with `useAsyncFn`-shaped state incl. `error` — low risk, real gain) |
| `journal-sync.ts` (module, not a hook) | `useLocalStorage`/`useSessionStorage` (persistence), `useAsyncFn` (flush), `useInterval` (periodic flush) | Vendor persistence hooks handle serialization quirks (functions, undefined) — irrelevant for binary frames; `useInterval` pause/resume semantics are clean | Binary WAL (41-byte frames), monotonic turnstile `AppendQueue` (contiguous seqIds regardless of caller discipline), receipt verification against FULL ledger sliced to ack horizon (KD-165), typed snapback (`SYNC_REFUSED_BY_SERVER` → purge + cursor reset), smaltFetch-only egress, nested-lock deadlock repair (raw `_markSynced` under held lease) | skip-with-reason (vendor has no binary/WAL/merkle story; `useLocalStorage` would be a downgrade) |
| `tab-lease.ts` (`withWalLease`, `PeerGuard`) | none; weak neighbours `useNetwork` (online flag), `useHeartbeat`-style presence absent in vendor, `useIdle` (presence-ish) | Vendor sensor hooks consistently: event→cleanup discipline, `useUnmount` teardown, SSR no-op returns | Web Locks exclusive master lease with typed timeout/abort/steal; fallback mode disclosed (`mode:"fallback"`), never silent; BroadcastChannel ping/pong peer detection with bounded pong poll (observable wait, not fixed sleep); `PEER_TAB_ACTIVE` typed refusal instead of double-minted seqIds; `onAcquired` rehydrate hook (lease transfers, horizon doesn't) | skip-with-reason (no vendor analogue; this is the engine's crown) |

## What react-use does better (port these disciplines)

1. **SSR guard uniformity** — vendor wraps every hook in `isBrowser` checks; engine relies on
   `"use client"` + `getServerSnapshot` (useJournal is fine) but `useSovereignTerminal` and the
   bridge would throw raw if ever rendered server-side. Cheap to harden.
2. **setState-after-unmount protection** — `useMounted`/`useUnmount` pattern. `useSovereignTerminal`
   `setBusy` after a resolved promise can fire post-unmount (React 18 is tolerant; React 19
   strict-mode double-invoke makes the hand-rolled `busy` gate in `admitAndCommit` close over a
   stale `busy` — vendor's `useAsyncFn` keeps it in a ref). This is the one real defect class.
3. **Standardized result tuple** — `useAsyncFn`'s `[state, fn, {loading, error}]` beats the
   engine's `{ ok, error? }` + separate `busy` mix.
4. **Event-listener cleanup discipline** — vendor's sensors always tear down on unmount;
   engine's `PeerGuard` has `close()` but nothing in the landed code calls it (module-lifetime
   singleton — acceptable, but a `useUnmount`-anchored teardown would be free).

## What the engine does that react-use cannot

- **WASM worker pin**: memoized ready promise, page-lifetime worker, pre-flight alloc cap,
  shared refusal vocabulary with the worker's own typed refusals.
- **IndexedDB WAL + merkle chain**: durable frames, replay-rebuilt accumulator, server receipt
  verified against the full local chain, typed snapback on server head divergence.
- **Lease semantics**: Web Locks master lease + typed fallback + BroadcastChannel peer guard +
  rehydrate-on-promotion. Vendor has nothing cross-tab; its `useLocalStorage` storage-event echo
  is the entire extent of multi-tab awareness.

## Prioritized adoption list

| # | Action | Hook | Target | Why |
|---|---|---|---|---|
| 1 | **port-pattern** | `useAsyncFn` semantics | `useSovereignTerminal` | Replace stale-closure `busy` boolean + missing `error` surfacing. Fixes a real stale-state class; vendor code is 60 lines to mirror, no dependency needed. |
| 2 | **adopt-vendor** | `useNetwork` | `journal-sync` flush gating | Skip `sync()` when `navigator.onLine === false`; avoids burning a typed 401/HTTP-error cycle offline. Highest value-per-line of any vendor adoption. |
| 3 | **adopt-vendor** | `useIdle` | auto-flush | When idle ≥30–60s and `unsyncedCount > 0`, fire `syncUpstream()`. Also gates rehydrate-on-focus: flush on activity resume, not on a timer. |
| 4 | **adopt-vendor** | `useVisibility` (page lifecycle) | flush + lease hygiene | On `visibilitychange → visible`, run `sync()` (catch-up after tab suspension, incl. Web Locks handed off while hidden). Pairs with rehydrate-on-promotion. |
| 5 | **adopt-vendor** | `usePermission` | WebAuthn/WebCrypto surfaces | Pre-flight `publickey-credential-get`/`crypto` permission state before wiring token issuance into `setToken`; renders a typed "permission refused" instead of a raw challenge failure. |
| 6 | **adopt-vendor** | `useEvent` / `useKey` | terminal input | Sovereign console input surface currently unspecified in the hook; vendor key handling is battle-tested for focus/IMU edge cases. |
| 7 | **port-pattern** | `useMounted` guard | `useJournal.patch` via engine emit | Guard `emit()` against listener sets from unmounted trees — minor; only worth doing with #1. |
| 8 | **adopt-vendor** (optional) | `useLocalStorage` | UI prefs only (theme, panel state) | NEVER for journal/WAL — vendor persistence has no integrity model. |
| 9 | **skip-with-reason** | `useObservable`, `useList`, `useBoolean`, `useToggle` | — | Engine's `useSyncExternalStore` + typed context already supersede them; adopting would add re-render churn without a capability gain. |

Dependency note: react-use is a single dep (~many hooks, tree-shakable); items 2/3/4/5 are each
<20 lines if ported instead. Recommendation: install vendor for 2/3/4/5, port #1 locally
(keeps the busy/error state inside the typed `TerminalStatus` contract).

## Falsifier / receipt

- Claims about vendor hooks derived from the react-use docs tree; `useIdle` verified live via
  raw fetch; `useNetwork` doc URL 404s (hook exists in catalog as sensor, name per catalog is
  `useNetwork` — verify path `docs/useNetworkState.md` if a follow-up needs the exact API).
- No code modified; single file written (this one). Not committed.
