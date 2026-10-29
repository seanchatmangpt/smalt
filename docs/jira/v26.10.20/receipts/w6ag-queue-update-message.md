# Receipt — w6ag: Azure Queue Storage Update Message (popreceipt parity)

**Standing:** PARTIAL_ALIVE
Date: 2026-10-20
Lane: w6ag (wave-6)
Subject: lib/smalt/data_plane/queue_storage.ex (additive), tmp/w6ag_witness.exs, tmp/w6ag_lib (freeze-safe replay lib)

## Scope finding (the honest one)

The Update Message engine surface was **already landed** in `queue_storage.ex`:
`update_message/6` rotates the popreceipt, replaces content, extends visibility
(0..604800 s bounds, i.e. real-Azure ≤7d parity — note real Azure bounds the
update vt at <7 days minus clock skew; the landed 0..604800 grammar matches the
scoping comment), stale/superseded receipt → 404 `PopReceiptMismatch`, missing
message → 404 `MessageNotFound`, and the dequeue/peek/update renders carry
`PopReceipt` + `TimeNextVisible`. The PUT messageid route + dispatch in
`egress_router.ex` already exist (lines ~308-336) — **no router patch is
needed**; nothing staged in lane tmp either.

## What this lane landed

**The one real parity gap closed: malformed popreceipt → typed 400.**
Previously only missing/empty receipt was rejected (400
MissingRequiredQueryParameter); a syntactically invalid receipt fell through to
the stale-receipt 404 path. Real Azure base64-decodes the receipt server-side;
syntactically invalid value → 400 `InvalidQueryParameterValue`. Landed:

- `check_popreceipt/1` now validates receipt format (base64 charset,
  %4==0 length) → 400 `InvalidQueryParameterValue` on malformed input.
  Base-valid-but-unknown payloads still fall through to the stale 404
  (`PopReceiptMismatch`), preserving the wire contract.

Single additive edit to the exclusive lane file; no other lib/ file touched.
No unblock fixes to foreign files were applied this lane.

## Verification (real output)

Compile: full-tree `MIX_BUILD_ROOT=_build-lane-w6ag MIX_ENV=test mix compile
--warnings-as-errors` — **zero diagnostics in queue_storage.ex** across all
attempts; the strict gate itself was blocked by sibling in-flight files
(cosmos.ex, then egress/Observability.ex — w6R's split churn, both owner-
repaired mid-wave). Freeze-safe replay documented below. Module standalone
`elixirc` → BEAM emitted (tmp/w6ag_ebin).

Witness: module-direct over the real Store (Store + StoreTables booted real;
tables readiness via bounded poll). Because sibling churn kept replacing the
load order, the witness runs against an isolated lib copy
(`tmp/w6ag_lib` = copy of `_build-coord/test/lib` with the fresh lane beam
dropped into `smalt/ebin/`), loaded via `ERL_LIBS`:

```
$ ERL_LIBS=$PWD/tmp/w6ag_lib elixir tmp/w6ag_witness.exs
W6AG WITNESS: ALL FACES OK
exit 0 (ran twice, both green, incl. teardown via drop_account_data)
```

Faces witnessed (each a pattern-matched final state, no interaction asserts):

- F1 put 201 → dequeue (receipt rotated pr0→pr1, TimeNextVisible present) →
  update with current receipt → 200 + NEW receipt pr2 + vt=1s; peek empty
  during window; bounded poll → updated content visible after expiry.
- F2 stale receipt (pr1) → 404 `PopReceiptMismatch`.
- F3 missing message id → 404 `MessageNotFound`.
- F4 malformed receipt (`not@base64!!`) → 400 `InvalidQueryParameterValue`
  (the gap this lane closed; pre-change behavior was 404 PopReceiptMismatch —
  witnessed as the BEFORE face during debugging and is the exact flip).
- F5 empty receipt → 400 `MissingRequiredQueryParameter`.
- F6 vt 604801 → 400 InvalidQueryParameterValue (0..7d bound parity).
- F7 delete with fresh-current receipt → 204; repeat → 404 MessageNotFound.
  (Witness correction en route: after a 1s vt elapses, the receipt is
  superseded — expiry supersedes receipts is the engine's correct stale face;
  F7 re-dequeues to mint a current receipt.)

Honest blocker note: two of the debug iterations initially loaded the stale
smalt beam from ERL_LIBS precedence — resolved by the isolated lib copy; the
receipted run is the corrected one.

## Standing justification

PARTIAL_ALIVE (not ALIVE): full-tree strict compile + a real-wire HTTP leg
were not re-runnable inside the lane window (w6R router-split churn owns
egress/; the route already existed, so the module entry exercised here is the
same entry the dispatch calls — the module-direct witness is not a mock, it is
the real Store with real engine code on the wire path). Flips to ALIVE at
integration when w6R lands and the tree compiles strict.

## Replay

```
MIX_BUILD_ROOT=_build-lane-w6ag MIX_ENV=test mix compile --warnings-as-errors  # strict gate at integration
ERL_LIBS=$PWD/tmp/w6ag_lib elixir tmp/w6ag_witness.exs
```
