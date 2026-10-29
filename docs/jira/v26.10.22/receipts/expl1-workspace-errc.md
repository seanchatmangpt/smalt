# EXPLORE-1 (expl1) — workspace/ ERRC sweep: engine, terminal page, workers, courts

**Standing:** **ALIVE (explore lane)** — read-only sweep, all findings are observations
against the working tree at HEAD `23976f3` (+dirty `lib/smalt/messaging/event_hubs.ex`,
`test/integration/amqp10_debug_test.exs` — unrelated surfaces). No code edits, no commit.
Context: solo
Date: 2026-10-21
Repo: /Users/sac/smalt (main)

Excluded (already covered by landed receipts, read first per dispatch):
bk73-workspace-combined, bk114-verification-reruns (its sync-e2e-court home-path
finding is CLOSED — 0 `/Users/sac` literals remain in the file), spof4-tab-hardening,
bk83-sync-e2e-auth, bk92-receipt-sot, bk102-e2e-harness, bk106-sync-engine-fixes.

---

## Full findings list (ranked)

### W1 — SHACL admission gate fails OPEN on response-shape drift (top ticket)

- **File**: `workspace/workers/law-reticle.worker.ts` `evaluate()` (lines 168–177)
- **Class**: fail-open admission guard / security
- **Scenario**: op-1 (SHACL preflight) admits unless `r.value.conforms === false`.
  A graphlaw artifact whose shacl response omits `conforms` (ABI drift, version
  skew between the pinned wasm and the worker's JSON contract, a capabilities
  change) falls through every check to `return { status: 0 }` — every payload
  admits, no andon raised, frames journal and sync as if sieved. The guard's
  entire purpose (sieve before journal) silently disappears while all DOM
  verdict fields keep reporting a healthy status 0. Note the asymmetry with the
  worker's own other checks: `loadWasm` fail-closes on missing exports; only
  the admission verdict itself fails open.
- **Blast radius**: the law layer's integrity property ("no frame is journaled
  without sieve admission") is void on a one-field ABI drift; every downstream
  receipt/merkle seal inherits the un-sieved frame. Silent — no andon, no log.
- **Patch (shape)**: op-1 requires `conforms === true` (`r.value.conforms !== true`
  → status 1 with a typed reason, e.g. `SHACL_VERDICT_ABSENT`). Same strictness
  the `loadWasm` import-surface check already applies.
- **Falsification court**: node court that stubs `WebAssembly` with a fake
  instance whose `gl_call` returns `{"ok":true}` (no `conforms`) for a shacl
  request → `evaluate`/admit must refuse typed (status 1); with
  `{"ok":true,"conforms":true}` it must admit. A court that still admits the
  conforms-absent response is the vacuity witness.

### W2 — committed court imports an untracked (gitignored) collaborator

- **File**: `workspace/scripts/sync-e2e-court.mjs` line 9
- **Class**: harness durability / SPOF (BK-73 stale-artifact class cousin)
- **Scenario**: the committed BK-83 court imports
  `../../tmp/witness/bk83/idb-shim.mjs`; `/tmp/` is gitignored (`.gitignore:19`).
  Any fresh clone, or any `tmp/` cleanup, and the court dies at import with
  MODULE_NOT_FOUND — `just ws-court`-family green on this machine, dead on the
  next. The IndexedDB collaborator BK-102 hardened lives outside version
  control: the exact "court truth lives in scratch" failure the BK-73 stale-dir
  incident foreshadowed.
- **Blast radius**: sync e2e verification unrunnable outside this one checkout;
  court receipts (bk83/bk102/bk106) are unreplayable on a fresh clone.
  Deterministic — likelihood 1.0 on clean clone.
- **Patch**: move `tmp/witness/bk83/idb-shim.mjs` (and the court's boot.exs
  dependency, same class) under `workspace/scripts/` or `workspace/test/`,
  tracked; keep `tmp/` scratch-only per the KD/shim-court law.
