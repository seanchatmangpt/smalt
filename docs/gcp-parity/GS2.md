# GS2 Cloud Pub/Sub Dialect Receipt

Standing: UNVERIFIED

Authoring lane only: no mix/just/git was run; nothing compiled or tested.

## Files
- lib/smalt/gcp/pubsub.ex (engine GenServer over QueueStorage)
- lib/smalt/gcp/pubsub_router.ex (REST v1 `route(conn)` -> conn | nil)
- test/gcp/pubsub_engine_test.exs, test/gcp/pubsub_router_test.exs
- docs/gcp-parity/GS2-pubsub-census.md

## Wiring (shared files, not edited)
1. Supervision: add `Smalt.Gcp.PubSub` to the application children list.
2. Egress dispatch, before body parsing, in `Smalt.EgressRouter`:

```elixir
case Smalt.Gcp.PubSubRouter.route(conn) do
  nil -> next_plane(conn)
  conn -> conn
end
```

## Falsifiers
Ack deadline redelivery, ordering-key hold-back, DLQ forward after 5 attempts, snapshot seek
replay; first compile may expose typos (UNVERIFIED).
