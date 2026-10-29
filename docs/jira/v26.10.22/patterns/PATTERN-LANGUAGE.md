# A Pattern Language: Sovereign In-Browser Client & Lithographic Sync (12 + 8 patterns)

Standing: OPERATOR-CHARTER (2026-10-21) — implementation landed by lanes PAT-A/B/C
(receipts `receipts/pat-a-dom-contract.md` ALIVE, `receipts/pat-b-sync-semantics.md`
ALIVE, `receipts/pat-c-pattern-court.md` PARTIAL_ALIVE); the pattern court itself is
the standing proof. Full text: operator transcript (mor of record); this file is the
tracked index + selector contract. Refreshed 2026-10-22 (BK-PATDRIFT, receipt
`receipts/bkpatdrift-refresh.md`): all 20 cells re-verified against landed code,
with file:line anchors.

## Topology
Boundary/Sieve: P1 Ontological Airlock → P2 Visible Andon Cord, P3 Monotonic Turnstile.
Local-First Hearth: P4 Local Hearth → P5 Cold Ash Rehydration, P6 Bounded Arena.
Transit: P7 Sealed Convoy → P8 Fast-Forward Sluice, P9 Commutative Weave, P10 Elastic
Snapback, P11 Sabotage Trapdoor. Provenance: P12 Constant Seal (← P8, P9).

## Semantic selector contract (summary)

| # | Name | Trigger | Terminal attribute | Anchor (2026-10-22) |
|---|---|---|---|---|
| 1 | Ontological Airlock | `[data-action="admit"]` | `[data-status="COMMITTED_LOCAL"]`, seq+1 | `app/terminal/page.tsx:121` (admit button), `:84` (`data-status`); browser leg PASS (admit → COMMITTED_LOCAL, seq 0→1, real wasm sieve) |
| 2 | Visible Andon Cord | violating admit | `[data-status="HALTED_BY_SIEVE"]`, `[role="alert"]` + `[data-andon-rule]`, seq unchanged | `lib/engine/useAndon.tsx:57-60` (banner: `role="alert"`, `data-andon-state="RAISED"`, `data-andon-rule`); `useSovereignTerminal.ts:105` (andon outranks phase → HALTED_BY_SIEVE); browser leg PASS (wasm sieve refusal, seq unchanged) |
| 3 | Monotonic Turnstile | 50-burst admit | `[data-seq="50"]`, contiguous `[data-frame-seq]` in `role="log"` | `lib/engine/journal-sync.ts:195` (`AppendQueue`) + `:206` (`appendQueue` singleton FIFO); `page.tsx:141,147` (`role="log"`, `data-frame-seq`); browser leg PASS (50-burst seq 3..52, no gaps) |
| 4 | Local Hearth | `setOffline(true)` + 5 admits | `[data-seq="5"]`, `[data-unsynced-count="5"]` | `useJournal.ts:280` / `journal-sync.ts` flush queue; TYPED SKIP in court (needs browser + SYNC-1 server) — logic surfaces exist, browser leg not yet witnessed |
| 5 | Cold Ash Rehydration | `page.reload()` offline | seq + unsynced preserved post-READY_STANDALONE | `journal-sync.ts:256` (`hydrate()`, rebuild-from-frames Merkle policy); exp1c W4/W8: hydration prefers stored seqIds (`entries`) with index fallback — TYPED SKIP in court (browser reload leg unwitnessed) |
| 6 | Bounded Arena | >16MiB payload | `[data-andon-rule="ALLOC_CAP_EXCEEDED"]` then worker survives | `lib/engine/guard.ts:38` (`ALLOC_CAP_EXCEEDED`, 16 MiB, pre-worker); browser leg PASS (17MiB → andon, seq unchanged, worker survives) |
| 7 | Sealed Convoy | `[data-action="sync"]` | outbound buffer `0x534D4C54`, len Σ(41+len) | `lib/engine/codec.ts` (41-byte header, `0x534D4C54`); codec-court PASS (`scripts/codec-court.mjs`) |
| 8 | Fast-Forward Sluice | linear-history sync | `SYNCED_AND_SEALED`, unsynced 0, `[data-receipt]` set | `useSovereignTerminal.ts:89` (`syncUpstream`); `page.tsx:88` (`data-receipt`); sync-e2e-court 9/9 (exp1b: `flush-5-200-verified bytes=320 verified=true`) |
| 9 | Commutative Weave | two-context ⊗ sync | both SYNCED_AND_SEALED, zero ANDON | TYPED SKIP in court (two browser contexts + SYNC-1); identity side landed: `journal-sync.ts:39` `ensureClientId()` random nonzero u64 persisted in `sync_cursor` (exp1c W3 — removes the (0,seq) collision class the two-context commute would hit) |
| 10 | Elastic Snapback | conflicting ⊕ sync | `SYNC_REFUSED_BY_SERVER`, unsynced 0, seq snaps to server head | `journal-sync.ts:107` (typed code), `snapback.ts` (purge-to-head transitions); sync-e2e-court PASS (`corruption-typed-refusal` + `snapback-purge-to-head`, exp1b) |
| 11 | Sabotage Trapdoor | route byte-flip | typed `BAD_CRC32` refusal | `codec.ts:30,119` (`code: "BAD_CRC32"`, expected/observed); codec-court PASS; wire witness: sync-e2e `corruption-typed-refusal detail=BAD_CRC32 serverHeadSeq=5 purged=2` (exp1b). Earlier prose said lowercase `bad_crc32` — the landed code emits uppercase `BAD_CRC32` |
| 12 | Constant Seal | 1-frame vs 100-frame | `[data-receipt-bytes="320"]`, `[data-receipt-verified="true"]` | receipt chain now index-sliced by seqId with gap-typed refusal (`receipt chain gap: seqId N missing below acked horizon`, exp1c W4); 320-byte verified receipt witnessed (exp1b) |