- **Falsification**: `rm -rf tmp/witness && node workspace/scripts/sync-e2e-court.mjs`
  → must still run (today: MODULE_NOT_FOUND).

### W3 — hardcoded `clientId = 0n` on the browser append path

- **File**: `workspace/lib/engine/useSovereignTerminal.ts` line 61
  (`globalJournalEngine.append(0n, 1, bytes)`)
- **Class**: wire-contract violation (codec.ts: "seqId monotone per clientId")
- **Scenario**: the page mints no client identity; every console forever sends
  clientId 0. Two consoles (two machines, or a wiped IndexedDB) both mint
  (0, seq 1…n) — the server's per-client head tracking sees duplicate
  (clientId, seqId) pairs → refusal/snapback storms. The BK-83 court itself
  mints `0x636300 + pid`, disclosing the contract the page ignores.
  Under the single-origin single-machine court topology it never fires —
  premise holds only in the court, not in deployment.
- **Blast radius**: cross-client collision class; sync refusals purge un-acked
  frames via snapback (data loss is bounded but real).
- **Patch**: persist a random u64 clientId in the `sync_cursor` store on first
  init; thread through appendLocal.
- **Falsification**: two engines, distinct persisted clientIds, same server →
  both sync clean; force equal clientIds → typed server refusal.

### W4 — receipt verification slices the ledger by array INDEX, not seqId

- **File**: `workspace/lib/engine/journal-sync.ts` lines 446–449
- **Class**: correctness (fails safe, fails wrong)
- **Scenario**: `ledger.value.frames.filter((_, i) => i + 1 <= lastSeq)` assumes
  `frames[0].seqId === 1` and full contiguity. Any mid-ledger gap (a failed
  `deleteSeqIds` — which swallows errors and returns 0, another accounting
  gap — or a partial snapback) maps the WRONG frames into the chain slice:
  `verified:false` on a fully-consistent ledger, or `syncedSeq` advanced past
  frames never actually sealed.
- **Blast radius**: spurious unverified seals; silent, only surfaced via the
  P12 DOM bit.
- **Patch**: carry `{seqId, frame}` through hydrate and filter on
  `s.seqId <= lastSeq`; make `deleteSeqIds` report real deletion counts
  (IDB `store.delete` never reports misses — count via cursor or get-then-delete).
- **Falsification**: seed ledger with seqIds {1,2,4} (gap at 3), lastSeq=3 →
  current code verifies the wrong chain slice; patched code must refuse typed
  (gap detected) or verify against exact seqIds.

### W5 — openDb negative-caches a failed open forever

- **File**: `workspace/lib/engine/journal-sync.ts` (`dbPromise`, lines 85–107)
- **Class**: unhandled promise path / availability
- **Scenario**: `dbPromise` memoizes the open promise; on rejection it is never
  cleared. A transient failure (version-migration contention, tab restore,
  storage pressure) permanently bricks the journal for the page lifetime —
  every later op refuses STORE_FAILURE with no retry path. Also `open.onblocked`
  is unhandled: a blocked version upgrade hangs the open promise silently.
  Corollary in tab-lease: `withWalLease`'s external-signal abort listener is
  never removed (per-call leak, bounded by page lifetime).
- **Blast radius**: one transient IDB failure → journal dead until reload.
- **Patch**: reset `dbPromise = null` in the rejection path; add `onblocked`
  → typed STORE_FAILURE.
- **Falsification**: make the first open reject (real IDB, `indexedDB.open`
  monkey-free: use a blocked version upgrade), then recover and call hydrate →
  must succeed on retry (today: permanent STORE_FAILURE).

### W6 — Guard/worker lifecycle swallows in-flight admissions

- **Files**: `workspace/lib/engine/guard.ts` (dispose, lines 111–115),
  `workspace/lib/engine/law-worker-bridge.ts` (init, lines 50–67),
  `workspace/workers/law-reticle.worker.ts` (onmessage, lines 183–220)
