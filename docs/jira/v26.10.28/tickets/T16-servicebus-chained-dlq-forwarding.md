# T-16 — Service Bus: chained DLQ forwarding (A → B DLQ → C, hop limit)

- window: v26.10.28 · maps-to: Topaz v1.14 "Service Bus — chained DLQ forwarding with configurable hop limit" · verdict-at-open: **GAP** (blocked)
- size: **M** · depends-on: **T-08** (native DLQ must exist first)

## current state (evidence)

There is no DLQ to chain from — see the T-08 evidence
(`lib/smalt/sb_rules.ex:104` "never DLQ here"). Strictly downstream work
(map row marked blocked).

## scope

1. A forward-to queue/subqueue property on DLQ sinks (queue property in
   the real resource model): dead-lettered messages in A are forwarded
   into B's DLQ, then C's, up to a configurable hop limit.
2. At the hop limit the message terminates in the last DLQ with a typed
   marker (reason carrying the chain path + hop count) and an OCEL/telemetry
   event — never a silent drop.
3. Cycle protection: a chain that revisits a queue terminates at the
   revisit with the cycle marker.

## non-goals

- Forwarding between LIVE queues (topic/subscription forwarding already
  exists in the rules surface; this ticket is DLQ-to-DLQ only).

## Definition of Done — the Azure developer's view

You configure your ops pipeline the way the pattern intends: A is your
hot path queue, B your reprocessing queue, C the terminal audit queue,
with a hop limit of 2. A poison message dead-lettered in A shows up in
B's `$deadletterqueue` receiver moments later carrying its accumulated
reason chain; when B dead-letters it too, it lands in C's DLQ and stops
there — your C receiver sees the full path (`A→B→C`) and hop count in the
dead-letter properties, and your alert on "terminal DLQ arrival" fires
exactly once. Misconfigure a cycle (C forwarding back to A) and the
message terminates at the revisit with a cycle marker instead of looping
your CPU away.

## receipts required

Two-hop happy-path receipt (order/properties preserved, terminal exactly
at the limit); cycle-termination receipt; hop-limit=0 degenerate receipt;
one OCEL event per terminal landing.