## Implementation (landed)

- PAT-A: semantic DOM contract (patterns 1-6) — `workspace/app/terminal/page.tsx` +
  engine libs (receipt `pat-a-dom-contract.md`, ALIVE).
- PAT-B: sync semantics (patterns 8/10/12 client side; 7 in the codec) — snapback
  rollback in journal-sync, receipt display + verify badge; server contract via
  SYNC-1 (receiptToken/40-word + server-head refusal frames, FR-SNC-005/006)
  (receipt `pat-b-sync-semantics.md`, ALIVE).
- PAT-C: the verification court `workspace/scripts/pattern-court.mjs` +
  `workspace/tests-patterns/selector-contract.json`, `just patterns-court`
  (receipt `pat-c-pattern-court.md`, PARTIAL_ALIVE as-written; since promoted:
  the browser tier now runs — system Chrome via the headless-Chromium witnessing
  pattern, `docs/jira/v26.10.22/BROWSER-COURT-PATTERNS.md` — with a real
  `next start` boot. Current run: 13 PASS / 3 SKIP / 0 FAIL, exit 0; P4/P5/P9
  remain typed SKIP, see selector table).
- Post-PAT repairs folded into the exemplars: worker-guard/bridge lifecycle
  (`exp1a-worker-guard-repairs.md`: SHACL fail-closed, bridge init retry, worker
  WORKER_FAULT), journal/sync/lease repairs (`exp1c-journal-sync-repairs.md`:
  clientId identity, seqId receipt chain, IDB negative-cache/onblocked, WAL-lease
  abort-listener removal, dead wrappers deleted), script hygiene
  (`exp1b-script-hygiene.md`: courts self-contained, no /tmp collaborators).

## Next.js console extension (patterns 13-20, operator charter 2026-10-21)

