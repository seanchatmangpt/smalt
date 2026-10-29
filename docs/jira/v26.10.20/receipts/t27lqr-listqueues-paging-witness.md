# T27LQ-r: listQueues ATOM feed paging — wire repro, root cause, fix

- **Date**: 2026-10-21
- **Lane**: T27LQ-r (relaunch of dead lane T27LQ; atom_bridge feed + integration
  test found on disk uncommitted from the dead lane, extended in-lane)
- **Repo**: /Users/sac/smalt
- **Context**: pair
- **Subject**: `@azure/service-bus` `ServiceBusAdministrationClient` 7.10.0
  (`/Users/sac/smalt/verification/ts/node_modules/@azure/service-bus`) against
  (a) the live shared substrate (pid 8877, pre-fix code, NEVER restarted —
  repro only) and (b) a lane-local instance on alt ports
  (15672/15673/19443/19444/18443/19545, `_build-t27r`, auth :enforce,
  cert env from `.smalt/tls/`), torn down at lane end.

## Repro (wire, loud-SKIP contract honored; substrate never restarted)

`tmp/t27lq-listqueues.cjs` (from the dead lane, endpoint parameterized in-lane)
against the LIVE substrate:

```
[RAW] status=404
[RAW-BODY-FIRST-2000] {"error":{"code":"RouteNotFound",...,"target":"/$Resources/Queues"}}
[LIST-FAIL] name=RestError statusCode=404 code=MessageEntityNotFoundError
```

The node SDK's listQueues rides `GET /$Resources/Queues?api-version=...` on the
management endpoint derived from the connStr (port-5672-style flat face, or the
9444 HTTPS alias face for bearer probes). Two independent defects stacked:

1. **Router route gap** (HTTPS management face): the ARM router's flat ATOM
   aliases were single-segment (`get "/:entity_name"`); the two-segment
   `/$Resources/Queues` fell to the catch-all `RouteNotFound` 404.
2. **Entry-id shape** (flat face after route fix): with the route fixed, the
   SDK lists zero/wrong-named items: the SDK's `setName` derives the resource
   name from the entry `<id>` URL PATHNAME
   (`atomXmlHelper.setName: pathname.substring(firstIndexOfDelimiter+1)`), so
   id `sb://emulator/queues/<name>` makes listQueues report every queue as
   `queues/<name>` (offline serializer receipt: `QueueName: "queues/t27lqr-seed"`).

## Root cause + fix (failing-first: both defects witnessed on the wire before edit)

- `lib/smalt/arm_gateway/router.ex`: added `get "/$Resources/:resource"` alias
  forwarding to the same flat dispatcher (`sb_atom_alias`), plus
  `sb_atom_alias` now reconstructs `path <> "?" <> query_string`
  (`conn.request_path` carries no query, which would have silently dropped
  `$top/$skip` continuation on the alias face).
- `lib/smalt/messaging/amqp/atom_bridge.ex`: entry `<id>` is now
  `sb://emulator/<name>` (single segment), comment OUTSIDE the XML heredoc.
  (First edit attempt landed the comment inside the heredoc — caught on the
  wire as a PARSE_ERROR, root-caused by parsing the feed with the SDK's own
  `parseXML`, fixed same session.)

Dead-lane work absorbed: ATOM feed renderer (feed head/entry/tail, `$top/$skip`
slicing, rel=self + rel=next link pair — the link ARRAY requirement of
`parseLinkInfo`, absolute hrefs) and the `Store`-backed page slice. Verified
disjoint sorted pages to exhaustion in ExUnit (real Store, real dispatch) and
on the wire with the real SDK `getQueues({maxCount: 2, skip: 0})`:

```
[P1] n=2 cont="2" names=["t27lqr-p1","t27lqr-p2"]
[P2] n=2 cont=undefined names=["t27lqr-p3","t27lqr-seed2"]
```

## Tests

```
MIX_BUILD_ROOT=_build-t27r mix test test/integration/t27lq_list_queues_feed_test.exs \
  test/integration/kd155_delete_framing_test.exs test/integration/kd51_sb_atom_https_test.exs
14 tests, 0 failures
```

New tests: ATOM feed shape, `$top/$skip` + rel=next continuation, empty-namespace
200 (never 404), HTTPS-face route + query-string preservation, flat-alias
regression guard, and the single-segment entry-id pin (refutes `queues/` prefix).

## Honest notes

- The shared compile was found BROKEN mid-run by another lane's in-flight
  `lib/smalt/tls.ex` edit (`:tlsv1.3` syntax error, mtime 13:03:12). I prepared
  a minimal unblock (`:"tlsv1.3"`), but the owner lane fixed it before my edit
  applied (my assert failed — no edit landed from this lane). Disclosed per the
  compile-freeze SLA; `tls.ex` shows +187 lines from that lane, none mine.
- Probe client bugs found in-lane and fixed (disclosed as probe artifacts, not
  server defects): my raw probe's template-literal `\$` sent a literal backslash
  on the wire (`GET /\$Resources/...` → legit 404), and the page-iteration probe
  read `page.queueItems` where `byPage` pages are arrays. Net effect: two
  apparent "server still broken" readings were client artifacts.
- SDK-side note (divergence candidate, not fixed — SDK behavior): SDK
  `listQueues().byPage({maxPerPage: N})` does NOT send `$top` on this variant
  (wire-observed url had no `$top`), so the server default (100) governs page
  size.

## KD-158 recommendation (register not edited)

**KD-158**: `ServiceBusAdministrationClient` listQueues/listTopics/listRules
paged-list surfaces. Divergence (open): SDK `byPage({maxPerPage})` never sends
`$top` on the iterator variant, so the emulator's default page size (100)
governs; continuation rides `<link rel="next">` `$skip` and works (witnessed
P1/P2 above). Close condition: real-SDK paged listing across queues, topics and
rules surfaces with continuation to exhaustion against the recycled substrate
(with the router alias + entry-id fix live), each surface returning correct
un-prefixed names.

## Standing

- **Standing**: ALIVE (fix verified end-to-end on the wire with the real SDK;
  the live shared substrate still runs pre-fix code and will 404 the
  `/$Resources` face until next recycle — repro receipt on file)
- **Context**: pair (wire repro + in-VM/instance SDK legs)
- MIX_BUILD_ROOT: `_build-t27r`
