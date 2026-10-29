# WSKEP-R1 — clientId mint+persist atomic (F1) + loud rehydratePlan fallback (F2)

**Standing:** **ALIVE**
Context: solo
Date: 2026-10-22
Repo: /Users/sac/smalt (main, lane WSKEP-R1)
Files: `workspace/lib/engine/journal-sync.ts`, `workspace/scripts/exp1c-journal-court.mjs`
Closes: BK-WSKEP F1 (LOW-MED) and F2 (latent note) from `bkwskep-engine-skeptic.md`

## Fix 1 (F1): atomic clientId read-mint-write

`ensureClientId` (journal-sync.ts:39) previously ran a readonly get tx, then a
separate readwrite put tx with no serialization: two concurrent first-boot
callers minted DISTINCT u64s, last-writer-wins, the loser signed frames with a
non-persisted identity.

New shape (module's own pattern-3 idiom):
- the whole read-mint-write runs through a dedicated FIFO turnstile
  (`clientIdQueue = new AppendQueue()`), so concurrent in-page callers
  serialize deterministically;
- the mint+persist is a SINGLE `readwrite` transaction (get → put → commit),
  so under real IndexedDB store-scope write atomicity a cross-tab loser reads
  the winner's committed identity instead of overwriting it.

Non-vacuity BEFORE probe (HEAD module, byte-copy scratch, real idb-shim store,
concurrent `Promise.all([ensureClientId(), ensureClientId()])`):

```
BEFORE(HEAD): a=3220181481172676189 b=1754243384292337298 DIFFERENT posthoc=1754243384292337298 match=false
```

After (court leg L9): both callers + a post-hoc third call land on ONE
persisted identity.

## Fix 2 (F2): loud rehydratePlan index fallback

`rehydratePlan` still falls back to index-derived seqIds only for
pre-entries callers (spof4 leg-4 surface unchanged — leg passes untouched),
but an entries-present-but-short hydration now logs
`rehydratePlan: entries.length (N) !== frames.length (M) — index fallback in
use; stored seqIds untrusted for this hydration` instead of drifting
silently. No current caller can produce the mismatch.

## Court (exp1c-journal-court.mjs, 13 → 16 legs)

New legs:
- `f1.concurrent-first-boot-single-identity` — two simultaneous
  `ensureClientId` calls + post-hoc third on a fresh store: all three return
  the same u64 AND the store holds exactly that one clientId.
- `f2.entries-frames-mismatch-fallback-is-loud` — mismatch shape warns AND
  still returns the index plan.
- `f2.no-entries-fallback-stays-quiet` — the legacy no-entries caller shape
  logs nothing.

```
$ node workspace/scripts/exp1c-journal-court.mjs   # 16/16 PASS, JOURNAL_EXIT=0
$ node workspace/scripts/sync-e2e-court.mjs        # 9/9 PASS, SYNC_EXIT=0 (enforce, boot :18543)
$ node scripts/spof4-court.mjs                     # 19/19 PASS, SPOF_EXIT=0
$ npm run lint (workspace)                         # 0 errors, LINT_EXIT=0
```

Journal leg witness:

```
[PASS] f1.concurrent-first-boot-single-identity :: a=12095188549803664623 b=12095188549803664623 posthoc=12095188549803664623 stored=12095188549803664623
[PASS] f2.entries-frames-mismatch-fallback-is-loud :: frames=1,2,3 warn=rehydratePlan: entries.length (2) !== frames.length (3) — index fallback in use; stored seqIds untrusted for this hydration
[PASS] f2.no-entries-fallback-stays-quiet :: warned=false
SUMMARY: 16/16 PASS, 0 FAIL
```

Environment notes (typed, neither session-introduced):
- `spof4-court` tsc leg requires cwd with `@types/node` resolvable — run from
  `workspace/` (`node scripts/spof4-court.mjs`); from repo root it fails
  TS2688 (pre-existing resolution sensitivity, independent of this diff).
- First sync-e2e attempt exited 2: substrate boot hit another lane's
  in-flight `lib/smalt/attestation/maa.ex` compile error (compile-freeze
  class, disclosed; not this lane's lease). Retry after that lane's unblock
  landed green 9/9.

## Standing

ALIVE — F1 closed by fix + non-vacuity BEFORE/AFTER witness + regression
courts; F2 closed by loud-fallback legs; no landed claim flipped.
