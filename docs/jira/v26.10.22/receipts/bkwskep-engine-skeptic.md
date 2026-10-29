# BK-WSKEP — adversarial skeptic re-audit of the workspace engine repairs

**Standing:** **ALIVE** (every landed claim re-verified; 2 new findings, neither invalidates a landed claim)
Context: solo
Date: 2026-10-22
Repo: /Users/sac/smalt (main, lane BK-WSKEP, read-only skeptic — no lib/ edits)
Audits: exp1a-worker-guard-repairs.md, exp1b-script-hygiene.md, exp1c-journal-sync-repairs.md, bke2er-sync-e2e-rerun.md, expl7r1-bff-repairs.md

## Falsifier legs re-run fresh (all PASS, exit 0)

```
$ node workspace/scripts/guard-court.mjs        # 17 PASS, verdict PASS, GUARD_EXIT=0
$ node workspace/scripts/exp1c-journal-court.mjs # 13/13 PASS, JOURNAL_EXIT=0
$ node workspace/scripts/sync-e2e-court.mjs      # 9/9 PASS, SYNC_EXIT=0
$ node workspace/scripts/e2e-court.mjs           # PASS=70 FAIL=0 SKIP=2 (substrate down), E2E_EXIT=0
```

Key legs witnessed fresh: SHACL_VERDICT_ABSENT typed refusal (leg c, both
halves: refusal minted AND no status-0 verdict for that shape); silent-worker
GUARD_TIMEOUT in 61ms against a 60ms bound (leg k); gap refusal on ledger
{1,2,4}: `receipt chain gap: seqId 3 missing below acked horizon lastSeq=3`;
clientId mint-once-persisted + append-carries-clientId; dbPromise
failed-open-retry + onblocked typed refusal.

## Debug-face 404s without env — re-witnessed on a fresh server (gate OFF)

```
POST /api/v1/stream          -> 404 {"error":"not_found"}
GET  /api/v1/stream?stats=1  -> 404 {"error":"not_found"}
GET  /api/v1/stream?drift=1  -> 404 {"error":"not_found"}
GET  /api/v1/ingest          -> 404 {"error":"not_found"}
POST /api/bench/isr-revalidate -> 404 {"error":"not_found"}
POST /api/bench/isr-stats    -> 404 {"error":"not_found"}
```

Gate ON (`SMALT_DEBUG_FACES=1`): storm POST -> `{"aborted":0}` 200, ingest GET
-> capacity JSON 200. Source-audited: `debugFacesEnabled()` reads
`process.env.SMALT_DEBUG_FACES === "1"` (server env only — no header
participates in the gate, so a header-case bypass is structurally impossible;
typed NO-DEFECT). All five declared faces gate every non-read-only handler;
`isr-stats` GET left open is read-only stats, matching the receipt.

## Adversarial hunt — new-defect classes

### F1 (NEW, LOW-MED): ensureClientId concurrent-mint race (exp1c W3 residue)

`ensureClientId` (workspace/lib/engine/journal-sync.ts:39) reads then writes
the clientId in two separate IDB transactions with no lease or merge rule. Two
concurrent calls on a fresh store (the two-tabs-boot-simultaneously shape)
mint DISTINCT u64s; last-writer-wins in the store; each caller returns its own
minted value. Real probe (fresh scratch, real idb-shim store):

```
A concurrent: 4528721503372322410n 16775150549687441796n DIFFERENT
A post-hoc third call: 16775150549687441796n   (sequential calls reuse stored: true)
C nonzero+u64: true
```

Consequence: a tab losing the race appends frames signed with a clientId that
is NOT the persisted page identity — a clientId split-brain within one
journal, adjacent to the exact (clientId, seq) collision class W3 closed.
Window is small (concurrent first-boot only) and the collision is per-boot,
not per-frame. Fix shape: mint inside the master WAL lease (or
get-or-create inside one readwrite tx re-read after write).

### F2 (NOTE, latent-only): rehydratePlan silent index fallback

rehydratePlan (journal-sync.ts:655) falls back to the index slice whenever
`entries.length !== frames.length` — including the entries-present-but-short
shape, which is the wrong-frame class W4 closed, taken through a SILENT
fallback instead of a typed refusal. No current caller can produce the
mismatch (hydrate() always emits equal lengths), so latent; flag is to refuse
typed if a future caller drifts.

## Hunted, no defect (typed NO-DEFECT)

- **seqId off-by-one at the lastSeq boundary**: `_flushSync` acked slice is
  `seqId <= lastSeq` and the gap loop is `1..lastSeq` INCLUSIVE
  (journal-sync.ts:532-544); contiguous {1..5} at lastSeq=5 verifies
  (sync-court leg 4) and the gap at 3<lastSeq=3 refuses typed (journal-court
  w4). Both boundary shapes court-covered.
- **dispose/timeout interplay (guard.ts)**: settle is idempotent (pending
  entry removed on first settle); timeout drops the pending entry so a late
  worker response cannot resolve a stale awaiter; dispose resolves pending
  through the same settle (clearing timers) and clears the rest. No
  double-settle, no leaked timer, no stale-await path.
- **debug-faces header-case bypass**: gate is server-env only; header names
  in the handlers (x-smalt-storm) are read only AFTER the gate. No vector.
- **caller-gate (KD-171R) host parsing**: exact-match list
  ["127.0.0.1","localhost","[::1]","::1"] after port strip; suffix
  ("127.0.0.1.evil.com") and non-lowercase hosts fail CLOSED (403); Origin
  hostname is WHATWG-lowercased. No bypass; over-rejection only.
- **secret timing compare**: length-prefixed timingSafeEqual with a burned
  comparison on length mismatch — no missing-vs-wrong oracle.
- **W8 dead wrappers**: grep confirms zero live callers of
  `markSynced`/`snapbackStoreOps`/`leasedLoose` (only `_`-prefixed internals
  and court assertions on absence).

## Regression courts (fresh, this lane)

All four node courts green (see top). W2 fresh-clone falsifier holds
structurally: `tmp/witness` absent from the tree; zero references to it in
workspace/{lib,scripts,app}.

## Standing

ALIVE — every landed claim in the five audited receipts re-verified on the
current tree with real runs. Two new findings filed (F1 LOW-MED race, F2
latent note); neither flips a landed claim.