- **Class**: unhandled promise paths (BK-102 accounting class)
- **Scenario**: three compounding gaps. (a) `Guard.dispose()` clears `pending`
  without resolving — every in-flight `admit()` promise never settles; the
  terminal's `busy` flag clears but the awaiter hangs. (b) `LawWorkerBridge`
  memoizes a REJECTED `readyPromise` forever on INIT failure — one failed
  worker spawn and every subsequent `admit()` throws `INIT failed` for the
  page lifetime, no retry. (c) worker `unpack4` throws inside `onmessage`
  (malformed frame) → no response posted, unhandled rejection in the worker,
  and `Guard.call` has no timeout — the main-thread admission hangs forever,
  silently.
- **Blast radius**: any single worker fault (bad spawn URL, malformed frame,
  wasm fetch 404 after INIT succeeded once) converts into a silent permanent
  hang or a permanently dead sieve with no andon and no recovery path.
- **Patch**: dispose resolves pending with typed GUARD_FAULT; init clears
  readyPromise on rejection; Guard.call carries a bounded timeout refusing
  typed; worker onmessage wraps the body in try/catch posting a status-2
  verdict.
- **Falsification**: terminate the worker mid-admit → admit must refuse typed
  within the bound (today: never settles).

### W7 — premise rot: receipt.ts header claims the server minter "has not landed"

- **File**: `workspace/lib/engine/receipt.ts` lines 4–8
- **Class**: premise rot (b)
- **Scenario**: the module header still reads "DISCLOSED, not yet coordinated
  with SYNC-1 — its server code has not landed; this module defines the
  proposal". BK-92 (`bk92-receipt-sot.md`, ALIVE) proved the server minter
  (`lib/smalt/sync/receipt.ex`) landed and is byte-identical cross-mint. The
  comment contradicts both the tree and the receipt chain; a reader budgets
  coordination work that is already done and closed.
- **Patch**: replace the paragraph with the BK-92 receipt pointer
  (byte-identical mint faces, hex-only mint, hex∪base64 parse superset).

### W8 — dead lease-wrapped public wrappers (`markSynced`, `snapbackStoreOps`)

- **File**: `workspace/lib/engine/journal-sync.ts` lines 533–560
- **Class**: dead code (d)
- **Scenario**: zero callers anywhere in the tree (census: each symbol appears
  only in its own definition — internal raw `_markSynced`/`_snapbackStoreOps`
  serve all real paths after the BK-83 deadlock repair). They are advertised
  as "the public lease-wrapped surface" (SPOF-4.3 comments) — an unreceipted
  claim of a maintained surface that nothing exercises; a future caller would
  inherit untested semantics (note `snapbackStoreOps.setCursor` routes through
  `markSynced`, re-requesting the lock — the exact nested-lock deadlock the
  BK-83 repair removed from the internal path).
- **Patch**: delete both wrappers (or wire one court leg through them and
  fix `setCursor` to the raw `_markSynced`).

### W9 — sync_fault_probe readiness check is dead code; typed exit lost

- **File**: `workspace/scripts/sync_fault_probe.mjs` lines 269–280
- **Class**: dead branch / degraded failure mode
- **Scenario**: `pollUntil` resolves true or THROWS on timeout — it never
  returns false, so `if (!ready)` is unreachable and the documented typed
  `[FAIL] BFF route never became ready` + exit 1 path never runs; a timeout
  surfaces as an unhandled rejection stack instead of the court's own verdict
  line (exit code is still non-zero, so the gate holds, but the receipt
  contract in the header is not what executes).
- **Patch**: `try { await pollUntil(...) } catch (e) { console.error(...); process.exit(1); }`.

### W10 — enclave-loop classifies transport TIMEOUT as SKIP-LOUD

- **File**: `workspace/scripts/enclave-loop.mjs` (`is5xxOrNetError`, line 136)
- **Class**: court leniency (loud, but misclassified)
- **Scenario**: `AbortError`/`TimeoutError` → SKIP-LOUD. A substrate that is
  up but hung (the exact state a 10 s timeout detects) is disclosed as a skip,
  not a FAIL — the verdict line reads PASS=x FAIL=0 SKIP=1 for a genuinely
  faulted leg. Loud, but the classification inverts the observation.
