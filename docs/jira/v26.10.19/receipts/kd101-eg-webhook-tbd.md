# kd101-eg-webhook-tbd.md — evidence receipt (witness lane, 2026-10-20)

- **KD row**: KD-101 (Event Grid no-HTTP-webhook)
- **Standing**: ALIVE — evidence-executed (typed absence witnessed over the wire;
  in-proc delivery channel witnessed delivering; this is a divergence row, the
  absence IS the evidence)
- **Subject**: smalt working tree @ 81a7a29, substrate block b4
  (amqp=39040 eh=39041 arm=39042 egress=39043 tls=39044 mcp=39045), auth=enforce,
  booted via `scripts/substrate-ctl up --block b4 --auth enforce`
- **Context**: solo

## Execution-2026-10-20

### 1. Wire refusal of webhook delivery configuration (the typed absence)

ARM PUT of an Event Grid event subscription with a WebHook destination, topic scope:

```
$ curl -sS -X PUT -H "Authorization: Bearer $TOKEN" -H 'Content-Type: application/json' \
    --data '{"properties":{"destination":{"endpointType":"WebHook","properties":{"endpointUrl":"http://127.0.0.1:19999/hook"}},"eventDeliverySchema":"CloudEventSchemaV1_0"}}' \
    "http://127.0.0.1:39042/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-probe/providers/Microsoft.EventGrid/topics/t-probe/providers/Microsoft.EventGrid/eventSubscriptions/sub-webhook?api-version=2022-06-15"
{"error":{"code":"RouteNotFound","innererror":{},"message":"The route '/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-probe/providers/Microsoft.EventGrid/topics/t-probe/providers/Microsoft.EventGrid/eventSubscriptions/sub-webhook' could not be found.","target":"/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-probe/providers/Microsoft.EventGrid/topics/t-probe/providers/Microsoft.EventGrid/eventSubscriptions/sub-webhook"}}
http=404
```

Subscription-scoped PUT (system topic shape) — refused by the ontology gate, not a
silent accept:

```
$ curl -sS -X PUT -H "Authorization: Bearer $TOKEN" -H 'Content-Type: application/json' \
    --data '{"properties":{"destination":{"endpointType":"WebHook","properties":{"endpointUrl":"http://127.0.0.1:19999/hook"}}}}' \
    "http://127.0.0.1:39042/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-probe/providers/Microsoft.EventGrid/eventSubscriptions/sub-sys?api-version=2022-06-15"
{"error":{"code":"InvalidResourceShape","innererror":{},"message":"GraphLaw validation failure: Resource type Microsoft.EventGrid/eventSubscriptions is not an admitted ontology individual in smalt-substrate-pack","target":"AshGraphLaw.Enforcement"}}
http=400
```

Direct webhook validation handshake at the egress port is bearer-gated like every
other route (no handshake surface exists to answer `WebHook-Request-Origin`):

```
$ curl -sS -X OPTIONS -H 'WebHook-Request-Origin: eg-validation.example' -H 'WebHook-Request-Rate: 1M' -D - 'http://127.0.0.1:39043/'
HTTP/1.1 401 Unauthorized
www-authenticate: Bearer authorization="http://127.0.0.1:39042/organizations", resource="http://127.0.0.1:39043", error="invalid_token", error_description="MissingBearerToken"
http=401
```

Zero matches for `eventSubscription|webhook|WebHook` in
`lib/smalt/egress_router.ex` and `lib/smalt/arm_gateway/` — the delivery-config
surface does not exist in the wire routers.

### 2. Ingestion works; the ONLY delivery channel is in-proc

```
$ curl -sS -X POST -H "Authorization: Bearer $TOKEN" -H 'Content-Type: application/cloudevents-batch+json' \
    --data '[{"specversion":"1.0","id":"kd101-evt-1","source":"/smalt/probe","type":"smalt.probe.kd101","data":{"note":"kd101 witness"}}]' \
    "http://127.0.0.1:39043/topics/t-probe/events"
http=200
```

### 3. In-proc subscriber path witnessed delivering (read-only citation +
execution)

`lib/smalt/messaging/event_grid.ex` moduledoc: "At-least-once fan-out of
CloudEvent-shaped events to in-process subscribers, acked per event" — plus the
G3 DLQ blob-spillover witness
(`docs/jira/v26.10.18/receipts/azb-07-integration-plane.md`, Standing: ALIVE,
`DeadLetterReason: MaxDeliveryCountExceeded` spillover to
`eg-dlq-<subscriber>` containers). Executed live:

```
$ MIX_BUILD_ROOT=_build-lane-w MIX_ENV=test mix run /tmp/kd101_inproc.exs
MSG: {:event_grid, "t-probe", :kd101_probe, "kd101-inproc-1",
 %{
   data: %{note: "inproc delivery"},
   id: "kd101-inproc-1",
   type: "smalt.probe.kd101",
   source: "/smalt/probe",
   specversion: "1.0"
 }}
```

(probe: `EventGrid.subscribe/3` + `EventGrid.publish/2` → `:fresh`, delivery
received as `{:event_grid, topic, subscriber_name, id, event}` and ackable.
`probe_exit=0` — mix run exit 0.)

## Standing rationale

The skeleton falsifier ("subscriber HTTP endpoint receives the validation
handshake AND a delivered CloudEvent") is NOT achievable and is witnessed as
unachievable by typed wire refusals (404 RouteNotFound / 400
InvalidResourceShape-ontology) — there is no HTTP webhook delivery mode. The
in-proc channel delivers. KD-101 remains OPEN in the register as a real
divergence; this receipt is the executed evidence for it.

## Close condition (unchanged)

Implement webhook push delivery incl. handshake validation; falsifier: subscriber
endpoint receives delivered CloudEvent over HTTP.

## Cross-links

- `KNOWN_DIVERGENCES.md` KD-101 row; `docs/WIRE_PARITY.md` Event Grid rows;
  `docs/jira/v26.10.18/receipts/azb-07-integration-plane.md` (in-proc contract +
  DLQ witness).
