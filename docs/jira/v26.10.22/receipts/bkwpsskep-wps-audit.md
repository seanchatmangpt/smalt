# Receipt — BK-WPSSKEP: Web PubSub adversarial skeptic audit

**Standing**: PARTIAL_ALIVE (all four landed WPS repair waves verified against re-run
falsifiers — ALIVE claims hold; one NEW typed defect found in an in-flight sibling
edit, see WPS-SKEP-1)
**Context**: solo
**Date**: 2026-10-22 · Lane: BK-WPSSKEP · Repo: `/Users/sac/smalt`

## (1) Landed claims re-verified (re-run falsifiers, embedded output)

### Token fail-closed (EXPL-4 F1, `lib/smalt/webpubsub/token.ex`)

9 independent mint/verify probes (`/tmp/bkpsskep_token_probes.exs`, real Joken
HS256, `mix run --no-start`):

```
PASS full control: chathub={:ok, "u1", ["webpubsub.joinLeaveGroup"]} other-hub=:error
PASS no-aud: chathub=:error other-hub=:error
PASS no-exp: chathub=:error other-hub=:error
PASS no-nbf: chathub=:error other-hub=:error
PASS no-sub: chathub=:error other-hub=:error
PASS empty-sub: chathub=:error other-hub=:error
PASS expired: chathub=:error other-hub=:error
PASS hub-confusion aud: chathub=:error other-hub=:error
PASS wrong-signing-key: chathub=:error other-hub=:error
```

All 9 PASS; no-aud/no-exp/no-nbf/no-sub/empty-sub/expired/hub-confusion/wrong-key
all `:error`; valid token verifies only on its own hub.

### Subprotocol echo (KD-166, raw `:gen_tcp` handshake vs real Bandit)

```
RAW 101 LEG:
HTTP/1.1 101 Switching Protocols
date: Thu, 22 Oct 2026 12:34:39 GMT
upgrade: websocket
connection: Upgrade
sec-websocket-accept: s3pPLMBiTxaQ9kYGzzhZRbK+xOo=
cache-control: max-age=0, private, must-revalidate
sec-websocket-protocol: json.webpubsub.azure.v1
```

Echo present with protocol offered; `no-offer 101-no-echo: PASS=true`;
`multi-offer first-wins: PASS=true` (protoB, json.webpubsub.azure.v1 → protoB
echoed); `hub-B token on chathub 401: PASS=true`; `bad token 401: PASS=true`.

### Socket dispatch (EXPL-4 F6, in-process real module, real WebSock callbacks)

```
sendToGroup-no-group -> {"message":"InvalidMessage: sendToGroup: missing required key","type":"error"}
event-no-event      -> {"message":"InvalidMessage: event: missing required key","type":"error"}
sendToGroup-no-perm -> {"ackId":3,"error":{"message":"send to g","name":"Forbidden"},"success":false,"type":"ack"}
leave-no-role       -> {"ackId":4,"error":{"message":"leave g","name":"Forbidden"},"success":false,"type":"ack"}
join-no-role        -> {"ackId":5,"error":{"name":"Forbidden","message":"join g"},"success":false,"type":"ack"}
binary frame        -> {"message":"binary client frames are not subprotocol messages","type":"error"}
join-with-role      -> {"ackId":7,"success":true,"type":"ack"} groups=["g"]
leave-with-role     -> {"ackId":8,"success":true,"type":"ack"} groups=[]
```

Catch-all dispatch present (`socket.ex` ~line 113), no FunctionClauseError kill;
leaveGroup is permission-checked symmetric to joinGroup; join mutates `state.groups`
tracking (in-flight EXPL-11 F3 addition, consistent).

## (2) KD-169R credential gate — verified + bypass hunt

17 raw-wire legs against real Bandit + real router (real :gen_tcp HTTP, real Joken):

```
PASS absent cred -> 401 naming face
PASS query-param key bypass -> still 401
PASS lowercase scheme -> 401
PASS wrong SharedAccessKey -> 401
PASS SharedAccessKey trailing-space -> 401
PASS Basic scheme -> 401
PASS wrong-aud Bearer -> 401
PASS expired Bearer -> 401
PASS no-exp Bearer ADMITS (fail-open probe, expected admit)
PASS valid Bearer -> 200 + minted client token verifies hub-bound
PASS valid SharedAccessKey negotiate -> 200 + url carries access_token
PASS groups send valid cred -> 202
PASS groups send absent cred -> 401
PASS unknown action valid cred -> 404 (auth checked BEFORE 404)
PASS SharedAccessKey valid -> 200
```

