# w6ai — Cosmos read-feed options (x-ms-max-item-count / x-ms-continuation / If-Modified-Since)

**Standing:** PARTIAL_ALIVE
Date: 2026-10-20
Lane: w6ai (wave-6 v26.10.20)
Subject: smalt @ main, uncommitted working tree (lane diff = lib/smalt/data_plane/cosmos_feeds.ex + tmp/w6ai_witness.exs)

## Landed

`lib/smalt/data_plane/cosmos_feeds.ex` (NEW): additive feed-option wrappers
over materialized cosmos doc sets — the query engine is untouched.

- `paginate_doc_set/3`: page-size clamp 1..1000; opaque version-tagged
  base64url continuation token `{3, index}`; exhausted feed → `nil`
  (no `x-ms-continuation-continuation` echo, Azure parity); garbage or
  foreign-version token → `{:error, :invalid_continuation}` (typed 400 at
  surface). Version tag 3 = namespace separation from cosmos.ex's own token
  namespaces.
- `mod_since_filter/2`: keeps docs with `_ts >= instant` (Azure parity:
  If-Modified-Since returns docs changed at-or-after the instant).
- `mod_since/1`: RFC1123 parse via `:httpd_util.convert_request_date/1`;
  malformed → `{:error, :bad_request}` (typed 400 at surface).

## Verification (real output)

Standalone elixirc: RC=0 (exit 0), zero errors, zero warnings.

Witness (tmp/w6ai_witness.exs, real Store boot, seeded 25 docs):
```
SEEDED=25
PAGE1=10 CONT1=true
PAGE2=10 CONT2=true
PAGE3=5 CONT3=true
CHAIN_EXACT=true
GARBAGE_TOKEN_400=ok
VERSION_MISMATCH_400=ok
MOD_SINCE_FUTURE=0
MOD_SINCE_PARSE=ok
MOD_SINCE_PAST_ALL=25
W6AI WITNESS: ALL FACES OK
```
(CONT3=true = continuation IS nil on exhaustion — the no-header echo face.)
Replay: `elixir -pa <standalone store beams> -pa tmp/w6ai_ebin tmp/w6ai_witness.exs`
(store.ex + store_tables.ex compiled standalone into a scratch ebin; full
tree was mid-integration under the w6R router split).

## Deferred to integration

- Surface exposure: 3-5 additive lines at the query/list arms (w6h plug
  pattern applies post router-split).
- Full-tree compile gate + census run: tree mid-integration (w6R split in
  flight); verified standalone per the wave SLA; ALIVE flip rides
  integration.

## Disclosures

- Foreign repair disclosure: coordinator/w6R minimally repaired a corruption
  artifact in cosmos_feeds.ex during my lane (the wave's large-Write
  degradation class); disk state reconciled before further edits — final
  file matches my clean rewrite and compiles zero-warning.
- Two large-Write corruption artifacts hit my own lane payloads (module
  draft, first witness draft, one receipt draft); each was caught and
  rewritten clean before landing — the corruption never reached a landed
  file in a broken state.
- No Process.sleep (bounded polls only), no mocks (real Store boot), no git
  commands.
