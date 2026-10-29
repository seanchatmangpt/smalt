# EXPL-7 — workspace BFF routes + uncovered courts ERRC sweep (read-only)

**Standing:** **PARTIAL_ALIVE (explore lane)** — read-only sweep; findings are observations
against the working tree, no code edits. All probe commands embedded below, real output.
Context: solo
Date: 2026-10-22
Repo: /Users/sac/smalt (main)
Lane: EXPL-7

Excluded (covered by prior receipts, read first per dispatch):
`expl1-workspace-errc` (W1–W11; W1/W2/W7/W9/W10 repaired in `expl1r-w1-repair`,
`exp1b-script-hygiene`), `expl4-wirefronts-errc` (F1–F6; F5 is KD-169), `bk73-workspace-combined`,
`bk83-sync-e2e-auth`, `spof4-tab-hardening`, `bk6-validation-closures` (the duplicated
assertion-free clause pattern — none found in the eight audited courts), `pat-a-dom-contract`,
`pat-c-pattern-court`, `bk102-e2e-harness`.

## Scope actually covered

- `workspace/app/api/v1/ingest/route.ts` (130 L), `app/api/v1/stream/route.ts` (194 L),
  `app/api/sync/state/route.ts` (338 L), `app/api/bench/isr-{revalidate,stats}/route.ts`,
  `workspace/middleware.ts`.
- Courts executed (not just read): codec, receipt, snapback, dom-contract, tab-lease, spof4,
  e2e. `pattern-court` NOT executed (runs `next build`; read-only audit only) — coverage gap,
  honest.
- `route.test.ts` under `node --test`.

## Executed court receipts (fresh runs, 2026-10-22, node, cwd workspace/)

```
$ for f in codec receipt snapback dom-contract tab-lease spof4; do node scripts/$f-court.mjs; echo exit=$?
== codec     exit=0  "# codec court verdict: PASS (0 failure(s))"
== receipt   exit=0  "receipt-court: all assertions passed"
== snapback  exit=0  "snapback-court: all assertions passed"
== dom-contract exit=0 "# dom-contract court verdict: PASS (0 failure(s))"
== tab-lease exit=0  "# PASS: 7 / # FAIL: 0"
== spof4     exit=0  "# PASS: 19 / # FAIL: 0"
$ node scripts/e2e-court.mjs
# PASS=67 FAIL=0 SKIP=2
# SKIP: composition: panel rendering: DOM/Web Serial rendering is not executable in node…
# SKIP: live: popcorn iframe src: no Next server on :3100 (ECONNREFUSED)…
exit=0
$ node --test app/api/sync/state/route.test.ts
ℹ pass 14 / skipped 2 (the 2 live-POST tests skip loudly — no substrate gate)  exit=0
```

No vacuous legs found: every leg asserts real end state (store rows, etag, snapshot fields),
not call counts. BK-6's duplicated assertion-free clause class: zero matches across all eight
audited court scripts.

## Findings (ranked)

### E7-1 (top ticket) — POST /api/sync/state has NO authentication; its own header documents a session that does not exist

- **File**: `workspace/app/api/sync/state/route.ts` — header contract lines ~4–31 claim
  "Authenticity of batch entries requires the BFF session"; the handler has no session, token,
  or origin check at all. `middleware.ts` does only redirect-hygiene (open-redirect refusal +
  popcorn COOP/COEP); matcher `/api/:path*` enforces nothing auth-related.
- **Class**: missing auth neither gated nor KD-registered (EXPL-4 F5 / KD-169 class, new
  surface). `grep KD rows for bff|sync/state|ingest|storm|isr` → 0 rows.
- **Scenario**: anything that can reach the Next port can read-modify-write every doc in the
  `sync/state` cosmos container via the BFF (read etag → PUT with or without If-Match; the
  absent-baseVersion path is documented LWW overwrite of an existing doc). The Bearer/STS
  machinery in `bearer()` authenticates the BFF to the substrate, never the caller to the BFF.
- **Blast radius**: the entire sync data plane is writable through an unauthenticated BFF hop;
  CAS/LWW integrity machinery is downstream of an open door. The doc-comment premise rot
  (claiming a session gate that is not landed) makes it worse than KD-169: there the
  divergence was registered; here the contract text asserts a control that does not exist.
  This is EXPL-1 W7 premise-rot class riding a security surface.
- **Repair ticket**: either (a) land a session/shared-secret gate
  (`x-smalt-session` HMAC or loopback STS-minted caller check) with a witness court
  (unauthed POST → typed 401/403; authed → applied), or (b) register the divergence as a KD row
  (emulator posture, per KD-169 precedent) and fix the header contract text to stop claiming a
  session. Either way the false "requires the BFF session" sentence must be repaired — it is
  an unreceipted claim today.

### E7-2 — createDoc silently swaps the doc identity: `{ id, ...data }` lets `data.id` override the validated id

- **File**: `workspace/app/api/sync/state/route.ts`, `createDoc` (POST upsert body).
- **Witness** (real node run):
  ```
  $ node -e 'console.log(JSON.stringify({id:"validated-id", ...{id:"ATTACKER-ID"}}))'
  {"id":"ATTACKER-ID"}
  ```
