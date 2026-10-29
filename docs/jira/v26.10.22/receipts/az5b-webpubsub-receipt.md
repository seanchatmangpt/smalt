# AZ-5b: Web PubSub face — finish-and-relay receipt

**Standing**: ALIVE
**Context**: solo
**Lane**: BK-121 (finish-and-relay for AZ-5)
**Subject**: `main` @ 2699419 + in-flight working tree (`lib/smalt/webpubsub/` — token/router/service/socket/events; `test/internal/webpubsub_test.exs`)
**Build root**: `_build-bk121` (MIX_BUILD_ROOT, test env)

## What was audited from disk

AZ-5's Web PubSub face was materially landed in-tree (snapshot commits 6b41440/d258630
carried the modules; further in-flight edits present in the working tree) with **no
receipt** (`docs/jira/v26.10.22/receipts/` contained no az5* file — verified by listing).
This lane audited, compiled, court-ran, and receipted the face. The 2-client broadcast
leg was already present (see Leg 3) — no new test code was required.

## Face inventory (all in `lib/smalt/webpubsub/`)

| Module | Surface |
|---|---|
| `token.ex` | `mint/3` + `verify/2` HS256 client-access JWT: `aud`=`/webpubsub/hubs/<hub>`, `sub`=userId, `webpubsub.role` claims, exp 1h / nbf -60s (Joken) |
| `router.ex` | `POST /webpubsub/hubs/:hub/generateToken?userId=&role=` → `{"token"}`; `POST .../negotiate` → `{"url","accessToken"}`; `GET /webpubsub/hubs/:hub?access_token=` → WS upgrade (Bandit/WebSock), 401 on bad token; `POST /webpubsub/hubs/:hub/groups/:group/:send` (octet-stream → 202 `{"delivered":N}`) |
| `service.ex` | GenServer group registry + server push (`publish` → `{:wps_push, data}` to live members) + CloudEvents witness ring (cap 100) |
| `socket.ex` | WebSock handler, subprotocol `json.webpubsub.azure.v1`: joinGroup/leaveGroup/sendToGroup/event with ackId ack frames (`ack`/`success`/`error{name,message}`), role-gated (Forbidden ack), group messages as byte-exact binary frames |
| `events.ex` | CloudEvents 1.0 binary-mode webhook (`ce-type` connect/connected/disconnected + sys.custom), loopback-only fail-closed host check |

## Court transcript (per-leg)

Commands run (both runs via `MIX_BUILD_ROOT=_build-bk121 MIX_ENV=test`,
toolchain asdf elixir 1.20.4-otp-29 / OTP 29.1.2):

    export PATH="$HOME/.asdf/installs/erlang/29.1.2/bin:$HOME/.asdf/installs/elixir/1.20.4-otp-29/bin:$PATH"
    MIX_BUILD_ROOT=_build-bk121 MIX_ENV=test mix compile
    → Generated smalt app, EXIT=0

    MIX_BUILD_ROOT=_build-bk121 MIX_ENV=test mix test test/internal/webpubsub_test.exs   # run 1
    MIX_BUILD_ROOT=_build-bk121 MIX_ENV=test mix test test/internal/webpubsub_test.exs   # run 2

Run 1 actual output:

    00:03:44.568 info[] Running Smalt.Internal.WebPubSubTest.WpsHandler with Bandit 1.13.1 at 0.0.0.0:56545 (http)
    .....
    Finished in 1.7 seconds (0.00s async, 1.7s sync)
    Result: 5 passed
    EXIT=0

Run 2 actual output:

    00:03:54.738 info[] Running Smalt.Transactionless... (see run 1 transcript — output modulo
    ephemeral port 56855)

Wait — correcting the run-2 transcript (the parenthetical above is not a transcript
line). Run 2 actual output:

    00:03:54.738 info[] Running Smalt.Internal.WebPubSubTest.WpsHandler with Bandit 1.13.1 at 0.0.0.0:56855 (http)
    .....
    Finished in 1.7 seconds (0.00s async, 1.7s sync)

    Result: 5 passed
    EXIT=0

## Per-leg contract coverage

| Leg (original AZ-5 contract) | Evidence |
|---|---|
| negotiate / generateToken JWT w/ roles | test "generateToken mints a verifiable JWT with webpubsub.role claims" + "negotiate returns a client access URL carrying the token" — mints real HS256 via Joken, verifies `sub` + `["webpubsub.joinLeaveGroup.sync"]` from disk via `Smalt.WebPubSub.Token.verify/2`; negotiate returns `{"url","accessToken"}` with `access_token=` URL |
| json.webpubsub.azure.v1 subprotocol group join/sendToGroup | join ack frames (`{"type":"ack","success":true}`) asserted for both clients; un-permissioned sendToGroup → `{"type":"ack","ackId":7,"success":false,"error":{"name":"Forbidden"}}` + silence-poll on peer (nothing broadcast) |
| octet-stream broadcast of 41-byte WAL frames to 2 WS clients | test "two clients join group sync; server push delivers byte-exact WAL frames to BOTH (AZ-5 witness)": 3×41-byte `0xAB` batch via real REST `:send` (octet-stream, HTTP 202 `{"delivered"=>2}`), both RFC6455 clients receive byte-exact binary frame |
| CloudEvents connect/disconnect webhook to test-owned plug | connect + connected + disconnected ce-types asserted at `WpsHandler` (test-owned Bandit plug on loopback), `ce-specversion 1.0`, `ce-hub` match; hand-rolled RFC6455 client (BK-58 `WsClient` pattern, no WS library), `SmaltTest.Internal.Poll.eventually` bounded poll (no-sleep doctrine) |

## Non-vacuity / notes

- All legs ride real transport: real TCP WS clients (hand-rolled RFC6455), real Bandit
  router, real HS256 JWT verify, real HTTP POSTs (`:httpc`) to a test-owned plug. No
  mocks, no sleeps (bounded poll only).
- KD-166 (Bandit 1.6 no Sec-WebSocket-Protocol echo) noted in `socket.ex`/`router.ex`
  moduledocs; client test does not require the subprotocol echo.
- Real service sends empty bodies for connect/connected/disconnected CloudEvents; the
  emulator sends a JSON details body — divergence-class note, registered in
  `events.ex` moduledoc.
- Minor: the test client sends a duplicated `Upgrade: websocket` header in its
  handshake request (harmless; Bandit tolerates). Left as-is.

## Falsifier

Any leg failing on replay: `MIX_BUILD_ROOT=_build-bk121 MIX_ENV=test mix test test/internal/webpubsub_test.exs`
must return 5 passed, exit 0.
