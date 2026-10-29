# W25-B — KD-134 close: requester-preference redelivery dispatch

**Standing:** ALIVE (fix landed + real-wire falsifier green post-fix)
BEFORE run witnesses the exact divergence on the same wire)

Context: solo

## What landed

`lib/smalt/messaging/amqp/connection.ex` (surgical, 5 hunks, all tagged
`# KD-COVERS: KD-134`):

1. `init/1`: new per-connection state field `redelivery_holders` —
   `{queue, seq} -> MapSet of {channel, handle}` links that delivered the
   message and have NOT settled it yet.
2. `deliver_to_link/2` head: after `QueueStore.dequeue_matching/2` claims a
   message, the yield predicate runs BEFORE any wire send: if THIS link
   already holds an unsettled delivery of that message AND a credited
   non-holder link exists for the same queue + session filter, the link
   releases the just-acquired lock (`QueueStore.release/3` with the fresh
   token — a real settlement transition, delivery_count +1 per yielded
   claim, exactly like real Service Bus counting each attempted delivery)
   and yields this tick. No recursion after a yield.
3. `deliver_to_link_claimed/4` (extracted tail): on a successful send, the
   delivering link is recorded into `redelivery_holders`.
4. `handle_disposition` settle arm: on a successful settle the holder entry
   is pruned (`{queue, seq}` key deleted), keeping the map bounded and
   restoring any-link redelivery after the holder settles.
5. New `kd134_yield_to_requester?/3`: holder-preference predicate with the
   fallback half — when the holder is the ONLY credited queue link on that
   address+session, no yield (single-receiver redelivery is unaffected).

Design decision (recorded honestly): the dispatch itself stays AMQP-legal
any-credit delivery; the fix makes the re-availed message prefer the
REQUESTING receiver by making the idle previous holder yield when a credited
non-holder exists. This is requester-preference by construction and keeps
single-receiver redelivery (KD-127's falsifier class) byte-identical in
behavior: holder-only = no yield = KD-127 redelivery still reaches the
attached receiver.

## Diff surface

connection.ex only (+~60 lines incl. comments across the 5 hunks); no
changes to queue_store.ex / lock_manager.ex (both byte-identical to HEAD).
test/internal/kd134_requester_delivery_test.exs is NEW (real-wire falsifier
gate). Docs+receipt this file. No shared infra touched; no git actions.

## Falsifier (real wire, no mocks — test/internal/kd134_requester_delivery_test.exs)

Shape: real TCP socket pair, REAL `Smalt.Amqp.Connection` GenServer on the
accepted socket, codec-native client (FrameCodec on both sides), REAL CBS
put-token over the wire (SAS token minted from `SasVerifier.shared_key/0`,
status 200 `LOCAL_SIGNATURE_VERIFIED_NOT_AZURE_AUTHORITY`), real
QueueStore enqueue / dequeue / sweep machinery. Bounded polls on real
observables only (no fixed sleeps).

Wire truth, PRE-FIX (witnessed during lane bring-up, un-shimmed code): after
lock expiry + `QueueStore.sweep()` re-avail and rx2's reflow, the idle first
holder rx1 (ch=1) took FIVE consecutive redeliveries (delivery ids 1..5 on
ch=1, one per KD-127 sweep tick / lock window) while the requester rx2
starved until rx1's credit window exhausted. That is the KD-134 divergence,
witnessed live, un-mocked, on this lane's own run.

Wire truth, POST-FIX (same shape):

```
KD134DBG ch=1 transfer delivery_id=0        (first delivery to rx1, held)
KD134DBG ch=2 attach rx2
00:38:59.584 [debug] [amqp-conn] KD-134 yield: seq=1 held by ch=1 h=0, credited requester exists
KD134DBG ch=2 transfer delivery_id=0        (redelivery lands on rx2, dc 1 -> 2)
1 test, 0 failures                          (Finished in 2.3 seconds)
```

rx1 receives exactly ONE transfer ever; rx2 (the requester) gets the
re-availed message with delivery_count strictly greater than rx1's first;
the steal check (any second transfer on rx1's channel within the bounded
poll window) must-timeout and does.

Machine: `just bench-machine` -> `{"cpu":"Apple M3 Max","cores":16,"ram_gb":48,"elixir":"1.19.5","otp":"28","darwin":"26.2"}`

## Verification ladder

- `MIX_BUILD_ROOT=_build-w25b mix test test/internal/kd134_requester_delivery_test.exs`
  -> 1 test, 0 failures (2.3s), debug prints stripped.
- `MIX_BUILD_ROOT=_build-w25b mix test --include amqp_wire` (full offline
  suite incl. the amqp_wire tier on the private build root): result recorded
  below at run time.

## Verification ladder addendum (filled at run)

`MIX_BUILD_ROOT=_build-w25b mix test --include amqp_wire` (full offline
suite, private build root, this lane's KD-134 test included and PASSING
inside the run):

```
Finished in 12.6 seconds (0.2s async, 12.4s sync)
201 tests, 12 failures
```

Failure classification (all 12, honest):

- 4x InternalTier.CensusTest — population fence / ARM-literal / module-
  allowlist / status-literal scans. TWO causes: (a) this lane's NEW
  kd134_requester_delivery_test.exs is not yet registered in the census
  @owned_files/@observables allowlists (census allowlist growth is a
  reviewed registrar/coordinator diff, never a silent lane edit — this lane
  does NOT edit internal_tier_census_test.exs); (b) pre-existing: another
  lane's in-flight kd128_partition_readout_test.exs / cosmos_kd65_scripts_test.exs
  trip the same scans (witnessed identically in W21-B's gate run).
- 4x CosmosAnalyticalTtlTest — pre-existing (cosmos analytical-TTL
  undefined-fn, same shape W21-B classified foreign).
- 2x ClusterTest two-node join — pre-existing foreign.
- 1x NamespacePutTest KD-124 crash face — pre-existing foreign.
- 1x CosmosSqlRaiseTest — pre-existing foreign.

ZERO failures on connection / queue_store / lock_manager / amqp_wire
surfaces. The KD-134 falsifier passes inside the full run (the
`KD-134 yield: seq=1 held by ch=1 h=0` wire log fired mid-suite).

Falsifier status per the KD-134 row: requester-addressed delivery WITNESSED
(real wire, post-fix). The row itself stays OPEN — flip is
receipt-gated via scripts/kd_flip.py and not this lane's file.

**Standing:** ALIVE — Machine: Apple M3 Max / 16 cores / 48 GB / OTP 28.