Bypass hunt result: no bypass found. Query-param key rejected; case-varied header
NAME admitted (correct — HTTP header names are case-insensitive, Plug downcases);
case-varied header VALUE (scheme) rejected (exact scheme match, correct); wrong
scheme/trailing-space/wrong-key all 401. `case-varied HEADER NAME -> admitted
(case-insensitive, correct) PASS` was also witnessed separately.

**Hardenings noted (not defects, real-service-parity class)**: (a) the server
Bearer leg accepts a JWT with NO `exp` claim (joken absent-claim skip) — same
trust domain (signed with the access key) so not a bypass, but the same
fail-closed `@essential_claims` treatment as the client token (EXPL-4 F1) would
close it; (b) server-Bearer `aud` is bound to the client-supplied `Host` header —
key holders can pick their own audience; same trust domain, no bypass. Both are
key-holder-only, typed as hardening notes, not repair tickets.

Hub-scoping: the gate is account-level (hub-agnostic), matching real Azure
server credentials. Token mint still binds client `aud` to
`/webpubsub/hubs/<hub>`; hub-confusion refuses (`:error`), hub-B token on
chathub → 401 on the wire. Gate fires before 404 (auth-before-enumeration).

## (3) NEW DEFECT — WPS-SKEP-1 (typed, owner: EXPL-11 lane)

**In-flight EXPL-11 F2 edit (events.ex/service.ex mtime 05:20, mid-audit) breaks
the `{:delivery_result, ...}` cast contract → FunctionClauseError kills
`Smalt.WebPubSub` on EVERY client connect when `handler_url` is nil.**

* Sender: `events.ex:75` casts the 4-tuple `{:delivery_result, id, false,
  "no_handler"}` (and `:117/:120` send 4-tuples `{id, delivered?, status}`);
* Receiver: `service.ex:108` matches only the 3-tuple `{:delivery_result,
  event_id, result}`.
* Witnessed 4x: direct probe + wire runs — `** (FunctionClauseError) no function
  clause matching in Smalt.WebPubSub.handle_cast/2`, broker dies, supervision
  restarts it wiping groups registry + witness buffer — one broker kill per
  client connection (no_handler path fires on every connect/disconnected).
* The 25-test WPS suites pass DESPITE this because no test asserts broker
  aliveness after a connect — a tautology-shaped gap the F2 law itself warns
  about.
* Repair: align the tuple. Either (a) senders send `{id, {:no_handler, nil} |
  {:delivered, code} | {:refused, reason}}` 3-tuples to match service.ex, or
  (b) service.ex handles the 4-tuple `{id, delivered?, status}`. (a) matches
  the service.ex EXPL-11 comment contract ("Results (from Events.deliver/2)").
  Non-vacuity: with the fix, the direct cast probe must NOT kill the broker
  (re-run `/tmp/bkpsskep_cast.exs` equivalent: `GENSRV ALIVE after no_handler
  cast: true`).

**WPS-SKEP-1 makes the WPS surface PARTIAL_ALIVE as of 05:45Z 2026-10-22: every
landed repair holds, the in-flight F2 edit is the one open kill.**

## (4) Fresh suite runs

```
$ MIX_BUILD_ROOT=_build-bkpsskep2 bash scripts/fast_test.sh test/internal/wps_exp4_court_test.exs test/internal/kd169r_cred_gate_test.exs test/internal/webpubsub_test.exs
...
Finished in 1.7 seconds (0.00s async, 1.7s sync)
Result: 25 passed          (post-edit disk truth, 05:40Z)
```

Earlier run (pre-05:20 edits) also 25 passed (05:16Z). Token probes re-run
post-edit: token.ex mtime unchanged, 9/9 PASS.

## Notes

* Compile-freeze windows hit twice: (a) `lib/smalt/confidential_ledger/service.ex`
  broken ~05:25–05:27 (undefined `remainder_digits/1`, then missing `end` at
  :524) — resolved by the owning lane within the SLA window; no edit by this
  lane. (b) shared `lib/` recompiles picked up in-flight EXPL-11 webpubsub
  edits mid-audit; all findings reflect CURRENT disk truth (re-verified after
  thaw).
* No git state commands run; coordinator owns transitions. Substrate was UP
  (shared boot) throughout; untouched.
* Probe scripts: `/tmp/bkpsskep_{token_probes,wire,frame,inproc,hs,cast}.exs`
  (scratch, not repo files).
