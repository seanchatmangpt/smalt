# BK-PATDRIFT — PATTERN-LANGUAGE.md drift refresh (20 cells vs landed tree)

**Standing:** **ALIVE** — every anchor below was re-read from the landed tree this
session; the pattern court was re-run as the standing proof.
Context: solo
Date: 2026-10-22
Repo: /Users/sac/smalt (main, shared tree — coordinator owns git)
Lane: BK-PATDRIFT
Owns: `docs/jira/v26.10.22/patterns/PATTERN-LANGUAGE.md` (only doc edited) + this receipt.

## Method

Per pattern: read the doc cell, grep the exemplar surface on disk, and where a
court exists, run it. Court executed this session (embedded output below):
`cd workspace && node scripts/pattern-court.mjs` — exit 0.

## Per-pattern verification (20 cells)

### Alexander patterns P1-P12

- **P1 Ontological Airlock** — VERIFIED. `page.tsx:121` `data-action="admit"`,
  `:84` `data-status`; browser leg PASS "admit -> COMMITTED_LOCAL, seq 0 -> 1
  (real wasm sieve + local journal commit)".
- **P2 Visible Andon Cord** — VERIFIED with prose fix. `useAndon.tsx:57-60`
  banner (`role="alert"`, `data-andon-state="RAISED"`, `data-andon-rule`);
  `useSovereignTerminal.ts:105` andon outranks phase. Browser leg PASS
  (wasm sieve refusal, HALTED_BY_SIEVE, seq unchanged).
- **P3 Monotonic Turnstile** — VERIFIED. `journal-sync.ts:195` `AppendQueue`,
  `:206` `appendQueue` singleton; `page.tsx:141,147` log/frame-seq. Browser leg
  PASS (50-burst seq 3..52 strictly monotonic).
- **P4 Local Hearth** — SURFACES VERIFIED, browser leg TYPED SKIP (court:
  "needs playwright browsers + live server (SYNC-1)"). Cell updated to carry
  the SKIP typing — was unstated before.
- **P5 Cold Ash Rehydration** — VERIFIED. `journal-sync.ts:256` `hydrate()`;
  exp1c W4/W8 folded in (hydration prefers stored seqIds, index fallback kept).
  Browser reload leg TYPED SKIP.
- **P6 Bounded Arena** — VERIFIED. `guard.ts:38` `ALLOC_CAP_EXCEEDED`, 16 MiB
  pre-worker; browser leg PASS (17MiB → andon, seq unchanged, worker survives).
- **P7 Sealed Convoy** — VERIFIED. codec 41-byte header + `0x534D4C54`; codec
  court spawned by pattern-court, exit 0.
- **P8 Fast-Forward Sluice** — VERIFIED. `useSovereignTerminal.ts:89`
  `syncUpstream`, `page.tsx:88` `data-receipt`; sync-e2e 9/9 with
  `flush-5-200-verified bytes=320 verified=true` (exp1b).
- **P9 Commutative Weave** — TYPED SKIP kept (two contexts + SYNC-1
  unwitnessed); exp1c W3 clientId identity (`journal-sync.ts:39`
  `ensureClientId`) recorded as the landed collision-class removal.
- **P10 Elastic Snapback** — VERIFIED. `journal-sync.ts:107` typed code;
  `snapback.ts` purge-to-head; sync-e2e `corruption-typed-refusal` +
  `snapback-purge-to-head` PASS (exp1b).
- **P11 Sabotage Trapdoor** — VERIFIED with case fix. Codec emits
  `code: "BAD_CRC32"` (`codec.ts:30,119`); doc's lowercase `bad_crc32`
  corrected. Wire witness `detail=BAD_CRC32 serverHeadSeq=5 purged=2` (exp1b).
- **P12 Constant Seal** — VERIFIED with update. Receipt chain is now
  seqId-sliced with gap-typed refusal (exp1c W4); 320-byte verified receipt
  re-witnessed (exp1b).

