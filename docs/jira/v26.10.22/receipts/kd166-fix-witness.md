# KD-166 Fix Witness — SUBPROTOCOL ECHO LANDED (close condition MET)

**Standing:** ALIVE (fix landed + real-wire witness, close condition met)
Context: solo
Date: 2026-10-22 · Lane: KD-166F · Repo: /Users/sac/smalt

## Fix landed

`lib/smalt/webpubsub/router.ex` (`# KD-COVERS: KD-166`): before
`upgrade_adapter(:websocket, ...)`, the GET `/webpubsub/hubs/:hub` client-WS
route now echoes the client's requested WebSocket subprotocol:

- `echo_subprotocol/1` reads `sec-websocket-protocol` request headers; when the
  client offered one, sets `put_resp_header("sec-websocket-protocol", <first
  requested protocol>)`. Bandit 1.13.1's `send_handshake/2` appends
  `conn.resp_headers` to the 101, so the echo rides the custom 101-echo path
  identified in `kd166-witness.md`.
- No subprotocol offered -> no header (RFC 6455 §4.1: a server must not return
  a protocol the client did not request).

## Raw wire witness (real substrate, embedded, unedited)

Substrate booted lane-safe by this lane (`scripts/substrate.sh up` with the
lock fd closed `9>&-`; pid 63671, port 5676 `beam.smp` LISTEN). Raw python3
socket client, same handshake shape as `kd166-witness.md`:

```
POST http://127.0.0.1:5676/webpubsub/hubs/chathub/generateToken?userId=witness166f -> 200 JWT
```

Positive leg (client offers `Sec-WebSocket-Protocol: json.webpubsub.azure.v1`):

```
HTTP/1.1 101 Switching Protocols
date: Thu, 22 Oct 2026 11:39:14 GMT
c: ...
upgrade: websocket
connection: Upgrade
sec-websocket-accept: uFohkt2RpIAoYzWBGQrgpUhgzOA=
cache-control: max-age=0, private, must-revalidate
sec-websocket-protocol: json.webpubsub.azure.v1
```

**`sec-websocket-protocol: json.webpubsub.azure.v1` IS echoed in the 101.**
Close condition met. The KD-166 witness close condition is also bound to the
first/primary protocol semantics: the fix echoes the first of a comma-list.

Negative leg (client offers no subprotocol):

```
HTTP/1.1 101 Switching Protocols
date: Thu, 22 Oct 2026 11:39:14 GMT
upgrade: websocket
connection: Upgrade
sec-websocket-accept: DFAv4jRfdoKJO4yVAxg8P68pVh8=
cache-control: max-age=0, private, must-revalidate
```

No echo header when not requested — correct RFC 6455 posture, header leak-free.

## Regression

```
$ MIX_BUILD_ROOT=_build-kd166f mix test test/internal/webpubsub_test.exs test/internal/wps_exp4_court_test.exs
...
Finished in 1.8 seconds (0.00s async, 1.8s sync)
Result: 17 passed
```

wps_exp4 court + webpubsub_test green in the lane build root
(`_build-kd166f`), post-fix.

## Flip

KD-166 flipped via `scripts/kd_flip.py --apply --witness KD-166=<this file>`
(witness receipt postdates the `router.ex` shim mtime; row moves
OPEN -> CLOSED-SIMULATED per the kd_flip convention). Register:
`docs/jira/v26.10.14/KNOWN_DIVERGENCES.md` (canonical).

## Commands

- `scripts/substrate.sh status` -> UP (this lane's boot, lock fd `9>&-`)
- raw socket witness, both legs, single pass each, exit 0
- `mix test` regression: 17 passed, 0 failures