| # | Name | Mechanism | Selector / gate | Anchor (2026-10-22) |
|---|---|---|---|---|
| 13 | Silent Crucible | client boundary + mount guard, SSR shell INITIALIZING | no hydration errors on /terminal | `useJournal.ts:277` (`globalJournalEngine` module singleton) + distinct server snapshot (INITIALIZING defaults); useWebLocks L5 confirms the pattern (`server snapshot is the unsupported default`) |
| 14 | Ambient Cord | AndonProvider context | `[data-andon-state="RAISED"]`, `[role="alert"]` | `useAndon.tsx:33,57-60`. Doc drift fixed: earlier table said `TRIPPED` — the landed banner emits `RAISED`/`CLEARED` (`page.tsx:89`) |
| 15 | Persistent Worker Pin | module-scoped singleton bridge | zero WASM re-init across Fast Refresh | `law-worker-bridge.ts:34` (`LawWorkerBridge`) / `:107` (`lawWorkerBridge` singleton); hardened exp1a: rejected init is un-memoized (retry), malformed packet-4 → typed `WORKER_FAULT`; second instance of the pattern: `useWebLocks.ts:61` `WebLocksCore` (`bk119b-weblocks-port.md`) |
| 16 | Reactive Hearth | useSyncExternalStore | `[data-seq]`, `[data-unsynced-count]` atomic | `useJournal.ts:280` (`useJournal`) + `useWebLocks.ts:115` (`useWebLocks`) — two consumers of the same pattern; Web Locks master lease reactive face (standing `supported`/`lastMode`/`isMaster`/`inFlight` disclosed, never ahead of outcome) per `bk119b-weblocks-port.md` |
| 17 | Air-Gapped Siphon | smaltFetch + ESLint fetch ban | 100% localhost + octet-stream requests | `lib/smalt.ts:11` `assertLocalUrl`, `:22` `smaltFetch`; `eslint.config.mjs:22-35` (http-client group ban + fetch-literal ban) — verified present |
| 18 | Ephemeral Mask | generic payload slot | domain-grep clean | unverifiable this session (no domain-grep run executed); cell left typed, not flipped. Adjacent: the bench-side `SMALT_DEBUG_FACES` gate (`bknenv-debug-faces.md`, 404 → typed FATAL exit 3) is a harness gate, not a console pattern cell |
| 19 | Dual-Head Status | FSM wrapper | `[data-machine-state]` transition path | `useSovereignTerminal.ts:48` (`useSovereignTerminal`, andon-cord-outranks-phase derivation); `page.tsx:85` (`data-machine-state` mirrors `data-status`) |
| 20 | Frozen Console | served app (`next start`) | NOT a static export — UNBUILT-for-static | Tested honestly (BK-P20, `bkp20-export-disposition.md`): adding `output: 'export'` fails `next build` with `Error: export const dynamic = "force-dynamic" on page "/api/v1/stream" cannot be used with "output: export"` — the BFF route handlers (`app/api/v1/stream`, `app/api/sync/state`, `app/process/api`, `app/bench/metrics`, …) and COOP/COEP header config are dynamic server faces. Witnessed alternative: normal build + `next start` on 127.0.0.1:47183 → `/console` 200 with `Cross-Origin-Opener-Policy: same-origin` + `Cross-Origin-Embedder-Policy: require-corp`, `/terminal` 200. Shim reverted byte-exact (sha256 match); config unchanged |

### Refresh notes (2026-10-22, BK-PATDRIFT)

- No exemplar file was invented here; every anchor above was grepped from the
  landed tree this session and the pattern court was re-run (13 PASS / 3 SKIP /
  0 FAIL, exit 0) as the standing proof for the P1-P12 table.
- Standing discipline applied: stale → landed (lanes section), census-only →
  typed (P4/P5/P9 SKIP legs, P18 domain-grep, P20 `output: 'export'`).
- Web Locks master lease (row 8, W3C-FORMALIZATION) is the newest pattern
  instance: `useWebLocks.ts` composes `tab-lease.ts:214` `withWalLease`
  (abort-listener leak closed, exp1c W5); court `weblocks-court.mjs` 11/11
  (bk119b) + browser witness `weblocks-browser-court.mjs`
  (`bkwl-browser-witness.md`).