### Next.js patterns 13-20

- **13 Silent Crucible** — VERIFIED. `useJournal.ts:277` module singleton +
  distinct server snapshot; cross-evidence weblocks court L5.
- **14 Ambient Cord** — DRIFT FIXED. Doc said `[data-andon-state="TRIPPED"]`;
  landed banner emits `RAISED`/`CLEARED` (`useAndon.tsx:58`,
  `page.tsx:89`). Cell re-pointed.
- **15 Persistent Worker Pin** — VERIFIED + extended. `law-worker-bridge.ts:34,107`
  singleton; exp1a hardening (rejected-init retry, `WORKER_FAULT`) recorded;
  second instance `useWebLocks.ts:61` `WebLocksCore` (bk119b).
- **16 Reactive Hearth** — VERIFIED + extended. `useJournal.ts:280` +
  `useWebLocks.ts:115` — two consumers of the same useSyncExternalStore
  pattern; standing disclosure per bk119b.
- **17 Air-Gapped Siphon** — VERIFIED. `lib/smalt.ts:11` `assertLocalUrl`,
  `:22` `smaltFetch`; `eslint.config.mjs:22-35` bans.
- **18 Ephemeral Mask** — UNVERIFIED this session (no domain-grep run);
  cell left typed, never flipped.
- **19 Dual-Head Status** — VERIFIED. `useSovereignTerminal.ts:48`,
  `page.tsx:85` `data-machine-state`.
- **20 Frozen Console** — DRIFT TYPED, NOT FLIPPED. `workspace/next.config.mjs`
  carries NO `output: 'export'` (read in full this session); the console ships
  served (`next start`, COOP/COEP headers in the same file). The `out/`
  boots-standalone claim is unwitnessed; cell marked DRIFTED.

### Cross-cutting drift fixed in the doc prose

- Header: "each pattern's Playwright semantic verification is its court" and
  the future-tense lanes section ("PAT-A lands them") were stale — PAT-A/B/C
  landed (receipts with standings), and the court's browser tier now executes
  via system Chrome (headless-Chromium witnessing pattern,
  `BROWSER-COURT-PATTERNS.md`), not the playwright-download path pat-c typed
  SKIP on.
- Post-PAT session repairs folded into anchors: exp1a (guard fail-closed,
  bridge lifecycle), exp1b (self-contained courts), exp1c (clientId, seqId
  receipt chain, IDB refusal typing, WAL-lease abort-listener removal —
  `tab-lease.ts:214` `withWalLease`), bk119b (useWebLocks reactive lease).

## Embedded verification output

`cd workspace && node scripts/pattern-court.mjs` (exit 0):

```
totals: 13 PASS / 3 SKIP / 0 FAIL
```

Tier detail: P1/P2/P3/P6 have real browser legs PASS (system Chrome, real wasm
sieve, real `next start` boot on 127.0.0.1:46826); P4/P5/P9 typed SKIP;
dom-lint and codec-logic legs all PASS. Companion: `node scripts/dom-contract-court.mjs`
→ "dom-contract court verdict: PASS (0 failure(s))".

Non-vacuity note: the P11 case fix and the P14 TRIPPED→RAISED fix both flip a
doc cell against a literal string in the landed tree (`grep -c "TRIPPED"
BROWSER-COURT-PATTERNS.md` = 0; `grep -n 'data-andon-state="RAISED"'
useAndon.tsx` = :58) — the cells moved only because the referents moved.

## Honest limits

- P4/P5/P9 browser legs, P18 domain-grep, and P20 static-export remain typed
  SKIP/UNVERIFIED/DRIFTED — no cell was flipped without a witness.
- `output: 'export'` removal history (whether it ever existed) not
  investigated — the current-tree fact is what the cell now states.
- Line anchors are as-of this session's tree; concurrent lanes may shift them.
