# PY-4 — Real azure-servicebus SDK over loopback AMQP — BLOCKED (substrate AMQP wire gap)

- **Lane:** PY-4, wave v26.10.14
- **Lane artifacts:** `test/sdk-python/py_servicebus.py` (7 fail-closed probes,
  per-probe 90 s watchdog), venv `test/sdk-python/.venv-sb`
  (azure-servicebus 7.15.0, py3.14)
- **SDK/transport:** azure-servicebus 7.15.0, pyamqp transport only — uamqp is
  uninstallable on this host (no wheels for py3.11/3.14; source build fails)
- **Substrate:** `MIX_ENV=test mix run --no-start --no-halt` with
  `SMALT_TEST_AMQP_PORT=39140 / ARM_PORT=39141 / ARM_TLS_PORT=39143`,
  `sb_shared_key` minted `openssl rand -base64 32`, booted under exclusive
  `flock /tmp/smalt-substrate.lock`
- **Run receipts:** `test/sdk-python/.logs/probe-final*.log` (4 runs, all 0/7
  with the same signature), attach-wire evidence
  `test/sdk-python/.logs/pyamqp-attach-trace.log`

## Verdict: 0/7 PASS — transport-level BLOCKED; root cause is the substrate's
AMQP attach echo, not the probes

Every probe fails at the FIRST data-plane operation: pyamqp detaches every
link on attach. Client-side wire trace
(`test/sdk-python/.logs/pyamqp-attach-trace.log`):

```
INFO:azure.servicebus._pyamqp.link:Cannot get source or target. Detaching link
INFO:azure.servicebus._pyamqp.link:Link state changed: ATTACH_SENT -> DETACHED
INFO:azure.servicebus._pyamqp.management_link:Management link receiver state changed: ATTACH_SENT -> DETACHED
DEBUG:azure.servicebus._pyamqp.cbs:CBS completed opening with status: <ManagementOpenResult.ERROR: 2>
```

### Root cause (substrate side)

`lib/smalt/messaging/amqp/connection.ex` `handle_attach/3` echoes attach with
only `name/handle/role/initial_delivery_count` (`base_attach`). pyamqp's
`_incoming_attach` (`azure/servicebus/_pyamqp/link.py`) requires the echo to
carry non-empty `source` and `target` (frame[5]/frame[6]); absence →
"Invalid link" → detach → CBS open ERROR → the send path then blocks
indefinitely (bounded by the probe harness at 90 s/probe). rhea (JS SDK)
tolerates the missing echo — that is why the JS census passes while pyamqp
does not. The uamqp escape hatch is unavailable (build failure above). The
session case in `handle_attach` echoes `source` (session-filter) but still no
`target`, so session probes are equally blocked.

### Fix location (AMQP-wire lane, not this lane)

`connection.ex handle_attach/3`: echo back the client's `source`/`target`
from `perf` on every attach response (including `base_attach` and the session
case). Until it lands, azure-servicebus (pyamqp) cannot drive the data plane.
The probes in `py_servicebus.py` are otherwise complete and will exercise
send/peek/abandon/dead-letter(reason+description+custom
props)/defer+receive-by-seq/session/PT2S-lock-expiry once it lands.

## Per-probe results (final bounded run, probe-final4.log)

| # | probe | result |
|---|---|---|
| 1 | send_receive_batch_complete | TIMEOUT 90 s — hung on first send (attach echo gap) |
| 2 | peek | TIMEOUT 90 s — same root cause |
| 3 | abandon_requeues | TIMEOUT 90 s — same |
| 4 | dead_letter_surface (reason+description+custom props) | TIMEOUT 90 s — same |
| 5 | defer_receive_by_sequence | TIMEOUT 90 s — same |
| 6 | session_roundtrip (requires_session queue) | TIMEOUT 90 s — same |
| 7 | lock_expiry_PT2S | TIMEOUT 90 s on delivery path; provisioning half of the probe verified over real ARM HTTP (see below) |

## ARM provisioning receipt (real HTTP this run)

- `PUT .../resourceGroups/py4-rg?api-version=2021-04-01` → 201
- `PUT .../Microsoft.ServiceBus/namespaces/py4-ns` body
  `{"location":"eastus","skuName":"Standard"}` → 201 (nested
  `sku:{...}` → 400 GraphLaw InvalidResourceShape)
- `PUT .../namespaces/py4-ns/queues/py4-lock-q` body
  `{"location":"eastus","properties":{"lockDuration":"PT2S","maxDeliveryCount":10}}`
  → 201/200; PT2S accepted at the ARM plane
- `GET` same path → 200 with `properties.lock_duration` (snake_case) —
  **finding: lossy camelCase→snake_case read-back normalization on the queue
  child record. `QueueStore.arm_queue_properties/1` reads
  `props["lockDuration"]` (camelCase), so a queue created via ARM PUT with
  camelCase `lockDuration` may never apply it on the delivery claim path
  (clamp to default 30 s). Needs wire-lane confirmation on the delivery path
  (untestable here — transport blocked).**
- Python `ServiceBusAdministrationClient` cannot drive either surface: it
  hardcodes `https://` + the ARM URL space (PUT `/{entity}` → 404
  RouteNotFound), and the ATOM plane the JS admin client uses
  (`$Resources/Queues` over `http://host:5672`) is not served by this
  substrate.

## Harness notes

- Private ports 39140/39141/39143 (5672/9443 held by other lanes).
- The lane substrate was killed twice mid-run by external SIGTERMs (silent
  death in `substrate.log`, no shutdown banner) — concurrent-lane kill
  discipline, not a probe failure; relaunched under the exclusive flock each
  time.
- Probe harness is deterministic and fail-closed: per-probe 90 s watchdog
  (pyamqp blocks indefinitely on the dead CBS path), exit 1 on any FAIL.
