# w6u — SB F1/F2 SDK-divergence fixes (KD-120/KD-121)

**Standing:** **ALIVE** — all witness legs passed on the real wire, real SDKs.

Subject: main @ bab1949 + this lane's two lib/ files, verified on a frozen
scratch tree (`/Users/sac/.claude/jobs/cfab9d25/tmp/w6u-scratch` = HEAD
archive + the lane overlay) because the shared tree was churning from ~19
concurrent sibling lanes. Both files parse-gate OK on the shared tree.

## Findings fixed

- **F1 / KD-120** — `@azure/service-bus` (managementClient.js:886) and
  azure-servicebus py (`_session_browser.py:98`) send the since-filter as
  `last-updated-time`; the server read only `since-updated-time`, so the
  SDK-native key was dead code. Fix: `lib/smalt/messaging/amqp/management_rpc.ex`
  accepts both keys (SDK key wins), and clamps the SDK default-listing
  sentinel `last-updated-time = 253402300800000` (DateTime.MaxValue, year
  10000) to nil (no filter) — the sentinel-as-filter bug was found BY this
  lane's witness and is the actual wire-observed close for KD-120.
- **F2 / KD-121** — TS SDK `acceptNextSession` (null-selector
  `com.microsoft:session-filter` attach) fell through to the unfiltered
  passthrough (no session-filter echo, no lock fields) and the SDK threw
  `TypeError: Cannot read properties of undefined (reading
  'com.microsoft:locked-until-utc')`. Fix: `lib/smalt/messaging/amqp/connection.ex`
  distinguishes the null-selector attach via `nil_session_filter?/1`, picks
  the next unlocked session via `next_unlocked_session/1` (real
  `QueueStore.list_sessions` + `LockManager.session_acquire`), echoes the
  chosen sid + `com.microsoft:locked-until-utc` (.NET filetime), and refuses
  empty with echo-then-detach `session-cannot-be-locked`
  / NO_UNLOCKED_SESSIONS_AVAILABLE.

## Witness (real wire, real SDKs; block b14 off the scratch tree)

`W6U_CWD=<scratch> SMALT_REPO=/Users/sac/smalt node w6u_witness.cjs`:

```
PASS F1-last-updated-time-filter
PASS F2-acceptNextSession-with-session
PASS F2b-acceptNextSession-empty-clean-fail
SUMMARY pass=3 fail=0
```

- F1 leg: real azure-servicebus py `list_queue_sessions` (default listing +
  `state_updated_after` future bound) → `ALL3=3 FUTURE=0` over the live AMQP
  wire. Server-side scratch debug line (one-off shim, scratch only):
  `W6U-DBG get_message_sessions queue="w6u-final-q" body=%{"last-updated-time" => {:timestamp, 253402300800000}, ...}` — the sentinel arrives on the
  wire exactly as the py SDK docs describe.
- Store-level leg (scratch `mix run`): `LIST_ALL=3 LIST_FUTURE=0`.
- F2 legs: real @azure/service-bus 7.10.0 `acceptNextSession` returns a
  usable receiver (correct sessionId + delivery) with a session present, and
  fails cleanly on an empty queue — no TypeError.

## Register

KD-120 and KD-121 minted OPEN in
`docs/jira/v26.10.19/KNOWN_DIVERGENCES.md` (canonical newest register),
then flipped via `scripts/kd_flip.py --apply` gated on this receipt's mtime
(flip receipts appended there). `# KD-COVERS: KD-120` /
`# KD-COVERS: KD-121` tokens landed with the fixes.

## Cross-lane disclosures

- Scratch overlay note: the scratch's queue_store.ex is HEAD's (pre-w5g), so
  the scratch detail map dropped the w5g `session-state` echo field for the
  witness run; the SHARED-tree management_rpc.ex keeps the w5g field — the
  shared tree compiles against the w5g store (w5g's lane gates were green).
- No other lane's file was modified. One-off debug shims lived ONLY in the
  scratch tree, never in the shared tree.
