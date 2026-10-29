# T-09 — Event Hubs: consumer group epoch enforcement

- status: IMPLEMENTED-unreceipted (2026-10-28): citation receipt receipts/r2-t09-epoch-citation.md; wire probe pending
- window: v26.10.28 · maps-to: Topaz v1.12 "Event Hub — consumer group epoch tracking" · verdict-at-open: **PARTIAL** (store mechanics ahead)
- size: **S/M** · depends-on: — · parity-leg: eh suite epoch races

## current state (evidence)

The mechanics Topaz is still planning are shipped in smalt: checkpoint
compare-and-swap, lease `reserve_processing/4`, `reconcile/3`
(`lib/smalt/messaging/event_hubs.ex`), receipted in
`test/internal/event_hubs_consumer_groups_test.exs` and
`test/internal/eh_geo_dr_test.exs`. What is absent is **epoch**
(owner-level) enforcement on consumer-group claims — the `epoch` option
`@azure/event-hubs` sends when a receiver claims exclusive ownership.

## scope

1. Track the highest claimed epoch per (hub, consumer group) in the Store.
2. Real-Azure semantics: a receiver with epoch E arriving while epoch E' > E
   is active → the E receiver's link is detached with the real retryable
   error (`ReceiverDisconnection` mapping); a claim with a LOWER epoch than
   active → the new claimant is refused/detached (`QuotaExceeded`-class
   error shape used by the real service for stale owners).
3. No epoch (undefined) receivers keep today's behavior.

## non-goals

- Load balancer group semantics beyond claim/evict (partition-claim
  stealing rules beyond epoch comparison stay as-is).

## Definition of Done — the Azure developer's view

You open two `@azure/event-hubs` receivers on the same hub + consumer
group, the first with `{ epoch: 1 }` and the second with `{ epoch: 2 }` —
exactly the pattern your production code uses to hand off ownership during
deploys. The moment the epoch-2 receiver attaches, your epoch-1 receiver's
`subscribe()` error handler fires with the same disconnection error you
catch in Azure, while the epoch-2 receiver continues receiving seamlessly.
Trying to re-attach an epoch-1 receiver afterwards is refused with the
stale-owner error. Everything you already rely on — checkpoints, leases,
geo-DR reconciliation — keeps working unchanged.

## receipts required

Epoch race court (2 receivers, detach receipt for the lower epoch, stale
claim refusal); regression receipt that epoch-less receivers are unaffected.
