# r2 — T-09: Event Hub consumer-group epoch enforcement is SHIPPED (citation receipt)

- window: v26.10.28 · ticket: `tickets/T09-eventhub-epoch-enforcement.md` · date: 2026-10-28

The v26.10.28 map marked EH epoch "PARTIAL / absent" — that was an
under-read. Source verification shows the full GAP-A2-02 epoch machinery
already shipped in the AMQP tier:

| mechanism | evidence |
|---|---|
| epoch parsed from the wire (`com.microsoft:epoch`, exclusive-receiver claim on attach) | `lib/smalt/messaging/amqp/connection.ex:722-727` (`eh_epoch` link field) |
| cross-connection eviction of the incumbent epoch-holding link (new higher epoch wins; the OLD link is detached with the typed error) | `lib/smalt/messaging/amqp/connection.ex:149-158` (`eh_epoch_evict`) |
| epoch registrations released on link/session teardown (no stale claims) | `lib/smalt/messaging/amqp/connection.ex:537-540` |

This is exactly the DoD's first half (epoch-2 receiver detaches the
epoch-1 receiver; epoch-less receivers unaffected — release paths guard
`eh_epoch: nil`).

## residual (honest scope note)

A live two-receiver `@azure/event-hubs` wire probe (the DoD's "your error
handler fires" leg) has not been executed on this box — the EH SDK leg
needs the CBS/SAS connection-string contract booted in enforce mode
(`verification/ts` run-all path). The implementation is present and
covered by the azsim EH courts (`test/internal/event_hubs_consumer_groups_test.exs`,
`test/internal/eh_geo_dr_test.exs` for the adjacent machinery); the wire
probe remains the follow-up receipt before T-09 can be marked CLOSED. This
receipt moves T-09 from PARTIAL-unimplemented to IMPLEMENTED-unreceipted.
