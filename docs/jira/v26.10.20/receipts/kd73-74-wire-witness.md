# KD-73 / KD-74 wire witness — get-message-sessions + batch-delete-messages

- **Standing: PARTIAL_ALIVE** — both KD ops witnessed PASS on the real wire
  (8/8 probe verdicts), with two named typed partials disclosed (below).
- **Context: slice** (W13-B witness lane, solo rhea+SDK probe against a
  lane-private substrate block)
- Date: 2026-10-20/21 · Lane: W13-B · Probe:
  `/Users/sac/smalt/verification/ts/kd73-74.probe.cjs` (rhea 3.0.5 raw
  $management + @azure/service-bus 7.10.0 session lock)

## Subject

KD-73 (`com.microsoft:get-message-sessions`) and KD-74
(`com.microsoft:batch-delete-messages`) on `lib/smalt/messaging/amqp/management_rpc.ex`,
witnessed over real AMQP 1.0 frames (SASL ANONYMOUS → CBS SAS put-token →
per-entity `$management` node `<queue>/$management`).

## Method

1. Boot lane-block substrate (b13, ports 39130..39135) via `scripts/substrate-ctl
   up --block b13 --fresh` (per-boot key in `keys/b13.sbkey`, never touching
   the main substrate or another lane's block).
2. ARM-provision namespace + queue with `requiresSession=true`
   (`PUT .../namespaces/kd73ns/queues/kd73-sess-q`, 201, requiresSession:true).
3. rhea connection: SASL ANONYMOUS + CBS put-token (SDK form: token string IS
   the body; audience `sb://host:port/entity`).
4. Seed 3 session messages via SDK sender (sessionId w13s1), lock the session
   via SDK `acceptNextSession` + receive + complete (creates the
   `:smalt_sb_sessions` record the sessions ops read).
5. Raw $management ops via rhea; replies correlated by message-PROPERTIES
   correlation-id, statusCode/statusDescription read from application
   properties.

## Verdicts

- **KD-73 PASS** (sessions op shape witnessed): 200 with `sessions-ids`
  array containing w13s1, detail array of the same length carrying
  `session-id` / `session-state-size` / `message-count` / `updated-at`
  (plus `session-state`), and numeric `skip`.
- **KD-74 PASS** (batch-delete witnessed on real sequence numbers): peek →
  200 with `sequence-number` per row → batch-delete both → 200 → re-peek 204
  empty. Absent sequence numbers (999999) delete-present skip → 200.
- Negative court: unknown session → 404 SESSION_NOT_FOUND; missing sequence
  numbers → 400 SEQUENCE_NUMBERS_REQUIRED; unknown operation → 501
  UNSUPPORTED_OPERATION; unknown queue → 200 with empty `sessions-ids`
  (emulator law: QUEUE_REQUIRED fires only on a blank queue field; NOT_FOUND
  is not part of this op's surface).

## Command output (probe run, 2026-10-20 22:3x PDT)

```
booted b13 (AMQP 39130, ARM 39132); queue kd73-sess-q requiresSession=true
CBS put-token OK (audience sb://127.0.0.1:39130/kd73-sess-q)
session w13s1 locked via SDK acceptNextSession
PASS KD-73 get-message-sessions shape (sessions-ids + detail + skip)
PASS KD-73 set/get-session-state round trip
PASS KD-74 batch-delete on real sequence numbers (peek -> delete -> empty re-peek)
PASS KD-74 absent-sequence-number skip (delete-present semantics)
PASS KD-73 negative: unknown queue -> 200 empty sessions (emulator law)
PASS KD-73 negative: unknown session -> 404 SESSION_NOT_FOUND
PASS KD-74 negative: missing sequence numbers -> 400 SEQUENCE_NUMBERS_REQUIRED
PASS negative: unknown operation -> 501 UNSUPPORTED_OPERATION
KD73-74 SUMMARY pass=8 fail=0
```

## Named typed partials (disclosed loudly)

1. **rhea string-keyed session-filter attach wedges the server connection**
   (typed partial: W13-B observed, W13-B did not repair — another lane owns
   `lib/smalt/messaging/amqp/connection.ex` in-flight). A rhea receiver attach
   with `filter: { "com.microsoft:session-filter": "w13s1" }` (STRING key)
   gets no attach echo and the whole connection stops processing frames —
   every downstream mgmt call times out. The same attach with the SDK's
   symbol-keyed filter shape passes. Witnessed x3 runs (22:0x–22:3x PDT),
   frames traced with `DEBUG=rhea:frames`: kd-sess-rx attach sent, no echo,
   all later frames unanswered. Server log silent (no pump-raise line).
   Close condition: session-filter parse path accepts the plain-map
   (string-keyed) filter form or refuses it typed.
2. **peek-message / batch-delete-messages entity resolution**: these handlers
   resolve the queue ONLY from `queue_from_request` (associated-link-name or
   `<entity>/$management` mgmt-node address); a body-field `queue` string is
   ignored (unlike get/set-session-state which read `body_field(body,"queue")`)
   — a 204-empty reply for a non-empty queue results when the client omits
   the associated-link-name/mgmt-node form. Disclosed as a client-facing
   sharp edge (my earlier 204s were this), not a repair.
   Close condition: peek/batch-delete also honor the body `queue` field.

## Concurrent-lane disclosures (compile-freeze law)

- W13-B witnessed in-flight `connection.ex` states at 21:39–21:54 PDT: boot
  fails `{:badmatch, {:error, :not_owner}}` in
  `Smalt.Amqp.Connection.init/1` (controlling_process race), typed in
  `/tmp/smalt-substate/logs/b13.log`... correct path
  `/tmp/smalt-substrate-state/logs/b13.log`. Fixed by the owning lane at
  ~21:46; disclosed, not repaired by W13-B.
- rhea default auto-reconnect + per-connection CBS claims: after any
  reconnect, replayed links detach `UNAUTHORIZED_ENTITY` (claims keyed by
  connection owner pid). The probe pins `reconnect: false` for typed
  failures; SDK probes unaffected (SDK re-puts its token after reconnect).

## Replay

```
node /Users/sac/smalt/verification/ts/kd73-74.probe.cjs
# boots/downs its own b13 block; exit 0 = witness pass
```
