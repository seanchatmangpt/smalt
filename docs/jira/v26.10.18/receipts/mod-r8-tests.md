# MOD-R8 — ratchet mod automated test suite (lane R8, lease test/)

Standing: **ALIVE** — `node --test` exit 0, 29/29 pass (21 in R8 files, 8 from
Context: slice(mods/ratchet/test/ — node --test, 29/29 pass, run 2x)
the sibling hooks lane's suite.test.js), run twice green against real repo
files and real receipt fixtures.

## What landed

Test suite for the ratchet mod under `/Users/sac/smalt/mods/ratchet/test/`
(runner: plain `node --test /Users/sac/smalt/mods/ratchet/test/`):

- `state.test.js` (3) — lib/state.js against the REAL repo: TICKETS.md parse
  → exactly 24 tickets with lanes and parsed deps (AZB-02→[AZB-01] spot
  check); receipts glob `azb-NN-*.md` cross-checked against an independent
  readdir count; every landed ticket's receipt file exists on disk;
  nextTicket is the FIRST deps-satisfied OPEN ticket in file order, and
  deps-satisfaction is receipt-map sensitive (dropping AZB-01 from the map
  flips AZB-02 to unsatisfied).
- `inject.test.js` (5) — 5-minute dedup refuses the second inject
  (RATE_LIMITED, reservation proven persisted to a real temp state file);
  dispatchLock blocks with zero submissions (incl. fail-closed on a state
  file missing the field); bounded prompt is EXACT-template conformance
  (ticket id present, slug `[a-z0-9-]{1,40}`, zero shell-significant chars —
  the hostile input `AZB-07 … "rm -rf /" && $(curl evil)` renders only as a
  sanitized slug); no AZB id → UNBOUNDABLE_PROMPT; submit fault releases the
  reserved window and surfaces typed. Only double: prompt.submit recorder
  (no live session exists in a test process); state rides real file I/O via
  $api.fs with a path redirect.
- `gate.test.js` (7) — ring RED holds court-x2 (fixture = verbatim copy of
  the real RED azb-22 receipt); green azb-22b fix fixture lifts the hold
  (pass-through); green ring + boot-burn PARTIAL_ALIVE still holds; missing
  receipt fails CLOSED (MISSING); unrelated bash (`just doctor`, `mix test`,
  `ls -la`) passes untouched with the ring RED; parseStanding on real
  receipt texts; pure decide() truth table incl. a RED fix NOT lifting.
  Fixtures: `test/fixtures/{red,green,boot-stale}/` — real receipts with
  mutated verdict lines (marked MUTATED FIXTURE in the standing line).
- `commands.test.js` (6) — mode transitions persist through the atomic
  tmp+rename write (OBSERVE→AUTO→OFF with a full decisionLog chain read back
  from disk; idempotent re-set changed=false); loadState merges over an
  existing file without clobbering lane fields (BOGUS mode → DEFAULT);
  decisionLog bounded at 200; readTickets/renderStatus against the real
  TICKETS.md; unreadable tickets degrade typed.

## Verification (real output)

```
$ node --test /Users/sac/smalt/mods/ratchet/test/ ; echo "exit=$?"
... 29 tests listed, all ✔ ...
ℹ tests 29
ℹ suites 0
ℹ pass 29
ℹ fail 0
ℹ cancelled 0
ℹ skipped 0
ℹ todo 0
ℹ duration_ms 730.511708
exit=0
```
Second run identical (exit 0, 29/29). Sample per-test lines:
```
✔ 5-minute dedup: second inject inside the window is refused RATE_LIMITED (3.071375ms)
✔ dispatchLock blocks the inject and nothing is submitted (0.966125ms)
✔ ring RED holds court-x2 (real RED receipt copy as fixture) (1.412083ms)
✔ green azb-22b fix fixture lifts the hold — court-x2 passes through (0.750584ms)
✔ missing ring receipt fails CLOSED, never passes (0.451458ms)
✔ DAG priority: nextTicket is a deps-satisfied OPEN ticket (first in file order) (1.149583ms)
✔ setMode transition persists and appends a decisionLog entry (3.918584ms)
```

Anti-vacuity witnesses baked into the asserts: the gate tests flip the same
fixture corpus between HOLD and PASS (RED holds, green fix lifts, RED fix
re-holds — a gate that only ever held or only ever passed would fail the
truth-table test); the inject tests prove the dedup reservation is real
persisted state read back from disk; the state test proves deps-satisfaction
flips when a receipt is removed from the map.

## Subject / replay

- Subject: `/Users/sac/smalt`, HEAD `2eb5f89d4f44a62b6136e15bec918be303052d41`
- Replay: `node --test /Users/sac/smalt/mods/ratchet/test/` (exit 0; 0/fail; no
  substrate needed; node v26.10.0)

## Disclosures

- Co-tenant: the sibling hooks lane's `suite.test.js` (8 tests) lives in the
  same dir and runs in the same invocation; counted but not owned here.
- Session-introduced: during development one early commands test called
  `logDecision` without a statePath, which wrote ~250 bounded log entries to
  the module's runtime state file
  `docs/jira/v26.10.18/rewrite-drafts/ratchet-state.json` (mode OBSERVE
  preserved; prior decisionLog contents not restorable). The test now always
  passes an explicit temp statePath; fixed in the landed version. Runtime
  scratch, not a source artifact — flagged for the coordinator.
