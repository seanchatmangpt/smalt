# POWL-7 — In-memory CAS store + zero-lease change feed (FR-3.1)

Standing: **ALIVE** (8/8 green on the lane build root)

Date: 2026-10-21 · Lane: POWL-7 (writer) · Build root: `_build-powl7`

## Files (owned, landed)

- `lib/smalt/powl2/change_feed.ex` (new) — `Smalt.POWL2.ChangeFeed`
- `test/internal/powl2_change_feed_test.exs` (new) — 8 Chicago tests

## Contract delivered (FR-3.1)

- ETS `:set` docs `{{pk, id}, etag, seq, body}` + ETS `:ordered_set` CDC log
  `{seq, :put, pk, id, etag}` + `:atomics` sequence counter.
- `put_item/5` If-Match CAS: `nil` → 201 create / 200 upsert; match → 200;
  stale → `{:error, 412, current_etag}`; missing+if_match → `{:error, 404, nil}`.
- etag = dashed RFC-4122 v4 GUID via existing renderer
  `Smalt.Egress.KvRoutes.guid_version/0` (reused, not duplicated).
- Push-based CDC: `{:cdc_watermark, seq}` per mutation;
  `:gen_statem` (`:idle`/`:draining`, pause flag) drains
  `{:cdc_batch, from, to, events}` (limit 50, offset advance via `last_sent`)
  to the subscriber in seq order.

## Verification (actual output)

```
$ MIX_BUILD_ROOT=_build-powl7 mix test test/internal/powl2_change_feed_test.exs
........
Finished in 2.1 seconds (2.1s async, 0.00s sync)
8 tests, 0 failures
```

(Twice consecutively, stable; compile "Generated smalt app" clean.)

Test classes: CAS 201/200/412/404 paths; RFC-4122 v4 etag shape; watermark+batch
received push-only (bounded receive, no polling, no sleeps); 120 docs drain in
strictly increasing seq order across batch boundaries; backpressure pause holds
delivery (state-checked `last_sent: 0` while paused) then resume drains [1,2,3].

## Lane incidents (disclosure)

- **Duplicate POWL-7 writer collision** on
  `lib/smalt/powl2/change_feed.ex`: an in-flight alternate implementation
  (LockManager-token based, sketch syntax error at 12:11, revised 12:12)
  overwrote this lane's leased file twice. This lane restored its
  test-verified implementation; final on-disk state is this lane's, md5
  `bf148a3991b060300de51e1c860e2880`. Coordinator should reconcile the
  duplicate dispatch — one writer per file was violated, not by this lane.
  The foreign version's full text is preserved at
  `/tmp/foreign_change_feed_attempt.ex` (12:11 snapshot) for comparison.
- Repeated transient compile breaks from sibling POWL2 files
  (`compiler.ex`, `decomposition.ex`, `projection.ex`, `sb_rules.ex`,
  `executor.ex`) — each self-repaired by its owner; no unblock fixes applied
  by this lane, disclosure per compile-freeze law unnecessary.
- No mock collaborators anywhere (Chicago: real ETS, real gen_statem, real
  message delivery); zero `Process.sleep` — delivery asserted via bounded
  receive timeouts.
