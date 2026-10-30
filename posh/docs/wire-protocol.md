# posh Wire Protocol (v1)

# Overview

posh speaks 4-byte big-endian length-prefixed JSON over its membrane
listeners: a unix domain socket (`socket` from `posh.yaml`, default
`run/posh.sock`) and an optional TCP listener (`tcp_addr`, e.g.
`127.0.0.1:7443`). On TCP, a JSON request envelope POSTed to `/` is answered
with the JSON response envelope (same envelope, no length prefix — HTTP
chunking does the framing); the length-prefixed framing is the native UDS
surface and is also valid on TCP raw sockets.

Reference implementation: `posh/internal/server/server.go` (`readFrame`,
`writeFrame`). Envelopes: `posh/internal/api/api.go`.

# Frame layout

    +--------+--------+--------+--------+--------------------------+
    |  len[3]|  len[2]|  len[1]|  len[0]|  JSON envelope (len bytes)|
    +--------+--------+--------+--------+--------------------------+

- The first 4 bytes are an unsigned 32-bit big-endian (network byte order)
  length of the JSON payload that follows.
- The payload is exactly `len` bytes of UTF-8 JSON; there is no trailing
  delimiter, padding, or checksum. The next frame starts immediately after.
- A length of 0 is refused (`frame length 0 out of bounds`); frames are
  closed on read error, so the peer sees EOF, not a partial envelope.

# Max frame size

`MaxFrameBytes = 4 MiB` (4194304 bytes) — `internal/server/server.go`. A
prefix of `0` or `> 4194304` aborts the connection with
`frame length %d out of bounds`. Clients MUST NOT exceed this bound; HTTP
bodies are likewise capped at `MaxFrameBytes` via `io.LimitReader`.

# Request envelope

```json
{
  "id": "req-1",
  "op": "echo",
  "params": {"msg": "hello"},
  "deadline": "2026-10-30T12:00:00Z"
}
```

- `id` (string, required): echoed verbatim on the response. DecodeRequest
  rejects an empty `id` or empty `op` as TRANSPORT-class decode failures.
- `op` (string, required): registry key in `cmd/posh/main.go`. Unknown ops
  are typed `UPSTREAM` errors ("unknown op: %s").
- `params` (map of string to string, optional): op arguments.
- `deadline` (RFC 3339 / RFC 3339Nano, optional; Go `time.Time` JSON): when
  present, dispatch derives a `context.WithDeadline`; a handler that runs
  past it answers a typed `DEADLINE` error. Zero/absent means no fence.

# Response envelope

Exactly one of `ok`/`error` is present. A response carrying both is
rejected by `DecodeResponse`.

```json
{"id": "req-1", "ok": {"result": {"msg": "hello"}}}
```

```json
{"id": "req-1", "error": {"code": "UPSTREAM", "op": "echo", "message": "..."}}
```

## Error codes (typed, closed set)

| Code            | Meaning                                                     |
|-----------------|-------------------------------------------------------------|
| `TRANSPORT`     | Malformed envelope, bad frame length, JSON decode failure.   |
| `UPSTREAM`      | Unknown op or upstream capability failure.                   |
| `DEADLINE`      | Handler exceeded the request deadline.                       |
| `REFUSED_EGRESS`| Destination host not on the `egress_allowlist` (default-deny).|

`Error` also implements Go `error` with `errors.Is/As` support (sentinel
constructors `NewTransport`, `NewUpstream`, ... in `internal/api/errors.go`),
so in-process Go clients get typed matching without re-parsing JSON.

# Deadlines

- `deadline` is wall-clock, RFC 3339, interpreted by the server's clock.
- `dispatch` turns it into `context.WithDeadline`; the DEADLINE error is the
  only deadline face a client sees — the handler is never torn down mid-frame
  in v1, it answers once, either ok or DEADLINE-typed error.
- Over HTTP, a DEADLINE error maps to HTTP 504; other errors map to 500,
  success to 200.

# Worked example

Request `{"id":"req-1","op":"echo","params":{"msg":"hello"}}` — 51 bytes:

    00 00 00 33                                        # length prefix (51)
    7b 22 69 64 22 3a 22 72 65 71 2d 31 22 2c 22 6f    {"id":"req-1","o
    70 22 3a 22 65 63 68 6f 22 2c 22 70 61 72 61 6d    p":"echo","param
    73 22 3a 7b 22 6d 73 67 22 3a 22 68 65 6c 6c 6f    s":{"msg":"hello
    22 7d 7d                                           "}}

Success response, 46 bytes, prefix `00 00 00 2e`:

    {"id":"req-1","ok":{"result":{"msg":"hello"}}}

Unknown-op error response (witnessed, prefix `00 00 00 4a`, 74 bytes):

    {"id":"req-1","error":{"code":"UPSTREAM","message":"unknown op \"nope\""}}

All envelopes above are Go `json.Marshal` compact output — no space after
`:` or `,`.

# Versioning

v1 is the only version. Additive changes (new ops, new `params` keys) do not
bump the version; a framing or envelope-shape change bumps to v2 with a new
socket path convention and this document updated first.
