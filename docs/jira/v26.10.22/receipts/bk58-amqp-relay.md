# BK-58 — AMQP-over-WebSocket relay (BK-40 lane 3)

**Standing: PARTIAL_ALIVE** — host-side relay ALIVE (witnessed end-to-end); browser eg/topic/eh leg TYPED-PERMANENT under the workspace transport law (mechanism corrected: transport law, not "needs AMQP sockets").

Context: solo

## Law analysis (read fresh on disk, this lane)

- `workspace/lib/smalt.ts` is the entire workspace transport surface:
  `assertLocalUrl` (loopback-only) + `smaltFetch` (fetch-only, `redirect:
  "error"`). There is no WS face. `fetch()` cannot do WebSockets — there is
  no lawful browser WS transport under the law as written.
- `workspace/eslint.config.mjs` bans `ws*` imports, `XMLHttpRequest`, and
  raw-fetch literals/template-literals. It does NOT currently ban the
  browser-native `WebSocket` global — but the documented law
  ("Networking ONLY through lib/smalt.ts") is smaltFetch-only.
- Verdict: the browser eg/topic/eh leg cannot ride `smaltFetch` to a WS
  endpoint. Under the law as written the browser leg is TYPED-PERMANENT —
  **the corrected SKIP mechanism is the workspace transport law
  (smaltFetch-only), NOT "needs AMQP raw sockets"** (the in-browser-BEAM
  `:eprotonosupport` fact remains the underlying motivation for the law,
  but the proximate blocker is the law itself). Extending the law to admit
  a loopback-native `WebSocket` global is a harness self-edit (C22 class)
  requiring an out-of-family falsifier — not done here, and not needed for
  the deliverable.

## Deliverable (delivered where lawful)

- `lib/smalt/messaging/ws_amqp_relay.ex` — domain-blind WebSocket → AMQP
  relay: `GET /ws/amqp/sb` → `Smalt.Amqp.Listener.Sb` (5672 lane),
  `GET /ws/amqp/eh` → `Smalt.Amqp.Listener.Eh` (5673 lane); other paths →
  typed 404. The socket process owns the raw TCP leg for the WS lifetime
  and shuffles opaque bytes both ways (no AMQP interpretation beyond
  WS/TCP framing). Listener-down degrades honestly: typed WS close 1011
  naming the lane, never a fake open.
- Wired in `lib/smalt/plane/data_supervisor.ex` (data-plane subtree, AZB-22b
  10s bounded graceful-stop, port `:ws_amqp_relay_port` default 5675,
  probed-free under MIX_ENV=test via `config/test.exs`).
- `test/internal/ws_amqp_relay_test.exs` — Chicago-style witness: real
  RFC6455 client over real TCP (`SmaltTest.WsClient`, no WS library), real
  Bandit relay, real `Smalt.Amqp.Listener` in `:eh` mode with real broker
  connections under `Smalt.AmqpBroker.ConnSup`. No mocks.

## Witnesses (actual output, MIX_BUILD_ROOT=_build-bk58)

- `mix test test/internal/ws_amqp_relay_test.exs` → **rc=0, "Result: 2 passed"**.
  - unknown-lane 404 refusal: PASS
  - EH publish → consume end-to-end THROUGH the relay: PASS — AMQP header
    echoed verbatim through the relay; settled publish on a hub-address
    sender link accepted (disposition accepted); partition receivers with
    `link_credit` flows received the published event back through the
    relay (delivered transfer payload matches the published event string).
- Compile gate: `mix compile --force --warnings-as-errors` → exit 0, zero
  warnings in lane files.
- Debug shims used during diagnosis (BK58-FLOW / BK58-DELIV / bk58-dbg /
  BK58-DBG state dump) were REMOVED after the witness; final tree greps 0
  (only benign `bk58-` fixture names in the test). The relay debug shim is
  also removed — the delivered `handle_info({:tcp,...})` clause is the
  plain push.

## Diagnosis record (for the lane's falsifier trail)

- The failing-first iterations were lane-own test bugs, not relay bugs:
  (1) the flow performative field is `link_credit`, not `credit` — a wrong
  field encodes null and grants credit 0 (wire-decoded `lc=nil`), and
  (2) the second flow frame's field had the same error (fixed both).
- The broker EH delivery path was verified clean via a raw-socket probe
  (event lands under `<hub>/partitions/<md5(pk) mod 2>`; raw delivery works
  with correct `link_credit`), isolating the defect to the test, not the
  relay or broker.

## Compile-freeze disclosures (SLA #2/#6)

- `lib/smalt/plane/data_supervisor.ex`: the STORE-2 sibling lane landed a
  `Smalt.Store.Heir` child ref before the module existed, aborting every
  lane's boot for several minutes. This lane applied a disclosed unblock
  (omit child until module exists) to get lanes unblocked; the Heir module
  has since landed and the file is restored to the sibling lane's plain
  child spec. Disclosed here per SLA; the sibling receipt (bk67) also
  carries the class note if its owner adds it.
- Shared `mix` lock-dir races (File.Error on mix_lock_user501) and sibling
  WIP syntax errors (partition.ex / journal_sink.ex / Heir) stalled this
  lane ~25 min total; retried through each window, no silent passes.

## No-commit note

Per lane orders: nothing committed by this lane. In-flight files:
- `lib/smalt/messaging/ws_amqp_relay.ex` (new)
- `test/internal/ws_amqp_relay_test.exs` (new)
- `lib/smalt/plane/data_supervisor.ex` (relay child + port fn)
- `config/test.exs` (ws_amqp_relay_port ephemeral probe)
- `docs/jira/v26.10.22/receipts/bk58-amqp-relay.md` (this file)
