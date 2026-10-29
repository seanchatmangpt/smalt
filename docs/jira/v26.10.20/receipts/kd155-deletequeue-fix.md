# KD-155 fix receipt — SB ATOM DELETE framing (two layers)

**Standing:** ALIVE
Date: 2026-10-21
Lane: kd155fix (writer)
Context: solo
MIX_BUILD_ROOT: _build-kd155fix

## Defects fixed

Layer 1 — `lib/smalt/messaging/amqp/atom_bridge.ex` `http?/1` matched fixed
3/4-byte prefixes ("DELE", "PATC", "OPTI") + space, so DELETE / PATCH /
OPTIONS fell through to AMQP header negotiation and the client read an AMQP
error frame (node: HPE_INVALID_CONSTANT).
Layer 2 — `dispatch("DELETE", ...)` answered 200 OK with a full ATOM entry
body (body-on-delete). Real Azure ATOM "Delete Queue" answers 204 No Content,
empty body, no Content-Length (RFC 9110 §8.6).

## Changes

- `lib/smalt/messaging/amqp/atom_bridge.ex`: `http?/1` now splits at the
  first space and checks the full method word against `@http_methods`
  (GET/PUT/POST/DELETE/HEAD/PATCH/OPTIONS/MERGE); `# KD-COVERS: KD-155`
  marker present. DELETE dispatch returns `{204, :no_content, <<>>}`; a
  dedicated `respond/4` clause emits `HTTP/1.1 204 No Content` with no
  content-type/content-length and no body. Module doc updated.
- `lib/smalt/arm_gateway/router.ex` `sb_atom_alias/3`: translates the ATOM
  face's 204 tuple to the ARM alias face's real-Azure shape (Queues - Delete
  = 200 OK, empty body; Plug 204s must not carry content-type headers).
  Keeps kd51 green; `# KD-COVERS: KD-155 layer 2` comment in place.

## Raw-wire bytes

BEFORE (HEAD code executed in-lane, scratch module `Kd155Before.AtomBridge`
compiled from `git show HEAD:lib/smalt/messaging/amqp/atom_bridge.ex`):

```
http?("DELETE /q HTTP/1.1...") = false   # defect: DELETE falls to AMQP path
http?("PATCH /q HTTP/1.1...")  = false
http?("AMQP\x00\x01\x00\x00")  = false   # non-HTTP still refused (safe)
HEAD handle_request("DELETE") tuple = {200, atom-content-type, <full ATOM entry body>}
```

AFTER (live substrate, beam booted 2026-10-21 11:11:05 from this tree, port
5672; also witnessed on a private-port lane instance):

```
PUT    kd155-witness -> HTTP/1.1 201 Created
DELETE kd155-witness -> HTTP/1.1 204 No Content\r\nconnection: close\r\n\r\n
                       (no content-length, no body bytes before close)
```

AMQP regression (same port): `AMQP\x00\x01\x00\x00` header still elicits the
AMQP protocol-header echo, never the ATOM bridge.

## Test output

```
MIX_BUILD_ROOT=_build-kd155fix mix test test/integration/kd155_delete_framing_test.exs \
  test/integration/amqp_kd131_133_triage_test.exs test/internal/kd134_requester_delivery_test.exs \
  test/integration/kd51_sb_atom_https_test.exs test/integration/kd156_sb_shape_test.exs
...
20 tests, 0 failures
```

kd155_delete_framing_test.exs (5 tests): sniff truth table (all 8 methods
admitted; AMQP/SASL/garbage refused), raw-TCP PUT→201 then DELETE→204 with
no content-length and zero body bytes, DELETE-missing→404 HTTP, AMQP header
→ AMQP echo regression.

## Honest notes

- kd51_sb_atom_https_test.exs previously pinned `del.status == 200` on the
  ARM alias face; the router translation keeps that pin green (ARM Delete
  Queue really is 200 empty-body), while the raw ATOM face now answers the
  Azure-truthful 204.
- Pre-existing, out-of-lane: `test/internal/internal_tier_census_test.exs`
  (3 failures: scvd_concurrency_courts.exs drift, owned by the SCVD lane)
  and `test/internal/kd134_requester_delivery_test.exs` (flaky in isolation:
  0-fail / 1-fail across runs; passed in the final combined tier run). Not
  touched by this diff (http?/1 has no causal path to delivery ordering).
- A double-recv-past-close harness artifact in the Layer-2 test
  (`:enotconn` on second `recv_exhausted`) was made lawful by reading the
  drained tail once; assertion strength preserved (drained bytes asserted
  == <<>>).
