# BK-106 — Sync engine fixes: auth seam, lease-nesting deadlock, P12 cumulative verify

**Standing:** **ALIVE** (sync-e2e-court 9/9 ×2 exit 0 against the fixed engine; spof4 19/19, receipt, snapback courts exit 0; ws-lint / ws-build exit 0)
Context: solo
Date: 2026-10-21
Repo: /Users/sac/smalt (main)

## Subject

The three engine defects BK-83's e2e court witnessed
(`docs/jira/v26.10.22/receipts/bk83-sync-e2e-auth.md`, "Findings for owner
lanes") are fixed in the workspace engine:

- `workspace/lib/engine/journal-sync.ts`
- `workspace/lib/engine/useJournal.ts`
- `workspace/lib/engine/useSovereignTerminal.ts` + `workspace/app/terminal/page.tsx` (additive browser wiring)
- `workspace/scripts/sync-e2e-court.mjs` (leg 6 asserts the fixed semantics)

Files NOT changed: `workspace/lib/engine/tab-lease.ts` (byte-identical to
HEAD — the PAT/SPOF-4 lanes' landed surface; no edit owed), `lib/` (Elixir
side untouched — the server contract is correct per BK-83).

## Per-defect diff

### Fix 1 — flushSync Authorization wiring (BK-83 finding 1, AUTH-SEAM landed)

The court's copied module added `setSyncAuthHeader(h)`; the browser lib had
no token wiring. Landed the seam exactly as the copy showed the shape:

- `journal-sync.ts`: module-level `setSyncAuthHeader` / `syncAuthHeader()`
  seam; `_flushSync` threads `Authorization: Bearer <token>` into the
  smaltFetch call when a token is present (per-call `opts.authHeader`
  overrides the module seam); empty = tokenless → typed SYNC_HTTP 401.
- `useJournal.ts`: `JournalSyncEngine.setAuthToken(token)`; `sync()` passes
  `authHeader: this.authToken` into flushSync.
- `useSovereignTerminal.ts`: `setToken` passthrough on the terminal surface.
- `app/terminal/page.tsx`: additive token input (`data-slot="sync-token-input"`)
  wired through `wireToken` → engine → flushSync. Tokenless default keeps
  enforce-mode honesty (typed 401 + snapback law unchanged, server-side).

### Fix 2 — lease-nesting deadlock (BK-83 finding 2, SPOF-4.3 internal-ops design)

flushSync holds the master WAL lease; its refusal path called the
LEASE-WRAPPED `snapbackStoreOps()` → `setCursor` → public `markSynced` — a
nested same-client `navigator.locks` request, deadlocking under real Web
Locks (witnessed live on Node 26). Two call sites switched to the internal
ops (lease holder executes directly, no re-acquisition):

- `applySnapback` now runs `snapbackWithStore(_snapbackStoreOps(), …)` (was
  the public lease-wrapped `snapbackStoreOps()`).
- `_snapbackStoreOps().setCursor` now calls raw `_markSynced(seq)` (was the
  public lease-wrapped `markSynced`).

The e2e court's corruption leg (leg 5) is the witness: the flush promise
settles (typed SYNC_REFUSED_BY_SERVER, purged=2) where the pre-fix engine
deadlocked.

### Fix 3 — P12 cumulative-receipt divergence (BK-83 finding 3, KD-165)

The server seals the cumulative per-client chain (leafCount over every
committed frame); the client verified only the flushed parts — verified:false
on any flush after the first. `_flushSync` now verifies against the FULL
local frame ledger sliced to the acked horizon (`hydrate()` frames, index
≤ lastSeq). Leg 6b's security property is now the client law: the cumulative
receipt verifies against the full local ledger. Leg 6 in the court updated to
assert `p12-verified=true` (cumulative ledger verify, KD-165 fix). KD-165
minted in the canonical register
(`docs/jira/v26.10.14/KNOWN_DIVERGENCES.md`), pointer doc bumped
(`docs/jira/v26.10.21/KNOWN_DIVERGENCES.md`: KD-01..KD-165, 162 rows, mint
from KD-166).

## Commands / exits

```
node workspace/scripts/sync-e2e-court.mjs     exit 0, 9/9 PASS (run 1)
node workspace/scripts/sync-e2e-court.mjs     exit 0, 9/9 PASS (run 2)
cd workspace && node scripts/spof4-court.mjs  exit 0, 19 PASS / 0 FAIL
node workspace/scripts/receipt-court.mjs      exit 0, all assertions passed
node workspace/scripts/spof4-court.mjs (workspace cwd) — see above; from repo root the court's tsc cannot resolve @types/node (court cwd contract, pre-existing)
just ws-lint                                  exit 0 (0 errors, 45 pre-existing warnings)
just ws-build                                 exit 0
python3 scripts/kd_flip.py                    exit 0, FLIP-ELIGIBLE: 0 / FLIP-PENDING-WITNESS: 0
just kd-stale                                 exit 0 (post-mint skew check)
just docs-dod-check                           exit 0
```

Run 1 transcript (both runs identical shape):

```
BOOT_OK :: BK83_BOOT_OK enforce sync=:18543 sts=:18581
[PASS] auth.tokenless-401-challenge :: status=401 www-authenticate=Bearer authorization="http://127.0.0.1:9443/organizations", resource="http://127.0.0.1:18543", error="invalid_token", error_description="MissingBearerToken"
[PASS] auth.sts-mint :: mint.access_token jws-segments=3
[PASS] auth.tokenless-flushSync-refused :: ok=false code=SYNC_HTTP status=401
[PASS] sync.flush-5-200-verified :: ok=true lastSeq=5 verified=true bytes=320 leaves=5 markedTo=5
[PASS] sync.cursor-advanced :: cursor=5
[PASS] sync.corruption-typed-refusal :: code=SYNC_REFUSED_BY_SERVER detail=BAD_CRC32 serverHeadSeq=5 purged=2
[PASS] sync.snapback-purge-to-head :: cumulative-receipt-vs-full-ledger
[PASS] sync.clean-resync :: ok=true lastSeq=6 bytes=320 p12-verified=true (cumulative ledger verify, KD-165 fix)
[PASS] sync.cumulative-receipt-vs-full-ledger :: verified=true leafCount=6 localFrames=6 root=5e446035b3fdcbaf (run 1) / ff6d1620b9eff474 (run 2)
SUMMARY: 9/9 PASS, 0 FAIL
```

## KD-165 register diff (canonical, 1 insertion)

```
| KD-165 | workspace sync engine — client P12 receipt verify (`workspace/lib/engine/journal-sync.ts` flushSync) | server seals the CUMULATIVE per-client frame chain (leafCount over every committed frame 1..lastSeq, not just the flushed batch); client verified only the flushed parts — verified:false on any flush after the first | BK-83 witness (bk83-sync-e2e-auth.md) + BK-106 fix receipt (bk106-sync-engine-fixes.md) | fix landed in the client verifier; falsifier: sync-e2e-court red on leg 6 (p12-verified=false), or receipt-court negative green while a partial-parts verify passes | CLOSED-WITH-EVIDENCE |
```

Pointer doc (`docs/jira/v26.10.21/KNOWN_DIVERGENCES.md`): range KD-01..KD-165
(162 rows), mint-from KD-166, "Rows minted this window" bullet for KD-165,
closing note "All five minted 2026-10-21 … KD-165 by BK-106's
sync-engine-fixes lane".

## Court notes

- The e2e court imports the engine byte-copies under
  `tmp/witness/bk83/engine/`; refreshed from the fixed lib (sed path-only
  import-specifier deltas, `./codec` → `./codec.ts`); copy-vs-lib diff is
  path-only, verified byte-discipline
  (`diff <(sed 's|.ts"|"|g' copy) lib` clean).
- spof4-court must run from the workspace cwd — from the repo root its tsc
  invocation cannot resolve `--types node` (pre-existing court cwd contract,
  not this lane's defect; exit 0 from workspace cwd, 19/19).

## Falsifier status

- Tokenless flushSync → typed SYNC_HTTP 401 (auth seam wired, honesty kept): verified ×2.
- Corruption leg settles (no deadlock; typed refusal + snapback purge-to-head): verified ×2.
- Cumulative receipt verifies against the full local ledger on the second flush (leg 6 verified=true, leafCount=6): verified ×2.
- Negative: receipt-court's "frames not under the receipt → verified false" green — the verifier still refuses receipts that don't cover the presented frames.

## Not committed

Per lane contract: diffs left uncommitted for the coordinator.
