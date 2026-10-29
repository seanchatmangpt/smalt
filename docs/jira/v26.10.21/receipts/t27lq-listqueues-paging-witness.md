# T27LQ — listQueues ATOM feed paging fix (KD-155SDK out-of-scope note chase)

Context: pair(live-substrate wire repro + real-node-SDK end-to-end witness (existing pair line normalized to law form))

- **Date**: 2026-10-21
- **Lane**: T27LQ (writer), repo `/Users/sac/smalt`
- **Context**: pair (live-substrate wire repro + in-process integration tests
  + real-node-SDK end-to-end against a scratch listener, same window)
- **Build root**: `MIX_BUILD_ROOT=_build-t27lq`

## Standing
**Standing:** ALIVE

**ALIVE** — the defect is reproduced on the live substrate, characterized,
fixed in `lib/smalt/messaging/amqp/atom_bridge.ex`, and proven end-to-end
with the real `@azure/service-bus` 7.10.0 `ServiceBusAdministrationClient`
`listQueues().byPage()` surface. The live substrate (pid 8877) still runs the
pre-fix code (never restarted, per lane law); re-witness on the next
substrate recycle is the outstanding step before any KD flip.

## Repro (live substrate, never restarted)

`/Users/sac/smalt/tmp/t27lq-listqueues.cjs` (exit 0, loud-SKIP contract):
real SDK `listQueues().byPage({maxPerPage:50})` on TLS 9444 →

```
[LIST-FAIL] name=RestError statusCode=404 code=MessageEntityNotFoundError
[LIST-FAIL-RESP] status=404 body="<?xml ... <error ...><code>ResourceNotFound</code>..."
```

Root cause: the ATOM bridge `dispatch("GET", ...)` had no list route —
`GET /$Resources/Queues?...` (two path segments) fell into the single-entity
clause and answered the flat 404 `ResourceNotFound` error XML.

## Characterization (wire truth, SDK 7.10.0 source-read)

Real-Azure / SDK contract for `GET /$Resources/Queues?api-version=...&$top=N&$skip=M`:

1. 200 `application/atom+xml;type=feed` ATOM **feed** (never a flat 404):
   `<feed xmlns="http://www.w3.org/2005/Atom">` with per-queue `<entry>`s
   (no per-entry XML declaration — one declaration per document).
2. Continuation: `<link rel="next" href=...>` whose href must be **absolute**
   and carry `$skip=K` (the SDK's `getMarkerFromNextLinkUrl` parses the href
   as a URL and reads `$skip`; a relative href throws into the client's
   PARSE_ERROR "cannot form a list" branch).
3. The feed must carry **two** `<link>` elements (rel="self" + rel="next")
   when a next page exists: the SDK's xml2js parse yields `feed.link` as a
   bare object for a single link, and `parseLinkInfo` only walks arrays —
   a single next link is silently dropped and the SDK stops paging, losing
   queues (measured: page1 3-of-3, no continuation).
4. The SDK percent-encodes the query (`%24top=2`, not `$top=2`) — the server
   must decode before matching (wire witness: echo-server sniff showed
   `GET /$Resources/Queues?api-version=2024-05&%24top=2 HTTP/1.1`).

## Diff

`lib/smalt/messaging/amqp/atom_bridge.ex` (working tree, on top of the
coordinator checkpoint befb45e which landed the first feed cut):

- GET dispatch: list route `$Resources/Queues` → `list_queues_feed/2`
  (`$top`/`$skip` slicing, `URI.decode` of the query before matching).
- Feed renderer: feed head/id/title/updated + `entry_body/2` entries
  (declaration-less; the single-entry GET keeps its declaration), sorted
  deterministic names from `Store.list_prefix(:smalt_resources, ...)` on the
  downcased queues key prefix.
- Continuation contract: `rel="self"` + `rel="next"` link pair, absolute
  `sb://emulator/...` hrefs carrying `$skip`.
- `queue_entry_xml/2` returns a materialized binary (`IO.iodata_to_binary`)
  — an iolist payload crashed `respond/3`'s `byte_size/1`, killing the serve
  task and closing the socket with no response (KD-155 DELETE wire test
  caught it failing: `{:error, :closed}` on the PUT leg).

New Chicago integration test (failing-first: 3/3 fail with the exact wire
404 pre-fix, 0 failures post-fix):
`test/integration/t27lq_list_queues_feed_test.exs` — real Store + real
dispatch tuple, asserts the rendered XML bytes (feed shape, paging,
encoded-query leg, link-pair + absolute-href contract).

## Outputs

In-process (MIX_BUILD_ROOT=_build-t27lq):

```
mix test test/integration/t27lq_list_queues_feed_test.exs \
         test/integration/kd155_delete_framing_test.exs
Finished in 0.1 seconds — 8 tests, 0 failures
```

Real-SDK end-to-end (scratch `Smalt.Amqp.Listener` on private port 39880
booted with `mix run --no-start`, lock fd closed, fresh Store; scratch beam
torn down after — port now free; live substrate untouched):

```
[CREATE-OK] t27lq-sdk-a,t27lq-sdk-b,t27lq-sdk-c
[PAGE 1] maxPerPage=2 names=["queues/t27lq-sdk-a","queues/t27lq-sdk-b"] continuation=2
[PAGE 2] maxPerPage=2 names=["queues/t27lq-sdk-c"] continuation=none
[BY-PAGE-2] pages=2 total=3
[LIST-OK] pages=1 queues=["queues/t27lq-sdk-a","queues/t27lq-sdk-b","queues/t27lq-sdk-c"]
[DONE] EXIT=0
```

## Honest notes

- Probe-side corrections in-lane: (1) the service-bus admin byPage page IS
  the queue array (`p.queueItems` was a probe bug); (2) SDK 7.10.0 reads
  `byPage({maxPageSize})`, not `maxPerPage` — both probe artifacts were fixed
  before the final witness run.
- Compile-freeze churn: the powl2 wave (another lane) broke the shared
  compile four times mid-session; per SLA I polled with bounded retries and
  did NOT apply any unblock fix (the owner landed between attempts).
  Compilation now green on `_build-t27lq`.
- Pre-existing, unrelated: `mix test` prints warnings in powl2/change_feed
  and amqp/connection (other lanes' in-flight work).
- Final test binary delta vs HEAD checkpoint befb45e: the self+next link
  pair with absolute hrefs (22 added lines in atom_bridge.ex) + the hardened
  test assertions; the base feed route landed in the coordinator's
  checkpoint of this lane's in-flight work.

## Mint recommendation (register untouched)

- **KD-157 (recommended)**: Service Bus ATOM list surfaces (`$Resources/Queues`,
  and by symmetry `$Resources/Topics`/`Rules`) must answer a 200 ATOM feed
  with the SDK 7.10.0 continuation contract: two `<link>` elements
  (self+next), absolute next-href carrying `$skip`, `%24`-encoded query
  decoded server-side. Close condition: real-SDK `listQueues().byPage()`
  paged witness on the recycled substrate with the fix live (this receipt is
  the scratch-listener witness; substrate recycle pending).
- Topics/Rules list faces are NOT implemented here — out of T27LQ scope;
  they will 404 the same way until they get the same feed route.
