# KD-155 dedicated witness: ServiceBusAdministrationClient.deleteQueue

- **Date**: 2026-10-21
- **Lane**: KD155W (bench-runner), repo `/Users/sac/smalt`
- **Subject**: `@azure/service-bus` `ServiceBusAdministrationClient` (7.10.0,
  `verification/ts/node_modules`) against the live substrate
  (beam.smp pid 56472, ports 9443/9444/8443/5672/5673/9545 listening;
  liveness preflight passed; substrate never restarted).
- **Probes**: `/Users/sac/smalt/tmp/kd155-witness.cjs` (SDK leg) and
  `/Users/sac/smalt/tmp/kd155-raw-delete.cjs` (raw-socket HTTP leg; node's
  own HTTP parser trips on the DELETE response, so the raw leg rides a plain
  `net.Socket`). The substrate log was read only via grep/tail.

## (1) createQueue — expect success

```
[AUTH] SharedKey per-host accepted
[CREATE-OK] queue=kd155w-b4ufzh name=queues/kd155w-b4ufzh maxDeliveryCount=10
```

createQueue over the ATOM management face (port 5672, plaintext HTTP,
`UseDevelopmentEmulator=true` conn-string shape) succeeds. The KD-15
challenge/fallthrough key admission also witnessed: per-host dev key accepted.

## (2) deleteQueue — exact failure

```
[DELETE-FAIL] name=RestError
[DELETE-FAIL-MSG] Parse Error: Expected HTTP/, RTSP/ or ICE/
[DELETE-FAIL-CODE] HPE_INVALID_CONSTANT
[DELETE-FAIL-STATUS] undefined
[DELETE-FAIL-STACK] RestError: Parse Error: Expected HTTP/, RTSP/ or ICE/ |
    at ClientRequest.<anonymous> (.../node_modules/@typespec/ts-http-runtime/dist/commonjs/nodeHttpClient.js:212:11) |
    at ClientRequest.wrapper (node:events:639:12) | ... | at Socket.socketOnData (node:_http_client:825:5)
```

Also witnessed during the auth probe's cleanup attempt (same failure, so it
is deterministic, not load- or state-dependent).

## (3) Does the queue still exist — did DELETE reach the broker?

```
[GET-AFTER-DELETE] EXISTS — DELETE did not reach the broker
[LIST-AFTER-DELETE-FAIL] Detailed error message information not available. ...
```

The queue survives deleteQueue. **The DELETE never reaches the broker's
management logic at all** — it is not a broker-side delete failure.

## Raw HTTP DELETE shape (raw TCP socket, server bytes verbatim)

DELETE `/{queue}?api-version=2021-10` with SharedAccessSignature + x-ms-version:

```
===== DELETE RESPONSE =====
"\u0000\u0000\u0000=\u0002\u0000\u0000\u0000\u0000S\u0018À0\u0001À-\u0003£\u0013amqp:internal-error¡\u0014:bad_protocol_header@"
HEAD HEX: 0000003d02000000005318c03001c02d03a313616d71703a696e7465726e616c2d6572726f72a1143a6261645f70726f746f636f6c5f68656164657240 ...
```

The server answers the DELETE with an **AMQP protocol frame**
(`amqp:internal-error` / `:bad_protocol_header`), not an HTTP response —
node's parser reads the leading `\0\0\0=` and reports
`Expected HTTP/, RTSP/ or ICE/` → `HPE_INVALID_CONSTANT`. For contrast, GET
on the same socket returns a well-framed `HTTP/1.1 404 ...` ATOM error.

## Server-side log side (read-only)

`/tmp/smalt-substrate-state/substrate.log` (grep, read-only):

```
1374511:11:02:52.298 [warning] [amqp-conn] closing on :bad_protocol_header
```

(`grep -c` = 13 total; the 11:02:52.298 entry is this witness's DELETE.)

## Root cause (hypothesis — now pinned to source, not speculation)

`lib/smalt/messaging/amqp/connection.ex` sniffs the first 8 bytes and hands
HTTP to `Smalt.Amqp.AtomBridge.http?/1`
(`/Users/sac/smalt/lib/smalt/messaging/amqp/atom_bridge.ex:40-48`):

```elixir
def http?(<<method::binary-size(4), " ", _::binary>>)
    when method in ["POST", "DELE", "HEAD", "PATC", "OPTI"],
    do: true
```

The clause matches **exactly 4 method letters followed by a space**. `DELETE`
is 6 letters: the 5th byte is `T`, not a space, so the clause falls through
to `http?(_) -> false`, the connection is treated as AMQP, and the broker
replies with the `:bad_protocol_header` AMQP error frame. Only `GET`/`PUT`
(3 letters) and `POST`/`HEAD` (4 letters) survive the prefix sniff —
`DELETE`, `PATCH` and `OPTIONS` are all structurally unreachable on the
ATOM face. Verdict: **response-framing defect at the protocol-dispatch seam,
pre-broker** — not a routing defect (the URL/headers are correct; the same
socket's GET is answered by the ATOM face) and not an absent face (the
`dispatch("DELETE", ...)` handler exists in atom_bridge and is simply
unreachable).

## Fix shape (for the repair lane)

Add a 6-letter clause (`DELETE`, plus 5-letter `PATCH`/`TRACE` handled by
matching through the first space: e.g. take the binary up to the first
`" "` and membership-check the method word) instead of fixed-size prefix
matches. Close condition per KD-155: real-SDK deleteQueue succeeds
end-to-end (wire witness postdating any shim), or a typed pinion pins the
management DELETE response face; flip via `scripts/kd_flip.py`.

## Standing

- **Verdict**: framing defect (protocol-dispatch sniff misclassifies the
  HTTP DELETE as AMQP; broker delete logic never runs).
- **Standing**: ALIVE (defect witnessed on the live substrate, root cause
  pinned to source at `atom_bridge.ex:44-46`, raw-wire + log + SDK evidence
  chain complete). KD-155 stays OPEN until the fix + flip receipt lands.
- **Context: pair** (SDK witness leg + raw-wire leg over the same live
  substrate, same window).

---

## Re-witness 2026-10-21 (post-shim, post-token-fix)

Shim files retouched (KD-COVERS token normalization in
`lib/smalt/messaging/amqp/atom_bridge.ex`), so the mtime gate was re-satisfied
by re-running the dedicated court suite:

```
$ MIX_BUILD_ROOT=_build-lane1 mix test test/integration/kd155_delete_framing_test.exs test/integration/kd156_sb_shape_test.exs
...
Finished in 0.1 seconds (0.00s async, 0.1s sync)
9 tests, 0 failures
```

Standing: PASS — 9 tests, 0 failures (KD-155 framing + KD-156 SB-shape courts,
exit 0). Context: solo.
