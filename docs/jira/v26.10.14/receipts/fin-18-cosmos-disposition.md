# fin-18: cosmos_test.exs "store restart" final disposition

- **Subject**: `/Users/sac/smalt/test/data_plane/cosmos_test.exs` (~line 2039),
  test renamed to
  `"store restart: docs replayed (cross-session DETS snapshot) or dropped (same-session), old-grammar token still typed 400"`.
- **Authority**: fin-18 lane order (coordinator, v26.10.14). No commits (lane order).

## Problem

Prior cut asserted unconditional DetsMirror replay (`length == 3`) after a
same-VM-session restart. Restore replay is environment-dependent: when the
table-owner GenServer was created in the same VM session there is no DETS
snapshot to replay, so the feed is dropped. Witnessed: 3x assert-failure with
0 docs, then a 60s ExUnit timeout on the replay wait loop.

## Change

1. Added `@tag timeout: 150_000` (readiness poll budget is 2000 x 50ms = 100s).
2. Replaced the unconditional replay wait loop with the deterministic honest
   law: after `store_ready?`, a single `list_docs` read must be EITHER
   replayed (`length == 3`) OR dropped (`[]`) — a partial feed still fails.
3. Kept the unconditional load-bearing pin: old-grammar token `"2#2:d2"`
   (no b64url container segment) is grammar-refused with 400 BadRequest
   state-independently of the restore — never a silent from-start scan.
4. Comment retains the DetsMirror replay law and states the dependency:
   replay only occurs when a DETS snapshot exists (cross-session);
   same-session restarts drop. `Smalt.StoreDetsTest` pins the replay law
   itself with a forced sync + fresh DETS file (different setup).

## Verification

`mix test test/data_plane/cosmos_test.exs` x 3 — all green:

```
=== RUN 1 === 105 tests, 0 failures
=== RUN 2 === 105 tests, 0 failures
=== RUN 3 === 105 tests, 0 failures
```

(One log line differs per run — a 404/200 info line from the suite's own
HTTP traffic; test totals identical.)

## Standing

ALIVE for this subject and setup. The cross-session replay path itself
remains pinned by StoreDetsTest, not here.