- **Patch**: timeouts on a substrate that already answered the STS mint
  (proof of liveness) should FAIL; only pre-mint transport failure is a skip.

### W11 — andon `HALTED_BY_SIEVE` has no provenance and outlives its cause

- **Files**: `workspace/lib/engine/useAndon.tsx` / `useSovereignTerminal.ts` lines 82–85
- **Class**: design gap (ranked last; judgment, not defect)
- **Scenario**: `status` derivation overrides every journal phase with
  `HALTED_BY_SIEVE` whenever `andon.raised`, and the andon is raised for
  cap refusals, worker GUARD_FAULT, and SHACL refusals alike — the terminal
  cannot distinguish "frame guilty" from "sieve down" (rule string only),
  and after acknowledge the status snaps back as if nothing happened; no
  snapshot field remembers that the last admitted frame was refused. The
  pattern-19 contract ("derived, never stored twice") holds, but the refusal
  HISTORY is dropped on the floor — the DOM contract courts assert only the
  live state, so nothing fails today.
- **Patch**: carry `lastRule` into the derived status block
  (`HALTED_BY_SIEVE:<rule>` or a `data-last-refusal` attr) with a court leg.

---

## Top-finding handoff ticket

```
TICKET:      EXPLORE1-W1 — SHACL admission gate fails open on response-shape drift
OWNER:       repair lane (coordinator dispatch)
SURFACE:     workspace/workers/law-reticle.worker.ts, evaluate(), op===1 branch
CLASS:       fail-open admission guard / security
SEVERITY:    high (integrity of the law layer) | LIKELIHOOD: medium (ABI drift)
FAILURE:     graphlaw shacl response {ok:true} without `conforms` admits the
             payload — sieve void, no andon, frame journaled + sealed.
PATCH:       op-1 requires conforms === true; absent verdict -> status 1
             "SHACL_VERDICT_ABSENT" (mirror loadWasm's fail-closed import check).
COURT:       node court, fake gl_call: {"ok":true} -> admit MUST refuse typed;
             {"ok":true,"conforms":true} -> admit; {"ok":true,"conforms":false}
             -> refuse with focus/component detail. Non-vacuity: the conforms-
             absent leg must flip on the one-line fix.
EXCLUSIONS:  op-2 (N3) semantics unchanged; do not tighten ok!==true handling.
FALSIFIER:   the court above still passing after the patch => gate vacuous.
```

---

## Coverage note

Read in full: lib/engine/{journal-sync,tab-lease,useJournal,useSovereignTerminal,
codec,receipt,merkle,snapback,guard,law-worker-bridge,useAndon}.ts(x),
app/terminal/page.tsx, workers/law-reticle.worker.ts,
scripts/{enclave-loop,sync_fault_probe}.mjs; targeted reads: sync-e2e-court,
spof4-court, tab-lease-court, pattern-court (grep-level), azure probes
(grep-level). EXPORTS dead-code census run over app/lib/workers/scripts/test.
IND-pack client walkthroughs: no `IND pack` walkthrough docs exist under
docs/jira/v26.10.22 — the nearest surfaces are docs/PACK_INTEGRATION/*.md
(16 files, integration notes, not client walkthroughs) and were not swept
line-by-line this lane; flagged as a coverage gap, not a finding.
Uncovered this lane (residual for a future wave): full line-reads of
e2e-court.mjs, pattern-court.mjs, spof4-court.mjs, tab-lease-court.mjs,
dom-contract-court.mjs, codec-court.mjs, receipt-court.mjs, snapback-court.mjs,
azure-dataplane-probe.mjs, azure-arm-probe.mjs, and the workspace BFF routes
(app/api) — the courts are green at HEAD and their internals were sampled,
not exhausted.