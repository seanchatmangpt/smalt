# BK-83 — Authenticated sync end-to-end witness (full client path, enforce mode)

**Standing:** **ALIVE** (9/9 legs PASS, court exit 0)
Context: solo

## Subject

- Court: `workspace/scripts/sync-e2e-court.mjs` (plain node, no new deps;
  self-contained: spawns the runtime, pins the asdf OTP-29 toolchain in the
  child env, boots enforce-mode, runs all legs, kills the runtime). Exit
  0 pass / 1 court fail / 2 substrate never up.
- Client: byte-copies of the workspace engine — `journal-sync.ts`,
  `codec.ts`, `receipt.ts`, `merkle.ts`, `snapback.ts`, `tab-lease.ts` +
  `smalt.ts` under `tmp/witness/bk83/engine/` (+`../smalt.ts`). The FULL
  public client path ran: `appendLocal` → `flushSync` → snapback, over a
  real in-memory IndexedDB shim (`tmp/witness/bk83/idb-shim.mjs` — real
  Maps, real deletes, real cursor writes; asserted on final state).
- Server: real `Smalt.EgressRouter` + real `Smalt.Sync.Store` + real
  `Smalt.ArmGateway.Router` (the production STS mint face) served by Bandit
  on 127.0.0.1:18543 (sync) / :18581 (STS), auth `:enforce`, compiled in
  `MIX_BUILD_ROOT=_build-bk83` (OTP 29.1.2 / Elixir 1.20.4-otp-29 asdf
  toolchain; `mix compile` exit 0).
- Scoping: the air-gap law governs the BROWSER page. This is a node court —
  plain fetch to loopback is what the server sees; `smaltFetch`'s
  assertLocalUrl guard is exercised in the workspace lint surface (pat-e).

## Disclosed deltas vs workspace/lib/engine (byte-copy discipline)

Path-only (node type-stripping import specifiers, no semantics):
`./codec`→`./codec.ts` etc. (5 files), `../smalt`→`../smalt.ts`.

Semantic (each follows the module's own documented contract; the workspace
lib/ defects below are NOT fixed in lib/ — owner-lane repair, not this lane):

1. **AUTH-SEAM**: copied `journal-sync.ts` adds `setSyncAuthHeader(h)` and
   threads `Authorization: Bearer <token>` into the flushSync smaltFetch
   call. The browser surface has no token wiring into flushSync today —
   flushSync cannot pass enforce-mode auth as landed. (Owner finding.)
2. **Raw snapback ops in the refusal path**: workspace wires the refusal
   path through the LEASE-WRAPPED public `snapbackStoreOps()` /
   `markSynced()` while flushSync holds the master WAL lease — a nested
   same-client Web Locks request DEADLOCKS (witnessed live: the flush
   promise never settles; Node 26 exposes real `navigator.locks`, so the
   browser hits the identical deadlock). The copy uses the documented
   SPOF-4.3 INTERNAL ops (`_snapbackStoreOps()` / `_markSynced()`). Two
   call sites. The court's corruption leg was the first witness.
3. **P12 cumulative-receipt divergence** (asserted honest, not repaired):
   the server seals the CUMULATIVE per-client chain (leg-6 token:
   leafCount=6 over frames 1..6) while the workspace P12 check in
   flushSync verifies only the flushed parts — `verified:false` on ANY
   flush after the first, browser engine included. Leg 6b proves the
   security property directly: the cumulative receipt verifies against the
   FULL local frame ledger (verified=true, leafCount=6, localFrames=6).

## Per-leg transcript (final run, court exit 0)

```
BOOT_OK :: BK83_BOOT_OK enforce sync=:18543 sts=:18581
[PASS] auth.tokenless-401-challenge :: status=401 www-authenticate=Bearer authorization="http://127.0.0.1:9443/organizations", resource="http://127.0.0.1:18543", error="invalid_token", error_description="MissingBearerToken"
[PASS] auth.sts-mint :: expires_in=3600 jws-segments=3
[PASS] auth.tokenless-flushSync-refused :: ok=false code=SYNC_HTTP status=401
[PASS] sync.flush-5-200-verified :: ok=true lastSeq=5 verified=true bytes=320 leaves=5 markedTo=5
[PASS] sync.cursor-advanced :: cursor=5
[PASS] sync.corruption-typed-refusal :: code=SYNC_REFUSED_BY_SERVER detail=BAD_CRC32 serverHeadSeq=5 purged=2
[PASS] sync.snapback-purge-to-head :: cursor=5 unsynced=0 currentSeq=5
[PASS] sync.clean-resync :: ok=true lastSeq=6 bytes=320 p12-verified=false (false = P12 divergence, KD-candidate)
[PASS] sync.cumulative-receipt-vs-full-ledger :: verified=true leafCount=6 localFrames=6 root=e45871f4ae3ea8b2
SUMMARY: 9/9 PASS, 0 FAIL
```

## Commands / exits

```
MIX_BUILD_ROOT=_build-bk83 mix compile                     exit 0
node workspace/scripts/sync-e2e-court.mjs                  exit 0, SUMMARY 9/9 PASS
```

(OTP 29.1.2 / Elixir 1.20.4-otp-29 asdf toolchain pinned in the court's
child env; the court's own waitUp poll bounds substrate boot at 240s.)

## Findings for owner lanes (lib/ untouched by this lane)

1. flushSync has no Authorization wiring (enforce mode would 401 every
   flush from the browser) — the AUTH-SEAM is the seam a browser fix must
   thread.
2. flushSync refusal path deadlocks under real Web Locks (nested
   same-client lock request). Repair: use the documented SPOF-4.3 internal
   ops. First witness: this court's corruption leg.
3. P12 verified is false on any flush after the first (cumulative-receipt
   vs partial-parts). KD-candidate: register with the cumulative-sealing
   server contract as evidence.
4. BK-76's receipt (docs/jira/v26.10.22/receipts/bk76-sync-auth-witness.md)
   was not on disk during this window — this receipt does not consolidate
   with it.

## Falsifier status

- Tokenless 401 + WWW-Authenticate challenge (KD-15 shape): verified.
- Real STS mint (grant_type=client_credentials, tenant route) → 3-segment
  JWS, expires_in 3600: verified.
- Tokenless flushSync → typed SYNC_HTTP 401: verified.
- 5 appends → authenticated flush → 200, 320-byte receipt, verified:true,
  cursor=5: verified.
- Client-side frame corruption → BAD_CRC32 typed refusal + snapback
  purge-to-head (purged=2, cursor=5, unsynced=0): verified.
- Clean re-sync 200 lastSeq=6 + cumulative receipt verifies against the
  full local ledger: verified.

## Not committed

Per lane contract: court + engine copies + receipt left uncommitted for
the coordinator.
