# KD-51 — Python SB admin client URL space served over HTTPS (lane W13-E, 2026-10-21)

**Standing:** ALIVE (falsifier run; row flip-eligible)
Context: solo

## Empirical URL-space capture (BEFORE)

azure-servicebus **7.15.0** (fresh /tmp venv, python 3.14.3). Two constructions probed:

- `from_connection_string("Endpoint=sb://localhost:5672;...")` → client hardcodes
  `https://` (`_management_client.py:129 self._endpoint = "https://" + fqn`), so the
  sb://-port ATOM plane (`Smalt.Amqp.AtomBridge` serve/2 on 5672, KD-45 closure) is
  unreachable from current Python clients: `SSL: WRONG_VERSION_NUMBER`.
- fully-qualified-namespace + TokenCredential → `https://localhost:9444` (TLS twin).

Captured URLs (client HTTP debug log):

```
Request URL: 'https://localhost:9444/w13e-kd51-queue?api-version=2024-05'   PUT
Request URL: 'https://localhost:9444/w13e-kd51-queue?enrich=...&api-version=2024-05' GET
```

404 shapes: ARM catch-all `RouteNotFound` "The route '/w13e-kd51-queue could not be
found" over the conn-string construction (SAS `SharedAccessKey` auth header →
401 MalformedBearerHeader — see Auth note). No trailing-slash variants observed;
the `$`-segment forms in the client's URL templates
(`azure/servicebus/management/_generated/operations/_operations.py:51,204,428`):
`/{entityName}`, `/{topicName}/subscriptions[/{subName}[/rules[/{ruleName}]]]`,
`/$Resources/{entityType}`, `/$namespaceinfo` — only `/$Resources` and
`/$namespaceinfo` are `$`-forms, neither sent during queue round-trips.

## Diff

Surgical, disclosed cross-lane:

- `lib/smalt/messaging/amqp/atom_bridge.ex` — public `handle_request/3` (KD-COVERS:
  KD-51) exposing the existing raw-socket dispatcher's `{status, ctype, payload}`
  tuple; zero behavior change to the sb://-port plane.
- `lib/smalt/arm_gateway/router.ex` — flat ATOM alias routes
  `put/get/delete "/:entity_name"` + `sb_atom_alias/3` (KD-COVERS: KD-51), declared
  immediately before the catch-all so every earlier static route
  (/tenant, /tenants, /subscriptions, /healthz, …) keeps precedence.
- `lib/smalt/application.ex` — `TlsTwinDispatch` (not in the lane's file ownership;
  disclosed minimal unblock, compile-freeze SLA): cond clause routing any
  twin-seated path whose query carries `api-version=` to `Smalt.ArmGateway.Router`.
  Discriminator is typed: SB management calls always carry ARM-style `api-version=`;
  storage-service requests (`restype=`/`comp=`) never do, so the KD-114 storage
  catch-all keeps every face (verified by the tls_blob_dispatch suite + a negative
  test in kd51_sb_atom_https_test.exs).

## AFTER (wire witness, real client, real TLS)

Ephemeral instance (MIX_BUILD_ROOT=_build-w13e, MIX_ENV=test, random ports;
ARMTLS=60293), stopped after the run — shared substrate untouched (still 401 on
9444 throughout). azure-servicebus 7.15.0, `ServiceBusAdministrationClient` with a
TokenCredential minting HS256-equivalent bearer from the instance's STS
(`POST /organizations/oauth2 v2.0/token`, any client_id/secret):

```
CREATE OK w13e-kd51-final lock_duration: 0:00:30 max_delivery: 10
    (create_queue -> PUT /{queue}?api-version=2024-05 -> 201)
RUNTIME OK w13e-kd51-final created_at_utc: False
    (get_queue_runtime_properties -> GET ?enrich=...&api-version=2024-05 -> 200)
GET_QUEUE OK w13e-kd51-final max_delivery_count: 10   (get_queue -> 200)
DELETE OK                       (delete_queue -> DELETE -> 200)
POST-DELETE OK 404 ResourceNotFoundError
```

Falsifier met: Python admin client create_queue succeeds (and the full
create → read properties → delete round-trip is 2xx, typed 404 after delete).

## Test

`test/integration/kd51_sb_atom_https_test.exs` (Chicago: real router + real store,
no mocks) — 3 tests, 0 failures. Neighbor suites under
`MIX_BUILD_ROOT=_build-w13e`, all 0 failures: tls_blob_dispatch (2),
deletedkeys_purge_route + kv_ec_create + sb_topic_fanout (13 combined),
eh_arm (10), arm_dcr + namespace_put + sb_arm_rules + arm_consumer_group_bridge +
cors_headers_knob + arm_workspace_tables (19 combined). Compile clean (one
pre-existing warning, Smalt.Mcp.Router/`effective_ttl`, not this diff's).

## Auth note (unflipped residual)

Conn-string construction sends SAS `SharedAccessKey sig=...` and is refused 401
MalformedBearerHeader by the emulator's bearer-only 9444 auth (lib/smalt/auth/bearer.ex).
The witness rides a TokenCredential (bearer). Serving SAS on the ATOM plane is a
separate, unregistered residual — disposition left to the registrar.

## Disposition

Row KD-51 (canonical v26.10.14 register) is flip-eligible: close condition
("Python admin client createQueue succeeds") witnessed on the wire. Flip via
`scripts/kd_flip.py --apply` is registrar-owned; witness receipt mtime postdates
all three shim/lib edits. `created_at_utc` renders None (runtime fields not
emitted) — disclosure, not a falsifier failure; candidate KD row material.