- **Scenario**: `validateEntry` validates `entry.id` and the handler reports
  `applied: [{ id: entry.id, etag }]`, but the upsert body is `JSON.stringify({ id, ...data })`
  — the spread runs AFTER `id`, so a client `data.id` silently replaces the doc identity the
  server just validated and reported. Result: doc stored under an id the applied-row does not
  name (unreported write), or a same-key later PUT (writeDoc uses `entry.id` in the URL) 404s
  while the applied row claimed success. Silent identity swap / misattributed write.
- **Repair**: `JSON.stringify({ ...data, id })` (validated id wins) or refuse entries where
  `data.id` is present and differs (`invalid_entry`), plus a court leg: create entry with
  `data.id` ≠ `id` → stored doc id must equal the validated id or a typed refusal row returns.
- **Blast radius**: low-frequency (needs client to send `data.id`) but zero-cost to fix and
  breaks the applied-row ↔ store identity invariant.

### E7-3 — bench-lane mutating/debug endpoints unauthenticated AND unregistered (KD-169 posture, new surfaces, no rows)

- **Files**: `app/api/v1/stream/route.ts` POST (`x-smalt-storm: abort` hard-errors every
  connected SSE client), GET `?stats=1`/`?drift=1`; `app/api/v1/ingest/route.ts` GET (heap
  snapshot via `process.memoryUsage()` + token-bucket counters); `app/api/bench/isr-revalidate`
  POST (revalidatePath for arbitrary slugs), `app/api/bench/isr-stats` POST (reset/log stale
  counts).
- **Class**: same missing-auth-not-gated-not-KD-registered class as E7-1/KD-169, but these are
  self-declared bench lanes (N-4/N-6/N-7) — so the *defect* is narrower: nothing gates them to
  bench runs and nothing registers them. Contrast KD-169: the Web PubSub faces at least have a
  registered OPEN row with a close condition.
- **Scenario**: `POST /api/v1/stream` with the storm header is a one-request DoS on all
  connected console clients; the GETs leak runtime internals unauthenticated; isr-revalidate
  triggers cache invalidation for arbitrary path slugs.
- **Repair ticket**: one KD row per surface (or one grouped row: "BFF bench-lane faces are
  unauthenticated on the emulator") with close condition "env-gated
  (`SMALT_BENCH_FACES=1`) or removed from production build", plus honest header comments
  stating the emulator posture. Cheap partial: require the same HMAC gate ingest already uses.
  `grep KD rows for bff|sync/state|ingest|storm|isr` → 0 (witnessed above).

### E7-4 — e2e-court hand-copies the air-gap guard twice (drift risk against lib/smalt.ts)

- **File**: `workspace/scripts/e2e-court.mjs` lines ~409 and ~477: two separate
  `function assertLocalUrl(url)` definitions (8 occurrences total in the file), each a
  hand-copy of the canonical `lib/smalt.ts` guard.
- **Class**: harness drift / O(N²) copy class (N implementations of one calculus). If
  `lib/smalt.ts`'s guard tightens (e.g. new forbidden host), the court's live legs keep
  enforcing the stale rule and a green court no longer proves the shipped posture.
- **Repair**: extract one shared `scripts/lib/airgap.mjs` (tracked, tmp/-free per EXPL-1 W2
  lesson) imported by both legs; or a premise-drift assertion comparing the court copy against
  the lib copy's source. Low priority — currently byte-equivalent behavior.

## Premise-rot checks

- `route.ts` header claims session-gated batch authenticity → FALSE today (E7-1). This is the
  one premise rot found.
- Court header claims (codec 41-byte wire contract, receipt 320-byte seal, snapback purge
  semantics, spof4 rehydrate-before-mint) all verified by real runs above — no rot.
- `exp1b` closures held: e2e-court no longer imports tmp/ collaborators; sync_fault_probe and
  enclave-loop repairs still in place (e2e run exit 0).

## Coverage note

- `pattern-court` (487 L, runs `next build` + optional browser tier) audited by reading only;
  its exit-code contract (`process.exit(nFail > 0 ? 1 : 0)`, FAIL defaults for P1/P2/P3/P6,
  SKIP-loud records) is sound on inspection. Not executed — recorded honestly.
- ISR routes' `lib/bench/isr-counter` module not audited (file-backed event log; out of lane
  scope).

## Top-finding handoff ticket (E7-1)

- **WO**: land or register the /api/sync/state caller gate per E7-1 repair options (a)/(b).
- **Falsifier court**: unauthenticated `POST /api/sync/state` with a valid batch → must answer
  typed 401/403 (option a) or the divergence must exist as a KD row with the header text
  repaired (option b); a route that applies the batch AND still claims session-gated
  authenticity in its header is the vacuity witness.
- **Blast radius if unfixed**: unauthenticated sync-container write path + a contract comment
  asserting a security control that does not exist.

## Standing

PARTIAL_ALIVE — all embedded outputs are real fresh runs on this tree; E7-2 witnessed with a
real node execution; pattern-court and isr-counter read-only. Repair lanes own E7-1..E7-4.
