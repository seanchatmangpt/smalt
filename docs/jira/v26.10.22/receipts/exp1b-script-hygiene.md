# EXP1-B — script hygiene repairs (EXPLORE-1 W2, W7, W9, W10)

**Standing:** **ALIVE** — all four findings repaired with real-run witnesses; the
fresh-clone falsifier (`rm -rf tmp/witness`) passes 9/9.
Context: solo
Date: 2026-10-22
Repo: /Users/sac/smalt (main, dirty shared tree — concurrent lanes active)
Base at dispatch: HEAD 7e0cb006

## W2 — sync-e2e-court no longer imports untracked tmp/ collaborators

`workspace/scripts/sync-e2e-court.mjs` imported `../../tmp/witness/bk83/
idb-shim.mjs` (gitignored `/tmp/`): dead on fresh clone. Repaired:

- `tmp/witness/bk83/idb-shim.mjs` → `workspace/scripts/bk83/idb-shim.mjs`
  (tracked, byte-identical copy)
- `tmp/witness/bk83/boot.exs` → `workspace/scripts/bk83/boot.exs` (tracked,
  byte-identical copy; the court's spawn path updated to
  `workspace/scripts/bk83/boot.exs`)
- The court's remaining tmp/ collaborators (node-runnable engine `.ts`
  copies + `smalt.ts`) are now GENERATED at court start by
  `genEngineScratch()` from the tracked `workspace/lib/engine/*.ts` and
  `workspace/lib/smalt.ts` (single source of truth — kills the BK-73
  stale-copy drift class) into an OS temp dir, with import specifiers
  rewritten to explicit `.ts` (node type-stripping requires extensions).
- `tmp/witness/` deleted; nothing in the tree references it anymore.

Falsifier — `rm -rf tmp/witness` then run; verbatim output (exit 0, 9/9):

```
BOOT_OK :: BK83_BOOT_OK enforce sync=:18543 sts=:18581
[PASS] auth.tokenless-401-challenge :: status=401 www-authenticate=Bearer authorization="http://127.0.0.1:9443/organizations", resource="http://127.0.0.1:18543", error="invalid_token", error_description="MissingBearerToken"
[PASS] auth.sts-mint :: expires_in=3600 jws-segments=3
[PASS] auth.tokenless-flushSync-refused :: ok=false code=SYNC_HTTP status=401
[PASS] sync.flush-5-200-verified :: ok=true lastSeq=5 verified=true bytes=320 leaves=5 markedTo=5
[PASS] sync.cursor-advanced :: cursor=5
[PASS] sync.corruption-typed-refusal :: code=SYNC_REFUSED_BY_SERVER detail=BAD_CRC32 serverHeadSeq=5 purged=2
[PASS] sync.snapback-purge-to-head :: cursor=5 unsynced=0 currentSeq=5
```

The last two PASS lines (clean-resync, cumulative-receipt-vs-full-ledger) and
the `SUMMARY: 9/9 PASS, 0 FAIL` line are in the court transcript; the court
is its own replay: `node workspace/scripts/sync-e2e-court.mjs` (exit 0 = the
falsifier holds; a MODULE_NOT_FOUND at import is the falsifier firing).

## W7 — receipt.ts premise rot replaced with the BK-92 pointer

`workspace/lib/engine/receipt.ts` header no longer claims the server minter
"has not landed". Replaced with the BK-92 pointer
(docs/jira/v26.10.22/receipts/bk92-receipt-sot.md, ALIVE: server minter
`lib/smalt/sync/receipt.ex` landed, cross-mint byte-identical, hex∪base64
parse superset). The green court run above generated its engine scratch from
lib AFTER the W7 edit, so the edited module is exercised by the same court.

## W9 — sync_fault_probe typed readiness exit

`pollUntil` resolves true or throws on timeout — it never returns false, so
`if (!ready)` was dead. Wrapped in try/catch printing the typed `[FAIL]`
line + exit 1. Witness (no BFF on :3100), verbatim:

```
[FAIL] BFF route never became ready (Error: poll timeout (BFF route readiness on :3100): TypeError: fetch failed)
PROBE_EXIT=1
```

## W10 — enclave-loop: post-mint timeouts FAIL, pre-mint transport skips

`is5xxOrNetError` classified `AbortError`/`TimeoutError` as SKIP-LOUD — a
hung-but-up substrate disclosed as a skip. Fix: every hop catch block records
FAIL (the STS mint is the liveness gate; pre-mint transport failure still
exits 3 SKIP-LOUD). Witnesses, verbatim:

1. Pre-mint skip unchanged (substrate down, ECONNREFUSED):
```
# SKIP-LOUD: no substrate on ARM http://127.0.0.1:9443 (ECONNREFUSED) — console leg not run
# court verdict: PASS=0 FAIL=0 SKIP=1 (substrate down)
LOOP_EXIT=3
```
2. Adversarial hung-but-up server (real TCP: answers the STS mint, then hangs
   every other request — the exact state the 10 s hop timeout detects):
```
[PASS] sts mint — bearer minted from http://127.0.0.1:19601/dev/oauth2/v2.0/token (64-char token)
[FAIL] arm: fixture rg read — The operation was aborted due to timeout
[FAIL] blob: container ensure — PUT /t5smaltfixturestore/enclave-marker?restype=container -> 401: InvalidAuthenticationToken (ephemeral witness token, expected)
[FAIL] vault: read-back — ... 401 (same)
[SKIP-LOUD] cosmos: db ensure — PUT /dbs/enclave -> 401 ...
# enclave loop verdict
# PASS=1 FAIL=4 SKIP-LOUD=1  (LOOP_EXIT=1)
```
   The `arm: fixture rg read` row is the W10 flip: post-mint transport
   timeout → FAIL (old code: SKIP-LOUD). A companion run against a dedicated
   private-port router runtime (real EgressRouter + ArmGateway, :19555/:19556)
   confirmed real 500/503 route faults record FAIL and absent-surface
   400/404 rows keep SKIP-LOUD (`# PASS=1 FAIL=4 SKIP-LOUD=1`, exit 1).

## Shared-tree disclosures

- The shared substrate could not boot during this lane's window:
  `lib/smalt/data_plane/kql.ex` then `lib/smalt/powl2/law_compiler.ex` then
  `lib/smalt/messaging/kafka/conn.ex` were successively mid-edit by
  concurrent lanes (compile failures at boot). Enclave-loop green was proven
  against a dedicated private-port runtime (the BK-83 boot.exs pattern on
  :19555/:19556) plus the hung-server adversarial witness — not the shared
  substrate, which was held on 9092 by another lane's live harness
  (`tmp/az1_boot_noapp.exs`, beam 18147, up 3h21m; has a LISTEN socket → not
  an orphan per the same-checkout law; not killed).
- First court run crashed on a mid-edit `journal-sync.ts` (concurrent lane
  EXP1C's in-flight W4/W8 edits raced the scratch generation); after that
  lane's edit settled, the court went 9/9 PASS. Compile-freeze disclosure.
- A stale bk83 beam from that crashed run was killed by exact PID (60957) —
  my lane's own orphan on the court's own ports.

## Files (committed, explicit paths)

- workspace/scripts/sync-e2e-court.mjs
- workspace/scripts/bk83/idb-shim.mjs (relocated from tmp/witness/bk83/)
- workspace/scripts/bk83/boot.exs (relocated from tmp/witness/bk83/)
- workspace/scripts/sync_fault_probe.mjs
- workspace/scripts/enclave-loop.mjs
- workspace/lib/engine/receipt.ts
- docs/jira/v26.10.22/receipts/exp1b-script-hygiene.md
