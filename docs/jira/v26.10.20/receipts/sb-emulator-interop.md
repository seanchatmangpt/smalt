# W30-B — Microsoft SB Emulator Interop Probe (differential vs smalt AMQP face)

- **Standing: PARTIAL_ALIVE** — leg A (official emulator) 6/6 observed PASS;
  leg B (private smalt block b30) 3/4 with one **reproducible smalt defect**
  (AMQP peek drops application properties / breaks after complete). Leg B was
  additionally interrupted twice by concurrent lanes' in-flight `lib/` edits
  (compile freeze, disclosed below).
- Context: solo
- Date: 2026-10-21
- Probe: `/Users/sac/smalt/verification/ts/sb-emulator.probe.cjs`
- Raw run: `/tmp/sbemu-w30b/final-run.txt`, rows `/tmp/sbemu-w30b/probe-rows.json`

## Emulator stack (replay)

Docker (colima) was DOWN at lane start; started with `colima start`
(server 29.5.2). SQL Server 2022 (`mcr.microsoft.com/mssql/server:2022-latest`)
is **amd64-only and OOMs under arm64 emulation** ("Out of memory" → emulator
halts with `SQL Health Check failed … SQL DB Unhealthly`). The arm64-native
backend that works:

```bash
docker network create sbemu-net
docker run -d --name sbemu-sql --network sbemu-net \
  -e ACCEPT_EULA=Y -e MSSQL_SA_PASSWORD='SBemu-w30b-Pass!' \
  mcr.microsoft.com/azure-sql-edge:latest
docker run -d --name sbemu-emulator --network sbemu-net \
  -p 25672:5672 -p 25300:5300 \
  -e SQL_SERVER=sbemu-sql -e MSSQL_SA_PASSWORD='SBemu-w30b-Pass!' \
  -e ACCEPT_EULA=Y \
  mcr.microsoft.com/azure-messaging/servicebus-emulator:latest
```

(Note: the code block above is illustrative — the byte-exact commands used are
in `/tmp/sbemu-w30b/` history above; the probe file header carries the
authoritative stack. Also: the Config.json entity mount was NOT honored at
either documented path (`/ServiceBus-Emulator/Config.json` or
`/ServiceBus_Emulator/Config.json`) — the emulator booted its default config
(ns `sbemulatorns`, `queue.1`, `topic.1`) regardless, so the probe exercised
the default entities. Caveat recorded for a future lane.)

## Leg A — official emulator (isolated ports 25672 AMQP / 25300 mgmt)

Connection string used (verbatim documented shape, host port in endpoint):

```
Endpoint=sb://localhost:25672;SharedAccessKeyName=RootManageSharedAccessKey;SharedAccessKey=SAS_KEY_VALUE;UseDevelopmentEmulator=true;
```

| # | probe | result |
|---|---|---|
| A1 | send (`queue.1`) with literal `SAS_KEY_VALUE` key, port-in-endpoint, no `HttpTransportPort` | PASS — literal placeholder key accepted; endpoint port honored |
| A2 | receive + complete | PASS (1 msg) |
| A3 | peek (bounded 3s poll) | PASS |
| A4/A5 | `ServiceBusAdministrationClient.createQueue` via sb:// conn string (with/without `HttpTransportPort=25300`) | typed divergence both ways — the admin client speaks HTTPS to the endpoint host; the emulator mgmt face is plain-HTTP 25300 and unreachable from a `sb://` conn string (ECONNRESET) |
| A6 | wrong SAS key | **emulator accepts ANY key** — auth is shape-check only (documented literal placeholder, now wire-witnessed) |

## Leg B — smalt private block b30 (39300..39305, substrate-ctl, MIX_BUILD_ROOT=_build-lane30)

Shared substrate (beam on 5672) untouched throughout; b30 swept down at every exit.

| # | probe | result |
|---|---|---|
| B1 | `ServiceBusAdministrationClient.createQueue` on the same sb:// conn string | PASS — smalt serves the admin REST shape on the same endpoint; no `HttpTransportPort` needed (differential vs emulator, where it is unreachable). Note: requested `maxDeliveryCount: 7` was returned as **10** (default) — option not persisted (minor divergence candidate). |
| B2 | send + receive + complete | PASS (1 msg) |
| B3 | peek (bounded 3s poll) | FAIL — see Finding 1 |
| B4 | wrong SAS key | rejected with `INVALID_LOCAL_SAS` (enforce mode) — see Finding 2 |

```text
PASS smalt/admin-createQueue-no-HttpTransportPort [maxDeliveryCount=10]
PASS smalt/send-receive-complete [1 msg(s)]
FAIL smalt/send-receive-peek: peek missed smalt-2 within 3s
PASS smalt/auth-wrong-key [rejected: INVALID_LOCAL_SAS]
```

### Finding 1 (smalt defect, KD candidate): AMQP peek is broken two ways

Isolated with `/tmp/sbemu-w30b/peek-diag.cjs` on a fresh b30 block, fresh
`diag-q`, three phases, reproducible across runs:

1. **Peeked messages lose application properties.** Fresh queue, send 2
   messages with `messageId` set, peek 10 → `n=2`, bodies intact (`"1"`,`"2"`)
   but `messageId` empty on both. The emulator returns message-id correctly.
2. **Peek after receive+complete returns nothing.** receive+complete 2 →
   peek → `n=0`, and stays 0 for 3s even after a new send ("c"). Emulator
   peek continues to return messages after completes.

### Finding 2: smalt enforces SAS; emulator does not

`INVALID_LOCAL_SAS` on a wrong key (enforce mode) vs emulator accepting any
key. smalt is stricter than the official emulator here — real Azure accepts
valid-only keys, so smalt's model is closer to production, but the emulator's
documented literal-key convention means SDKs configured with the documented
emulator conn string work against smalt only when the key matches the block
key (i.e. `UseDevelopmentEmulator=true` conn strings are not portable between
smalt and the official emulator without swapping the key).

## Environment noise (disclosed, not attributed to smalt)

- Colima VM restart mid-lane (transient daemon failure) — containers survived;
  the emulator container had to be recreated after a halted-health state.
- Concurrent lanes twice froze the shared compile mid-run
  (`lib/smalt/data_plane/blob_error.ex` undefined `put_resp_header/3`;
  `lib/smalt/arm_gateway/router.ex:2272 invalid_match`); leg B waited them out
  with bounded 30s compile polls (150s and 60s). No shared files edited by this
  lane; the compile-freeze fixes were authored by their owning lanes.

## Cleanup

- Docker emulator stack removed; 25672/25300 verified free after sweep.
- b30 swept (substrate-ctl down --mode sweep every exit).
- `_build-lane30` (APFS clone of `_build-x3` test profile, 345 MB-class) left
  in tree for probe reruns — coordinator `just lane-clean` will reclaim it.
- `mix deps.get` was run (deps/ was absent; gitignored) — required for any
  private-block boot to resolve deps.

## Replay

```bash
# 1. emulator stack (commands in probe header), then:
node /Users/sac/smalt/verification/ts/sb-emulator.probe.cjs
# expected: LEG A 6/6, LEG B 3/4 with smalt/send-receive-peek FAIL
node /tmp/sbemu-w30b/peek-diag.cjs
# expected: phase1 n=2 with empty messageIds; phase2/3 n=0
```
